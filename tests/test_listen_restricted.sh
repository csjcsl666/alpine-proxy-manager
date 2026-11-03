# shellcheck shell=sh
# 权限受限环境里的监听检测: root 没有 CAP_SYS_PTRACE 时读不到降权用户进程的 /proc/PID/fd 链接, 归属只能退化为按配置端口匹配 (config-port)
# 起因: v0.9.5 的 TUI Snell 页只接受 pid 归属, config-port 时显示 实际监听没有检测到 而 CLI 能正确识别 (us-n-home 实机复现)
# 这里的模拟器用 fd_denied 旋钮让 readlink 失败, 与真实内核对 fd 链接的拒绝一致, 真实内核版本见 test_listen_realproc.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui
PM="$T_ROOT/bin/proxy-manager"

if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, 运行时用例跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL
PSK=ListenPskNotSecret0123456789abcdef

page() { printf '1\n0\n0\n' | ( tui_run ) 2>&1; }
# Snell 页与 CLI 详情里出现的监听端口集合, 用来比对两处结论
tui_ports() { printf '%s\n' "$1" | sed -n '/实际监听：/,/状态说明\|归属/p' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | sort -un | tr '\n' ' '; }
cli_ports() { printf '%s\n' "$1" | sed -n 's/^ *\([0-9][0-9]*\) \(TCP\|UDP\) .*/\1/p' | sort -un | tr '\n' ' '; }
snell_up() { # 名称 listen
    new_s "$1"
    printf '%s\n' "$PSK" | "$PM" snell install --listen "$2" --psk-stdin >/dev/null 2>&1
}
denied_restart() { touch "$K/fd_denied"; "$PM" snell restart >/dev/null 2>&1; }

printf '== 基线: 进程 socket 可读时归属 pid, 页面不出现归属未确认\n'
snell_up r1 "0.0.0.0:28391"
core_discover snell
assert_eq "基线: 归属 pid" pid "$CF_LISTEN_ATTRIB"
menu=$(page)
assert_contains "基线: 实际监听" "$menu" "TCP  IPv4  0.0.0.0:28391"
assert_contains "基线: 一致" "$menu" "状态说明：实际监听与配置一致"
assert_not_contains "基线: 不出现归属未确认" "$menu" "未确认归属于该进程"

printf '== fd 不可读: config-port 仍显示真实监听 (v0.9.5 误报的场景)\n'
denied_restart
assert_fail "前提: 模拟器里 fd 链接确实不可读" readlink "$A/proc/23755/fd/10"
core_discover snell
assert_eq "降级为 config-port" config-port "$CF_LISTEN_ATTRIB"
assert_contains "发现: 监听来自 /proc/net" "$CF_LISTEN" "tcp 0.0.0.0:28391"
assert_eq "状态仍是 running" running "$CF_STATE"
menu=$(page)
assert_contains "TUI: 实际监听" "$menu" "TCP  IPv4  0.0.0.0:28391"
assert_contains "TUI: 判定一致" "$menu" "状态说明：实际监听与配置一致"
assert_contains "TUI: 注意行写明归属未确认" "$menu" "注意：无法读取服务进程的 socket, 监听按配置端口匹配, 未确认归属于该进程"
assert_eq "TUI: 归属提示只写一次" 1 "$(printf '%s\n' "$menu" | grep -c '未确认归属于该进程')"
assert_not_contains "TUI: 不再报没有检测到" "$menu" "实际监听：没有检测到"
assert_not_contains "TUI: 不再报检测失败" "$menu" "检测失败"
st=$("$PM" snell status 2>&1)
assert_contains "CLI: 同一端口" "$st" "28391 TCP"
assert_contains "CLI: 同样写明归属未确认" "$st" "未确认是该服务的进程占用"
assert_eq "CLI 与 TUI 的端口集合一致" "$(cli_ports "$st")" "$(tui_ports "$menu")"
assert_eq "TUI 与 CLI 都没有 stderr" "" "$( { page >/dev/null; "$PM" snell status >/dev/null; } 2>&1)"

printf '== 多次刷新结论不变\n'
for i in 1 2 3; do
    menu=$(page)
    assert_contains "刷新 $i: 监听" "$menu" "TCP  IPv4  0.0.0.0:28391"
    assert_not_contains "刷新 $i: 无检测失败" "$menu" "检测失败"
done

printf '== fd 不可读且配置端口真的没有监听: 如实报告, 不是检测失败\n'
touch "$K/no_listen"
"$PM" snell restart >/dev/null 2>&1 || true
core_discover snell
assert_eq "降级为 config-port 且没有监听" "" "$CF_LISTEN"
menu=$(page)
assert_contains "没监听: 实际监听没有检测到" "$menu" "没有检测到"
assert_contains "没监听: 指出配置的端口没有在监听" "$menu" "配置的端口 28391 没有在监听"
assert_not_contains "没监听: 不说检测失败" "$menu" "检测失败"
st=$("$PM" snell status 2>&1)
assert_contains "没监听: CLI 也说没有检测到监听端口" "$st" "没有检测到监听端口"
rm -f "$K/no_listen"

printf '== 服务已停止: 不误报运行\n'
"$PM" snell restart >/dev/null 2>&1
"$PM" snell stop >/dev/null 2>&1
menu=$(page)
assert_contains "停止: 实际监听是没有" "$menu" "实际监听：服务已停止，没有监听"
assert_not_contains "停止: 不显示端口行" "$menu" "实际监听：
    TCP"
assert_not_contains "停止: 不出现归属提示" "$menu" "未确认归属于该进程"
st=$("$PM" snell status 2>&1)
assert_contains "停止: CLI 无监听" "$st" "监听：无 (服务没有运行)"

