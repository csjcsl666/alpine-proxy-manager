#!/bin/sh
# 从当前源码目录安装 proxy-manager 本身, 不下载任何内容, 不安装 Snell 或 sing-box
#
# 用法:
#   sh install.sh              安装到 /usr/local/lib/alpine-proxy-manager
#   sh install.sh --uninstall  卸载程序本体, 不删除 /etc/alpine-proxy-manager 中的配置
#
# 覆盖变量: APM_PREFIX 安装目录, APM_BINDIR 命令链接目录

set -u

src=$(cd "$(dirname "$0")" && pwd) || exit 1
prefix=${APM_PREFIX:-/usr/local/lib/alpine-proxy-manager}
bindir=${APM_BINDIR:-/usr/local/bin}
link=$bindir/proxy-manager

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# 递归删除前的保护: 目录名必须是 alpine-proxy-manager
guard_prefix() {
    case $prefix in
        /|'') die "不安全的安装目录: '$prefix'" ;;
        */alpine-proxy-manager) ;;
        *) die "安装目录必须以 alpine-proxy-manager 结尾: $prefix" ;;
    esac
}

if [ "$(id -u)" != 0 ] && [ -z "${APM_PREFIX:-}" ]; then
    die "需要 root 权限"
fi

case ${1:-install} in
    install)
        guard_prefix
        if [ ! -r "$src/VERSION" ] || [ ! -x "$src/bin/proxy-manager" ]; then
            die "$src 不是有效的源码目录"
        fi
        build=
        if command -v git >/dev/null 2>&1 && [ -e "$src/.git" ]; then
            build=$(git -c safe.directory='*' -C "$src" rev-parse --short HEAD 2>/dev/null) || build=
        fi
        tmp=$prefix.new.$$
        rm -rf -- "$tmp"
        mkdir -p -- "$tmp" "$bindir" || die "无法创建目录"
        cp -R -- "$src/bin" "$src/lib" "$src/VERSION" "$tmp/" || { rm -rf -- "$tmp"; die "复制失败"; }
        [ -z "$build" ] || printf '%s\n' "$build" > "$tmp/BUILD"
        rm -rf -- "$prefix"
        mv -- "$tmp" "$prefix" || die "无法写入 $prefix"
        ln -sf -- "$prefix/bin/proxy-manager" "$link" || die "无法创建 $link"
        printf '已安装到 %s\n' "$prefix"
        "$link" --version
        ;;
    --uninstall)
        guard_prefix
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$prefix/bin/proxy-manager" ]; then
            rm -f -- "$link"
        fi
        rm -rf -- "$prefix"
        printf '已卸载 %s, 配置目录未改动\n' "$prefix"
        ;;
    *) die "未知参数: $1" ;;
esac
