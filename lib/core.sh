# shellcheck shell=sh
# Core 层: Snell 与 sing-box 是两个相互独立的 Core, 没有 Both 模式
#
# Core Discovery: core_discover KEY 只读地发现一次, 把事实写入全局变量 CF_*
# status, info, core list 等命令都消费同一组事实, 不各自重新猜测环境
#
# 安全原则
#   - 发现不等于接管: 已有部署默认是 external, 本层不做任何写操作
#   - 未知可执行文件不得执行: 只有确认为 ELF 的二进制才会被运行, 且只运行版本查询
#     脚本, 指向脚本的符号链接与无法识别的文件一律不执行
#   - 运行状态以 OpenRC 为准, 不使用 /proc/*/comm, gcompat 下 comm 是 ld-musl-*
#   - 读取 OpenRC 脚本只做文本解析, 不 source, 不执行
#
# Adapter 接口: 生命周期写操作以 core_<key>_<op> 实现, 未实现的统一返回 3
#   op: install uninstall start stop restart reload check_config update
# Core key 使用 snell 与 singbox, 因为 POSIX sh 函数名不能含连字符

CORE_KEYS="snell singbox anytlsgw"

# 二进制固定搜索目录, 不依赖 PATH, 避免 root 与普通用户结果不一致
CORE_BIN_DIRS="/usr/local/bin /usr/bin /usr/local/sbin /usr/sbin"

core_valid_key() {
    case $1 in snell|singbox|anytlsgw) return 0 ;; *) return 1 ;; esac
}

core_name() {
    case $1 in
        snell) printf 'Snell' ;;
        singbox) printf 'sing-box' ;;
        anytlsgw) printf 'AnyTLS Gateway' ;;
    esac
}

core_binary_name() {
    case $1 in
        snell) printf 'snell-server' ;;
        singbox) printf 'sing-box' ;;
        anytlsgw) printf 'anytls-socks-gateway' ;;
    esac
}

# 约定的 OpenRC 服务名, 两种已知布局都叫这个名字
core_service_name() {
    case $1 in
        snell) printf 'snell' ;;
        singbox) printf 'sing-box' ;;
        anytlsgw) printf 'anytls-socks-gateway' ;;
    esac
}

# 只读版本查询的参数
core_version_arg() {
    case $1 in
        snell) printf -- '-v' ;;
        singbox) printf 'version' ;;
        anytlsgw) printf -- '-version' ;;
    esac
}

# 无 OpenRC 声明时尝试的配置路径, 已知两种布局
core_config_candidates() {
    case $1 in
        snell) printf '%s\n' /etc/snell-server.conf /etc/snell/snell-server.conf ;;
        singbox) printf '%s\n' /etc/sing-box/config.json ;;
        anytlsgw) printf '%s\n' /etc/anytls-socks-gateway/config.json ;;
    esac
}

# ---- 小工具 ----

# 可被测试覆盖, 以便模拟没有读权限的文件 (测试以 root 运行时 -r 恒为真)
_core_can_read() { [ -r "$1" ]; }

