#!/bin/sh
# Snell 目标访问限制 (受限链式代理) 端到端测试
# 真实 Snell v6 加官方 sing-box 1.14.x 的 Snell 客户端, 真实 OpenRC 与 supervise-daemon
# 前提: Snell 已由 proxy-manager 安装并在运行 (端口 SNELL_PORT, PSK E2E_PSK), apm 已在 PATH
#   APM_SNN_URL APM_SNN_SHA256 指向本地提供的 graftcp, SB_BIN 是官方 sing-box
#   /etc/hosts 里有 t1.apm-lab.example 与 t2.apm-lab.example 的测试映射 (由本脚本写入)
# 每个拒绝用例都检查目标的连接记录为零, 不只看客户端错误

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

section "准备: 受控目标 (含通配地址服务, 即原先 127.0.0.53 绕过漏洞的复现条件)"
# 通配地址 0.0.0.0 的服务同时在所有 127.x 地址上可达, 包括 127.0.0.53 与 127.0.0.1
start_targets 0.0.0.0,24001 0.0.0.0,53 127.0.0.3,24010 127.0.0.3,24011 127.0.0.4,24010 127.0.0.4,24011 127.0.0.5,24010 ::1,24012 || exit 1
hosts_drop 'apm-lab\.example'
printf '127.0.0.3 t1.apm-lab.example\n' >> /etc/hosts

section "启用目标访问限制 (空名单)"
pm access enable --yes >"$E2E_DIR/enable.out" 2>&1 || { cat "$E2E_DIR/enable.out"; bad "启用失败"; e2e_finish; exit 1; }
settle 3
if [ "$(pcount tinyproxy)" -ge 1 ]; then ok "内部网关在运行"; else bad "内部网关没有运行"; fi
if [ "$(pcount graftcp)" -eq 1 ]; then ok "graftcp 在运行"; else bad "graftcp 数量不是 1"; ps | grep -E 'graftcp|tinyproxy|snell|run.sh' | grep -v grep; fi
"$PM" snell access show | grep -q '空' && ok "显示名单为空" || bad "show 没有显示空名单"
start_client || exit 1

section "空名单: 所有 TCP 与 UDP 目标都被拒绝, 目标零命中"
for a in 127.0.0.1 127.0.0.2 127.0.0.53 0.0.0.0 ::1; do
    expect_denied "空名单 TCP $a:24001" tcp "$a" 24001
    expect_denied "空名单 UDP $a:24001" udp "$a" 24001
done
expect_denied "空名单 TCP 127.0.0.53:53 (DNS 地址上的通配服务)" tcp 127.0.0.53 53
expect_denied "空名单 UDP 127.0.0.53:53 (DNS 地址上的通配服务)" udp 127.0.0.53 53
expect_denied "空名单 TCP 127.0.0.1:1082 (内部网关)" tcp 127.0.0.1 1082
expect_denied "空名单 TCP 127.0.0.3:24010 (有服务但未列入)" tcp 127.0.0.3 24010

section "精确 地址:端口"
pm access add 127.0.0.3 24010 || bad "add 127.0.0.3 24010 失败"
settle 3
expect_peer "允许 127.0.0.3:24010" tcp 127.0.0.3 24010 127.0.0.1
expect_denied "同地址其他端口 127.0.0.3:24011" tcp 127.0.0.3 24011
expect_denied "其他地址同端口 127.0.0.4:24010" tcp 127.0.0.4 24010
expect_denied "UDP 业务一律拒绝 127.0.0.3:24010" udp 127.0.0.3 24010
expect_denied "通配服务 127.0.0.1:24001" tcp 127.0.0.1 24001
expect_denied "通配服务 127.0.0.53:24001" tcp 127.0.0.53 24001
expect_denied "UDP 通配服务 127.0.0.53:24001" udp 127.0.0.53 24001

