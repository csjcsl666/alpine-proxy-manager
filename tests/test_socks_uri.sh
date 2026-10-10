# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败, 单引号里的 $ 是字面量
# 三个 Core 共享的 SOCKS5 链接解析 与 sing-box / Snell 的 TUI 入口: 完整链接 不完整链接 分项输入 非法输入 凭据不泄漏
# 全部使用虚构凭据, AnyTLS Gateway 的入口在 test_anytlsgw.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_socks_uri.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

# ---- 解析器 ----
P() { tui_socks_uri_parse "$1"; }
fields() { printf '%s|%s|%s|%s|%s|%s' "$TUI_SK_HOST" "$TUI_SK_PORT" "$TUI_SK_USER" "$TUI_SK_PASS" "$TUI_SK_HASUSER" "$TUI_SK_HASPASS"; }
ok_case() { # 名称 输入 期望字段
    P "$2"; _rc=$?
    assert_eq "解析 $1 返回 0" 0 "$_rc"
    assert_eq "解析 $1 字段" "$3" "$(fields)"
}
bad_case() { # 名称 输入
    P "$2"; _rc=$?
    assert_eq "拒绝 $1" 1 "$_rc"
    case $TUI_SK_ERR in '') t_fail "拒绝 $1 带原因" ;; *) t_pass "拒绝 $1 带原因" ;; esac
    assert_not_contains "错误原因不含输入 ($1)" "$TUI_SK_ERR" "$2"
}
ok_case "域名带认证" 'socks5://alice:Pw0123@proxy.example.com:1080' 'proxy.example.com|1080|alice|Pw0123|1|1'
ok_case "域名无认证" 'socks5://proxy.example.com:1080' 'proxy.example.com|1080|||0|0'
ok_case "IPv4" 'socks5://alice:Pw0123@192.0.2.10:1080' '192.0.2.10|1080|alice|Pw0123|1|1'
ok_case "IPv6" 'socks5://alice:Pw0123@[2001:db8::1]:1080' '[2001:db8::1]|1080|alice|Pw0123|1|1'
ok_case "IPv6 无认证" 'socks5://[2001:db8::1]:1080' '[2001:db8::1]|1080|||0|0'
ok_case "方案大小写" 'SOCKS5://alice:Pw0123@192.0.2.10:1080' '192.0.2.10|1080|alice|Pw0123|1|1'
ok_case "结尾斜杠" 'socks5://192.0.2.10:1080/' '192.0.2.10|1080|||0|0'
ok_case "百分号编码" 'socks5://al%40ice:p%40ss%3Aw%2Fd%25%20x@192.0.2.10:1080' '192.0.2.10|1080|al@ice|p@ss:w/d% x|1|1'
ok_case "密码里的字面量冒号和特殊字符" 'socks5://alice:a:b!$&*,;=@192.0.2.10:1080' '192.0.2.10|1080|alice|a:b!$&*,;=|1|1'
ok_case "端口 1" 'socks5://192.0.2.10:1' '192.0.2.10|1|||0|0'
ok_case "端口 65535" 'socks5://192.0.2.10:65535' '192.0.2.10|65535|||0|0'
ok_case "缺端口保留主机" 'socks5://proxy.example.com' 'proxy.example.com||||0|0'
ok_case "缺端口保留认证" 'socks5://alice:Pw0123@proxy.example.com' 'proxy.example.com||alice|Pw0123|1|1'
ok_case "只有用户名" 'socks5://alice@192.0.2.10:1080' '192.0.2.10|1080|alice||1|0'
P 'proxy.example.com'; assert_eq "普通域名返回 2" 2 "$?"
P '192.0.2.10'; assert_eq "普通 IPv4 返回 2" 2 "$?"
P '2001:db8::1'; assert_eq "普通 IPv6 返回 2" 2 "$?"
P '[2001:db8::1]'; assert_eq "带方括号的普通 IPv6 返回 2" 2 "$?"
bad_case "错误协议 http" 'http://alice:SecretX@192.0.2.10:1080'
bad_case "错误协议 socks4" 'socks4://192.0.2.10:1080'
bad_case "错误协议 socks5h" 'socks5h://alice:SecretX@192.0.2.10:1080'
bad_case "缺主机" 'socks5://alice:SecretX@:1080'
bad_case "只有协议" 'socks5://'
bad_case "端口 0" 'socks5://alice:SecretX@192.0.2.10:0'
bad_case "端口 65536" 'socks5://alice:SecretX@192.0.2.10:65536'
bad_case "端口非数字" 'socks5://alice:SecretX@192.0.2.10:abc'
bad_case "端口为空" 'socks5://alice:SecretX@192.0.2.10:'
bad_case "IPv6 缺方括号" 'socks5://alice:SecretX@2001:db8::1:1080'
bad_case "IPv6 方括号不闭合" 'socks5://alice:SecretX@[2001:db8::1:1080'
bad_case "IPv6 非法字符" 'socks5://alice:SecretX@[2001:zz::1]:1080'
bad_case "IPv6 空" 'socks5://alice:SecretX@[]:1080'
bad_case "百分号编码不完整" 'socks5://alice:Sec%4@192.0.2.10:1080'
bad_case "百分号编码非十六进制" 'socks5://alice:Sec%zzret@192.0.2.10:1080'
bad_case "百分号解出控制字符" 'socks5://alice:Sec%0aret@192.0.2.10:1080'
bad_case "主机名中的百分号" 'socks5://alice:SecretX@pro%78y.example.com:1080'
bad_case "空用户名" 'socks5://:SecretX@192.0.2.10:1080'
bad_case "空密码" 'socks5://alice:@192.0.2.10:1080'
bad_case "空认证" 'socks5://@192.0.2.10:1080'
bad_case "带路径" 'socks5://alice:SecretX@192.0.2.10:1080/path'
bad_case "带参数" 'socks5://alice:SecretX@192.0.2.10:1080?x=1'
bad_case "带片段" 'socks5://alice:SecretX@192.0.2.10:1080#x'
bad_case "带空白" 'socks5://alice:Secret X@192.0.2.10:1080'
bad_case "无协议的认证写法" 'alice:SecretX@192.0.2.10:1080'
bad_case "主机名非法" 'socks5://alice:SecretX@-bad-.example.com:1080'
bad_case "999 数字串主机" 'socks5://alice:SecretX@999.1.1.1:1080'
bad_case "主机名首尾为点" 'socks5://alice:SecretX@.example.com:1080'
SECRET_SEEN=
for u in 'socks5://alice:SecretX@192.0.2.10:99999' 'http://alice:SecretX@h:1' 'socks5://alice:Sec%zz@h:1' 'socks5://:SecretX@h:1'; do
    P "$u"
    case $TUI_SK_ERR in *SecretX*|*alice*) SECRET_SEEN=yes ;; esac
