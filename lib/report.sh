# shellcheck shell=sh
# 只读报告: doctor, core list, status
# 本文件中的函数不得修改系统

_rpt_mib() { printf '%s MiB' "$(apm_mib "$1")"; }

# doctor 以 FAIL 计数决定退出码, WARN 不影响
report_doctor() {
    local _fails _lsrc _k
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
        cgroup-v2) _lsrc="cgroup v2" ;;
        cgroup-v1) _lsrc="cgroup v1" ;;
        *)
            if [ "$ENV_CG_VER" = none ]; then
                _lsrc="/proc/meminfo, 未找到 cgroup 内存控制器"
            elif [ -n "$ENV_CG_LIMIT" ]; then
                _lsrc="/proc/meminfo, cgroup 限制 $(_rpt_mib "$ENV_CG_LIMIT") 更宽松"
            else
                _lsrc="/proc/meminfo, cgroup 无数值上限"
            fi
            ;;
    esac
    printf '内存上限：%s (%s)\n' "$(_rpt_mib "$ENV_MEM_LIMIT")" "$_lsrc"
    if [ "$ENV_MEM_CUR_SRC" = meminfo ]; then
        printf '当前内存：%s (/proc/meminfo 已用, 不含可回收缓存)\n' "$(_rpt_mib "$ENV_MEM_CUR")"
    else
        printf '当前内存：%s (cgroup memory.current, 含页缓存)\n' "$(_rpt_mib "$ENV_MEM_CUR")"
    fi
    if [ -n "$ENV_MEM_ANON" ]; then
        printf '其中匿名内存：%s\n' "$(_rpt_mib "$ENV_MEM_ANON")"
    fi
    if [ "$ENV_SWAP_TOTAL" -eq 0 ]; then
        if [ "$ENV_SWAP_SRC" = cgroup-v2 ] && [ "$ENV_SWAP_CG_MAX" = 0 ]; then
            printf 'swap：未启用 (cgroup memory.swap.max 为 0)\n'
        else
            printf 'swap：未启用\n'
        fi
    else
        printf 'swap：%s / %s (空闲 / 总计, %s)\n' "$(_rpt_mib "$ENV_SWAP_FREE")" "$(_rpt_mib "$ENV_SWAP_TOTAL")" "$ENV_SWAP_SRC"
    fi
    if [ "$ENV_MEM_LIMIT" -lt $((64 * 1048576)) ]; then
        printf '64 MiB 基线：WARN (有效内存上限低于 64 MiB)\n'
    else
        printf '64 MiB 基线：OK\n'
    fi

    for _k in $CORE_KEYS; do
        core_discover "$_k"
        case $CF_INSTALLED in
            yes) printf '%s：Installed (%s)\n' "$CF_NAME" "$(core_deployment_label "$CF_DEPLOYMENT")" ;;
            unverified) printf '%s：Unverified (%s 不是已确认的 ELF, 未执行)\n' "$CF_NAME" "$CF_BINARY" ;;
            *) printf '%s：Not installed\n' "$CF_NAME" ;;
        esac
        if [ "$CF_INSTALLED" = yes ]; then
            printf '%s version：%s\n' "$CF_NAME" "${CF_VERSION_REPORTED:-unknown}"
        else
            printf '%s version：-\n' "$CF_NAME"
        fi
    done

    [ "$_fails" -eq 0 ]
}

# 一个 Core 的摘要块, 消费 core_discover 已填好的 CF_* 事实
_rpt_core_block() {
    printf '%s\n' "$CF_NAME"
    printf '  状态：%s\n' "$(core_state_label "$CF_STATE")"
    if [ "$CF_INSTALLED" = yes ]; then
        if [ -n "$CF_VERSION_REPORTED" ]; then
            printf '  版本：%s (二进制自报)\n' "$CF_VERSION_REPORTED"
        else
            printf '  版本：未知\n'
        fi
        printf '  来源：%s\n' "$(core_deployment_label "$CF_DEPLOYMENT")"
        printf '  管理状态：%s\n' "$(core_managed_label)"
    fi
}