# 去掉 APM_SYSROOT 前缀, 得到系统内的逻辑路径用于显示
_core_logical() {
    local _sr
    _sr=${APM_SYSROOT:-}
    _sr=${_sr%/}
    if [ -n "$_sr" ]; then
        case $1 in "$_sr"/*) printf '%s' "${1#"$_sr"}"; return 0 ;; esac
    fi
    printf '%s' "$1"
}

_core_file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# ---- 文件类型识别 ----

# 手工解析符号链接, 绝对目标要落在 APM_SYSROOT 内才与真实系统一致
# 设置 CORE_RESOLVED (文件系统路径) 与 CORE_IS_LINK, 链接过深或无法读取时返回 1
core_resolve() {
    local _p _n _t
    _p=$1
    _n=0
    CORE_IS_LINK=no
    CORE_RESOLVED=
    while [ -L "$_p" ]; do
        CORE_IS_LINK=yes
        _n=$((_n + 1))
        [ "$_n" -le 10 ] || return 1
        _t=$(readlink "$_p") || return 1
        case $_t in
            /*) _p=$(env_path "$_t") ;;
            *) _p=${_p%/*}/$_t ;;
        esac
    done
    CORE_RESOLVED=$_p
}

# 输出 elf | script | unknown | missing, 只读文件头 4 字节, 从不执行
core_file_kind() {
    local _m
    core_resolve "$1" || { printf 'unknown\n'; return 0; }
    if [ ! -e "$CORE_RESOLVED" ]; then
        printf 'missing\n'
        return 0
    fi
    if [ ! -f "$CORE_RESOLVED" ]; then
        printf 'unknown\n'
        return 0
    fi
    _m=$(head -c 4 "$CORE_RESOLVED" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case $_m in
        7f454c46) printf 'elf\n' ;;
        2321*) printf 'script\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# ---- OpenRC 脚本解析 (只读文本) ----

# _core_init_var FILE NAME SVC, 取 NAME=值 去引号, 展开服务名变量, 含其他变量时视为未知
_core_init_var() {
    local _v
    _v=$(sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | head -n 1)
    _v=$(printf '%s' "$_v" | sed -e 's/^"\(.*\)"[[:space:]]*$/\1/' -e "s/^'\\(.*\\)'[[:space:]]*\$/\\1/")
    _v=$(printf '%s' "$_v" | sed -e "s/\${RC_SVCNAME}/$3/g" -e "s/\$RC_SVCNAME/$3/g" -e "s/\${SVCNAME}/$3/g" -e "s/\$SVCNAME/$3/g")
    case $_v in *'$'*) _v= ;; esac
    printf '%s' "$_v"
}

# 设置 CF_SERVICE CF_SERVICE_FILE CF_SERVICE_OPENRC CF_INIT_COMMAND CF_INIT_ARGS
#     CF_SERVICE_USER CF_PIDFILE CF_SUPERVISOR CF_LOG_OUT CF_LOG_ERR
_core_parse_init() {
    local _svc _f
    _svc=$(core_service_name "$1")
    CF_SERVICE=
    CF_SERVICE_FILE=
    CF_SERVICE_OPENRC=no
    CF_INIT_COMMAND=
    CF_INIT_ARGS=
    CF_SERVICE_USER=
    CF_PIDFILE=
    CF_SUPERVISOR=
    CF_LOG_OUT=
    CF_LOG_ERR=
    _f=$(env_path "/etc/init.d/$_svc")
    [ -f "$_f" ] || return 0
    _core_can_read "$_f" || return 0
    CF_SERVICE=$_svc
    CF_SERVICE_FILE=/etc/init.d/$_svc
    # 只有明确是 openrc-run 脚本才会交给 rc-service 去执行 status
    if head -n 1 "$_f" | grep -q 'openrc-run'; then
        CF_SERVICE_OPENRC=yes
    fi
    CF_INIT_COMMAND=$(_core_init_var "$_f" command "$_svc")
    CF_INIT_ARGS=$(_core_init_var "$_f" command_args "$_svc")
    CF_SERVICE_USER=$(_core_init_var "$_f" command_user "$_svc")
    CF_PIDFILE=$(_core_init_var "$_f" pidfile "$_svc")
    CF_SUPERVISOR=$(_core_init_var "$_f" supervisor "$_svc")
    CF_LOG_OUT=$(_core_init_var "$_f" output_log "$_svc")
    CF_LOG_ERR=$(_core_init_var "$_f" error_log "$_svc")
    # OpenRC 的默认 pidfile
    [ -n "$CF_PIDFILE" ] || CF_PIDFILE=/run/$_svc.pid
    # Snell 启用网络功能时, 服务运行的是包装脚本, 真正的二进制记录在 apm_binary
    if grep -q '^# apm-net:' "$_f" 2>/dev/null; then
        CF_INIT_COMMAND=$(_core_init_var "$_f" apm_binary "$_svc")
        CF_INIT_ARGS=
        CF_SERVICE_USER=snell
    fi
}

# ---- 二进制发现 ----

# 设置 CF_BINARY (逻辑路径) CF_BINARY_KIND CF_BINARY_LINK CF_BINARY_REAL CF_NOTES
# 返回 0 表示找到已确认的 ELF, 1 表示没有可信二进制
# 候选顺序: OpenRC 脚本里的 command, 然后固定目录
# 非 ELF 的候选只记录, 绝不执行
core_find_binary() {
    local _name _d _p _k _found _cand
    _name=$(core_binary_name "$1")
    CF_BINARY=
    CF_BINARY_KIND=
    CF_BINARY_LINK=no
    CF_BINARY_REAL=
    _found=
    _cand=
    [ -z "${CF_INIT_COMMAND:-}" ] || _cand=$CF_INIT_COMMAND
    for _d in $CORE_BIN_DIRS; do
        _cand="$_cand $_d/$_name"
    done
    for _p in $_cand; do
        case $_p in /*) ;; *) continue ;; esac
        [ -e "$(env_path "$_p")" ] || [ -L "$(env_path "$_p")" ] || continue
        _k=$(core_file_kind "$(env_path "$_p")")
        if [ "$_k" = elf ]; then
            # 采用第一个 ELF, 但继续扫描以便记录被忽略的非 ELF 入口
            if [ -z "$_found" ]; then
                _found=elf
                core_resolve "$(env_path "$_p")"
                CF_BINARY=$_p
                CF_BINARY_KIND=elf
                CF_BINARY_LINK=$CORE_IS_LINK
                CF_BINARY_REAL=$(_core_logical "$CORE_RESOLVED")
            fi
            continue
        fi
        if [ -z "$_found" ] && [ -z "$CF_BINARY" ]; then
            core_resolve "$(env_path "$_p")"
            CF_BINARY=$_p
            CF_BINARY_KIND=$_k
            CF_BINARY_LINK=$CORE_IS_LINK
            CF_BINARY_REAL=$(_core_logical "${CORE_RESOLVED:-}")
        fi
        CF_NOTES="${CF_NOTES}检测到 $_p 但它不是已确认的 ELF (类型 $_k), 未执行
"
    done
    [ "$_found" = elf ]
}

# 信任的二进制 (文件系统路径), 供需要执行 Core 的调用方使用
core_trusted_binary() {
    local _saved
    _saved=${CF_NOTES:-}
    _core_parse_init "$1"
    CF_NOTES=
    if core_find_binary "$1"; then
        CF_NOTES=$_saved
        env_path "$CF_BINARY"
        return 0
    fi
    CF_NOTES=$_saved
    return 1
}

# ---- 版本 ----

_core_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    else
        "$@"
    fi
}

# 只对已确认的 ELF 执行版本查询, 设置 CF_VERSION_REPORTED CF_VERSION_EXACT CF_VERSION_SOURCE CF_VERSION_OK
_core_query_version() {
    local _out _bin _arg
    CF_VERSION_REPORTED=
    CF_VERSION_EXACT=unknown
    CF_VERSION_SOURCE=none
    CF_VERSION_OK=no
    [ "$CF_BINARY_KIND" = elf ] || return 0
    _bin=$(env_path "$CF_BINARY")
    _arg=$(core_version_arg "$1")
    _out=$(_core_timeout "$_bin" "$_arg" 2>&1 | head -n 3)
    case $1 in
        snell)
            CF_VERSION_REPORTED=$(printf '%s\n' "$_out" | sed -n 's/.*snell-server \(v[0-9][0-9A-Za-z.]*\).*/\1/p' | head -n 1)
            ;;
        singbox)
            CF_VERSION_REPORTED=$(printf '%s\n' "$_out" | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n 1)
            ;;
        anytlsgw)
            CF_VERSION_REPORTED=$(printf '%s\n' "$_out" | sed -n 's/^anytls-socks-gateway \(v[0-9][0-9A-Za-z.-]*\).*/\1/p' | head -n 1)
            ;;
    esac
    if [ -n "$CF_VERSION_REPORTED" ]; then
        CF_VERSION_OK=yes
        CF_VERSION_SOURCE=binary
    fi
}

