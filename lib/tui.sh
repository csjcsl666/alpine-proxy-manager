# shellcheck shell=sh
# 统一 TUI 管理界面: 现有业务能力的交互前端, 不含任何业务规则
#
# 原则
#   - 不复制业务逻辑: 校验, 事务, 保护, 路由生成都在已有函数里, TUI 只读取输入, 调用 snell_cli 与 singbox_cli 等同一入口, 显示结果
#   - 写操作在子 shell 中执行, 业务函数里的 trap 与锁在子 shell 退出时清理, 不会污染 TUI 进程
#   - 秘密只通过 tui_read_secret 读取 (关闭回显, 任何退出路径都恢复), 通过 stdin 交给业务函数, 不进入 argv
#   - 不使用外部依赖, 没有常驻进程, 没有自动联网, 进入时只做一次 Core 发现
#   - 不依赖 UTF-8, 颜色与 ANSI 都是可选的, NO_COLOR 与 TERM=dumb 退化为纯文本
#   - 不绘制固定宽度的表格, 中文宽度不一致时仍然可读
#
# 测试接缝: tui_run 不检查 TTY, 输入全部来自 stdin, APM_TUI_ANSI 可强制开关 ANSI, APM_TUI_TEST_TTY=1 让秘密输入走 stty 路径
# 生产入口 tui_cli 要求 stdin 与 stdout 都是 TTY
#
# 菜单项的格式是换行分隔的 "键|标签", 选择后键放在 TUI_KEY, 0 与 EOF 与 q 一律返回键 back

TUI_ANSI=
TUI_COLOR=
TUI_UTF8=
TUI_IN=
TUI_KEY=
TUI_SECRET=
TUI_PICK=
TUI_STTY_SAVED=
TUI_EOF=0
TUI_RC=0
TUI_EXIT=0
TUI_TICK_ON=0

# ---- 终端能力 ----

_tui_init() {
    case ${APM_TUI_ANSI:-auto} in
        0) TUI_ANSI=0 ;;
        1) TUI_ANSI=1 ;;
        *)
            if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ]; then TUI_ANSI=1; else TUI_ANSI=0; fi
            ;;
    esac
    [ "${TERM:-}" != dumb ] || TUI_ANSI=0
    TUI_COLOR=0
    if [ "$TUI_ANSI" = 1 ] && [ -z "${NO_COLOR:-}" ]; then TUI_COLOR=1; fi
    case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) TUI_UTF8=1 ;;
        *) TUI_UTF8=0 ;;
    esac
    [ "${TERM:-}" != dumb ] || TUI_UTF8=0
}

_tui_c() { # 颜色名
    [ "$TUI_COLOR" = 1 ] || return 0
    case $1 in
        green) printf '\033[32m' ;;
        red) printf '\033[31m' ;;
        yellow) printf '\033[33m' ;;
        bold) printf '\033[1m' ;;
        off) printf '\033[0m' ;;
    esac
}

_tui_clear() {
    if [ "$TUI_ANSI" = 1 ]; then printf '\033[H\033[2J'; else printf '\n'; fi
}

_tui_header() { # 标题
    printf '============================\n'
    printf ' %s\n' "$1"
    printf '============================\n'
}

_tui_rule() { printf -- '--------------------------------\n'; }

# 状态符号, Unicode 不是功能依赖
_tui_dot() { # run | stop | err | na
    case $1 in
        run) _tui_c green; if [ "$TUI_UTF8" = 1 ]; then printf '● 运行中'; else printf '[RUNNING]'; fi; _tui_c off ;;
        stop) if [ "$TUI_UTF8" = 1 ]; then printf '○ 未运行'; else printf '[STOPPED]'; fi ;;
        err) _tui_c red; if [ "$TUI_UTF8" = 1 ]; then printf '! 异常'; else printf '[ERROR]'; fi; _tui_c off ;;
        *) if [ "$TUI_UTF8" = 1 ]; then printf '%s' '- 未安装'; else printf '[N/A]'; fi ;;
    esac
}

_tui_warn() { _tui_c yellow; printf '警告：%s\n' "$1"; _tui_c off; }

_tui_restore() {
    if [ -n "$TUI_STTY_SAVED" ]; then
        _snell_run stty "$TUI_STTY_SAVED" 2>/dev/null
        TUI_STTY_SAVED=
    fi
}

_tui_on_int() {
    _tui_restore
    printf '\n已退出\n'
    exit 130
}

_tui_in_tty() { [ -t 0 ] || [ "${APM_TUI_TEST_TTY:-}" = 1 ]; }

# ---- 输入 ----

tui_ask() { # 提示, 结果在 TUI_IN, EOF 时为空并置 TUI_EOF
    printf '%s' "$1"
    TUI_IN=
    IFS= read -r TUI_IN || TUI_EOF=1
    TUI_IN=$(printf '%s' "$TUI_IN" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# 唯一的秘密输入入口: 保存终端状态, 关闭回显, 读取, 无论成功失败都恢复
# read 在没有末尾换行时返回非零但变量已赋值, 所以不能清空
tui_read_secret() { # 提示, 结果在 TUI_SECRET
    TUI_SECRET=
    printf '%s' "$1"
    if _tui_in_tty; then
        TUI_STTY_SAVED=$(_snell_run stty -g 2>/dev/null) || TUI_STTY_SAVED=
        if [ -z "$TUI_STTY_SAVED" ]; then
            printf '\n'
            apm_err "无法关闭终端回显, 拒绝输入秘密"
            return 1
        fi
        _snell_run stty -echo 2>/dev/null
        IFS= read -r TUI_SECRET || :
        _tui_restore
        printf '\n'
    else
        IFS= read -r TUI_SECRET || :
    fi
    return 0
}

tui_confirm() { # 说明文字, 默认 N
    local _a
    printf '%s\n' "$1"
    printf '继续？[y/N]：'
    _a=
    IFS= read -r _a || { TUI_EOF=1; _a=; }
    case $_a in y|Y|yes|YES) return 0 ;; esac
    printf '已取消\n'
    return 1
}

_tui_pause() {
    local _x
    printf '\n按 Enter 返回'
    IFS= read -r _x || TUI_EOF=1
    printf '\n'
}

# ---- 主菜单内存显示与空闲刷新 ----
# 只在主菜单展示期间刷新, 不创建后台进程: 菜单等待输入时用 read -t 超时, 超时就只重写内存那一行
# 用保存光标 绝对定位 写入 恢复光标, 所以已经键入的字符与光标位置都不受影响, 菜单不会重绘
# 输入无效时清屏重绘整个主菜单并带一行提示, 刷新继续; 终端放不下整个主菜单 没有 read -t 或不是交互终端时不刷新, 行为与之前完全相同

# 内存行, 复用 env_probe_memory 的口径: cgroup 优先, 其次 meminfo, 读不到就显示未知
_tui_mem_text() {
    env_probe_memory 2>/dev/null
    if [ "${ENV_MEM_LIMIT:-0}" -gt 0 ] 2>/dev/null && [ "${ENV_MEM_CUR:-0}" -ge 0 ] 2>/dev/null; then
        printf '内存：%s / %s MiB' "$(apm_mib "$ENV_MEM_CUR")" "$(apm_mib "$ENV_MEM_LIMIT")"
    else
        printf '内存：未知'
    fi
}

# 是否启用刷新: 间隔 APM_TUI_REFRESH 秒 (默认 5, 最小 2, 0 关闭), 需要交互终端 ANSI 与 read -t, 参数是提示符所在的行号
_tui_tick_init() {
    local _n _rows
    TUI_TICK_ON=0
    TUI_TICK_SEC=
    _n=${APM_TUI_REFRESH:-5}
    case $_n in ''|*[!0-9]*) return 0 ;; esac
    [ "$_n" -gt 0 ] || return 0
    [ "$_n" -ge 2 ] || _n=2
    [ "$TUI_ANSI" = 1 ] || return 0
    { { [ -t 0 ] && [ -t 1 ]; } || [ "${APM_TUI_TEST_TTY:-}" = 1 ]; } || return 0
    # 这个 shell 的 read 必须支持 -t, 不支持就不刷新
    # read -t 不是 POSIX, 这里先探测, 不支持的 shell 直接不刷新
    # shellcheck disable=SC3045
    ( IFS= read -r -t 1 _tui_probe ) </dev/null 2>/dev/null
    [ $? -eq 1 ] || return 0
    # 刷新用绝对行号重写内存行, 所以整个主菜单 (到提示符所在行 $1) 必须完整在屏幕内, 否则滚动后行号会错
    # 标准 24 行终端可以: 清屏后提示符在第 20 行, 非 root 多一行警告, 重绘时再多一行提示
    _rows=$(stty size 2>/dev/null | cut -d' ' -f1)
    case $_rows in ''|*[!0-9]*) _rows=${LINES:-0} ;; esac
    case $_rows in ''|*[!0-9]*) return 0 ;; esac
    [ "$_rows" -ge $((${1:-21} + 1)) ] || return 0
    TUI_TICK_SEC=$_n
    TUI_TICK_ON=1
}

