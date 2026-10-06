#!/bin/sh
# 官方 sing-box release 上的目标访问限制 (Relay Access Policy) 真实流量验证, 需要网络, 在 Alpine 容器内运行
# 用 Manager 自己的生成器为四种协议各生成 不限制 与 allowlist 两个实例, 真实运行 sing-box,
# 再用第二个 sing-box 作为客户端经每个入站连接本机两个目标 A 与 B, 只有 allowlist 实例的 B 必须被拒绝
# 全部在 127.0.0.1 上完成, 不开放任何公网端口, 不属于 tests/run.sh
set -eu

VER=${1:-1.13.14}
HERE=$(cd "$(dirname "$0")" && pwd)
case "$VER/$(uname -m)" in
    1.13.14/x86_64) SHA=d5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34; ARCH=amd64 ;;
    1.13.14/aarch64) SHA=edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118; ARCH=arm64 ;;
    1.14.2/x86_64) SHA=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297; ARCH=amd64 ;;
    *) echo "没有内置的校验和: $VER $(uname -m)" >&2; exit 1 ;;
esac
ASSET="sing-box-$VER-linux-$ARCH-musl.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v$VER/$ASSET"
W=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$W"' EXIT

n=1
while [ "$n" -le 3 ]; do
    if wget -q -T 60 -O "$W/sb.tgz" "$URL" && [ -s "$W/sb.tgz" ]; then break; fi
    n=$((n + 1))
    sleep 3
done
[ -s "$W/sb.tgz" ] || { echo "下载失败: $URL" >&2; exit 1; }
[ "$(sha256sum "$W/sb.tgz" | awk '{ print $1 }')" = "$SHA" ] || { echo "sha256 不匹配" >&2; exit 1; }
tar -xzf "$W/sb.tgz" -C "$W" "sing-box-$VER-linux-$ARCH-musl/sing-box"
rm -f "$W/sb.tgz"
B="$W/sing-box-$VER-linux-$ARCH-musl/sing-box"
chmod 755 "$B"
"$B" version | head -n 1 | grep -q "sing-box version $VER" || { echo "自报版本不符" >&2; exit 1; }

"$B" generate tls-keypair apm.local -m 12 > "$W/kp.pem"
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$W/kp.pem" > "$W/key.pem"
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$W/kp.pem" > "$W/cert.pem"

# 加载 Manager 的生成器
APM_HOME=$(dirname "$HERE")
export APM_HOME
for m in common environment state core model policy txn report snell singbox; do
    # shellcheck source=/dev/null
    . "$APM_HOME/lib/$m.sh"
done

