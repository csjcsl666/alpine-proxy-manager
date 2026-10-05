# shellcheck shell=sh
# 环境检测, 全部只读
# 测试用覆盖变量:
#   APM_SYSROOT  所有系统路径(/etc /proc /sys /sbin)的前缀, 默认为空
#   APM_EUID     覆盖有效 uid
#   APM_ARCH     覆盖 uname -m

env_path() { printf '%s%s' "${APM_SYSROOT:-}" "$1"; }

env_alpine_version() {
    local _f _v
    _f=$(env_path /etc/alpine-release)
    [ -r "$_f" ] || return 1
    _v=
    IFS= read -r _v < "$_f" || :
    [ -n "$_v" ] || return 1
    printf '%s\n' "$_v"
}

# 需要 alpine-release 存在, 且 os-release 若存在则 ID 必须是 alpine
env_is_alpine() {
    local _o
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

_env_stat_field() { awk -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# 是否是可用的 cgroup 数值: 1 到 18 位十进制且大于 0
# 空, max, 乱码与 0 都不是, 19 位及以上视为 cgroup v1 的 "无限制" 哨兵值
_env_cg_number() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 18 ] && [ "$1" -gt 0 ]
}

# 填充全局变量, 概念上分开 "检测到的 cgroup 限制" 与 "有效内存上限":
#   ENV_MEM_TOTAL      /proc/meminfo 的 MemTotal, 字节
#   ENV_CG_VER         v2 | v1 | none, 是否找到 cgroup 内存控制器
#   ENV_CG_LIMIT       检测到的 cgroup 数值上限, 字节, 无数值上限时为空
#   ENV_MEM_LIMIT      有效上限 = min(MemTotal, ENV_CG_LIMIT)
#   ENV_MEM_LIMIT_SRC  cgroup-v2 | cgroup-v1 | meminfo, 即决定有效上限的来源
#                      两者相等时归于 cgroup, LXCFS 会把 MemTotal 虚拟化成 cgroup 上限
#   ENV_MEM_CUR / ENV_MEM_CUR_SRC / ENV_MEM_ANON  当前使用, cgroup 可读时优先
#   ENV_SWAP_TOTAL / ENV_SWAP_FREE / ENV_SWAP_SRC / ENV_SWAP_CG_MAX
#
# cgroup v2: 从 /proc/self/cgroup 给出的路径出发, 逐级向上读到 cgroup 根, 每级的 memory.max
# 取所有数值中最小者, 相等时取更靠外的一级, 因为外层才是整体用量
# 某级不可读或内容异常则跳过该级, max 不会覆盖更严格的数值
# 这是只读 sysfs 文件的简单遍历, 不假设任何容器平台
# 局限: cgroup namespace 之外的更高层级不可见, 只能看到命名空间内可见的部分
env_probe_memory() {
    local _root _pf _p _d _lv _m _sw _any _lim_lv _cur _cur_lv _anon _lim _swmax _v1
    ENV_MEM_TOTAL=$(_env_meminfo MemTotal)
    ENV_MEM_TOTAL=${ENV_MEM_TOTAL:-0}
    ENV_CG_VER=none
    ENV_CG_LIMIT=
    ENV_MEM_LIMIT=$ENV_MEM_TOTAL
    ENV_MEM_LIMIT_SRC=meminfo
    ENV_MEM_ANON=
    ENV_SWAP_SRC=meminfo
    ENV_SWAP_CG_MAX=

    _m=$(_env_meminfo MemAvailable)
    [ -n "$_m" ] || _m=$(_env_meminfo MemFree)
    ENV_MEM_CUR=$((ENV_MEM_TOTAL - ${_m:-0}))
    ENV_MEM_CUR_SRC=meminfo
    ENV_SWAP_TOTAL=$(_env_meminfo SwapTotal)
    ENV_SWAP_TOTAL=${ENV_SWAP_TOTAL:-0}
    ENV_SWAP_FREE=$(_env_meminfo SwapFree)
    ENV_SWAP_FREE=${ENV_SWAP_FREE:-0}

    _root=$(env_path /sys/fs/cgroup)
    _pf=$(env_path /proc/self/cgroup)
    _p=
    if [ -r "$_pf" ]; then
        _p=$(sed -n 's/^0:://p' "$_pf" 2>/dev/null | head -n 1)
    fi
    [ "$_p" = / ] && _p=

    _any=0
    _lim=
    _lim_lv=
    _swmax=
    _d=$_p
    while :; do
        _lv=$_root$_d
        if [ -r "$_lv/memory.max" ]; then
            _any=1
            _m=$(cat "$_lv/memory.max" 2>/dev/null)
            if _env_cg_number "$_m" && { [ -z "$_lim" ] || [ "$_m" -le "$_lim" ]; }; then
                _lim=$_m
                _lim_lv=$_lv
            fi
        fi
        if [ -r "$_lv/memory.swap.max" ]; then
            _sw=$(cat "$_lv/memory.swap.max" 2>/dev/null)
            # swap 上限允许为 0, 与内存不同
            case $_sw in
                ''|*[!0-9]*) ;;
                *) [ "${#_sw}" -le 18 ] && { [ -z "$_swmax" ] || [ "$_sw" -le "$_swmax" ]; } && _swmax=$_sw ;;
            esac
        fi
        [ -n "$_d" ] || break
        _d=${_d%/*}
    done

    _cur=
    _cur_lv=
    _anon=
    if [ "$_any" = 1 ]; then
        ENV_CG_VER=v2
        ENV_CG_LIMIT=$_lim
        if [ -n "$_lim_lv" ]; then
            _cur_lv=$_lim_lv
        elif [ -r "$_root/memory.current" ]; then
            # 没有数值上限时, 只有 cgroup 根本身有 memory.current 才说明处在容器级 cgroup 内
            # 宿主机的真实根没有这个文件, 此时回退 meminfo, 避免把某个 slice 的用量当成整机
            _cur_lv=$_root
        fi
        if [ -n "$_cur_lv" ]; then
            _cur=$(cat "$_cur_lv/memory.current" 2>/dev/null)
            _anon=$(_env_stat_field "$_cur_lv/memory.stat" anon)
        fi
    else
        _v1=$(env_path /sys/fs/cgroup/memory)
        if [ -r "$_v1/memory.limit_in_bytes" ]; then
            ENV_CG_VER=v1
            _m=$(cat "$_v1/memory.limit_in_bytes" 2>/dev/null)
            _env_cg_number "$_m" && _lim=$_m
            ENV_CG_LIMIT=$_lim
            _cur=$(cat "$_v1/memory.usage_in_bytes" 2>/dev/null)
            _anon=$(_env_stat_field "$_v1/memory.stat" rss)
        fi
    fi

    if [ -n "$ENV_CG_LIMIT" ]; then
        if [ "$ENV_MEM_TOTAL" -eq 0 ] || [ "$ENV_CG_LIMIT" -le "$ENV_MEM_TOTAL" ]; then
            ENV_MEM_LIMIT=$ENV_CG_LIMIT
            ENV_MEM_LIMIT_SRC=cgroup-$ENV_CG_VER
        fi
    fi
    case ${_cur:-} in
        ''|*[!0-9]*) ;;
        *) [ "${#_cur}" -le 18 ] && { ENV_MEM_CUR=$_cur; ENV_MEM_CUR_SRC=cgroup; } ;;
    esac
    case ${_anon:-} in
        ''|*[!0-9]*) ;;
        *) ENV_MEM_ANON=$_anon ;;
    esac

    # swap: cgroup v2 的 memory.swap.max 优先, 它限制容器真正可用的 swap
    # 宿主机或 LXCFS 暴露的 free 与 SwapTotal 可能与此不符
    if [ -n "$_swmax" ]; then
        ENV_SWAP_CG_MAX=$_swmax
        ENV_SWAP_SRC=cgroup-v2
        if [ "$_swmax" -lt "$ENV_SWAP_TOTAL" ]; then
            ENV_SWAP_TOTAL=$_swmax
        fi
        [ "$ENV_SWAP_FREE" -le "$ENV_SWAP_TOTAL" ] || ENV_SWAP_FREE=$ENV_SWAP_TOTAL
    fi
    return 0
}
