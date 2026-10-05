# shellcheck shell=sh
# Core 层: Snell 与 sing-box 是两个相互独立的 Core, 没有 Both 模式
#
# Adapter 接口: 每个 Core 以 core_<key>_<op> 函数实现生命周期操作
# 未实现的操作由 core_op 统一返回 3
#   op: install uninstall start stop restart reload check_config update
#
# Core key 使用 snell 与 singbox, 因为 POSIX sh 函数名不能含连字符

CORE_KEYS="snell singbox"

# 二进制固定搜索目录, 不依赖 PATH, 避免 root 与普通用户结果不一致
CORE_BIN_DIRS="/usr/local/bin /usr/bin /usr/local/sbin /usr/sbin"

core_valid_key() {
    case $1 in snell|singbox) return 0 ;; *) return 1 ;; esac
}

core_name() {
    case $1 in
        snell) printf 'Snell' ;;
        singbox) printf 'sing-box' ;;
    esac
}

core_binary_name() {
    case $1 in
        snell) printf 'snell-server' ;;
        singbox) printf 'sing-box' ;;
    esac
}

# 输出二进制路径, 找不到返回 1
core_binary() {
    local _bn _d _p
    _bn=$(core_binary_name "$1")
    for _d in $CORE_BIN_DIRS; do
        _p=$(env_path "$_d/$_bn")
        if [ -f "$_p" ] && [ -x "$_p" ]; then
            printf '%s\n' "$_p"
            return 0
        fi
    done
    return 1
}

core_installed() { core_binary "$1" >/dev/null 2>&1; }

# 通过 /proc/*/comm 判断进程是否存在, 不依赖 pgrep 与服务名
core_process_running() {
    local _bn _d _c
    _bn=$(core_binary_name "$1")
    for _d in "$(env_path /proc)"/[0-9]*; do
        [ -r "$_d/comm" ] || continue
        _c=
        IFS= read -r _c < "$_d/comm" || :
        [ "$_c" = "$_bn" ] && return 0
    done
    return 1
}

# 输出版本号, 未知时输出空并返回 1
# Snell 的版本获取方式尚未调查, 不猜测
core_version() {
    local _bin _v
    case $1 in
        snell) return 1 ;;
        singbox)
            _bin=$(core_binary singbox) || return 1
            _v=$("$_bin" version 2>/dev/null | head -n 1 | awk '{ print $3 }')
            [ -n "$_v" ] || return 1
            printf '%s\n' "$_v"
            ;;
    esac
}

# 输出状态键: not-installed | stopped | running | broken
# broken 目前仅用于 sing-box 二进制存在但无法执行 version
core_state() {
    core_installed "$1" || { printf 'not-installed\n'; return 0; }
    if [ "$1" = singbox ] && ! core_version singbox >/dev/null; then
        printf 'broken\n'
        return 0
    fi
    if core_process_running "$1"; then
        printf 'running\n'
    else
        printf 'stopped\n'
    fi
}

core_state_label() {
    case $1 in
        not-installed) printf '未安装' ;;
        stopped) printf '已安装 / 未运行' ;;
        running) printf '已安装 / 运行中' ;;
        broken) printf '已安装 / 异常' ;;
    esac
}

# 统一的生命周期分发
core_op() {
    local _key _op _fn
    _key=$1
    _op=$2
    shift 2
    core_valid_key "$_key" || { apm_err "未知 Core: $_key"; return 2; }
    _fn="core_${_key}_${_op}"
    if command -v "$_fn" >/dev/null 2>&1; then
        "$_fn" "$@"
    else
        apm_err "$(core_name "$_key") 的 $_op 尚未实现"
        return 3
    fi
}

# sing-box 配置校验, 供配置事务作为 validator 使用
core_singbox_check_config() {
    local _bin
    _bin=$(core_binary singbox) || { apm_err "sing-box 未安装, 无法校验配置"; return 1; }
    "$_bin" check -c "$1"
}
