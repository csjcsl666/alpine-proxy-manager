# shellcheck shell=sh
# Snell 多地址监听 (IPv4 IPv6 双栈) 的完整生命周期: 校验 读取 显示 修改其他字段 改端口 切换监听方式 重启 失败恢复 卸载后重装
# 起因: 真实服务器上 Snell 手工改成 listen = 0.0.0.0:P,[::]:P 后, 要求 Manager 的任何常规操作都不能破坏它
# 所有 PSK 都是虚构值
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui
PM="$T_ROOT/bin/proxy-manager"

printf '== listen 校验\n'
v() { _snell_valid_listen "$1"; }
assert_ok "单 IPv4" v '0.0.0.0:29981'
assert_ok "单 IPv6" v '[::]:29981'
assert_ok "双栈" v '0.0.0.0:29981,[::]:29981'
assert_ok "双栈 顺序反过来" v '[::]:29981,0.0.0.0:29981'
assert_ok "指定 IPv6 地址" v '[2001:db8::1]:29981'
assert_ok "完整 8 组 IPv6" v '[2001:db8:0:0:0:0:0:1]:29981'
assert_ok "内嵌 IPv4 的 IPv6" v '[::ffff:192.0.2.1]:29981'
assert_ok "多端口" v '0.0.0.0:29981,0.0.0.0:29982'
assert_fail "空值" v ''
assert_fail "没有端口" v '[::]'
assert_fail "端口越界" v '[::]:80'
assert_fail "IPv6 不在方括号里" v '::1:29981'
assert_fail "方括号里只有冒号" v '[:]:29981'
assert_fail "方括号里只有点" v '[.]:29981'
assert_fail "IPv6 含非法字符" v '[::g]:29981'
assert_fail "IPv6 两个压缩" v '[1::2::3]:29981'
assert_fail "IPv6 三个冒号" v '[:::1]:29981'
assert_fail "IPv6 组数不够" v '[1:2:3]:29981'
assert_fail "IPv6 组数过多" v '[1:2:3:4:5:6:7:8:9]:29981'
assert_fail "IPv6 组过长" v '[12345::1]:29981'
assert_fail "IPv6 带区域 ID" v '[fe80::1%eth0]:29981'
assert_fail "IPv4 放进方括号" v '[192.0.2.1]:29981'
assert_fail "重复的监听项" v '0.0.0.0:29981,0.0.0.0:29981'
assert_fail "第二项非法时整体拒绝" v '0.0.0.0:29981,[::g]:29981'

printf '== 只改端口: 地址与顺序原样保留\n'
assert_eq "单 IPv4" "0.0.0.0:20001" "$(_snell_listen_with_port '0.0.0.0:29981' 20001)"
assert_eq "双栈" "0.0.0.0:20001,[::]:20001" "$(_snell_listen_with_port '0.0.0.0:29981,[::]:29981' 20001)"
assert_eq "双栈 顺序反过来" "[::]:20001,0.0.0.0:20001" "$(_snell_listen_with_port '[::]:29981,0.0.0.0:29981' 20001)"
assert_eq "带空格的写法被规整为逗号分隔" "0.0.0.0:20001,[::]:20001" "$(_snell_listen_with_port '0.0.0.0:29981, [::]:29981' 20001)"
assert_eq "指定 IPv6 地址" "[2001:db8::1]:20001" "$(_snell_listen_with_port '[2001:db8::1]:29981' 20001)"