done
assert_eq "错误提示不含用户名与密码" "" "$SECRET_SEEN"
P 'socks5://alice:SecretX@192.0.2.10:99999'
assert_eq "失败后不保留主机" "" "$TUI_SK_HOST"

# 地址或链接的混合输入提示必须是正常可见输入, 不能使用隐藏输入
TGT_SRC=$(sed -n '/^_tui_socks_target()/,/^}/p' "$T_ROOT/lib/tui.sh")
assert_contains "混合输入提示读取函数存在" "$TGT_SRC" "tui_ask"
assert_not_contains "混合输入提示不使用隐藏输入" "$TGT_SRC" "tui_read_secret"
assert_not_contains "混合输入提示不关闭回显" "$TGT_SRC" "stty"
for p in '上游地址或完整 socks5:// 链接' 'SOCKS5 出口地址或完整 socks5:// 链接' 'SOCKS5 服务器地址或完整 socks5:// 链接'; do
    assert_not_contains "混合输入提示文案不声明不回显: $p" "$(grep -F "$p" "$T_ROOT/lib/tui.sh")" "输入不回显"
done
# ---- sing-box SOCKS Profile: TUI 入口 ----
T() { printf '%b' "$1" | ( _tui_socks_add ) 2>&1; }
SPW='Fict%Pass:01@x'
ready() { new_s "$1"; "$PM" sing-box install >/dev/null 2>&1; }
ready u1
out=$(T 'socks5://alice:Fict%25Pass%3A01%40x@192.0.2.60:1085\nmyprof\n\n')
assert_contains "完整链接直接添加" "$out" "已添加 SOCKS Profile myprof"
assert_contains "完整链接给出识别摘要" "$out" "已识别：主机 192.0.2.60，端口 1085"
assert_eq "链接主机" "192.0.2.60" "$(kv_get "$(PROF myprof)" host)"
assert_eq "链接端口" 1085 "$(kv_get "$(PROF myprof)" port)"
assert_eq "链接用户名" alice "$(kv_get "$(PROF myprof)" username)"
assert_eq "链接密码已解码保存" "$SPW" "$(kv_get "$(PROF myprof)" password)"
assert_not_contains "完整链接不再询问用户名" "$out" "用户名（留空表示无认证）"
assert_not_contains "输出不含密码" "$out" "Fict"
assert_not_contains "输出不含编码后的密码" "$out" "Pass%3A"
assert_eq "Profile 权限 600" 600 "$(stat -c %a "$(PROF myprof)")"
sbleak=$(grep -rlF -- "Fict" "$A" 2>/dev/null | grep -vF "$(PROF myprof)")
assert_eq "密码只出现在 Profile 文件" "" "$sbleak"
out=$(T 'socks5://192.0.2.61:1086\n\n\n')
assert_contains "无认证链接直接添加" "$out" "已添加 SOCKS Profile SOCKS-01"
assert_eq "无认证链接没有用户名" "" "$(kv_get "$(PROF SOCKS-01)" username)"
out=$(T 'socks5://[2001:db8::7]:1087\n\n\n')
assert_contains "IPv6 链接添加" "$out" "已添加 SOCKS Profile SOCKS-02"
assert_eq "IPv6 规范化保存" "[2001:db8::7]" "$(kv_get "$(PROF SOCKS-02)" host)"
out=$(T 'socks5://bob@192.0.2.62:1088\n\nFictBobPw01\n')
assert_contains "只有用户名的链接补问密码" "$out" "密码（输入不回显）"
assert_eq "补问后用户名" bob "$(kv_get "$(PROF SOCKS-03)" username)"
assert_eq "补问后密码" FictBobPw01 "$(kv_get "$(PROF SOCKS-03)" password)"
out=$(T 'socks5://192.0.2.63\n1089\n\n\n')
assert_contains "缺端口的链接补问端口" "$out" "端口："
assert_eq "补问端口生效" 1089 "$(kv_get "$(PROF SOCKS-04)" port)"
assert_eq "补问后保留主机" "192.0.2.63" "$(kv_get "$(PROF SOCKS-04)" host)"
out=$(T 'socks5://carol:FictCarolPw@192.0.2.64\n1090\n\n')
assert_eq "缺端口但带认证: 端口补问" 1090 "$(kv_get "$(PROF SOCKS-05)" port)"
assert_eq "缺端口但带认证: 密码保留" FictCarolPw "$(kv_get "$(PROF SOCKS-05)" password)"
assert_not_contains "缺端口但带认证不再问用户名" "$out" "用户名（留空表示无认证）"
before=$(find "$A/etc/alpine-proxy-manager/socks" -type f | sort | xargs cat | sha256sum)
out=$(T 'http://x:FictBad@192.0.2.65:1080\nsocks5://x:FictBad@192.0.2.65:70000\nsocks5://x:FictBad@[::1:1080\n\n')
assert_contains "非法链接提示" "$out" "错误：不支持的协议"
assert_contains "非法端口提示" "$out" "错误：端口无效"
assert_contains "畸形 IPv6 提示" "$out" "错误：IPv6 地址格式无效"
assert_contains "非法后允许重新输入" "$out" "请重新输入，留空取消"
assert_not_contains "错误不回显链接" "$out" "FictBad"
assert_eq "非法链接后配置不变" "$before" "$(find "$A/etc/alpine-proxy-manager/socks" -type f | sort | xargs cat | sha256sum)"
out=$(T 'http://x:FictBad@192.0.2.65:1080\nsocks5://192.0.2.66:1091\n\n\n')
assert_contains "非法后重新输入有效链接成功" "$out" "已添加 SOCKS Profile SOCKS-06"
n=$(find "$A/etc/alpine-proxy-manager/socks" -type f | wc -l)
out=$(T '\n')
assert_eq "留空取消不创建 Profile" "$n" "$(find "$A/etc/alpine-proxy-manager/socks" -type f | wc -l)"
# 原有分项输入
out=$(T '192.0.2.70\n1095\nplain1\nplainuser\nFictPlainPw01\n')
assert_contains "分项输入仍问端口" "$out" "端口："
assert_eq "分项输入主机" "192.0.2.70" "$(kv_get "$(PROF plain1)" host)"
assert_eq "分项输入端口" 1095 "$(kv_get "$(PROF plain1)" port)"
assert_eq "分项输入密码" FictPlainPw01 "$(kv_get "$(PROF plain1)" password)"
out=$(T '192.0.2.71\n1096\nplain2\n\n')
assert_eq "分项无认证" "" "$(kv_get "$(PROF plain2)" username)"
# 完整链接与分项输入的配置一致
a=$(grep -v '^#' "$(PROF plain1)" | sed 's/^name=.*//' | sort | tr '\n' ' ')
T 'socks5://plainuser:FictPlainPw01@192.0.2.70:1095\nplain1b\n' >/dev/null
b=$(grep -v '^#' "$(PROF plain1b)" | sed 's/^name=.*//' | sort | tr '\n' ' ')
assert_eq "链接与分项输入生成相同配置" "$a" "$b"
# TTY 路径下程序自己不打印密码 (终端回显由用户自己的终端负责)
out=$(printf 'socks5://dave:FictTtyPw@192.0.2.72:1099\nttyprof\n\n' | ( APM_TUI_TEST_TTY=1 _tui_socks_add ) 2>&1)
case $out in *FictTtyPw*) t_fail "TTY 路径程序不打印密码" ;; *) t_pass "TTY 路径程序不打印密码" ;; esac

