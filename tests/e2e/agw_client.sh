#!/bin/sh
# shellcheck disable=SC2015,SC2016,SC2034 # 测试脚本里 A && B || C 用来记录通过或失败
# AnyTLS Gateway 客户端配置的真实端到端测试 (v0.8.3)
# 真实的 AnyTLS Gateway 二进制 (GW_BIN) 真实的官方 sing-box 客户端 (SB_BIN) 真实的 SOCKS5 上游 真实的 openssl 证书
# 产品的导出代码 (agw_client) 读取与网关相同的转发线路记录和证书, 生成的 JSON 交给官方 sing-box 做 check 并真实连接
# 验证: 导出的 JSON 能通过 check; 不带固定校验与带固定校验的配置都能完成 TLS 握手 认证 与代理请求; 错误密码被拒; 线路之间不串用
# 用法: GW_BIN=网关二进制 SB_BIN=官方sing-box sh agw_client.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
GW_BIN=${GW_BIN:?需要 GW_BIN}
_SB_KEEP=$SB_BIN
for _m in common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth; do
    # shellcheck source=/dev/null
    . "$E2E_HERE/../../lib/$_m.sh"
done
SB_BIN=$_SB_KEEP
APM_HOME=$(cd "$E2E_HERE/../.." && pwd)
export APM_HOME
trap 'e2e_cleanup' EXIT
ROOT=$E2E_DIR/root
APM_SYSROOT=$ROOT
export APM_SYSROOT
rm -f "$ROOT"/etc/alpine-proxy-manager/anytlsgw*.conf
mkdir -p "$ROOT/etc/alpine-proxy-manager" "$ROOT/etc/anytls-socks-gateway" "$ROOT/usr/bin"
printf '#!/bin/sh\nexec openssl "$@"\n' > "$ROOT/usr/bin/openssl"
chmod +x "$ROOT/usr/bin/openssl"
PW1=GwClientPassOne0123456789
PW2=GwClientPassTwo0123456789
ST=$ROOT/etc/alpine-proxy-manager/anytlsgw.conf
CERT=$ROOT/etc/anytls-socks-gateway/cert.pem
KEY=$ROOT/etc/anytls-socks-gateway/key.pem
gen_cert() { # 带 SAN (v0.8.3 起新生成的证书) 或 only-cn (旧证书)
    if [ "$1" = san ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=anytls-gateway" -addext "subjectAltName=DNS:anytls-gateway" -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
    else
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=anytls-gateway" -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
    fi
    chmod 600 "$KEY"
}
cat > "$ST" <<SEOF
next_id=3
listener.1.listen=127.0.0.1:33001
listener.1.password=$PW1
listener.1.socks_server=127.0.0.1:31080
listener.1.socks_username=gwuser
listener.1.socks_password=$UPPASS
listener.2.listen=127.0.0.1:33002
listener.2.password=$PW2
listener.2.socks_server=127.0.0.1:31081
listener.2.socks_username=gwuser
listener.2.socks_password=$UPPASS
SEOF
printf 'public.host=127.0.0.1\npublic.port=33001\n' > "$ROOT/etc/alpine-proxy-manager/anytlsgw-endpoint-1.conf"
printf 'public.host=127.0.0.1\npublic.port=33002\n' > "$ROOT/etc/alpine-proxy-manager/anytlsgw-endpoint-2.conf"

section "准备: 目标 两个上游 带 SAN 的证书 真实网关"
start_targets 127.0.0.2,24003 || exit 1
UP_TAG=A start_upstream 31080 permissive gwuser 127.0.0.77 || exit 1
UP_TAG=B start_upstream 31081 permissive gwuser 127.0.0.78 || exit 1
gen_cert san
start_gw() {
    agw_gen_json "$ST" | sed "s|\"cert_file\": \"[^\"]*\"|\"cert_file\": \"$CERT\"|; s|\"key_file\": \"[^\"]*\"|\"key_file\": \"$KEY\"|" > "$E2E_DIR/gw.json"
    [ -z "${GW_PID:-}" ] || { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; GW_PID=; }
    GOMEMLIMIT=16MiB GOGC=50 "$GW_BIN" -config "$E2E_DIR/gw.json" > "$E2E_DIR/gw.log" 2>&1 &
    GW_PID=$!
    track "$GW_PID"
    wait_tcp 127.0.0.1 33001 && wait_tcp 127.0.0.1 33002 || { say "网关没有监听"; cat "$E2E_DIR/gw.log"; return 1; }
}
start_gw || exit 1
ok "网关启动 两条线路监听"

use_client() { # JSON文本
    [ -z "${CL_PID:-}" ] || { kill "$CL_PID" 2>/dev/null; wait "$CL_PID" 2>/dev/null; CL_PID=; }
    printf '%s\n' "$1" > "$E2E_DIR/exported.json"
    "$SB_BIN" check -c "$E2E_DIR/exported.json" > "$E2E_DIR/check.out" 2>&1 || return 3
    "$SB_BIN" run -c "$E2E_DIR/exported.json" > "$E2E_DIR/client.log" 2>&1 &
    CL_PID=$!
    track "$CL_PID"
    wait_tcp 127.0.0.1 2080 || { say "客户端没有启动"; cat "$E2E_DIR/client.log"; return 1; }
}
peer_ok() { # 说明 期望对端正则
    tclear
    r=$(sc tcp 127.0.0.2 24003)
    case $r in OK:*) ;; *) bad "$1: 请求失败 $r"; return 1 ;; esac
    if tail -1 "$TLOG" | grep -Eq "peer=$2"; then ok "$1"; else bad "$1: 对端 $(tail -1 "$TLOG")"; fi
}

