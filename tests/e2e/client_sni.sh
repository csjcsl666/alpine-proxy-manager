#!/bin/sh
# shellcheck disable=SC2015,SC2016,SC2034 # 测试脚本里 A && B || C 用来记录通过或失败
# 客户端 TLS 服务名 (SNI) 的真实协议验证 (v0.8.4)
# 真实的官方 sing-box 服务端 (AnyTLS 入站, 配置由产品的生成器产生, 证书由 sing-box generate tls-keypair 产生)
# 真实的官方 sing-box 客户端 (配置由产品的导出代码产生) 真实的 openssl 证书 真实的 TLS 握手
# 一个 TLS 中继读取 ClientHello, 记录线路上真实发送的 SNI, 不解密不修改
# 验证 (最终策略 D139): 默认不指定 SNI 用 IP 连接时 AnyTLS 握手与代理请求照常成功 线路上没有 SNI
#       用户指定的名称真的出现在线路上 嵌入证书的严格校验在名称正确时成功 在错误 SNI 时失败 (不靠跳过证书验证掩盖名称错误)
#       IP SAN 证书不发送 SNI 用 IP 校验 多个 DNS SAN 的选择 JSON 与分享 URL 的连接语义一致
# 用法: SB_BIN=官方sing-box sh client_sni.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
_SB_KEEP=$SB_BIN
for _m in common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth; do
    # shellcheck source=/dev/null
    . "$E2E_HERE/../../lib/$_m.sh"
done
SB_BIN=$_SB_KEEP
APM_HOME=$(cd "$E2E_HERE/../.." && pwd)
export APM_HOME
CL=
trap 'e2e_cleanup; [ -z "$CL" ] || kill "$CL" 2>/dev/null' EXIT
ROOT=$E2E_DIR/root
rm -rf "$ROOT"
APM_SYSROOT=$ROOT
export APM_SYSROOT
mkdir -p "$ROOT/etc/alpine-proxy-manager/instances" "$ROOT/etc/sing-box/tls" "$ROOT/usr/bin" "$ROOT/run" "$ROOT/var/lib"
printf '#!/bin/sh\nexec openssl "$@"\n' > "$ROOT/usr/bin/openssl"
chmod +x "$ROOT/usr/bin/openssl"

SPORT=20543
RPORT=31543
PW=ClientSniPassNotSecret0123456
RLOG=$E2E_DIR/relay.log
INSTF=$ROOT/etc/alpine-proxy-manager/instances/AnyTLS-01.conf
CRT=$ROOT/etc/sing-box/tls/AnyTLS-01.crt
KEY=$ROOT/etc/sing-box/tls/AnyTLS-01.key
: > "$RLOG"

# 与产品相同的方式生成服务端证书: 官方 sing-box generate tls-keypair 的输出拆成证书与私钥
gen_cert() { # 名称
    "$SB_BIN" generate tls-keypair "$1" -m 12 > "$E2E_DIR/kp.pem" || return 1
    awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$E2E_DIR/kp.pem" > "$KEY"
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$E2E_DIR/kp.pem" > "$CRT"
}
write_instance() { # 名称
    cat > "$INSTF" <<EOF
id=AnyTLS-01
name=AnyTLS-01
type=anytls
enabled=true
listen=127.0.0.1
listen_port=$SPORT
credential.password=$PW
tls.mode=self-signed
tls.server_name=$1
tls.certificate_path=/etc/sing-box/tls/AnyTLS-01.crt
tls.key_path=/etc/sing-box/tls/AnyTLS-01.key
public.host=127.0.0.1
public.port=$RPORT
EOF
    chmod 600 "$INSTF"
}
# 用产品的配置生成器生成服务端配置, 证书路径换成沙盒路径后交给真实 sing-box
start_server() {
    [ -z "${SV_PID:-}" ] || { kill "$SV_PID" 2>/dev/null; wait "$SV_PID" 2>/dev/null; SV_PID=; sleep 0.3; }
    sb_generate_config "$ROOT/etc/alpine-proxy-manager/instances" | sed "s#\"/etc/sing-box#\"$ROOT/etc/sing-box#g" > "$E2E_DIR/server.json"
    "$SB_BIN" check -c "$E2E_DIR/server.json" >/dev/null 2>&1 || { bad "服务端配置 check 失败: $("$SB_BIN" check -c "$E2E_DIR/server.json" 2>&1 | head -3)"; return 1; }
    "$SB_BIN" run -c "$E2E_DIR/server.json" > "$E2E_DIR/server.log" 2>&1 &
    SV_PID=$!
    track "$SV_PID"
    wait_tcp 127.0.0.1 "$SPORT" || { bad "服务端没有启动: $(head -3 "$E2E_DIR/server.log")"; return 1; }
}
start_client() { # JSON文件 日志
    [ -z "$CL" ] || { kill "$CL" 2>/dev/null; wait "$CL" 2>/dev/null; CL=; sleep 0.3; }
    "$SB_BIN" run -c "$1" > "$2" 2>&1 &
    CL=$!
    track "$CL"
    wait_tcp 127.0.0.1 2080 || { bad "客户端没有启动: $(head -3 "$2")"; return 1; }
}
last_sni() { tail -n 1 "$RLOG" 2>/dev/null | sed 's/^SNI=//'; }
try_conn() { tclear; sc tcp 127.0.0.2 24003; }
export_json() { singbox_export AnyTLS-01 sing-box "$@" 2>/dev/null; }
# 导出 -> 官方 check -> 启动真实客户端 -> 真实请求: 成功返回 0
run_json() { # 说明 JSON文件
    "$SB_BIN" check -c "$2" >/dev/null 2>&1 || { bad "$1: 客户端配置 check 失败: $("$SB_BIN" check -c "$2" 2>&1 | head -3)"; return 2; }
    start_client "$2" "$2.log" || return 2
    r=$(try_conn)
    case $r in OK:*) return 0 ;; *) return 1 ;; esac
}

