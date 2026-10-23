# shellcheck shell=sh
# 只读报告: doctor, core list, status
# 本文件中的函数不得修改系统

_rpt_mib() { printf '%s MiB' "$(apm_mib "$1")"; }

# doctor 以 FAIL 计数决定退出码, WARN 不影响
report_doctor() {
    local _fails _lsrc _k
    _fails=0

    if env_is_alpine; then
        printf 'Alpine Linux：正常 (%s)\n' "$(env_alpine_version)"
    else
        printf 'Alpine Linux：失败 (本项目仅支持 Alpine Linux)\n'
        _fails=$((_fails + 1))
    fi

    if env_has_openrc; then
        printf 'OpenRC：正常\n'
    else
        printf 'OpenRC：失败 (未找到 /sbin/openrc)\n'
        _fails=$((_fails + 1))
    fi

    if env_is_root; then
        printf 'root：正常\n'
    else
        printf 'root：警告 (当前 uid=%s, 安装与管理操作需要 root)\n' "$(env_euid)"
    fi

    if env_arch_known; then
        printf '架构：%s\n' "$(env_arch)"
    else
        printf '架构：%s (警告, 未验证的架构)\n' "$(env_arch)"
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
        printf '64 MiB 基线：警告 (有效内存上限低于 64 MiB)\n'
    else
        printf '64 MiB 基线：正常\n'
    fi

    for _k in $CORE_KEYS; do
        core_discover "$_k"
        case $CF_INSTALLED in
            yes) printf '%s：已安装 (%s)\n' "$CF_NAME" "$(core_deployment_label "$CF_DEPLOYMENT")" ;;
            unverified) printf '%s：未确认 (%s 不是已确认的 ELF, 未执行)\n' "$CF_NAME" "$CF_BINARY" ;;
            *) printf '%s：未安装\n' "$CF_NAME" ;;
        esac
        if [ "$CF_INSTALLED" = yes ]; then
            printf '%s 版本：%s\n' "$CF_NAME" "${CF_VERSION_REPORTED:-未知}"
            _rpt_bin_owner
        else
            printf '%s 版本：-\n' "$CF_NAME"
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
        _rpt_bin_owner
    fi
}

# Manager 部署的二进制应属于 root, 属主修复之前安装的 sing-box 保留了上游压缩包里的 uid
# 只告警, 不修改: 修复方法是 sing-box update --force
_rpt_bin_owner() {
    local _u _cmd
    [ "$CF_DEPLOYMENT" = managed ] || return 0
    [ -n "$CF_BINARY_REAL" ] || return 0
    _u=$(stat -c %u "$(env_path "$CF_BINARY_REAL")" 2>/dev/null) || return 0
    case $_u in ''|*[!0-9]*|0) return 0 ;; esac
    _cmd=$CF_KEY
    [ "$_cmd" != singbox ] || _cmd=sing-box
    printf '  警告：二进制属主是 uid %s 而不是 root, 同 uid 的用户可以替换它, 请执行 proxy-manager %s update --force 修复\n' "$_u" "$_cmd"
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
    printf '服务\n────────────────\n'
    for _k in $CORE_KEYS; do
        core_discover "$_k"
        _extra=
        if [ "$CF_INSTALLED" = yes ]; then
            _extra=" ($(core_deployment_label "$CF_DEPLOYMENT"), $(core_managed_label))"
        fi
        printf '  %s：%s%s\n' "$CF_NAME" "$(core_state_label "$CF_STATE")" "$_extra"
        _rpt_notes
    done
    printf '\n功能\n────────────────\n'
    printf '  SOCKS5 出口：%s\n' "$(state_socks_summary)"
    printf '  目标访问限制：%s\n' "$(state_relay_summary)"
    printf '  网络与进程保护：%s\n' "$(lowmem_summary)"
}

# ---- 展示用的公共函数: 把底层的 /proc 与 OpenRC 事实翻译成管理员能直接读懂的中文 ----
# 分四类, 不混在一起: 配置 (配置文件里声明的) 运行 (实际检测到的进程与监听) 公网连接信息 (客户端该连的地址) 未确认 (条件不足不下结论)

_rpt_yn() { case $1 in yes) printf '是' ;; no) printf '否' ;; *) printf '%s' "$1" ;; esac; }

# OpenRC 服务状态
_rpt_svc_state() {
    case $1 in
        started) printf '运行中' ;;
        stopped) printf '未运行' ;;
        crashed) printf '异常退出' ;;
        starting) printf '启动中' ;;
        stopping) printf '停止中' ;;
        none|'') printf '未找到' ;;
        *) printf '%s' "$1" ;;
    esac
}

