#!/bin/sh
# 官方 sing-box 上的 SOCKS 出口真实流量矩阵, 需要网络, 在 Alpine 容器内运行, 不属于 tests/run.sh
# 用 Manager 自己的生成器生成服务端, 真实运行官方 sing-box 作为服务端、客户端和多个上游 SOCKS5 服务器
# 上游的出站绑定 127.0.0.77, 受控目标记录对端地址: 看到 127.0.0.77 说明流量经过了上游, 看到 127.0.0.1 说明服务器直连
# 覆盖: 本机 内网地址 IPv6 主机名 四类 SOCKS 服务器地址, 认证与无认证, TCP, 域名目标由上游解析, UDP,
#       上游不支持 UDP 时不泄漏成直连, 上游停止时不回落 DIRECT
# 内网地址与 IPv6 需要给 lo 添加地址的权限, 没有权限时这两项如实跳过, 不当作通过
# 全部在本机回环上完成, 不连接任何外部服务
set -eu

VER=${1:-1.13.14}
HERE=$(cd "$(dirname "$0")" && pwd)
case "$VER/$(uname -m)" in
    1.13.14/x86_64) SHA=d5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34; ARCH=amd64 ;;
    1.13.14/aarch64) SHA=edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118; ARCH=arm64 ;;
    1.14.2/x86_64) SHA=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297; ARCH=amd64 ;;
    *) echo "没有内置的校验和: $VER $(uname -m)" >&2; exit 1 ;;
esac
[ -n "${SB_BIN:-}" ] || apk add --no-cache python3 dante-server >/dev/null
ASSET="sing-box-$VER-linux-$ARCH-musl.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v$VER/$ASSET"
W=$(mktemp -d)
# shellcheck disable=SC2046
cleanup() { kill $(jobs -p) 2>/dev/null; pkill -f "$W/" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

if [ -n "${SB_BIN:-}" ]; then
    # 本地调试: 使用预置的官方二进制 (已核对过 sha256), 供没有网络的隔离环境使用
    B=$SB_BIN
else
    n=1
    while [ "$n" -le 3 ]; do
        if wget -q -T 60 -O "$W/sb.tgz" "$URL" && [ -s "$W/sb.tgz" ]; then break; fi
        n=$((n + 1)); sleep 3
    done
    [ -s "$W/sb.tgz" ] || { echo "下载失败: $URL" >&2; exit 1; }
    [ "$(sha256sum "$W/sb.tgz" | awk '{ print $1 }')" = "$SHA" ] || { echo "sha256 不匹配" >&2; exit 1; }
    tar -xzf "$W/sb.tgz" -C "$W" "sing-box-$VER-linux-$ARCH-musl/sing-box"
    B="$W/sing-box-$VER-linux-$ARCH-musl/sing-box"
    chmod 755 "$B"
fi
cd "$W"

APM_HOME=$(dirname "$HERE")
export APM_HOME
for m in common environment state core model policy txn report snell singbox; do
    # shellcheck source=/dev/null
    . "$APM_HOME/lib/$m.sh"
done
mkdir -p inst inst.socks

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  跳过 %s\n' "$1"; }
expect() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 [$2] 实际 [$3])"; fi
}

HAVE_PRIV=no
HAVE_V6=no
if ip addr add 10.99.0.9/32 dev lo 2>/dev/null; then HAVE_PRIV=yes; fi
if ip -6 addr add fd00::9/128 dev lo 2>/dev/null; then HAVE_V6=yes; fi
echo '127.0.0.1 target.test socks.test' >> /etc/hosts

"$B" generate tls-keypair apm.local -m 12 > kp.pem
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' kp.pem > key.pem
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' kp.pem > cert.pem

cat > target.py <<'PY'
import socket, threading
def log(m):
    open("target.log", "a").write(m + "\n")
def tcp():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 24001)); s.listen(50)
    while True:
        c, a = s.accept()
        def h(c=c, a=a):
            try:
                c.settimeout(5); d = c.recv(200).decode(errors="replace").strip(); log("TCP peer=%s line=%s" % (a[0], d)); c.sendall(b"TARGET_OK\n")
            except Exception:
                pass
            c.close()
        threading.Thread(target=h, daemon=True).start()
def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 24002))
    while True:
        d, a = s.recvfrom(500); log("UDP peer=%s data=%s" % (a[0], d.decode(errors="replace").strip())); s.sendto(b"UDP_OK " + d, a)
threading.Thread(target=tcp, daemon=True).start(); udp()
PY
: > target.log
python3 target.py &

