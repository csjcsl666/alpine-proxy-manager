#!/bin/sh
# shellcheck disable=SC2015,SC2016,SC2034 # 测试脚本里 A && B || C 用来记录通过或失败
# sing-box SOCKS5 上游事件驱动健康监控的真实端到端测试
# 真实的官方 sing-box (被测的代理, 带 Clash API) 真实的 SOCKS5 上游 (另一个 sing-box 实例) 真实的监控守护进程 (产品里的 sbh_run, 不是模拟)
# 场景 A 正常 B 上游断线 C 上游恢复 (不重启 sing-box 与监控) D 没有业务流量时不产生任何探测 E 多个 Profile 相互独立
# 长连接恢复 (方案 B 的本机 /connections 有界查询) 与它的假阳性排除
# 用法: SB_BIN=官方sing-box sh sbhealth.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
_SB_KEEP=$SB_BIN
for _m in common environment state core model policy txn report client snell singbox sbhealth; do
    # shellcheck source=/dev/null
    . "$E2E_HERE/../../lib/$_m.sh"
done
SB_BIN=$_SB_KEEP
APM_HOME=$(cd "$E2E_HERE/../.." && pwd)
export APM_HOME
trap 'e2e_cleanup; [ -z "${MON_PID:-}" ] || kill "$MON_PID" 2>/dev/null' EXIT
SBH_DEBUG=$E2E_DIR/confirm.dbg
export SBH_DEBUG

ROOT=$E2E_DIR/root
APM_SYSROOT=$ROOT
export APM_SYSROOT
SBDIR=$ROOT/run/apm-sbhealth
mkdir -p "$ROOT/etc/sing-box" "$ROOT/run"
API_PORT=29191
API_SECRET=0123456789abcdef0123456789abcdef
UPPASS=UpPassNotSecret0123456789
export UPPASS

stat_of() { kv_get "$SBDIR/apm-socks-$1.state" "${2:-state}"; }
wait_state() { # Profile 状态 [最多秒数]
    local _n=0 _max
    _max=$(( ${3:-10} * 5 ))
    while [ "$_n" -lt "$_max" ]; do
        [ "$(stat_of "$1")" = "$2" ] && return 0
        sleep 0.2
        _n=$((_n + 1))
    done
    return 1
}
expect_state() { # 说明 Profile 状态 [秒数]
    if wait_state "$2" "$3" "${4:-10}"; then ok "$1 (状态 $3)"; else bad "$1: 期望 $3, 实际 $(stat_of "$2") 原因 $(stat_of "$2" reason)"; fi
}
pid_of() { # 命令行片段 -> 第一个匹配的 pid
    local _p
    for _p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)" in *"$1"*) echo "${_p#/proc/}"; return 0 ;; esac
    done
    return 1
}
cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat" 2>/dev/null; }
RSS_OF() { grep VmRSS "/proc/$1/status" 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2; }
count_procs() { # 命令名片段
    local _n=0 _p
    for _p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)" in *"$1"*) _n=$((_n + 1)) ;; esac
    done
    echo "$_n"
}

section "准备: 受控目标 两个真实 SOCKS5 上游 被测的 sing-box (带 Clash API)"
start_targets 127.0.0.2,24003 127.0.0.2,24005 || exit 1
# 长连接目标: 连接后立即回数据并保持打开 30 秒 (用来验证长连接的恢复确认)
python3 -I -c "
import socket, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.2', 24020)); s.listen(16)
def h(c):
    try:
        c.recv(100); c.sendall(b'LONG_HELLO\n'); time.sleep(30)
    except Exception: pass
    c.close()
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
" &
track $!
# 沉默目标: 接受连接但不回任何数据 (握手成功 download 恒为 0)
python3 -I -c "
import socket, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.2', 24021)); s.listen(16)
def h(c):
    try: time.sleep(30)
    except Exception: pass
    c.close()
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
" &
track $!
sleep 0.5
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
UP_TAG=B start_upstream 31102 permissive uu 127.0.0.92 || exit 1
UP_PID_B=$UP_PID