# 重写内存行 (绝对第 7 行, 前提是主菜单刚清屏重绘), 保存与恢复光标
_tui_tick_mem() {
    printf '\033%s\033[7;1H\033[2K%s\033%s' 7 "$(_tui_mem_text)" 8
}

# 当前时间, 单位 0.01 秒, 结果在 TUI_NOW: 读 /proc/uptime 不需要启动进程, 读不到就退回整秒的 date
_tui_now() {
    local _u _f
    if IFS=' ' read -r _u _f < /proc/uptime 2>/dev/null && [ -n "$_u" ]; then
        _f=${_u#*.}
        TUI_NOW=$(( ${_u%.*} * 100 + ${_f#0} ))
    else
        TUI_NOW=$(( $(date +%s) * 100 ))
    fi
}

# 读取一行选择: 刷新开启时每个间隔超时一次并更新内存行, 其余与 read -r 完全一致
# BusyBox 的超时与 EOF 返回码相同, 所以用耗时区分: 等满间隔才算超时, EOF (含 Ctrl-D 与连接断开) 会提前返回
_tui_read_choice() {
    local _t0
    if [ "${TUI_TICK_ON:-0}" != 1 ]; then
        IFS= read -r _c
        return $?
    fi
    while :; do
        _tui_now
        _t0=$TUI_NOW
        # shellcheck disable=SC3045
        if IFS= read -r -t "$TUI_TICK_SEC" _c; then return 0; fi
        _tui_now
        # 没等满间隔就失败: EOF 或错误, 不重试 (留 50 毫秒余量给调度抖动)
        [ $((TUI_NOW - _t0)) -ge $((TUI_TICK_SEC * 100 - 5)) ] || return 1
        _tui_tick_mem
    done
}

# tui_choose ITEMS BACKLABEL: 无效输入只提示并继续, 0 q EOF 返回 back
tui_choose() {
    local _n _c
    while :; do
        _n=$(printf '%s\n' "$1" | grep -c .)
        if [ "$_n" -gt 0 ]; then
            printf '%s\n' "$1" | awk -F'|' 'NF { printf "%d. %s\n", ++i, substr($0, index($0, "|") + 1) }'
        fi
        printf '0. %s\n' "$2"
        printf '\n请选择：'
        _c=
        if ! _tui_read_choice; then
            TUI_EOF=1
            TUI_KEY=back
            printf '\n'
            return 0
        fi
        _c=$(printf '%s' "$_c" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_c in
            0|q|Q) TUI_KEY=back; return 0 ;;
            ''|*[!0-9]*)
                # 主菜单刷新模式: 不在下面追加重打 (会滚屏), 交给主菜单清屏重绘并带一行提示
                if [ "${TUI_TICK_ON:-0}" = 1 ]; then TUI_KEY=invalid; return 0; fi
                printf '输入无效，请重新选择。\n\n'
                ;;
            *)
                if [ "$_c" -ge 1 ] && [ "$_c" -le "$_n" ]; then
                    TUI_KEY=$(printf '%s\n' "$1" | grep . | sed -n "${_c}p" | cut -d'|' -f1)
                    return 0
                fi
                if [ "${TUI_TICK_ON:-0}" = 1 ]; then TUI_KEY=invalid; return 0; fi
                printf '输入无效，请重新选择。\n\n'
                ;;
        esac
    done
}

# ---- 业务调用 ----
# 写操作与带输出的操作都在子 shell 里执行, stdin 默认断开, 不会吃掉 TUI 的输入

_tui_do() { # 命令...
    ( "$@" ) </dev/null
    TUI_RC=$?
}

_tui_do_secret() { # 秘密 命令...
    local _s
    _s=$1
    shift
    printf '%s\n' "$_s" | ( "$@" )
    TUI_RC=$?
}

# 命令之后统一收尾: 失败给出提示, 然后等待
_tui_done() {
    if [ "$TUI_RC" -ne 0 ]; then
        printf '\n该操作没有完成 (返回码 %s), 上面是业务层给出的原因\n' "$TUI_RC"
    fi
    _tui_pause
}

_tui_need_root() {
    if env_is_root; then return 0; fi
    printf '此操作需要 root, TUI 不会自动 sudo\n'
    _tui_pause
    return 1
}

# ---- Core 状态 ----

# 设置 TUI_CK 为 managed | external | unverified | none, 并保留 core_discover 的全部 CF_*
_tui_core_kind() {
    core_discover "$1"
    case $CF_INSTALLED in
        no) TUI_CK=none ;;
        unverified) TUI_CK=unverified ;;
        *) if [ "$CF_DEPLOYMENT" = managed ]; then TUI_CK=managed; else TUI_CK=external; fi ;;
    esac
}

_tui_state_dot() {
    case $CF_STATE in
        running) _tui_dot run ;;
        stopped) _tui_dot stop ;;
        not-installed) _tui_dot na ;;
        *) _tui_dot err ;;
    esac
}

