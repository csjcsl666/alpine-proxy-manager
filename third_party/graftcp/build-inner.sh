#!/bin/sh
# 在 Alpine 环境里构建打过补丁的 graftcp, 由 build.sh 在容器里调用, CI 也直接调用
# 用法: sh build-inner.sh 输出目录
# 需要 git go gcc musl-dev make linux-headers patch; 补丁取自本脚本所在目录
set -eu

OUT=${1:?用法: build-inner.sh 输出目录}
HERE=$(cd "$(dirname "$0")" && pwd)
UPSTREAM_REPO=https://github.com/hmgle/graftcp.git
UPSTREAM_TAG=v0.8.3
UPSTREAM_COMMIT=825cf6d3b9ec043defe8e598eb218eccc1a3eaf3
VERSION=v0.8.3-apm1
NAME=graftcp-$VERSION

mkdir -p "$OUT"
# 固定的构建目录和 -trimpath, 二进制里不带随机路径, 同一环境下重复构建得到相同的 SHA256
B=/tmp/apm-graftcp-build
rm -rf "$B"
mkdir -p "$B"
trap 'rm -rf "$B"' EXIT
export GOFLAGS=-trimpath CGO_CFLAGS="-O2 -ffile-prefix-map=$B=." SOURCE_DATE_EPOCH=1760000000
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$B/src"
cd "$B/src"
[ "$(git rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || { echo "上游提交与预期不符" >&2; exit 1; }
patch -p1 < "$HERE/0001-exact-endpoint-exemption.patch"
GO_LDFLAGS="-s -w -linkmode external -extldflags -static" make VERSION="$VERSION" >/dev/null
./local/graftcp --version
cp local/graftcp "$OUT/$NAME-linux-x86_64"
(cd "$OUT" && sha256sum "$NAME-linux-x86_64" > "$NAME-linux-x86_64.sha256")
rm -rf .git local/.cache .gomodcache
{ echo "alpine $(cat /etc/alpine-release)"; go version; gcc --version | head -n 1; } > "$OUT/BUILDINFO"
# 对应源码: 补丁后的完整源码树, 发布二进制时一起发布
mv "$B/src" "$B/$NAME-source"
tar -C "$B" -czf "$OUT/$NAME-source.tar.gz" "$NAME-source"
