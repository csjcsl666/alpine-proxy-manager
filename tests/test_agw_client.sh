# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# AnyTLS Gateway 客户端配置 (v0.8.3): 每条转发线路一个客户端入口, 事实来自转发线路记录与网关真实证书, 与 sing-box 实例互不引用
# 证书用真实 openssl 生成 (带 SAN 的新证书, 只有 CN 的旧证书, CA 签发的证书); 服务端二进制是 ELF 桩, 真实连接见 tests/e2e/agw_client.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
command -v openssl >/dev/null 2>&1 || { t_skip "没有 openssl, test_agw_client.sh 全部跳过"; t_done; exit $?; }
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_agw_client.sh 全部跳过"
    t_done
    exit $?
fi
ZIPS=$T_TMP/zips
DL=$T_TMP/dl
mkdir -p "$ZIPS"
mk_dl_shim "$DL"
mk_elf_stub "$ZIPS/anytls-socks-gateway-v0.1.0-linux-x86_64" "anytls-socks-gateway v0.1.0"
GW_SHA=$(sha256sum "$ZIPS/anytls-socks-gateway-v0.1.0-linux-x86_64" | awk '{ print $1 }')
SOCKSPW=FakeSocksPassNotSecret0001
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL
ESC=$(printf '\033')

# IP 查询 mock
MOCK=$T_TMP/ipmock
printf '#!/bin/sh\ncase ${MOCK_MODE:-ok} in ok) printf "%%s\\n" "${MOCK_IP:-93.184.216.34}" ;; *) exit 1 ;; esac\n' > "$MOCK"
chmod +x "$MOCK"

new_g() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_sim_system "$A"
    mkdir -p "$A/usr/bin"
    printf '#!/bin/sh\nexec /usr/bin/openssl "$@"\n' > "$A/usr/bin/openssl"
    chmod +x "$A/usr/bin/openssl"
    K=$A/fake-rc
    mkdir -p "$K"
    echo stopped > "$K/state-anytls-socks-gateway"
    : > "$K/dl.log"
    APM_SYSROOT=$A; APM_FAKE_RC_DIR=$K; APM_EUID=0; APM_ARCH=x86_64; APM_DOWNLOADER=$DL
    APM_TEST_ZIPS=$ZIPS; APM_TEST_DL_LOG=$K/dl.log; APM_SNELL_WAIT=1
    APM_AGW_URL=http://example.invalid/anytls-socks-gateway-v0.1.0-linux-x86_64
    APM_AGW_SHA256=$GW_SHA
    export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER APM_TEST_ZIPS APM_TEST_DL_LOG APM_SNELL_WAIT APM_AGW_URL APM_AGW_SHA256
    unset APM_VAR APM_ETC APM_BACKUP_DIR APM_BACKUP_KEEP
}
gw() { "$PM" anytls-gateway "$@"; }
ST() { printf '%s/etc/alpine-proxy-manager/anytlsgw.conf' "$A"; }
EPF() { printf '%s/etc/alpine-proxy-manager/anytlsgw-endpoint-%s.conf' "$A" "$1"; }
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }

new_g g1
printf '%s\n' "$SOCKSPW" | gw install --port 20443 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
printf '%s\n' "$SOCKSPW" | gw listener add --port 20444 --socks-server 192.0.2.11 --socks-port 1081 --socks-username upuser2 --socks-password-stdin >/dev/null 2>&1
PW1=$(kv_get "$(ST)" listener.1.password)
PW2=$(kv_get "$(ST)" listener.2.password)
assert_eq "两条线路的密码不同" yes "$([ -n "$PW1" ] && [ -n "$PW2" ] && [ "$PW1" != "$PW2" ] && echo yes)"
CERT=$A/etc/anytls-socks-gateway/cert.pem
assert_contains "新生成的网关证书带 SAN" "$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>&1)" "DNS:anytls-gateway"