_tui_core_line() { # key
    _tui_core_kind "$1"
    printf '  %-10s ' "$CF_NAME"
    _tui_state_dot
    case $TUI_CK in
        managed) printf '  已接管' ;;
        external) printf '  现有部署，未接管' ;;
        unverified) printf '  未确认' ;;
    esac
    printf '\n'
}

_tui_core_notes() {
    if [ -n "$CF_NOTES" ]; then
        printf '%s' "$CF_NOTES" | sed 's/^/  注意：/'
    fi
}

# ---- 日志与状态 ----

_tui_log() { # key
    local _n
    tui_ask "显示最后多少行 [20，最多 200]："
    _n=${TUI_IN:-20}
    if [ "$1" = snell ]; then _tui_do snell_cli log "$_n"; else _tui_do singbox_cli log "$_n"; fi
    _tui_done
}

tui_log_menu() {
    while :; do
        _tui_clear
        _tui_header "日志"
        printf '提示：日志可能包含访问目标，注意不要公开\n\n'
        tui_choose "snell|Snell 日志
singbox|sing-box 日志" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            snell) _tui_log snell ;;
            singbox) _tui_log singbox ;;
        esac
    done
}

_tui_resources() {
    local _k _p
    env_probe_memory
    # 标签按真实来源区分: 有 cgroup 上限时这是容器内存, 否则才是系统内存, 读不到就显示未知, 不编数字
    if [ "${ENV_MEM_LIMIT:-0}" -le 0 ] 2>/dev/null || [ "${ENV_MEM_CUR:-0}" -lt 0 ] 2>/dev/null; then
        printf '内存：未知\n'
    else
        case $ENV_MEM_LIMIT_SRC in
            cgroup-*)
                printf '容器内存：当前使用 %s MiB，限制 %s MiB（来源 %s）\n' "$(apm_mib "$ENV_MEM_CUR")" "$(apm_mib "$ENV_MEM_LIMIT")" "$ENV_MEM_LIMIT_SRC"
                [ "$ENV_MEM_CUR_SRC" = cgroup ] || printf '说明：当前使用量来自 /proc/meminfo，不是 cgroup 统计\n'
                ;;
            *) printf '系统内存：当前使用 %s MiB，总计 %s MiB（没有容器内存限制）\n' "$(apm_mib "$ENV_MEM_CUR")" "$(apm_mib "$ENV_MEM_LIMIT")" ;;
        esac
    fi
    for _k in $CORE_KEYS; do
        core_discover "$_k"
        _p=$CF_PID
        if [ -n "$_p" ] && [ -r "$(env_path "/proc/$_p/status")" ]; then
            printf '%s：PID %s，RSS %s kB，HWM %s kB\n' "$CF_NAME" "$_p" \
                "$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "$(env_path "/proc/$_p/status")")" \
                "$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\).*/\1/p' "$(env_path "/proc/$_p/status")")"
        else
            printf '%s：没有运行进程\n' "$CF_NAME"
        fi
    done
    printf '说明：只在选择时读取一次，TUI 不做持续刷新\n'
}

tui_status_menu() {
    while :; do
        _tui_clear
        _tui_header "状态与诊断"
        tui_choose "status|系统状态
core|Core 状态
doctor|doctor 环境检查
res|资源使用" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            status) _tui_do report_status; _tui_done ;;
            core) _tui_do report_core_list; _tui_done ;;
            doctor) _tui_do report_doctor; _tui_done ;;
            res) _tui_do _tui_resources; _tui_done ;;
        esac
    done
}

# Manager 自更新的确认与执行: 只更新 Manager 本身, 实际升级由 manager_cli update 复用现有安装器完成
# 成功后当前 TUI 进程仍是旧代码, 所以提示重新运行 apm 并退出, 避免误以为已经进入新版
_tui_manager_confirm_update() { # 目标版本
    _tui_need_root || return 0
    tui_confirm "Manager · 更新

当前版本：$(apm_version)
目标版本：$1

此次操作只更新 Alpine Proxy Manager。

以下内容不会被主动修改：
- Snell 服务及配置
- sing-box 服务及配置
- 协议实例
- SOCKS Profile
- 目标访问限制
- PSK / 密钥
- 客户端连接地址
" || { _tui_pause; return 0; }
    _tui_do manager_cli update
    if [ "$TUI_RC" -eq 0 ]; then TUI_EXIT=1; fi
    _tui_done
}

# 查询并展示, 结果的返回码 10 表示发现新版本, 最新版本号放在 TUI_MGR_VER
_tui_manager_probe() {
    local _out
    printf '正在查询 GitHub 最新正式 Release ...\n\n'
    _out=$( ( manager_cli check-update ) </dev/null 2>&1 )
    TUI_RC=$?
    printf '%s\n' "$_out"
    TUI_MGR_VER=$(printf '%s\n' "$_out" | sed -n 's/^最新正式版：//p' | head -n 1)
    printf '%s' "$TUI_MGR_VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || TUI_MGR_VER=
}

tui_manager_check() {
    _tui_clear
    _tui_header "Manager · 检查更新"
    _tui_manager_probe
    if [ "$TUI_RC" -eq 10 ] && [ -n "$TUI_MGR_VER" ]; then
        printf '\n'
        tui_choose "up|更新到 $TUI_MGR_VER" "返回"
        [ "$TUI_KEY" != up ] || _tui_manager_confirm_update "$TUI_MGR_VER"
    else
        _tui_pause
    fi
}

tui_manager_update() {
    _tui_clear
    _tui_header "Manager · 更新"
    _tui_need_root || return 0
    _tui_manager_probe
    if [ "$TUI_RC" -eq 10 ] && [ -n "$TUI_MGR_VER" ]; then
        printf '\n'
        _tui_manager_confirm_update "$TUI_MGR_VER"
    else
        _tui_pause
    fi
}

tui_manager_menu() {
    while :; do
        _tui_clear
        _tui_header "Manager 管理"
        printf '当前版本：%s\nBuild：%s\n\n' "$(apm_version)" "$(apm_build)"
        tui_choose "ver|查看版本
check|检查更新
update|更新 Manager
doctor|检查环境
help|查看帮助" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            ver) _tui_do apm_print_version; _tui_done ;;
            check) tui_manager_check ;;
            update) tui_manager_update ;;
            doctor) _tui_do report_doctor; _tui_done ;;
            help)
                if command -v usage >/dev/null 2>&1; then _tui_do usage; else printf '帮助：proxy-manager help\n'; TUI_RC=0; fi
                _tui_done
                ;;
        esac
        [ "$TUI_EXIT" != 1 ] || return 0
    done
}

# ---- Core: 公共的安装 卸载 ----