printf '== 配置与实际不一致 (fd 不可读)\n'
snell_up r2 "0.0.0.0:20005"
denied_restart
sed -i 's/^listen = .*/listen = 0.0.0.0:20006/' "$A/etc/snell/snell-server.conf"
menu=$(page)
assert_contains "不一致: 配置的端口没有在监听" "$menu" "配置的端口 20006 没有在监听"
assert_not_contains "不一致: 不会把无关端口当成监听" "$menu" "TCP  IPv4  0.0.0.0:20005"

printf '== IPv4 IPv6 双栈 (fd 不可读)\n'
snell_up r3 "0.0.0.0:20001,[::]:20001"
denied_restart
menu=$(page)
assert_contains "双栈: IPv4" "$menu" "TCP  IPv4  0.0.0.0:20001"
assert_contains "双栈: IPv6" "$menu" "TCP  IPv6  [::]:20001"
assert_contains "双栈: 一致" "$menu" "状态说明：实际监听与配置一致"
assert_not_contains "双栈: 无检测失败" "$menu" "检测失败"
snell_up r4 "[::]:20003"
denied_restart
menu=$(page)
assert_contains "只 IPv6: 实际监听" "$menu" "TCP  IPv6  [::]:20003"
assert_not_contains "只 IPv6: 无检测失败" "$menu" "检测失败"

printf '== UDP 转发临时端口不是监听 (fd 不可读)\n'
snell_up r5 "0.0.0.0:28391"
echo 49549 > "$K/relay_udp6"
denied_restart
assert_contains "前提: 临时 socket 在 udp6 表" "$(cat "$A/proc/net/udp6")" ":C18D "
core_discover snell
assert_eq "降级为 config-port" config-port "$CF_LISTEN_ATTRIB"
assert_not_contains "临时 UDP 不在监听里" "$CF_LISTEN" "49549"
menu=$(page)
assert_not_contains "TUI 不把临时端口当监听" "$menu" "49549"
assert_contains "TUI 仍显示配置的 TCP 监听" "$menu" "TCP  IPv4  0.0.0.0:28391"
assert_not_contains "TUI 不因临时端口报配置异常" "$menu" "配置异常"
assert_not_contains "CLI 不把临时端口当监听" "$("$PM" snell status 2>&1)" "49549"
echo 28391 > "$K/listen_udp"
"$PM" snell restart >/dev/null 2>&1
menu=$(page)
assert_contains "配置端口上的 UDP 仍是监听" "$menu" "UDP  IPv4  0.0.0.0:28391"
assert_not_contains "配置端口上的 UDP: 临时端口仍不算" "$menu" "49549"

printf '== sing-box: 同一类缺陷 (v0.9.5 没有 config-port 降级, 实例显示没有监听且安装验证失败)\n'
new_s b1
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20902 >/dev/null 2>&1
core_discover singbox
assert_eq "sing-box 基线: pid" pid "$CF_LISTEN_ATTRIB"
touch "$K/fd_denied"
"$PM" sing-box restart >/dev/null 2>&1
core_discover singbox
assert_eq "sing-box fd 不可读: 降级为 config-port" config-port "$CF_LISTEN_ATTRIB"
assert_contains "sing-box: AnyTLS 的 TCP 端口" "$CF_LISTEN" "tcp "
assert_contains "sing-box: TUIC 的 UDP 端口" "$CF_LISTEN" "udp "
assert_contains "sing-box: 归属未确认写进说明" "$CF_NOTES" "未确认归属于该进程"
INSTF=$(ls "$A"/etc/alpine-proxy-manager/instances/AnyTLS-01.conf)
TUICF=$(ls "$A"/etc/alpine-proxy-manager/instances/TUIC-01.conf)
assert_contains "sing-box: 实例页是运行中" "$(_tui_inst_state "$INSTF")" "运行中"
assert_contains "sing-box: TUIC 实例页是运行中" "$(_tui_inst_state "$TUICF")" "运行中"
assert_not_contains "sing-box: 不再显示没有监听" "$(_tui_inst_state "$INSTF")" "没有监听"
APM_SB_WAIT=1
export APM_SB_WAIT
_sb_wait_healthy
assert_eq "sing-box: 健康检查通过" 0 "$?"
OUT=$("$PM" sing-box show AnyTLS-01 2>&1)
assert_contains "sing-box: CLI 内部 Listener 正常" "$OUT" "内部 TCP Listener：正常"
assert_eq "sing-box: 受限环境下新增实例不被验证拒绝" 0 "$("$PM" sing-box add anytls --port 20444 >/dev/null 2>&1; echo $?)"

printf '== sing-box: 端口真的没有监听时仍如实报告\n'
touch "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1 || true
core_discover singbox
assert_eq "sing-box: 没有监听信息" "" "$CF_LISTEN"
assert_contains "sing-box: 实例页没有监听" "$(_tui_inst_state "$INSTF")" "没有监听"
assert_fail "sing-box: 健康检查失败" _sb_wait_healthy
rm -f "$K/no_listen-sing-box"

printf '== sing-box: 没有 Manager 实例 (外部部署) 无从知道端口, 保持没有监听信息\n'
new_s b2
"$PM" sing-box install >/dev/null 2>&1
touch "$K/fd_denied"
"$PM" sing-box restart >/dev/null 2>&1
core_discover singbox
assert_eq "无实例: 不猜测端口" none "$CF_LISTEN_ATTRIB"
assert_eq "无实例: 没有监听信息" "" "$CF_LISTEN"
t_done
