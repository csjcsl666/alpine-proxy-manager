# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# sing-box SOCKS5 上游健康状态机 (lib/sbhealth.awk): 用合成的 Clash API 日志流验证状态转换 原因分类 隔离 脱敏 无事件时不变
# 全部输入是虚构的, 时钟由测试文件控制, 不依赖 sleep
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

AWKF="$T_ROOT/lib/sbhealth.awk"
D=$T_TMP/sbh
mkdir -p "$D"

hdr() { printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n'; }
# 事件构造: ev 类型 ID 文本 -> 一行 JSON (与 Clash API /logs 一致)
ev() { printf '{"type":"%s","payload":"[%s 0ms] %s"}\n' "$1" "$2" "$3"; }
att() { ev info "$1" "outbound/socks[apm-socks-$2]: outbound connection to target.invalid:443"; }
fail() { ev error "$1" "connection: open connection to target.invalid:443 using outbound/socks[apm-socks-$2]: $3"; }
fin() { ev debug "$1" "connection: connection download finished"; }
T() { printf '@T %s\n' "$1"; }
# run: 标准输入是事件, 输出到目录 D; 返回后状态文件已写入
run() { rm -f "$D"/*.state "$D"/connected "$D"/confirm.* "$D"/profiles; SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF"; }
runkeep() { SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF"; }
st() { kv_get "$D/apm-socks-$1.state" "${2:-state}"; }
# 读取 kv (不依赖整个产品库)
kv_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }

# 事件流 = 响应头 + 事件, 末尾 EOF 触发 END (订阅结束)
# 为了在 END 之前检查状态, 测试用 head 截断的方式不可行, 所以每个用例都分成: 流内状态 (通过 last_state 记录) 与 结束后的 unknown
# 用 last_state 读取流结束前的最后状态
last() { kv_get "$D/apm-socks-$1.state" last_state; }

# ---- 正常 -> 健康 ----
{ hdr; T 1000; att 11 A; fin 11 A; } | run
assert_eq "成功连接后最后状态是 healthy" healthy "$(last A)"
assert_eq "last_ok 记录事件时间" 1000 "$(st A last_ok)"
assert_eq "流结束后回到 unknown" unknown "$(st A)"
assert_eq "流结束后原因是 monitor-down" monitor-down "$(st A reason)"
assert_eq "流结束时 connected 标记被清除" no "$([ -e "$D/connected" ] && echo yes || echo no)"

# ---- 失败分类 ----
for c in "dial tcp 192.0.2.1:1080: connect: connection refused|refused" \
         "dial tcp 192.0.2.1:1080: connect: network is unreachable|unreachable" \
         "dial tcp 192.0.2.1:1080: connect: no route to host|unreachable" \
         "dial tcp 192.0.2.1:1080: i/o timeout|timeout" \
         "dial tcp: lookup up.example.test on 127.0.0.53:53: no such host|dns" \
         "socks5: incorrect user name or password|auth" \
         "socks5: unsupported version|protocol" \
         "read tcp 127.0.0.1:1->192.0.2.1:1080: read: connection reset by peer|protocol" \
         "EOF|protocol"; do
    txt=${c%|*}; code=${c##*|}
    { hdr; att 21 B; fail 21 B "$txt"; } | run
    assert_eq "失败分类 $code: $txt" "$code" "$(st B last_fail_reason)"
done

# ---- 与上游健康无关的错误不得影响状态 ----
{ hdr; T 1100; att 31 C; fin 31 C; fail 32 C "socks5: request rejected, code=1"; fail 33 C "context canceled"; fail 34 C "some unknown new error text"; } | run
assert_eq "code=1 context canceled 未知错误不改变 healthy" healthy "$(last C)"
assert_eq "中性错误不记录失败时间" 0 "$(st C last_fail)"
# 目标侧错误 (上游回复了错误码 2 到 6) 证明上游在线并通过认证
{ hdr; T 1200; fail 41 D "socks5: request rejected, code=5"; } | run
assert_eq "上游回复 code=5 (目标拒绝) 视为上游在线" healthy "$(last D)"
assert_eq "目标侧错误没有记录失败" 0 "$(st D last_fail)"
{ hdr; T 1210; att 51 D; fail 51 D "dial tcp 192.0.2.1:1080: connect: connection refused"; fail 52 D "socks5: request rejected, code=4"; } | run
assert_eq "一次拨号失败后收到目标侧错误: 回到 healthy 且失败时间被保留" healthy "$(last D)"
assert_eq "失败时间保留" 1210 "$(st D last_fail)"

# ---- 状态机: healthy -> degraded -> unhealthy -> recovering -> healthy (一个流里按时间推进, 每步截取快照) ----
S() { printf '@S %s\n' "$1"; }
snap() { kv_get "$D/apm-socks-$1.snap.$2" "${3:-state}"; }
REF="dial tcp 192.0.2.1:1080: connect: connection refused"
AUTH="socks5: incorrect user name or password"
{ hdr
  T 2000; att 61 E; fin 61 E; S a
  T 2010; att 62 E; fail 62 E "$REF"; S b
  T 2020; att 63 E; fail 63 E "$REF"; S c
  T 2030; att 64 E; S d
  T 2040; fin 64 E; S e
} | run
assert_eq "成功后 healthy" healthy "$(snap E a)"
assert_eq "第一次失败是 degraded" degraded "$(snap E b)"
assert_eq "窗口内第二次失败是 unhealthy" unhealthy "$(snap E c)"
assert_eq "不可用的原因" refused "$(snap E c reason)"
assert_eq "不可用时 last_ok 仍保留" 2000 "$(snap E c last_ok)"
assert_eq "不可用后出现新的拨号: recovering" recovering "$(snap E d)"
assert_eq "recovering 时仍显示上次的失败原因" refused "$(snap E d reason)"
assert_eq "新连接完成: healthy" healthy "$(snap E e)"
assert_eq "healthy 后原因清空" "" "$(snap E e reason)"
assert_eq "恢复后 last_ok 更新" 2040 "$(snap E e last_ok)"
{ hdr
  T 3000; att 71 F; fail 71 F "$AUTH"; S a
  T 3001; att 72 F; S b
  T 3002; fail 72 F "$AUTH"; S c
  T 3003; att 73 F; fin 73 F; S d
} | run
assert_eq "认证失败一次就 unhealthy" unhealthy "$(snap F a)"
assert_eq "认证失败的原因" auth "$(snap F a reason)"
assert_eq "新尝试后是 recovering" recovering "$(snap F b)"
assert_eq "recovering 时再次失败回到 unhealthy" unhealthy "$(snap F c)"
assert_eq "之后成功 -> healthy" healthy "$(snap F d)"
{ hdr
  T 3010; att 91 G; fail 91 G "$REF"; att 92 G; fail 92 G "$REF"; S a
  T 3011; att 93 G; fail 93 G "$REF"; S b
  T 3012; att 94 G; S c
} | run
assert_eq "连续失败 unhealthy" unhealthy "$(snap G a)"
assert_eq "unhealthy 时继续失败保持 unhealthy" unhealthy "$(snap G b)"
assert_eq "再次出现拨号: recovering" recovering "$(snap G c)"
assert_eq "连续失败计数" 3 "$(snap G b streak)"

# ---- 失败窗口: 超过窗口的失败不累计 ----
{ hdr
  T 4000; att 101 H; fail 101 H "$REF"
  T 4500; att 102 H; fail 102 H "$REF"; S a
  T 4501; att 103 H; fail 103 H "$REF"; S b
} | run
assert_eq "间隔超过窗口的两次失败仍是 degraded" degraded "$(snap H a)"
assert_eq "窗口内的第二次失败才是 unhealthy" unhealthy "$(snap H b)"

# ---- 无事件时状态不变: 时间流逝本身不产生任何转换 ----
{ hdr
  T 4600; att 111 R; fin 111 R; S a
  T 99999; S b
} | run
assert_eq "没有新事件, 很久以后状态文件仍是原状态" healthy "$(snap R b)"
assert_eq "没有新事件, last_ok 不变" 4600 "$(snap R b last_ok)"

# ---- 多个 Profile 互相独立 ----
{ hdr; T 5000; att 111 I; fin 111 I; att 112 J; fail 112 J "socks5: incorrect user name or password"; att 113 K; fin 113 K; } | run
assert_eq "I healthy" healthy "$(last I)"
assert_eq "J unhealthy" unhealthy "$(last J)"
assert_eq "K healthy" healthy "$(last K)"
assert_eq "J 的失败没有污染 I" 0 "$(st I last_fail)"

# ---- ID 交错 (并发连接) ----
{ hdr; T 5100; att 121 L; att 122 M; fail 122 M "dial tcp 192.0.2.1:1080: connect: connection refused"; fin 121 L; } | run
assert_eq "并发: L 成功" healthy "$(last L)"
assert_eq "并发: M 单次失败" degraded "$(last M)"

# ---- 脱敏: 状态文件里没有目标 域名 地址 用户名 密码 ----
{ hdr; T 5200; att 131 N; fail 131 N "dial tcp 203.0.113.9:1080: connect: connection refused"; } | run
assert_eq "状态文件不含目标域名" "" "$(grep -rl 'target.invalid' "$D" 2>/dev/null)"
assert_eq "状态文件不含上游地址" "" "$(grep -rl '203.0.113.9' "$D" 2>/dev/null)"
{ hdr; att 141 N; fail 141 N "socks5: incorrect user name or password"; } | run
assert_eq "状态文件内容只有固定字段" "version state reason since last_ok last_fail last_fail_reason streak updated last_state" "$(cut -d= -f1 "$D/apm-socks-N.state" | tr '\n' ' ' | sed 's/ $//')"

# ---- 不相关的行 ----
{ hdr; T 5300; ev info 151 "inbound/socks[in-A]: inbound connection from 127.0.0.1:1"; ev info 151 "outbound/direct[direct]: outbound connection to x:1"; ev error 151 "connection: open connection to x:1 using outbound/direct[direct]: dial tcp: connection refused"; ev error 152 "connection: open connection to x:1 using outbound/socks[not-apm]: socks5: incorrect user name or password"; ev error 153 "connection: open connection to x:1 using outbound/socks[apm-socks-../../etc]: socks5: incorrect user name or password"; printf 'garbage line\n'; printf '{"type":"error"}\n'; } | run
assert_eq "不相关的行不产生任何状态文件" "" "$(ls "$D" | grep '\.state$')"

# ---- 订阅失败 (密钥错误) ----
printf 'HTTP/1.1 401 Unauthorized\r\n\r\n' | SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF" 2>/dev/null
assert_eq "401 以非零退出" 3 "$?"

# ---- 流结束后的重连: 历史时间戳被保留, 状态从 unknown 开始 ----
{ hdr; T 6000; att 161 P; fin 161 P; } | run
{ hdr; T 6100; att 162 P; } | runkeep
assert_eq "重连后第一个事件前没有证据: 流内保持 unknown" unknown "$(last P)"
assert_eq "重连后保留旧的 last_ok" 6000 "$(st P last_ok)"

# ---- 无事件 = 无变化, 也没有自行产生的任何输出 ----
rm -f "$D"/*.state
hdr | runkeep
assert_eq "只有响应头没有事件: 不产生状态文件" "" "$(ls "$D" | grep '\.state$')"

# ---- 压力: 大量并发未结束的连接不会让内存无限增长 ----
n=0
{ hdr; while [ $n -lt 6000 ]; do att $((200000 + n)) Q; n=$((n + 1)); done; fin 200000 Q; fin 205999 Q; } | run
assert_eq "6000 个未结束连接后最新的完成事件仍被识别" healthy "$(last Q)"

# ---- 恢复确认 (方案 B) 的触发规则: 只有 recovering 且出现新的真实拨号, 同一个 Profile 同一时间最多一组, 有冷却 ----
CONF_LOG=$T_TMP/confirm.log
cat > "$T_TMP/confirm-stub.sh" <<'EOS'
#!/bin/sh
echo "$1" >> "$CONF_LOG"
cp "$SBH_DIR/confirm.$1.req" "$CONF_LOG.req" 2>/dev/null
EOS
chmod +x "$T_TMP/confirm-stub.sh"
runc() { rm -f "$D"/*.state "$D"/connected "$D"/confirm.* "$D"/profiles; : > "$CONF_LOG"; rm -f "$CONF_LOG.req"; CONF_LOG=$CONF_LOG SBH_CONFIRM="$T_TMP/confirm-stub.sh" SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF"; sleep 0.3; }
src() { ev info "$1" "inbound/socks[in-A]: inbound connection from $2"; }
nconf() { local n; n=$(grep -c . "$CONF_LOG" 2>/dev/null); echo "${n:-0}"; }
S() { printf '@S %s\n' "$1"; }
REF="dial tcp 192.0.2.1:1080: connect: connection refused"
AUTH="socks5: incorrect user name or password"
# 触发: unhealthy 后第一个新的拨号 -> 一组
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 A; fail 1 A "$AUTH"; src 2 127.0.0.1:50002; att 2 A; } | runc
assert_eq "recovering 的新拨号触发一组确认" 1 "$(nconf)"
assert_eq "确认的是 A" apm-socks-A "$(head -n 1 "$CONF_LOG")"
assert_eq "请求里是新连接的来源和时间" "127.0.0.1:50002 100" "$(cat "$CONF_LOG.req")"
# 同时只有一组, 后到的拨号只更新请求文件
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 A; fail 1 A "$AUTH"; src 2 127.0.0.1:50002; att 2 A; T 101; src 3 127.0.0.1:50003; att 3 A; src 4 "[2001:db8::5]:50004"; att 4 A; } | runc
assert_eq "高并发的新拨号不会启动更多组" 1 "$(nconf)"
assert_eq "请求文件包含所有待确认连接" "[2001:db8::5]:50004 101
127.0.0.1:50003 101
127.0.0.1:50002 100" "$(sort -r "$D/confirm.apm-socks-A.req")"
# healthy degraded 的 Profile 不触发
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 B; fin 1 B; src 2 127.0.0.1:50002; att 2 B; fail 2 B "$REF"; src 3 127.0.0.1:50003; att 3 B; } | runc
assert_eq "healthy 和 degraded 的新拨号不触发确认" 0 "$(nconf)"
# 没有来源的拨号 (入站行缺失) 不触发
{ hdr; T 100; att 1 C; fail 1 C "$AUTH"; att 2 C; } | runc
assert_eq "没有来源记录的拨号不触发确认" 0 "$(nconf)"
# 回报 ok: recovering 才接受
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 D; fail 1 D "$AUTH"; src 2 127.0.0.1:50002; att 2 D; S a; printf '@C ok apm-socks-D\n'; S b; } | runc
assert_eq "recovering 时收到 ok 回报" recovering "$(snap D a)"
assert_eq "确认回报后变为 healthy" healthy "$(snap D b)"
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 E; fin 1 E; printf '@C ok apm-socks-E\n'; S a; } | runc
assert_eq "非 recovering 时的 ok 回报被忽略 (仍是 healthy 且不改时间)" healthy "$(snap E a)"
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 F; fail 1 F "$AUTH"; printf '@C ok apm-socks-F\n'; S a; } | runc
assert_eq "unhealthy (没有新拨号) 时 ok 回报被忽略" unhealthy "$(snap F a)"
{ hdr; T 100; printf '@C ok apm-socks-Zzz\n@C ok ../x\n@C bogus apm-socks-A\n'; } | runc
assert_eq "未知 Profile 与非法标签的回报被忽略 不产生状态文件" "" "$(ls "$D" | grep '\.state$')"
# end 回报后冷却 20 秒, 之后新的拨号再触发; 新的故障周期清除冷却
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 G; fail 1 G "$AUTH"; src 2 127.0.0.1:50002; att 2 G; printf '@C end apm-socks-G\n'; T 105; src 3 127.0.0.1:50003; att 3 G; T 125; src 4 127.0.0.1:50004; att 4 G; } | runc
assert_eq "end 之后冷却内不再触发 冷却过后再触发 (共 2 组)" 2 "$(nconf)"
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 H; fail 1 H "$AUTH"; src 2 127.0.0.1:50002; att 2 H; printf '@C end apm-socks-H\n'; T 101; fail 2 H "$AUTH"; src 3 127.0.0.1:50003; att 3 H; } | runc
assert_eq "新的故障周期不受上一周期冷却影响 (共 2 组)" 2 "$(nconf)"
# 只保留最新的 16 个
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 I; fail 1 I "$AUTH"; n=2; while [ $n -le 30 ]; do src $n 127.0.0.1:$((50000 + n)); att $n I; n=$((n + 1)); done; } | runc
assert_eq "请求文件最多 16 个待确认连接" 16 "$(grep -c . "$D/confirm.apm-socks-I.req")"
assert_not_contains "保留的是最新的" "$(cat "$D/confirm.apm-socks-I.req")" "127.0.0.1:50002 "
# 没有设置确认脚本时完全不启用 B
{ hdr; T 100; src 1 127.0.0.1:50001; att 1 J; fail 1 J "$AUTH"; src 2 127.0.0.1:50002; att 2 J; } | run
assert_eq "没有 SBH_CONFIRM 时不产生请求文件" "" "$(ls "$D" | grep '^confirm\.')"

# ---- 每个 Profile 的监控开关: 关闭的 Profile 不产生也不保留任何状态, 重新开启从未知开始 ----
P() { printf '@P %s\n' "$1"; }
PC() { printf '@PC\n'; }
runp() { rm -f "$D"/*.state "$D"/*.snap.* "$D"/connected "$D"/confirm.*; printf '%s' "$1" > "$D/profiles"; SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF"; }
# 启动时就关闭的 Profile: 事件被忽略, 没有状态文件; 其他 Profile 不受影响
{ hdr; T 100; att 1 A; fin 1 A; att 2 B; fin 2 B; att 3 A; fail 3 A "$AUTH"; } | runp "A off 1
"
assert_eq "关闭的 Profile 没有状态文件" no "$([ -e "$D/apm-socks-A.state" ] && echo yes || echo no)"
assert_eq "没有关闭的 Profile 照常记录" healthy "$(last B)"
# 运行中关闭: 之前的健康状态被丢弃, 状态文件被删除
{ hdr; T 100; att 1 C; fin 1 C; S a; PC; P "C off 1"; T 101; att 2 C; fail 2 C "$AUTH"; S b; } | runp ""
assert_eq "关闭前是 healthy" healthy "$(snap C a)"
assert_eq "关闭后状态文件被删除" no "$([ -e "$D/apm-socks-C.state" ] && echo yes || echo no)"
assert_eq "关闭后的失败事件不产生状态" no "$([ -e "$D/apm-socks-C.snap.b" ] && echo yes || echo no)"
# 重新开启: 从未知开始, 不复用关闭前的健康, 也不复用关闭前的失败计数
{ hdr; T 100; att 1 D; fin 1 D; att 2 D; fail 2 D "$REF"; S a; PC; P "D off 1"; T 101; att 3 D; PC; P "D on 2"; T 102; att 4 D; fail 4 D "$REF"; S b; } | runp ""
assert_eq "关闭前有一次失败 degraded" degraded "$(snap D a)"
assert_eq "重新开启后的第一次失败是 degraded 而不是 unhealthy (旧失败计数没有被复用)" degraded "$(snap D b)"
assert_eq "重新开启后 last_ok 不沿用旧值" 0 "$(snap D b last_ok)"
# 关闭前的未结束连接, 在重新开启后结束, 不能被当作新的成功
{ hdr; T 100; att 1 E; fail 1 E "$AUTH"; att 2 E; PC; P "E off 1"; T 101; att 3 E; PC; P "E on 2"; T 102; fin 2 E; fin 3 E; S a; } | runp ""
assert_eq "关闭期间留下的未结束连接不会在重新开启后造成健康" no "$([ -e "$D/apm-socks-E.snap.a" ] && echo yes || echo no)"
# 另一个 Profile 的开关变化不影响这一个
{ hdr; T 100; att 1 G; fin 1 G; att 2 H; fin 2 H; PC; P "H off 1"; T 101; att 3 G; fin 3 G; S a; } | runp ""
assert_eq "关闭 H 不影响 G" healthy "$(snap G a)"
assert_eq "关闭 H 后 H 没有状态" no "$([ -e "$D/apm-socks-H.snap.a" ] && echo yes || echo no)"
# 恢复确认的回报对关闭的 Profile 无效
{ hdr; T 100; att 1 I; fail 1 I "$AUTH"; src 2 127.0.0.1:50002; att 2 I; PC; P "I off 1"; T 101; printf '@C ok apm-socks-I\n'; S a; } | runp ""
assert_eq "关闭后收到确认回报也不产生状态" no "$([ -e "$D/apm-socks-I.snap.a" ] && echo yes || echo no)"
# 启动时目录里残留的、已被关闭的 Profile 的状态文件被删除而不是重置为未知
rm -f "$D"/*.state
printf 'version=1\nstate=healthy\nreason=\nsince=1\nlast_ok=1\nlast_fail=0\nlast_fail_reason=\nstreak=0\nupdated=1\n' > "$D/apm-socks-J.state"
printf 'J off 1\n' > "$D/profiles"
hdr | SBH_DIR=$D SBH_TEST_CLOCK=1 awk -f "$AWKF"
assert_eq "启动时被关闭的 Profile 的残留状态被删除" no "$([ -e "$D/apm-socks-J.state" ] && echo yes || echo no)"

# ---- 源码检查: 状态机不含任何主动探测 ----
SRC=$(cat "$AWKF")
assert_not_contains "不使用 sleep" "$SRC" "sleep"
assert_not_contains "不调用 nc/wget/curl" "$SRC" "wget"
assert_not_contains "不主动建立连接 (无 /inet/)" "$SRC" "/inet/"

t_done