printf '== 配置与实际监听的地址级比对\n'
LIVE4='tcp 0.0.0.0:29981 1'
LIVE6='tcp [::]:29981 2'
BOTH=$(printf '%s\n%s' "$LIVE4" "$LIVE6")
miss() { _snell_listen_missing "$1" "$2" | tr '\n' ' ' | sed 's/ $//'; }
assert_eq "双栈都在: 没有缺失" "" "$(miss '0.0.0.0:29981,[::]:29981' "$BOTH")"
assert_eq "双栈只有 IPv4: IPv6 缺失" "[::]:29981" "$(miss '0.0.0.0:29981,[::]:29981' "$LIVE4")"
assert_eq "双栈只有 IPv6 socket: IPv4 监听缺失 (v6only 不能覆盖 IPv4)" "0.0.0.0:29981" "$(miss '0.0.0.0:29981,[::]:29981' "$LIVE6")"
assert_eq "单 IPv4 配置不能由 [::] 覆盖" "0.0.0.0:29981" "$(miss '0.0.0.0:29981' "$LIVE6")"
assert_eq "什么都没有: 两个都缺失" "0.0.0.0:29981 [::]:29981" "$(miss '0.0.0.0:29981,[::]:29981' '')"
assert_eq "单 IPv6 配置而实际只有 IPv4: 缺失" "[::]:29981" "$(miss '[::]:29981' "$LIVE4")"
assert_eq "单 IPv4 正常" "" "$(miss '0.0.0.0:29981' "$LIVE4")"
assert_eq "端口不同算缺失" "0.0.0.0:29982" "$(miss '0.0.0.0:29982' "$LIVE4")"
assert_eq "配置具体 IPv4 地址由通配地址覆盖" "" "$(miss '192.0.2.5:29981' "$LIVE4")"
assert_eq "配置具体 IPv6 地址由 [::] 覆盖" "" "$(miss '[2001:db8::5]:29981' "$LIVE6")"
assert_eq "配置 [::] 不能由具体 IPv6 地址覆盖" "[::]:29981" "$(miss '[::]:29981' 'tcp [2001:db8::5]:29981 3')"
assert_eq "[::0] 写法与 [::] 等价" "" "$(miss '[::0]:29981' "$LIVE6")"
assert_eq "UDP 行不算监听" "[::]:29981" "$(miss '[::]:29981' 'udp [::]:29981 4')"

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

CONF() { printf '%s/etc/snell/snell-server.conf' "$A"; }
LISTEN() { sed -n 's/^listen = //p' "$(CONF)"; }
PSK_A=MultiListenFakePskAAAA0123456789
PSK_B=MultiListenFakePskBBBB0123456789
inst() { printf '%s\n' "$PSK_A" | "$PM" snell install "$@" --psk-stdin >/dev/null 2>&1; }
page() { printf '1\n0\n0\n' | ( tui_run ) 2>&1; }

