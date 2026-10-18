#!/bin/sh
# shellcheck disable=SC2015,SC2016,SC2034 # 测试脚本里 A && B || C 用来记录通过或失败
# sing-box SOCKS5 自动故障切换的真实端到端测试
# 真实的官方 sing-box (带 selector 与 Clash API) 真实的 SOCKS5 上游 (另一个 sing-box 实例) 真实的监控守护进程 (产品里的 sbhealth-daemon.sh)
# 恢复验证使用本机 https 目标 (临时信任一张测试证书, 结束后还原), 请求经 sing-box 的 /proxies/<出站>/delay 走指定的 SOCKS5
# 场景: 默认关闭 / 故障切到 DIRECT / 没有流量不探测 / 真实请求触发探测并自动切回 / 两个验证地址的组合 / 认证失败 / 多 Profile 隔离 / 取消授权 / 不重启
# 用法: SB_BIN=官方sing-box sh failover.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
APM_HOME=$(cd "$E2E_HERE/../.." && pwd)
export APM_HOME
CA=/etc/ssl/certs/ca-certificates.crt
cp "$CA" "$E2E_DIR/ca.orig" 2>/dev/null || : > "$E2E_DIR/ca.orig"
trap 'cp "$E2E_DIR/ca.orig" "$CA" 2>/dev/null; e2e_cleanup; [ -z "${MON_PID:-}" ] || kill "$MON_PID" 2>/dev/null' EXIT

