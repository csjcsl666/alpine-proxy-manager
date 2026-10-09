#!/bin/sh
# 在 Alpine 环境里构建 anytls-socks-gateway (静态 musl 无关 纯 Go, CGO 关闭), 由 build.sh 在容器里调用, CI 也直接调用
# 用法: sh build-inner.sh 输出目录
# 需要 go; 依赖由 go.sum 固定
set -eu

OUT=${1:?用法: build-inner.sh 输出目录}
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=v0.1.0
NAME=anytls-socks-gateway-$VERSION

mkdir -p "$OUT"
# 固定的构建目录 -trimpath 同一环境下重复构建得到相同的 SHA256
B=/tmp/apm-agw-build
rm -rf "$B"
mkdir -p "$B"
trap 'rm -rf "$B"' EXIT
cp "$HERE/main.go" "$HERE/go.mod" "$HERE/go.sum" "$B/"
cd "$B"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=local GOFLAGS=-trimpath \
    go build -ldflags "-s -w -buildid= -X main.version=$VERSION" -o "$OUT/$NAME-linux-x86_64" .
"$OUT/$NAME-linux-x86_64" -version
(cd "$OUT" && sha256sum "$NAME-linux-x86_64" > "$NAME-linux-x86_64.sha256")
{ echo "alpine $(cat /etc/alpine-release 2>/dev/null || echo unknown)"; go version; } > "$OUT/BUILDINFO"
# 对应源码: 源文件 依赖锁定文件 许可证 构建脚本
S=$B/$NAME-source
mkdir -p "$S"
cp "$HERE"/main.go "$HERE"/go.mod "$HERE"/go.sum "$HERE"/COPYING "$HERE"/THIRD_PARTY_LICENSES.txt "$HERE"/README.md "$HERE"/build.sh "$HERE"/build-inner.sh "$S/"
tar -C "$B" -czf "$OUT/$NAME-source.tar.gz" "$NAME-source"