# ---- Snell SOCKS5 出口: TUI 入口 ----
S() { printf '%b' "$1" | ( tui_snell_egress_menu ) 2>&1; }
new_s s1
printf '%s\n' "SocksUriSnellPskNotSecret0123456" | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
out=$(S '1\nsocks5://erin:FictSnellPw%2101@192.0.2.80:1100\n\n0\n')
EGF=$(grep -rl "FictSnellPw" "$A" 2>/dev/null | head -n1)
assert_eq "Snell 密码只保存在出口配置" 1 "$(grep -rl "FictSnellPw" "$A" 2>/dev/null | wc -l)"
assert_not_contains "Snell 完整链接不泄漏密码" "$out" "FictSnellPw"
assert_eq "Snell 链接主机" 192.0.2.80 "$(kv_get "$EGF" host)"
assert_eq "Snell 链接端口" 1100 "$(kv_get "$EGF" port)"
assert_eq "Snell 链接用户名" erin "$(kv_get "$EGF" username)"
assert_eq "Snell 链接密码已解码" 'FictSnellPw!01' "$(kv_get "$EGF" password)"
assert_eq "Snell 出口配置权限 600" 600 "$(stat -c %a "$EGF")"
assert_not_contains "Snell 完整链接不再问端口" "$out" "上游端口："
out=$(S '1\nsocks5://up.example.test:1101\n\n0\n')
assert_eq "Snell 无认证链接" "" "$(kv_get "$EGF" username)"
assert_eq "Snell 域名上游" up.example.test "$(kv_get "$EGF" host)"
out=$(S '1\nsocks5://up2.example.test\n1102\n\n\n0\n')
assert_contains "Snell 缺端口补问" "$out" "上游端口："
assert_eq "Snell 补问端口" 1102 "$(kv_get "$EGF" port)"
assert_eq "Snell 补问后保留主机" up2.example.test "$(kv_get "$EGF" host)"
out=$(S '1\nup3.example.test\n1103\nfrank\nFictFrankPw\n\n0\n')
assert_contains "Snell 分项输入仍问端口" "$out" "上游端口："
assert_eq "Snell 分项主机" up3.example.test "$(kv_get "$EGF" host)"
assert_eq "Snell 分项密码" FictFrankPw "$(kv_get "$EGF" password)"
sum=$(sha256sum "$EGF")
out=$(S '1\nsocks5://x:FictBadPw@192.0.2.81:99999\nhttp://x:FictBadPw@h:1\n\n0\n')
assert_contains "Snell 非法链接提示" "$out" "错误：端口无效"
assert_not_contains "Snell 错误不回显链接" "$out" "FictBadPw"
assert_eq "Snell 非法链接后配置不变" "$sum" "$(sha256sum "$EGF")"

t_done