# sing-box 卸载: 先列出会删除的内容与数量, 再让用户在 完整卸载 与 仅卸载程序 之间明确选择, 然后再确认, 默认取消
# 实际删除复用 singbox_cli uninstall --purge 与 uninstall, 这里不另写清理逻辑
# 完整卸载只删除 sing-box 专属的数据, Snell 与其他 Core 不受影响 (清理范围由 singbox_uninstall 决定并有测试)
_tui_singbox_uninstall() {
    local _ni _ns _f
    _tui_need_root || return 0
    _tui_count_instances
    _ni=$TUI_N_TOTAL
    _ns=0
    for _f in $(state_list_confs "$(state_socks_dir)"); do _ns=$((_ns + 1)); done
    _tui_clear
    _tui_header "卸载 sing-box"
    printf '完整卸载会删除 sing-box 及其专属的托管数据：\n'
    printf '  - sing-box 程序与服务\n'
    printf '  - 协议实例 %s 个（含各自的目标访问限制与客户端连接地址）\n' "$_ni"
    printf '  - SOCKS Profile %s 个\n' "$_ns"
    printf '  - 证书、运行配置、配置备份与日志\n'
    printf '  - 由 Manager 创建的 sing-box 用户\n'
    printf '不会修改 Snell 或其他 Core 的任何数据。\n'
    printf '完整卸载不可恢复，客户端将无法再连接这些协议实例。\n'
    if [ ! -f "$(env_path "$SB_MARK_FILE")" ]; then
        _tui_warn "$SB_ETC 没有 Manager 标记，完整卸载时它会被保留"
    fi
    printf '\n'
    tui_choose "full|完整卸载：删除 sing-box 及上述全部数据
keep|仅卸载程序：保留配置、证书、实例与 SOCKS Profile，便于重新安装" "返回"
    case $TUI_KEY in
        back) return 0 ;;
        full)
            tui_confirm "即将完整卸载 sing-box 并删除上述全部数据，此操作不可恢复" || { _tui_pause; return 0; }
            _tui_do singbox_cli uninstall --purge
            ;;
        keep)
            tui_confirm "即将卸载 sing-box 程序，配置、证书、实例与 SOCKS Profile 会保留" || { _tui_pause; return 0; }
            _tui_do singbox_cli uninstall
            ;;
    esac
    _tui_done
}

_tui_core_uninstall() { # key
    local _cli
    if [ "$1" = snell ]; then _cli=snell_cli; else _cli=singbox_cli; fi
    _tui_need_root || return 0
    tui_confirm "即将卸载 $CF_NAME，默认保留配置与日志" || { _tui_pause; return 0; }
    if tui_confirm "是否同时删除配置、日志与证书 (--purge)？此操作不可恢复"; then
        _tui_do "$_cli" uninstall --purge
    else
        _tui_do "$_cli" uninstall
    fi
    _tui_done
}

_tui_core_lifecycle() { # key op
    local _cli
    if [ "$1" = snell ]; then _cli=snell_cli; else _cli=singbox_cli; fi
    _tui_need_root || return 0
    case $2 in
        stop) tui_confirm "即将停止 $CF_NAME，所有连接会中断" || { _tui_pause; return 0; } ;;
        restart) tui_confirm "即将重启 $CF_NAME，现有连接会短暂中断" || { _tui_pause; return 0; } ;;
    esac
    _tui_do "$_cli" "$2"
    _tui_done
}

# ---- Snell ----

tui_snell_config_menu() {
    local _pw
    while :; do
        _tui_clear
        _tui_header "Snell 修改配置"
        _tui_do snell_cli config show
        printf '\n'
        tui_choose "listen|修改 listen
mode|修改 mode
psk|修改 PSK" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            listen|mode)
                _tui_need_root || continue
                tui_ask "新的 $TUI_KEY 值（留空取消）："
                [ -n "$TUI_IN" ] || continue
                _tui_do snell_cli config set "$TUI_KEY" "$TUI_IN"
                _tui_done
                ;;
            psk)
                _tui_need_root || continue
                tui_read_secret "新的 PSK（输入不回显，留空自动生成）：" || { _tui_pause; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                if [ -z "$_pw" ]; then
                    tui_confirm "将自动生成新的 PSK，并在结果中显示一次" || { _tui_pause; continue; }
                    _tui_do snell_cli config set psk --generate
                else
                    _tui_do_secret "$_pw" snell_cli config set psk --stdin
                fi
                _pw=
                _tui_done
                ;;
        esac
    done
}

_tui_snell_install() {
    local _pw _port
    _tui_need_root || return 0
    tui_confirm "将下载 Snell 官方 release 并安装为 Manager 管理的服务" || { _tui_pause; return 0; }
    tui_ask "端口（留空随机选择）："
    _port=$TUI_IN
    tui_read_secret "PSK（输入不回显，留空自动生成）：" || { _tui_pause; return 0; }
    _pw=$TUI_SECRET
    TUI_SECRET=
    set --
    [ -z "$_port" ] || set -- --port "$_port"
    if [ -z "$_pw" ]; then
        tui_confirm "将自动生成 PSK，并在结果中显示一次" || { _tui_pause; return 0; }
        _tui_do snell_cli install "$@"
    else
        _tui_do_secret "$_pw" snell_cli install "$@" --psk-stdin
    fi
    _pw=
    _tui_done
}

# Snell 的客户端信息: 只有两个操作, 不需要先设置客户端连接地址
#   查看连接信息 经 snell export info 按需查询服务器公网 IP, 端口与版本来自 Snell 现有配置, 只读, 查询失败时其余信息照常显示
#   查看 PSK 先确认, 默认 N, 经 snell export secret 显示, 不生成不修改
tui_snell_client_menu() {
    while :; do
        _tui_clear
        _tui_header "Snell · 客户端信息"
        tui_choose "info|查看连接信息
psk|查看 PSK" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            info) _tui_do snell_cli export info; _tui_done ;;
            psk)
                tui_confirm "即将显示 Snell PSK。
请注意终端记录和截图可能泄漏凭据。" || { _tui_pause; continue; }
                _tui_do snell_cli export secret
                _tui_done
                ;;
        esac
    done
}

tui_snell_menu() {
    local _items
    while :; do
        _tui_clear
        _tui_header "Snell"
        _tui_core_kind snell
        printf '状态：'
        _tui_state_dot
        printf '\n'
        case $TUI_CK in
            none) printf '管理：未安装\n' ;;
            unverified) printf '管理：未确认\n'; _tui_warn "检测到名为 snell 的入口，但它不是已确认的 ELF，拒绝写操作" ;;
            external) printf '管理：现有部署，未接管\n'; printf '本项目不会修改现有部署，只提供只读信息\n' ;;
            managed)
                printf '管理：已接管\n'
                printf 'Release：%s\n' "$CF_VERSION_EXACT"
                printf '版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
                printf '监听：%s\n' "${CF_SNELL_LISTEN:--}"
                ;;
        esac
        case $CF_STATE in crashed|broken) _tui_warn "Snell 状态异常，详情见详细信息与日志" ;; esac
        _tui_core_notes
        printf '\n'
        case $TUI_CK in
            none) _items="install|安装 Snell" ;;
            unverified) _items="info|查看详细信息" ;;
            external) _items="info|查看详细信息