# ---- 服务状态 ----

# 设置 CF_SERVICE_STATE (started|stopped|crashed|unknown|none) 与 CF_SERVICE_SOURCE
# 优先 rc-service status, 其次读取 OpenRC 的状态文件, 两者都只读
_core_service_state() {
    local _rc _out _r _st
    CF_SERVICE_STATE=none
    CF_SERVICE_SOURCE=none
    [ -n "$CF_SERVICE" ] || return 0
    CF_SERVICE_STATE=unknown
    _rc=$(env_path /sbin/rc-service)
    if [ "$CF_SERVICE_OPENRC" = yes ] && [ -x "$_rc" ]; then
        _out=$("$_rc" "$CF_SERVICE" status 2>&1)
        _r=$?
        _st=$(printf '%s\n' "$_out" | sed -n 's/.*status:[[:space:]]*\([a-z]*\).*/\1/p' | head -n 1)
        case $_st in
            started|stopped|crashed) CF_SERVICE_STATE=$_st ;;
            *) if [ "$_r" -eq 0 ]; then CF_SERVICE_STATE=started; else CF_SERVICE_STATE=stopped; fi ;;
        esac
        CF_SERVICE_SOURCE=rc-service
        return 0
    fi
    if [ -d "$(env_path /run/openrc)" ]; then
        if [ -e "$(env_path "/run/openrc/started/$CF_SERVICE")" ] || [ -L "$(env_path "/run/openrc/started/$CF_SERVICE")" ]; then
            CF_SERVICE_STATE=started
        else
            CF_SERVICE_STATE=stopped
        fi
        CF_SERVICE_SOURCE=openrc-files
    fi
    return 0
}

# ---- 进程 ----

_core_pid_alive() { [ -d "$(env_path "/proc/$1")" ]; }

# 进程命令行的 argv 第一项与完整命令行 (NUL 换成空格)
_core_cmdline() { tr '\0' ' ' < "$(env_path "/proc/$1/cmdline")" 2>/dev/null; }

# argv 中是否有一个元素恰好等于 PATH
_core_argv_has() {
    tr '\0' '\n' < "$(env_path "/proc/$1/cmdline")" 2>/dev/null | grep -Fxq -- "$2"
}

_core_argv0_base() {
    local _a
    _a=$(tr '\0' '\n' < "$(env_path "/proc/$1/cmdline")" 2>/dev/null | head -n 1)
    printf '%s' "${_a##*/}"
}

# 输出父进程为 PID 的子进程 PID, /proc/N/stat 中 comm 可能含空格, 取最后一个右括号之后的字段
_core_children_of() {
    local _s _p
    for _s in "$(env_path /proc)"/[0-9]*/stat; do
        [ -r "$_s" ] || continue
        _p=$(sed 's/^[0-9]* (.*) //' "$_s" 2>/dev/null | awk '{ print $2 }')
        if [ "$_p" = "$1" ]; then
            _s=${_s%/stat}
            printf '%s\n' "${_s##*/}"
        fi
    done
}

