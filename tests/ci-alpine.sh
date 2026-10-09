#!/bin/sh
# 在 Alpine 容器内执行: 语法检查, shellcheck, 测试
# 源码以只读方式挂载在 /src, 测试不得写入源码目录
set -eu
cd /src

# util-linux-misc 提供 script, 只用于测试里分配伪终端 (apm 的 TTY 行为)
# tmux 是真实终端模拟器, 只用于测试主菜单内存刷新的光标行为, Manager 本身不依赖它
apk add --no-cache shellcheck git util-linux-misc tmux >/dev/null
printf 'Alpine %s, shellcheck %s\n' "$(cat /etc/alpine-release)" "$(shellcheck --version | sed -n 's/^version: //p')"

echo '== sh -n'
for f in bin/proxy-manager install.sh lib/*.sh tests/*.sh tests/e2e/*.sh third_party/graftcp/*.sh; do
    sh -n "$f"
done

echo '== shellcheck'
shellcheck -x -P lib bin/proxy-manager install.sh lib/*.sh tests/*.sh tests/e2e/*.sh third_party/graftcp/*.sh

echo '== tests'
sh tests/run.sh
