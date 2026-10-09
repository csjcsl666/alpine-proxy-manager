#!/bin/sh
# Snell SOCKS5 出口端到端测试
# 真实 Snell v6 加官方 sing-box 1.14.x 的 Snell 客户端, 真实 OpenRC, graftcp 补丁版, unbound
# 流量路径用目标端看到的对端地址证明: 经上游的连接来自 127.0.0.77 (上游出站绑定的地址),
# Snell 自己直连会是 127.0.0.1 或目标地址本身
# 前提同 net_access.sh

# shellcheck disable=SC2015,SC2009 # 测试脚本里 A && B || C 用来记录通过或失败
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
trap e2e_cleanup EXIT

PM=${PM:-proxy-manager}
pm() {
    "$PM" snell "$@" >"$E2E_DIR/pm.out" 2>&1
    PM_RC=$?
    [ "$PM_RC" -eq 0 ] || sed "s/^/    | /" "$E2E_DIR/pm.out"
    return "$PM_RC"
}
settle() { sleep "${1:-3}"; [ -z "${CL_PID:-}" ] || restart_client; }
VIA='127\.0\.0\.77'
DECOY=$E2E_DIR/decoy.log

# Snell 先读 /etc/hosts 再查 DNS, 残留的测试映射会掩盖 DNS 路径
sed -i '/apm-lab\.example/d' /etc/hosts

section "准备: 受控目标, 受控 DNS, 诱饵 DNS (系统解析器不应收到任何查询)"
# 通配地址服务: 127.0.0.1 与 127.0.0.53 的任何端口都可达, 是回环绕过的复现条件
start_targets 0.0.0.0,24001 127.0.0.2,24003 ::1,24012 || exit 1
start_dnsd 127.0.0.9 127.0.0.2 || exit 1
rm -f "$DECOY.ready"; : > "$DECOY"
python3 -I "$E2E_HERE/dnsd.py" "$DECOY" 127.0.0.10 127.0.0.2 &
track $!
wait_file "$DECOY.ready" || exit 1
cp /etc/resolv.conf "$E2E_DIR/resolv.conf.orig" 2>/dev/null
printf 'nameserver 127.0.0.10\n' > /etc/resolv.conf

section "配置 SOCKS5 出口 (无认证, 上游 127.0.0.1:1080, DNS 127.0.0.9)"
start_upstream 1080 permissive || exit 1
pm egress set --server 127.0.0.1 --port 1080 --no-auth --dns-server 127.0.0.9 || bad "egress set 失败"
pm egress enable --yes || { bad "启用失败"; e2e_finish; exit 1; }
settle 4
if [ "$(pcount unbound)" -ge 1 ]; then ok "解析器在运行"; else bad "解析器没有运行"; fi
if [ "$(pcount graftcp)" -eq 1 ]; then ok "graftcp 在运行"; else bad "graftcp 数量不是 1"; fi
if [ "$(pcount tinyproxy)" -eq 0 ]; then ok "没有 tinyproxy"; else bad "出口模式不应有 tinyproxy"; fi
"$PM" snell egress show | grep -q '127.0.0.1:1080' && ok "show 显示上游" || bad "show 没有显示上游"
start_client || exit 1

section "TCP UDP 经上游 (对端地址是上游绑定的 127.0.0.77)"
expect_peer "TCP 127.0.0.2:24003 经上游" tcp 127.0.0.2 24003 "$VIA"
expect_peer "UDP 127.0.0.2:24003 经上游" udp 127.0.0.2 24003 "$VIA"

section "回环地址不会被 Snell 直连 (通配服务), 只会交给上游"
expect_peer "127.0.0.1:24001 对端是上游" tcp 127.0.0.1 24001 "$VIA"
expect_peer "127.0.0.53:24001 对端是上游" tcp 127.0.0.53 24001 "$VIA"
expect_peer "UDP 127.0.0.53:24001 对端是上游" udp 127.0.0.53 24001 "$VIA"
expect_peer "UDP 127.0.0.1:24001 对端是上游" udp 127.0.0.1 24001 "$VIA"

section "域名: DNS 经上游, 系统解析器零查询"
tclear
expect_peer "域名 TCP 经上游" tcp t1.apm-lab.example 24003 "$VIA"
if grep -q 'peer=127.0.0.77' "$DLOG"; then ok "DNS 查询经上游到达受控 DNS ($(grep -c . "$DLOG") 条)"; else bad "受控 DNS 没有收到来自上游的查询: $(cat "$DLOG")"; fi
if grep -v 'peer=127.0.0.77' "$DLOG" | grep -q .; then bad "受控 DNS 收到了非上游的查询: $(grep -v 'peer=127.0.0.77' "$DLOG")"; else ok "没有非上游的 DNS 查询"; fi
if [ "$(grep -c . "$DECOY")" -eq 0 ]; then ok "诱饵系统解析器零查询"; else bad "诱饵系统解析器收到查询: $(cat "$DECOY")"; fi
expect_peer "域名 UDP 经上游" udp t1.apm-lab.example 24003 "$VIA"
upstream_hits=$(grep -c '127.0.0.9' "$E2E_DIR/upstream.log" || true)
if [ "${upstream_hits:-0}" -ge 1 ]; then ok "上游日志记录了到 DNS 的连接"; else bad "上游日志里没有 DNS 连接"; fi