log|查看日志" ;;
            managed)
                _items="info|查看详细信息"
                if [ "$CF_STATE" = running ]; then
                    _items="$_items
stop|停止
restart|重启"
                else
                    _items="$_items
start|启动"
                fi
                _items="$_items
config|修改配置
log|查看日志
client|客户端信息
update|更新
uninstall|卸载"
                ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            install) _tui_snell_install ;;
            info) _tui_do snell_cli info; _tui_done ;;
            start|stop|restart) _tui_core_lifecycle snell "$TUI_KEY" ;;
            config) tui_snell_config_menu ;;
            log) _tui_log snell ;;
            client) tui_snell_client_menu ;;
            update)
                _tui_need_root || continue
                tui_confirm "将联网下载 Snell 官方 release，失败会自动回滚" || { _tui_pause; continue; }
                _tui_do snell_cli update
                _tui_done
                ;;
            uninstall) _tui_core_uninstall snell ;;
        esac
    done
}

# ---- sing-box Core ----

_tui_count_instances() {
    local _f _t _e
    _t=0
    _e=0
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _t=$((_t + 1))
        [ "$(kv_get "$_f" enabled)" = true ] && _e=$((_e + 1))
    done
    TUI_N_TOTAL=$_t
    TUI_N_ON=$_e
}

_tui_singbox_install() {
    _tui_need_root || return 0
    tui_confirm "将下载 sing-box 官方 release 并安装为 Manager 管理的服务" || { _tui_pause; return 0; }
    _tui_do singbox_cli install
    _tui_done
}

tui_singbox_menu() {
    local _items
    while :; do
        _tui_clear
        _tui_header "sing-box"
        _tui_core_kind singbox
        printf '状态：'
        _tui_state_dot
        printf '\n'
        case $TUI_CK in
            none) printf '管理：未安装\n' ;;
            unverified) printf '管理：未确认\n'; _tui_warn "检测到名为 sing-box 的入口，但它不是已确认的 ELF，拒绝写操作" ;;
            external) printf '管理：现有部署，未接管\n'; printf '本项目不会修改现有部署，只提供只读信息\n' ;;
            managed)
                _tui_count_instances
                printf '管理：已接管\n'
                printf 'Release：%s\n' "$CF_VERSION_EXACT"
                printf '版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
                printf '协议实例：%s，启用 %s\n' "$TUI_N_TOTAL" "$TUI_N_ON"
                ;;
        esac
        case $CF_STATE in crashed|broken) _tui_warn "sing-box 状态异常，详情见详细信息与日志" ;; esac
        _tui_core_notes
        printf '\n'
        case $TUI_CK in
            none) _items="install|安装 sing-box" ;;
            unverified) _items="info|查看详细信息" ;;
            external) _items="info|查看详细信息
log|查看日志" ;;
            managed)
                _items="info|查看详细信息
instances|协议实例
socks|SOCKS 出口"
                if [ "$CF_STATE" = running ]; then
                    _items="$_items
stop|停止
restart|重启"
                else
                    _items="$_items
start|启动"
                fi
                _items="$_items
check|检查配置
log|查看日志
update|更新
uninstall|卸载"
                ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            install) _tui_singbox_install ;;
            info) _tui_do singbox_cli info; _tui_done ;;
            instances) tui_instances_menu ;;
            socks) tui_socks_menu ;;
            start|stop|restart) _tui_core_lifecycle singbox "$TUI_KEY" ;;
            check) _tui_do singbox_cli check; _tui_done ;;
            log) _tui_log singbox ;;
            update)
                _tui_need_root || continue
                tui_confirm "将联网下载 sing-box 官方 release，更新前会用新二进制检查当前配置，失败会回滚" || { _tui_pause; continue; }
                _tui_do singbox_cli update
                _tui_done
                ;;
            uninstall) _tui_singbox_uninstall ;;
        esac
    done
}

# ---- 实例选择与展示 ----

# sing-box 实例相关的写操作要求 Core 已被接管
_tui_sb_managed() {
    _tui_core_kind singbox
    if [ "$TUI_CK" = managed ]; then return 0; fi
    case $TUI_CK in
        none) printf 'sing-box 尚未安装，请先在 sing-box 菜单中安装\n' ;;
        external) printf 'sing-box 是现有部署，未接管，本项目不会修改它\n' ;;
        *) printf 'sing-box 状态未确认，拒绝写操作\n' ;;
    esac
    _tui_pause
    return 1
}

_tui_inst_summary() { # FILE
    local _st _l
    if [ "$(kv_get "$1" enabled)" = true ]; then _st=已启用; else _st=已禁用; fi
    sb_instance_validate "$1" >/dev/null 2>&1 || _st="$_st，配置无效"
    printf '%s\n' "$(kv_get "$1" id) ($(kv_get "$1" type), $_st)"
    printf '  内部监听：%s 端口 %s / %s\n' "$(kv_get "$1" listen)" "$(kv_get "$1" listen_port)" "$(_sb_type_transport "$(kv_get "$1" type)" | tr 'a-z+' 'A-Z+')"
    _l=$(_sb_egress_show "$1" | sed -n 1p | sed 's/^  //')
    printf '  %s\n' "$_l"
    _l=$(_sb_policy_show "$1" | sed -n 1p | sed 's/^  //')
    printf '  %s\n' "$_l"
}

# 选择实例, 结果在 TUI_PICK, 选择返回时失败
_tui_pick_instance() {
    local _f _items _id
    _items=
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _id=$(kv_get "$_f" id)
        _items="${_items}${_id}|${_id} ($(kv_get "$_f" type))
"
    done
    if [ -z "$(printf '%s' "$_items" | tr -d '\n')" ]; then
        printf '(没有实例)\n'
        _tui_pause
        return 1
    fi
    tui_choose "$_items" "返回"
    [ "$TUI_KEY" != back ] || return 1
    TUI_PICK=$TUI_KEY
}

# ---- 协议实例 ----

_tui_gen_confirm() { # 说明
    tui_confirm "将自动生成$1，并在结果中显示一次"
}

_tui_add_instance() { # 协议
    local _t _port _sni _pw _uuid _cc _m
    _t=$1
    _tui_sb_managed || return 0
    _tui_need_root || return 0
    set --
    tui_ask "监听端口（留空随机选择）："
    [ -z "$TUI_IN" ] || set -- "$@" --port "$TUI_IN"
    case $_t in
        anytls|hysteria2|tuic)
            tui_ask "TLS server-name（留空使用默认）："
            [ -z "$TUI_IN" ] || set -- "$@" --server-name "$TUI_IN"
            ;;
    esac
    if [ "$_t" = tuic ]; then
        tui_ask "UUID（留空自动生成）："
        [ -z "$TUI_IN" ] || set -- "$@" --uuid "$TUI_IN"
        tui_ask "congestion-control（cubic、new_reno、bbr，留空使用默认）："
        [ -z "$TUI_IN" ] || set -- "$@" --congestion-control "$TUI_IN"
    fi
    if [ "$_t" = shadowsocks ]; then
        tui_ask "method（留空使用默认 $SB_SS_DEFAULT_METHOD）："
        [ -z "$TUI_IN" ] || set -- "$@" --method "$TUI_IN"
    fi
    tui_read_secret "密码或密钥（输入不回显，留空自动生成）：" || { _tui_pause; return 0; }
    _pw=$TUI_SECRET
    TUI_SECRET=
    if [ -z "$_pw" ]; then
        _tui_gen_confirm "密码" || { _tui_pause; return 0; }
        _tui_do singbox_cli add "$_t" "$@"
    else
        _tui_do_secret "$_pw" singbox_cli add "$_t" "$@" --password-stdin
    fi
    _pw=
    _tui_done
}

