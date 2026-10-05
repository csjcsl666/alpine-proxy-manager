#!/bin/sh
# Alpine Proxy Manager 安装器 (Bootstrap)
#
# 一条命令安装:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)"
# 卸载 (只删除 Manager 自己, 不动 Snell, sing-box 与任何配置):
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)" -- --uninstall
#
# 本脚本可能通过 sh -c "$(...)" 或管道从 stdin 执行, 因此:
#   - 不依赖 $0, 当前目录或已 clone 的仓库
#   - 所有逻辑都在函数中, 最后一行才调用 apm_main, 下载被截断时只会得到未完成的函数定义而不会执行安装
#
# 选项:
#   --uninstall     卸载 Manager 本体
#   --force         即使 Build 相同也重新安装
#   --from-dir DIR  开发者用: 从本地源码目录安装而不下载 (需要 git 以确定 Build)
#   -h, --help      显示帮助
#
# 环境变量:
#   APM_REPO     GitHub 仓库, 默认 csjcsl666/alpine-proxy-manager
#   APM_REF      分支, tag 或 commit, 默认 main
#   APM_SHA256   可选, 期望的归档 sha256, 不匹配则拒绝安装
#   APM_ROOT     安装根目录, 默认 /, 测试用
#   APM_VERBOSE  设为 1 时输出下载与磁盘占用
#   以下仅供测试: APM_ARCHIVE_URL APM_DOWNLOADER APM_SYSROOT APM_EUID APM_ARCH
#                 APM_MIN_FREE_KIB APM_DOWNLOAD_TRIES APM_FAULT

APM_DEFAULT_REPO="csjcsl666/alpine-proxy-manager"
APM_DEFAULT_REF="main"
APM_DEFAULT_MIN_FREE_KIB=10240