ROOT=$E2E_DIR/root
APM_SYSROOT=$ROOT
export APM_SYSROOT
SBDIR=$ROOT/run/apm-sbhealth
HISTDIR=$ROOT/var/lib/sing-box/apm-health
mkdir -p "$ROOT/etc/sing-box" "$ROOT/run" "$SBDIR" "$HISTDIR"
# 监控重启会保留上一次的判断, 所以重复运行前清掉残留的状态与历史文件
rm -f "$SBDIR"/*.state "$HISTDIR"/*.hist
API_PORT=29291
API_SECRET=0123456789abcdef0123456789abcdef
UPPASS=UpPassNotSecret0123456789
export UPPASS

kvg() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }
stat_of() { kvg "$SBDIR/apm-socks-$1.state" "${2:-state}"; }
hist_of() { kvg "$HISTDIR/$1.hist" "$2"; }
wait_for() { # 命令... 最多 N 秒: 由 W_MAX 控制
    local _n=0
    while [ "$_n" -lt $(( ${W_MAX:-15} * 5 )) ]; do
        "$@" && return 0
        sleep 0.2; _n=$((_n + 1))
    done
    return 1
}
st_is() { [ "$(stat_of "$1")" = "$2" ]; }
sel_now() { # Profile -> 当前 selector 选择 (socks 或 direct)
    local _o
    _o=$(printf 'GET /proxies/apm-sel-%s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n' "$1" "$API_SECRET" | nc -w 5 127.0.0.1 "$API_PORT" 2>/dev/null | tr -d '\r' | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p')
    case $_o in apm-socks-*) echo socks ;; direct) echo direct ;; *) echo "?$_o" ;; esac
}
sel_is() { [ "$(sel_now "$1")" = "$2" ]; }
pid_of() {
    local _p
    for _p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" in *"$1"*) echo "${_p#/proc/}"; return 0 ;; esac
    done
    return 1
}
count_procs() {
    local _n=0 _p
    for _p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2>/dev/null < "$_p/cmdline")" in *"$1"*) _n=$((_n + 1)) ;; esac
    done
    echo "$_n"
}

section "准备: 临时信任的 https 目标 两个真实 SOCKS5 上游 带 selector 的官方 sing-box"
if ! ip route 2>/dev/null | grep -q '^default'; then
    ip link set lo up 2>/dev/null
    ip link add dummy0 type dummy 2>/dev/null
    ip addr add 10.99.0.2/24 dev dummy0 2>/dev/null
    ip link set dummy0 up 2>/dev/null
    ip route add default via 10.99.0.1 dev dummy0 2>/dev/null
fi
ip route 2>/dev/null | grep -q '^default' || { say "跳过: 没有默认路由且无法创建 (sing-box 的 delay 接口需要默认网卡), 请使用 --cap-add NET_ADMIN"; exit 0; }
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=probe.test" -addext "subjectAltName=IP:127.0.0.2" -keyout "$E2E_DIR/k.pem" -out "$E2E_DIR/c.pem" >/dev/null 2>&1 || { say "没有 openssl"; exit 1; }
cat "$E2E_DIR/c.pem" >> "$CA"
HITS=$E2E_DIR/https.hits
: > "$HITS"
for _port in 24031 24032; do
python3 -I -c "
import http.server, socketserver, ssl
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(s):
        H.do_GET(s)
    def do_GET(s):
        open('$HITS', 'a').write('port=$_port peer=%s\n' % s.client_address[0]); s.send_response(204); s.end_headers()
    def log_message(*a): pass
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain('$E2E_DIR/c.pem', '$E2E_DIR/k.pem')
s = S(('127.0.0.2', $_port), H); s.socket = c.wrap_socket(s.socket, server_side=True); s.serve_forever()" &
track $!
done
start_targets 127.0.0.2,24003 || exit 1
sleep 0.5
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
UP_TAG=B start_upstream 31102 permissive uu 127.0.0.92 || exit 1
UP_PID_B=$UP_PID
UP_TAG=C start_upstream 31103 permissive uu 127.0.0.93 || exit 1
UP_PID_C=$UP_PID

# A 已授权自动故障切换 (selector), B 没有授权 (直接走 SOCKS5 出站, 与 v0.8.1 完全相同), C 已授权 (用来证明 Profile 之间互不影响), W 已授权但密码错误
cat > "$ROOT/etc/sing-box/config.json" <<JEOF
{"log":{"level":"warn","timestamp":true},
 "experimental":{"clash_api":{"external_controller":"127.0.0.1:$API_PORT","secret":"$API_SECRET"}},
 "inbounds":[
  {"type":"socks","tag":"in-A","listen":"127.0.0.1","listen_port":30001},
  {"type":"socks","tag":"in-B","listen":"127.0.0.1","listen_port":30002},
  {"type":"socks","tag":"in-C","listen":"127.0.0.1","listen_port":30003},
  {"type":"socks","tag":"in-W","listen":"127.0.0.1","listen_port":30004}],
 "outbounds":[{"type":"direct","tag":"direct"},
  {"type":"socks","tag":"apm-socks-A","server":"127.0.0.1","server_port":31101,"version":"5","username":"uu","password":"$UPPASS"},
  {"type":"selector","tag":"apm-sel-A","outbounds":["apm-socks-A","direct"],"default":"apm-socks-A","interrupt_exist_connections":false},
  {"type":"socks","tag":"apm-socks-B","server":"127.0.0.1","server_port":31102,"version":"5","username":"uu","password":"$UPPASS"},
  {"type":"socks","tag":"apm-socks-C","server":"127.0.0.1","server_port":31103,"version":"5","username":"uu","password":"$UPPASS"},
  {"type":"selector","tag":"apm-sel-C","outbounds":["apm-socks-C","direct"],"default":"apm-socks-C","interrupt_exist_connections":false},
  {"type":"socks","tag":"apm-socks-W","server":"127.0.0.1","server_port":31101,"version":"5","username":"uu","password":"WrongPwNotSecret"},
  {"type":"selector","tag":"apm-sel-W","outbounds":["apm-socks-W","direct"],"default":"apm-socks-W","interrupt_exist_connections":false}],
 "route":{"rules":[
  {"inbound":["in-A"],"action":"route","outbound":"apm-sel-A"},
  {"inbound":["in-B"],"action":"route","outbound":"apm-socks-B"},
  {"inbound":["in-C"],"action":"route","outbound":"apm-sel-C"},
  {"inbound":["in-W"],"action":"route","outbound":"apm-sel-W"}]}}
JEOF
printf 'A on 1 fo\nB on 1\nC on 1 fo\nW on 1 fo\n' > "$SBDIR/profiles"
printf 'https://127.0.0.2:24031/\nhttps://127.0.0.2:24032/\n' > "$SBDIR/probe_url"
chmod 644 "$SBDIR/profiles" "$SBDIR/probe_url"
# FO_WRAP 可以把 sing-box 与监控放进限额 cgroup 里运行 (64 MiB 验收), 默认不用
# shellcheck disable=SC2086
${FO_WRAP:-} "$SB_BIN" run -c "$ROOT/etc/sing-box/config.json" > "$E2E_DIR/sb.out" 2>&1 &
SB_PID=$!
track "$SB_PID"
wait_tcp 127.0.0.1 30001 || { say "sing-box 没有启动"; cat "$E2E_DIR/sb.out"; exit 1; }
# shellcheck disable=SC2086
${FO_WRAP:-} sh "$APM_HOME/lib/sbhealth-daemon.sh" > "$E2E_DIR/mon.out" 2>&1 &
MON_PID=$!
wait_file "$SBDIR/connected" 100 || { say "监控没有订阅成功"; cat "$E2E_DIR/mon.out"; exit 1; }
ok "sing-box 与监控守护进程已启动 并已订阅事件流"
SB_PID0=$SB_PID; MON_PID0=$MON_PID

client() { E2E_CLIENT_PORT=$1 python3 -I "$E2E_HERE/sc.py" tcp 127.0.0.2 "${2:-24003}"; }
peer_of() { tail -1 "$TLOG" | sed -n 's/.*peer=\([0-9.]*\).*/\1/p'; }