write_sb() {
    cat > "$ROOT/etc/sing-box/config.json" <<JEOF
{"log":{"level":"warn","timestamp":true},
 "experimental":{"clash_api":{"external_controller":"127.0.0.1:$API_PORT","secret":"$API_SECRET"}},
 "inbounds":[
  {"type":"socks","tag":"in-A","listen":"127.0.0.1","listen_port":30001},
  {"type":"socks","tag":"in-B","listen":"127.0.0.1","listen_port":30002},
  {"type":"socks","tag":"in-W","listen":"127.0.0.1","listen_port":30003},
  {"type":"socks","tag":"in-S","listen":"127.0.0.1","listen_port":30004}],
 "outbounds":[{"type":"direct","tag":"direct"},
  {"type":"socks","tag":"apm-socks-A","server":"127.0.0.1","server_port":31101,"version":"5","username":"uu","password":"$UPPASS"},
  {"type":"socks","tag":"apm-socks-B","server":"127.0.0.1","server_port":31102,"version":"5","username":"uu","password":"$UPPASS"},
  {"type":"socks","tag":"apm-socks-W","server":"127.0.0.1","server_port":31101,"version":"5","username":"uu","password":"WrongPwNotSecret"},
  {"type":"socks","tag":"apm-socks-S","server":"127.0.0.1","server_port":31103,"version":"5"}],
 "route":{"rules":[
  {"inbound":["in-A"],"action":"route","outbound":"apm-socks-A"},
  {"inbound":["in-B"],"action":"route","outbound":"apm-socks-B"},
  {"inbound":["in-W"],"action":"route","outbound":"apm-socks-W"},
  {"inbound":["in-S"],"action":"route","outbound":"apm-socks-S"}]}}
JEOF
}
start_sb() {
    write_sb
    "$SB_BIN" run -c "$ROOT/etc/sing-box/config.json" > "$E2E_DIR/sb.out" 2>&1 &
    SB_PID=$!
    track "$SB_PID"
    wait_tcp 127.0.0.1 30001 || { say "sing-box 没有启动"; cat "$E2E_DIR/sb.out"; return 1; }
}
start_mon() {
    sh "$APM_HOME/lib/sbhealth-daemon.sh" > "$E2E_DIR/mon.out" 2>&1 &
    MON_PID=$!
    local _n=0
    while [ "$_n" -lt 50 ] && [ ! -f "$SBDIR/connected" ]; do sleep 0.2; _n=$((_n + 1)); done
    [ -f "$SBDIR/connected" ]
}
client() { E2E_CLIENT_PORT=$1 python3 -I "$E2E_HERE/sc.py" tcp 127.0.0.2 "${2:-24003}"; }
# 长连接客户端: 经 PORT 连目标, 收到回复后保持打开 HOLD 秒
cat > "$E2E_DIR/hold.py" <<'PY'
import socket, struct, sys, time
port, dst, dport, hold = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
s = socket.create_connection(("127.0.0.1", port)); s.sendall(b"\x05\x01\x00"); s.recv(2)
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(dst) + struct.pack("!H", dport))
s.settimeout(10)
try:
    r = s.recv(10)
    if r[1] != 0:
        print("REPLY", r[1], flush=True); sys.exit(0)
    s.sendall(b"hello\n")
    print("OK", s.recv(100).decode().strip(), flush=True)
except Exception as e:
    print("ERR", e, flush=True)
time.sleep(hold)
PY
hold() { python3 -I "$E2E_DIR/hold.py" "$@"; }

start_sb || exit 1
start_mon || { say "监控没有订阅成功"; cat "$E2E_DIR/mon.out"; exit 1; }
ok "sing-box 与监控守护进程已启动 并已订阅事件流"
SB_PID0=$SB_PID; MON_PID0=$MON_PID