section "上游认证"
stop_upstream
start_upstream 1080 permissive egressuser || exit 1
printf '%s\n' "$UPPASS" | pm egress set --server 127.0.0.1 --port 1080 --username egressuser --password-stdin || bad "set 带认证失败"
settle 5
expect_peer "带认证 TCP 经上游" tcp 127.0.0.2 24003 "$VIA"
printf 'WrongPassNotSecret0000\n' | pm egress set --server 127.0.0.1 --port 1080 --username egressuser --password-stdin || bad "set 错误密码失败"
settle 5
F0=$E2E_FAIL
expect_denied "认证错误 TCP (不回退直连)" tcp 127.0.0.2 24003
expect_denied "认证错误 回环 TCP" tcp 127.0.0.1 24001
expect_denied "认证错误 UDP" udp 127.0.0.2 24003
[ "$E2E_FAIL" -eq "$F0" ] && ok "认证错误时全部失败且目标零命中"
printf '%s\n' "$UPPASS" | pm egress set --server 127.0.0.1 --port 1080 --username egressuser --password-stdin || bad "恢复密码失败"
settle 5
expect_peer "恢复密码后正常" tcp 127.0.0.2 24003 "$VIA"

section "上游拒绝回环目标 (模拟远端上游): 目标零命中"
stop_upstream
start_upstream 1080 rejectlocal egressuser || exit 1
for a in 127.0.0.1 127.0.0.53 127.0.0.2; do
    for p in 24001 24003 54; do
        expect_denied "上游拒绝回环 TCP $a:$p" tcp "$a" "$p"
    done
    expect_denied "上游拒绝回环 UDP $a:24001" udp "$a" 24001
done
expect_denied "上游拒绝 IPv6 回环 [::1]:24012" tcp ::1 24012

section "故障: 上游关闭后不回退直连"
stop_upstream
F0=$E2E_FAIL
n=0
while [ "$n" -lt 10 ]; do
    expect_denied "上游关闭 TCP $n" tcp 127.0.0.2 24003 >/dev/null
    expect_denied "上游关闭 UDP $n" udp 127.0.0.2 24003 >/dev/null
    expect_denied "上游关闭 域名 $n" tcp t1.apm-lab.example 24003 >/dev/null
    n=$((n + 1))
done
if [ "$E2E_FAIL" -eq "$F0" ]; then ok "上游关闭时 30 次探测目标始终零命中"; else bad "上游关闭时出现直连"; fi
if [ "$(grep -c . "$DECOY")" -eq 0 ]; then ok "上游关闭时诱饵解析器仍然零查询"; else bad "上游关闭时系统解析器收到查询"; fi
start_upstream 1080 permissive egressuser || exit 1
settle 2
expect_peer "上游恢复后正常" tcp 127.0.0.2 24003 "$VIA"

section "故障: 解析器与 graftcp 异常退出"
HP=$(head -n 1 /run/apm-snell/helper.pid 2>/dev/null)
kill -9 "$HP" 2>/dev/null
F0=$E2E_FAIL
n=0; while [ "$n" -lt 15 ]; do expect_not_direct "解析器被杀后" tcp 127.0.0.1 24001 >/dev/null; n=$((n + 1)); sleep 0.3; done
if [ "$E2E_FAIL" -eq "$F0" ]; then ok "解析器被杀后 15 次探测未出现直连"; else bad "解析器被杀后出现直连"; fi
settle 9
expect_peer "解析器被杀后恢复" tcp 127.0.0.2 24003 "$VIA"
GC=$(head -n 1 /run/apm-snell/graftcp.pid 2>/dev/null)
SN=$(head -n 1 /run/apm-snell/snell.pid 2>/dev/null)
kill -9 "$GC" 2>/dev/null
sleep 1
if [ -d "/proc/$SN" ]; then bad "graftcp 被杀后 Snell 仍然存活 (孤儿)"; else ok "graftcp 被杀后 Snell 随之终止"; fi
F0=$E2E_FAIL
n=0; while [ "$n" -lt 10 ]; do expect_not_direct "graftcp 被杀后" tcp 127.0.0.1 24001 >/dev/null; n=$((n + 1)); sleep 0.3; done
if [ "$E2E_FAIL" -eq "$F0" ]; then ok "graftcp 被杀后 10 次探测未出现直连"; else bad "graftcp 被杀后出现直连"; fi
settle 9
expect_peer "graftcp 被杀后恢复" tcp 127.0.0.2 24003 "$VIA"

section "OpenRC 生命周期"
rc-service snell stop >/dev/null 2>&1; sleep 2
if [ "$(pcount unbound)$(pcount graftcp)$(pcount snell-server)" = 000 ]; then ok "stop 后没有残留进程"; else bad "stop 后有残留进程"; fi
if [ ! -e /run/apm-snell ]; then ok "stop 后运行时目录已清理"; else bad "运行时目录仍存在"; fi
rc-service snell start >/dev/null 2>&1; settle 5
expect_peer "start 后正常" tcp 127.0.0.2 24003 "$VIA"
rc-service snell restart >/dev/null 2>&1; settle 6
expect_peer "restart 后正常" tcp 127.0.0.2 24003 "$VIA"
[ "$(pcount unbound)" -eq 1 ] && [ "$(pcount graftcp)" -eq 1 ] && [ "$(pcount snell-server)" -eq 1 ] && ok "restart 后恰好一套进程" || bad "restart 后进程数异常"

section "关闭功能: 回到普通 Snell"
pm egress disable || bad "disable 失败"
settle 3
if [ "$(pcount unbound)$(pcount graftcp)" = 00 ]; then ok "关闭后没有辅助进程"; else bad "关闭后仍有辅助进程"; fi
if [ ! -e /run/apm-snell ]; then ok "运行时目录已清理"; else bad "运行时目录仍存在"; fi
grep -q '^# apm-net:' /etc/init.d/snell && bad "服务脚本仍含网络功能标记" || ok "服务脚本回到普通启动方式"

cp "$E2E_DIR/resolv.conf.orig" /etc/resolv.conf 2>/dev/null
e2e_finish