UPPASS=UpPassNotSecret0123456789
mkup() { # 名称 监听地址 端口 [用户]
    if [ -n "${4:-}" ]; then us="\"users\":[{\"username\":\"$4\",\"password\":\"$UPPASS\"}],"; else us=; fi
    cat > "up-$1.json" <<J
{"log":{"level":"debug"},"inbounds":[{"type":"socks","tag":"s","listen":"$2","listen_port":$3,$us"sniff":false}],"outbounds":[{"type":"direct","tag":"direct","inet4_bind_address":"127.0.0.77"}]}
J
    "$B" run -c "up-$1.json" > "up-$1.log" 2>&1 &
}
mkup U1 127.0.0.1 26001 upuser
[ "$HAVE_PRIV" != yes ] || mkup U2 10.99.0.9 26002
[ "$HAVE_V6" != yes ] || mkup U3 fd00::9 26003 upuser
cat > dante.conf <<'D'
logoutput: stderr
internal: 127.0.0.1 port = 26004
external: 127.0.0.77
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect
}
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect
  log: connect
}
D
sockd -f dante.conf > dante.log 2>&1 &
sleep 2

mkprof() { { printf 'name=%s\nhost=%s\nport=%s\nenabled=true\n' "$1" "$2" "$3"; [ -z "${4:-}" ] || printf 'username=%s\npassword=%s\n' "$4" "$UPPASS"; } > "inst.socks/$1.conf"; }
mkprof SOCKS-01 127.0.0.1 26001 upuser
mkprof SOCKS-02 10.99.0.9 26002
mkprof SOCKS-03 '[fd00::9]' 26003 upuser
mkprof SOCKS-04 127.0.0.1 26004
mkprof SOCKS-05 socks.test 26001 upuser

PSK=ExpPasswordNotSecret0123456789ab
K16=AAAAAAAAAAAAAAAAAAAAAA==
port=22000; cport=23000
: > cli.in; : > cli.out; : > cli.rt; : > map
mkinst() { # id type [egress]
    id=$1; t=$2; eg=${3:-}; port=$((port + 1))
    {
        printf 'id=%s\nname=%s\ntype=%s\nenabled=true\nlisten=127.0.0.1\nlisten_port=%s\n' "$id" "$id" "$t" "$port"
        case $t in
            shadowsocks) printf 'credential.method=2022-blake3-aes-128-gcm\ncredential.password=%s\ntransport.type=tcp+udp\n' "$K16" ;;
            *) printf 'credential.password=%s\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=%s\ntls.key_path=%s\n' "$PSK" "$W/cert.pem" "$W/key.pem" ;;
        esac
        [ -z "$eg" ] || printf 'egress_socks=%s\n' "$eg"
    } > "inst/$id.conf"
    case $t in
        anytls) ob="{\"type\":\"anytls\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
        shadowsocks) ob="{\"type\":\"shadowsocks\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$K16\"}" ;;
    esac
    printf '%s,' "$ob" >> cli.out
    for kind in tcp dom udp; do
        [ "$kind" != udp ] || [ "$t" = shadowsocks ] || continue
        cport=$((cport + 1))
        case $kind in
            tcp) ov='"override_address":"127.0.0.1","override_port":24001' ;;
            dom) ov='"override_address":"target.test","override_port":24001' ;;
            udp) ov='"network":"udp","override_address":"127.0.0.1","override_port":24002' ;;
        esac
        printf '{"type":"direct","tag":"i-%s-%s","listen":"127.0.0.1","listen_port":%s,%s},' "$id" "$kind" "$cport" "$ov" >> cli.in
        printf '{"inbound":["i-%s-%s"],"action":"route","outbound":"o-%s"},' "$id" "$kind" "$id" >> cli.rt
        printf '%s %s %s\n' "$id" "$kind" "$cport" >> map
    done
}
mkinst AnyTLS-01 anytls SOCKS-01
[ "$HAVE_PRIV" != yes ] || mkinst AnyTLS-02 anytls SOCKS-02
[ "$HAVE_V6" != yes ] || mkinst AnyTLS-03 anytls SOCKS-03
mkinst AnyTLS-04 anytls
mkinst AnyTLS-05 anytls SOCKS-04
mkinst AnyTLS-06 anytls SOCKS-05
mkinst Shadowsocks-01 shadowsocks SOCKS-01
mkinst Shadowsocks-02 shadowsocks SOCKS-04
mkinst Shadowsocks-03 shadowsocks
sb_generate_config inst > server.json
"$B" check -c server.json
{
    printf '{"log":{"level":"error"},"inbounds":['
    sed 's/,$//' cli.in
    printf '],"outbounds":['
    cat cli.out
    printf '{"type":"direct","tag":"direct"}],"route":{"rules":['
    sed 's/,$//' cli.rt
    printf ']}}\n'
} > client.json
"$B" check -c client.json
echo "Manager 生成的服务端配置与客户端配置 check 通过 $VER"
"$B" run -c server.json > server.log 2>&1 &
sleep 2
"$B" run -c client.json > client.log 2>&1 &
sleep 3

probe() { # kind port id
    case $1 in
        udp)
            python3 - "$2" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4); s.sendto(b"U-" + sys.argv[1].encode(), ("127.0.0.1", int(sys.argv[1])))
try:
    print(s.recv(100).decode().strip())
except Exception:
    print("none")