say() { printf '%s\n' "$*"; }
err() { printf '错误: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
verbose() { [ "${APM_VERBOSE:-0}" = 1 ] && printf '  %s\n' "$*"; return 0; }

first_line() {
    local _l
    _l=
    [ -r "$1" ] || return 1
    IFS= read -r _l < "$1" || :
    printf '%s' "$_l"
}

usage() {
    cat <<'EOF'
用法: install.sh [--uninstall] [--force] [--from-dir DIR]

  (无参数)        安装或升级 Alpine Proxy Manager
  --uninstall     卸载 Manager 本体, 不删除 Snell, sing-box 与配置
  --force         即使 Build 相同也重新安装
  --from-dir DIR  从本地源码目录安装 (开发者)

环境变量 APM_REF 可指定分支, tag 或 commit, 默认 main
EOF
}

setup_paths() {
    ROOT=${APM_ROOT:-}
    ROOT=${ROOT%/}
    SYSROOT=${APM_SYSROOT:-}
    SYSROOT=${SYSROOT%/}
    LIBPARENT=$ROOT/usr/local/lib
    LIB=$LIBPARENT/alpine-proxy-manager
    BINDIR=$ROOT/usr/local/bin
    LINK=$BINDIR/proxy-manager
    # 相对符号链接, 在任何根目录下都有效
    LINK_TARGET=../lib/alpine-proxy-manager/current/bin/proxy-manager
    LOCKDIR=$LIBPARENT/.alpine-proxy-manager.lock
    REPO=${APM_REPO:-$APM_DEFAULT_REPO}
    REF=${APM_REF:-$APM_DEFAULT_REF}
    ARCHIVE_URL=${APM_ARCHIVE_URL:-https://codeload.github.com/$REPO/tar.gz/$REF}
    DOWNLOADER=${APM_DOWNLOADER:-wget}
    STAGING=
    LOCKED=0
    CREATED_LIB=0
}

validate_source_params() {
    printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || die "APM_REPO 格式无效: $REPO"
    printf '%s' "$REF" | grep -Eq '^[A-Za-z0-9._/-]+$' || die "APM_REF 格式无效: $REF"
}

cleanup() {
    [ -n "$STAGING" ] && rm -rf -- "$STAGING"
    if [ "$LOCKED" = 1 ]; then
        rm -rf -- "$LOCKDIR"
        LOCKED=0
    fi
    return 0
}

# ---- 环境检查 ----

check_alpine() {
    local _rel _os
    _rel=$SYSROOT/etc/alpine-release
    _os=$SYSROOT/etc/os-release
    if [ ! -r "$_rel" ] || { [ -r "$_os" ] && ! grep -Eq '^ID="?alpine"?$' "$_os"; }; then
        die "Alpine Proxy Manager 当前仅支持 Alpine Linux。"
    fi
}

check_root() {
    local _u
    _u=${APM_EUID:-$(id -u)}
    [ "$_u" = 0 ] || die "请使用 root 运行安装命令。(Alpine 小 VPS 通常没有 sudo, 不会自动提权)"
}

check_tools() {
    local _t _missing
    _missing=
    for _t in tar gzip sha256sum mktemp df awk sed grep head cut sort tr id readlink ln mv rm cp mkdir chmod du wc date; do
        command -v "$_t" >/dev/null 2>&1 || _missing="$_missing $_t"
    done
    if [ "$1" = download ]; then
        command -v "$DOWNLOADER" >/dev/null 2>&1 || _missing="$_missing $DOWNLOADER"
    fi
    [ -z "$_missing" ] || die "缺少必需工具:$_missing (可执行 apk add busybox wget 后重试)"
}

# 输出最近的已存在祖先目录
existing_ancestor() {
    local _d
    _d=$1
    while [ ! -d "$_d" ] && [ "$_d" != / ] && [ -n "$_d" ]; do
        _d=${_d%/*}
    done
    printf '%s' "${_d:-/}"
}

check_disk() {
    local _need _avail _d
    _need=${APM_MIN_FREE_KIB:-$APM_DEFAULT_MIN_FREE_KIB}
    _d=$(existing_ancestor "$LIBPARENT")
    _avail=$(df -Pk "$_d" 2>/dev/null | awk 'NR == 2 { print $4 }')
    case $_avail in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$_avail" -lt "$_need" ]; then
        die "磁盘空间不足: $_d 可用 ${_avail} KiB, 至少需要 ${_need} KiB"
    fi
}

# 只提示, 不阻止安装
note_memory() {
    local _lim _f
    for _f in "$SYSROOT/sys/fs/cgroup/memory.max" "$SYSROOT/sys/fs/cgroup/memory/memory.limit_in_bytes"; do
        [ -r "$_f" ] || continue
        _lim=$(first_line "$_f")
        case $_lim in
            ''|max|*[!0-9]*) return 0 ;;
        esac
        [ "${#_lim}" -le 18 ] || return 0
        if [ "$_lim" -lt $((64 * 1048576)) ]; then
            say "提示: 检测到内存上限 $((_lim / 1048576)) MiB, 低于 64 MiB 基线, 安装本身仍可继续"
        fi
        return 0
    done
    return 0
}

acquire_lock() {
    local _pid
    mkdir -p -- "$LIBPARENT" || die "无法创建 $LIBPARENT"
    if ! mkdir -- "$LOCKDIR" 2>/dev/null; then
        _pid=$(first_line "$LOCKDIR/pid" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            die "另一个安装进程正在运行 (pid $_pid)"
        fi
        rm -rf -- "$LOCKDIR"
        mkdir -- "$LOCKDIR" 2>/dev/null || die "无法获取安装锁: $LOCKDIR"
    fi
    LOCKED=1
    printf '%s\n' "$$" > "$LOCKDIR/pid"
}

# ---- 下载与源码处理 ----

fetch() {
    local _url _dest _tries _n
    _url=$1
    _dest=$2
    _tries=${APM_DOWNLOAD_TRIES:-3}
    _n=1
    while [ "$_n" -le "$_tries" ]; do
        rm -f -- "$_dest"
        if "$DOWNLOADER" -q -T 30 -O "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]; then
            return 0
        fi
        [ "$_n" -lt "$_tries" ] && sleep 1
        _n=$((_n + 1))
    done
    rm -f -- "$_dest"
    return 1
}

# 从 GitHub archive 的 pax 全局头读取该归档对应的完整 commit SHA
# 与归档内容同源, 不存在先查 API 再下载之间 ref 移动的竞态
archive_commit() {
    gzip -dc < "$1" 2>/dev/null | head -c 4096 | grep -a -o 'comment=[0-9a-f]\{40\}' | head -n 1 | sed 's/^comment=//'
}

# 下载并解压归档, 设置 SRC_DIR FULL_SHA ARCHIVE_SHA256 ARCHIVE_BYTES SRC_DESC
obtain_archive() {
    local _f _list _tops _got
    _f=$STAGING/src.tar.gz
    _list=$STAGING/src.list
    say "正在下载 $REPO@$REF"
    fetch "$ARCHIVE_URL" "$_f" || die "下载失败: $ARCHIVE_URL (请检查网络, 以及 busybox wget 的 https 支持: apk add ssl_client ca-certificates)"
    ARCHIVE_BYTES=$(wc -c < "$_f" | tr -d ' ')
    gzip -t "$_f" 2>/dev/null || die "归档已损坏, 未安装任何内容"
    ARCHIVE_SHA256=$(sha256sum "$_f" | awk '{ print $1 }')
    if [ -n "${APM_SHA256:-}" ] && [ "$APM_SHA256" != "$ARCHIVE_SHA256" ]; then
        die "归档 sha256 不匹配: 期望 $APM_SHA256, 实际 $ARCHIVE_SHA256"
    fi
    FULL_SHA=$(archive_commit "$_f")
    [ -n "$FULL_SHA" ] || die "无法从归档确定 commit SHA, 拒绝安装 (Build 必须准确)"

    tar -tzf "$_f" > "$_list" 2>/dev/null || die "归档无法读取, 未安装任何内容"
    if grep -Eq '(^|/)\.\.(/|$)|^/' "$_list"; then
        die "归档包含不安全的路径, 拒绝安装"
    fi
    _tops=$(grep -v '^pax_global_header$' "$_list" | sed 's|/.*||' | sort -u | wc -l | tr -d ' ')
    [ "$_tops" = 1 ] || die "归档结构异常 (顶层目录数 $_tops)"

    mkdir -p -- "$STAGING/x"
    tar -xzf "$_f" -C "$STAGING/x" 2>/dev/null || die "解压失败, 未安装任何内容"
    SRC_DIR=
    for _got in "$STAGING"/x/*; do
        [ -d "$_got" ] && SRC_DIR=$_got
    done
    [ -n "$SRC_DIR" ] || die "归档中没有源码目录"
    SRC_DESC=$ARCHIVE_URL
    verbose "归档 ${ARCHIVE_BYTES} 字节 sha256 $ARCHIVE_SHA256"
    verbose "解压后 $(du -sk "$STAGING/x" | awk '{ print $1 }') KiB"
}

# 开发者安装: 从本地目录复制, Build 来自该目录的 git HEAD
obtain_local() {
    local _d _dirty
    _d=$1
    [ -d "$_d" ] || die "目录不存在: $_d"
    command -v git >/dev/null 2>&1 || die "--from-dir 需要 git 来确定 Build"
    FULL_SHA=$(git -c safe.directory='*' -C "$_d" rev-parse HEAD 2>/dev/null) || die "$_d 不是 git 仓库, 无法确定 Build"
    _dirty=$(git -c safe.directory='*' -C "$_d" status --porcelain 2>/dev/null | head -n 1)
    LOCAL_DIRTY=0
    [ -z "$_dirty" ] || LOCAL_DIRTY=1
    mkdir -p -- "$STAGING/x/src"
    cp -R -- "$_d/bin" "$_d/lib" "$_d/VERSION" "$STAGING/x/src/" || die "复制本地源码失败"
    SRC_DIR=$STAGING/x/src
    ARCHIVE_SHA256=-
    ARCHIVE_BYTES=0
    SRC_DESC="dir:$_d"
}

# ---- 校验与构建 release ----

valid_version() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
}

# 校验源码并设置 NEW_VERSION NEW_BUILD
validate_source() {
    local _f
    [ -f "$SRC_DIR/bin/proxy-manager" ] || die "源码缺少 bin/proxy-manager"
    [ -d "$SRC_DIR/lib" ] || die "源码缺少 lib/"
    NEW_VERSION=$(first_line "$SRC_DIR/VERSION") || die "源码缺少 VERSION"
    valid_version "$NEW_VERSION" || die "VERSION 格式无效: '$NEW_VERSION'"
    printf '%s' "$FULL_SHA" | grep -Eq '^[0-9a-f]{40}$' || die "commit SHA 无效: '$FULL_SHA'"
    NEW_BUILD=$(printf '%s' "$FULL_SHA" | cut -c1-7)
    [ "${LOCAL_DIRTY:-0}" = 1 ] && NEW_BUILD=$NEW_BUILD-dirty
    for _f in "$SRC_DIR/bin/proxy-manager" "$SRC_DIR"/lib/*.sh; do
        sh -n "$_f" 2>/dev/null || die "语法检查失败, 源码不完整或已损坏: ${_f#"$SRC_DIR"/}"
    done
}

expected_version_output() { printf 'Alpine Proxy Manager %s\nBuild: %s\n' "$NEW_VERSION" "$NEW_BUILD"; }

# 在 staging 中组装 release 目录并自检
build_release() {
    local _r _out
    _r=$STAGING/release
    mkdir -p -- "$_r" || die "无法创建 staging"
    cp -R -- "$SRC_DIR/bin" "$SRC_DIR/lib" "$SRC_DIR/VERSION" "$_r/" || die "复制文件失败"
    printf '%s\n' "$NEW_BUILD" > "$_r/BUILD"
    {
        printf 'source=%s\nrepo=%s\nref=%s\ncommit=%s\narchive_sha256=%s\narchive_bytes=%s\ninstalled_at=%s\n' \
            "$SRC_DESC" "$REPO" "$REF" "$FULL_SHA" "$ARCHIVE_SHA256" "$ARCHIVE_BYTES" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_r/INSTALL"
    # 不依赖 umask, 非 root 用户也要能运行只读命令
    chmod 755 -- "$_r" "$_r/bin" "$_r/lib" "$_r/bin/proxy-manager"
    chmod 644 -- "$_r/VERSION" "$_r/BUILD" "$_r/INSTALL" "$_r"/lib/*.sh
    _out=$("$_r/bin/proxy-manager" --version 2>&1)
    if [ "$_out" != "$(expected_version_output)" ]; then
        die "新版本自检失败, 当前安装保持不变: $_out"
    fi
}

# ---- 已安装状态 ----

# 设置 INST_KIND (none|release|legacy) INST_VERSION INST_BUILD INST_ID
detect_installed() {
    local _t
    INST_KIND=none
    INST_VERSION=
    INST_BUILD=
    INST_ID=
    if [ -L "$LIB/current" ] && [ -r "$LIB/current/VERSION" ]; then
        _t=$(readlink "$LIB/current")
        INST_KIND=release
        INST_ID=${_t##*/}
        INST_VERSION=$(first_line "$LIB/current/VERSION")
        INST_BUILD=$(first_line "$LIB/current/BUILD")
    elif [ -f "$LIB/bin/proxy-manager" ]; then
        # 早期版本直接把 bin lib 放在安装目录下, 无 current 链接
        INST_KIND=legacy
        INST_VERSION=$(first_line "$LIB/VERSION")
        INST_BUILD=$(first_line "$LIB/BUILD")
    fi
    INST_BUILD=${INST_BUILD:-unknown}
}

installed_healthy() {
    [ -x "$LINK" ] && "$LINK" --version >/dev/null 2>&1
}

# 命令链接是否可由我们接管: 不存在, 已是我们的链接, 或旧布局的链接
link_is_ours() {
    local _t
    [ -L "$LINK" ] || return 1
    _t=$(readlink "$LINK")
    case $_t in
        "$LINK_TARGET"|*/alpine-proxy-manager/bin/proxy-manager) return 0 ;;
    esac
    return 1
}

# 原子地把符号链接 NAME 指向 TARGET
atomic_symlink() {
    local _target _name _tmp
    _target=$1
    _name=$2
    _tmp=${_name%/*}/.${_name##*/}.new.$$
    rm -f -- "$_tmp"
    ln -s -- "$_target" "$_tmp" || return 1
    mv -T -- "$_tmp" "$_name" || { rm -f -- "$_tmp"; return 1; }
}

# 失败回滚: PREV_ID 为空表示 current 原本不存在, PREV_LINK 为命令链接原来的目标
rollback() {
    local _id
    _id=$1
    if [ -n "$PREV_ID" ] && [ -d "$LIB/releases/$PREV_ID" ]; then
        atomic_symlink "releases/$PREV_ID" "$LIB/current"
    else
        rm -f -- "$LIB/current"
    fi
    if [ -n "$PREV_LINK" ]; then
        atomic_symlink "$PREV_LINK" "$LINK"
    else
        rm -f -- "$LINK"
    fi
    rm -rf -- "$LIB/releases/$_id"
    rmdir "$LIB/releases" 2>/dev/null
    [ "$CREATED_LIB" = 1 ] && rmdir "$LIB" 2>/dev/null
    return 0
}

do_install() {
    local _id _n _out _d

    if [ -n "$FROM_DIR" ]; then
        check_tools local
    else
        check_tools download
    fi
    check_disk
    note_memory
    acquire_lock
    STAGING=$(mktemp -d "$LIBPARENT/.apm-staging.XXXXXX") || die "无法创建 staging 目录"

    if [ -n "$FROM_DIR" ]; then
        obtain_local "$FROM_DIR"
    else
        obtain_archive
    fi
    validate_source
    detect_installed

    if [ -e "$LINK" ] || [ -L "$LINK" ]; then
        link_is_ours || die "$LINK 已存在且不是由本项目安装的, 拒绝覆盖"
    fi

    if [ "$INST_KIND" = release ] && [ "$INST_VERSION" = "$NEW_VERSION" ] && [ "$INST_BUILD" = "$NEW_BUILD" ] \
        && [ "$FORCE" = 0 ] && installed_healthy; then
        say "已是最新: $NEW_VERSION (Build: $NEW_BUILD), 无需更改"
        return 0
    fi

    case $INST_KIND in
        none) say "正在安装 Alpine Proxy Manager $NEW_VERSION (Build: $NEW_BUILD)" ;;
        *)
            if [ "$INST_VERSION" = "$NEW_VERSION" ] && [ "$INST_BUILD" != "$NEW_BUILD" ]; then
                say "检测到同一开发版本的新 Build:"
                say "$INST_BUILD → $NEW_BUILD"
            elif [ "$INST_VERSION" = "$NEW_VERSION" ]; then
                say "重新安装 $NEW_VERSION (Build: $NEW_BUILD)"
            else
                say "更新: $INST_VERSION ($INST_BUILD) → $NEW_VERSION ($NEW_BUILD)"
            fi
            ;;
    esac

    build_release
    [ "${APM_FAULT:-}" = before_switch ] && die "故障注入: before_switch, 当前安装保持不变"

    # 以下才开始触碰正式目录
    [ -d "$LIB" ] || CREATED_LIB=1
    mkdir -p -- "$LIB/releases" "$BINDIR" || die "无法创建安装目录"
    PREV_ID=
    [ "$INST_KIND" = release ] && PREV_ID=$INST_ID
    _id=$NEW_BUILD
    _n=0
    while [ -e "$LIB/releases/$_id" ]; do
        _n=$((_n + 1))
        _id=$NEW_BUILD.$_n
    done
    mv -- "$STAGING/release" "$LIB/releases/$_id" || { rollback "$_id"; die "无法写入 $LIB/releases"; }

    PREV_LINK=
    [ -L "$LINK" ] && PREV_LINK=$(readlink "$LINK")
    if ! atomic_symlink "releases/$_id" "$LIB/current"; then
        rollback "$_id"
        die "无法切换 current"
    fi
    if ! atomic_symlink "$LINK_TARGET" "$LINK"; then
        rollback "$_id"
        die "无法创建 $LINK"
    fi

    _out=$("$LINK" --version 2>&1)
    if [ "$_out" != "$(expected_version_output)" ] || [ "${APM_FAULT:-}" = post_switch ]; then
        rollback "$_id"
        die "安装后自检失败, 已回滚到原状态: $_out"
    fi

    # 成功后才清理旧 release 与旧布局文件
    for _d in "$LIB"/releases/*; do
        [ -d "$_d" ] && [ "${_d##*/}" != "$_id" ] && rm -rf -- "$_d"
    done
    if [ "$INST_KIND" = legacy ]; then
        rm -rf -- "${LIB:?}/bin" "${LIB:?}/lib" "${LIB:?}/VERSION" "${LIB:?}/BUILD"
    fi

    verbose "安装目录 $(du -sk "$LIB" | awk '{ print $1 }') KiB"
    say ""
    say "Alpine Proxy Manager 安装完成"
    say ""
    say "版本: $NEW_VERSION"
    say "Build: $NEW_BUILD"
    say ""
    say "命令: proxy-manager"
    say "常用:"
    say "  proxy-manager doctor"
    say "  proxy-manager status"
    say "  proxy-manager core list"
}