printf '== 安装的默认监听与明确选择\n'
new_s m0
printf '%s\n' "$PSK_A" | "$PM" snell install --psk-stdin >/dev/null 2>&1
assert_contains "没有 IPv6 时默认: 只监听 IPv4" "$(LISTEN)" "0.0.0.0:"
assert_not_contains "没有 IPv6 时默认: 不含 IPv6" "$(LISTEN)" "["
new_s m0d
printf 'fd42b9964cf21c8c12666aff0e3600 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
printf '%s\n' "$PSK_A" | "$PM" snell install --port 20015 --psk-stdin >/dev/null 2>&1
assert_eq "只有内网 ULA 地址时默认仍是 IPv4" "0.0.0.0:20015" "$(LISTEN)"
new_s m0e
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --port 20016 --psk-stdin 2>&1)
assert_eq "有全局 IPv6 时默认: 自动生成双栈" "0.0.0.0:20016,[::]:20016" "$(LISTEN)"
assert_contains "自动双栈: 说明原因与退路" "$out" "只需要 IPv4 请加 --ip-family ipv4"
core_discover snell
assert_contains "自动双栈: IPv4 在监听" "$CF_LISTEN" "tcp 0.0.0.0:20016"
assert_contains "自动双栈: IPv6 在监听" "$CF_LISTEN" "tcp [::]:20016"
assert_contains "自动双栈: 状态页一致" "$(page)" "状态说明：实际监听与配置一致"
new_s m0f
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
printf '%s\n' "$PSK_A" | "$PM" snell install --port 20017 --ip-family ipv4 --psk-stdin >/dev/null 2>&1
assert_eq "有 IPv6 时 ipv4 明确选择仍然只监听 IPv4" "0.0.0.0:20017" "$(LISTEN)"
new_s m0g
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
printf '%s\n' "$PSK_A" | "$PM" snell install --listen "0.0.0.0:20018" --psk-stdin >/dev/null 2>&1
assert_eq "明确给了 listen 时不自动加 IPv6" "0.0.0.0:20018" "$(LISTEN)"
new_s m0a
before=$(snap)
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --port 20011 --ip-family dual --psk-stdin 2>&1); rc=$?
assert_eq "没有 IPv6 时 dual 被拒绝" 1 "$rc"
assert_contains "没有 IPv6: 说明原因" "$out" "未检测到可用的全局 IPv6 地址"
assert_eq "没有 IPv6: 不留任何文件" "$before" "$(snap)"
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --port 20011 --ip-family ipv6 --psk-stdin 2>&1); rc=$?
assert_eq "没有 IPv6 时 ipv6 被拒绝" 1 "$rc"
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --port 20011 --ip-family dual --psk-stdin 2>&1); rc=$?
assert_eq "有全局 IPv6 时 dual 成功" 0 "$rc"
assert_eq "dual: 配置是官方双栈写法" "0.0.0.0:20011,[::]:20011" "$(LISTEN)"
assert_contains "dual: 提示本机监听不等于公网可达" "$out" "公网 IPv6 能否到达"
new_s m0b
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
inst --port 20012 --ip-family ipv6
assert_eq "ipv6: 只监听 IPv6" "[::]:20012" "$(LISTEN)"
new_s m0c
printf 'fe80000000000000000000000000001 02 40 20 80 eth0\n' > "$A/proc/net/if_inet6"
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --port 20013 --ip-family dual --psk-stdin 2>&1); rc=$?
assert_eq "只有链路本地地址不算可用 IPv6" 1 "$rc"
assert_rc "ip-family 取值无效" 2 "$PM" snell install --ip-family ipv5
assert_rc "ip-family 与 listen 互斥" 2 "$PM" snell install --ip-family dual --listen 0.0.0.0:20014
assert_rc "listen 里的 IPv6 非法被拒绝" 2 "$PM" snell install --listen '[::g]:20014'

printf '== 读取与显示 (模拟生产服务器当前的双栈配置)\n'
new_s m1
inst --listen "0.0.0.0:20001,[::]:20001"
assert_eq "双栈安装后配置原样" "0.0.0.0:20001,[::]:20001" "$(LISTEN)"
core_discover snell
assert_eq "读取: 配置监听" "0.0.0.0:20001,[::]:20001" "$CF_SNELL_LISTEN"
menu=$(page)
assert_contains "页面: 配置 IPv4" "$menu" "TCP  IPv4  0.0.0.0:20001"
assert_contains "页面: 配置 IPv6" "$menu" "TCP  IPv6  [::]:20001"
assert_contains "页面: 一致" "$menu" "状态说明：实际监听与配置一致"
assert_not_contains "页面: 一致时没有异常" "$menu" "监听缺失"

