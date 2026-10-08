# shellcheck shell=sh
# Client Export: Public Endpoint, show-secret, 人类可读信息, sing-box 客户端 JSON, 分享 URL, 二维码, 与服务端策略独立, 泄漏边界
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_client_export.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
CFGSUM() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
sbpid() { core_discover singbox; printf '%s' "$CF_PID"; }
ready() { new_s "$1"; "$PM" sing-box install >/dev/null 2>&1; }
leaks() { # 秘密 允许的位置
    grep -rlF -- "$1" "$A" 2>/dev/null | while IFS= read -r f; do
        ok=0
        for a in $2; do
            # shellcheck disable=SC2254
            case $f in $a) ok=1 ;; esac
        done
        [ "$ok" = 1 ] || printf '%s\n' "$f"
    done
}

# ---- 主机规范化 ----
hn() { client_host_norm "$1"; }
assert_eq "IPv4" 203.0.113.10 "$(hn 203.0.113.10)"
assert_eq "IPv6" 2001:db8::1 "$(hn 2001:DB8::1)"
assert_eq "带方括号的 IPv6 去掉方括号" 2001:db8::1 "$(hn '[2001:db8::1]')"
assert_eq "主机名转小写" proxy.example.com "$(hn Proxy.Example.COM)"
assert_eq "单段主机名" localhost "$(hn localhost)"
assert_eq "回环 IPv4 允许" 127.0.0.1 "$(hn 127.0.0.1)"
assert_eq "回环 IPv6 允许" ::1 "$(hn ::1)"
for bad in '' 0.0.0.0 :: 256.1.1.1 1.2.3 01.2.3.4 '[1.2.3.4]' '[example.com]' 'a b' 'a_b.com' '-a.com' 'a-.com' 'a..com' 'a.com.' 'http://a.com' 'a.com:80' '2001:db8::1::2' '2001:db8:::1' 'fe80::1%eth0' '1.2.3.4/32' '*.a.com' 'a.1'; do
    assert_fail "无效主机 [$bad]" client_host_norm "$bad"
done
assert_fail "过长主机名" client_host_norm "$(printf 'a%.0s' $(seq 1 64)).com"
assert_ok "63 字符标签" client_host_norm "$(printf 'a%.0s' $(seq 1 63)).com"

# ---- Public Endpoint CLI ----
ready e1
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
CS0=$(CFGSUM)
PID0=$(sbpid)
RS0=$(count_calls restart)
out=$("$PM" sing-box endpoint AnyTLS-01 show 2>&1)
assert_contains "未配置时显示未配置" "$out" "客户端连接地址：未配置"
assert_contains "显示内部监听并说明不等于客户端地址" "$out" "不等于客户端连接地址"
assert_fail "没有 endpoint 时 export show 失败" "$PM" sing-box export AnyTLS-01 show
out=$("$PM" sing-box export AnyTLS-01 show 2>&1)
assert_contains "没有 endpoint 的提示" "$out" "尚未配置客户端连接地址"
for a in sing-box url qr; do
    assert_fail "没有 endpoint 时 export $a 失败" "$PM" sing-box export AnyTLS-01 $a
    assert_eq "没有 endpoint 时 export $a 没有任何输出" "" "$("$PM" sing-box export AnyTLS-01 $a 2>/dev/null)"
done
assert_contains "没有 endpoint 时 export secret 仍可用" "$("$PM" sing-box export AnyTLS-01 secret 2>/dev/null)" "密码："