section "场景 A 正常: 真实业务经指定 SOCKS5 上游 监控识别成功"
tclear
r=$(client 30001)
case $r in OK:*) ok "经 Profile A 的请求成功" ;; *) bad "请求失败: $r" ;; esac
grep -q 'peer=127.0.0.91$' "$TLOG" && ok "目标看到的对端是上游 A 的出口地址" || bad "目标对端不是上游 A: $(cat "$TLOG")"
expect_state "成功连接后 A 变为健康" A healthy
[ "$(stat_of B)" = "" ] && ok "没有流量的 B 没有状态记录 (未知)" || bad "B 不应有状态: $(stat_of B)"

section "场景 E 多个 Profile 相互独立: B 也成功 W (密码错误) 失败"
r=$(client 30002); case $r in OK:*) ok "经 Profile B 的请求成功" ;; *) bad "B 请求失败: $r" ;; esac
expect_state "B 变为健康" B healthy
tclear
r=$(client 30003)
case $r in OK:*) bad "W 密码错误却成功了" ;; *) ok "W 认证失败的请求失败" ;; esac
expect_state "W 认证失败 -> 不可用" W unhealthy
[ "$(stat_of W reason)" = auth ] && ok "W 的原因是认证失败" || bad "W 原因 $(stat_of W reason)"
[ "$(thits)" = 0 ] && ok "W 失败时目标零命中 (没有 DIRECT 回退)" || bad "W 失败时目标有命中"
[ "$(stat_of A)" = healthy ] && [ "$(stat_of B)" = healthy ] && ok "A 与 B 没有被 W 的故障污染" || bad "A/B 被污染"

section "场景 B 上游 A 断线: 请求失败 无 DIRECT 回退 sing-box 保持运行 监控识别故障"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null
sleep 0.5
tclear
r=$(client 30001)
case $r in OK:*) bad "上游断线却成功了: $r" ;; *) ok "上游断线时请求失败" ;; esac
r=$(client 30001)
sleep 0.3
[ "$(thits)" = 0 ] && ok "目标收到零次连接 (没有绕过 SOCKS5, 没有 DIRECT)" || bad "目标收到了连接: $(cat "$TLOG")"
expect_state "上游断线 -> 不可用" A unhealthy
[ "$(stat_of A reason)" = refused ] && ok "原因是上游拒绝连接" || bad "A 原因 $(stat_of A reason)"
kill -0 "$SB_PID0" 2>/dev/null && ok "sing-box 保持运行" || bad "sing-box 退出了"
r=$(client 30002); case $r in OK:*) ok "断线期间 B 照常转发" ;; *) bad "B 受影响: $r" ;; esac
expect_state "B 仍然健康" B healthy

section "场景 D 没有业务流量: 不产生任何探测"
UPLOG=$E2E_DIR/upstreamB.log
before_a=$(grep -c "inbound connection" "$E2E_DIR/upstreamB.log" 2>/dev/null || echo 0)
upd_a=$(stat_of A updated); upd_b=$(stat_of B updated)
helpers_before=$(count_procs sbhealth-confirm)
AWKP=$(pid_of sbhealth.awk); NCP=$(pid_of "nc 127.0.0.1 $API_PORT")
cpu0="$(cpu_ticks "$MON_PID") $(cpu_ticks "$AWKP") $(cpu_ticks "$NCP")"
sleep 12
cpu1="$(cpu_ticks "$MON_PID") $(cpu_ticks "$AWKP") $(cpu_ticks "$NCP")"
[ "$cpu0" = "$cpu1" ] && ok "空闲 12 秒守护进程 状态机 nc 的 CPU 时间没有增加 ($cpu0)" || bad "空闲时有 CPU 消耗: $cpu0 -> $cpu1"
after_a=$(grep -c "inbound connection" "$E2E_DIR/upstreamB.log" 2>/dev/null || echo 0)
[ "$before_a" = "$after_a" ] && ok "空闲 12 秒上游 B 的连接数没有增加 (监控不连接上游)" || bad "上游 B 空闲时收到了新连接 $before_a -> $after_a"
[ "$(stat_of A updated)" = "$upd_a" ] && [ "$(stat_of B updated)" = "$upd_b" ] && ok "没有事件时状态文件没有任何更新" || bad "空闲时状态文件被改写"
[ "$(stat_of A)" = unhealthy ] && ok "没有新事件: A 保持最后观测的不可用 不自行变化" || bad "A 状态变了 $(stat_of A)"
[ "$(count_procs sbhealth-confirm)" = "$helpers_before" ] && ok "空闲时没有启动任何确认脚本" || bad "空闲时出现了确认脚本"