TA=24001
TB=24002
UUID=11111111-2222-4333-8444-555555555555
PSK=SmokeRelayPasswordNotSecret0123456789
K16=AAAAAAAAAAAAAAAAAAAAAA==
mkdir -p "$W/inst"
port=22000
cport=23000
: > "$W/cli.in"
: > "$W/cli.out"
: > "$W/cli.rt"
: > "$W/expect"
for t in anytls hysteria2 tuic shadowsocks; do
    case $t in anytls) P=AnyTLS ;; hysteria2) P=Hysteria2 ;; tuic) P=TUIC ;; shadowsocks) P=Shadowsocks ;; esac
    for k in 01 02; do
        id=$P-$k
        port=$((port + 1))
        {
            printf 'id=%s\nname=%s\ntype=%s\nenabled=true\nlisten=127.0.0.1\nlisten_port=%s\n' "$id" "$id" "$t" "$port"
            case $t in
                tuic) printf 'credential.uuid=%s\ncredential.password=%s\n' "$UUID" "$PSK" ;;
                shadowsocks) printf 'credential.method=2022-blake3-aes-128-gcm\ncredential.password=%s\ntransport.type=tcp+udp\n' "$K16" ;;
                *) printf 'credential.password=%s\n' "$PSK" ;;
            esac
            if [ "$t" != shadowsocks ]; then
                printf 'tls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=%s\ntls.key_path=%s\n' "$W/cert.pem" "$W/key.pem"
            fi
            if [ "$k" = 02 ]; then
                printf 'relay_access.enabled=true\nrelay_access.mode=allowlist\nrelay_access.default_action=reject\nrelay_access.destination.1=127.0.0.1:%s\n' "$TA"
            fi
        } > "$W/inst/$id.conf"
        # 客户端: 每个服务端实例一个出站, 两个本地入口分别转发到目标 A 与 B
        case $t in
            anytls) ob="{\"type\":\"anytls\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            hysteria2) ob="{\"type\":\"hysteria2\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            tuic) ob="{\"type\":\"tuic\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"uuid\":\"$UUID\",\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            shadowsocks) ob="{\"type\":\"shadowsocks\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$K16\"}" ;;
        esac
        printf '%s,' "$ob" >> "$W/cli.out"
        for tgt in A B; do
            cport=$((cport + 1))
            [ "$tgt" = A ] && tp=$TA || tp=$TB
            printf '{"type":"direct","tag":"i-%s-%s","listen":"127.0.0.1","listen_port":%s,"override_address":"127.0.0.1","override_port":%s},' "$id" "$tgt" "$cport" "$tp" >> "$W/cli.in"
            printf '{"inbound":["i-%s-%s"],"action":"route","outbound":"o-%s"},' "$id" "$tgt" "$id" >> "$W/cli.rt"
            if [ "$k" = 02 ] && [ "$tgt" = B ]; then want=reject; else want=ok; fi
            printf '%s %s %s %s\n' "$id" "$tgt" "$cport" "$want" >> "$W/expect"
        done
    done
done
sb_generate_config "$W/inst" > "$W/server.json"
grep -q '"route"' "$W/server.json" || { echo "生成的配置没有 route" >&2; exit 1; }
"$B" check -c "$W/server.json"
echo "Manager 生成的四协议八实例配置 check 通过 $VER"
# 客户端配置: 逗号结尾去掉, 用一个 direct 出站占位避免空列表问题
{
    printf '{"log":{"level":"error"},"inbounds":['
    sed 's/,$//' "$W/cli.in"
    printf '],"outbounds":['
    cat "$W/cli.out"
    printf '{"type":"direct","tag":"direct"}],"route":{"rules":['
    sed 's/,$//' "$W/cli.rt"
    printf ']}}\n'
} > "$W/client.json"
"$B" check -c "$W/client.json"

( while :; do echo TARGET_A | nc -l -p "$TA" -s 127.0.0.1 >/dev/null 2>&1 || sleep 1; done ) &
PIDS="$!"
( while :; do echo TARGET_B | nc -l -p "$TB" -s 127.0.0.1 >/dev/null 2>&1 || sleep 1; done ) &
PIDS="$PIDS $!"
"$B" run -c "$W/server.json" > "$W/server.log" 2>&1 &
PIDS="$PIDS $!"
sleep 2
"$B" run -c "$W/client.json" > "$W/client.log" 2>&1 &
PIDS="$PIDS $!"
sleep 4
fail=0
while read -r id tgt cp want; do
    got=$( (echo ping; sleep 2) | nc -w 5 127.0.0.1 "$cp" 2>/dev/null | head -c 20 || true)
    want_txt=TARGET_$tgt
    if [ "$want" = ok ]; then
        if [ "$got" = "$want_txt" ]; then r=PASS; else r=FAIL; fail=1; fi
    else
        if [ -z "$got" ]; then r=PASS; else r=FAIL; fail=1; fi
    fi
    printf '%s %-14s 目标 %s 期望 %-6s 实际 [%s]\n' "$r" "$id" "$tgt" "$want" "$got"
done < "$W/expect"
if [ "$fail" -ne 0 ]; then
    echo "--- server.log" >&2; tail -20 "$W/server.log" >&2
    echo "--- client.log" >&2; tail -20 "$W/client.log" >&2
    exit 1
fi
echo "官方 sing-box $VER 目标访问限制真实流量测试通过"