"$PM" sing-box endpoint AnyTLS-01 set 203.0.113.10 32001 >/dev/null 2>&1
assert_eq "set IPv4 成功" 0 $?
assert_eq "public.host 已存储" 203.0.113.10 "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_eq "public.port 已存储" 32001 "$(kv_get "$(INST AnyTLS-01)" public.port)"
assert_eq "set 没有改运行配置" "$CS0" "$(CFGSUM)"
assert_eq "set 没有重启 sing-box" "$RS0" "$(count_calls restart)"
assert_eq "set 没有换 PID" "$PID0" "$(sbpid)"
assert_eq "内部监听端口不变" 20001 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
assert_contains "show 显示 endpoint" "$("$PM" sing-box endpoint AnyTLS-01 show)" "客户端连接地址：203.0.113.10:32001"
assert_eq "文件权限 0600" 600 "$(stat -c %a "$(INST AnyTLS-01)")"
"$PM" sing-box endpoint AnyTLS-01 set '[2001:DB8::5]' 443 >/dev/null 2>&1
assert_eq "set IPv6 成功并规范化" 2001:db8::5 "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_contains "show 的 IPv6 带方括号" "$("$PM" sing-box endpoint AnyTLS-01 show)" "客户端连接地址：[2001:db8::5]:443"
"$PM" sing-box endpoint AnyTLS-01 set Proxy.Example.com 443 >/dev/null 2>&1
assert_eq "set 主机名成功并小写" proxy.example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
before=$(cat "$(INST AnyTLS-01)")
for bad in "0.0.0.0 443" ":: 443" "999.1.1.1 443" "a_b 443" "example.com 0" "example.com 65536" "example.com abc" "example.com -1" "example.com 080a" ; do
    # shellcheck disable=SC2086
    "$PM" sing-box endpoint AnyTLS-01 set $bad >/dev/null 2>&1
    assert_eq "无效 endpoint [$bad] 返回用法错误" 2 $?
done
assert_eq "无效输入没有改动实例文件" "$before" "$(cat "$(INST AnyTLS-01)")"
"$PM" sing-box endpoint AnyTLS-01 set example.com >/dev/null 2>&1
assert_eq "缺少端口是用法错误" 2 $?
"$PM" sing-box endpoint Nope-01 set example.com 443 >/dev/null 2>&1
assert_eq "实例不存在" 1 $?
"$PM" sing-box endpoint AnyTLS-01 bogus >/dev/null 2>&1
assert_eq "未知操作" 2 $?
out=$("$PM" sing-box endpoint AnyTLS-01 set proxy.example.com 443 2>&1)
assert_contains "相同值不改动" "$out" "没有变化"
assert_eq "改动都没有重启" "$RS0" "$(count_calls restart)"
assert_eq "改动都没有改运行配置" "$CS0" "$(CFGSUM)"
# 其他实例没有被影响
assert_eq "其他实例没有 endpoint" "" "$(kv_get "$(INST Hysteria2-01)" public.host)"
"$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
assert_eq "clear 后没有 public.host" "" "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_eq "clear 后没有 public 键" 0 "$(grep -c '^public\.' "$(INST AnyTLS-01)")"
assert_eq "clear 没有重启" "$RS0" "$(count_calls restart)"
assert_eq "clear 没有改运行配置" "$CS0" "$(CFGSUM)"
# 每个实例独立
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
"$PM" sing-box endpoint Hysteria2-01 set example.com 32002 >/dev/null 2>&1
"$PM" sing-box endpoint TUIC-01 set 198.51.100.7 41000 >/dev/null 2>&1
"$PM" sing-box endpoint Shadowsocks-01 set '[2001:db8::9]' 42000 >/dev/null 2>&1
assert_eq "AnyTLS 端口" 32001 "$(kv_get "$(INST AnyTLS-01)" public.port)"
assert_eq "Hysteria2 端口" 32002 "$(kv_get "$(INST Hysteria2-01)" public.port)"
assert_eq "TUIC 主机" 198.51.100.7 "$(kv_get "$(INST TUIC-01)" public.host)"
assert_eq "Shadowsocks 主机" 2001:db8::9 "$(kv_get "$(INST Shadowsocks-01)" public.host)"
assert_eq "四个实例设置后仍没有重启" "$RS0" "$(count_calls restart)"
assert_eq "四个实例设置后运行配置不变" "$CS0" "$(CFGSUM)"
assert_eq "运行配置没有 public 字段" 0 "$(grep -c 'public\|example.com\|32001' "$A/etc/sing-box/config.json")"
assert_eq "check 仍通过" 0 "$("$PM" sing-box check >/dev/null 2>&1; echo $?)"