section "场景 A 基线: 全部正常时经各自的 SOCKS5, 没有任何 DIRECT"
tclear
r=$(client 30001); case $r in OK:*) ok "经 A 的请求成功" ;; *) bad "A 请求失败: $r" ;; esac
[ "$(peer_of)" = 127.0.0.91 ] && ok "目标看到的是上游 A 的出口地址" || bad "对端不是上游 A: $(peer_of)"
sel_is A socks && ok "A 的 selector 当前是 SOCKS5" || bad "A selector: $(sel_now A)"

section "场景 B 默认关闭: 没有授权的 B 上游断线, 请求失败且绝不 DIRECT"
kill "$UP_PID_B" 2>/dev/null; wait "$UP_PID_B" 2>/dev/null
sleep 0.5
tclear
n=0; while [ "$n" -lt 4 ]; do client 30002 >/dev/null 2>&1; n=$((n + 1)); done
[ "$(thits)" = 0 ] && ok "B 故障时目标零命中 (严格 SOCKS5, 没有回退)" || bad "B 有直连命中: $(cat "$TLOG")"
wait_for st_is B unhealthy && ok "B 被识别为故障" || bad "B 状态 $(stat_of B)"
sel_now B | grep -vq '^?' || ok "B 没有 selector (未授权的配置不含自动切换)"

section "场景 C 授权 Profile 故障: 上游 A 断线, 新连接临时走 DIRECT, 不重启任何进程"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null
sleep 0.5
tclear
n=0; while [ "$n" -lt 5 ] && ! sel_is A direct; do client 30001 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is A direct && ok "确认故障后 A 的 selector 切到 DIRECT" || bad "A 仍是 $(sel_now A), 状态 $(stat_of A) 原因 $(stat_of A reason)"
tclear
r=$(client 30001); case $r in OK:*) ok "DIRECT 期间 A 的新连接可用" ;; *) bad "DIRECT 期间连接失败: $r" ;; esac
[ "$(peer_of)" = 127.0.0.1 ] && ok "目标看到的是 VPS 自己的地址 (真实 DIRECT, 不是只改了界面)" || bad "对端 $(peer_of)"
st_is A unhealthy && ok "健康状态仍是故障" || bad "状态 $(stat_of A)"
[ "$(stat_of A exit)" = direct ] && ok "当前出口记录为 direct" || bad "exit=$(stat_of A exit)"
[ -n "$(hist_of A last_fault)" ] && ok "记录了最近故障时间" || bad "没有最近故障时间"
[ "$(sel_now C)" = socks ] && [ "$(stat_of C exit)" != direct ] && ok "C 不受 A 故障影响 (仍是 SOCKS5)" || bad "C 被影响"
kill -0 "$SB_PID0" 2>/dev/null && kill -0 "$MON_PID0" 2>/dev/null && ok "切换期间 sing-box 与监控进程都没有重启" || bad "进程被重启"

section "场景 D 没有业务流量就不探测: 上游已恢复但没有真实请求"
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
: > "$HITS"
sleep 9
[ ! -s "$HITS" ] && ok "没有真实请求的 9 秒内验证地址零命中 (没有定时探测)" || bad "出现了探测: $(cat "$HITS")"
sel_is A direct && ok "仍在 DIRECT, 等待真实请求" || bad "selector $(sel_now A)"

