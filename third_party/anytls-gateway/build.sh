#!/bin/sh
# 在 Alpine 容器里构建 anytls-socks-gateway
# 用法: sh third_party/anytls-gateway/build.sh 输出目录 [alpine 镜像标签, 默认 3.24]
set -eu

OUT=${1:?用法: build.sh 输出目录 [alpine标签]}
ALPINE=${2:-3.24}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
RT=$(command -v docker || command -v podman) || { echo "需要 docker 或 podman" >&2; exit 1; }

"$RT" run --rm -v "$HERE:/in:ro" -v "$OUT:/out" "alpine:$ALPINE" sh -eu -c '
apk add --no-cache go >/dev/null
sh /in/build-inner.sh /out
'
echo "输出: $OUT"
cat "$OUT"/anytls-socks-gateway-*-linux-x86_64.sha256