# ---- 没有客户端连接地址: 明确提示, 不输出看似有效的配置 ----
OUT=$(gw client 1 show 2>&1); assert_eq "没有地址时 show 失败" 1 "$?"
assert_contains "提示先设置地址" "$OUT" "anytls-gateway endpoint 1 set"
assert_contains "提示 SOCKS5 上游不是连接入口" "$OUT" "SOCKS5 上游也不是"
OUT=$(gw client 1 sing-box 2>&1); assert_eq "没有地址时 JSON 失败" 1 "$?"
OUT=$(gw client 9 show 2>&1); assert_eq "不存在的线路返回 2" 2 "$?"
OUT=$(gw client 1 bogus 2>&1); assert_eq "未知操作返回 2" 2 "$?"
OUT=$(gw client 2>&1); assert_eq "缺参数返回 2" 2 "$?"
# 凭据不需要地址
OUT=$(gw client 1 secret 2>&1)
assert_contains "凭据: 线路 1 的 AnyTLS 密码" "$OUT" "$PW1"
assert_not_contains "凭据: 不含线路 2 的密码" "$OUT" "$PW2"
assert_not_contains "凭据: 不含 SOCKS5 上游密码" "$OUT" "$SOCKSPW"

# ---- 设置地址: 只写自己的文件, 不改网关配置, 不重启 ----
CFG0=$(sha256sum "$A/etc/anytls-socks-gateway/config.json" "$(ST)" "$CERT" | awk '{ print $1 }' | tr -d '\n')
R0=$(grep -c '^anytls-socks-gateway restart$' "$K/calls" 2>/dev/null || true)
OUT=$(gw endpoint 1 set 203.0.113.10 31443 2>&1); assert_eq "设置线路 1 地址" 0 "$?"
assert_eq "地址文件权限 600" 600 "$(stat -c %a "$(EPF 1)")"
assert_eq "线路 2 没有被设置" no "$([ -e "$(EPF 2)" ] && echo yes || echo no)"
assert_eq "网关配置 记录 证书都没有变化" "$CFG0" "$(sha256sum "$A/etc/anytls-socks-gateway/config.json" "$(ST)" "$CERT" | awk '{ print $1 }' | tr -d '\n')"
assert_eq "没有重启网关" "$R0" "$(grep -c '^anytls-socks-gateway restart$' "$K/calls" 2>/dev/null || true)"
OUT=$(gw endpoint 1 set 0.0.0.0 443 2>&1); assert_eq "未指定地址被拒绝" 2 "$?"
OUT=$(gw endpoint 1 set example.com 70000 2>&1); assert_eq "无效端口被拒绝" 2 "$?"
OUT=$(gw endpoint 1 show 2>&1)
assert_contains "show 显示地址" "$OUT" "203.0.113.10:31443"
assert_contains "show 显示内部监听" "$OUT" "内部监听"
OUT=$(gw client 1 show 2>&1)
assert_contains "连接信息: 协议" "$OUT" "协议：AnyTLS"
assert_contains "连接信息: 服务器" "$OUT" "服务器：203.0.113.10"
assert_contains "连接信息: 使用映射端口而不是内部监听" "$OUT" "端口：31443"
assert_contains "连接信息: server name 来自证书" "$OUT" "TLS Server Name：anytls-gateway"
assert_not_contains "连接信息: 不含密码" "$OUT" "$PW1"
assert_not_contains "连接信息: 不含 SOCKS5 上游地址" "$OUT" "192.0.2.10"

# ---- sing-box JSON ----
JSON=$(gw client 1 sing-box 2>/dev/null)
assert_contains "JSON: 类型" "$JSON" '"type": "anytls"'
assert_contains "JSON: 服务器" "$JSON" '"server": "203.0.113.10"'
assert_contains "JSON: 端口" "$JSON" '"server_port": 31443'
assert_contains "JSON: 线路 1 的密码" "$JSON" "\"password\": \"$PW1\""
assert_contains "JSON: server_name" "$JSON" '"server_name": "anytls-gateway"'
assert_contains "JSON: 自签名跳过校验" "$JSON" '"insecure": true'
assert_not_contains "JSON: 不含线路 2 的密码" "$JSON" "$PW2"
assert_not_contains "JSON: 不含 SOCKS5 上游" "$JSON" "192.0.2.10"
assert_not_contains "JSON: 不含 SOCKS5 密码" "$JSON" "$SOCKSPW"
assert_not_contains "JSON: 不连接内部监听端口" "$JSON" '"server_port": 20443'
RED=$(gw client 1 sing-box --redacted 2>/dev/null)
assert_contains "脱敏: 密码被遮盖" "$RED" '"password": "REDACTED"'
assert_not_contains "脱敏: 不含真实密码" "$RED" "$PW1"
assert_not_contains "脱敏: 不含 SOCKS5 密码" "$RED" "$SOCKSPW"
# 证书固定
PIN=$(gw client 1 sing-box --embed-cert 2>/dev/null)
assert_contains "固定: 嵌入证书" "$PIN" '"certificate": ['
assert_contains "固定: PEM 头" "$PIN" "BEGIN CERTIFICATE"
assert_not_contains "固定: 不再 insecure" "$PIN" '"insecure"'
# JSON 语法正确
if command -v python3 >/dev/null 2>&1; then
    for j in "$JSON" "$RED" "$PIN"; do printf '%s' "$j" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && t_pass "JSON 语法有效" || t_fail "JSON 语法无效"; done
