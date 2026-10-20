# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# 客户端 TLS 服务名 (SNI) 的最终策略 (v0.8.4 D139)
#   默认 (自签名证书 跳过证书验证 服务端不要求 SNI): 不指定 JSON 不写 server_name URL 不带 sni 不使用内部占位名称与任何第三方域名
#   用户用 sni set 明确指定的名称始终优先 恢复默认就是清除
#   嵌入证书固定校验 与 CA 签发的证书必须与证书匹配 从真实证书解析 唯一确定不了就拒绝
# 证书用真实 openssl 生成: 单个 DNS SAN 多个 DNS SAN 只有 IP SAN 只有 CN 的历史证书 通配符 服务端二进制是 ELF 桩
# 真实 TLS 握手与错误 SNI 的识别见 tests/e2e/client_sni.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
command -v openssl >/dev/null 2>&1 || { t_skip "没有 openssl, test_client_sni.sh 全部跳过"; t_done; exit $?; }
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_client_sni.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"
APM_FAKE_REAL_CERT=1
export APM_FAKE_REAL_CERT

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
mk_openssl() { mkdir -p "$A/usr/bin"; printf '#!/bin/sh\nexec /usr/bin/openssl "$@"\n' > "$A/usr/bin/openssl"; chmod +x "$A/usr/bin/openssl"; }
ready() { new_s "$1"; mk_openssl; "$PM" sing-box install >/dev/null 2>&1; "$PM" sing-box add anytls --port 20001 >/dev/null 2>&1; }
# 用真实 openssl 换掉实例的证书 (只换证书文件, 不碰服务端配置与密钥): 实例 CN SAN (SAN 为空表示没有 SAN)
put_cert() {
    if [ -n "$3" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$2" -addext "subjectAltName=$3" \
            -keyout "$T_TMP/k.pem" -out "$A/etc/sing-box/tls/$1.crt" >/dev/null 2>&1
    else
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$2" \
            -keyout "$T_TMP/k.pem" -out "$A/etc/sing-box/tls/$1.crt" >/dev/null 2>&1
    fi
}
url_sni() { "$PM" sing-box export "$1" url 2>/dev/null | sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p'; }
json_sni() { "$PM" sing-box export "$1" sing-box 2>/dev/null | sed -n 's/.*"server_name": *"\([^"]*\)".*/\1/p'; }
pin_sni() { "$PM" sing-box export "$1" sing-box --embed-cert 2>/dev/null | sed -n 's/.*"server_name": *"\([^"]*\)".*/\1/p'; }
# JSON 与分享 URL 的连接语义必须一致: 同一个 server_name 与 sni, 同一个 insecure
same_semantics() { # 说明 实例
    local _u _j _ji _ui
    _u=$("$PM" sing-box export "$2" url 2>/dev/null)
    _j=$("$PM" sing-box export "$2" sing-box 2>/dev/null)
    assert_eq "$1: JSON 的 server_name 等于 URL 的 sni" "$(printf '%s' "$_j" | sed -n 's/.*"server_name": *"\([^"]*\)".*/\1/p')" "$(printf '%s' "$_u" | sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p')"
    _ji=no; printf '%s' "$_j" | grep -q '"insecure": true' && _ji=yes
    _ui=no; printf '%s' "$_u" | grep -q 'insecure=1' && _ui=yes
    assert_eq "$1: JSON 与 URL 的 insecure 一致" "$_ji" "$_ui"
}

# ---- 单元: 名称规范化 ----
assert_eq "SNI 转小写" proxy.example.com "$(client_sni_norm Proxy.Example.COM)"
for bad in '' 203.0.113.9 2001:db8::1 'a b' 'a_b.com' '-a.com' 'a-.com' 'a..com' '*.example.com' 'a.com:443' 'http://a.com' '1.2.3'; do
    assert_fail "无效 SNI [$bad]" client_sni_norm "$bad"
done
assert_ok "单段名称有效" client_sni_norm localhost
assert_eq "IPv6 展开" 2001:0db8:0000:0000:0000:0000:0000:0009 "$(_cx_ip_canon 2001:DB8::9)"
assert_eq "IPv6 完整形式相同" "$(_cx_ip_canon 2001:db8::9)" "$(_cx_ip_canon 2001:DB8:0:0:0:0:0:9)"
assert_eq "IPv6 回环" 0000:0000:0000:0000:0000:0000:0000:0001 "$(_cx_ip_canon ::1)"
assert_eq "IPv4 原样" 203.0.113.9 "$(_cx_ip_canon 203.0.113.9)"

# ---- 默认: 不指定 SNI, 不使用内部占位名称, 新旧实例一致 ----
ready s1
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
assert_eq "默认 URL 没有 sni" "" "$(url_sni AnyTLS-01)"
assert_eq "默认 JSON 没有 server_name" "" "$(json_sni AnyTLS-01)"
assert_eq "默认 URL 的完整形式" "anytls://$(kv_get "$(INST AnyTLS-01)" credential.password)@example.com:32001/?insecure=1#AnyTLS-01" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)"
assert_not_contains "默认 JSON 不含 apm.local" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)" "apm.local"
assert_contains "默认 JSON 仍启用 TLS 并跳过证书验证" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)" '"insecure": true'
same_semantics "默认" AnyTLS-01
out=$("$PM" sing-box export AnyTLS-01 show 2>&1)
assert_contains "show 说明未指定" "$out" "TLS Server Name：未指定"
assert_contains "show 说明默认来源" "$out" "默认: 不填写 SNI"
assert_not_contains "show 不含内部占位名称" "$out" "apm.local"
# 历史实例 (升级前创建的, 没有 public.sni): 与新实例行为相同, 不依赖证书里的名称
"$PM" sing-box set AnyTLS-01 server-name www.example.org >/dev/null 2>&1
assert_eq "改证书名称不影响默认的客户端导出 (URL)" "" "$(url_sni AnyTLS-01)"
assert_eq "改证书名称不影响默认的客户端导出 (JSON)" "" "$(json_sni AnyTLS-01)"
"$PM" sing-box set AnyTLS-01 server-name apm.local >/dev/null 2>&1
# 嵌入证书固定校验必须与证书匹配: 这里才从证书取名称
assert_eq "嵌入证书的 server_name 来自证书" apm.local "$(pin_sni AnyTLS-01)"
assert_not_contains "嵌入证书时没有 insecure" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)" insecure
# 不需要 openssl 也能完成默认导出
rm -f "$A/usr/bin/openssl"
assert_eq "没有 openssl 默认导出仍然成功" "" "$(url_sni AnyTLS-01)"
assert_contains "没有 openssl 默认导出有 URL" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "anytls://"
mk_openssl