# 设置 CF_SUP_PID CF_PID, 不使用 comm
# 有监督进程时 pidfile 里是监督进程, 服务进程取其子进程
# Snell 启用网络功能时, supervise-daemon 的子进程是包装脚本, 真正的 Snell 由包装脚本记录
# 只有记录的 PID 仍然是命令行含 "-c 运行时配置" 的 Snell 二进制时才采用, 否则视为没有服务进程
_core_net_pid() {
    local _f _p
    [ "${CF_KEY:-}" = snell ] || return 0
    grep -q '^# apm-net:' "$(env_path "${CF_SERVICE_FILE:-/nonexistent}")" 2>/dev/null || return 0
    [ -n "$CF_PID" ] || return 0
    _f=$(env_path /run/apm-snell/snell.pid)
    _p=$(head -n 1 "$_f" 2>/dev/null | tr -d ' \r\n')
    case $_p in ''|*[!0-9]*) CF_PID=; return 0 ;; esac
    if _core_pid_alive "$_p" && _core_argv_has "$_p" /run/apm-snell/snell.conf; then
        CF_PID=$_p
    else
        CF_PID=
    fi
}

_core_find_pids() {
    local _pf _pid _c
    CF_SUP_PID=
    CF_PID=
    if [ -n "$CF_PIDFILE" ] && _core_can_read "$(env_path "$CF_PIDFILE")"; then
        _pid=$(head -n 1 "$(env_path "$CF_PIDFILE")" 2>/dev/null | tr -d ' \r\n')
        case $_pid in ''|*[!0-9]*) _pid= ;; esac
        if [ -n "$_pid" ] && _core_pid_alive "$_pid"; then
            if [ "$(_core_argv0_base "$_pid")" = supervise-daemon ]; then
                CF_SUP_PID=$_pid
                for _c in $(_core_children_of "$_pid"); do
                    CF_PID=$_c
                    break
                done
            else
                CF_PID=$_pid
            fi
        fi
    fi
    _core_net_pid
    # 没有 pidfile 信息时, 退化为按命令行匹配二进制路径, 排除 supervise-daemon 自身
    if [ -z "$CF_PID" ] && [ -z "$CF_SUP_PID" ] && [ -n "$CF_BINARY" ]; then
        for _pf in "$(env_path /proc)"/[0-9]*; do
            _pid=${_pf##*/}
            [ -r "$_pf/cmdline" ] || continue
            # 排除监督进程, 以及版本查询时 timeout 留下的瞬时进程, 它们的命令行也含二进制路径
            case $(_core_argv0_base "$_pid") in supervise-daemon|timeout) continue ;; esac
            # 必须是某个 argv 元素恰好等于二进制路径, 不能是拼接后命令行里的子串
            # 否则 sh -c "...路径..." 这样的无关进程会被误判为服务进程
            if _core_argv_has "$_pid" "$CF_BINARY" || { [ -n "$CF_BINARY_REAL" ] && _core_argv_has "$_pid" "$CF_BINARY_REAL"; }; then
                CF_PID=$_pid
                CF_PIDSRC=cmdline
                break
            fi
        done
    fi
}

# ---- 管理归属 ----

core_meta_file() { printf '%s/cores/%s.meta' "$(state_var)" "$1"; }

# 只有 Manager 自己的元数据才能证明归属, 二进制路径相同不算
# 设置 CF_MANAGED CF_DEPLOYMENT CF_META_EXACT CF_META_STATE
#   CF_META_STATE  none 无元数据文件 | valid 语法正确且 core 匹配 | invalid 文件存在但无法证明归属
# invalid 时 CF_MANAGED 为 no, 写操作必须拒绝, 避免归属丢失后覆盖用户环境
_core_ownership() {
    local _f _m
    CF_MANAGED=no
    CF_META_EXACT=
    CF_META_STATE=none
    _f=$(core_meta_file "$1")
    if [ -e "$_f" ]; then
        CF_META_STATE=invalid
        if [ -f "$_f" ] && _core_can_read "$_f" && kv_check_syntax "$_f" 2>/dev/null \
            && [ "$(kv_get "$_f" core)" = "$1" ] && [ -n "$(kv_get "$_f" managed)" ]; then
            CF_META_STATE=valid
            if [ "$(kv_get "$_f" managed)" = true ]; then
                CF_MANAGED=yes
                CF_META_EXACT=$(kv_get "$_f" exact_release)
                _m=$(kv_get "$_f" binary_path)
                [ -n "$_m" ] || _m=$(kv_get "$_f" binary)
                if [ -n "$_m" ] && [ -n "$CF_BINARY" ] && [ "$_m" != "$CF_BINARY" ] && [ "$_m" != "$CF_BINARY_REAL" ]; then
                    CF_NOTES="${CF_NOTES}元数据中的二进制路径 $_m 与实际发现的 $CF_BINARY 不一致
"
                fi
            fi
        fi
        if [ "$CF_META_STATE" = invalid ]; then
            CF_NOTES="${CF_NOTES}Manager 元数据 $_f 存在但无法证明归属 (语法错误, core 不匹配或缺少 managed), 视为归属不明, 拒绝写操作
"
        fi
    fi
    if [ "$CF_INSTALLED" = no ]; then
        CF_MANAGED=no
        CF_DEPLOYMENT=none
    elif [ "$CF_MANAGED" = yes ]; then
        CF_DEPLOYMENT=managed
    else
        CF_DEPLOYMENT=external
    fi
}