printf '== 修改其他字段不丢监听\n'
printf 'dns-ip-preference = ipv4-first\n' >> "$(CONF)"
cp "$(CONF)" "$T_TMP/m1.before"
printf '%s\n' "$PSK_B" | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "改 PSK: 监听不变" "0.0.0.0:20001,[::]:20001" "$(LISTEN)"
assert_contains "改 PSK: PSK 确实变了" "$(cat "$(CONF)")" "psk = $PSK_B"
assert_contains "改 PSK: 未知字段保留" "$(cat "$(CONF)")" "dns-ip-preference = ipv4-first"
"$PM" snell config set psk --generate >/dev/null 2>&1
assert_eq "自动生成 PSK: 监听不变" "0.0.0.0:20001,[::]:20001" "$(LISTEN)"
assert_contains "自动生成 PSK: 未知字段保留" "$(cat "$(CONF)")" "dns-ip-preference = ipv4-first"
"$PM" snell config set mode default >/dev/null 2>&1
assert_eq "改 mode: 监听不变" "0.0.0.0:20001,[::]:20001" "$(LISTEN)"
assert_contains "改 mode: 未知字段保留" "$(cat "$(CONF)")" "dns-ip-preference = ipv4-first"
assert_eq "改 mode: 文件只多出备份, 行数不变" "$(wc -l < "$T_TMP/m1.before" | tr -d ' ')" "$(wc -l < "$(CONF)" | tr -d ' ')"
assert_eq "改 PSK 后权限不变" "640" "$(stat -c %a "$(CONF)")"
core_discover snell
assert_contains "改完后实际监听仍是双栈 IPv4" "$CF_LISTEN" "tcp 0.0.0.0:20001"
assert_contains "改完后实际监听仍是双栈 IPv6" "$CF_LISTEN" "tcp [::]:20001"
menu=$(page)
assert_contains "改完后页面仍一致" "$menu" "状态说明：实际监听与配置一致"

printf '== 取消与查看不改配置\n'
cp "$(CONF)" "$T_TMP/m1.keep"
"$PM" snell config show >/dev/null 2>&1
assert_eq "查看配置不改文件" "" "$(cmp "$(CONF)" "$T_TMP/m1.keep" 2>&1)"
out=$(printf '1\n3\n\n0\n0\n0\n' | ( tui_run ) 2>&1)
assert_eq "TUI 打开修改配置菜单再取消不改文件" "" "$(cmp "$(CONF)" "$T_TMP/m1.keep" 2>&1)"

printf '== 非法 listen 被拒绝且不写入\n'
cp "$(CONF)" "$T_TMP/m1.keep"
assert_rc "listen 非法 IPv6" 2 "$PM" snell config set listen '[::g]:20001'
assert_rc "listen 方括号里只有冒号" 2 "$PM" snell config set listen '[:]:20001'
assert_rc "listen 缺端口" 2 "$PM" snell config set listen '0.0.0.0'
assert_rc "port 非法" 2 "$PM" snell config set port 80
assert_rc "family 非法" 2 "$PM" snell config set family ipv5
assert_eq "拒绝之后配置未动" "" "$(cmp "$(CONF)" "$T_TMP/m1.keep" 2>&1)"

printf '== 改端口: 所有地址同步更新\n'
out=$("$PM" snell config set port 20021 2>&1); rc=$?
assert_eq "改端口成功" 0 "$rc"
assert_eq "改端口: 两个地址一起变, 顺序不变" "0.0.0.0:20021,[::]:20021" "$(LISTEN)"
assert_contains "改端口: 提示 IPv6 只是本机监听" "$out" "公网 IPv6 能否到达"
assert_contains "改端口: 未知字段保留" "$(cat "$(CONF)")" "dns-ip-preference = ipv4-first"
core_discover snell
assert_contains "改端口后: 实际 IPv4" "$CF_LISTEN" "tcp 0.0.0.0:20021"
assert_contains "改端口后: 实际 IPv6" "$CF_LISTEN" "tcp [::]:20021"
assert_not_contains "改端口后: 旧端口不再监听" "$CF_LISTEN" ":20001"
assert_contains "改端口后: 页面一致" "$(page)" "状态说明：实际监听与配置一致"
"$PM" snell config set listen "[::]:20021,0.0.0.0:20021" >/dev/null 2>&1
"$PM" snell config set port 20022 >/dev/null 2>&1
assert_eq "顺序反过来的双栈改端口后顺序保留" "[::]:20022,0.0.0.0:20022" "$(LISTEN)"
"$PM" snell config set listen "0.0.0.0:20022,[::]:20022" >/dev/null 2>&1
assert_eq "改 listen 本身可以整体替换" "0.0.0.0:20022,[::]:20022" "$(LISTEN)"