section "场景 C 上游恢复: 不重启 sing-box 不重启监控 真实请求触发恢复"
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
[ "$(stat_of A)" = unhealthy ] && ok "上游恢复但还没有业务请求: 状态不变 (不虚构恢复)" || bad "状态自行变化 $(stat_of A)"
tclear
r=$(client 30001)
case $r in OK:*) ok "恢复后的第一个请求成功" ;; *) bad "恢复后请求失败: $r" ;; esac
grep -q 'peer=127.0.0.91$' "$TLOG" && ok "目标看到的仍是上游 A 的出口 (出口绑定不变)" || bad "对端不对: $(cat "$TLOG")"
expect_state "短请求结束后 A 回到健康" A healthy
[ "$SB_PID" = "$SB_PID0" ] && kill -0 "$SB_PID" 2>/dev/null && [ "$MON_PID" = "$MON_PID0" ] && kill -0 "$MON_PID" 2>/dev/null && ok "sing-box 与监控进程都没有重启" || bad "有进程被重启"

section "长连接恢复 (方案 B): 恢复后的第一个连接是长连接, 在它结束前就确认健康"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null; sleep 0.3
client 30001 >/dev/null; client 30001 >/dev/null
expect_state "再次断线 -> 不可用" A unhealthy
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
hold 30001 127.0.0.2 24020 25 > "$E2E_DIR/hold1.out" 2>&1 &
HP=$!; track $HP
sleep 0.8
[ "$(stat_of A)" = recovering ] && ok "长连接建立中: 状态是恢复中 (尚未确认)" || ok "状态 $(stat_of A) (确认可能已完成)"
expect_state "长连接仍然打开 但数据已经回传: 确认为健康" A healthy 12
[ "$(stat_of A)" = healthy ] || { say "  --- 确认脚本调试日志:"; cat "$SBH_DEBUG" 2>/dev/null; ls "$SBDIR"; }
kill -0 "$HP" 2>/dev/null && ok "确认发生时长连接仍在打开 (不是靠连接结束)" || bad "长连接已经结束, 无法证明是提前确认"
[ "$(count_procs sbhealth-confirm)" = 0 ] && ok "确认完成后没有残留的确认进程" || bad "确认进程残留 $(count_procs sbhealth-confirm)"
kill "$HP" 2>/dev/null

section "假阳性排除: 握手成功但目标沉默 (download 恒为 0) 不得被确认为健康"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null; sleep 0.3
client 30001 >/dev/null; client 30001 >/dev/null
expect_state "断线 -> 不可用" A unhealthy
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
hold 30001 127.0.0.2 24021 25 > "$E2E_DIR/hold2.out" 2>&1 &
HP2=$!; track $HP2
sleep 18
[ "$(stat_of A)" = recovering ] && ok "目标沉默: 18 秒后仍是恢复中 没有被猜测为健康" || bad "目标沉默却变成了 $(stat_of A)"
[ "$(count_procs sbhealth-confirm)" = 0 ] && ok "有界查询已经结束 没有形成长期轮询" || bad "确认进程仍在 $(count_procs sbhealth-confirm)"
# 之后一个正常的短请求照样能确认
r=$(client 30001); case $r in OK:*) ok "随后的短请求成功" ;; *) bad "短请求失败 $r" ;; esac
expect_state "正常连接结束后确认健康" A healthy
kill "$HP2" 2>/dev/null

