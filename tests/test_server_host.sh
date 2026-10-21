# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016,SC2030,SC2031 # 测试里 A && B || C 用来记录通过或失败
# 服务器公网地址输入 (v0.8.3): Enter 自动获取 / 手动输入 IPv4 IPv6 域名 / Esc 取消, 所有客户端配置入口共用同一个组件
# 公网 IP 查询全部用 APM_DOWNLOADER 的 mock, 不访问真实网络; 真实按键行为用 tmux 验证 (没有 tmux 时这部分跳过)
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_server_host.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL
ESC=$(printf '\033')
INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }

# ---- IP 查询 mock: 按 URL 决定返回什么, 记录每次调用 ----
MOCK=$T_TMP/ipmock
cat > "$MOCK" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case $* in
    *api6.ipify*|*ipv6.icanhazip*) v=6 ;;
    *) v=4 ;;
esac
case ${MOCK_MODE:-ok4} in
    ok4) [ "$v" = 4 ] && printf '%s\n' "${MOCK_V4:-93.184.216.34}" || exit 1 ;;
    ok6) [ "$v" = 6 ] && printf '%s\n' "${MOCK_V6:-2606:2800:220:1:248:1893:25c8:1946}" || exit 1 ;;
    both) [ "$v" = 4 ] && printf '%s\n' "${MOCK_V4:-93.184.216.34}" || printf '%s\n' "${MOCK_V6:-2606:2800:220:1:248:1893:25c8:1946}" ;;
    fail) exit 1 ;;
    text) printf '%s\n' "$MOCK_TEXT" ;;
    slow) exec sleep 30 ;;
esac
EOS
chmod +x "$MOCK"
MOCK_LOG=$T_TMP/ipcalls
export MOCK_LOG
mockenv() { # 模式 [文本] -> 在子 shell 里设置环境
    APM_DOWNLOADER=$MOCK; MOCK_MODE=$1; MOCK_TEXT=${2:-}; APM_IP_TIMEOUT=2
    export APM_DOWNLOADER MOCK_MODE MOCK_TEXT APM_IP_TIMEOUT
}

# ---- 公网 IPv6 校验 ----
for good in 2606:2800:220:1:248:1893:25c8:1946 2a00:1450:4001:81b::200e 2001:4860:4860::8888 3fff::1; do
    assert_ok "公网 IPv6 [$good] 被接受" client_valid_public_ipv6 "$good"
done
for bad in ::1 :: fe80::1 fc00::1 fd12:3456::1 ff02::1 2001:db8::1 2001:0db8:85a3::1 ::ffff:1.2.3.4 1:2:3 notip 192.0.2.1 "" 2606:2800:220:1:248:1893:25c8:1946:1 2606::1::2 g::1; do
    assert_fail "非公网或无效 IPv6 [$bad] 被拒绝" client_valid_public_ipv6 "$bad"
done

# ---- 自动获取: IPv4 优先, 仅 IPv6 可用时返回 IPv6, 全失败返回 1, 垃圾响应不被接受 ----
: > "$MOCK_LOG"
assert_eq "IPv4 可用时返回 IPv4" 93.184.216.34 "$( (mockenv ok4; client_public_ip_auto) )"
assert_eq "两者都可用时保持 IPv4 优先 (不改变原有行为)" 93.184.216.34 "$( (mockenv both; client_public_ip_auto) )"
assert_eq "只有 IPv6 可用时返回 IPv6 而不是无效 IPv4" 2606:2800:220:1:248:1893:25c8:1946 "$( (mockenv ok6; client_public_ip_auto) )"
assert_fail "全部失败返回非零" sh -c ". '$T_ROOT/lib/common.sh'; . '$T_ROOT/lib/environment.sh'; . '$T_ROOT/lib/state.sh'; . '$T_ROOT/lib/core.sh'; . '$T_ROOT/lib/model.sh'; . '$T_ROOT/lib/policy.sh'; . '$T_ROOT/lib/txn.sh'; . '$T_ROOT/lib/report.sh'; . '$T_ROOT/lib/client.sh'; APM_DOWNLOADER='$MOCK' MOCK_MODE=fail APM_IP_TIMEOUT=2 client_public_ip_auto"
for bad in "<html>203.0.113.9</html>" "10.0.0.5" "192.168.1.2" "127.0.0.1" "fe80::1" "::1" "2001:db8::5" "evil;rm -rf /" "300.1.1.1"; do
    r=$( (mockenv text "$bad"; client_public_ip_auto) )
    assert_eq "查询返回 [$bad] 不被当作成功" "" "$r"