# ---- 多个实例: 默认都不指定, 各自可以有自己的自定义值 ----
"$PM" sing-box add hysteria2 --port 20002 --server-name hy.example.net >/dev/null 2>&1
"$PM" sing-box endpoint Hysteria2-01 set example.com 32002 >/dev/null 2>&1
assert_eq "实例二默认也不指定" "" "$(url_sni Hysteria2-01)"
assert_eq "实例二嵌入证书用自己的证书名称" hy.example.net "$(pin_sni Hysteria2-01)"
assert_eq "实例一嵌入证书用自己的证书名称" apm.local "$(pin_sni AnyTLS-01)"
"$PM" sing-box endpoint Hysteria2-01 sni set only-two.example.org >/dev/null 2>&1
assert_eq "实例二的自定义值" only-two.example.org "$(url_sni Hysteria2-01)"
assert_eq "实例一没有继承实例二的自定义值" "" "$(url_sni AnyTLS-01)"
same_semantics "实例二" Hysteria2-01

# ---- 自定义: 始终优先, 保存, 恢复默认就是清除 ----
ready s5
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
out=$("$PM" sing-box endpoint AnyTLS-01 sni set 203.0.113.9 2>&1); rc=$?
assert_eq "SNI 不能是 IP" 2 $rc
assert_contains "说明原因" "$out" "不能是 IP"
assert_fail "SNI 不接受通配符" "$PM" sing-box endpoint AnyTLS-01 sni set '*.example.com'
assert_fail "SNI 不接受空" "$PM" sing-box endpoint AnyTLS-01 sni set ''
assert_eq "无效输入没有写入" "" "$(kv_get "$(INST AnyTLS-01)" public.sni)"
BEFORE_CFG=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)
BEFORE_CRT=$(sha256sum "$A/etc/sing-box/tls/AnyTLS-01.crt" | cut -c1-16)
BEFORE_SRV=$(kv_get "$(INST AnyTLS-01)" tls.server_name)
BEFORE_RST=$(grep -c 'restart' "$K/calls" 2>/dev/null || true)
out=$("$PM" sing-box endpoint AnyTLS-01 sni set CDN.Example.org 2>&1)
assert_contains "设置成功 (转小写)" "$out" "已设置实例 AnyTLS-01 的客户端 TLS 服务名: cdn.example.org"
assert_contains "说明不是真实身份验证" "$out" "不会验证该名称对应网站的身份"
assert_contains "说明不等于网站伪装" "$out" "不等于网站伪装"
assert_contains "说明没有被证书覆盖时嵌入固定校验不可用" "$out" "没有被服务端证书覆盖"
assert_contains "说明没有修改运行配置与证书" "$out" "没有修改运行配置与证书"
assert_eq "不改运行配置" "$BEFORE_CFG" "$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)"
assert_eq "不改证书" "$BEFORE_CRT" "$(sha256sum "$A/etc/sing-box/tls/AnyTLS-01.crt" | cut -c1-16)"
assert_eq "不改服务端 server_name" "$BEFORE_SRV" "$(kv_get "$(INST AnyTLS-01)" tls.server_name)"
assert_eq "sing-box 没有重启" "$BEFORE_RST" "$(grep -c 'restart' "$K/calls" 2>/dev/null || true)"
assert_eq "指定的名称进入 URL" cdn.example.org "$(url_sni AnyTLS-01)"
assert_eq "指定的名称进入 JSON" cdn.example.org "$(json_sni AnyTLS-01)"
same_semantics "自定义" AnyTLS-01
assert_contains "show 标注用户指定" "$("$PM" sing-box export AnyTLS-01 show 2>&1)" "用户指定"
assert_contains "show 提示不等于网站伪装" "$("$PM" sing-box export AnyTLS-01 show 2>&1)" "不等于网站伪装"
assert_fail "没有被证书覆盖的名称不能嵌入证书固定校验" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_contains "endpoint show 显示自定义值" "$("$PM" sing-box endpoint AnyTLS-01 show 2>&1)" "cdn.example.org"
assert_contains "再次设置同一个值没有变化" "$("$PM" sing-box endpoint AnyTLS-01 sni set cdn.example.org 2>&1)" "没有变化"
# 重新进入 重新导出后不丢失
for i in 1 2 3; do assert_eq "重复导出 $i 仍是自定义值" cdn.example.org "$(url_sni AnyTLS-01)"; done
# endpoint clear 只清除连接地址, 保留 TLS 服务名
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
assert_eq "clear 保留 public.sni" cdn.example.org "$(kv_get "$(INST AnyTLS-01)" public.sni)"
assert_eq "clear 清除 public.host" "" "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_ok "只有 public.sni 没有连接地址的实例仍然有效" "$PM" sing-box export AnyTLS-01 secret
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
assert_eq "重新设置地址后自定义值仍在" cdn.example.org "$(url_sni AnyTLS-01)"
out=$("$PM" sing-box endpoint AnyTLS-01 sni clear 2>&1)
assert_contains "恢复默认的说明" "$out" "恢复默认 (不指定 SNI)"
assert_eq "恢复默认后 URL 没有 sni" "" "$(url_sni AnyTLS-01)"
assert_eq "恢复默认后 JSON 没有 server_name" "" "$(json_sni AnyTLS-01)"
assert_eq "恢复默认删除键" "" "$(kv_get "$(INST AnyTLS-01)" public.sni)"
assert_not_contains "恢复默认不是恢复成占位名称" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "apm.local"
assert_not_contains "恢复默认也不是第三方域名" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "bing.com"
# 非 TLS 协议没有 TLS 服务名
"$PM" sing-box add shadowsocks --port 20009 >/dev/null 2>&1
assert_fail "Shadowsocks 没有 TLS 服务名" "$PM" sing-box endpoint Shadowsocks-01 sni set a.example.com
# 损坏的 public.sni 导出失败
"$PM" sing-box endpoint AnyTLS-01 sni set good.example.com >/dev/null 2>&1
cp -p "$(INST AnyTLS-01)" "$T_TMP/inst.bak"
sed -i 's/^public.sni=.*/public.sni=1.2.3.4/' "$(INST AnyTLS-01)"
assert_fail "存储里的 public.sni 无效时导出被拒绝" "$PM" sing-box export AnyTLS-01 secret
cp -p "$T_TMP/inst.bak" "$(INST AnyTLS-01)"