# 损坏的 endpoint 存储 fail-closed
cp "$(INST AnyTLS-01)" "$T_TMP/anytls.good"
printf 'public.host=bad host\n' >> "$(INST AnyTLS-01)"
assert_fail "只有 host 的损坏实例导出失败" "$PM" sing-box export AnyTLS-01 sing-box
assert_eq "损坏实例没有半份输出" "" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"
cp "$T_TMP/anytls.good" "$(INST AnyTLS-01)"
sed -i '/^public.port=/d' "$(INST AnyTLS-01)"
assert_fail "缺少 port 的实例导出失败" "$PM" sing-box export AnyTLS-01 url
assert_fail "缺少 port 时 doctor 以外的修改也被校验拒绝" sb_instance_validate "$(INST AnyTLS-01)"
cp "$T_TMP/anytls.good" "$(INST AnyTLS-01)"
sed -i 's/^public.host=.*/public.host=Example.COM/' "$(INST AnyTLS-01)"
assert_fail "非规范形式的 host 被校验拒绝" sb_instance_validate "$(INST AnyTLS-01)"
cp "$T_TMP/anytls.good" "$(INST AnyTLS-01)"
assert_ok "恢复后校验通过" sb_instance_validate "$(INST AnyTLS-01)"

# ---- 导出事实: 人类可读 ----
out=$("$PM" sing-box export AnyTLS-01 show 2>&1)
assert_contains "show 协议" "$out" "协议：AnyTLS"
assert_contains "show 服务器" "$out" "服务器：example.com"
assert_contains "show 端口是 public 端口不是内部端口" "$out" "端口：32001"
assert_not_contains "show 没有内部端口" "$out" "端口：20001"
assert_contains "show 的 SNI 与 endpoint 独立" "$out" "TLS Server Name：apm.local"
assert_contains "show 说明自签名" "$out" "自签名"
assert_contains "show 说明不配置 NAT" "$out" "不配置 NAT"
PW_A=$(kv_get "$(INST AnyTLS-01)" credential.password)
assert_not_contains "show 不含密码" "$out" "$PW_A"
assert_contains "show 说明凭据已配置" "$out" "凭据：已配置"
out=$("$PM" sing-box export TUIC-01 show 2>&1)
assert_contains "TUIC show 含 UUID" "$out" "UUID：$(kv_get "$(INST TUIC-01)" credential.uuid)"
out=$("$PM" sing-box export Shadowsocks-01 show 2>&1)
assert_contains "Shadowsocks show 含 method" "$out" "method：2022-blake3-aes-128-gcm"
assert_contains "Shadowsocks 没有 TLS" "$out" "传输层：tcp+udp"
assert_not_contains "Shadowsocks 没有 SNI" "$out" "TLS Server Name"
assert_not_contains "Shadowsocks show 不含密钥" "$out" "$(kv_get "$(INST Shadowsocks-01)" credential.password)"
# 回环提醒
"$PM" sing-box endpoint Hysteria2-01 set 127.0.0.1 20002 >/dev/null 2>&1
assert_contains "回环提醒" "$("$PM" sing-box export Hysteria2-01 show 2>&1)" "回环地址只有本机可用"
"$PM" sing-box endpoint Hysteria2-01 set example.com 32002 >/dev/null 2>&1
# 禁用的实例允许导出并提示
"$PM" sing-box disable Hysteria2-01 >/dev/null 2>&1
out=$("$PM" sing-box export Hysteria2-01 show 2>&1)
assert_contains "禁用实例仍可导出并提示" "$out" "已禁用, 客户端暂时无法连接"
assert_contains "禁用实例的 JSON 仍可导出" "$("$PM" sing-box export Hysteria2-01 sing-box 2>/dev/null)" '"type": "hysteria2"'
"$PM" sing-box enable Hysteria2-01 >/dev/null 2>&1

# ---- show-secret ----
out=$("$PM" sing-box export AnyTLS-01 secret 2>/dev/null)
assert_eq "AnyTLS secret 只有密码" "密码：$PW_A" "$out"
assert_contains "secret 警告在 stderr" "$("$PM" sing-box export AnyTLS-01 secret 2>&1 >/dev/null)" "警告：以下内容包含客户端凭据"
assert_not_contains "secret 警告不在 stdout" "$out" "警告"
out=$("$PM" sing-box export TUIC-01 secret 2>/dev/null)
assert_contains "TUIC secret 含 UUID" "$out" "UUID：$(kv_get "$(INST TUIC-01)" credential.uuid)"
assert_contains "TUIC secret 含密码" "$out" "密码：$(kv_get "$(INST TUIC-01)" credential.password)"
out=$("$PM" sing-box export Shadowsocks-01 secret 2>/dev/null)
assert_contains "Shadowsocks secret 含 method" "$out" "method：2022-blake3-aes-128-gcm"
assert_contains "Shadowsocks secret 含密钥原样" "$out" "密码：$(kv_get "$(INST Shadowsocks-01)" credential.password)"
assert_eq "instance show 仍然不显示密码" 0 "$("$PM" sing-box show AnyTLS-01 2>&1 | grep -c "$PW_A")"
assert_eq "list 不显示密码" 0 "$("$PM" sing-box list 2>&1 | grep -c "$PW_A")"
assert_fail "secret 不接受多余参数" "$PM" sing-box export AnyTLS-01 secret extra