done
# 超时不挂起
S0=$(date +%s)
( mockenv slow; APM_IP_TIMEOUT=1; client_public_ip_auto ) >/dev/null 2>&1
S1=$(date +%s)
[ $((S1 - S0)) -le 8 ] && t_pass "查询超时不挂起 (4 个服务各 1 秒内放弃, 实际 $((S1 - S0)) 秒)" || t_fail "查询超时太久 $((S1 - S0)) 秒"
# 下载器参数只读: 只有 -q -T -O - URL
assert_not_contains "查询只发 HTTPS GET, 没有写入类参数" "$(cat "$MOCK_LOG")" "--post"

# ---- tui_ask_server_host 的行为 (非交互按行模式; 真实按键见后面的 tmux 用例) ----
ask() { # 输入 模式 -> 输出 + RESULT 行
    printf '%b' "$1" | ( mockenv "${2:-ok4}" "${3:-}"; tui_ask_server_host; printf 'RESULT rc=%s host=%s\n' "$?" "$TUI_HOST" ) 2>&1
}
out=$(ask '\n')
assert_contains "界面: 标题" "$out" "服务器公网 IP / 域名"
assert_contains "界面: Enter 说明" "$out" "直接按 Enter：自动获取公网 IP"
assert_contains "界面: 手动输入说明" "$out" "输入 IP 或域名：使用自定义地址"
assert_contains "界面: 0 与 Esc 说明" "$out" "输入 0 或按 Esc：取消并返回"
assert_contains "界面: 提示符是请选择" "$out" "请选择："
assert_contains "空输入 Enter: 自动获取成功并显示结果" "$out" "已自动获取服务器公网 IP：93.184.216.34"
assert_contains "空输入 Enter: 返回成功并带回地址" "$out" "RESULT rc=0 host=93.184.216.34"
assert_contains "自动获取提示 NAT 风险与手动输入" "$out" "NAT"
out=$(ask '\n' ok6)
assert_contains "仅 IPv6: 自动获取 IPv6" "$out" "RESULT rc=0 host=2606:2800:220:1:248:1893:25c8:1946"
# 自动获取失败: 清楚提示, 可重试, 可手动输入, 可取消, 不卡死
out=$(ask '\n\n' fail)
assert_contains "自动失败: 提示原因" "$out" "自动获取失败"
assert_contains "自动失败: 说明可重试或手动输入或取消" "$out" "可以再按 Enter 重试，或手动输入 IP 或域名，或输入 0 / 按 Esc 返回"
assert_contains "自动失败后 EOF: 取消而不是死循环" "$out" "RESULT rc=1 host="
out=$(ask "\\n198.51.100.7\\n" fail)
assert_contains "自动失败后手动输入 IPv4" "$out" "RESULT rc=0 host=198.51.100.7"
out=$(ask "\\n${ESC}\\n" fail)
assert_contains "自动失败后 Esc 取消" "$out" "RESULT rc=1 host="
# 失败后重试成功: 第一次查询失败, 改成成功再按 Enter
cat > "$T_TMP/flip" <<'EOS'
#!/bin/sh
n=$(cat "$FLIP_STATE" 2>/dev/null || echo 0)
echo $((n + 1)) > "$FLIP_STATE"
# 前 4 次调用 (IPv4 两个服务 + IPv6 两个服务) 失败, 之后成功
[ "$n" -ge 4 ] || exit 1
case $* in *api6.ipify*|*ipv6.icanhazip*) exit 1 ;; esac
printf '93.184.216.34\n'
EOS
chmod +x "$T_TMP/flip"
rm -f "$T_TMP/flip.state"
out=$(printf '\n\n' | ( APM_DOWNLOADER=$T_TMP/flip FLIP_STATE=$T_TMP/flip.state APM_IP_TIMEOUT=2; export APM_DOWNLOADER FLIP_STATE APM_IP_TIMEOUT; tui_ask_server_host; printf 'RESULT rc=%s host=%s\n' "$?" "$TUI_HOST" ) 2>&1)
assert_contains "自动失败后再按 Enter 重试成功" "$out" "RESULT rc=0 host=93.184.216.34"
# 手动输入: 直接使用填写值, 不再自动获取
: > "$MOCK_LOG"
out=$(ask "203.0.113.50\\n")
assert_contains "手动 IPv4" "$out" "RESULT rc=0 host=203.0.113.50"
assert_eq "手动输入时没有发起任何公网查询" 0 "$(grep -c . "$MOCK_LOG")"
out=$(ask "2001:db8::10\\n")
assert_contains "手动 IPv6" "$out" "RESULT rc=0 host=2001:db8::10"
out=$(ask "[2001:DB8::10]\\n")
assert_contains "手动 IPv6 带方括号与大写规范化" "$out" "RESULT rc=0 host=2001:db8::10"
out=$(ask "Vpn.Example.COM\\n")
assert_contains "手动域名规范化为小写" "$out" "RESULT rc=0 host=vpn.example.com"
out=$(ask "  198.51.100.9  \\n")
assert_contains "首尾空白被去掉" "$out" "RESULT rc=0 host=198.51.100.9"
# 手动输入无效: 说明原因并重新输入, 之后可用有效值或 Esc
for bad in "0.0.0.0" "999.1.1.1" "a b" "bad_host" "::" "[1.2.3.4]" "-x.com" "1.2.3.4.5"; do
    out=$(ask "$bad\\n${ESC}\\n")
    assert_contains "无效输入 [$bad] 被拒绝并提示" "$out" "输入无效："
    assert_contains "无效输入 [$bad] 之后可以 Esc 取消" "$out" "RESULT rc=1 host="