printf '== 重启后双栈恢复\n'
"$PM" snell stop >/dev/null 2>&1
core_discover snell
assert_eq "停止后没有监听" "" "$CF_LISTEN"
assert_eq "停止后配置仍是双栈" "0.0.0.0:20022,[::]:20022" "$(LISTEN)"
"$PM" snell start >/dev/null 2>&1
core_discover snell
assert_contains "启动后 IPv4 恢复" "$CF_LISTEN" "tcp 0.0.0.0:20022"
assert_contains "启动后 IPv6 恢复" "$CF_LISTEN" "tcp [::]:20022"
"$PM" snell restart >/dev/null 2>&1
core_discover snell
assert_contains "重启后 IPv4" "$CF_LISTEN" "tcp 0.0.0.0:20022"
assert_contains "重启后 IPv6" "$CF_LISTEN" "tcp [::]:20022"

printf '== IPv4 正常而 IPv6 实际没有监听\n'
rm -f "$A/proc/net/tcp6"
core_discover snell
assert_contains "只剩 IPv4 socket" "$CF_LISTEN" "tcp 0.0.0.0:20022"
assert_not_contains "IPv6 socket 没有" "$CF_LISTEN" "[::]"
menu=$(page)
assert_contains "页面: 实际监听仍列出 IPv4" "$menu" "TCP  IPv4  0.0.0.0:20022"
assert_contains "页面: 配置里的 IPv6 照常列出" "$menu" "TCP  IPv6  [::]:20022"
assert_contains "页面: 明确指出 IPv6 监听缺失" "$menu" "IPv6 监听缺失：[::]:20022"
assert_not_contains "页面: 不再写成端口一致" "$menu" "状态说明：实际监听与配置一致"
assert_not_contains "页面: 不再写成地址写法不同" "$menu" "地址范围的写法不同"
assert_not_contains "页面: IPv4 不报缺失" "$menu" "IPv4 监听缺失"
st=$("$PM" snell status 2>&1)
assert_contains "详情: 指出 IPv6 监听缺失" "$st" "IPv6 监听缺失 [::]:20022"
assert_not_contains "详情: IPv4 不报缺失" "$st" "IPv4 监听缺失"
printf '== 配置 IPv4 与 IPv6 都要有但 IPv4 缺失\n'
"$PM" snell restart >/dev/null 2>&1
: > "$K/tcp.rows"
{ printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'; } > "$A/proc/net/tcp"
core_discover snell
assert_not_contains "IPv4 socket 没有" "$CF_LISTEN" "tcp 0.0.0.0:"
menu=$(page)
assert_contains "页面: 指出 IPv4 监听缺失" "$menu" "IPv4 监听缺失：0.0.0.0:20022"

printf '== 新配置起不来时恢复原配置 (双栈不被破坏)\n'
"$PM" snell restart >/dev/null 2>&1
cp "$(CONF)" "$T_TMP/m1.pre"
touch "$K/no_listen"
out=$("$PM" snell config set port 20031 2>&1); rc=$?
assert_eq "新配置不健康时返回非零" 1 "$rc"
assert_contains "说明已恢复旧配置" "$out" "已恢复旧配置"
assert_eq "恢复后的配置与修改前逐字节相同" "" "$(cmp "$(CONF)" "$T_TMP/m1.pre" 2>&1)"
assert_eq "恢复后监听仍是双栈" "0.0.0.0:20022,[::]:20022" "$(LISTEN)"
rm -f "$K/no_listen"
"$PM" snell restart >/dev/null 2>&1
core_discover snell
assert_contains "故障解除后 IPv6 回来" "$CF_LISTEN" "tcp [::]:20022"

printf '== 切换监听方式\n'
new_s m2
inst --port 20041
assert_eq "起点: 只有 IPv4" "0.0.0.0:20041" "$(LISTEN)"
cp "$(CONF)" "$T_TMP/m2.keep"
out=$("$PM" snell config set family dual 2>&1); rc=$?
assert_eq "没有 IPv6 时切 dual 失败" 1 "$rc"
assert_contains "说明没有可用的 IPv6" "$out" "未检测到可用的全局 IPv6 地址"
assert_eq "失败后配置未动" "" "$(cmp "$(CONF)" "$T_TMP/m2.keep" 2>&1)"
printf '20010db8000000000000000000000001 02 40 00 80 eth0\n' > "$A/proc/net/if_inet6"
"$PM" snell config set family dual >/dev/null 2>&1
assert_eq "切 dual" "0.0.0.0:20041,[::]:20041" "$(LISTEN)"
core_discover snell
assert_contains "切 dual 后 IPv6 在监听" "$CF_LISTEN" "tcp [::]:20041"
"$PM" snell config set family ipv6 >/dev/null 2>&1
assert_eq "切 ipv6" "[::]:20041" "$(LISTEN)"
"$PM" snell config set family ipv4 >/dev/null 2>&1
assert_eq "切回 ipv4" "0.0.0.0:20041" "$(LISTEN)"
"$PM" snell config set listen "0.0.0.0:20041,0.0.0.0:20042" >/dev/null 2>&1
out=$("$PM" snell config set family dual 2>&1); rc=$?
assert_eq "含多个端口时不自动生成" 1 "$rc"
assert_contains "多端口: 说明原因" "$out" "多个端口"
assert_eq "多端口: 配置未动" "0.0.0.0:20041,0.0.0.0:20042" "$(LISTEN)"

printf '== 老的 IPv4 单监听配置\n'
new_s m3
inst --listen "0.0.0.0:20051"
assert_contains "页面: IPv4 一致" "$(page)" "状态说明：实际监听与配置一致"
printf '%s\n' "$PSK_B" | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "改 PSK 后仍是 IPv4 单监听" "0.0.0.0:20051" "$(LISTEN)"
"$PM" snell config set port 20052 >/dev/null 2>&1
assert_eq "老配置改端口" "0.0.0.0:20052" "$(LISTEN)"

printf '== 只监听 IPv6 的配置\n'
new_s m4
inst --listen "[::]:20061"
assert_contains "页面: IPv6 一致" "$(page)" "状态说明：实际监听与配置一致"
printf '%s\n' "$PSK_B" | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "改 PSK 后仍是 IPv6 单监听" "[::]:20061" "$(LISTEN)"
"$PM" snell config set port 20062 >/dev/null 2>&1
assert_eq "IPv6 单监听改端口" "[::]:20062" "$(LISTEN)"
rm -f "$A/proc/net/tcp6"
assert_contains "IPv6 单监听整体没起来: 端口没有在监听" "$(page)" "配置的端口 20062 没有在监听"

printf '== 卸载保留配置后重装, 双栈保留\n'
new_s m5
inst --listen "0.0.0.0:20071,[::]:20071"
cp "$(CONF)" "$T_TMP/m5.keep"
"$PM" snell uninstall >/dev/null 2>&1
assert_eq "卸载 (默认) 保留配置" "" "$(cmp "$(CONF)" "$T_TMP/m5.keep" 2>&1)"
out=$(printf '%s\n' "$PSK_A" | "$PM" snell install --psk-stdin 2>&1)
assert_contains "重装沿用保留的配置" "$out" "沿用已保留的配置"
assert_eq "重装后配置逐字节相同" "" "$(cmp "$(CONF)" "$T_TMP/m5.keep" 2>&1)"
core_discover snell
assert_contains "重装后 IPv4 监听" "$CF_LISTEN" "tcp 0.0.0.0:20071"
assert_contains "重装后 IPv6 监听" "$CF_LISTEN" "tcp [::]:20071"

printf '== 不写入真实凭据\n'
assert_eq "测试文件只用虚构 PSK" "0" "$(grep -c -E 'psk *= *[A-Za-z0-9]{32}$' "$0" || true)"
t_done