report_core_list() {
    local _k
    for _k in $CORE_KEYS; do
        core_discover "$_k"
        _rpt_core_block
        _rpt_notes
    done
}

# 提示行, 每行缩进显示
_rpt_notes() {
    [ -n "$CF_NOTES" ] || return 0
    printf '%s' "$CF_NOTES" | sed 's/^/  注意：/'
}

report_status() {
    local _k _extra
    printf '%s\n\n' "$APM_NAME"
    printf 'Core\n────────────────\n'
    for _k in $CORE_KEYS; do
        core_discover "$_k"
        _extra=
        if [ "$CF_INSTALLED" = yes ]; then
            _extra=" ($(core_deployment_label "$CF_DEPLOYMENT"), $(core_managed_label))"
        fi
        printf '%-12s%s%s\n' "$CF_NAME" "$(core_state_label "$CF_STATE")" "$_extra"
    done
    printf '\nFeatures\n────────────────\n'
    printf '%-22s%s\n' "Server SOCKS Egress" "$(state_socks_summary)"
    printf '%-22s%s\n' "Relay Access Policy" "$(state_relay_summary)"
}

# ---- Snell 只读 Adapter ----

_rpt_yn() { case $1 in yes) printf '是' ;; no) printf '否' ;; *) printf '%s' "$1" ;; esac; }

# 监听行, 如实说明归属依据
_rpt_listeners() {
    if [ -z "$CF_LISTEN" ]; then
        printf '  监听：未观察到\n'
        return 0
    fi
    case $CF_LISTEN_ATTRIB in
        pid) printf '  监听 (按进程 %s 的 socket 确认)：\n' "$CF_PID" ;;
        *) printf '  监听 (仅按配置端口匹配, 未确认进程)：\n' ;;
    esac
    printf '%s\n' "$CF_LISTEN" | awk '{ printf "    %s %s\n", $1, $2 }'
    printf '  说明：以上是容器或系统内观察到的监听端口, 不是公网映射端口\n'
}

report_snell_status() {
    core_discover snell
    printf 'Snell\n'
    printf '  状态：%s\n' "$(core_state_label "$CF_STATE")"
    if [ "$CF_INSTALLED" != yes ]; then
        _rpt_notes
        return 0
    fi
    printf '  版本：%s (二进制自报)\n' "${CF_VERSION_REPORTED:-未知}"
    printf '  来源：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    case $CF_SERVICE_STATE in
        none) printf '  OpenRC：未找到服务脚本, 运行状态按进程命令行判断\n' ;;
        *) printf '  OpenRC：服务 %s 状态 %s (来源 %s)\n' "$CF_SERVICE" "$CF_SERVICE_STATE" "$CF_SERVICE_SOURCE" ;;
    esac
    [ -z "$CF_PID" ] || printf '  进程：%s\n' "$CF_PID"
    _rpt_listeners
    _rpt_notes
}

