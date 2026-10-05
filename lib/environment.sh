# shellcheck shell=sh
# 环境检测, 全部只读
# 测试用覆盖变量:
#   APM_SYSROOT  所有系统路径(/etc /proc /sys /sbin)的前缀, 默认为空
#   APM_EUID     覆盖有效 uid
#   APM_ARCH     覆盖 uname -m

env_path() { printf '%s%s' "${APM_SYSROOT:-}" "$1"; }

env_alpine_version() {
    _f=$(env_path /etc/alpine-release)
    [ -r "$_f" ] || return 1
    _v=
    IFS= read -r _v < "$_f" || :
    [ -n "$_v" ] || return 1
    printf '%s\n' "$_v"
}

# 需要 alpine-release 存在, 且 os-release 若存在则 ID 必须是 alpine
env_is_alpine() {
    env_alpine_version >/dev/null 2>&1 || return 1
    _o=$(env_path /etc/os-release)
    if [ -r "$_o" ]; then
        grep -Eq '^ID="?alpine"?$' "$_o" || return 1
    fi
    return 0
}

env_has_openrc() {
    [ -x "$(env_path /sbin/openrc)" ] || [ -x "$(env_path /usr/sbin/openrc)" ]
}

env_euid() { printf '%s\n' "${APM_EUID:-$(id -u)}"; }
env_is_root() { [ "$(env_euid)" = 0 ]; }

env_arch() { printf '%s\n' "${APM_ARCH:-$(uname -m)}"; }

env_arch_known() {
    case $(env_arch) in
        x86_64|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

# 读 /proc/meminfo 的字段, 输出字节
_env_meminfo() {
    awk -v k="$1:" '$1 == k { print $2 * 1024; exit }' "$(env_path /proc/meminfo)" 2>/dev/null
}

# 输出 cgroup v2 目录, 优先 cgroup namespace 根, 其次 /proc/self/cgroup 路径
_env_cgroup_v2_dir() {
    _root=$(env_path /sys/fs/cgroup)
    if [ -r "$_root/memory.max" ]; then
        printf '%s\n' "$_root"
        return 0
    fi
    _pf=$(env_path /proc/self/cgroup)
    [ -r "$_pf" ] || return 1
    _p=$(sed -n 's/^0:://p' "$_pf" | head -n 1)
    [ -n "$_p" ] || return 1
    [ -r "$_root$_p/memory.max" ] || return 1
    printf '%s\n' "$_root$_p"
}

_env_stat_field() { awk -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# 填充全局变量:
#   ENV_MEM_LIMIT      有效内存上限, 字节
#   ENV_MEM_LIMIT_SRC  cgroup-v2 | cgroup-v1 | meminfo
#   ENV_MEM_CUR        当前内存, 字节
#   ENV_MEM_CUR_SRC    cgroup memory.current | cgroup usage_in_bytes | meminfo
#   ENV_MEM_ANON       cgroup 内匿名内存, 字节, 未知为空
#   ENV_SWAP_TOTAL / ENV_SWAP_FREE  字节
# cgroup 上限大于等于 MemTotal 或为 max 时视为未限制, 回退 meminfo
env_probe_memory() {
    _total=$(_env_meminfo MemTotal)
    _total=${_total:-0}
    ENV_MEM_LIMIT=$_total
    ENV_MEM_LIMIT_SRC=meminfo
    ENV_MEM_ANON=
    _avail=$(_env_meminfo MemAvailable)
    [ -n "$_avail" ] || _avail=$(_env_meminfo MemFree)
    ENV_MEM_CUR=$((_total - ${_avail:-0}))
    ENV_MEM_CUR_SRC=meminfo
    ENV_SWAP_TOTAL=$(_env_meminfo SwapTotal)
    ENV_SWAP_TOTAL=${ENV_SWAP_TOTAL:-0}
    ENV_SWAP_FREE=$(_env_meminfo SwapFree)
    ENV_SWAP_FREE=${ENV_SWAP_FREE:-0}

    _lim=
    _cur=
    if _d=$(_env_cgroup_v2_dir); then
        _lim=$(cat "$_d/memory.max" 2>/dev/null)
        _cur=$(cat "$_d/memory.current" 2>/dev/null)
        _anon=$(_env_stat_field "$_d/memory.stat" anon)
        _lsrc=cgroup-v2
        _csrc="cgroup memory.current"
    else
        _v1=$(env_path /sys/fs/cgroup/memory)
        if [ -r "$_v1/memory.limit_in_bytes" ]; then
            _lim=$(cat "$_v1/memory.limit_in_bytes" 2>/dev/null)
            _cur=$(cat "$_v1/memory.usage_in_bytes" 2>/dev/null)
            _anon=$(_env_stat_field "$_v1/memory.stat" rss)
            _lsrc=cgroup-v1
            _csrc="cgroup usage_in_bytes"
        fi
    fi
    case ${_lim:-} in
        ''|max|*[!0-9]*) return 0 ;;
    esac
    # 数值超出 sh 算术范围时位数会远大于 MemTotal, 先按位数判断为未限制
    [ ${#_lim} -le 18 ] || return 0
    if [ "$_total" -eq 0 ] || [ "$_lim" -lt "$_total" ]; then
        ENV_MEM_LIMIT=$_lim
        ENV_MEM_LIMIT_SRC=$_lsrc
        case ${_cur:-} in
            ''|*[!0-9]*) ;;
            *) ENV_MEM_CUR=$_cur; ENV_MEM_CUR_SRC=$_csrc ;;
        esac
        case ${_anon:-} in
            ''|*[!0-9]*) ;;
            *) ENV_MEM_ANON=$_anon ;;
        esac
    fi
    return 0
}
