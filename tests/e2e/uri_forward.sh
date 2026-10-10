#!/bin/sh
# shellcheck disable=SC2015,SC2016 # 测试脚本里 A && B || C 用来记录通过或失败
# SOCKS5 链接到真实转发: 用 TUI 共用的解析器从 socks5:// 链接取出主机 端口 用户名 密码 (密码含需要百分号编码的特殊字符),
# 再用这些字段配置真实网关和真实 SOCKS5 上游 (官方 sing-box) 验证 TCP 经上游转发, 凭据错误时失败且目标零命中
# 链接里的密码全部是虚构的
# 用法: GW_BIN=路径 SB_BIN=官方sing-box sh uri_forward.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
_SB_KEEP=$SB_BIN
for _m in common environment state core model policy txn report client snell singbox tui; do
    # shellcheck source=/dev/null
    . "$E2E_HERE/../../lib/$_m.sh"
done
SB_BIN=$_SB_KEEP
trap e2e_cleanup EXIT
GW_BIN=${GW_BIN:?需要 GW_BIN}
GW_PW1=GwUriPassNotSecret00001
GW_ENV=${GW_ENV:-GOMEMLIMIT=16MiB GOGC=50}
# 上游密码含 : @ ! % 空格 / 这些需要在链接里做百分号编码的字符
UPPASS='Fict:p@ss!%x /y'
URI_OK='socks5://uriuser:Fict%3Ap%40ss%21%25x%20%2Fy@127.0.0.1:31090'
URI_BADPW='socks5://uriuser:Fict%3Ap%40ss%21%25x%20%2Fz@127.0.0.1:31090'

section "准备: 自签证书, 受控目标, 密码含特殊字符的真实 SOCKS5 上游"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=gw.apm.test" -keyout "$E2E_DIR/key.pem" -out "$E2E_DIR/cert.pem" >/dev/null 2>&1 || { say "openssl 失败"; exit 1; }
chmod 600 "$E2E_DIR/key.pem"
start_targets 0.0.0.0,24001 127.0.0.2,24003 || exit 1
UP_TAG=U start_upstream 31090 permissive uriuser 127.0.0.91 || exit 1

parse_ok() { tui_socks_uri_parse "$1"; }
write_conf() { # 主机:端口 用户名 密码
    cat > "$E2E_DIR/gw.json" <<JEOF
{"tls":{"cert_file":"$E2E_DIR/cert.pem","key_file":"$E2E_DIR/key.pem"},
 "listeners":[
  {"listen":"127.0.0.1:33201","password":"$GW_PW1","socks5":{"server":"$1","username":"$2","password":"$3"}}]}
JEOF
    chmod 600 "$E2E_DIR/gw.json"
}
start_gw() {
    # shellcheck disable=SC2086
    env $GW_ENV "$GW_BIN" -config "$E2E_DIR/gw.json" > "$E2E_DIR/gw.log" 2>&1 &
    GW_PID=$!
    track "$GW_PID"
    wait_tcp 127.0.0.1 33201 || { say "网关没有监听"; cat "$E2E_DIR/gw.log"; return 1; }
}
stop_gw() { [ -z "${GW_PID:-}" ] || { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }; GW_PID=; }

section "链接解析 + 真实转发"
parse_ok "$URI_OK" && ok "完整链接解析成功" || bad "完整链接解析失败"
[ "$TUI_SK_PASS" = "$UPPASS" ] && ok "密码已按百分号编码还原" || bad "密码还原不一致"
[ "$TUI_SK_USER" = uriuser ] && [ "$TUI_SK_HOST" = 127.0.0.1 ] && [ "$TUI_SK_PORT" = 31090 ] && ok "主机 端口 用户名一致" || bad "主机 端口 用户名不一致"
write_conf "$TUI_SK_HOST:$TUI_SK_PORT" "$TUI_SK_USER" "$TUI_SK_PASS"
start_gw || exit 1
start_anytls_client 33201 "$GW_PW1" || exit 1
expect_peer "链接凭据通过真实上游认证并转发 TCP" tcp 127.0.0.2 24003 '127\.0\.0\.91'
expect_peer "回环目标交给上游 (不是网关直连)" tcp 127.0.0.1 24001 '127\.0\.0\.91'

section "链接里的密码错误: 失败且目标零命中"
stop_gw
parse_ok "$URI_BADPW" && ok "错误密码的链接解析成功 (格式合法)" || bad "链接解析失败"
write_conf "$TUI_SK_HOST:$TUI_SK_PORT" "$TUI_SK_USER" "$TUI_SK_PASS"
start_gw || exit 1
start_anytls_client 33201 "$GW_PW1" || exit 1
expect_denied "上游认证失败 (不回退直连)" tcp 127.0.0.2 24003
expect_denied "上游认证失败 回环" tcp 127.0.0.1 24001
stop_gw

section "不完整或畸形链接不会产生任何配置"
parse_ok 'socks5://uriuser:Fict%zz@127.0.0.1:31090' && bad "畸形百分号编码被接受" || ok "畸形百分号编码被拒绝"
[ -z "$TUI_SK_HOST" ] && ok "拒绝后不保留主机" || bad "拒绝后仍保留主机"
parse_ok 'http://uriuser:x@127.0.0.1:31090' && bad "错误协议被接受" || ok "错误协议被拒绝"

e2e_finish