done
out=$(ask "bad_host\\nexample.org\\n")
assert_contains "无效后重新输入有效域名" "$out" "RESULT rc=0 host=example.org"
# 输入 0 并 Enter: 取消 (不查询); 失败后 0 与 Esc 仍能退出
: > "$MOCK_LOG"
out=$(ask "0\\n")
assert_contains "输入 0 回车: 取消" "$out" "RESULT rc=1 host="
assert_contains "输入 0 回车: 有提示" "$out" "已取消"
assert_eq "输入 0 回车没有触发查询" 0 "$(grep -c . "$MOCK_LOG")"
out=$(ask "\\n0\\n" fail)
assert_contains "自动获取失败后输入 0 返回" "$out" "RESULT rc=1 host="
out=$(ask "\\n${ESC}\\n" fail)
assert_contains "自动获取失败后 Esc 返回" "$out" "RESULT rc=1 host="
out=$(ask "00\\n${ESC}\\n")
assert_contains "00 不是取消 而是无效输入" "$out" "输入无效："
out=$(ask "10.0.0.0\\n0\\n")
assert_contains "含 0 的合法输入不被当成取消" "$out" "RESULT rc=0 host=10.0.0.0"
# Esc: 立即取消 (不查询)
: > "$MOCK_LOG"
out=$(ask "${ESC}\\n")
assert_contains "Esc 取消" "$out" "RESULT rc=1 host="
assert_contains "Esc 取消有提示" "$out" "已取消"
assert_eq "Esc 取消没有触发查询" 0 "$(grep -c . "$MOCK_LOG")"
out=$(ask "")
assert_contains "EOF 取消" "$out" "RESULT rc=1 host="

# ---- 自动获取只读: 组件源码不包含任何网络配置命令 ----
SRC=$(cat "$T_ROOT/lib/client.sh" "$T_ROOT/lib/tui.sh")
for cmd in "ip addr" "ip route" "ip link" "ifconfig" "iptables" "nft " "route add" "resolv.conf"; do
    FN=$(sed -n '/^tui_ask_server_host()/,/^}/p;/^_client_fetch_ip()/,/^}/p;/^client_public_ip_auto()/,/^}/p' "$T_ROOT/lib/tui.sh" "$T_ROOT/lib/client.sh")
    assert_not_contains "地址选择与查询函数不含 [$cmd]" "$FN" "$cmd"