PY
            ;;
        *) (printf 'T-%s-%s\n' "$3" "$1"; sleep 1) | nc -w 4 127.0.0.1 "$2" 2>/dev/null | head -c 20 | tr -d '\n'; echo ;;
    esac
}
peer() { # 标记 -> 对端地址, 没有记录输出 none
    grep "line=T-$1\$" target.log | head -n 1 | sed 's/^TCP peer=\([^ ]*\) .*/\1/' | grep . || echo none
}
echo "== 阶段 1 基线探测"
RES=
while read -r id kind cp; do
    r=$(probe "$kind" "$cp" "$id")
    printf '%s %s %s\n' "$id" "$kind" "$r" >> res.txt
done < map
sleep 1
getr() { awk -v i="$1" -v k="$2" '$1 == i && $2 == k { $1 = ""; $2 = ""; sub(/^  /, ""); print }' res.txt; }

echo "-- TCP 流量路径 (127.0.0.77 = 经过上游 SOCKS)"
expect "本机 SOCKS 带认证: TCP 经过上游" 127.0.0.77 "$(peer AnyTLS-01-tcp)"
expect "本机 SOCKS 带认证: 域名目标经过上游" 127.0.0.77 "$(peer AnyTLS-01-dom)"
if [ "$HAVE_PRIV" = yes ]; then
    expect "内网地址 SOCKS 无认证: TCP 经过上游" 127.0.0.77 "$(peer AnyTLS-02-tcp)"
else skip "内网地址 SOCKS (容器没有给 lo 添加地址的权限)"; fi
if [ "$HAVE_V6" = yes ]; then
    expect "IPv6 SOCKS 带认证: TCP 经过上游" 127.0.0.77 "$(peer AnyTLS-03-tcp)"
else skip "IPv6 SOCKS (容器没有给 lo 添加 IPv6 地址的权限)"; fi
expect "主机名形式的 SOCKS 服务器: TCP 经过上游" 127.0.0.77 "$(peer AnyTLS-06-tcp)"
expect "对照: 没有绑定出口的实例直连" 127.0.0.1 "$(peer AnyTLS-04-tcp)"
expect "只支持 TCP 的上游 (dante): TCP 经过上游" 127.0.0.77 "$(peer AnyTLS-05-tcp)"
expect "Shadowsocks 经过上游: TCP" 127.0.0.77 "$(peer Shadowsocks-01-tcp)"

echo "-- DNS: 域名目标原样交给上游, 由上游解析"
if grep -q 'inbound connection to target.test:24001' up-U1.log; then ok "上游 SOCKS 收到的是域名 target.test, 不是服务器解析后的 IP"; else bad "上游没有收到域名"; fi
if grep -q 'inbound connection to 127.0.0.1:24001' up-U1.log; then ok "IP 目标原样到达上游"; else bad "上游没有收到 IP 目标"; fi

echo "-- UDP"
case $(getr Shadowsocks-01 udp) in "UDP_OK "*) ok "UDP 经 SOCKS5 UDP ASSOCIATE 到达目标并返回" ;; *) bad "UDP 没有返回: $(getr Shadowsocks-01 udp)" ;; esac
expect "UDP 经过上游 (目标看到上游地址)" 127.0.0.77 "$(grep 'UDP peer=.* data=U-' target.log | head -n 1 | sed 's/^UDP peer=\([^ ]*\) .*/\1/')"
expect "上游 (dante) 不支持 UDP: 客户端收不到回复" none "$(getr Shadowsocks-02 udp)"
cp2=$(awk '$1 == "Shadowsocks-02" && $2 == "udp" { print $3 }' map)
expect "上游不支持 UDP 时目标没有收到 Shadowsocks-02 的 UDP 包 (没有直连泄漏)" 0 "$(grep -c "data=U-$cp2\$" target.log)"
case $(getr Shadowsocks-03 udp) in "UDP_OK "*) ok "对照: 没有绑定出口的实例 UDP 直连可用" ;; *) bad "对照 UDP 不可用" ;; esac

echo "== 阶段 2 故障: 停止上游 U1 后, 绑定它的实例不能回落直连"
pkill -f "up-U1.json"
sleep 1
n0=$(wc -l < target.log)
for k in "AnyTLS-01 tcp" "AnyTLS-01 dom" "AnyTLS-06 tcp" "Shadowsocks-01 tcp"; do
    # shellcheck disable=SC2086
    set -- $k
    cp=$(awk -v i="$1" -v kk="$2" '$1 == i && $2 == kk { print $3 }' map)
    r=$(probe "$2" "$cp" "$1")
    expect "上游停止: $1 $2 失败" "" "$r"
done
cp=$(awk '$1 == "Shadowsocks-01" && $2 == "udp" { print $3 }' map)
expect "上游停止: Shadowsocks-01 UDP 失败" none "$(probe udp "$cp" Shadowsocks-01)"
sleep 1
expect "上游停止后目标没有收到任何新请求 (没有直连兜底)" 0 "$(( $(wc -l < target.log) - n0 ))"

printf '\n通过 %s 失败 %s 跳过 %s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