section "线路 1: 默认导出 (自签名 跳过校验)"
J1=$(agw_client 1 sing-box 2>/dev/null)
use_client "$J1"; rc=$?
[ $rc = 0 ] && ok "导出的 JSON 通过官方 sing-box check" || { bad "check 失败: $(cat "$E2E_DIR/check.out")"; }
[ $rc = 0 ] && peer_ok "TLS 握手 认证 代理请求成功 经线路 1 的上游" '127\.0\.0\.77'

section "线路 1: 嵌入证书固定校验 (带 SAN 的证书)"
P1=$(agw_client 1 sing-box --embed-cert 2>/dev/null)
use_client "$P1"; rc=$?
[ $rc = 0 ] && ok "固定校验 JSON 通过 check" || bad "固定校验 check 失败: $(cat "$E2E_DIR/check.out")"
[ $rc = 0 ] && peer_ok "固定校验配置真实连接成功 (证书按固定的证书校验)" '127\.0\.0\.77'
# 另一张证书的固定配置必须连不上: 换掉服务端证书后旧的固定配置失败 (证明校验真的在工作)
cp "$CERT" "$E2E_DIR/cert.old"; cp "$KEY" "$E2E_DIR/key.old"
gen_cert san
start_gw || exit 1
use_client "$P1"
tclear
r=$(sc tcp 127.0.0.2 24003)
case $r in OK:*) bad "证书变化后固定校验配置仍连上了" ;; *) ok "服务端证书变化后旧的固定校验配置被拒绝" ;; esac
[ "$(thits)" = 0 ] && ok "被拒绝时目标零命中" || bad "目标有命中"
P1B=$(agw_client 1 sing-box --embed-cert 2>/dev/null)
use_client "$P1B"
peer_ok "重新导出的固定校验配置连接成功" '127\.0\.0\.77'

section "线路 2: 独立的端口与密码 不串用"
J2=$(agw_client 2 sing-box 2>/dev/null)
use_client "$J2"
peer_ok "线路 2 经线路 2 的上游" '127\.0\.0\.78'
printf '%s' "$J2" | grep -q "$PW1" && bad "线路 2 的 JSON 含线路 1 的密码" || ok "线路 2 的 JSON 不含线路 1 的密码"
# 线路 1 的密码连线路 2 的端口必须失败
MIX=$(printf '%s' "$J1" | sed 's/"server_port": 33001/"server_port": 33002/')
use_client "$MIX"
tclear
r=$(sc tcp 127.0.0.2 24003)
case $r in OK:*) bad "线路 1 的密码连上了线路 2" ;; *) ok "线路 1 的密码不能连线路 2 的端口" ;; esac

section "错误凭据与脱敏"
BADPW=$(printf '%s' "$J1" | sed "s/$PW1/WrongClientPassNotSecret/")
use_client "$BADPW"
tclear
r=$(sc tcp 127.0.0.2 24003)
case $r in OK:*) bad "错误密码连上了" ;; *) ok "错误密码被网关拒绝" ;; esac
RED=$(agw_client 1 sing-box --redacted 2>/dev/null)
printf '%s\n' "$RED" > "$E2E_DIR/red.json"
"$SB_BIN" check -c "$E2E_DIR/red.json" >/dev/null 2>&1 && ok "脱敏配置语法通过 check" || bad "脱敏配置 check 失败"
printf '%s' "$RED" | grep -q "$PW1" && bad "脱敏配置含真实密码" || ok "脱敏配置不含真实密码"

section "旧证书 (只有 CN): 固定校验被拒绝 普通导出仍可连接"
gen_cert cn
start_gw || exit 1
OUT=$(agw_client 1 sing-box --embed-cert 2>&1); rc=$?
[ $rc != 0 ] && ok "CN-only 证书拒绝生成固定校验配置" || bad "CN-only 证书生成了固定校验配置"
printf '%s' "$OUT" | grep -q '"outbounds"' && bad "拒绝时仍输出了配置" || ok "拒绝时没有输出配置"
use_client "$(agw_client 1 sing-box 2>/dev/null)"
peer_ok "CN-only 证书的普通导出真实连接成功" '127\.0\.0\.77'
# 如果旧证书直接被嵌入, 官方客户端确实会拒绝 (这就是不生成它的原因)
CNPIN=$(printf '%s' "$J1" | sed "s|\"insecure\": true|\"certificate\": [\"$(awk '/BEGIN CERTIFICATE/{on=1} on{printf "%s\\\\n", $0} /END CERTIFICATE/{exit}' "$CERT")\"]|")
use_client "$CNPIN" 2>/dev/null
tclear
r=$(sc tcp 127.0.0.2 24003)
case $r in OK:*) say "  信息: 当前 sing-box 接受了 CN-only 的固定证书" ;; *) ok "CN-only 证书被嵌入时官方客户端拒绝 (所以产品拒绝生成)" ;; esac

section "导出是只读的: 网关一直在运行 没有被重启"
kill -0 "$GW_PID" 2>/dev/null && ok "网关进程仍在运行" || bad "网关进程不见了"

e2e_finish