done
[ -n "$SRC" ] && t_pass "已读取源码"

# ---- 全部同类入口都走统一组件 ----
CNT=$(grep -c "tui_ask_server_host" "$T_ROOT/lib/tui.sh")
assert_eq "tui.sh 里除定义外有 2 处调用 (按需询问 与 更改地址)" 3 "$CNT"
assert_not_contains "不再有各自实现的公网 IP 或域名提示" "$(cat "$T_ROOT/lib/tui.sh")" "服务器的公网 IP 或域名（留空取消）"

# ---- 集成: 每个客户端配置入口 (没有保存地址时) ----
new_s h1
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20500 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20700 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20600 >/dev/null 2>&1
# 页面: 实例列表顺序按名称, 取实例编号
I_ANYTLS=1; I_HY2=2; I_SS=3; I_TUIC=4
tx() { # 输入 模式 -> TUI 输出
    printf '%b' "$1" | ( mockenv "${2:-ok4}" "${3:-}"; tui_run ) 2>&1
}
# 查看连接信息 (show): 空输入 Enter 自动获取 -> 端口默认 -> 继续原有操作
rm -f "$(INST AnyTLS-01)".bak
BEFORE=$(cd "$A" && find etc -type f ! -name '*.conf' | sort | tr '\n' ' ')
out=$(tx "2\\n${I_ANYTLS}\\n5\\n1\\n\\n\\n0\\n0\\n0\\n0\\n")
assert_contains "show: 自动获取成功" "$out" "已自动获取服务器公网 IP：93.184.216.34"
assert_contains "show: 继续原有操作显示连接信息" "$out" "协议：AnyTLS"
assert_eq "show: 保存的客户端连接地址" 93.184.216.34 "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_eq "show: 端口默认使用监听端口" 20443 "$(kv_get "$(INST AnyTLS-01)" public.port)"
# 其余入口 (已保存地址后不再询问); 逐个入口在未保存的实例上验证
for spec in "2:Hysteria2-01:show" "2:Hysteria2-01:json-redacted"; do :; done
# 逐入口: 在 4 个全新实例各用一个入口, 每个都先走统一组件
ENTRIES="show|1 secret|2 json|3 json-redacted|4"
i=0
for inst in Hysteria2-01 Shadowsocks-01 TUIC-01; do
    "$PM" sing-box endpoint "$inst" clear >/dev/null 2>&1