# ---- 嵌入证书固定校验: 多个 DNS SAN 唯一确定不了就拒绝, 选择之后可用 (默认导出不受影响) ----
ready s2
put_cert AnyTLS-01 first.example.com "DNS:first.example.com,DNS:second.example.com,DNS:third.example.com"
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
assert_eq "多个 SAN: 默认导出不受影响 (没有 SNI)" "" "$(url_sni AnyTLS-01)"
assert_ok "多个 SAN: 默认 JSON 可导出" "$PM" sing-box export AnyTLS-01 sing-box
out=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
assert_eq "多个 SAN 且连接地址不在其中: 嵌入被拒绝 (4)" 4 $rc
assert_contains "列出证书里的名称" "$out" "first.example.com second.example.com third.example.com"
assert_contains "指向 sni set" "$out" "sni set"
assert_eq "拒绝时没有 JSON 输出" "" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)"
"$PM" sing-box endpoint AnyTLS-01 sni set Second.Example.com >/dev/null 2>&1
assert_eq "选择之后嵌入证书使用该名称" second.example.com "$(pin_sni AnyTLS-01)"
assert_eq "选择之后默认导出也使用该名称" second.example.com "$(url_sni AnyTLS-01)"
same_semantics "多 SAN 选择后" AnyTLS-01
assert_contains "被证书覆盖的名称可以嵌入证书固定校验" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1)" "BEGIN CERTIFICATE"
# 连接地址正好是其中一个名称: 嵌入时自动使用
"$PM" sing-box endpoint AnyTLS-01 sni clear >/dev/null 2>&1
"$PM" sing-box endpoint AnyTLS-01 set third.example.com 32001 >/dev/null 2>&1
assert_eq "连接地址在 SAN 里时嵌入证书自动使用" third.example.com "$(pin_sni AnyTLS-01)"
# 实例记录的 server_name 在 SAN 里时使用它
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
put_cert AnyTLS-01 apm.local "DNS:apm.local,DNS:other.example.com"
assert_eq "实例记录的 server_name 在 SAN 里" apm.local "$(pin_sni AnyTLS-01)"
# 通配符 SAN 只覆盖一级
put_cert AnyTLS-01 wild.example.com "DNS:*.example.com,DNS:*.other.example.com"
"$PM" sing-box export AnyTLS-01 sing-box --embed-cert >/dev/null 2>&1
assert_eq "两个通配符且无法确定: 嵌入被拒绝" 4 $?
"$PM" sing-box endpoint AnyTLS-01 sni set a.example.com >/dev/null 2>&1
assert_ok "通配符覆盖一级子域" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
"$PM" sing-box endpoint AnyTLS-01 sni set a.b.example.com >/dev/null 2>&1
assert_fail "通配符不覆盖两级子域: 嵌入被拒绝" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_contains "不覆盖仍可跳过证书验证导出" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)" '"insecure": true'