# ---- sing-box 客户端 JSON ----
j=$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)
assert_contains "AnyTLS JSON type" "$j" '"type": "anytls"'
assert_contains "AnyTLS JSON server" "$j" '"server": "example.com"'
assert_contains "AnyTLS JSON 端口是数字" "$j" '"server_port": 32001,'
assert_contains "AnyTLS JSON 密码" "$j" "\"password\": \"$PW_A\""
assert_contains "AnyTLS JSON SNI" "$j" '"server_name": "apm.local"'
assert_contains "AnyTLS JSON insecure" "$j" '"insecure": true'
assert_not_contains "AnyTLS JSON 没有内部端口" "$j" 20001
assert_not_contains "AnyTLS JSON 没有私钥" "$j" "PRIVATE KEY"
assert_not_contains "AnyTLS JSON 没有私钥路径" "$j" ".key"
assert_contains "警告在 stderr" "$("$PM" sing-box export AnyTLS-01 sing-box 2>&1 >/dev/null)" "警告：以下内容包含客户端凭据"
assert_eq "JSON 输出重复一致" "$j" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"
r=$("$PM" sing-box export AnyTLS-01 sing-box --redacted 2>&1)
assert_not_contains "redacted 不含密码" "$r" "$PW_A"
assert_contains "redacted 标记" "$r" '"password": "REDACTED"'
assert_not_contains "redacted 没有警告" "$r" "警告"
j=$("$PM" sing-box export Hysteria2-01 sing-box 2>/dev/null)
assert_contains "Hysteria2 JSON type" "$j" '"type": "hysteria2"'
assert_contains "Hysteria2 JSON 端口" "$j" '"server_port": 32002,'
assert_not_contains "Hysteria2 JSON 不含未实现的 obfs" "$j" obfs
assert_not_contains "Hysteria2 JSON 不含带宽" "$j" mbps
j=$("$PM" sing-box export TUIC-01 sing-box 2>/dev/null)
assert_contains "TUIC JSON type" "$j" '"type": "tuic"'
assert_contains "TUIC JSON uuid" "$j" "\"uuid\": \"$(kv_get "$(INST TUIC-01)" credential.uuid)\"" 
assert_contains "TUIC JSON 主机" "$j" '"server": "198.51.100.7"'
assert_contains "TUIC JSON 密码" "$j" "\"password\": \"$(kv_get "$(INST TUIC-01)" credential.password)\""
assert_not_contains "TUIC 未设置拥塞控制时不猜默认值" "$j" congestion_control
"$PM" sing-box set TUIC-01 congestion-control bbr >/dev/null 2>&1
assert_contains "TUIC 设置了拥塞控制就导出" "$("$PM" sing-box export TUIC-01 sing-box 2>/dev/null)" '"congestion_control": "bbr"'
j=$("$PM" sing-box export Shadowsocks-01 sing-box 2>/dev/null)
assert_contains "Shadowsocks JSON type" "$j" '"type": "shadowsocks"'
assert_contains "Shadowsocks JSON IPv6 不带方括号" "$j" '"server": "2001:db8::9"'
assert_contains "Shadowsocks JSON method" "$j" '"method": "2022-blake3-aes-128-gcm"'
assert_contains "Shadowsocks JSON 密钥原样" "$j" "\"password\": \"$(kv_get "$(INST Shadowsocks-01)" credential.password)\""
assert_not_contains "Shadowsocks JSON 没有 tls" "$j" '"tls"'
assert_fail "未知参数" "$PM" sing-box export AnyTLS-01 sing-box --bogus
# 嵌入证书
j=$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)
assert_contains "嵌入证书" "$j" '"certificate": ['
assert_contains "嵌入证书包含证书头" "$j" "BEGIN CERTIFICATE"
assert_not_contains "嵌入证书时没有 insecure" "$j" insecure
assert_not_contains "嵌入证书没有私钥" "$j" "PRIVATE KEY"
mv "$A/etc/sing-box/tls/AnyTLS-01.crt" "$T_TMP/crt.bak"
assert_fail "证书缺失时嵌入失败" "$PM" sing-box export AnyTLS-01 sing-box --embed-cert
assert_eq "证书缺失时没有半份输出" "" "$("$PM" sing-box export AnyTLS-01 sing-box --embed-cert 2>/dev/null)"
mv "$T_TMP/crt.bak" "$A/etc/sing-box/tls/AnyTLS-01.crt"