section "场景 E 真实请求触发恢复验证: 请求本身不被阻塞, 随后自动切回 SOCKS5 且不重启"
tclear
t0=$(date +%s%N)
r=$(client 30001)
t1=$(date +%s%N)
case $r in OK:*) ok "触发请求本身成功 (走 DIRECT)" ;; *) bad "触发请求失败: $r" ;; esac
[ $(( (t1 - t0) / 1000000 )) -lt 3000 ] && ok "触发请求没有被探测阻塞 ($(( (t1 - t0) / 1000000 )) 毫秒)" || bad "触发请求耗时 $(( (t1 - t0) / 1000000 )) 毫秒"
W_MAX=20
n=0; while [ "$n" -lt 20 ] && ! sel_is A socks; do client 30001 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is A socks && ok "恢复验证通过后 selector 自动切回 SOCKS5" || bad "selector $(sel_now A) 状态 $(stat_of A)"
tclear
r=$(client 30001); case $r in OK:*) ok "切回后的新连接成功" ;; *) bad "切回后失败: $r" ;; esac
[ "$(peer_of)" = 127.0.0.91 ] && ok "切回后目标看到的是上游 A 的出口地址" || bad "对端 $(peer_of)"
grep -q 'peer=127.0.0.91' "$HITS" && ok "恢复验证请求确实经过 A 的 SOCKS5 出站 (验证地址看到上游 A 的出口)" || bad "验证请求没有经过 A: $(cat "$HITS")"
grep -q 'peer=127.0.0.1$' "$HITS" && bad "出现了直连的验证请求" || ok "验证请求没有走 DIRECT"
grep -q 'peer=127.0.0.92\|peer=127.0.0.93' "$HITS" && bad "验证请求经过了其他 Profile" || ok "没有检测其他 Profile"
wait_for st_is A healthy && ok "A 恢复为正常" || bad "A 状态 $(stat_of A)"
[ -n "$(hist_of A last_recover)" ] && ok "记录了最近恢复时间" || bad "没有最近恢复时间"
kill -0 "$SB_PID0" 2>/dev/null && kill -0 "$MON_PID0" 2>/dev/null && ok "恢复全程 sing-box 与监控进程都没有重启" || bad "进程被重启"
[ "$(count_procs sbhealth-failover)" = 0 ] && ok "探测结束后没有残留脚本进程" || bad "残留 $(count_procs sbhealth-failover)"

section "场景 F 两个验证地址: 一个不可达另一个正常 / 两个都不可达 / 恢复"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null
sleep 0.5
n=0; while [ "$n" -lt 6 ] && ! sel_is A direct; do client 30001 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is A direct && ok "A 再次故障切到 DIRECT" || bad "A selector $(sel_now A)"
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
# 两个地址都不可达: 继续 DIRECT, 且不新增故障证据
printf 'https://127.0.0.2:24091/\nhttps://127.0.0.2:24092/\n' > "$SBDIR/probe_url"
lf=$(stat_of A last_fail)
n=0; while [ "$n" -lt 25 ]; do client 30001 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is A direct && ok "两个验证地址都不可达时继续 DIRECT" || bad "selector $(sel_now A)"
[ "$(stat_of A last_fail)" = "$lf" ] && ok "验证未通过没有被记录成新的上游故障" || bad "last_fail 变化 $lf -> $(stat_of A last_fail)"
[ "$(stat_of A reason)" != auth ] || bad "验证失败被当成了认证故障"
# 第一个不可达 第二个正常
printf 'https://127.0.0.2:24091/\nhttps://127.0.0.2:24032/\n' > "$SBDIR/probe_url"
: > "$HITS"
n=0; while [ "$n" -lt 70 ] && ! sel_is A socks; do client 30001 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is A socks && ok "第一个地址不可达而第二个正常时恢复成功 (任意一个通过即可)" || bad "selector $(sel_now A)"
grep -q 'port=24032 peer=127.0.0.91' "$HITS" && ok "通过的是第二个地址且经过 A 的 SOCKS5" || bad "验证命中: $(cat "$HITS")"
# 第一个正常 第二个不可达
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null
sleep 0.5
n=0; while [ "$n" -lt 6 ] && ! sel_is A direct; do client 30001 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
UP_TAG=A start_upstream 31101 permissive uu 127.0.0.91 || exit 1
UP_PID_A=$UP_PID
printf 'https://127.0.0.2:24031/\nhttps://127.0.0.2:24092/\n' > "$SBDIR/probe_url"
n=0; while [ "$n" -lt 70 ] && ! sel_is A socks; do client 30001 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is A socks && ok "第一个地址正常而第二个不可达时恢复成功" || bad "selector $(sel_now A)"