# ---- 只有 IP SAN: 嵌入时不发送 SNI, 连接地址在 IP SAN 里才算被证书覆盖 ----
ready s3
put_cert AnyTLS-01 203.0.113.9 "IP:203.0.113.9"
"$PM" sing-box endpoint AnyTLS-01 set 203.0.113.9 32001 >/dev/null 2>&1
url=$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)
assert_not_contains "IP 连接: URL 不带 sni" "$url" "sni="
assert_contains "IP 连接: URL 的完整形式" "$url" "@203.0.113.9:32001/?insecure=1#AnyTLS-01"
js=$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)
assert_not_contains "IP 连接: JSON 没有 server_name" "$js" "server_name"
assert_contains "IP 连接: JSON 仍启用 TLS" "$js" '"enabled": true'
pj=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1)
assert_contains "连接地址在 IP SAN 里可以嵌入证书" "$pj" "BEGIN CERTIFICATE"
assert_not_contains "嵌入时也不带 server_name" "$pj" "server_name"
"$PM" sing-box endpoint AnyTLS-01 set 198.51.100.7 32001 >/dev/null 2>&1
assert_fail "连接地址不在 IP SAN 里: 嵌入被拒绝" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_contains "说明原因" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1)" "只有 IP SAN"
put_cert AnyTLS-01 2001:db8::9 "IP:2001:db8::9"
"$PM" sing-box endpoint AnyTLS-01 set 2001:db8::9 32001 >/dev/null 2>&1
assert_contains "IPv6 SAN 与压缩形式的连接地址匹配" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1)" "BEGIN CERTIFICATE"
assert_contains "IPv6 URL 带方括号" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "@[2001:db8::9]:32001/?insecure=1"
put_cert AnyTLS-01 both.example.com "DNS:both.example.com,IP:2001:db8::9"
assert_eq "DNS 与 IP 都有时嵌入证书用 DNS 名称" both.example.com "$(pin_sni AnyTLS-01)"