# ---- 分享 URL ----
assert_eq "AnyTLS URL" "anytls://$PW_A@example.com:32001/?sni=apm.local&insecure=1#AnyTLS-01" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)"
assert_eq "Hysteria2 URL" "hysteria2://$(kv_get "$(INST Hysteria2-01)" credential.password)@example.com:32002/?sni=apm.local&insecure=1#Hysteria2-01" "$("$PM" sing-box export Hysteria2-01 url 2>/dev/null)"
assert_contains "URL 警告在 stderr" "$("$PM" sing-box export AnyTLS-01 url 2>&1 >/dev/null)" "警告：以下内容包含客户端凭据"
"$PM" sing-box export TUIC-01 url >/dev/null 2>&1
assert_eq "TUIC 没有 URL 返回 3" 3 $?
assert_contains "TUIC 说明原因并指向 JSON" "$("$PM" sing-box export TUIC-01 url 2>&1)" "没有稳定的通用分享 URI"
assert_eq "TUIC URL 没有任何输出" "" "$("$PM" sing-box export TUIC-01 url 2>/dev/null)"
"$PM" sing-box export TUIC-01 qr >/dev/null 2>&1
assert_eq "TUIC 没有 QR 返回 3" 3 $?
# Shadowsocks 2022: 不用 base64url, method 与密钥分别百分号编码
SSPW=$(kv_get "$(INST Shadowsocks-01)" credential.password)
enc=$(printf '%s' "$SSPW" | sed 's/+/%2B/g; s#/#%2F#g; s/=/%3D/g')
assert_eq "SS 2022 URL" "ss://2022-blake3-aes-128-gcm:$enc@[2001:db8::9]:42000#Shadowsocks-01" "$("$PM" sing-box export Shadowsocks-01 url 2>/dev/null)"
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' | "$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-256-gcm --stdin >/dev/null 2>&1
assert_eq "SS 256 位 URL 的 = 被编码" "ss://2022-blake3-aes-256-gcm:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D@[2001:db8::9]:42000#Shadowsocks-01" "$("$PM" sing-box export Shadowsocks-01 url 2>/dev/null)"
# 带加号与斜杠的密钥
printf 'ab+/cdef0123456789ab+/cdef0123456789abc=' > "$T_TMP/k44"
KEY=$(printf '%s' 'abc+/def0123456789abc+/def0123456789ab+/c=' | head -c 44)
printf '%s' "$KEY" | "$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-256-gcm --stdin >/dev/null 2>&1
if kv_get "$(INST Shadowsocks-01)" credential.password | grep -q '[+/]'; then
    out=$("$PM" sing-box export Shadowsocks-01 url 2>/dev/null)
    assert_not_contains "SS URL 密钥里没有未编码的 +" "${out#*://}" "+"
    assert_contains "SS URL 密钥里 + 与 / 被编码" "$out" "%"
    assert_eq "SS URL 解码后等于密钥" "$(kv_get "$(INST Shadowsocks-01)" credential.password)" "$(printf '%s' "$out" | sed 's#^ss://[^:]*:##; s/@.*//; s/%2B/+/g; s/%2F/\//g; s/%3D/=/g')"