# ---- 发现入口 ----

# core_discover KEY, 只读, 填充全部 CF_* 事实
#   CF_KEY CF_NAME
#   CF_INSTALLED     yes | no | unverified (有同名入口但不是已确认的 ELF)
#   CF_STATE         not-installed | unverified | broken | crashed | running | stopped
#   CF_BINARY CF_BINARY_KIND CF_BINARY_LINK CF_BINARY_REAL
#   CF_SERVICE CF_SERVICE_FILE CF_SERVICE_STATE CF_SERVICE_SOURCE CF_SERVICE_USER
#   CF_PIDFILE CF_SUP_PID CF_PID CF_RUNNING_SOURCE
#   CF_VERSION_REPORTED CF_VERSION_EXACT CF_VERSION_SOURCE
#   CF_MANAGED CF_DEPLOYMENT
#   CF_LOG_OUT CF_LOG_ERR
#   CF_NOTES         换行分隔的提示
# Core 专有事实由 core_<key>_discover_extra 追加
core_discover() {
    core_valid_key "$1" || return 2
    CF_KEY=$1
    CF_NAME=$(core_name "$1")
    CF_NOTES=
    CF_PIDSRC=
    CF_RUNNING_SOURCE=none
    CF_INSTALLED=no
    CF_STATE=not-installed
    CF_SUP_PID=
    CF_PID=
    _core_parse_init "$1"
    if core_find_binary "$1"; then
        CF_INSTALLED=yes
    elif [ -n "$CF_BINARY" ]; then
        CF_INSTALLED=unverified
    fi
    CF_VERSION_REPORTED=
    CF_VERSION_EXACT=unknown
    CF_VERSION_SOURCE=none
    CF_VERSION_OK=no
    CF_SERVICE_STATE=none
    CF_SERVICE_SOURCE=none
    if [ "$CF_INSTALLED" = yes ]; then
        _core_query_version "$1"
    fi
    _core_ownership "$1"
    if [ "$CF_MANAGED" = yes ] && [ -n "$CF_META_EXACT" ]; then
        CF_VERSION_EXACT=$CF_META_EXACT
        CF_VERSION_SOURCE=manager-metadata
    fi

    if [ "$CF_INSTALLED" = no ]; then
        CF_STATE=not-installed
        return 0
    fi
    if [ "$CF_INSTALLED" = unverified ]; then
        CF_STATE=unverified
        return 0
    fi

    _core_service_state
    _core_find_pids
    case $CF_SERVICE_STATE in
        started) CF_RUNNING_SOURCE=$CF_SERVICE_SOURCE; CF_STATE=running ;;
        crashed) CF_RUNNING_SOURCE=$CF_SERVICE_SOURCE; CF_STATE=crashed ;;
        stopped) CF_RUNNING_SOURCE=$CF_SERVICE_SOURCE; CF_STATE=stopped ;;
        *)
            # 没有可用的 OpenRC 信息, 退化为进程扫描
            if [ -n "$CF_PID" ]; then
                CF_RUNNING_SOURCE=process
                CF_STATE=running
            else
                CF_RUNNING_SOURCE=process
                CF_STATE=stopped
            fi
            ;;
    esac
    if [ "$CF_VERSION_OK" = no ] && [ "$CF_STATE" != crashed ]; then
        CF_NOTES="${CF_NOTES}对 ELF 执行版本查询没有得到版本, 可能缺少运行库或二进制不兼容
"
        CF_STATE=broken
    fi
    if command -v "core_${1}_discover_extra" >/dev/null 2>&1; then
        "core_${1}_discover_extra"
    fi
}

core_installed() {
    core_discover "$1"
    [ "$CF_INSTALLED" = yes ]
}

core_state() {
    core_discover "$1"
    printf '%s\n' "$CF_STATE"
}

# 供不改变全局事实的快速调用
core_version() {
    core_discover "$1"
    [ -n "$CF_VERSION_REPORTED" ] || return 1
    printf '%s\n' "$CF_VERSION_REPORTED"
}

core_state_label() {
    case $1 in
        not-installed) printf '未安装' ;;
        unverified) printf '未确认 (有同名入口但不是 ELF)' ;;
        stopped) printf '未运行' ;;
        running) printf '运行中' ;;
        crashed) printf '已崩溃 (OpenRC 报告 crashed)' ;;
        broken) printf '异常 (二进制无法给出版本)' ;;
    esac
}