fi

# ---- 分享 URL ----
URL=$(gw client 1 url 2>/dev/null)
assert_eq "URL 完全正确" "anytls://$PW1@203.0.113.10:31443/?sni=anytls-gateway&insecure=1#AnyTLS-Gateway-1" "$URL"
# IPv6: 方括号
gw endpoint 2 set 2001:db8::20 443 >/dev/null 2>&1
URL6=$(gw client 2 url 2>/dev/null)
assert_eq "IPv6 URL" "anytls://$PW2@[2001:db8::20]:443/?sni=anytls-gateway&insecure=1#AnyTLS-Gateway-2" "$URL6"
J6=$(gw client 2 sing-box 2>/dev/null)
assert_contains "IPv6 JSON 不带方括号" "$J6" '"server": "2001:db8::20"'
assert_contains "线路 2 的 JSON 用线路 2 的密码" "$J6" "\"password\": \"$PW2\""
assert_not_contains "线路 2 的 JSON 不含线路 1 的密码" "$J6" "$PW1"
# 域名
gw endpoint 2 set VPN.Example.Com 8443 >/dev/null 2>&1
assert_contains "域名规范化为小写" "$(gw client 2 url 2>/dev/null)" "@vpn.example.com:8443/"
# 二维码: 与 URL 一致 (用 qrencode 桩把 stdin 原样写出)
mkdir -p "$A/usr/bin"
printf '#!/bin/sh\ncat\n' > "$A/usr/bin/qrencode"
chmod +x "$A/usr/bin/qrencode"
QR=$(gw client 1 qr 2>/dev/null)
assert_eq "二维码内容与分享 URL 一致" "$URL" "$QR"
rm -f "$A/usr/bin/qrencode"
OUT=$(gw client 1 qr 2>&1); assert_eq "没有 qrencode 时返回 5" 5 "$?"
assert_contains "沿用现有依赖提示" "$OUT" "qrencode"
assert_contains "分享链接仍可用的提示" "$OUT" "client 1 url"

# ---- 证书条件 ----
# 旧证书 (只有 CN, 没有 SAN): 其他功能可用, 固定校验被拒绝并说明原因, 不生成会被客户端拒绝的配置
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=anytls-gateway" -keyout "$A/etc/anytls-socks-gateway/key.pem" -out "$CERT" >/dev/null 2>&1
OUT=$(gw client 1 sing-box --embed-cert 2>&1); assert_eq "CN-only 证书拒绝固定校验" 1 "$?"
assert_contains "说明没有 SAN" "$OUT" "没有覆盖"
assert_not_contains "拒绝时不输出 JSON" "$OUT" '"outbounds"'
assert_contains "CN-only 证书的普通导出仍可用" "$(gw client 1 sing-box 2>/dev/null)" '"insecure": true'
# CA 签发的证书: 按证书链校验, 不带 insecure, 不支持固定
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=my-ca" -keyout "$T_TMP/ca.key" -out "$T_TMP/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=vpn.example.com" -keyout "$A/etc/anytls-socks-gateway/key.pem" -out "$T_TMP/srv.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:vpn.example.com\n' > "$T_TMP/san.cnf"
openssl x509 -req -in "$T_TMP/srv.csr" -CA "$T_TMP/ca.pem" -CAkey "$T_TMP/ca.key" -CAcreateserial -days 30 -extfile "$T_TMP/san.cnf" -out "$CERT" >/dev/null 2>&1
CAJ=$(gw client 2 sing-box 2>/dev/null)
assert_contains "CA 证书: server_name 是证书名称" "$CAJ" '"server_name": "vpn.example.com"'
assert_not_contains "CA 证书: 不带 insecure" "$CAJ" '"insecure"'
CAU=$(gw client 2 url 2>/dev/null)
assert_not_contains "CA 证书: URL 不带 insecure" "$CAU" "insecure"
assert_contains "CA 证书: URL 带 sni" "$CAU" "sni=vpn.example.com"
OUT=$(gw client 2 sing-box --embed-cert 2>&1); assert_eq "CA 证书不支持嵌入固定" 1 "$?"
printf '%s' "$CAJ" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && t_pass "CA 证书 JSON 语法有效" || t_fail "CA 证书 JSON 语法无效"
# 证书不可读: 拒绝而不是猜测
rm -f "$CERT"
OUT=$(gw client 1 sing-box 2>&1); assert_eq "没有证书时拒绝" 1 "$?"
assert_contains "说明无法读取证书" "$OUT" "证书"