fi
# 传统 AEAD: base64url 无填充
printf 'LegacyPasswordNumberOne0123456' | "$PM" sing-box set Shadowsocks-01 method aes-256-gcm --stdin >/dev/null 2>&1
out=$("$PM" sing-box export Shadowsocks-01 url 2>/dev/null)
ui=${out#ss://}
ui=${ui%%@*}
assert_eq "SS 传统 AEAD 的 userinfo 是 base64url" "aes-256-gcm:LegacyPasswordNumberOne0123456" "$(printf '%s' "$ui" | tr '_-' '/+' | base64 -d 2>/dev/null)"
assert_not_contains "base64url 没有填充与加减号以外字符" "$ui" "="
# IPv6 URL
"$PM" sing-box endpoint AnyTLS-01 set 2001:db8::1 443 >/dev/null 2>&1
assert_contains "AnyTLS IPv6 URL 带方括号" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)" "@[2001:db8::1]:443/?"
assert_contains "AnyTLS IPv4 export show 的服务器" "$("$PM" sing-box export AnyTLS-01 show 2>&1)" "服务器：2001:db8::1"
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1

# ---- 二维码: 可选, 不自动安装, 秘密走 stdin 不进 argv ----
out=$("$PM" sing-box export AnyTLS-01 qr 2>&1)
rc=$?
assert_eq "没有 qrencode 时返回 5" 5 $rc
assert_contains "没有 qrencode 的提示" "$out" "libqrencode-tools"
assert_contains "没有 qrencode 时指向 url" "$out" "export AnyTLS-01 url"
assert_eq "没有自动安装 qrencode" 0 "$(grep -c qrencode "$A/.apk-installed" 2>/dev/null || true)"
mkdir -p "$A/usr/bin"
cat > "$A/usr/bin/qrencode" <<EOF
#!/bin/sh
printf '%s\n' "\$#" > "$T_TMP/qr.argc"
printf '%s ' "\$@" > "$T_TMP/qr.argv"
cat > "$T_TMP/qr.stdin"
printf 'QR-OUTPUT\n'
EOF
chmod +x "$A/usr/bin/qrencode"
out=$("$PM" sing-box export AnyTLS-01 qr 2>/dev/null)
assert_eq "qrencode 输出被透传" "QR-OUTPUT" "$out"
assert_eq "stdin 收到完整 URL" "anytls://$PW_A@example.com:32001/?sni=apm.local&insecure=1#AnyTLS-01" "$(cat "$T_TMP/qr.stdin")"
assert_not_contains "argv 没有密码" "$(cat "$T_TMP/qr.argv")" "$PW_A"
assert_not_contains "argv 没有 URL" "$(cat "$T_TMP/qr.argv")" "anytls://"
assert_eq "argv 只有固定选项" "-t UTF8 -m 1 " "$(cat "$T_TMP/qr.argv")"
assert_contains "qr 有警告" "$("$PM" sing-box export AnyTLS-01 qr 2>&1 >/dev/null)" "警告：以下内容包含客户端凭据"
assert_eq "qr 没有留下临时文件" 0 "$(find "$A/tmp" "$A/var/tmp" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ---- 与服务端策略独立 ----
J0=$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)
U0=$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)
S0=$("$PM" sing-box export AnyTLS-01 show 2>/dev/null)
"$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username egressuser --password-stdin <<EOF >/dev/null 2>&1
EgressSecretPasswordZZ0123456789
EOF
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "绑定 SOCKS 出口后 JSON 不变" "$J0" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"
assert_eq "绑定 SOCKS 出口后 URL 不变" "$U0" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)"
assert_eq "绑定 SOCKS 出口后 show 不变" "$S0" "$("$PM" sing-box export AnyTLS-01 show 2>/dev/null)"
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
"$PM" sing-box access AnyTLS-01 add 192.0.2.77 8080 >/dev/null 2>&1
assert_eq "启用目标访问限制后 JSON 不变" "$J0" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"
assert_eq "启用目标访问限制后 URL 不变" "$U0" "$("$PM" sing-box export AnyTLS-01 url 2>/dev/null)"
assert_contains "show 只提示服务端有限制" "$("$PM" sing-box export AnyTLS-01 show 2>/dev/null)" "服务端策略, 不属于客户端参数"
assert_not_contains "show 没有 allowlist 目标" "$("$PM" sing-box export AnyTLS-01 show 2>/dev/null)" 192.0.2.77
assert_eq "出口与限制都保留了 endpoint" example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
# 泄漏边界
for a in show secret sing-box url; do
    o=$("$PM" sing-box export AnyTLS-01 $a 2>&1)
    assert_not_contains "export $a 不含 SOCKS 出口密码" "$o" EgressSecretPasswordZZ
    assert_not_contains "export $a 不含 SOCKS 出口用户名" "$o" egressuser
    assert_not_contains "export $a 不含 SOCKS 服务器" "$o" 192.0.2.10
    assert_not_contains "export $a 不含其他实例密码" "$o" "$(kv_get "$(INST TUIC-01)" credential.password)"
    assert_not_contains "export $a 不含私钥路径" "$o" "/etc/sing-box/tls/AnyTLS-01.key"
    assert_not_contains "export $a 不含私钥" "$o" "PRIVATE KEY"