tui_instances_menu() {
    local _f _any
    while :; do
        _tui_clear
        _tui_header "协议实例"
        _any=0
        for _f in $(state_list_confs "$(state_instances_dir)"); do
            _any=1
            _tui_inst_summary "$_f"
        done
        [ "$_any" = 1 ] || printf '(没有实例)\n'
        printf '\n'
        tui_choose "manage|管理现有实例
anytls|添加 AnyTLS
hysteria2|添加 Hysteria2
tuic|添加 TUIC
shadowsocks|添加 Shadowsocks" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            manage) _tui_pick_instance && tui_instance_menu "$TUI_PICK" ;;
            *) _tui_add_instance "$TUI_KEY" ;;
        esac
    done
}

tui_instance_edit_menu() { # ID
    local _f _t _items _pw _m
    _f=$(state_instances_dir)/$1.conf
    while [ -f "$_f" ]; do
        _t=$(kv_get "$_f" type)
        _tui_clear
        _tui_header "修改 $1"
        _items="port|修改监听端口
listen|修改监听地址"
        if _sb_type_tls "$_t"; then _items="$_items
server-name|修改 TLS server-name"; fi
        if [ "$_t" = tuic ]; then _items="$_items
uuid|修改 UUID
congestion-control|修改 congestion-control"; fi
        if [ "$_t" = shadowsocks ]; then _items="$_items
method|修改 method 与密钥"; fi
        _items="$_items
password|修改密码"
        [ "$_t" != shadowsocks ] || _items=$(printf '%s\n' "$_items" | sed 's/^password|修改密码$/password|修改密钥/')
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            port|listen|server-name|congestion-control)
                _tui_need_root || continue
                if [ "$TUI_KEY" = congestion-control ]; then tui_ask "取值 ($SB_TUIC_CC，留空取消)："; else tui_ask "新的值（留空取消）："; fi
                [ -n "$TUI_IN" ] || continue
                _tui_do singbox_cli set "$1" "$TUI_KEY" "$TUI_IN"
                _tui_done
                ;;
            uuid)
                _tui_need_root || continue
                tui_ask "新的 UUID（留空自动生成）："
                if [ -z "$TUI_IN" ]; then _tui_do singbox_cli set "$1" uuid --generate; else _tui_do singbox_cli set "$1" uuid "$TUI_IN"; fi
                _tui_done
                ;;
            password)
                _tui_need_root || continue
                tui_read_secret "新的密码（输入不回显，留空自动生成）：" || { _tui_pause; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                if [ -z "$_pw" ]; then
                    _tui_gen_confirm "新密码" || { _tui_pause; continue; }
                    _tui_do singbox_cli set "$1" password --generate
                else
                    _tui_do_secret "$_pw" singbox_cli set "$1" password --stdin
                fi
                _pw=
                _tui_done
                ;;
            method)
                _tui_need_root || continue
                tui_ask "method（$SB_SS_METHODS，留空取消）："
                _m=$TUI_IN
                [ -n "$_m" ] || continue
                tui_read_secret "该 method 的密钥（输入不回显，留空自动生成）：" || { _tui_pause; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                if [ -z "$_pw" ]; then
                    _tui_gen_confirm "密钥" || { _tui_pause; continue; }
                    _tui_do singbox_cli set "$1" method "$_m" --generate
                else
                    _tui_do_secret "$_pw" singbox_cli set "$1" method "$_m" --stdin
                fi
                _pw=
                _tui_done
                ;;
        esac
    done
}

# 启用或禁用实例会重新生成 sing-box 配置, Core 运行时需要重启整个 sing-box
# 只有 Core 正在运行且还有其他启用的实例时才提示, 默认取消
_tui_toggle_confirm() { # ID
    local _f _n
    _tui_core_kind singbox
    [ "$CF_STATE" = running ] || return 0
    _n=0
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        [ "$(kv_get "$_f" id)" != "$1" ] || continue
        [ "$(kv_get "$_f" enabled)" = true ] && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] || return 0
    tui_confirm "此操作需要重启 sing-box，
可能短暂影响该 Core 下的其他协议实例。" || { _tui_pause; return 1; }
}

tui_instance_menu() { # ID
    local _f _t _items _ep
    _f=$(state_instances_dir)/$1.conf
    while [ -f "$_f" ]; do
        _t=$(kv_get "$_f" type)
        _tui_clear
        _tui_header "$1"
        _tui_do singbox_cli show "$1"
        _ep=$(kv_get "$_f" public.host)
        if [ -z "$_ep" ]; then
            printf '  客户端连接地址：未配置\n'
        else
            printf '  客户端连接地址：%s:%s\n' "$_ep" "$(kv_get "$_f" public.port)"
        fi
        printf '\n'
        if [ "$(kv_get "$_f" enabled)" = true ]; then
            _items="edit|修改实例
toggle|禁用"
        else
            _items="edit|修改实例
toggle|启用"
        fi
        _items="$_items
policy|目标访问限制
egress|SOCKS 出口
endpoint|客户端连接地址（Public Endpoint）
export|客户端配置
secret|查看凭据
delete|删除实例"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            edit) tui_instance_edit_menu "$1" ;;
            toggle)
                _tui_need_root || continue
                _tui_toggle_confirm "$1" || continue
                if [ "$(kv_get "$_f" enabled)" = true ]; then _tui_do singbox_cli disable "$1"; else _tui_do singbox_cli enable "$1"; fi
                _tui_done
                ;;
            policy) tui_policy_menu "$1" ;;
            egress) tui_egress_menu "$1" ;;
            endpoint) tui_endpoint_menu "$1" ;;
            export) tui_export_menu "$1" ;;
            secret) _tui_show_secret "$1" ;;
            delete)
                _tui_need_root || continue
                tui_confirm "即将删除实例 $1，客户端将无法再连接" || { _tui_pause; continue; }
                _tui_do singbox_cli delete "$1"
                _tui_done
                ;;
        esac
    done
}

_tui_show_secret() { # ID
    tui_confirm "即将显示客户端凭据。终端记录或截图可能包含 Secret。" || { _tui_pause; return 0; }
    _tui_do singbox_cli export "$1" secret
    _tui_done
}