report_snell_info() {
    core_discover snell
    printf 'Snell\n'
    printf '  已安装：%s\n' "$(_rpt_yn "$CF_INSTALLED")"
    printf '  状态：%s\n' "$(core_state_label "$CF_STATE")"
    printf '  部署类型：%s\n' "$CF_DEPLOYMENT"
    printf '  管理状态：%s\n' "$(core_managed_label)"
    if [ -n "$CF_BINARY" ]; then
        printf '  二进制：%s (类型 %s, 符号链接 %s)\n' "$CF_BINARY" "$CF_BINARY_KIND" "$(_rpt_yn "$CF_BINARY_LINK")"
        [ "$CF_BINARY_LINK" != yes ] || printf '  二进制实际路径：%s\n' "$CF_BINARY_REAL"
    fi
    if [ "$CF_INSTALLED" != yes ]; then
        _rpt_notes
        return 0
    fi
    printf '  自报版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
    printf '  精确发布：%s\n' "$CF_VERSION_EXACT"
    printf '  版本来源：%s\n' "$CF_VERSION_SOURCE"
    if [ -n "$CF_SERVICE" ]; then
        printf '  服务：%s (%s)\n' "$CF_SERVICE" "$CF_SERVICE_FILE"
        printf '  服务状态：%s (来源 %s)\n' "$CF_SERVICE_STATE" "$CF_SERVICE_SOURCE"
        printf '  托管方式：%s\n' "${CF_SUPERVISOR:-未声明}"
        printf '  服务用户：%s\n' "${CF_SERVICE_USER:-未声明}"
        printf '  pidfile：%s\n' "${CF_PIDFILE:--}"
        [ -z "$CF_SUP_PID" ] || printf '  监督进程 PID：%s\n' "$CF_SUP_PID"
    else
        printf '  服务：未找到\n'
    fi
    [ -z "$CF_PID" ] || printf '  服务进程 PID：%s\n' "$CF_PID"
    if [ -n "$CF_CONFIG" ]; then
        printf '  配置：%s (来源 %s)\n' "$CF_CONFIG" "$CF_CONFIG_SOURCE"
        printf '  配置存在：%s\n' "$(_rpt_yn "$CF_CONFIG_EXISTS")"
        [ -z "$CF_CONFIG_PERM" ] || printf '  配置权限：%s\n' "$CF_CONFIG_PERM"
        if [ "$CF_CONFIG_READABLE" = yes ]; then
            printf '  配置字段：%s\n' "${CF_CONFIG_KEYS:--}"
            printf '  listen：%s\n' "${CF_SNELL_LISTEN:--}"
            printf '  mode：%s\n' "${CF_SNELL_MODE:--}"
            case $CF_PSK in
                configured) printf '  psk：已配置\n' ;;
                missing) printf '  psk：未配置\n' ;;
            esac
        fi
    else
        printf '  配置：未找到\n'
    fi
    _rpt_log_meta "access/output" "$CF_LOG_OUT" "$CF_LOG_OUT_EXISTS" "$CF_LOG_OUT_SIZE"
    _rpt_log_meta "error" "$CF_LOG_ERR" "$CF_LOG_ERR_EXISTS" "$CF_LOG_ERR_SIZE"
    _rpt_listeners
    _rpt_notes
}

_rpt_log_meta() {
    if [ -z "$2" ]; then
        printf '  %s 日志：未声明\n' "$1"
    elif [ "$3" = yes ]; then
        printf '  %s 日志：%s (%s 字节)\n' "$1" "$2" "$4"
    else
        printf '  %s 日志：%s (不存在)\n' "$1" "$2"
    fi
}

# snell log [N], 只读取末尾 N 行 默认 20 最多 200 优先 error 日志
report_snell_log() {
    local _n _f _fs
    _n=${1:-20}
    case $_n in ''|*[!0-9]*) apm_err "行数必须是正整数"; return 2 ;; esac
    [ "$_n" -ge 1 ] || { apm_err "行数必须是正整数"; return 2; }
    [ "$_n" -le 200 ] || _n=200
    core_discover snell
    if [ "$CF_INSTALLED" != yes ]; then
        apm_err "未检测到已确认的 Snell"
        return 1
    fi
    _f=$CF_LOG_ERR
    [ -n "$_f" ] || _f=$CF_LOG_OUT
    if [ -z "$_f" ]; then
        apm_err "服务脚本没有声明日志路径"
        return 1
    fi
    _fs=$(env_path "$_f")
    if [ ! -f "$_fs" ]; then
        apm_err "日志文件不存在: $_f"
        return 1
    fi
    if ! _core_can_read "$_fs"; then
        apm_err "没有读取权限: $_f"
        return 1
    fi
    printf '%s 最后 %s 行 (日志可能包含访问的目标域名, 注意不要公开)\n' "$_f" "$_n"
    tail -n "$_n" "$_fs"
}