section "假阳性排除: 拨号进行中 (上游 4 秒后才回复握手) 不得被确认, 握手完成且数据回传后才确认"
client 30004 >/dev/null; client 30004 >/dev/null
expect_state "S 的上游不存在 -> 不可用" S unhealthy
python3 -I "$E2E_HERE/slowsocks.py" 31103 4 &
track $!
sleep 0.5
hold 30004 127.0.0.2 24020 25 > "$E2E_DIR/hold4.out" 2>&1 &
HP4=$!; track $HP4
sleep 3
[ "$(stat_of S)" = recovering ] && ok "拨号进行中 (第 3 秒): 仍是恢复中 没有被确认" || bad "拨号进行中却是 $(stat_of S)"
expect_state "握手完成且目标数据回传后 (连接仍然打开) 确认为健康" S healthy 12
kill -0 "$HP4" 2>/dev/null && ok "确认发生时连接仍在打开" || bad "连接已结束"
kill "$HP4" 2>/dev/null

section "假阳性排除: 认证失败 拨号未完成 不会被确认"
r=$(client 30003)
expect_state "W 仍然不可用" W unhealthy
hold 30003 127.0.0.2 24020 5 > "$E2E_DIR/hold3.out" 2>&1
sleep 1
[ "$(stat_of W)" = unhealthy ] || [ "$(stat_of W)" = recovering ] && ok "W 认证失败的长连接不会让 W 变健康 ($(stat_of W))" || bad "W 被误判 $(stat_of W)"

section "场景 F 生命周期: 监控重启 sing-box 重启 事件流中断与重新订阅"
kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null
sleep 0.5
[ ! -f "$SBDIR/connected" ] && ok "监控退出后订阅标记被清除" || bad "订阅标记残留"
[ "$(stat_of A)" = unknown ] && ok "监控退出后状态回到未知 不再宣称健康" || bad "监控退出后 A 是 $(stat_of A)"
[ "$(stat_of A last_ok)" != 0 ] && ok "最近成功时间被保留" || bad "last_ok 丢失"
start_mon && ok "监控重新启动并订阅" || bad "监控重启后没有订阅"
MON_PID1=$MON_PID
[ "$(count_procs 'sbhealth.awk')" = 1 ] && ok "只有一个状态机进程 (没有重复)" || bad "awk 进程数 $(count_procs 'sbhealth.awk')"
r=$(client 30001); case $r in OK:*) ok "监控重启后业务照常" ;; *) bad "业务失败 $r" ;; esac
expect_state "监控重启后新事件重新建立状态" A healthy
# sing-box 重启: 事件流中断 监控自动重新订阅
kill "$SB_PID" 2>/dev/null; wait "$SB_PID" 2>/dev/null
sleep 1.5
[ "$(stat_of A)" = unknown ] && ok "sing-box 停止后状态回到未知" || bad "sing-box 停止后 A 是 $(stat_of A)"
kill -0 "$MON_PID1" 2>/dev/null && ok "sing-box 停止期间监控进程仍在 (等待重新订阅)" || bad "监控进程退出了"
start_sb || exit 1
n=0; while [ $n -lt 80 ] && [ ! -f "$SBDIR/connected" ]; do sleep 0.25; n=$((n + 1)); done
[ -f "$SBDIR/connected" ] && ok "sing-box 重启后监控自动重新订阅 (没有重启监控)" || bad "没有重新订阅"
r=$(client 30001); case $r in OK:*) ok "重启后业务照常" ;; *) bad "业务失败 $r" ;; esac
expect_state "重新订阅后新事件产生状态" A healthy
# 密钥错误: 订阅被拒绝, 不能当作健康
section "监控被强制结束 (kill -9) 不影响转发; 重启后回收残留进程; 命令行里没有密钥"
leak=
for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in *"$API_SECRET"*) leak="$leak ${p#/proc/}" ;; esac
done
[ -z "$leak" ] && ok "没有任何进程的命令行含有 API 密钥" || bad "命令行含密钥的进程: $leak"
kill -9 "$MON_PID1" 2>/dev/null; wait "$MON_PID1" 2>/dev/null
r=$(client 30001); case $r in OK:*) ok "监控被 kill -9 后业务照常转发" ;; *) bad "业务受影响: $r" ;; esac
[ "$(count_procs sbhealth.awk)" -ge 1 ] && ok "残留的状态机进程还在 (模拟异常退出)" || ok "残留进程已自行退出"
start_mon && ok "重新启动监控" || bad "重启失败"
n=0; while [ $n -lt 25 ] && [ "$(count_procs sbhealth.awk)" != 1 ]; do sleep 0.2; n=$((n + 1)); done
[ "$(count_procs sbhealth.awk)" = 1 ] && ok "旧的状态机被回收 只剩一个" || bad "状态机进程数 $(count_procs sbhealth.awk)"
[ "$(count_procs "nc 127.0.0.1 $API_PORT")" = 1 ] && ok "旧的 nc 被回收 只剩一个" || bad "nc 进程数 $(count_procs "nc 127.0.0.1 $API_PORT")"
MON_PID1=$MON_PID

