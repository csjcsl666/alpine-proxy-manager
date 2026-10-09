#!/bin/sh
# 在 Alpine 容器里从上游源码构建打过补丁的 graftcp (静态 musl 二进制)
# 用法: sh third_party/graftcp/build.sh 输出目录 [alpine 镜像标签, 默认 3.24]
# 需要 docker 或 podman 以及网络; 输出 graftcp-v0.8.3-apm1-linux-x86_64 与 .sha256, BUILDINFO, 以及对应源码包
set -eu

OUT=${1:?用法: build.sh 输出目录 [alpine标签]}
ALPINE=${2:-3.24}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
RT=$(command -v docker || command -v podman) || { echo "需要 docker 或 podman" >&2; exit 1; }

"$RT" run --rm -v "$HERE:/in:ro" -v "$OUT:/out" "alpine:$ALPINE" sh -eu -c '
apk add --no-cache git go gcc musl-dev make linux-headers patch >/dev/null
sh /in/build-inner.sh /out
'
echo "输出: $OUT"
cat "$OUT"/graftcp-*-linux-x86_64.sha256