section "场景 G 认证失败: W 密码错误, 切到 DIRECT, 恢复验证不会通过 (不会误切回)"
n=0; while [ "$n" -lt 5 ] && ! sel_is W direct; do client 30004 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is W direct && ok "认证失败确认后 W 切到 DIRECT" || bad "W selector $(sel_now W) 状态 $(stat_of W)"
[ "$(stat_of W reason)" = auth ] && ok "W 的原因是认证失败" || bad "W 原因 $(stat_of W reason)"
printf 'https://127.0.0.2:24031/\nhttps://127.0.0.2:24032/\n' > "$SBDIR/probe_url"
n=0; while [ "$n" -lt 25 ]; do client 30004 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is W direct && st_is W unhealthy && ok "认证仍然失败时探测不会通过, W 保持 DIRECT 且仍是故障" || bad "W selector $(sel_now W) 状态 $(stat_of W)"
sel_is A socks && sel_is C socks && ok "W 的故障与探测不影响 A 和 C" || bad "A/C selector $(sel_now A)/$(sel_now C)"

section "场景 H 并发与资源: 多个并发请求下恢复验证有界, 没有进程风暴"
kill "$UP_PID_C" 2>/dev/null; wait "$UP_PID_C" 2>/dev/null
sleep 0.5
n=0; while [ "$n" -lt 6 ] && ! sel_is C direct; do client 30003 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is C direct && ok "C 故障切到 DIRECT" || bad "C selector $(sel_now C)"
# 验证地址都不可达 (只统计命中本机验证地址的次数不行), 所以让上游保持故障, 观察验证脚本的并发度与启动次数
starts=$E2E_DIR/probe.starts
: > "$starts"
cnt=0
cpids=
n=0
while [ "$n" -lt 40 ]; do
    client 30003 >/dev/null 2>&1 &
    cpids="$cpids $!"
    client 30003 >/dev/null 2>&1 &
    cpids="$cpids $!"
    client 30003 >/dev/null 2>&1 &
    cpids="$cpids $!"
    c=$(count_procs "sbhealth-failover.sh probe apm-socks-C")
    [ "$c" -le 2 ] || cnt=$((cnt + 1))
    sleep 0.2
    n=$((n + 1))
done
# shellcheck disable=SC2086
wait $cpids
[ "$cnt" = 0 ] && ok "120 个并发请求期间同时运行的探测脚本不超过 1 组" || bad "探测脚本并发超限 $cnt 次"
[ "$(count_procs sbhealth-failover)" -le 2 ] && ok "没有进程风暴 (当前脚本进程 $(count_procs sbhealth-failover))" || bad "进程过多 $(count_procs sbhealth-failover)"
sel_is C direct && ok "上游仍故障时保持 DIRECT" || bad "C selector $(sel_now C)"
UP_TAG=C start_upstream 31103 permissive uu 127.0.0.93 || exit 1
UP_PID_C=$UP_PID
n=0; while [ "$n" -lt 80 ] && ! sel_is C socks; do client 30003 >/dev/null 2>&1; sleep 0.6; n=$((n + 1)); done
sel_is C socks && ok "C 恢复后自动切回" || bad "C selector $(sel_now C)"

section "场景 I 取消授权: 正在 DIRECT 时去掉授权, 立刻恢复严格 SOCKS5"
kill "$UP_PID_A" 2>/dev/null; wait "$UP_PID_A" 2>/dev/null
sleep 0.5
n=0; while [ "$n" -lt 6 ] && ! sel_is A direct; do client 30001 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is A direct && ok "A 处于 DIRECT" || bad "A selector $(sel_now A)"
printf 'A on 2\nB on 1\nC on 1 fo\nW on 1 fo\n' > "$SBDIR/profiles"
# 状态机在下一个事件到来时重读 profiles (同一秒内只读一次, 不使用计时器), 所以等过这一秒再发一次请求
sleep 1.3
client 30001 >/dev/null 2>&1
wait_for sel_is A socks && ok "取消授权后 selector 立即恢复 SOCKS5" || bad "A selector $(sel_now A)"
tclear
r=$(client 30001); case $r in OK:*) bad "取消授权且上游故障时连接竟然成功: $r" ;; *) ok "取消授权后上游故障的连接失败 (严格 SOCKS5)" ;; esac
[ "$(thits)" = 0 ] && ok "目标零命中, 没有 DIRECT 泄漏" || bad "目标有命中"