pm access add 127.0.0.4 24011 || bad "add 127.0.0.4 24011 失败"
settle 3
expect_peer "多条规则 A 127.0.0.3:24010" tcp 127.0.0.3 24010 127.0.0.1
expect_peer "多条规则 B 127.0.0.4:24011" tcp 127.0.0.4 24011 127.0.0.1
expect_denied "交叉 A 地址 B 端口 127.0.0.3:24011" tcp 127.0.0.3 24011
expect_denied "交叉 B 地址 A 端口 127.0.0.4:24010" tcp 127.0.0.4 24010

section "IPv6 回环"
pm access add ::1 24012 || bad "add ::1 24012 失败"
settle 3
expect_peer "允许 [::1]:24012" tcp ::1 24012 '::1'
expect_denied "IPv6 目标未列入的端口 [::1]:24001" tcp ::1 24001

section "网关自身地址不能加入名单, 也不能访问"
if pm access add 127.0.0.1 1082; then bad "网关地址被加入了名单"; else ok "拒绝把网关地址加入名单"; fi
expect_denied "网关端口 127.0.0.1:1082" tcp 127.0.0.1 1082

section "域名条目: 固定解析加手动刷新"
pm access add t1.apm-lab.example 24010 || bad "add 域名 失败"
settle 3
expect_peer "域名 t1 (解析到 127.0.0.3)" tcp t1.apm-lab.example 24010 127.0.0.1
expect_denied "域名 t1 其他端口" tcp t1.apm-lab.example 24011
# 系统解析改变, 但没有刷新: 仍使用启动时固定的地址
# 原地改写 (inode 不变), 模拟管理员编辑; Snell 的私有视图不受影响
sed 's/^127.0.0.3 t1.apm-lab.example/127.0.0.4 t1.apm-lab.example/' /etc/hosts > "$E2E_DIR/hosts.new"
cat "$E2E_DIR/hosts.new" > /etc/hosts
expect_peer "解析变化但未刷新: 仍是 127.0.0.3" tcp t1.apm-lab.example 24010 127.0.0.1
grep -q 'to=127.0.0.3:24010' "$TLOG" && ok "命中的是固定的旧地址" || bad "没有命中固定的旧地址: $(cat "$TLOG")"
pm access refresh || bad "refresh 失败"
settle 3
expect_peer "刷新后 t1 解析到 127.0.0.4" tcp t1.apm-lab.example 24010 127.0.0.1
grep -q 'to=127.0.0.4:24010' "$TLOG" && ok "刷新后命中新地址" || bad "刷新后没有命中新地址: $(cat "$TLOG")"
expect_denied "未列入的域名" tcp t2.apm-lab.example 24010
# 宿主原子替换 /etc/hosts (sed -i, DHCP 客户端等): Linux 会卸掉其他命名空间里叠在旧文件上的挂载,
# Snell 回到看真实的 hosts, 此时解析结果与固定的放行地址不一致, 必须是拒绝而不是放行
# 容器里 /etc/hosts 是 bind mount 不能被原子替换, 这一项只在能替换时进行
sed 's/^127.0.0.4 t1.apm-lab.example/127.0.0.5 t1.apm-lab.example/' /etc/hosts > "$E2E_DIR/hosts.atomic"
if mv "$E2E_DIR/hosts.atomic" /etc/hosts 2>/dev/null; then
    expect_denied "宿主原子替换 hosts 后解析与固定地址不一致: 拒绝 (fail-closed)" tcp t1.apm-lab.example 24010
else
    say "  跳过: 本环境的 /etc/hosts 不能被原子替换"
    printf '127.0.0.5 t1.apm-lab.example\n' >> /etc/hosts
    hosts_drop '^127.0.0.4 t1.apm-lab.example'
fi
pm access refresh || bad "refresh 失败"
settle 3
expect_peer "刷新后恢复 (t1 解析到 127.0.0.5)" tcp t1.apm-lab.example 24010 127.0.0.1

section "删除与清空"
pm access delete 127.0.0.3 24010 || bad "delete 失败"
settle 3
expect_denied "删除后 127.0.0.3:24010" tcp 127.0.0.3 24010
pm access clear || bad "clear 失败"
settle 3
expect_denied "清空后 127.0.0.4:24011" tcp 127.0.0.4 24011
expect_denied "清空后 [::1]:24012" tcp ::1 24012