# ---- 只读: 导出不改变任何文件, 不重启 ----
new_g g2
printf '%s\n' "$SOCKSPW" | gw install --port 20443 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
gw endpoint 1 set 203.0.113.10 20443 >/dev/null 2>&1
S0=$(cd "$A" && find etc var -type f ! -path 'var/tmp/*' -exec sha256sum {} + | sort | sha256sum)
C0=$(wc -l < "$K/calls" 2>/dev/null || echo 0)
for act in show secret "sing-box" "sing-box --redacted" "sing-box --embed-cert" url; do
    # shellcheck disable=SC2086
    gw client 1 $act >/dev/null 2>&1
done
assert_eq "导出前后文件完全一致" "$S0" "$(cd "$A" && find etc var -type f ! -path 'var/tmp/*' -exec sha256sum {} + | sort | sha256sum)"
assert_eq "导出没有调用任何服务操作" "$C0" "$(wc -l < "$K/calls" 2>/dev/null || echo 0)"

# ---- 删除线路与卸载清理地址文件 ----
new_g g3
printf '%s\n' "$SOCKSPW" | gw install --port 20443 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
printf '%s\n' "$SOCKSPW" | gw listener add --port 20444 --socks-server 192.0.2.11 --socks-port 1081 --socks-username u2 --socks-password-stdin >/dev/null 2>&1
gw endpoint 1 set 203.0.113.1 1111 >/dev/null 2>&1
gw endpoint 2 set 203.0.113.2 2222 >/dev/null 2>&1
gw listener delete 2 >/dev/null 2>&1
assert_eq "删除线路后清理它的地址文件" no "$([ -e "$(EPF 2)" ] && echo yes || echo no)"
assert_eq "其他线路的地址保留" yes "$([ -e "$(EPF 1)" ] && echo yes || echo no)"
gw uninstall --purge >/dev/null 2>&1
assert_eq "purge 清理地址文件" no "$([ -e "$(EPF 1)" ] && echo yes || echo no)"

# ---- TUI: 入口 统一地址选择 返回 ----
new_g g4
printf '%s\n' "$SOCKSPW" | gw install --port 20443 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
PW1=$(kv_get "$(ST)" listener.1.password)
tx() { printf '%b' "$1" | ( APM_DOWNLOADER=$MOCK MOCK_MODE=${2:-ok}; export APM_DOWNLOADER MOCK_MODE; tui_run ) 2>&1; }
out=$(tx '3\n0\n0\n')
assert_contains "Gateway 菜单有客户端配置入口" "$out" "客户端配置"
# 菜单序号: 查看详细信息 停止/启动 重启 转发线路 证书 客户端配置
out=$(tx '3\n6\n0\n0\n0\n' ok)
for item in "客户端配置 · AnyTLS Gateway 线路 1（端口 20443）" "查看连接信息" "查看凭据" "导出 sing-box JSON" "导出 sing-box JSON（隐藏凭据）" "可选：嵌入证书固定校验" "导出分享 URL" "显示 QR（需要 qrencode）" "证书校验：跳过（自签名，免维护）"; do
    assert_contains "Gateway 客户端配置含 $item" "$out" "$item"