# ---- 目标访问限制 ----

tui_policy_menu() { # ID
    local _f _d _h
    _f=$(state_instances_dir)/$1.conf
    while [ -f "$_f" ]; do
        _tui_clear
        _tui_header "目标访问限制 $1"
        _tui_do singbox_cli access "$1" show
        if _sb_policy_present "$_f" && _sb_policy_check "$_f" >/dev/null 2>&1 && _sb_policy_on "$_f" && [ -z "$(_sb_policy_dests "$_f")" ]; then
            printf '\n'
            _tui_warn "当前 Allowlist 为空，该实例将拒绝所有目标"
        fi
        printf '\n'
        tui_choose "unrestricted|设置为不限制
allowlist|设置为 Allowlist
show|查看允许目标
add|添加允许目标
delete|删除允许目标
clear|清空允许目标" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            show) _tui_do singbox_cli access "$1" show; _tui_done ;;
            unrestricted|allowlist|clear)
                _tui_need_root || continue
                _tui_sb_managed || continue
                if [ "$TUI_KEY" = clear ]; then
                    tui_confirm "将清空全部允许目标" || { _tui_pause; continue; }
                fi
                if [ "$TUI_KEY" = allowlist ] && [ -z "$(_sb_policy_dests "$_f")" ]; then
                    tui_confirm "新的 Allowlist 为空，该实例将拒绝所有目标，之后可添加允许目标" || { _tui_pause; continue; }
                fi
                _tui_do singbox_cli access "$1" "$TUI_KEY"
                _tui_done
                ;;
            add|delete)
                _tui_need_root || continue
                _tui_sb_managed || continue
                _d=$TUI_KEY
                tui_ask "目标地址（IPv4 或 IPv6，留空取消）："
                [ -n "$TUI_IN" ] || continue
                _h=$TUI_IN
                tui_ask "目标端口："
                [ -n "$TUI_IN" ] || continue
                _tui_do singbox_cli access "$1" "$_d" "$_h" "$TUI_IN"
                _tui_done
                ;;
        esac
    done
}

# ---- SOCKS 出口 ----

tui_egress_menu() { # ID
    local _f _items _p _cur
    _f=$(state_instances_dir)/$1.conf
    while [ -f "$_f" ]; do
        _tui_clear
        _tui_header "SOCKS 出口 $1"
        _tui_do singbox_cli egress "$1" show
        _cur=$(kv_get "$_f" egress_socks)
        printf '\n'
        _items="direct|DIRECT"
        for _p in $(state_list_confs "$(state_socks_dir)"); do
            _items="$_items
socks:$(kv_get "$_p" name)|SOCKS Profile $(kv_get "$_p" name)"
        done
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            direct)
                _tui_need_root || continue
                _tui_sb_managed || continue
                _tui_do singbox_cli egress "$1" direct
                _tui_done
                ;;
            socks:*)
                _tui_need_root || continue
                _tui_sb_managed || continue
                printf '该实例流量将通过 %s 出口，不会自动测试，也不会自动回落 DIRECT\n' "${TUI_KEY#socks:}"
                _tui_do singbox_cli egress "$1" socks "${TUI_KEY#socks:}"
                _tui_done
                ;;
        esac
    done
}

_tui_socks_add() {
    local _srv _port _name _user _pw
    _tui_need_root || return 0
    _tui_sb_managed || return 0
    tui_ask "SOCKS5 服务器地址（IPv4 或 IPv6，留空取消）："
    [ -n "$TUI_IN" ] || return 0
    _srv=$TUI_IN
    tui_ask "端口："
    [ -n "$TUI_IN" ] || return 0
    _port=$TUI_IN
    tui_ask "Profile 名称（留空自动编号）："
    _name=$TUI_IN
    tui_ask "用户名（留空表示无认证）："
    _user=$TUI_IN
    set -- --server "$_srv" --port "$_port"
    [ -z "$_name" ] || set -- "$@" --name "$_name"
    if [ -z "$_user" ]; then
        _tui_do singbox_cli socks add "$@" --no-auth
    else
        tui_read_secret "密码（输入不回显）：" || { _tui_pause; return 0; }
        _pw=$TUI_SECRET
        TUI_SECRET=
        if [ -z "$_pw" ]; then
            printf '密码不能为空\n'
            _tui_pause
            return 0
        fi
        _tui_do_secret "$_pw" singbox_cli socks add "$@" --username "$_user" --password-stdin
        _pw=
    fi
    _tui_done
}

tui_socks_profile_menu() { # 名称
    local _f _items _pw _u
    _f=$(state_socks_dir)/$1.conf
    while [ -f "$_f" ]; do
        _tui_clear
        _tui_header "SOCKS Profile $1"
        _tui_do singbox_cli socks show "$1"
        printf '\n'
        if [ "$(kv_get "$_f" enabled)" = true ]; then _items="toggle|禁用"; else _items="toggle|启用"; fi
        _items="$_items
server|修改服务器地址
port|修改端口
credential|修改用户名与密码
noauth|改为无认证
delete|删除 Profile"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            toggle)
                _tui_need_root || continue
                if [ "$(kv_get "$_f" enabled)" = true ]; then
                    tui_confirm "禁用后，绑定该 Profile 的实例流量会被拒绝，不会回落 DIRECT" || { _tui_pause; continue; }
                    _tui_do singbox_cli socks disable "$1"
                else
                    _tui_do singbox_cli socks enable "$1"
                fi
                _tui_done
                ;;
            server|port)
                _tui_need_root || continue
                tui_ask "新的值（留空取消）："
                [ -n "$TUI_IN" ] || continue
                _tui_do singbox_cli socks set "$1" "$TUI_KEY" "$TUI_IN"
                _tui_done
                ;;
            credential)
                _tui_need_root || continue
                tui_ask "用户名（留空取消）："
                [ -n "$TUI_IN" ] || continue
                _u=$TUI_IN
                tui_read_secret "密码（输入不回显）：" || { _tui_pause; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                [ -n "$_pw" ] || { printf '密码不能为空\n'; _tui_pause; continue; }
                _tui_do_secret "$_pw" singbox_cli socks set "$1" credential "$_u" --password-stdin
                _pw=
                _tui_done
                ;;
            noauth)
                _tui_need_root || continue
                _tui_do singbox_cli socks set "$1" no-auth
                _tui_done
                ;;
            delete)
                _tui_need_root || continue
                tui_confirm "即将删除 SOCKS Profile $1，仍被实例引用时业务层会拒绝" || { _tui_pause; continue; }
                _tui_do singbox_cli socks delete "$1"
                _tui_done
                ;;
        esac
    done
}