core_deployment_label() {
    case $1 in
        managed) printf 'Manager 部署' ;;
        external) printf '现有部署' ;;
        *) printf '-' ;;
    esac
}

core_managed_label() {
    if [ "$CF_META_STATE" = invalid ]; then
        printf '归属不明 (元数据异常)'
        return 0
    fi
    case $CF_DEPLOYMENT in
        managed) printf '已接管' ;;
        external) printf '未接管' ;;
        *) printf '-' ;;
    esac
}

# ---- 配置与日志与监听 (Snell 专有事实) ----

# 数字为 PID 时输出其打开的 socket inode, 空格分隔并以空格包围
_core_socket_inodes() {
    local _fd _t _r
    _r=" "
    for _fd in "$(env_path "/proc/$1/fd")"/*; do
        _t=$(readlink "$_fd" 2>/dev/null) || continue
        _t=$(printf '%s' "$_t" | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p')
        [ -z "$_t" ] || _r="$_r$_t "
    done
    printf '%s' "$_r"
}

# 解码 /proc/net/{tcp,tcp6,udp,udp6} 中处于监听的 socket
# 参数 inodes 与 ports 任选其一过滤, 输出 "协议 地址:端口 inode"
_core_proc_listeners() {
    local _f _proto _state
    for _f in tcp tcp6 udp udp6; do
        [ -r "$(env_path "/proc/net/$_f")" ] || continue
        case $_f in tcp*) _state=0A ;; *) _state=07 ;; esac
        awk -v proto="$_f" -v state="$_state" -v inodes="$1" -v ports="$2" '
            function hex(s,   i, c, v, d) {
                v = 0
                s = toupper(s)
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    d = index("0123456789ABCDEF", c) - 1
                    v = v * 16 + d
                }
                return v
            }
            function ip4(h) {
                return hex(substr(h, 7, 2)) "." hex(substr(h, 5, 2)) "." hex(substr(h, 3, 2)) "." hex(substr(h, 1, 2))
            }
            function ip6(h,   i, w, g, out, allzero) {
                out = ""; allzero = 1
                for (i = 0; i < 4; i++) {
                    w = substr(h, i * 8 + 1, 8)
                    g[i * 2] = substr(w, 7, 2) substr(w, 5, 2)
                    g[i * 2 + 1] = substr(w, 3, 2) substr(w, 1, 2)
                }
                for (i = 0; i < 8; i++) if (hex(g[i]) != 0) allzero = 0
                if (allzero) return "::"
                if (hex(g[7]) == 1) {
                    allzero = 1
                    for (i = 0; i < 7; i++) if (hex(g[i]) != 0) allzero = 0
                    if (allzero) return "::1"
                }
                for (i = 0; i < 8; i++) out = out (i ? ":" : "") sprintf("%x", hex(g[i]))
                return out
            }
            NR > 1 && $4 == state {
                split($2, a, ":")
                port = hex(a[2])
                ino = $10
                if (inodes != "") { if (index(inodes, " " ino " ") == 0) next }
                else if (ports != "") { if (index(ports, " " port " ") == 0) next }
                else next
                if (length(a[1]) == 32) addr = "[" ip6(a[1]) "]"; else addr = ip4(a[1])
                sub(/[46]$/, "", proto)
                print proto, addr ":" port, ino
            }' "$(env_path "/proc/net/$_f")"
    done
}

# 输出配置里 listen 的所有端口, 空格包围, 用于过滤
_core_listen_ports() {
    printf '%s' "$1" | tr ',' '\n' | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' | tr '\n' ' ' | sed 's/^/ /; s/$/ /'
}

# 设置 CF_CONFIG* CF_SNELL_LISTEN CF_SNELL_MODE CF_PSK, CF_LOG_*_EXISTS/SIZE, CF_LISTEN*
# PSK 的值不会被读入变量, 只判断是否已配置
core_snell_discover_extra() {
    local _c _argc _fs _inodes _ports
    CF_CONFIG=
    CF_CONFIG_SOURCE=none
    CF_CONFIG_EXISTS=no
    CF_CONFIG_READABLE=unknown
    CF_CONFIG_PERM=
    CF_CONFIG_KEYS=
    CF_SNELL_LISTEN=
    CF_SNELL_MODE=
    CF_PSK=unknown
    CF_LISTEN=
    CF_LISTEN_ATTRIB=none

    # 配置路径: OpenRC 脚本里 command_args 的 -c, 其次已知的两种布局
    _argc=$(printf '%s' "$CF_INIT_ARGS" | awk '{ for (i = 1; i < NF; i++) if ($i == "-c") { print $(i + 1); exit } }')
    if [ -n "$_argc" ]; then
        CF_CONFIG=$_argc
        CF_CONFIG_SOURCE=service
    else
        for _c in $(core_config_candidates snell); do
            if [ -e "$(env_path "$_c")" ]; then
                CF_CONFIG=$_c
                CF_CONFIG_SOURCE=default-candidate
                break
            fi
        done
    fi
    if [ -n "$CF_CONFIG" ]; then
        _fs=$(env_path "$CF_CONFIG")
        if [ -f "$_fs" ]; then
            CF_CONFIG_EXISTS=yes
            CF_CONFIG_PERM=$(stat -c '%a %U:%G' "$_fs" 2>/dev/null)
            if _core_can_read "$_fs"; then
                CF_CONFIG_READABLE=yes
                CF_CONFIG_KEYS=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\)[[:space:]]*=.*/\1/p' "$_fs" | tr '\n' ' ' | sed 's/ $//')
                CF_SNELL_LISTEN=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$_fs" | head -n 1 | sed 's/[[:space:]]*$//')
                CF_SNELL_MODE=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p' "$_fs" | head -n 1 | sed 's/[[:space:]]*$//')
                if grep -Eq '^[[:space:]]*psk[[:space:]]*=[[:space:]]*[^[:space:]]' "$_fs"; then
                    CF_PSK=configured
                else
                    CF_PSK=missing
                fi
            else
                CF_CONFIG_READABLE=no
                CF_NOTES="${CF_NOTES}配置文件 $CF_CONFIG 存在但当前用户无读取权限, 字段与监听信息不可用
"
            fi
        else
            CF_NOTES="${CF_NOTES}配置路径 $CF_CONFIG 不存在
"
        fi
    fi

    # 日志 metadata
    CF_LOG_OUT_EXISTS=no
    CF_LOG_OUT_SIZE=
    CF_LOG_ERR_EXISTS=no
    CF_LOG_ERR_SIZE=
    if [ -n "$CF_LOG_OUT" ] && [ -f "$(env_path "$CF_LOG_OUT")" ]; then
        CF_LOG_OUT_EXISTS=yes
        CF_LOG_OUT_SIZE=$(_core_file_size "$(env_path "$CF_LOG_OUT")")
    fi
    if [ -n "$CF_LOG_ERR" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then
        CF_LOG_ERR_EXISTS=yes
        CF_LOG_ERR_SIZE=$(_core_file_size "$(env_path "$CF_LOG_ERR")")
    fi

    # 监听: 有服务进程且能读到其 socket 时按进程归属, 否则按配置端口匹配并如实标注
    _ports=$(_core_listen_ports "$CF_SNELL_LISTEN")
    if [ -n "$CF_PID" ] && [ -r "$(env_path "/proc/$CF_PID/fd")" ]; then
        _inodes=$(_core_socket_inodes "$CF_PID")
        if [ "$_inodes" != " " ]; then
            CF_LISTEN=$(_core_proc_listeners "$_inodes" "")
            CF_LISTEN_ATTRIB=pid
        fi
    fi
    if [ "$CF_LISTEN_ATTRIB" = none ] && [ -n "$_ports" ] && [ "$CF_STATE" = running ]; then
        CF_LISTEN=$(_core_proc_listeners "" "$_ports")
        CF_LISTEN_ATTRIB=config-port
        if [ -n "$CF_PID" ]; then
            CF_NOTES="${CF_NOTES}无法读取服务进程的 socket, 监听按配置端口匹配, 未确认归属于该进程
"
        fi
    fi
}

# AnyTLS Gateway 事实: 配置路径 (OpenRC 脚本 -config, 其次默认路径), 日志 metadata, 按进程 socket 归属的监听, 配置里的 listen 端口
core_anytlsgw_discover_extra() {
    local _argc _fs _inodes _c _ports
    CF_CONFIG=
    CF_CONFIG_SOURCE=none
    CF_CONFIG_EXISTS=no
    CF_CONFIG_READABLE=unknown
    CF_CONFIG_PERM=
    CF_LISTEN=
    CF_LISTEN_ATTRIB=none
    _ports=
    _argc=$(printf '%s' "$CF_INIT_ARGS" | awk '{ for (i = 1; i < NF; i++) if ($i == "-config" || $i == "-c") { print $(i + 1); exit } }')
    if [ -n "$_argc" ]; then
        CF_CONFIG=$_argc
        CF_CONFIG_SOURCE=service
    else
        for _c in $(core_config_candidates anytlsgw); do
            if [ -e "$(env_path "$_c")" ]; then CF_CONFIG=$_c; CF_CONFIG_SOURCE=default-candidate; break; fi
        done
    fi
    if [ -n "$CF_CONFIG" ]; then
        _fs=$(env_path "$CF_CONFIG")
        if [ -f "$_fs" ]; then
            CF_CONFIG_EXISTS=yes
            CF_CONFIG_PERM=$(stat -c '%a %U:%G' "$_fs" 2>/dev/null)
            if _core_can_read "$_fs"; then
                CF_CONFIG_READABLE=yes
                _ports=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"[^"]*:\([0-9][0-9]*\)".*/\1/p' "$_fs" | tr '\n' ' ' | sed 's/^/ /; s/$/ /')
            else
                CF_CONFIG_READABLE=no
                CF_NOTES="${CF_NOTES}配置文件 $CF_CONFIG 存在但当前用户无读取权限, 监听信息按进程 socket 判断
"
            fi
        fi
    fi
    CF_LOG_OUT_EXISTS=no
    CF_LOG_OUT_SIZE=
    CF_LOG_ERR_EXISTS=no
    CF_LOG_ERR_SIZE=
    if [ -n "$CF_LOG_OUT" ] && [ -f "$(env_path "$CF_LOG_OUT")" ]; then CF_LOG_OUT_EXISTS=yes; CF_LOG_OUT_SIZE=$(_core_file_size "$(env_path "$CF_LOG_OUT")"); fi
    if [ -n "$CF_LOG_ERR" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then CF_LOG_ERR_EXISTS=yes; CF_LOG_ERR_SIZE=$(_core_file_size "$(env_path "$CF_LOG_ERR")"); fi
    if [ -n "$CF_PID" ] && [ -r "$(env_path "/proc/$CF_PID/fd")" ]; then
        _inodes=$(_core_socket_inodes "$CF_PID")
        if [ "$_inodes" != " " ]; then
            CF_LISTEN=$(_core_proc_listeners "$_inodes" "")
            CF_LISTEN_ATTRIB=pid
        fi
    fi
    if [ "$CF_LISTEN_ATTRIB" = none ] && [ -n "$_ports" ] && [ "$CF_STATE" = running ]; then
        CF_LISTEN=$(_core_proc_listeners "" "$_ports")
        CF_LISTEN_ATTRIB=config-port
    fi
}

# sing-box 通用事实: 配置路径 (OpenRC 脚本 -c, 其次默认路径), 日志 metadata, 按服务进程 socket 归属的监听
# 不解析配置 JSON, 因为外部部署的配置组织各不相同
core_singbox_discover_extra() {
    local _argc _argd _fs _inodes _c
    CF_CONFIG=
    CF_CONFIG_SOURCE=none
    CF_CONFIG_EXISTS=no
    CF_CONFIG_READABLE=unknown
    CF_CONFIG_PERM=
    CF_CONFIG_DIR=
    CF_LISTEN=
    CF_LISTEN_ATTRIB=none
    _argc=$(printf '%s' "$CF_INIT_ARGS" | awk '{ for (i = 1; i < NF; i++) if ($i == "-c" || $i == "--config") { print $(i + 1); exit } }')
    _argd=$(printf '%s' "$CF_INIT_ARGS" | awk '{ for (i = 1; i < NF; i++) if ($i == "-C" || $i == "--config-directory") { print $(i + 1); exit } }')
    CF_CONFIG_DIR=$_argd
    if [ -n "$_argc" ]; then
        CF_CONFIG=$_argc
        CF_CONFIG_SOURCE=service
    else
        for _c in $(core_config_candidates singbox); do
            if [ -e "$(env_path "$_c")" ]; then
                CF_CONFIG=$_c
                CF_CONFIG_SOURCE=default-candidate
                break
            fi
        done
    fi
    if [ -n "$CF_CONFIG" ]; then
        _fs=$(env_path "$CF_CONFIG")
        if [ -f "$_fs" ]; then
            CF_CONFIG_EXISTS=yes
            CF_CONFIG_PERM=$(stat -c '%a %U:%G' "$_fs" 2>/dev/null)
            if _core_can_read "$_fs"; then CF_CONFIG_READABLE=yes; else CF_CONFIG_READABLE=no; fi
        else
            CF_NOTES="${CF_NOTES}配置路径 $CF_CONFIG 不存在
"
        fi
    fi
    CF_LOG_OUT_EXISTS=no
    CF_LOG_OUT_SIZE=
    CF_LOG_ERR_EXISTS=no
    CF_LOG_ERR_SIZE=
    if [ -n "$CF_LOG_OUT" ] && [ -f "$(env_path "$CF_LOG_OUT")" ]; then
        CF_LOG_OUT_EXISTS=yes
        CF_LOG_OUT_SIZE=$(_core_file_size "$(env_path "$CF_LOG_OUT")")
    fi
    if [ -n "$CF_LOG_ERR" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then
        CF_LOG_ERR_EXISTS=yes
        CF_LOG_ERR_SIZE=$(_core_file_size "$(env_path "$CF_LOG_ERR")")
    fi
    if [ -n "$CF_PID" ] && [ -r "$(env_path "/proc/$CF_PID/fd")" ]; then
        _inodes=$(_core_socket_inodes "$CF_PID")
        if [ "$_inodes" != " " ]; then
            CF_LISTEN=$(_core_proc_listeners "$_inodes" "")
            CF_LISTEN_ATTRIB=pid
        fi
    fi
}

# sing-box 配置校验, 供配置事务作为 validator 使用, 只执行已确认的 ELF
core_singbox_check_config() {
    local _bin
    _bin=$(core_trusted_binary singbox) || {
        apm_err "未找到已确认为 ELF 的 sing-box, 不执行任何入口, 无法校验配置"
        return 1
    }
    "$_bin" check -c "$1"
}

# 统一的生命周期分发 (写操作, 当前全部未实现)
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
