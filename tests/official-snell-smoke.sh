#!/bin/sh
# 官方 Snell release 的真实 smoke test, 需要网络, 在 Alpine 容器内运行
# 下载官方 zip, 解压, 确认是 ELF, 运行 -v 并检查输出
# 不属于 tests/run.sh, 单元测试不依赖网络, 由 CI 单独的 job 执行
set -eu

TAG=${1:-v6.0.0rc2}
apk add --no-cache gcompat libstdc++ libgcc unzip wget >/dev/null

case $(uname -m) in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=aarch64 ;;
    *) echo "不支持的架构 $(uname -m)" >&2; exit 1 ;;
esac
URL="https://dl.nssurge.com/snell/snell-server-$TAG-linux-$ARCH.zip"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

n=1
while [ "$n" -le 3 ]; do
    if wget -q -T 30 -O "$W/snell.zip" "$URL" && [ -s "$W/snell.zip" ]; then
        break
    fi
    n=$((n + 1))
    sleep 3
done
[ -s "$W/snell.zip" ] || { echo "下载失败: $URL" >&2; exit 1; }
echo "zip $(wc -c < "$W/snell.zip") 字节 sha256 $(sha256sum "$W/snell.zip" | awk '{ print $1 }')"

unzip -o -q "$W/snell.zip" snell-server -d "$W"
magic=$(head -c 4 "$W/snell-server" | od -An -tx1 | tr -d ' \n')
[ "$magic" = 7f454c46 ] || { echo "不是 ELF: $magic" >&2; exit 1; }
chmod 755 "$W/snell-server"
out=$("$W/snell-server" -v 2>&1 | head -n 3)
echo "$out"
printf '%s\n' "$out" | grep -Eq 'snell-server v6\.[0-9]+\.[0-9]+' || { echo "-v 输出不符合预期" >&2; exit 1; }
echo "官方 $TAG smoke test 通过"