do_uninstall() {
    local _t _found
    _found=0
    check_tools local
    acquire_lock

    case $LIB in */alpine-proxy-manager) ;; *) die "不安全的安装目录: $LIB" ;; esac

    if [ -L "$LINK" ]; then
        if link_is_ours; then
            rm -f -- "$LINK"
            _found=1
        else
            _t=$(readlink "$LINK")
            err "$LINK 指向 $_t, 不是本项目安装的, 已保留"
        fi
    fi
    if [ -d "$LIB" ]; then
        rm -rf -- "$LIB"
        _found=1
    fi
    for _t in "$LIBPARENT"/.apm-staging.*; do
        [ -d "$_t" ] && rm -rf -- "$_t"
    done

    if [ "$_found" = 0 ]; then
        say "Alpine Proxy Manager 未安装, 无需卸载"
        return 0
    fi
    say "Alpine Proxy Manager 已卸载"
    say "以下内容未改动: Snell, sing-box, /etc/alpine-proxy-manager 配置, /var/lib/alpine-proxy-manager 数据"
}

apm_main() {
    local _mode
    # 最后一行传入的完成标记, 缺失说明脚本被截断
    if [ "${1:-}" != --apm-complete ]; then
        err "install.sh 不完整 (可能下载被中断), 未执行任何操作"
        exit 1
    fi
    shift

    _mode=install
    FORCE=0
    FROM_DIR=
    LOCAL_DIRTY=0
    while [ $# -gt 0 ]; do
        case $1 in
            --uninstall) _mode=uninstall ;;
            --force) FORCE=1 ;;
            --from-dir)
                [ $# -ge 2 ] || { err "--from-dir 需要目录参数"; exit 2; }
                FROM_DIR=$2
                shift
                ;;
            -h|--help) usage; exit 0 ;;
            --) ;;
            *) err "未知参数: $1"; usage >&2; exit 2 ;;
        esac
        shift
    done

    setup_paths
    validate_source_params
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM

    check_alpine
    check_root
    if [ "$_mode" = uninstall ]; then
        do_uninstall
    else
        do_install
    fi
}

apm_main --apm-complete "$@"