# 秒数 -> 简短的时长, 例如 2 天 3 小时
_rpt_dur() {
    local _s
    _s=$1
    if [ "$_s" -ge 86400 ]; then printf '%s 天 %s 小时' $((_s / 86400)) $((_s % 86400 / 3600))
    elif [ "$_s" -ge 3600 ]; then printf '%s 小时 %s 分钟' $((_s / 3600)) $((_s % 3600 / 60))
    elif [ "$_s" -ge 60 ]; then printf '%s 分钟' $((_s / 60))
    else printf '%s 秒' "$_s"; fi
}

# 进程已运行多久, 读 /proc, 读不到就不显示 (不编造)
_rpt_proc_age() { # PID
    local _st _up
    [ -r "$(env_path "/proc/$1/stat")" ] && [ -r "$(env_path /proc/uptime)" ] || return 0
    _st=$(sed 's/^.*) //' "$(env_path "/proc/$1/stat")" 2>/dev/null | awk '{ print $20 }')
    _up=$(awk '{ print int($1) }' "$(env_path /proc/uptime)" 2>/dev/null)
    case $_st$_up in *[!0-9]*|'') return 0 ;; esac
    [ $((_up - _st / 100)) -ge 0 ] || return 0
    _rpt_dur $((_up - _st / 100))
}

# 地址 -> 监听范围 (准确区分 [::] 0.0.0.0 127.0.0.1)
_rpt_scope() {
    case $1 in
        '[::]') printf '所有 IPv6 地址' ;;
        0.0.0.0) printf '所有 IPv4 地址' ;;
        127.*) printf '仅本机 (IPv4)' ;;
        '[::1]') printf '仅本机 (IPv6)' ;;
        '['*) printf '指定 IPv6 地址 %s' "$1" ;;
        *) printf '指定 IPv4 地址 %s' "$1" ;;
    esac
}

# 只监听 [::] 时, IPv4 能不能连是个需要说明依据的问题: 系统默认双栈, 但进程可以单独关闭, 读不到每个 socket 的设置, 所以只能说明依据不下结论
_rpt_v4_hint() {
    local _v
    _v=$(cat "$(env_path /proc/sys/net/ipv6/bindv6only)" 2>/dev/null)
    case $_v in
        0) printf '系统默认同时接受 IPv4, 进程可单独关闭, 未逐项确认' ;;
        1) printf '系统设置为 IPv6 套接字仅接受 IPv6, 除非进程另行设置, IPv4 连不上' ;;
        *) printf '是否接受 IPv4 未确认' ;;
    esac
}

# 端口的用途: 关联到具体的服务或线路, 找不到就不写, 不猜测
_rpt_port_purpose() { # 端口
    local _f _id _t
    case $CF_KEY in
        anytlsgw)
            command -v _agw_state >/dev/null 2>&1 || return 0
            _f=$(_agw_state)
            [ -r "$_f" ] || return 0
            for _id in $(_agw_ids "$_f" 2>/dev/null); do
                [ "$(_agw_get "$_f" "$_id" listen | sed 's/.*://')" != "$1" ] || { printf 'AnyTLS 转发线路 %s' "$_id"; return 0; }
            done
            ;;
        singbox)
            command -v state_list_confs >/dev/null 2>&1 || return 0
            for _f in $(state_list_confs "$(state_instances_dir)" 2>/dev/null); do
                [ "$(kv_get "$_f" listen_port)" != "$1" ] || { _t=$(kv_get "$_f" type); printf '实例 %s (%s)' "$(kv_get "$_f" id)" "$_t"; return 0; }
            done
            ;;
        snell)
            printf '%s\n' "$CF_SNELL_LISTEN" | tr ',' '\n' | grep -q ":$1[[:space:]]*$" && printf 'Snell 服务'
            ;;
    esac
    return 0
}

