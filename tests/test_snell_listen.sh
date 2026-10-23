# shellcheck shell=sh
# Snell 监听的显示: 配置里的 IPv4 IPv6 双栈 多地址 多端口 ::0 写法, 运行时以进程的真实 socket 为准, 停止时明确是配置
# 模拟器按配置生成 /proc/net/tcp 与 tcp6 (IPv6 监听只出现在 tcp6), 与真实 Snell v6 在 HK-IXP2 隔离网络命名空间里的实测一致
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui
PM="$T_ROOT/bin/proxy-manager"

printf '== 配置文字\n'
lt() { _tui_listen_text "$1"; }
assert_eq "单 IPv4" "所有 IPv4 地址，端口 28391" "$(lt '0.0.0.0:28391')"
assert_eq "单 IPv6" "所有 IPv6 地址，端口 28391" "$(lt '[::]:28391')"
assert_eq "官方写法 ::0" "所有 IPv6 地址，端口 28391" "$(lt '::0:28391')"
assert_eq "双栈" "IPv4 + IPv6，端口 20001" "$(lt '0.0.0.0:20001,[::]:20001')"
assert_eq "双栈 顺序反过来" "IPv4 + IPv6，端口 20001" "$(lt '[::]:20001,0.0.0.0:20001')"
assert_eq "双栈 带空格" "IPv4 + IPv6，端口 20001" "$(lt '0.0.0.0:20001, [::]:20001')"
assert_eq "多端口" "所有 IPv4 地址，端口 20001；所有 IPv4 地址，端口 20002" "$(lt '0.0.0.0:20002,0.0.0.0:20001')"
assert_eq "多端口混合" "IPv4 + IPv6，端口 20001；所有 IPv6 地址，端口 20002" "$(lt '0.0.0.0:20001,[::]:20001,[::]:20002')"
assert_eq "指定 IPv4" "指定地址 192.0.2.5，端口 28391" "$(lt '192.0.2.5:28391')"
assert_eq "指定 IPv6" "指定地址 2001:db8::5，端口 28391" "$(lt '[2001:db8::5]:28391')"
assert_eq "回环 IPv4" "仅本机 (IPv4)，端口 28391" "$(lt '127.0.0.1:28391')"
assert_eq "回环 IPv6" "仅本机 (IPv6)，端口 28391" "$(lt '[::1]:28391')"
assert_eq "没有配置" "未配置" "$(lt '')"

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
printf '#!/bin/sh\nexit 1\n' > "$T_TMP/dl-fail"; chmod +x "$T_TMP/dl-fail"

printf '== 双栈运行时\n'
new_s l1
printf 'ListenPskNotSecret0123456789abcdef\n' | "$PM" snell install --listen "0.0.0.0:20001,[::]:20001" --psk-stdin >/dev/null 2>&1
APM_DOWNLOADER=$T_TMP/dl-fail; export APM_DOWNLOADER
assert_contains "模拟器: IPv4 监听在 tcp 表" "$(cat "$A/proc/net/tcp")" ":4E21 "
assert_contains "模拟器: IPv6 监听在 tcp6 表" "$(cat "$A/proc/net/tcp6")" "00000000000000000000000000000000:4E21"
core_discover snell
assert_contains "发现: IPv6 socket" "$CF_LISTEN" "tcp [::]:20001"
assert_contains "发现: IPv4 socket" "$CF_LISTEN" "tcp 0.0.0.0:20001"
menu=$(printf '1\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "Snell 页: 双栈按实际 socket 显示" "$menu" "监听：IPv4 + IPv6，端口 20001（实际）"
assert_not_contains "Snell 页: 不再出现错误拼接" "$menu" "指定 IPv4 地址 0.0.0.0:20001"
assert_not_contains "Snell 页: 端口与配置一致时不提示" "$menu" "与配置不一致"
st=$("$PM" snell status 2>&1)
assert_contains "详情: IPv6 一行说明两者都已监听" "$st" "所有 IPv6 地址 (IPv4 与 IPv6 都已监听)"
assert_contains "详情: IPv4 一行" "$st" "20001 TCP  所有 IPv4 地址"
info=$("$PM" snell export info 2>&1)
assert_contains "连接信息: 双栈端口只写一次" "$info" "监听端口：20001"
assert_not_contains "连接信息: 不重复端口" "$info" "20001, 20001"
assert_eq "Snell 页与详情都没有 stderr" "" "$( { printf '1\n0\n0\n' | ( tui_run ) >/dev/null; "$PM" snell status >/dev/null; } 2>&1)"

printf '== 停止后\n'
"$PM" snell stop >/dev/null 2>&1
menu=$(printf '1\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "停止后: 明确是配置" "$menu" "监听配置：IPv4 + IPv6，端口 20001（服务未运行）"
assert_not_contains "停止后: 不写成实际监听" "$menu" "（实际）"

printf '== 只监听 IPv6 (::0 写法以外的 [::])\n'
new_s l2
printf 'ListenPskNotSecret0123456789abcdef\n' | "$PM" snell install --listen "[::]:20003" --psk-stdin >/dev/null 2>&1
menu=$(printf '1\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "只 IPv6: 实际监听" "$menu" "监听：所有 IPv6 地址，端口 20003（实际）"
assert_eq "只 IPv6: tcp 表里没有该端口" 0 "$(grep -c ':4E23 ' "$A/proc/net/tcp" 2>/dev/null || true)"

printf '== 配置与实际不一致\n'
new_s l3
printf 'ListenPskNotSecret0123456789abcdef\n' | "$PM" snell install --listen "0.0.0.0:20005" --psk-stdin >/dev/null 2>&1
# 运行中的进程仍是旧端口, 配置被外部改成了新端口 (没有重启)
sed -i 's/^listen = .*/listen = 0.0.0.0:20006/' "$A/etc/snell/snell-server.conf"
menu=$(printf '1\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "不一致: 显示实际端口" "$menu" "监听：所有 IPv4 地址，端口 20005（实际）"
assert_contains "不一致: 说明配置不同" "$menu" "与配置不一致，配置为：所有 IPv4 地址，端口 20006"
t_done
