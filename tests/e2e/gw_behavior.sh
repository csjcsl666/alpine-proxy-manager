#!/bin/sh
# shellcheck disable=SC2015,SC2016 # 测试脚本里 A && B || C 用来记录通过或失败
# AnyTLS Gateway 行为测试: 一个二进制 (GW_BIN), 官方 sing-box 的 AnyTLS 客户端, 受控 SOCKS5 上游与目标
# 验证: listener 与固定上游一一对应, TCP 经上游, 错误 AnyTLS 密码被拒, 上游认证错误 不可达 失败且目标零命中,
#       UDP 不被支持 (v0.7.0 只实现 TCP), 重启后无残留
# 用法: GW_BIN=路径 SB_BIN=官方sing-box sh gw_behavior.sh
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
trap e2e_cleanup EXIT
GW_BIN=${GW_BIN:?需要 GW_BIN}
GW_PW1=GwPassOneNotSecret0001
GW_PW2=GwPassTwoNotSecret0002
GW_ENV=${GW_ENV:-GOMEMLIMIT=16MiB GOGC=50}

section "准备: 自签证书, 两个受控上游, 受控目标"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=gw.apm.test" -keyout "$E2E_DIR/key.pem" -out "$E2E_DIR/cert.pem" >/dev/null 2>&1 || { say "openssl 失败"; exit 1; }
chmod 600 "$E2E_DIR/key.pem"
start_targets 0.0.0.0,24001 127.0.0.2,24003 || exit 1
UP_TAG=A start_upstream 31080 permissive gwuser 127.0.0.77 || exit 1
UP_TAG=B start_upstream 31081 permissive gwuser 127.0.0.78 || exit 1

write_conf() { # 上游A密码 [上游B端口]
    cat > "$E2E_DIR/gw.json" <<JEOF
{"tls":{"cert_file":"$E2E_DIR/cert.pem","key_file":"$E2E_DIR/key.pem"},
 "listeners":[
  {"listen":"127.0.0.1:33001","password":"$GW_PW1","socks5":{"server":"127.0.0.1:31080","username":"gwuser","password":"$1"}},
  {"listen":"127.0.0.1:33002","password":"$GW_PW2","socks5":{"server":"127.0.0.1:${2:-31081}","username":"gwuser","password":"$UPPASS"}}]}
JEOF
    chmod 600 "$E2E_DIR/gw.json"
}
start_gw() {
    # shellcheck disable=SC2086
    env $GW_ENV "$GW_BIN" -config "$E2E_DIR/gw.json" > "$E2E_DIR/gw.log" 2>&1 &
    GW_PID=$!
    track "$GW_PID"
    wait_tcp 127.0.0.1 33001 && wait_tcp 127.0.0.1 33002 || { say "网关没有监听"; cat "$E2E_DIR/gw.log"; return 1; }
}
stop_gw() { [ -z "${GW_PID:-}" ] || { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }; GW_PID=; }

write_conf "$UPPASS"
start_gw || exit 1
ok "网关启动, 两个 listener 监听"

section "listener 与固定上游一一对应, TCP 经上游"
start_anytls_client 33001 "$GW_PW1" || exit 1
expect_peer "listener 1 经上游 A" tcp 127.0.0.2 24003 '127\.0\.0\.77'
expect_peer "listener 1 回环目标交给上游 (不是网关直连)" tcp 127.0.0.1 24001 '127\.0\.0\.77'
start_anytls_client 33002 "$GW_PW2" || exit 1
expect_peer "listener 2 经上游 B" tcp 127.0.0.2 24003 '127\.0\.0\.78'

section "认证与协议范围"
start_anytls_client 33001 "WrongGwPassNotSecret" || exit 1
expect_denied "错误 AnyTLS 密码被拒" tcp 127.0.0.2 24003
start_anytls_client 33001 "$GW_PW1" || exit 1
# 网关自己不处理 UDP: AnyTLS 的 UDP-over-TCP 请求会被当成对魔术地址的 TCP 连接原样交给上游
# 只有上游本身是理解该魔术地址的 sing-box 时才会通 普通 SOCKS5 服务器不通 所以 v0.7.0 不承诺 UDP
# 这里只断言网关绝不自己直连目标: 目标若有命中 对端必须是上游
expect_not_direct "UDP 不由网关直连 (v0.7.0 不承诺 UDP)" udp 127.0.0.2 24003
if grep -c . "$E2E_DIR/gw.log" >/dev/null; then say "  网关日志行数 $(grep -c . "$E2E_DIR/gw.log")"; fi

section "故障: 上游认证错误 不可达"
stop_gw
write_conf "WrongUpPassNotSecret"
start_gw || exit 1
start_anytls_client 33001 "$GW_PW1" || exit 1
expect_denied "上游认证错误 TCP (不回退直连)" tcp 127.0.0.2 24003
expect_denied "上游认证错误 回环" tcp 127.0.0.1 24001
stop_gw
write_conf "$UPPASS" 9
start_gw || exit 1
start_anytls_client 33002 "$GW_PW2" || exit 1
expect_denied "上游不可达 TCP (不回退直连)" tcp 127.0.0.2 24003
expect_denied "上游不可达 回环" tcp 127.0.0.1 24001
write_conf "$UPPASS"
stop_gw
start_gw || exit 1
start_anytls_client 33002 "$GW_PW2" || exit 1
expect_peer "恢复后正常" tcp 127.0.0.2 24003 '127\.0\.0\.78'

section "配置校验 拒绝不完整配置"
stop_gw
printf '{"tls":{"cert_file":"%s","key_file":"%s"},"listeners":[]}\n' "$E2E_DIR/cert.pem" "$E2E_DIR/key.pem" > "$E2E_DIR/bad1.json"
"$GW_BIN" -config "$E2E_DIR/bad1.json" >/dev/null 2>&1 && bad "空 listener 列表被接受" || ok "空 listener 列表被拒绝"
printf '{"tls":{"cert_file":"%s","key_file":"%s"},"listeners":[{"listen":"127.0.0.1:33009","password":"x","socks5":{"server":"127.0.0.1:1","username":"u"}}]}\n' "$E2E_DIR/cert.pem" "$E2E_DIR/key.pem" > "$E2E_DIR/bad2.json"
"$GW_BIN" -config "$E2E_DIR/bad2.json" >/dev/null 2>&1 && bad "不完整 SOCKS5 配置被接受" || ok "不完整 SOCKS5 配置被拒绝"
printf '{"tls":{"cert_file":"%s","key_file":"%s"},"extra":1,"listeners":[]}\n' "$E2E_DIR/cert.pem" "$E2E_DIR/key.pem" > "$E2E_DIR/bad3.json"
"$GW_BIN" -config "$E2E_DIR/bad3.json" >/dev/null 2>&1 && bad "未知字段被接受" || ok "未知字段被拒绝"
sleep 0.5
if wait_tcp 127.0.0.1 33001 2>/dev/null; then bad "停止后仍有监听"; else ok "停止后没有残留监听"; fi

e2e_finish