section "准备: 目标 TLS 中继 官方 sing-box 服务端 (证书 SAN 是 apm.local)"
start_targets 127.0.0.2,24003 || exit 1
python3 -I "$E2E_HERE/sni_relay.py" "$RPORT" "$SPORT" "$RLOG" &
track $!
wait_file "$RLOG.ready" 100 || { say "中继没有启动"; exit 1; }
gen_cert apm.local || { say "生成证书失败"; exit 1; }
write_instance apm.local
start_server || exit 1
ok "服务端与中继已启动"

section "场景 0 默认: 不指定 SNI 用 IP 连接 跳过证书验证 真实 AnyTLS 握手与代理请求成功 线路上没有 SNI"
export_json > "$E2E_DIR/c0.json"
grep -q server_name "$E2E_DIR/c0.json" && bad "默认 JSON 里有 server_name" || ok "默认 JSON 没有 server_name"
singbox_export AnyTLS-01 url 2>/dev/null | grep -q 'sni=' && bad "默认 URL 里有 sni" || ok "默认 URL 没有 sni"
grep -q '"insecure": true' "$E2E_DIR/c0.json" && ok "默认 JSON 跳过证书验证" || bad "默认 JSON 没有 insecure"
run_json "场景 0" "$E2E_DIR/c0.json"; rc=$?
[ $rc = 0 ] && ok "不指定 SNI 时 IP 连接的 AnyTLS 握手 认证 代理请求成功" || bad "不指定 SNI 的连接失败 (rc=$rc): $(head -3 "$E2E_DIR/c0.json.log")"
[ "$(last_sni)" = none ] && ok "线路上没有发送 SNI" || bad "线路 SNI: $(last_sni)"

section "场景 1 嵌入证书的严格校验: server_name 来自证书 线路上的 SNI 就是它"
export_json --embed-cert > "$E2E_DIR/c1.json"
grep -q '"server_name": "apm.local"' "$E2E_DIR/c1.json" && ok "JSON 的 server_name 来自证书 SAN" || bad "JSON: $(grep server_name "$E2E_DIR/c1.json")"
grep -q '"insecure"' "$E2E_DIR/c1.json" && bad "固定校验 JSON 里仍有 insecure" || ok "固定校验 JSON 没有 insecure (严格校验)"
run_json "场景 1" "$E2E_DIR/c1.json"; rc=$?
[ $rc = 0 ] && ok "严格校验下 TLS 握手 认证 代理请求成功" || { [ $rc = 1 ] && bad "严格校验的连接失败: $(grep -i 'tls\|x509\|certificate' "$E2E_DIR/c1.json.log" | head -2)"; }
[ "$(last_sni)" = apm.local ] && ok "线路上真实发送的 SNI 是 apm.local" || bad "线路 SNI: $(last_sni)"

