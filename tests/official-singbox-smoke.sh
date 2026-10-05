#!/bin/sh
# 官方 sing-box release 的真实 smoke test, 需要网络, 在 Alpine 容器内运行
# 下载官方 musl 构建, 核对 sha256, 只解压 sing-box, 确认 ELF, version, 生成自签名证书,
# 用最小的 AnyTLS 配置执行 check, 并实际运行几秒确认监听与内存
# 不属于 tests/run.sh, 单元测试不依赖网络, 由 CI 单独的 job 执行
set -eu

VER=${1:-1.13.14}
# 与 lib/singbox.sh 里内置的校验和一致, 来自 GitHub 发布页资产 digest
case "$VER/$(uname -m)" in
    1.13.14/x86_64) SHA=d5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34; ARCH=amd64 ;;
    1.13.14/aarch64) SHA=edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118; ARCH=arm64 ;;
    1.14.2/x86_64) SHA=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297; ARCH=amd64 ;;
    *) echo "没有内置的校验和: $VER $(uname -m)" >&2; exit 1 ;;
esac
ASSET="sing-box-$VER-linux-$ARCH-musl.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v$VER/$ASSET"
W=$(mktemp -d)
trap 'kill "${PID:-0}" 2>/dev/null; rm -rf "$W"' EXIT

n=1
while [ "$n" -le 3 ]; do
    if wget -q -T 60 -O "$W/sb.tgz" "$URL" && [ -s "$W/sb.tgz" ]; then break; fi
    n=$((n + 1))
    sleep 3
done
[ -s "$W/sb.tgz" ] || { echo "下载失败: $URL" >&2; exit 1; }
echo "归档 $(wc -c < "$W/sb.tgz") 字节"
[ "$(sha256sum "$W/sb.tgz" | awk '{ print $1 }')" = "$SHA" ] || { echo "sha256 不匹配" >&2; exit 1; }
tar -xzf "$W/sb.tgz" -C "$W" "sing-box-$VER-linux-$ARCH-musl/sing-box"
rm -f "$W/sb.tgz"
B="$W/sing-box-$VER-linux-$ARCH-musl/sing-box"
echo "解压后 $(wc -c < "$B") 字节"
[ "$(head -c 4 "$B" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || { echo "不是 ELF" >&2; exit 1; }
chmod 755 "$B"
"$B" version | head -n 1
"$B" version | head -n 1 | grep -q "sing-box version $VER" || { echo "自报版本不符" >&2; exit 1; }

"$B" generate tls-keypair apm.local -m 12 > "$W/kp.pem"
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$W/kp.pem" > "$W/key.pem"
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$W/kp.pem" > "$W/cert.pem"
if [ ! -s "$W/key.pem" ] || [ ! -s "$W/cert.pem" ]; then
    echo "证书生成失败" >&2
    exit 1
fi
cat > "$W/config.json" <<EOC
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "anytls",
      "tag": "AnyTLS-01",
      "listen": "127.0.0.1",
      "listen_port": 20443,
      "users": [{"password": "SmokeTestPasswordNotSecret0123456789"}],
      "tls": {"enabled": true, "certificate_path": "$W/cert.pem", "key_path": "$W/key.pem"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOC
"$B" check -c "$W/config.json"
echo "最小 AnyTLS 配置 check 通过"
echo '{ not json' > "$W/bad.json"
if "$B" check -c "$W/bad.json" >/dev/null 2>&1; then echo "损坏的配置不应通过 check" >&2; exit 1; fi
echo "损坏的配置被 check 拒绝"
sed "s#$W/cert.pem#$W/missing.pem#" "$W/config.json" > "$W/nocert.json"
if "$B" check -c "$W/nocert.json" >/dev/null 2>&1; then echo "缺失证书不应通过 check" >&2; exit 1; fi
echo "缺失证书被 check 拒绝"

"$B" run -c "$W/config.json" > "$W/run.log" 2>&1 &
PID=$!
i=0
while [ "$i" -lt 10 ]; do
    grep -q ':4FDB ' /proc/net/tcp 2>/dev/null && break
    sleep 1
    i=$((i + 1))
done
grep -q ':4FDB ' /proc/net/tcp || { cat "$W/run.log" >&2; echo "20443 没有进入监听" >&2; exit 1; }
echo "20443 正在监听"
grep -E '^(VmRSS|VmHWM|Threads)' "/proc/$PID/status" | tr '\n\t' '  '
echo
kill "$PID"
echo "官方 sing-box $VER smoke test 通过"