tui_socks_menu() {
    local _f _items _n
    while :; do
        _tui_clear
        _tui_header "SOCKS 出口"
        _tui_do singbox_cli socks list
        printf '\n'
        tui_choose "manage|管理 Profile
add|添加 SOCKS Profile
enable-all|批量启用
disable-all|批量禁用" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            manage)
                _items=
                for _f in $(state_list_confs "$(state_socks_dir)"); do
                    _n=$(kv_get "$_f" name)
                    _items="${_items}${_n}|${_n}
"
                done
                if [ -z "$(printf '%s' "$_items" | tr -d '\n')" ]; then
                    printf '(没有 Profile)\n'
                    _tui_pause
                    continue
                fi
                tui_choose "$_items" "返回"
                [ "$TUI_KEY" = back ] || tui_socks_profile_menu "$TUI_KEY"
                ;;
            add) _tui_socks_add ;;
            enable-all)
                _tui_need_root || continue
                _tui_do singbox_cli socks enable-all
                _tui_done
                ;;
            disable-all)
                _tui_need_root || continue
                tui_confirm "批量禁用后，绑定这些 Profile 的实例流量会被拒绝，不会回落 DIRECT" || { _tui_pause; continue; }
                _tui_do singbox_cli socks disable-all
                _tui_done
                ;;
        esac
    done
}

# ---- 客户端连接地址与导出 ----

tui_endpoint_menu() { # ID
    local _h
    while :; do
        _tui_clear
        _tui_header "客户端连接地址（Public Endpoint） $1"
        _tui_do singbox_cli endpoint "$1" show
        printf '\n说明：只记录客户端应该连接的地址，不配置 NAT 与防火墙，修改不会重启服务\n\n'
        tui_choose "set|设置
clear|清除" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            set)
                _tui_need_root || continue
                tui_ask "主机（IPv4、IPv6 或主机名，留空取消）："
                [ -n "$TUI_IN" ] || continue
                _h=$TUI_IN
                tui_ask "端口："
                [ -n "$TUI_IN" ] || continue
                _tui_do singbox_cli endpoint "$1" set "$_h" "$TUI_IN"
                _tui_done
                ;;
            clear)
                _tui_need_root || continue
                _tui_do singbox_cli endpoint "$1" clear
                _tui_done
                ;;
        esac
    done
}

tui_export_menu() { # ID, 只用于 sing-box 实例, Snell 的客户端信息见 tui_snell_client_menu
    local _f _t _items
    _f=$(state_instances_dir)/$1.conf
    _t=$(kv_get "$_f" type)
    while :; do
        _tui_clear
        _tui_header "客户端配置 $1"
        _tui_do singbox_cli endpoint "$1" show
        if _sb_type_tls "$_t"; then
            printf '证书校验：跳过（自签名，免维护）\n'
        fi
        printf '\n'
        _items="show|查看连接信息
secret|查看凭据
json|导出 sing-box JSON
json-redacted|导出 sing-box JSON（隐藏凭据）"
        if _sb_type_tls "$_t"; then _items="$_items
json-pin|导出 sing-box JSON（可选：嵌入证书固定校验）"; fi
        case $_t in
            tuic) printf '说明：TUIC 没有稳定的通用分享 URL，请使用 sing-box JSON\n\n' ;;
            *) _items="$_items
url|导出分享 URL
qr|显示 QR（需要 qrencode）" ;;
        esac
        _items="$_items
endpoint|设置客户端连接地址"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            show) _tui_do singbox_cli export "$1" show; _tui_done ;;
            secret) _tui_show_secret "$1" ;;
            json-redacted) _tui_do singbox_cli export "$1" sing-box --redacted; _tui_done ;;
            json|json-pin|url|qr)
                tui_confirm "即将输出包含客户端凭据的内容。终端记录或截图可能包含 Secret。" || { _tui_pause; continue; }
                case $TUI_KEY in
                    json) _tui_do singbox_cli export "$1" sing-box ;;
                    json-pin) _tui_do singbox_cli export "$1" sing-box --embed-cert ;;
                    url) _tui_do singbox_cli export "$1" url ;;
                    qr)
                        if [ -z "$(_snell_tool qrencode 2>/dev/null)" ]; then
                            printf '当前未安装可选工具 qrencode。\nTUI 不会自动安装，如需使用请自行执行 apk add libqrencode-tools。\n分享链接仍可用：导出分享 URL\n'
                            TUI_RC=0
                        else
                            _tui_do singbox_cli export "$1" qr
                        fi
                        ;;
                esac
                [ "$TUI_KEY" != json ] || printf '\n提示：也可以在命令行用重定向保存：proxy-manager sing-box export %s sing-box > client.json\n' "$1"
                _tui_done
                ;;
            endpoint) tui_endpoint_menu "$1" ;;
        esac
    done
}

# ---- 主菜单 ----

tui_main_menu() {
    local _extra _note
    _note=
    while :; do
        _tui_clear
        _tui_header "Alpine Proxy Manager"
        printf '版本：%s\nBuild：%s\n\n' "$(apm_version)" "$(apm_build)"
        printf '%s\n\n' "$(_tui_mem_text)"
        printf 'Core 状态：\n'
        _tui_core_line snell
        _tui_core_line singbox
        _extra=0
        if ! env_is_root; then _tui_warn "当前不是 root，只能查看，写操作不可用"; _extra=$((_extra + 1)); fi
        _tui_rule
        if [ -n "$_note" ]; then printf '%s\n' "$_note"; _note=; _extra=$((_extra + 1)); fi
        # 清屏后提示符固定在第 20 行, 警告与提示各多一行
        _tui_tick_init $((20 + _extra))
        tui_choose "snell|Snell
singbox|sing-box
status|状态与诊断
log|日志
manager|Manager 管理" "退出"
        # 离开主菜单后立即停止刷新, 子菜单不受影响
        TUI_TICK_ON=0
        case $TUI_KEY in
            back) return 0 ;;
            invalid) _note='输入无效，请重新选择。'; continue ;;
            snell) tui_snell_menu ;;
            singbox) tui_singbox_menu ;;
            status) tui_status_menu ;;
            log) tui_log_menu ;;
            manager) tui_manager_menu ;;
        esac
        TUI_TICK_ON=0
        [ "$TUI_EXIT" != 1 ] || return 0
    done
}

# 不检查 TTY, 供测试与 tui_cli 使用
tui_run() {
    _tui_init
    TUI_EOF=0
    TUI_EXIT=0
    trap '_tui_on_int' INT TERM
    trap '_tui_restore' EXIT
    # 只在明确设置了非 UTF-8 的 locale 时提示, Alpine 默认不设置 locale, 终端本身通常能显示中文
    if [ "$TUI_UTF8" = 0 ] && [ -n "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" ] && [ "${TERM:-}" != dumb ] && [ "$TUI_ANSI" = 1 ]; then
        printf '提示：当前终端可能无法正确显示中文，功能仍可使用\n'
    fi
    tui_main_menu
    _tui_restore
    trap - INT TERM EXIT
    printf '已退出\n'
    return 0
}

# 生产入口: 必须是交互式终端
tui_cli() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        apm_err "TUI 需要交互式终端 (stdin 与 stdout 都是 TTY)，脚本请使用命令行: proxy-manager help"
        return 2
    fi
    tui_run
}