# 监听信息: 每个端口一行, 说明协议 监听范围 用途; 最后一行只说一次依据与边界
# CF_LISTEN 每行是 协议 地址:端口 inode, 来自 /proc/net 而不是外部网络工具; 服务没有运行时不会把配置里的端口当成正在监听
_rpt_listeners() {
    local _lines
    if [ -z "$CF_LISTEN" ]; then
        if [ "${CF_LISTEN_ATTRIB:-}" = denied ]; then printf '  监听：需要 root 才能确认 (当前用户无权读取服务进程的 socket)\n'
        elif [ "$CF_STATE" = running ]; then printf '  监听：服务在运行, 但没有检测到监听端口\n'; else printf '  监听：无 (服务没有运行)\n'; fi
        return 0
    fi
    printf '  监听 (服务器内部, 不等于公网映射端口)：\n'
    printf '%s\n' "$CF_LISTEN" | awk '{ n = split($2, a, ":"); port = a[n]; addr = substr($2, 1, length($2) - length(port) - 1); print toupper($1), port, addr }' | sort -k2,2n -k1,1 | while read -r _proto _port _addr; do
        _lines=
        case $_addr in
            '[::]')
                if printf '%s\n' "$CF_LISTEN" | awk -v p=":$_port" -v t="$(printf '%s' "$_proto" | tr '[:upper:]' '[:lower:]')" '$1 == t && index($2, "0.0.0.0" p) == 1 { f = 1 } END { exit !f }'; then
                    _lines="IPv4 与 IPv6 都已监听"
                else
                    _lines=$(_rpt_v4_hint)
                fi
                printf '    %s %s  %s (%s)' "$_port" "$_proto" "$(_rpt_scope "$_addr")" "$_lines"
                ;;
            *) printf '    %s %s  %s' "$_port" "$_proto" "$(_rpt_scope "$_addr")" ;;
        esac
        _lines=$(_rpt_port_purpose "$_port")
        if [ -n "$_lines" ]; then printf '  %s\n' "$_lines"; else printf '\n'; fi
    done
    case $CF_LISTEN_ATTRIB in
        pid) printf '    归属：已按进程 %s 的 socket 确认\n' "$CF_PID" ;;
        *) printf '    归属：仅按配置的端口匹配, 未确认是该服务的进程占用\n' ;;
    esac
}

# 配置文件一行: 路径 权限 (没有找到就说没有找到)
_rpt_config_line() {
    if [ -z "$CF_CONFIG" ]; then printf '  配置：未找到\n'; return 0; fi
    if [ "$CF_CONFIG_EXISTS" = denied ]; then printf '  配置：%s (当前用户无权读取, 需要 root)\n' "$CF_CONFIG"; return 0; fi
    if [ "$CF_CONFIG_EXISTS" != yes ]; then printf '  配置：%s (文件不存在)\n' "$CF_CONFIG"; return 0; fi
    printf '  配置：%s%s\n' "$CF_CONFIG" "${CF_CONFIG_PERM:+ (权限 $CF_CONFIG_PERM)}"
}

_rpt_log_meta() {
    if [ -z "$2" ]; then
        printf '  %s日志：未声明\n' "$1"
    elif [ "$3" = yes ]; then
        printf '  %s日志：%s (%s 字节)\n' "$1" "$2" "$4"
    else
        printf '  %s日志：%s (文件不存在)\n' "$1" "$2"
    fi
}

# 状态行: 运行中时带上 PID 与已运行时长
_rpt_state_line() {
    local _age
    printf '  状态：%s' "$(core_state_label "$CF_STATE")"
    if [ "$CF_STATE" = running ] && [ -n "$CF_PID" ]; then
        _age=$(_rpt_proc_age "$CF_PID")
        printf ' (PID %s%s)' "$CF_PID" "${_age:+, 已运行 $_age}"
    fi
    printf '\n'
}

# 版本行: 二进制自报的版本, 发布名不同时再附上
_rpt_version_line() {
    printf '  版本：%s (二进制自报' "${CF_VERSION_REPORTED:-未知}"
    if [ -n "$CF_VERSION_EXACT" ] && [ "$CF_VERSION_EXACT" != unknown ] && [ "${CF_VERSION_EXACT#v}" != "${CF_VERSION_REPORTED#v}" ]; then printf '; 发布 %s' "$CF_VERSION_EXACT"; fi
    printf ')\n'
}

# 服务行: OpenRC 服务名 状态 托管方式 运行用户
_rpt_service_line() {
    if [ -z "$CF_SERVICE" ]; then
        printf '  服务：未找到服务脚本, 运行状态按进程命令行判断\n'
        return 0
    fi
    printf '  服务：%s (OpenRC, %s' "$CF_SERVICE" "$(_rpt_svc_state "$CF_SERVICE_STATE")"
    [ -z "$CF_SUPERVISOR" ] || printf '; 由 %s 托管' "$CF_SUPERVISOR"
    [ -z "$CF_SERVICE_USER" ] || printf '; 运行用户 %s' "$CF_SERVICE_USER"
    printf ')\n'
}