done
assert_not_contains "只有一条线路时不再询问选哪条" "$out" "选择要导出客户端配置的转发线路"
# 查看凭据 (2) 直接显示该线路密码
out=$(tx '3\n6\n2\n\n0\n0\n0\n0\n' ok)
assert_contains "TUI 凭据: 线路密码" "$out" "$PW1"
# 查看连接信息 (1): 没有保存地址 -> 统一组件 -> Enter 自动获取 -> 端口默认 -> 继续
out=$(tx '3\n6\n1\n\n\n\n0\n0\n0\n0\n' ok)
assert_contains "TUI: 使用统一地址选择" "$out" "直接按 Enter：自动获取公网 IP"
assert_contains "TUI: 提示 0 与 Esc" "$out" "输入 0 或按 Esc：取消并返回"
assert_contains "TUI: 自动获取成功" "$out" "已自动获取服务器公网 IP：93.184.216.34"
assert_eq "TUI: 保存的地址" 93.184.216.34 "$(kv_get "$(EPF 1)" public.host)"
assert_eq "TUI: 端口默认使用监听端口" 20443 "$(kv_get "$(EPF 1)" public.port)"
assert_contains "TUI: 继续显示连接信息" "$out" "客户端连接信息 AnyTLS-Gateway-1"
assert_not_contains "TUI: 连接信息不含密码" "$out" "$PW1"
# 更改地址 (菜单最后一项 endpoint = 8): 手动 IPv6
out=$(tx '3\n6\n8\n2001:db8::9\n8443\n\n0\n0\n0\n0\n' ok)
assert_eq "TUI 手动 IPv6" 2001:db8::9 "$(kv_get "$(EPF 1)" public.host)"
assert_eq "TUI 手动端口" 8443 "$(kv_get "$(EPF 1)" public.port)"
# 0 与 Esc 返回, 不改地址
T0=$(cat "$(EPF 1)")
out=$(tx '3\n6\n8\n0\n0\n0\n0\n' ok)
assert_eq "输入 0 取消, 地址不变" "$T0" "$(cat "$(EPF 1)")"
out=$(tx "3\\n6\\n8\\n${ESC}\\n0\\n0\\n0\\n" ok)
assert_eq "Esc 取消, 地址不变" "$T0" "$(cat "$(EPF 1)")"
assert_contains "Esc 取消有提示" "$out" "已取消"
# 自动获取失败: 提示, 之后手动输入
gw endpoint 1 clear >/dev/null 2>&1
out=$(tx '3\n6\n1\n\n198.51.100.8\n\n\n0\n0\n0\n0\n' fail)
assert_contains "TUI: 自动失败提示" "$out" "自动获取失败"
assert_eq "TUI: 失败后手动输入" 198.51.100.8 "$(kv_get "$(EPF 1)" public.host)"
# 导出 JSON (3) 需要确认, 内容含线路密码
out=$(tx '3\n6\n3\n\n\n0\n0\n0\n0\n' ok)
assert_contains "TUI JSON: 真实配置" "$out" "\"password\": \"$PW1\""
out=$(tx '3\n6\n4\n\n0\n0\n0\n0\n' ok)
assert_contains "TUI 隐藏凭据" "$out" '"password": "REDACTED"'
assert_not_contains "TUI 隐藏凭据: 不含真实密码" "$out" "$PW1"
# 多条线路: 先选线路, 且各自独立
printf '%s\n' "$SOCKSPW" | gw listener add --port 20444 --socks-server 192.0.2.11 --socks-port 1081 --socks-username u2 --socks-password-stdin >/dev/null 2>&1
PW2=$(kv_get "$(ST)" listener.2.password)
out=$(tx '3\n6\n0\n0\n0\n' ok)
assert_contains "多条线路: 询问选择线路" "$out" "选择要导出客户端配置的转发线路"
assert_contains "多条线路: 列出线路 1" "$out" "转发线路 1（端口 20443）"
assert_contains "多条线路: 列出线路 2" "$out" "转发线路 2（端口 20444）"
out=$(tx '3\n6\n2\n2\n\n0\n0\n0\n0\n0\n' ok)
assert_contains "线路 2 的凭据" "$out" "$PW2"
assert_not_contains "线路 2 的凭据页不含线路 1 密码" "$out" "$PW1"
gw endpoint 2 set 203.0.113.22 20444 >/dev/null 2>&1
assert_not_contains "线路 2 的 URL 不含线路 1 密码" "$(gw client 2 url 2>/dev/null)" "$PW1"
assert_contains "线路 1 与线路 2 的地址独立" "$(gw endpoint 1 show)" "198.51.100.8"
# 卸载后入口消失
t_done