done
# Hysteria2: 导出 sing-box JSON (隐藏凭据): 菜单项顺序 1 查看连接信息 2 查看凭据 3 JSON 4 JSON(隐藏) 5 pin 6 url 7 qr
out=$(tx "2\\n${I_HY2}\\n5\\n7\\n1\\n198.51.100.20\\n\\n0\\n0\\n0\\n0\\n0\\n")
assert_contains "json-redacted: 使用统一组件" "$out" "输入 0 或按 Esc：取消并返回"
assert_eq "json-redacted: 手动 IPv4 被保存" 198.51.100.20 "$(kv_get "$(INST Hysteria2-01)" public.host)"
assert_contains "json-redacted: JSON 使用该地址" "$out" '"server": "198.51.100.20"'
# Shadowsocks: 分享 URL, 手动 IPv6
"$PM" sing-box endpoint Shadowsocks-01 clear >/dev/null 2>&1
out=$(tx "2\\n${I_SS}\\n4\\n3\\n2001:db8::77\\n\\n0\\n0\\n0\\n0\\n")
assert_eq "url: 手动 IPv6 以不带方括号的规范形式保存" 2001:db8::77 "$(kv_get "$(INST Shadowsocks-01)" public.host)"
assert_contains "url: 分享 URL 里的 IPv6 带方括号" "$out" "@[2001:db8::77]:20700"
# 域名
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
out=$(tx "2\\n${I_ANYTLS}\\n5\\n2\\nvpn.example.com\\n\\n0\\n0\\n0\\n0\\n")
assert_eq "json: 域名被保存" vpn.example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_contains "json: JSON 使用域名" "$out" '"server": "vpn.example.com"'
# 嵌入证书固定校验 (pin) 入口也走统一组件
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
out=$(tx "2\\n${I_ANYTLS}\\n5\\n7\\n2\\n\\n\\n0\\n0\\n0\\n0\\n0\\n")
assert_contains "json-pin: 使用统一组件并自动获取" "$out" "已自动获取服务器公网 IP：93.184.216.34"
# 二维码入口 (没有 qrencode 时仍先走统一组件)
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
out=$(tx "2\\n${I_ANYTLS}\\n5\\n4\\n198.51.100.30\\n\\n0\\n0\\n0\\n0\\n")
assert_contains "qr: 使用统一组件" "$out" "输入 0 或按 Esc：取消并返回"
assert_eq "qr: 地址被保存" 198.51.100.30 "$(kv_get "$(INST AnyTLS-01)" public.host)"
# Esc 取消: 不保存, 回到上级菜单, 后续菜单仍可用
"$PM" sing-box endpoint TUIC-01 clear >/dev/null 2>&1
out=$(tx "2\\n${I_TUIC}\\n7\\n2\\n${ESC}\\n0\\n0\\n0\\n0\\n")
assert_eq "Esc 取消不保存地址" "" "$(kv_get "$(INST TUIC-01)" public.host)"
assert_contains "Esc 取消有提示" "$out" "已取消"
assert_contains "Esc 之后回到客户端配置菜单 (再次显示菜单项)" "$out" "导出 sing-box JSON"
out=$(tx "2\\n${I_TUIC}\\n7\\n2\\n0\\n0\\n0\\n0\\n0\\n")
assert_eq "输入 0 取消不保存地址" "" "$(kv_get "$(INST TUIC-01)" public.host)"
assert_contains "输入 0 之后回到客户端配置菜单" "$out" "导出 sing-box JSON"
# 更改客户端连接地址: 同一组件, 手动 / 自动 / Esc
out=$(tx "2\\n${I_ANYTLS}\\n5\\n5\\n203.0.113.5\\n\\n0\\n0\\n0\\n0\\n0\\n")
assert_eq "更改地址: 手动" 203.0.113.5 "$(kv_get "$(INST AnyTLS-01)" public.host)"
out=$(tx "2\\n${I_ANYTLS}\\n5\\n5\\n\\n\\n0\\n0\\n0\\n0\\n0\\n")
assert_eq "更改地址: Enter 自动获取" 93.184.216.34 "$(kv_get "$(INST AnyTLS-01)" public.host)"
out=$(tx "2\\n${I_ANYTLS}\\n5\\n5\\n${ESC}\\n0\\n0\\n0\\n0\\n0\\n")
assert_eq "更改地址: Esc 取消保持原值" 93.184.216.34 "$(kv_get "$(INST AnyTLS-01)" public.host)"
# 网络不可用: 自动获取失败不挂起, 随后手动输入
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
S0=$(date +%s)
out=$(tx "2\\n1\\n${I_ANYTLS}\\n5\\n1\\n\\n192.0.2.44\\n\\n\\n0\\n0\\n0\\n0\\n" fail)
S1=$(date +%s)
assert_contains "网络不可用: 提示自动获取失败" "$out" "自动获取失败"
assert_eq "网络不可用后手动输入成功" 192.0.2.44 "$(kv_get "$(INST AnyTLS-01)" public.host)"
[ $((S1 - S0)) -le 10 ] && t_pass "网络不可用时没有长时间等待" || t_fail "等待 $((S1 - S0)) 秒"
# 原有输出格式不变: 已保存地址后的导出不再询问
out=$(tx "2\\n1\\n${I_ANYTLS}\\n5\\n3\\n\\n0\\n0\\n0\\n0\\n")
assert_not_contains "已保存地址后不再询问" "$out" "服务器公网 IP / 域名"