report_snell_status() {
    core_discover snell
    printf 'Snell\n'
    _rpt_state_line
    if [ "$CF_INSTALLED" != yes ]; then
        _rpt_notes
        return 0
    fi
    _rpt_version_line
    printf '  部署：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    _rpt_service_line
    _rpt_snell_net
    _rpt_listeners
    _rpt_notes
}

# 启用 SOCKS5 出口 或 目标访问限制 时显示, 并检查辅助进程是否都在; 未启用时不输出任何内容
_rpt_snell_net() {
    local _m
    command -v snn_mode >/dev/null 2>&1 || return 0
    _m=$(snn_mode)
    case $_m in
        egress|access)
            printf '  网络功能：%s' "$(snn_mode_label "$_m")"
            if [ "$CF_STATE" = running ]; then
                if snn_runtime_ok "$_m"; then printf ' (辅助进程正常)\n'; else printf ' (辅助进程异常, 业务连接会失败而不是直连)\n'; fi
            else
                printf '\n'
            fi
            ;;
        conflict) printf '  网络功能：配置冲突, 两个功能都被标记为启用, 请先禁用其中一个\n' ;;
    esac
}

# 二进制与文件位置 (低频, 放在详情的最后)
_rpt_files_block() {
    [ -z "$CF_BINARY" ] || printf '  二进制：%s%s\n' "$CF_BINARY" "$([ "$CF_BINARY_LINK" != yes ] || printf ' (符号链接, 实际 %s)' "$CF_BINARY_REAL")"
    _rpt_config_line
    [ -z "$CF_PIDFILE" ] || printf '  PID 文件：%s\n' "$CF_PIDFILE"
    _rpt_log_meta "访问/输出" "$CF_LOG_OUT" "$CF_LOG_OUT_EXISTS" "$CF_LOG_OUT_SIZE"
    _rpt_log_meta "错误" "$CF_LOG_ERR" "$CF_LOG_ERR_EXISTS" "$CF_LOG_ERR_SIZE"
}

report_snell_info() {
    core_discover snell
    printf 'Snell\n'
    _rpt_state_line
    if [ "$CF_INSTALLED" != yes ]; then
        [ -z "$CF_BINARY" ] || printf '  二进制：%s (类型 %s)\n' "$CF_BINARY" "$CF_BINARY_KIND"
        _rpt_notes
        return 0
    fi
    _rpt_version_line
    printf '  部署：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    _rpt_service_line
    if [ "$CF_CONFIG_READABLE" = yes ]; then
        printf '  配置内容：监听地址 %s, 运行模式 %s, PSK %s\n' "${CF_SNELL_LISTEN:--}" "${CF_SNELL_MODE:--}" "$(case $CF_PSK in configured) printf '已配置' ;; missing) printf '未配置' ;; *) printf '未确认' ;; esac)"
    fi
    [ "$CF_KEY" != snell ] || _rpt_snell_net
    _rpt_listeners
    _rpt_files_block
    _rpt_notes
}

# Core 日志 [N], 只读取末尾 N 行 默认 20 最多 200 优先 error 日志
_report_core_log() {
    local _n _f _fs _key
    _key=$1
    shift
    _n=${1:-20}
    case $_n in ''|*[!0-9]*) apm_err "行数必须是正整数"; return 2 ;; esac
    [ "$_n" -ge 1 ] || { apm_err "行数必须是正整数"; return 2; }
    [ "$_n" -le 200 ] || _n=200
    core_discover "$_key"
    if [ "$CF_INSTALLED" != yes ]; then
        apm_err "未检测到已确认的 $(core_name "$_key")"
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

report_snell_log() { _report_core_log snell "$@"; }
report_singbox_log() { _report_core_log singbox "$@"; }

# ---- sing-box 报告 ----

report_singbox_status() {
    core_discover singbox
    printf 'sing-box\n'
    _rpt_state_line
    if [ "$CF_INSTALLED" != yes ]; then
        _rpt_notes
        return 0
    fi
    _rpt_version_line
    printf '  部署：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    _rpt_service_line
    _rpt_listeners
    _rpt_notes
}

report_singbox_info() {
    core_discover singbox
    printf 'sing-box\n'
    _rpt_state_line
    if [ "$CF_INSTALLED" != yes ]; then
        [ -z "$CF_BINARY" ] || printf '  二进制：%s (类型 %s)\n' "$CF_BINARY" "$CF_BINARY_KIND"
        _rpt_notes
        return 0
    fi
    _rpt_version_line
    printf '  部署：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    _rpt_service_line
    _rpt_listeners
    _rpt_files_block
    _rpt_notes
}