done
# 切换回 DIRECT 与恢复无限制后还是不变
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
"$PM" sing-box access AnyTLS-01 unrestricted >/dev/null 2>&1
assert_eq "恢复后 JSON 不变" "$J0" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"

# ---- 导出不改变任何东西 ----
CK0=$(cat "$A"/etc/alpine-proxy-manager/instances/*.conf | cksum)
SN0=$(snap)
CS1=$(CFGSUM)
RS1=$(count_calls restart)
PID1=$(sbpid)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    for a in show secret sing-box url qr; do
        "$PM" sing-box export $id $a >/dev/null 2>&1
    done
    "$PM" sing-box endpoint $id show >/dev/null 2>&1
done
assert_eq "导出前后实例文件不变" "$CK0" "$(cat "$A"/etc/alpine-proxy-manager/instances/*.conf | cksum)"
assert_eq "导出前后运行配置不变" "$CS1" "$(CFGSUM)"
assert_eq "导出没有重启" "$RS1" "$(count_calls restart)"
assert_eq "导出没有换 PID" "$PID1" "$(sbpid)"
assert_eq "导出前后文件系统没有新增或删除文件" "$SN0" "$(snap)"

# ---- 泄漏扫描 ----
TUPW=$(kv_get "$(INST TUIC-01)" credential.password)
for s in "$PW_A" "$TUPW" EgressSecretPasswordZZ0123456789; do
    assert_eq "秘密只在允许的位置 [$(printf '%s' "$s" | cut -c1-6)]" "" "$(leaks "$s" "*/etc/alpine-proxy-manager/instances/* */etc/alpine-proxy-manager/socks/* */etc/sing-box/config.json */var/lib/alpine-proxy-manager/backups/* */qr.stdin */fake-rc/*")"
done
assert_eq "元数据不含密码" 0 "$(grep -c "$PW_A" "$A/var/lib/alpine-proxy-manager/cores/singbox.meta")"

# ---- Snell ----
new_s n2
printf 'SnellClientPsk0123456789abcdef' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
SC0=$(cksum < "$A/etc/snell/snell-server.conf")
SPID0=$(core_discover snell; printf '%s' "$CF_PID")
SRS0=$(grep -c '^snell restart$' "$K/calls" 2>/dev/null || true)
assert_fail "Snell 没有 endpoint 时 export show 失败" "$PM" snell export show
assert_contains "Snell 没有 endpoint 的提示" "$("$PM" snell export show 2>&1)" "尚未配置客户端连接地址"
# snell export info: 不依赖 endpoint, 公网 IP 按需查询 (mock 下载器), 失败时降级, 只读
IPMOCK=$T_TMP/ipmock_ce
cat > "$IPMOCK" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
case ${IP_MODE:-ok} in
    ok) printf '93.184.216.34\n' ;;
    bad) printf '<html>nope</html>\n' ;;
    fail) exit 1 ;;
esac
EOS
chmod +x "$IPMOCK"
IP_LOG=$T_TMP/ip_ce.log
: > "$IP_LOG"
export IP_LOG
out=$(APM_DOWNLOADER=$IPMOCK "$PM" snell export info 2>&1)
assert_contains "info 不需要 endpoint 就能用" "$out" "Snell 连接信息"
assert_contains "info 公网 IP 来自查询" "$out" "公网 IP：93.184.216.34"
assert_contains "info 监听端口来自 Snell 配置" "$out" "监听端口：20000"
assert_contains "info Snell 版本" "$out" "Snell 版本：v6.0.0"
assert_contains "info PSK 只显示已配置" "$out" "PSK：已配置"
assert_not_contains "info 不含 PSK" "$out" "SnellClientPsk0123456789abcdef"
assert_not_contains "info 不要求 endpoint" "$out" "尚未配置客户端连接地址"
assert_contains "info 查询走 HTTPS" "$(cat "$IP_LOG")" "https://"
out=$(IP_MODE=bad APM_DOWNLOADER=$IPMOCK "$PM" snell export info 2>&1)
assert_contains "info 无效响应降级" "$out" "公网 IP：获取失败"
assert_contains "info 降级时端口仍显示" "$out" "监听端口：20000"
out=$(IP_MODE=fail APM_DOWNLOADER=$IPMOCK "$PM" snell export info 2>&1)
assert_contains "info 网络失败降级" "$out" "公网 IP：获取失败"
APM_DOWNLOADER=$IPMOCK IP_MODE=fail "$PM" snell export info >/dev/null 2>&1
assert_eq "info 查询失败时命令本身仍成功" 0 $?
assert_fail "info 没有创建 endpoint" test -e "$A/etc/alpine-proxy-manager/snell-endpoint.conf"
assert_eq "info 没有改 Snell 配置" "$SC0" "$(cksum < "$A/etc/snell/snell-server.conf")"
assert_eq "info 后 show 仍要求 endpoint (旧行为兼容)" 1 "$("$PM" snell export show >/dev/null 2>&1; echo $?)"
"$PM" snell export info extra >/dev/null 2>&1
assert_eq "info 不接受多余参数" 2 $?
assert_contains "Snell secret 不需要 endpoint" "$("$PM" snell export secret 2>/dev/null)" "psk：SnellClientPsk0123456789abcdef"
assert_contains "Snell secret 警告" "$("$PM" snell export secret 2>&1 >/dev/null)" "警告：以下内容包含客户端凭据"
"$PM" snell endpoint set Snell.Example.com 32100 >/dev/null 2>&1
assert_eq "Snell set 成功" 0 $?
assert_contains "Snell endpoint show" "$("$PM" snell endpoint show)" "客户端连接地址：snell.example.com:32100"
out=$("$PM" snell export show 2>&1)
assert_contains "Snell show 协议" "$out" "协议：Snell"
assert_contains "Snell show 服务器" "$out" "服务器：snell.example.com"
assert_contains "Snell show 公网端口" "$out" "端口：32100"
assert_not_contains "Snell show 没有内部端口" "$out" "端口：20000"
assert_not_contains "Snell show 不含 psk" "$out" "SnellClientPsk0123456789abcdef"
assert_eq "Snell set 没有改配置" "$SC0" "$(cksum < "$A/etc/snell/snell-server.conf")"
assert_eq "Snell set 没有重启" "$SRS0" "$(grep -c '^snell restart$' "$K/calls" 2>/dev/null || true)"
assert_eq "Snell set 没有换 PID" "$SPID0" "$(core_discover snell; printf '%s' "$CF_PID")"
assert_eq "endpoint 文件 0600" 600 "$(stat -c %a "$A/etc/alpine-proxy-manager/snell-endpoint.conf")"
for a in sing-box url qr; do
    "$PM" snell export $a >/dev/null 2>&1
    assert_eq "Snell export $a 返回 3" 3 $?
done
"$PM" snell endpoint set 0.0.0.0 443 >/dev/null 2>&1
assert_eq "Snell 拒绝 0.0.0.0" 2 $?
"$PM" snell endpoint set '[2001:db8::2]' 443 >/dev/null 2>&1
assert_contains "Snell IPv6 show" "$("$PM" snell endpoint show)" "[2001:db8::2]:443"
assert_eq "Snell 导出前后配置不变" "$SC0" "$(cksum < "$A/etc/snell/snell-server.conf")"
"$PM" snell endpoint clear >/dev/null 2>&1
assert_fail "Snell clear 删除文件" test -e "$A/etc/alpine-proxy-manager/snell-endpoint.conf"
assert_fail "Snell clear 后导出失败" "$PM" snell export show
# 损坏的 endpoint 文件
mkdir -p "$A/etc/alpine-proxy-manager"
printf 'public.host=example.com\n' > "$A/etc/alpine-proxy-manager/snell-endpoint.conf"
assert_fail "Snell endpoint 文件缺少端口时导出失败" "$PM" snell export show
"$PM" snell endpoint set example.com 443 >/dev/null 2>&1
"$PM" snell uninstall --purge >/dev/null 2>&1
assert_fail "purge 删除 Snell endpoint" test -e "$A/etc/alpine-proxy-manager/snell-endpoint.conf"
t_done