section "场景 2 错误 SNI 必须被识别 (不靠跳过证书验证): 同一份配置只把 server_name 换成别的名称"
sed 's/"server_name": "apm.local"/"server_name": "wrong.example.com"/' "$E2E_DIR/c1.json" > "$E2E_DIR/c2.json"
run_json "场景 2" "$E2E_DIR/c2.json"; rc=$?
[ $rc = 1 ] && ok "严格校验下错误 SNI 的连接被拒绝" || bad "错误 SNI 居然连上了 (rc=$rc)"
grep -q 'certificate is valid for\|x509' "$E2E_DIR/c2.json.log" && ok "客户端日志指出证书名称不匹配" || bad "客户端日志里没有名称不匹配: $(head -3 "$E2E_DIR/c2.json.log")"
[ "$(last_sni)" = wrong.example.com ] && ok "线路上发送的确实是错误的名称 (测试能识别名称错误)" || bad "线路 SNI: $(last_sni)"

section "场景 3 服务端更换证书名称: 默认导出不受影响 旧的固定校验配置失效 新的固定校验导出跟随证书"
gen_cert cdn.example.net
write_instance cdn.example.net
start_server || exit 1
run_json "场景 3 默认配置" "$E2E_DIR/c0.json"; rc=$?
[ $rc = 0 ] && ok "默认配置在证书更换后仍然连上 (不依赖证书名称)" || bad "默认配置失败 (rc=$rc)"
run_json "场景 3 旧配置" "$E2E_DIR/c1.json"; rc=$?
[ $rc = 1 ] && ok "旧的固定校验配置被新证书拒绝" || bad "旧配置仍然连上 (rc=$rc)"
export_json --embed-cert > "$E2E_DIR/c3.json"
grep -q '"server_name": "cdn.example.net"' "$E2E_DIR/c3.json" && ok "新导出的 server_name 跟随新证书" || bad "新导出: $(grep server_name "$E2E_DIR/c3.json")"
run_json "场景 3" "$E2E_DIR/c3.json"; rc=$?
[ $rc = 0 ] && ok "新导出的配置严格校验下连接成功" || bad "新导出连接失败 (rc=$rc)"
[ "$(last_sni)" = cdn.example.net ] && ok "线路 SNI 是 cdn.example.net" || bad "线路 SNI: $(last_sni)"