section "场景 J 脱敏与监控进程"
leak=
for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" in *"$API_SECRET"*) leak="$leak ${p#/proc/}" ;; esac
done
[ -z "$leak" ] && ok "密钥没有出现在任何进程的命令行" || bad "密钥出现在命令行: $leak"
grep -l "$UPPASS\|WrongPwNotSecret" "$SBDIR"/*.state "$SBDIR"/profiles "$SBDIR"/probe_url "$HISTDIR"/*.hist >/dev/null 2>&1 && bad "运行目录含密码" || ok "状态与历史文件不含密码"
[ "$(cat "$HISTDIR"/A.hist | grep -c .)" -le 3 ] && ok "历史文件很小 (只有版本 最近故障 最近恢复)" || bad "历史文件过大"
kill -0 "$SB_PID0" 2>/dev/null && kill -0 "$MON_PID0" 2>/dev/null && ok "全程 sing-box 与监控进程 PID 不变" || bad "进程被重启"

section "场景 K 资源: 监控与切换相关进程的常驻内存"
rss_of() { awk '/VmRSS/ { print $2 }' "/proc/$1/status" 2>/dev/null; }
tot=0
for pat in "sbhealth-daemon.sh" "sbhealth.awk" "nc 127.0.0.1 $API_PORT"; do
    for p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" in *"$pat"*) r=$(rss_of "${p#/proc/}"); tot=$((tot + ${r:-0})); say "  $pat pid ${p#/proc/} RSS ${r:-0} KiB" ;; esac
    done
done
[ "$tot" -lt 8192 ] && ok "监控相关常驻进程的 RSS 合计 $tot KiB (小于 8 MiB)" || bad "监控进程 RSS 合计 $tot KiB"
for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" in "$SB_BIN run -c $ROOT/etc/sing-box/config.json"*) say "  sing-box (含 3 个 selector) RSS $(rss_of "${p#/proc/}") KiB" ;; esac
done
hist_bytes=$(cat "$HISTDIR"/*.hist 2>/dev/null | wc -c)
[ "$hist_bytes" -lt 512 ] && ok "最近故障与恢复历史文件合计 $hist_bytes 字节" || bad "历史文件 $hist_bytes 字节"
[ "$(count_procs sbhealth-failover)" = 0 ] && ok "结束时没有残留的切换或探测进程" || bad "残留进程"

section "场景 L 安全降级: 正在 DIRECT 时监控被停止, 必须回到严格 SOCKS5, 不依赖过期状态继续 DIRECT"
kill "$UP_PID_C" 2>/dev/null; wait "$UP_PID_C" 2>/dev/null
sleep 0.5
n=0; while [ "$n" -lt 8 ] && ! sel_is C direct; do client 30003 >/dev/null 2>&1; n=$((n + 1)); sleep 0.3; done
wait_for sel_is C direct && ok "C 再次处于 DIRECT" || bad "C selector $(sel_now C)"
# 与 OpenRC 停止服务一致: 给守护进程主进程发 SIGTERM (带 cgroup 包装时 MON_PID0 是包装脚本, 所以按命令行找主进程)
dpid=
for p in /proc/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" in *cgwrap*) ;; *"lib/sbhealth-daemon.sh"*) dpid="$dpid ${p#/proc/}" ;; esac
done
# shellcheck disable=SC2086
dpid=$(printf '%s\n' $dpid | sort -n | head -n 1)
[ -z "$dpid" ] || kill "$dpid" 2>/dev/null
wait_for sel_is C socks && ok "监控停止后 selector 立即回到 SOCKS5" || bad "C selector $(sel_now C)"
tclear
r=$(client 30003); case $r in OK:*) bad "监控停止且上游故障时连接竟然成功: $r" ;; *) ok "监控停止后上游故障的连接失败 (严格 SOCKS5)" ;; esac
[ "$(thits)" = 0 ] && ok "目标零命中 没有 DIRECT 泄漏" || bad "目标有命中"
[ "$(count_procs sbhealth.awk)" = 0 ] && ok "监控停止后没有残留的状态机进程" || bad "残留状态机进程"
sh "$APM_HOME/lib/sbhealth-daemon.sh" > "$E2E_DIR/mon2.out" 2>&1 &
MON_PID=$!
wait_file "$SBDIR/connected" 100 && ok "监控重新启动并订阅成功" || bad "监控没有重新订阅"
sel_is C socks && ok "监控重启不会把 selector 切回 DIRECT (重启复位)" || bad "C selector $(sel_now C)"
st_is C unhealthy && ok "重启后保留最近一次可靠判断 (故障), 显示层由真实请求更新" || bad "C 状态 $(stat_of C)"

say ""
say "通过 $E2E_PASS 失败 $E2E_FAIL"
[ "$E2E_FAIL" = 0 ]
