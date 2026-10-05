#!/bin/sh
# 在 Alpine 容器内执行: 语法检查, shellcheck, 测试
# 源码以只读方式挂载在 /src, 测试不得写入源码目录
set -eu
cd /src

apk add --no-cache shellcheck git >/dev/null
printf 'Alpine %s, shellcheck %s\n' "$(cat /etc/alpine-release)" "$(shellcheck --version | sed -n 's/^version: //p')"

echo '== sh -n'
for f in bin/proxy-manager install.sh lib/*.sh tests/*.sh; do
    sh -n "$f"
done

echo '== shellcheck'
shellcheck -x -P lib bin/proxy-manager install.sh lib/*.sh tests/*.sh

echo '== tests'
sh tests/run.sh