# ---- 真实按键 (tmux): Enter 自动获取 / 输入 / Backspace / Esc / 方向键 ----
if command -v tmux >/dev/null 2>&1; then
    DRV=$T_TMP/drv.sh
    {
        printf 'unset APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_TEST_ZIPS APM_TEST_DL_LOG\nAPM_HOME=%s\nexport APM_HOME\n' "$T_ROOT"
        for _m in common environment state core model policy txn report client snell singbox sbhealth tui; do printf '. "%s/lib/%s.sh"\n' "$T_ROOT" "$_m"; done
        printf 'APM_DOWNLOADER=%s MOCK_MODE=ok4 MOCK_LOG=%s APM_IP_TIMEOUT=2\nexport APM_DOWNLOADER MOCK_MODE MOCK_LOG APM_IP_TIMEOUT\n' "$MOCK" "$T_TMP/ttylog"
        printf 'TUI_ANSI=0\n[ -z "${DRV_TRACE:-}" ] || { exec 2>>"$DRV_TRACE"; set -x; }\ntui_ask_server_host\nprintf "RESULT rc=%%s host=%%s\\n" "$?" "$TUI_HOST"\nstty -a | grep -o -e "-icanon" -e " icanon" | head -1 | sed "s/^/STTY:/"\nprintf "DONE\\n"\nsleep 30\n'
    } > "$DRV"
    tkrun() { # 会话名 按键...: 启动驱动并依次发送按键, 返回屏幕内容
        _s=$1$$
        shift
        tmux kill-session -t "$_s" 2>/dev/null
        tmux new-session -d -s "$_s" -x 100 -y 40 "sh $DRV" || return 1
        # 等提示符出现并留出进入逐键模式的时间, 否则按键会在终端还是行模式时到达
        _w=0
        while [ "$_w" -lt 50 ] && ! tmux capture-pane -p -t "$_s" | grep -q '请选择：'; do sleep 0.1; _w=$((_w + 1)); done
        sleep 0.5
        for _k in "$@"; do
            tmux send-keys -t "$_s" -- "$_k"
            sleep 0.5
        done
        sleep 1.2
        tmux capture-pane -p -t "$_s"
        tmux kill-session -t "$_s" 2>/dev/null
    }
    scr=$(tkrun k1 Enter)
    assert_contains "真实按键: Enter 自动获取" "$scr" "RESULT rc=0 host=93.184.216.34"
    assert_contains "真实按键: 终端状态恢复 (回到规范模式)" "$scr" "STTY: icanon"
    scr=$(tkrun k2 Escape)
    assert_contains "真实按键: 单独的 Esc 立即取消" "$scr" "RESULT rc=1 host="
    assert_contains "真实按键: Esc 后终端状态恢复" "$scr" "STTY: icanon"
    scr=$(tkrun k3 1 9 8 . 5 1 . 1 0 0 . 7 Enter)
    assert_contains "真实按键: 输入 IPv4 后 Enter" "$scr" "RESULT rc=0 host=198.51.100.7"
    scr=$(tkrun k4 a b c BSpace BSpace BSpace e x . o r g Enter)
    assert_contains "真实按键: Backspace 编辑" "$scr" "RESULT rc=0 host=ex.org"
    scr=$(tkrun k5 Up Down Left Right e x . o r g Enter)
    assert_contains "真实按键: 方向键被忽略, 不当成 Esc 也不混进输入" "$scr" "RESULT rc=0 host=ex.org"
    scr=$(tkrun k6 e x Escape)
    assert_contains "真实按键: 输入一半按 Esc 同样取消" "$scr" "RESULT rc=1 host="
    scr=$(tkrun k7 b a d _ h Enter Escape)
    assert_contains "真实按键: 无效输入后提示并可 Esc" "$scr" "输入无效："
    assert_contains "真实按键: 无效输入后 Esc 取消" "$scr" "RESULT rc=1 host="
    scr=$(tkrun k9 0 Enter)
    assert_contains "真实按键: 输入 0 并 Enter 取消" "$scr" "RESULT rc=1 host="
    scr=$(tkrun k10 0)
    assert_not_contains "真实按键: 只输入 0 不按 Enter 不会返回" "$scr" "RESULT"
    scr=$(tkrun k11 '中' Enter Escape)
    assert_contains "真实按键: 中文输入按无效处理而不是触发自动获取" "$scr" "输入无效："
    assert_not_contains "真实按键: 中文输入不触发查询" "$scr" "正在查询"
    scr=$(tkrun k8 C-d)
    assert_contains "真实按键: 空输入 Ctrl+D 取消" "$scr" "RESULT rc=1 host="
else
    t_skip "没有 tmux, 真实按键用例跳过"
fi

t_done