section "场景 4 分享 URL 的连接语义与 JSON 一致: 按 URL 里的参数重建客户端 (默认 与 用户指定)"
rebuild_from_url() { # 说明 输出文件
    local _u _tls
    _u=$(singbox_export AnyTLS-01 url 2>/dev/null)
    U_SNI=$(printf '%s' "$_u" | sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p')
    J_SNI=$(export_json | sed -n 's/.*"server_name": *"\([^"]*\)".*/\1/p')
    [ "$U_SNI" = "$J_SNI" ] && ok "$1: URL 的 sni 与 JSON 的 server_name 相同 [${U_SNI:-无}]" || bad "$1: URL sni=$U_SNI JSON server_name=$J_SNI"
    printf '%s' "$_u" | grep -q 'insecure=1' && export_json | grep -q '"insecure": true' && ok "$1: URL 与 JSON 都跳过证书验证" || bad "$1: insecure 语义不一致"
    _tls='"enabled":true,"insecure":true'
    [ -z "$U_SNI" ] || _tls='"enabled":true,"server_name":"'$U_SNI'","insecure":true'
    printf '{"log":{"level":"warn"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":2080}],"outbounds":[{"type":"anytls","tag":"proxy","server":"127.0.0.1","server_port":%s,"password":"%s","tls":{%s}}]}\n' "$RPORT" "$PW" "$_tls" > "$2"
}
rebuild_from_url "场景 4 默认" "$E2E_DIR/c4.json"
run_json "场景 4" "$E2E_DIR/c4.json"; rc=$?
[ $rc = 0 ] && ok "按 URL 参数重建的客户端连接成功" || bad "URL 重建的客户端失败 (rc=$rc)"
[ "$(last_sni)" = none ] && ok "线路上没有 SNI 与 URL 一致" || bad "线路 SNI: $(last_sni)"

section "场景 5 用户指定的 TLS 服务名: 跳过证书验证时线路上发送它 嵌入证书固定校验被拒绝"
_sb_inst_set "$INSTF" public.sni custom.example.org
export_json > "$E2E_DIR/c5.json"
grep -q '"server_name": "custom.example.org"' "$E2E_DIR/c5.json" && ok "JSON 使用用户指定的名称" || bad "JSON: $(grep server_name "$E2E_DIR/c5.json")"
rebuild_from_url "场景 5 指定" "$E2E_DIR/c5u.json"
run_json "场景 5 按 URL 重建" "$E2E_DIR/c5u.json"; rc=$?
[ $rc = 0 ] && [ "$(last_sni)" = custom.example.org ] && ok "按 URL 重建的客户端线路上发送的也是 custom.example.org" || bad "URL 重建 rc=$rc 线路 SNI: $(last_sni)"
run_json "场景 5" "$E2E_DIR/c5.json"; rc=$?
[ $rc = 0 ] && ok "跳过证书验证的客户端连接成功" || bad "连接失败 (rc=$rc)"
[ "$(last_sni)" = custom.example.org ] && ok "线路上发送的是用户指定的名称" || bad "线路 SNI: $(last_sni)"
singbox_export AnyTLS-01 sing-box --embed-cert >/dev/null 2>&1 && bad "未被证书覆盖的名称居然允许嵌入固定校验" || ok "未被证书覆盖的名称拒绝嵌入固定校验"
_sb_inst_unset "$INSTF" public.sni
export_json > "$E2E_DIR/c5b.json"
grep -q server_name "$E2E_DIR/c5b.json" && bad "恢复默认后 JSON 里仍有 server_name" || ok "恢复默认 (清除) 后 JSON 没有 server_name"

section "场景 6 只有 IP SAN 的证书: 嵌入证书时不发送 SNI 用连接地址 (IP) 严格校验"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
start_server || exit 1
export_json --embed-cert > "$E2E_DIR/c6.json"
grep -q server_name "$E2E_DIR/c6.json" && bad "IP SAN 的 JSON 里仍有 server_name" || ok "IP SAN 的 JSON 没有 server_name"
singbox_export AnyTLS-01 url 2>/dev/null | grep -q 'sni=' && bad "IP SAN 的 URL 里仍有 sni" || ok "IP SAN 的 URL 没有 sni"
run_json "场景 6" "$E2E_DIR/c6.json"; rc=$?
[ $rc = 0 ] && ok "IP SAN 证书在严格校验下连接成功 (按 IP 校验)" || bad "IP SAN 连接失败 (rc=$rc): $(grep -i 'tls\|x509\|certificate' "$E2E_DIR/c6.json.log" | head -2)"
[ "$(last_sni)" = none ] && ok "线路上没有发送 SNI" || bad "线路 SNI: $(last_sni)"
sed 's/"enabled": true/"enabled": true,\n        "server_name": "bad.example.org"/' "$E2E_DIR/c6.json" > "$E2E_DIR/c6b.json"
run_json "场景 6 错误名称" "$E2E_DIR/c6b.json"; rc=$?
[ $rc = 1 ] && ok "IP SAN 证书遇到域名 SNI 时严格校验失败 (名称错误被识别)" || bad "错误名称居然连上 (rc=$rc)"

section "场景 7 多个 DNS SAN: 唯一确定不了就拒绝 选择之后严格校验成功"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 -subj "/CN=a.example.com" -addext "subjectAltName=DNS:a.example.com,DNS:b.example.com" -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
_sb_inst_set "$INSTF" tls.server_name unrelated.example.com
start_server || exit 1
singbox_export AnyTLS-01 sing-box --embed-cert >/dev/null 2>&1; rc=$?
[ $rc = 4 ] && ok "嵌入证书无法唯一确定名称时拒绝 (返回 4)" || bad "返回 $rc"
singbox_export AnyTLS-01 sing-box >/dev/null 2>&1 && ok "默认导出不受多个 SAN 影响" || bad "默认导出失败"
_sb_inst_set "$INSTF" public.sni b.example.com
export_json --embed-cert > "$E2E_DIR/c7.json"
run_json "场景 7" "$E2E_DIR/c7.json"; rc=$?
[ $rc = 0 ] && ok "选择 b.example.com 后严格校验成功" || bad "连接失败 (rc=$rc)"
[ "$(last_sni)" = b.example.com ] && ok "线路 SNI 是 b.example.com" || bad "线路 SNI: $(last_sni)"

kill -0 "$SV_PID" 2>/dev/null && ok "服务端全程没有崩溃" || bad "服务端进程不见了"
say ""
say "通过 $E2E_PASS 失败 $E2E_FAIL"
[ "$E2E_FAIL" -eq 0 ]