# ---- 只有 CN 的历史证书: 保持 v0.8.3 的严格限制 ----
ready s4
put_cert AnyTLS-01 legacy.example.com ""
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
assert_eq "CN-only: 默认导出仍然成功且没有 SNI" "" "$(url_sni AnyTLS-01)"
same_semantics "CN-only" AnyTLS-01
assert_fail "CN-only: 嵌入证书固定校验被拒绝" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_contains "CN-only: 拒绝原因" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1)" "没有 SAN"
assert_eq "CN-only: 嵌入失败时没有 JSON 输出" "" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)"

# ---- openssl: 默认导出不需要它 嵌入证书固定校验缺少时按需自动安装 失败不降级 ----
ready s6
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
rm -f "$A/usr/bin/openssl"
: > "$K/apk-calls"
assert_eq "没有 openssl: 默认没有 SNI" "" "$(url_sni AnyTLS-01)"
assert_ok "没有 openssl: 默认 JSON 可导出" "$PM" sing-box export AnyTLS-01 sing-box
"$PM" sing-box export AnyTLS-01 url >/dev/null 2>&1
"$PM" sing-box export AnyTLS-01 show >/dev/null 2>&1
assert_eq "默认导出 (JSON URL show) 不安装 openssl" 0 "$(grep -c 'apk add' "$K/apk-calls")"
assert_contains "没有 openssl 但用户指定名称时默认导出仍使用指定值" "$("$PM" sing-box endpoint AnyTLS-01 sni set x.example.org >/dev/null 2>&1; "$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "sni=x.example.org"
"$PM" sing-box endpoint AnyTLS-01 sni clear >/dev/null 2>&1
assert_eq "设置与清除名称同样不安装 openssl" 0 "$(grep -c 'apk add' "$K/apk-calls")"
# 嵌入证书固定校验: 缺少 openssl 时自动安装, 然后继续原有流程, 不需要重新进入
out=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
assert_eq "缺少 openssl 时自动安装并继续导出" 0 $rc
assert_contains "安装提示" "$out" "未安装 openssl，正在安装所需依赖 (openssl)"
assert_contains "安装成功提示" "$out" "openssl安装成功"
assert_contains "安装后继续生成嵌入证书的配置" "$out" "BEGIN CERTIFICATE"
assert_not_contains "嵌入证书的配置没有 insecure" "$out" '"insecure"'
assert_contains "名称来自证书" "$out" '"server_name": "apm.local"'
assert_eq "只安装了 openssl 一次" 1 "$(grep -c 'apk add --no-cache openssl' "$K/apk-calls")"
: > "$K/apk-calls"
"$PM" sing-box export AnyTLS-01 sing-box --embed-cert >/dev/null 2>&1
assert_eq "已安装时不重复安装" 0 "$(grep -c 'apk add' "$K/apk-calls")"
# 失败: 返回 5 说明原因, stdout 没有任何配置 (不降级成跳过证书验证的配置), 不卡死
ossl_fail() { # 名称 期望文本
    rm -f "$A/usr/bin/openssl"
    : > "$K/apk-calls"
    out=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
    assert_eq "$1: 返回 5" 5 $rc
    assert_contains "$1: 原因" "$out" "$2"
    assert_contains "$1: 说明默认配置不是证书固定校验" "$out" "不是证书固定校验"
    assert_eq "$1: stdout 没有任何配置" "" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)"
    assert_not_contains "$1: 输出里没有被降级的 insecure 配置" "$out" '"insecure"'
    assert_ok "$1: 默认导出仍然可用" "$PM" sing-box export AnyTLS-01 sing-box
}
printf 'WARNING: updating and opening https://dl-cdn.alpinelinux.org/alpine/v3.23/main: temporary error (try again later)\nERROR: unable to select packages\n' > "$K/apk_error"
ossl_fail "网络不可用" "无法访问 Alpine 软件源"
printf 'ERROR: Unable to lock database: Permission denied\n' > "$K/apk_error"
ossl_fail "没有权限" "没有写入软件包数据库的权限"
printf 'something unexpected\n' > "$K/apk_error"
ossl_fail "未分类的 apk 失败" "apk 返回了未分类的错误"
rm -f "$K/apk_error"
echo 5 > "$K/apk_sleep"
APM_DEP_INSTALL_TIMEOUT=1 ossl_fail "安装超时" "安装超过 1 秒没有完成"
rm -f "$K/apk_sleep"
touch "$K/apk_no_binary"
ossl_fail "安装后命令不可用" "找不到可以运行的 openssl"
rm -f "$K/apk_no_binary"
rm -f "$A/usr/bin/openssl"
out=$(APM_EUID=1000 "$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
assert_eq "没有 root: 返回 5" 5 $rc
assert_contains "没有 root 的提示" "$out" "需要 root 权限"
mv "$A/sbin/apk" "$T_TMP/apk.bak"
out=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
assert_eq "没有 apk: 返回 5" 5 $rc
assert_contains "没有 apk 的提示" "$out" "没有找到 apk"
mv "$T_TMP/apk.bak" "$A/sbin/apk"
# 安装不会碰证书 配置与服务
BEFORE_CFG=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)
BEFORE_CRT=$(sha256sum "$A/etc/sing-box/tls/AnyTLS-01.crt" | cut -c1-16)
BEFORE_RST=$(grep -c 'restart' "$K/calls" 2>/dev/null || true)
"$PM" sing-box export AnyTLS-01 sing-box --embed-cert >/dev/null 2>&1
assert_eq "自动安装 openssl 不改运行配置" "$BEFORE_CFG" "$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)"
assert_eq "自动安装 openssl 不改证书" "$BEFORE_CRT" "$(sha256sum "$A/etc/sing-box/tls/AnyTLS-01.crt" | cut -c1-16)"
assert_eq "自动安装 openssl 不重启服务" "$BEFORE_RST" "$(grep -c 'restart' "$K/calls" 2>/dev/null || true)"
# 证书格式错误: openssl 可用时也拒绝, 不降级, 不回退到实例记录的名称
mk_openssl
printf 'this is not a certificate\n' > "$A/etc/sing-box/tls/AnyTLS-01.crt"
out=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>&1); rc=$?
assert_eq "证书格式错误: 返回 1" 1 $rc
assert_contains "证书格式错误的说明" "$out" "无法解析服务端证书"
assert_eq "证书格式错误: stdout 没有配置" "" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)"
assert_ok "证书格式错误不影响默认导出" "$PM" sing-box export AnyTLS-01 sing-box
rm -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_fail "证书缺失: 嵌入被拒绝" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_ok "证书缺失不影响默认导出" "$PM" sing-box export AnyTLS-01 sing-box

# ---- 泄漏边界: SNI 相关输出不包含密码 ----
ready s7
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
PWX=$(kv_get "$(INST AnyTLS-01)" credential.password)
assert_not_contains "show 没有密码" "$("$PM" sing-box export AnyTLS-01 show 2>&1)" "$PWX"
assert_not_contains "endpoint show 没有密码" "$("$PM" sing-box endpoint AnyTLS-01 show 2>&1)" "$PWX"
assert_not_contains "sni 设置输出没有密码" "$("$PM" sing-box endpoint AnyTLS-01 sni set z.example.org 2>&1)" "$PWX"

t_done