section "故障: 任何组件异常都不会回到直连"
pm access add 127.0.0.3 24010; settle 3
expect_peer "故障前正常" tcp 127.0.0.3 24010 127.0.0.1
GW=$(head -n 1 /run/apm-snell/gateway.pid 2>/dev/null)
kill -9 "$GW" 2>/dev/null
F0=$E2E_FAIL
n=0; while [ "$n" -lt 20 ]; do expect_denied "网关被杀后 (第 $n 次探测)" tcp 127.0.0.1 24001 >/dev/null; n=$((n + 1)); sleep 0.3; done
if [ "$E2E_FAIL" -eq "$F0" ]; then ok "网关被杀后 20 次探测目标始终零命中"; else bad "网关被杀后出现了直连"; fi
settle 9
expect_peer "监督进程重启后恢复" tcp 127.0.0.3 24010 127.0.0.1

GC=$(head -n 1 /run/apm-snell/graftcp.pid 2>/dev/null)
SN=$(head -n 1 /run/apm-snell/snell.pid 2>/dev/null)
kill -9 "$GC" 2>/dev/null
sleep 1
if [ -d "/proc/$SN" ]; then bad "graftcp 被杀后 Snell 仍然存活 (孤儿)"; else ok "graftcp 被杀后 Snell 随之终止"; fi
F0=$E2E_FAIL
n=0; while [ "$n" -lt 10 ]; do expect_denied "graftcp 被杀后探测" tcp 127.0.0.1 24001 >/dev/null; n=$((n + 1)); sleep 0.3; done
if [ "$E2E_FAIL" -eq "$F0" ]; then ok "graftcp 被杀后 10 次探测目标始终零命中"; else bad "graftcp 被杀后出现了直连"; fi
settle 9
expect_peer "graftcp 重启后恢复" tcp 127.0.0.3 24010 127.0.0.1

section "OpenRC 生命周期"
rc-service snell stop >/dev/null 2>&1; sleep 2
if [ "$(pcount tinyproxy)$(pcount graftcp)$(pcount snell-server)" = 000 ]; then ok "stop 后没有任何残留进程"; else bad "stop 后有残留进程: tinyproxy=$(pcount tinyproxy) graftcp=$(pcount graftcp) snell=$(pcount snell-server)"; fi
if [ ! -e /run/apm-snell ]; then ok "stop 后运行时目录已清理"; else bad "运行时目录仍存在"; fi
rc-service snell start >/dev/null 2>&1; settle 4
expect_peer "start 后正常" tcp 127.0.0.3 24010 127.0.0.1
rc-service snell restart >/dev/null 2>&1; settle 5
expect_peer "restart 后正常" tcp 127.0.0.3 24010 127.0.0.1
[ "$(pcount tinyproxy)" -ge 1 ] && [ "$(pcount graftcp)" -eq 1 ] && [ "$(pcount snell-server)" -eq 1 ] && ok "restart 后恰好一套进程" || bad "restart 后进程数异常: tinyproxy=$(pcount tinyproxy) graftcp=$(pcount graftcp) snell=$(pcount snell-server)"

section "关闭功能: 回到普通 Snell, 没有辅助进程"
pm access disable || bad "disable 失败"
settle 3
if [ "$(pcount tinyproxy)$(pcount graftcp)" = 00 ]; then ok "关闭后没有 tinyproxy 与 graftcp"; else bad "关闭后仍有辅助进程"; fi
if [ ! -e /run/apm-snell ]; then ok "关闭后运行时目录已清理"; else bad "关闭后运行时目录仍存在"; fi
grep -q '^# apm-net:' /etc/init.d/snell && bad "服务脚本仍含网络功能标记" || ok "服务脚本回到普通启动方式"
expect_peer "普通 Snell 可直连 127.0.0.1:24001" tcp 127.0.0.1 24001 127.0.0.1

e2e_finish