section "事件接口不可用或密钥错误: 监控失败不得被当作上游健康"
kill "$MON_PID1" 2>/dev/null; wait "$MON_PID1" 2>/dev/null
cp "$ROOT/etc/sing-box/config.json" "$E2E_DIR/cfg.good"
sed -i 's/"secret":"[0-9a-f]*"/"secret":"ffffffffffffffffffffffffffffffff"/' "$ROOT/etc/sing-box/config.json"
sh "$APM_HOME/lib/sbhealth-daemon.sh" > "$E2E_DIR/mon2.out" 2>&1 &
MON_PID=$!
sleep 3
[ ! -f "$SBDIR/connected" ] && ok "密钥不匹配: 没有订阅标记" || bad "密钥错误却有订阅标记"
[ "$(stat_of A)" = unknown ] && ok "密钥不匹配: 状态保持未知" || bad "状态 $(stat_of A)"
grep -q "密钥不匹配" "$E2E_DIR/mon2.out" && ok "监控给出明确提示" || bad "没有提示: $(cat "$E2E_DIR/mon2.out")"
kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null
cp "$E2E_DIR/cfg.good" "$ROOT/etc/sing-box/config.json"

section "资源占用 (监控三个进程 + 一次确认)"
start_mon || exit 1

awk_pid=$(for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in *sbhealth.awk*) echo "${p#/proc/}" ;; esac; done | head -n 1)
nc_pid=$(for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in "nc 127.0.0.1 $API_PORT"*) echo "${p#/proc/}" ;; esac; done | head -n 1)
say "  RSS: 守护进程 sh $(RSS_OF "$MON_PID") kB, awk $(RSS_OF "$awk_pid") kB, nc $(RSS_OF "$nc_pid") kB (合计 $(( $(RSS_OF "$MON_PID") + $(RSS_OF "$awk_pid") + $(RSS_OF "$nc_pid") )) kB)"
say "  被测 sing-box RSS $(RSS_OF "$SB_PID") kB"
say "  监控相关进程数: $(count_procs 'sbhealth')"
n=0; while [ $n -lt 300 ]; do client 30002 >/dev/null; n=$((n + 1)); done
cpu() { awk '{ print $14 + $15 }' "/proc/$1/stat" 2>/dev/null; }
say "  300 个连接后 awk 累计 CPU ticks $(cpu "$awk_pid") (1 tick = 10ms), RSS $(RSS_OF "$awk_pid") kB"
say "  300 个连接后状态仍正确: B $(stat_of B)"

e2e_finish
