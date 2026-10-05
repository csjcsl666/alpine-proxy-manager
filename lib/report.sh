# shellcheck shell=sh
# 只读报告: doctor, core list, status
# 本文件中的函数不得修改系统

_rpt_mib() { printf '%s MiB' "$(apm_mib "$1")"; }

# doctor 以 FAIL 计数决定退出码, WARN 不影响
report_doctor() {
    _fails=0

    if env_is_alpine; then
        printf 'Alpine Linux：OK (%s)\n' "$(env_alpine_version)"
    else
        printf 'Alpine Linux：FAIL (本项目仅支持 Alpine Linux)\n'
        _fails=$((_fails + 1))
    fi

    if env_has_openrc; then
        printf 'OpenRC：OK\n'
    else
        printf 'OpenRC：FAIL (未找到 /sbin/openrc)\n'
        _fails=$((_fails + 1))
    fi

    if env_is_root; then
        printf 'root：OK\n'
    else
        printf 'root：WARN (当前 uid=%s, 安装与管理操作需要 root)\n' "$(env_euid)"
    fi

    if env_arch_known; then
        printf '架构：%s\n' "$(env_arch)"
    else
        printf '架构：%s (WARN, 未验证的架构)\n' "$(env_arch)"
    fi

    env_probe_memory
    case $ENV_MEM_LIMIT_SRC in
        meminfo) _lsrc="/proc/meminfo, 未检测到更小的 cgroup 限制" ;;
        *) _lsrc=$ENV_MEM_LIMIT_SRC ;;
    esac
    printf '内存上限：%s (%s)\n' "$(_rpt_mib "$ENV_MEM_LIMIT")" "$_lsrc"
    if [ "$ENV_MEM_CUR_SRC" = meminfo ]; then
        printf '当前内存：%s (已用, 不含可回收缓存)\n' "$(_rpt_mib "$ENV_MEM_CUR")"
    else
        printf '当前内存：%s (%s, 含页缓存)\n' "$(_rpt_mib "$ENV_MEM_CUR")" "$ENV_MEM_CUR_SRC"
    fi
    if [ -n "$ENV_MEM_ANON" ]; then
        printf '其中匿名内存：%s\n' "$(_rpt_mib "$ENV_MEM_ANON")"
    fi
    if [ "$ENV_SWAP_TOTAL" -eq 0 ]; then
        printf 'swap：未启用\n'
    else
        printf 'swap：%s / %s (空闲 / 总计)\n' "$(_rpt_mib "$ENV_SWAP_FREE")" "$(_rpt_mib "$ENV_SWAP_TOTAL")"
    fi
    if [ "$ENV_MEM_LIMIT" -lt $((64 * 1048576)) ]; then
        printf '64 MiB 基线：WARN (有效内存上限低于 64 MiB)\n'
    else
        printf '64 MiB 基线：OK\n'
    fi

    for _k in $CORE_KEYS; do
        if core_installed "$_k"; then
            printf '%s：Installed\n' "$(core_name "$_k")"
        else
            printf '%s：Not installed\n' "$(core_name "$_k")"
        fi
    done
    if core_installed singbox; then
        printf 'sing-box version：%s\n' "$(core_version singbox || printf 'unknown')"
    else
        printf 'sing-box version：-\n'
    fi

    [ "$_fails" -eq 0 ]
}

report_core_list() {
    for _k in $CORE_KEYS; do
        _st=$(core_state "$_k")
        _ver=$(core_version "$_k" 2>/dev/null) || _ver=
        printf '%s\t%s\t%s\n' "$(core_name "$_k")" "$(core_state_label "$_st")" "${_ver:--}"
    done
}
