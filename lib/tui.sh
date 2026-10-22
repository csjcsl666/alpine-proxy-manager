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
TUI_WAITKEY=enter
TUI_RC=0
TUI_EXIT=0
TUI_TICK_ON=0
TUI_KEEP=0
TUI_ONEKEY=0
TUI_NCH=99

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

# 清屏. 上一个操作刚显示过内容时 (TUI_KEEP=1) 不清屏, 只空一行, 内容留在屏幕上供阅读与复制, 下一个菜单接在它下面
_tui_clear() {
    if [ "${TUI_KEEP:-0}" = 1 ]; then TUI_KEEP=0; printf '\n'; return 0; fi
    if [ "$TUI_ANSI" = 1 ]; then printf '\033[H\033[2J'; else printf '\n'; fi
}

# 主菜单的内存行靠绝对定位刷新, 必须真正清屏
_tui_clear_hard() {
    TUI_KEEP=0
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


# ---- SOCKS5 链接 (socks5://[用户[:密码]@]主机[:端口]) 的共享解析 ----
# 只负责安全提取字段, 不回显输入, 不写任何文件; 最终配置仍由各 Core 自己的生成器处理

# 百分号解码, 只接受可打印 ASCII, 结果在 TUI_PD
_tui_pct_decode() { # 文本
    local _s _pre _h _v _o
    _s=$1
    TUI_PD=
    while :; do
        case $_s in
            *%*)
                _pre=${_s%%\%*}
                _s=${_s#*%}
                _h=${_s%"${_s#??}"}
                case $_h in [0-9A-Fa-f][0-9A-Fa-f]) ;; *) return 1 ;; esac
                _v=$((0x$_h))
                [ "$_v" -ge 32 ] && [ "$_v" -le 126 ] || return 1
                _o=$(printf '%03o' "$_v")
                _s=${_s#??}
                TUI_PD=$TUI_PD$_pre$(printf '%b' "\\0$_o")
                ;;
            *) TUI_PD=$TUI_PD$_s; return 0 ;;
        esac
    done
}

# 解析一行输入. 返回 0=完整或部分链接 (字段在 TUI_SK_*), 1=明确无效 (原因在 TUI_SK_ERR, 不含输入内容), 2=不是链接 (按普通主机处理)
# TUI_SK_PORT 为空表示链接没有给端口; TUI_SK_HASUSER/HASPASS 表示用户名/密码是否由链接给出
tui_socks_uri_parse() { # 输入
    local _r _auth _hp _ui _h _p _l
    TUI_SK_HOST=; TUI_SK_PORT=; TUI_SK_USER=; TUI_SK_PASS=; TUI_SK_HASUSER=0; TUI_SK_HASPASS=0; TUI_SK_ERR=
    _l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $_l in
        socks5://*) ;;
        *://*) TUI_SK_ERR='不支持的协议，只接受 socks5://'; return 1 ;;
        *@*|*/*|*' '*) TUI_SK_ERR='不是有效的地址，完整链接需要以 socks5:// 开头'; return 1 ;;
        *) return 2 ;;
    esac
    _r=${1#?????????}
    _r=${_r%/}
    case $_r in
        *[/?#' ']*) TUI_SK_ERR='链接格式有歧义，不接受路径、参数或空白'; return 1 ;;
        '') TUI_SK_ERR='链接缺少主机'; return 1 ;;
    esac
    case $_r in
        *@*) _ui=${_r%@*}; _hp=${_r##*@}; _auth=1 ;;
        *) _ui=; _hp=$_r; _auth=0 ;;
    esac
    if [ "$_auth" = 1 ]; then
        case $_ui in
            '') TUI_SK_ERR='认证信息为空'; return 1 ;;
            :*) TUI_SK_ERR='缺少用户名'; return 1 ;;
            *:) TUI_SK_ERR='密码为空'; return 1 ;;
            *:*)
                _tui_pct_decode "${_ui%%:*}" || { TUI_SK_ERR='用户名的百分号编码无效'; return 1; }
                TUI_SK_USER=$TUI_PD
                _tui_pct_decode "${_ui#*:}" || { TUI_SK_ERR='密码的百分号编码无效'; return 1; }
                TUI_SK_PASS=$TUI_PD
                TUI_SK_HASPASS=1
                ;;
            *)
                _tui_pct_decode "$_ui" || { TUI_SK_ERR='用户名的百分号编码无效'; return 1; }
                TUI_SK_USER=$TUI_PD
                ;;
        esac
        TUI_SK_HASUSER=1
    fi
    case $_hp in
        '['*)
            case $_hp in
                '['*']') _h=${_hp#\[}; _h=${_h%\]}; _p= ;;
                '['*']:'*) _h=${_hp#\[}; _h=${_h%%\]*}; _p=${_hp##*\]:}; [ -n "$_p" ] || { TUI_SK_ERR='端口为空'; return 1; } ;;
                *) TUI_SK_ERR='IPv6 地址格式无效'; return 1 ;;
            esac
            case $_h in
                '') TUI_SK_ERR='链接缺少主机'; return 1 ;;
                *[!0-9A-Fa-f:.]*|*']'*|*'['*) TUI_SK_ERR='IPv6 地址格式无效'; return 1 ;;
            esac
            _h="[$_h]"
            ;;
        *:*:*) TUI_SK_ERR='IPv6 地址需要用方括号包起来'; return 1 ;;
        *:*) _h=${_hp%%:*}; _p=${_hp#*:}; [ -n "$_p" ] || { TUI_SK_ERR='端口为空'; return 1; } ;;
        *) _h=$_hp; _p= ;;
    esac
    [ -n "$_h" ] || { TUI_SK_ERR='链接缺少主机'; return 1; }
    if [ -n "$_p" ] && ! is_port "$_p"; then TUI_SK_ERR='端口无效 (需要 1 到 65535)'; return 1; fi
    _sb_socks_host_normalize "$_h" "${_p:-1}" >/dev/null 2>&1 || { TUI_SK_ERR='主机地址无效'; return 1; }
    TUI_SK_HOST=$_h
    TUI_SK_PORT=$_p
    return 0
}

# 读取上游地址或完整链接, 正常可见输入, 用户可以在回车前检查与修改; 程序自己不回显链接 不写日志
# 返回 0=有输入 (字段在 TUI_SK_*, 普通地址时 TUI_SK_URI=0), 1=留空取消
_tui_socks_target() { # 提示
    local _line _rc
    while :; do
        tui_ask "$1"
        _line=$TUI_IN
        TUI_IN=
        [ -n "$_line" ] || return 1
        TUI_SK_PORT_FROM_URI=0
        TUI_SK_URI=1
        tui_socks_uri_parse "$_line"
        _rc=$?
        case $_rc in
            0)
                [ -z "$TUI_SK_PORT" ] || TUI_SK_PORT_FROM_URI=1
                printf '已识别：主机 %s' "$TUI_SK_HOST"
                [ -z "$TUI_SK_PORT" ] || printf '，端口 %s' "$TUI_SK_PORT"
                [ "$TUI_SK_HASUSER" = 0 ] || printf '，用户名已提供'
                [ "$TUI_SK_HASPASS" = 0 ] || printf '，密码已提供（不显示）'
                _line=
                printf '\n'
                return 0
                ;;
            2)
                TUI_SK_URI=0
                TUI_SK_HOST=$_line; TUI_SK_PORT=; TUI_SK_USER=; TUI_SK_PASS=; TUI_SK_HASUSER=0; TUI_SK_HASPASS=0
                ;;
            *)
                printf '错误：%s，请重新输入，留空取消\n' "$TUI_SK_ERR"
                continue
                ;;
        esac
        return 0
    done
}

# 链接没有给端口时, 沿用各 Core 原有的端口提问
_tui_socks_port() { # 提示
    [ -z "$TUI_SK_PORT" ] || return 0
    tui_ask "$1"
    TUI_SK_PORT=$TUI_IN
}

# 补全认证信息. ALLOW_NOAUTH=1 时允许无认证 (用户名留空); 链接带端口但没有认证信息即表示无认证
# 链接只给了用户名时只补问密码, 其余沿用各 Core 原有的提问; 结果在 TUI_SK_USER / TUI_SK_PASS
_tui_socks_auth() { # 用户名提示, 密码提示, ALLOW_NOAUTH
    if [ "$TUI_SK_URI" = 1 ] && [ "$TUI_SK_HASUSER" = 0 ] && [ "$3" = 1 ] && [ "$TUI_SK_PORT_FROM_URI" = 1 ]; then
        TUI_SK_USER=
        TUI_SK_PASS=
        return 0
    fi
    if [ "$TUI_SK_HASUSER" = 0 ]; then
        tui_ask "$1"
        TUI_SK_USER=$TUI_IN
    fi
    if [ "$TUI_SK_HASPASS" = 0 ] && { [ -n "$TUI_SK_USER" ] || [ "$3" != 1 ]; }; then
        tui_read_secret "$2" || return 1
        TUI_SK_PASS=$TUI_SECRET
        TUI_SECRET=
    fi
    return 0
}

_tui_socks_clear() { TUI_SK_PASS=; TUI_SK_USER=; TUI_SECRET=; }

tui_confirm() { # 说明文字, 回车默认 Yes
    local _a _rc
    printf '%s\n' "$1"
    while :; do
        printf '继续？[Y/n]：'
        _a=
        _rc=0
        IFS= read -r _a || _rc=$?
        # 读取失败且没有读到任何内容 (EOF 或终端断开) 不是空回车, 必须中止
        if [ "$_rc" -ne 0 ] && [ -z "$_a" ]; then
            TUI_EOF=1
            printf '\n已取消\n'
            return 1
        fi
        _a=$(printf '%s' "$_a" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_a in
            ''|y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) printf '已取消\n'; return 1 ;;
        esac
        printf '输入无效，请输入 y 或 n，直接按 Enter 表示 Yes\n'
    done
}

# ---- 结果与阅读 ----
# 三种不同的事, 不混用:
#   _tui_pause  只标记下一屏不清屏, 刚才的内容留在上面, 下一个菜单接在它下面; 不等待输入. 用于一两行就看完的操作反馈 (已启用 已取消)
#   _tui_wait   阅读暂停: 提示按回车返回并真正等待, 之后下一屏清屏重绘. 用于需要读完的内容 (报告 状态 日志 连接信息 错误)
#   清屏        _tui_clear 只负责画面, 不代替阅读暂停
# 零确认 (D141) 取消的是执行前的确认, 不取消结果的阅读: 菜单选择 单键 Esc 不变, 只在有东西要读时才停

# 阅读暂停是否生效: 交互终端才等待, 管道与脚本驱动 (测试 CI) 退回只标记不清屏, 不会吞掉后面的输入
# APM_TUI_PAUSE=1 强制开启 (测试用管道驱动时验证阅读暂停), 0 强制关闭
_tui_wait_on() {
    case ${APM_TUI_PAUSE:-auto} in
        1) return 0 ;;
        0) return 1 ;;
    esac
    [ -t 0 ] && [ -t 1 ]
}

# 丢弃停顿之前已经到达的输入 (粘贴的残余 误按的键), 否则阅读暂停会被旧输入立刻跳过
_tui_wait_flush() {
    local _st
    _st=$(_snell_run stty -g 2>/dev/null) || return 0
    [ -n "$_st" ] || return 0
    _snell_run stty -icanon -echo min 0 time 0 2>/dev/null
    dd bs=256 count=1 >/dev/null 2>&1
    _snell_run stty "$_st" 2>/dev/null
}

# 等待回车. 单键终端里只有 Enter Esc Ctrl-D 结束, 其他键与方向键忽略 (不回显, 不累积); 其余终端读一整行. EOF 不阻塞, 置 TUI_EOF 后返回
_tui_wait_enter() {
    local _st _k _rc
    TUI_WAITKEY=enter
    if [ "${TUI_ONEKEY:-0}" != 1 ]; then
        IFS= read -r _k || TUI_EOF=1
        case $_k in q|Q) TUI_WAITKEY=esc ;; esac
        [ "$TUI_EOF" != 1 ] || TUI_WAITKEY=esc
        return 0
    fi
    _st=$(_snell_run stty -g 2>/dev/null) || _st=
    if [ -z "$_st" ]; then
        IFS= read -r _k || TUI_EOF=1
        case $_k in q|Q) TUI_WAITKEY=esc ;; esac
        [ "$TUI_EOF" != 1 ] || TUI_WAITKEY=esc
        return 0
    fi
    TUI_STTY_SAVED=$_st
    _snell_run stty -icanon -echo min 1 time 0 2>/dev/null
    while :; do
        _k=
        # shellcheck disable=SC3045
        IFS= read -r -n 1 _k
        _rc=$?
        if [ "$_rc" -ne 0 ]; then TUI_EOF=1; TUI_WAITKEY=esc; break; fi
        [ -n "$_k" ] || break
        case $_k in
            "$(printf '\033')")
                _snell_run stty min 0 time 2 2>/dev/null
                _tui_getbyte
                _snell_run stty min 1 time 0 2>/dev/null
                if [ -n "$TUI_K" ]; then _tui_key_drain; continue; fi
                TUI_WAITKEY=esc
                break
                ;;
            "$(printf '\004')") TUI_WAITKEY=esc; break ;;
        esac
    done
    _snell_run stty "$_st" 2>/dev/null
    TUI_STTY_SAVED=
    return 0
}

_tui_wait() {
    if ! _tui_wait_on; then TUI_KEEP=1; return 0; fi
    _tui_wait_flush
    printf '\n按回车返回...'
    _tui_wait_enter
    printf '\n'
    TUI_KEEP=0
    return 0
}

# 刚才的操作没有完成时, 说明在上面的输出里, 这里补一句并让管理员读完
_tui_fail_note() {
    printf '\n操作没有完成，原因见上面的提示\n'
}

# 显示完内容之后不再等待: 只标记下一次不清屏, 内容留在屏幕上
_tui_pause() { TUI_KEEP=1; }

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

# 菜单输入模式: 真实终端里数字只进入输入行, Enter 提交 (D154), Backspace 可改, 单独的 Esc 立即返回, 方向键 粘贴 残留输入不会触发操作
# 需要交互终端 stty 与支持 read -n 的 shell, 缺一不可就保持整行输入 (终端自己的行编辑), 提交规则一样: 数字加 Enter
_tui_onekey_init() {
    TUI_ONEKEY=0
    [ "${APM_TUI_ONEKEY:-1}" = 1 ] || return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    _snell_run stty -g >/dev/null 2>&1 || return 0
    # shellcheck disable=SC3045
    ( IFS= read -r -n 1 _tui_probe ) </dev/null 2>/dev/null
    [ $? -eq 1 ] || return 0
    TUI_ONEKEY=1
}

# 丢弃已经到达但还没读的输入: 粘贴的多位数字 方向键的后续字节 都不能顺势变成下一个菜单的操作, 终端必须已处于 min 0 time 0 之外的原始模式
_tui_key_drain() {
    # 不用 read -n: bash 的 read 会自己把终端设成 min 1, 空缓冲会一直阻塞; dd 在 min 0 time 0 下立即返回
    _snell_run stty min 0 time 0 2>/dev/null
    dd bs=256 count=1 >/dev/null 2>&1
    _snell_run stty min 1 time 0 2>/dev/null
}

# 读一个菜单选择: 输入数字只更新输入行, 按 Enter 才提交 (D154 取代 D142 的单键立即执行)
#   Backspace 修改, 空 Enter 静默忽略 (没有输入不会执行任何默认项), Ctrl-D 在输入为空时视为 EOF
#   单独的 Esc 立即等同输入 0 返回, 方向键等 Esc 序列整体忽略; 提交后丢弃同批到达的字节 (粘贴 残留的 Enter 不会顺势变成下一个菜单的操作)
#   输入行最多 8 个可见字符, 其余忽略; 主菜单刷新开启时, 等待输入期间照常刷新内存行, 已键入的字符保留
#   终端模式在每次读取后立即恢复
_tui_read_key() {
    local _st _k _rc _t0 _buf
    _st=$(_snell_run stty -g 2>/dev/null) || return 2
    [ -n "$_st" ] || return 2
    TUI_STTY_SAVED=$_st
    _snell_run stty -icanon -echo min 1 time 0 2>/dev/null
    _buf=
    _rc=0
    while :; do
        _k=
        if [ "${TUI_TICK_ON:-0}" = 1 ]; then
            _tui_now
            _t0=$TUI_NOW
            # shellcheck disable=SC3045
            IFS= read -r -n 1 -t "$TUI_TICK_SEC" _k
            _rc=$?
            if [ "$_rc" -ne 0 ]; then
                _tui_now
                if [ $((TUI_NOW - _t0)) -ge $((TUI_TICK_SEC * 100 - 5)) ]; then _tui_tick_mem; continue; fi
            fi
        else
            # shellcheck disable=SC3045
            IFS= read -r -n 1 _k
            _rc=$?
        fi
        [ "$_rc" -eq 0 ] || break
        case $_k in
            '')
                # Enter: 有输入才提交
                [ -n "$_buf" ] || continue
                break
                ;;
            "$(printf '\033')")
                _snell_run stty min 0 time 2 2>/dev/null
                _tui_getbyte
                _snell_run stty min 1 time 0 2>/dev/null
                if [ -n "$TUI_K" ]; then _tui_key_drain; continue; fi
                _buf=0
                break
                ;;
            "$(printf '\004')")
                if [ -z "$_buf" ]; then _rc=1; break; fi
                ;;
            "$(printf '\177')"|"$(printf '\010')")
                if [ -n "$_buf" ]; then
                    _buf=${_buf%?}
                    printf '\b \b'
                fi
                ;;
            *)
                # 可见 ASCII 才进入输入行 (无效输入在提交后统一提示)
                case $_k in
                    [!\ -~]) ;;
                    *)
                        if [ "${#_buf}" -lt 8 ]; then
                            _buf=$_buf$_k
                            printf '%s' "$_k"
                        fi
                        ;;
                esac
                ;;
        esac
    done
    [ "$_rc" -ne 0 ] || _tui_key_drain
    _snell_run stty "$_st" 2>/dev/null
    TUI_STTY_SAVED=
    [ "$_rc" -eq 0 ] || return 1
    printf '\n'
    _c=$_buf
    return 0
}

# 读取一行选择: 刷新开启时每个间隔超时一次并更新内存行, 其余与 read -r 完全一致
# BusyBox 的超时与 EOF 返回码相同, 所以用耗时区分: 等满间隔才算超时, EOF (含 Ctrl-D 与连接断开) 会提前返回
_tui_read_choice() {
    local _t0 _r
    if [ "${TUI_ONEKEY:-0}" = 1 ]; then
        _tui_read_key
        _r=$?
        [ "$_r" -ne 2 ] && return "$_r"
    fi
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
        TUI_NCH=$_n
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

# 操作之后的收尾. 失败一定要读到, 所以等待; 成功只有一两行反馈的操作留在屏幕上 (下一屏不清屏), 不打断连续操作
_tui_done() {
    if [ "$TUI_RC" -ne 0 ]; then
        _tui_fail_note
        _tui_wait
    else
        _tui_pause
    fi
}

# 报告页的收尾: 内容就是用户要看的东西 (状态 日志 连接信息 安装与更新结果), 无论成功失败都读完再返回
_tui_page() {
    if [ "$TUI_RC" -ne 0 ]; then _tui_fail_note; fi
    _tui_wait
}

_tui_need_root() {
    if env_is_root; then return 0; fi
    printf '此操作需要 root, TUI 不会自动 sudo\n'
    _tui_wait
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

# 直接显示最后 30 行 (需要更多用命令行 log N)
_tui_log() { # key
    local _n
    _n=30
    case $1 in snell) _tui_do snell_cli log "$_n" ;; anytlsgw) _tui_do agw_cli log "$_n" ;; *) _tui_do singbox_cli log "$_n" ;; esac
    _tui_page
}

tui_log_menu() {
    while :; do
        _tui_clear
        _tui_header "日志"
        printf '提示：日志可能包含访问目标，注意不要公开\n\n'
        tui_choose "snell|Snell 日志
singbox|sing-box 日志
anytlsgw|AnyTLS Gateway 日志" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            snell) _tui_log snell ;;
            singbox) _tui_log singbox ;;
            anytlsgw) _tui_log anytlsgw ;;
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

# 系统状态 Core 状态 资源使用 一次显示
_tui_overview() {
    report_status
    printf '\n'
    _tui_resources
}

tui_status_menu() {
    while :; do
        _tui_clear
        _tui_header "状态与诊断"
        tui_choose "overview|状态总览（服务、功能、资源）
doctor|doctor 环境检查" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            overview) _tui_do _tui_overview; _tui_page ;;
            doctor) _tui_do report_doctor; _tui_page ;;
        esac
    done
}

# ---- Snell · 网络与进程保护（低内存环境） ----
# 信息架构: 首页看状态 (哪些机制实际生效) / 详情看原理 (分组的技术信息) / 取证看事件 (摘要加原始记录) / 操作看结果 (成功 失败 跳过 未改变)
# 展示只读 lowmem.sh 的检测与计划函数并实时读系统, 不信任保存的 "全部成功"; 命令行 apm lowmem 的输出不变
# 状态码 ok 已生效  bad 配置了但未生效  part 部分生效  avail 可启用  fine 无需调整  na 环境不允许  off 可选项未启用

# 把一段说明按 ； 拆成缩进的多行, 不依赖终端自动换行
_tui_lm_wrap() { # 缩进 文字
    printf '%s\n' "$2" | sed "s/；/\\
/g" | sed "s/^/$1/"
}

_tui_lm_row() { # 标记状态 标签 文字
    local _mk
    case $1 in bad|part) _mk='! ' ;; *) _mk='  ' ;; esac
    case $3 in 未生效*|未应用*) _mk='! ' ;; esac
    printf '%s%s：%s\n' "$_mk" "$2" "$3"
}

# 收集全部展示用的状态 (只读). 结果放在 LMT_* 里
_tui_lm_collect() {
    local _c_tcp _c_ssh _c_for _c_sac _k _t _c _n _okn _pid _adj _cm _bad
    lm_probe
    lm_plan_tcp
    lm_plan_ssh
    lm_plan_forensics
    lm_plan_sac
    LMT_EN=no
    lm_enabled && LMT_EN=yes
    _c_tcp=$(_lm_cget tcp); _c_ssh=$(_lm_cget ssh); _c_for=$(_lm_cget forensics); _c_sac=$(_lm_cget snell_sac)
    LMT_DAEMON=no
    _lm_daemon_running && LMT_DAEMON=yes
    LMT_CONF=0; LMT_OK=0; LMT_BAD=0; LMT_NA=0
    # ---- TCP ----
    if [ "$LMT_EN" = yes ] && [ "$_c_tcp" = on ]; then
        LMT_CONF=$((LMT_CONF + 1))
        _bad=
        for _k in rmem wmem; do
            _t=$(_lm_cget "tcp_$_k")
            [ -n "$_t" ] || continue
            _c=$(_lm_tcp_read "$_k")
            [ "$_c" = "$_t" ] || _bad="$_bad $_k"
        done
        if [ -z "$_bad" ]; then LMT_TCP_S=ok; LMT_TCP_T="已生效"; LMT_OK=$((LMT_OK + 1))
        else LMT_TCP_S=bad; LMT_TCP_T="未生效（当前值与设置不一致，可能被外部修改）"; LMT_BAD=$((LMT_BAD + 1)); fi
    else
        case $LM_P_TCP in
            plan) LMT_TCP_S=avail; LMT_TCP_T="可调整（缓冲上限偏大，启用后降到内核默认值）" ;;
            fine) LMT_TCP_S=fine; LMT_TCP_T="无需调整（缓冲上限合理）" ;;
            unconfirmed) LMT_TCP_S=na; LMT_TCP_T="未启用（作用范围未确认，不自动修改）" ;;
            unknown) LMT_TCP_S=na; LMT_TCP_T="无法判断（内存上限或参数格式未知）" ;;
            *)
                LMT_TCP_S=na
                case $LM_P_TCP_NOTE in
                    *只读*) LMT_TCP_T="不可用（当前环境不允许修改）" ;;
                    *没有提供*) LMT_TCP_T="不可用（内核没有提供该参数）" ;;
                    *管理员已在*) LMT_TCP_T="不可用（已由管理员在 sysctl 配置中设置）" ;;
                    *) LMT_TCP_T="不可用" ;;
                esac
                ;;
        esac
        { [ "$LMT_EN" != yes ] || [ "$LMT_TCP_S" != na ]; } || LMT_NA=$((LMT_NA + 1))
    fi
    # ---- SSH ----
    LMT_SSH_N=0
    LMT_SSH_OKN=0
    while read -r _pid _adj _cm; do
        [ -n "$_pid" ] || continue
        LMT_SSH_N=$((LMT_SSH_N + 1))
        [ "$_adj" -le "$LM_SSH_ADJ" ] 2>/dev/null && LMT_SSH_OKN=$((LMT_SSH_OKN + 1))
    done <<EOF
$(_lm_ssh_procs)
EOF
    if [ "$LMT_EN" = yes ] && [ "$_c_ssh" = on ]; then
        LMT_CONF=$((LMT_CONF + 1))
        if [ "$LMT_SSH_N" -eq 0 ]; then
            if [ "$LMT_DAEMON" = yes ]; then LMT_SSH_S=ok; LMT_SSH_T="已启用（当前没有 sshd 进程，出现后自动设置）"; LMT_OK=$((LMT_OK + 1))
            else LMT_SSH_S=bad; LMT_SSH_T="未生效（常驻进程没有运行）"; LMT_BAD=$((LMT_BAD + 1)); fi
        elif [ "$LMT_SSH_OKN" -eq "$LMT_SSH_N" ]; then
            LMT_SSH_S=ok; LMT_SSH_T="已生效（$LMT_SSH_N 个 sshd 进程，oom_score_adj 不高于 $LM_SSH_ADJ）"; LMT_OK=$((LMT_OK + 1))
        else
            LMT_SSH_S=part; LMT_SSH_T="部分生效（$LMT_SSH_OKN/$LMT_SSH_N 个进程，其余由常驻进程在数秒内设置）"; LMT_BAD=$((LMT_BAD + 1))
        fi
    else
        case $LM_P_SSH in
            plan) LMT_SSH_S=avail; LMT_SSH_T="可启用（把 sshd 的 oom_score_adj 降到 $LM_SSH_ADJ）" ;;
            fine) LMT_SSH_S=fine; LMT_SSH_T="可启用（sshd 的 oom_score_adj 已不高于 $LM_SSH_ADJ）" ;;
            *)
                LMT_SSH_S=na
                case $LM_P_SSH_NOTE in
                    *memory.oom.group*) LMT_SSH_R="cgroup 整组终止（memory.oom.group 为 1），调整无效" ;;
                    *不允许降低*) LMT_SSH_R="权限不足，无法降低 oom_score_adj" ;;
                    *) LMT_SSH_R="环境不允许" ;;
                esac
                if [ "$LMT_EN" = yes ]; then LMT_SSH_T="未生效（$LMT_SSH_R）"; LMT_NA=$((LMT_NA + 1)); else LMT_SSH_T="不可用（$LMT_SSH_R）"; fi
                ;;
        esac
    fi
    # ---- 内存取证 ----
    if [ "$LMT_EN" = yes ] && [ "$_c_for" = on ]; then
        LMT_CONF=$((LMT_CONF + 1))
        if [ "$LMT_DAEMON" = yes ]; then LMT_FOR_S=ok; LMT_FOR_T="运行中"; LMT_OK=$((LMT_OK + 1))
        else LMT_FOR_S=bad; LMT_FOR_T="未运行（常驻进程没有运行）"; LMT_BAD=$((LMT_BAD + 1)); fi
    else
        case $LM_P_FOR in
            plan) LMT_FOR_S=avail; LMT_FOR_T="可启用（记录 OOM 发生时的内存组成和进程表）" ;;
            *)
                LMT_FOR_S=na
                if [ "$LMT_EN" = yes ]; then LMT_FOR_T="未生效（需要 cgroup v2 的 memory.events）"; LMT_NA=$((LMT_NA + 1)); else LMT_FOR_T="不可用（需要 cgroup v2 的 memory.events）"; fi
                ;;
        esac
    fi
    # ---- Snell 优先终止 (可选) ----
    LMT_SAC_N=0
    LMT_SAC_OKN=0
    while read -r _pid _adj _cm; do
        [ -n "$_pid" ] || continue
        LMT_SAC_N=$((LMT_SAC_N + 1))
        [ "$_adj" -ge "$LM_SNELL_ADJ" ] 2>/dev/null && LMT_SAC_OKN=$((LMT_SAC_OKN + 1))
    done <<EOF
$(_lm_snell_procs)
EOF
    if [ "$LMT_EN" = yes ] && [ "$_c_sac" = on ]; then
        LMT_CONF=$((LMT_CONF + 1))
        if [ "$LMT_SAC_N" -eq 0 ]; then
            if [ "$LMT_DAEMON" = yes ]; then LMT_SAC_S=ok; LMT_SAC_T="已启用（Snell 当前没有运行，启动后自动设置）"; LMT_OK=$((LMT_OK + 1))
            else LMT_SAC_S=bad; LMT_SAC_T="未生效（常驻进程没有运行）"; LMT_BAD=$((LMT_BAD + 1)); fi
        elif [ "$LMT_SAC_OKN" -eq "$LMT_SAC_N" ]; then
            LMT_SAC_S=ok; LMT_SAC_T="已启用（$LMT_SAC_N 个 Snell 进程，oom_score_adj 不低于 $LM_SNELL_ADJ）"; LMT_OK=$((LMT_OK + 1))
        else
            LMT_SAC_S=part; LMT_SAC_T="部分生效（$LMT_SAC_OKN/$LMT_SAC_N 个进程，其余由常驻进程在数秒内设置）"; LMT_BAD=$((LMT_BAD + 1))
        fi
    else
        case $LM_P_SAC in
            na)
                LMT_SAC_S=na
                case $LM_P_SAC_NOTE in
                    *没有检测到*) LMT_SAC_T="不可用（没有检测到 Snell 服务）" ;;
                    *memory.oom.group*) LMT_SAC_T="不可用（cgroup 整组终止，调整无效）" ;;
                    *) LMT_SAC_T="不可用" ;;
                esac
                ;;
            *) LMT_SAC_S=off; LMT_SAC_T="未启用" ;;
        esac
    fi
    # ---- 开机持久化 ----
    LMT_PER_S=off
    LMT_PER_T=
    if [ "$LMT_EN" = yes ]; then
        if _lm_init_ours && [ -e "$(env_path "/etc/runlevels/default/$LM_SVC")" ]; then LMT_PER_S=ok; LMT_PER_T="已启用（OpenRC 服务 $LM_SVC，default 运行级别）"
        else LMT_PER_S=bad; LMT_PER_T="未生效（OpenRC 服务缺失或没有加入开机启动）"; fi
    fi
    return 0
}

# 一句话总结, 统计口径写明: 配置项 = 设置文件里启用的机制; 生效项 = 实时检测确认生效
_tui_lm_headline() {
    if [ "$LMT_EN" != yes ]; then printf '未启用'; return 0; fi
    if [ "$LMT_CONF" -eq 0 ]; then printf '已启用，但没有任何机制可用（见下）'; return 0; fi
    printf '已启用（配置 %s 项，实际生效 %s 项' "$LMT_CONF" "$LMT_OK"
    [ "$LMT_BAD" -eq 0 ] || printf '，%s 项未完全生效' "$LMT_BAD"
    [ "$LMT_NA" -eq 0 ] || printf '；另有 %s 项因环境限制没有生效' "$LMT_NA"
    printf '）'
}

# 首页: 只显示状态. 不展开路径 原始参数 权限解释
_tui_lm_home() {
    _tui_lm_collect
    printf '调整 TCP 缓冲与进程的 OOM 优先级，并记录内存取证；不清理或回收内存\n\n'
    printf '保护状态：%s\n' "$(_tui_lm_headline)"
    if [ "$LMT_EN" = yes ]; then printf '  配置项 = 设置里启用的机制；生效项 = 实时检测确认；环境限制项另计\n'; fi
    printf '\n'
    _tui_lm_row "$LMT_TCP_S" "TCP 缓冲优化" "$LMT_TCP_T"
    _tui_lm_row "$LMT_SSH_S" "SSH 进程保护" "$LMT_SSH_T"
    _tui_lm_row "$LMT_FOR_S" "内存取证" "$LMT_FOR_T"
    _tui_lm_row "$LMT_SAC_S" "Snell 优先终止" "$LMT_SAC_T"
    [ "$LMT_EN" != yes ] || _tui_lm_row "$LMT_PER_S" "开机持久化" "$LMT_PER_T"
    if [ "$LMT_SAC_S" = ok ] || [ "$LMT_SAC_S" = part ]; then
        printf '\n! Snell 优先终止不提高 Snell 的稳定性：内存不足时 Snell 会最先被终止\n'
    fi
    if [ "$LMT_EN" = yes ] && [ $((LMT_BAD + LMT_NA)) -gt 0 ]; then
        printf '\n! 有 %s 项没有生效（含环境限制），原因见「查看保护详情」\n' "$((LMT_BAD + LMT_NA))"
    fi
}

# ---- 保护详情 ----

_tui_lm_proc_list() { # 过程名 (_lm_ssh_procs|_lm_snell_procs) 最多 5 个
    local _pid _adj _cm _n
    _n=0
    while read -r _pid _adj _cm; do
        [ -n "$_pid" ] || continue
        _n=$((_n + 1))
        [ "$_n" -gt 5 ] || printf '      PID %s（%s）：oom_score_adj %s\n' "$_pid" "$_cm" "$_adj"
    done <<EOF
$($1)
EOF
    [ "$_n" -le 5 ] || printf '      …… 共 %s 个进程\n' "$_n"
    [ "$_n" -gt 0 ] || printf '      当前没有该进程\n'
}

# 依据按 ， 拆成多行, 续行缩进
_tui_lm_why() {
    printf '%s\n' "$1" | sed 's/，/\
/g' | awk 'NR == 1 { print "    依据：" $0; next } { print "      " $0 }'
}

_tui_lm_tcp_block() { # rmem|wmem
    local _cur _o _t _w _kd _lbl _cap
    if [ "$1" = rmem ]; then _cur=$LM_RMEM; _kd=$LM_KD_RMEM; _lbl="tcp_rmem（接收缓冲）"; else _cur=$LM_WMEM; _kd=$LM_KD_WMEM; _lbl="tcp_wmem（发送缓冲）"; fi
    _o=$(kv_get "$(_lm_orig)" "tcp_$1_orig" 2>/dev/null)
    _t=$(kv_get "$(_lm_orig)" "tcp_$1_target" 2>/dev/null)
    _w=$(kv_get "$(_lm_orig)" "tcp_$1_why" 2>/dev/null)
    printf '  %s\n' "$_lbl"
    if [ -n "$_cur" ]; then
        # shellcheck disable=SC2086
        set -- $_cur
        printf '    当前：%s（单个连接上限 %s）\n' "$_cur" "$(_lm_mib "$3")"
    else
        printf '    当前：不可用\n'
    fi
    if [ -n "$_o" ]; then
        # shellcheck disable=SC2086
        set -- $_o
        _cap=$(_lm_mib "$3")
        printf '    原始：%s（上限 %s）\n' "$_o" "$_cap"
        # shellcheck disable=SC2086
        set -- $_t
        printf '    目标：%s（上限 %s）\n' "$_t" "$(_lm_mib "$3")"
        _tui_lm_why "$_w"
    else
        printf '    内核默认（参照）：%s\n' "$_kd"
        printf '    原始 / 目标：没有保存（没有调整过）\n'
    fi
}

_tui_lm_detail() {
    local _k _on _ad
    _tui_lm_collect
    printf '保护状态：%s\n' "$(_tui_lm_headline)"
    printf '\nA. 运行环境\n'
    printf '  内存上限：%s（%s）\n' "$(_lm_mib "$LM_LIMIT")" "$(_lm_limit_src_text)"
    printf '  cgroup：%s%s\n' "${LM_CG_VER:-未知}" "$([ -z "$LM_CG_DIR" ] || printf '，%s' "${LM_CG_DIR#"${APM_SYSROOT:-}"}")"
    case $LM_NS_SCOPE in
        own) printf '  网络命名空间：与宿主机不共享\n  判断依据：本进程在子用户命名空间里，并且能写网络参数\n' ;;
        *) printf '  网络命名空间：是否与宿主机共享未确认\n  判断依据：没有直接证据，不用容器标记推断\n' ;;
    esac
    [ "$(_lm_cget netns_assumed)" != yes ] || printf '  管理员已用 --assume-own-netns 声明独占，APM 没有独立证据\n'
    printf '  辅助信息（不参与判断）：\n'
    _tui_lm_wrap '    ' "$(printf '%s' "$LM_NS_AUX" | sed 's/，/；/g')"
    printf '  TCP 参数影响范围：当前网络命名空间内的所有服务\n'
    printf '    （含 sing-box 与 AnyTLS Gateway，不只是 Snell）\n'
    printf '\nB. TCP 缓冲区\n'
    printf '  状态：%s\n' "$LMT_TCP_T"
    printf '  单位：字节，三个数依次是 最小 / 初值 / 上限\n'
    _tui_lm_tcp_block rmem
    _tui_lm_tcp_block wmem
    printf '  判断：单个连接上限之和超过内存上限的 1/4 时才调整\n'
    printf '  调整方向：只降不升，降到内核默认值与当前值中较小者\n'
    printf '\nC. 进程保护\n'
    printf '  SSH 进程保护：%s\n' "$LMT_SSH_T"
    printf '    目标：sshd 的 oom_score_adj 降到 %s\n' "$LM_SSH_ADJ"
    _tui_lm_proc_list _lm_ssh_procs
    printf '  Snell 优先终止（可选）：%s\n' "$LMT_SAC_T"
    printf '    目标：Snell 进程的 oom_score_adj 提高到 %s\n' "$LM_SNELL_ADJ"
    _tui_lm_proc_list _lm_snell_procs
    printf '\nD. 取证与持久化\n'
    printf '  内存取证：%s\n' "$LMT_FOR_T"
    printf '  记录文件：%s（%s 字节）\n' "$LM_LOG" "$(_lm_log_size)"
    printf '  记录方式：每 5 分钟一条心跳；OOM 计数变化时详细记录\n'
    printf '  常驻进程：%s\n' "$([ "$LMT_DAEMON" = yes ] && printf '运行中' || printf '没有运行')"
    if [ "$LMT_EN" = yes ]; then printf '  开机持久化：%s\n' "$LMT_PER_T"; else printf '  开机持久化：未启用（保护启用后创建 OpenRC 服务 %s）\n' "$LM_SVC"; fi
    printf '  设置文件：%s\n' "$(_lm_conf)"
    printf '  原始设置：%s\n' "$(_lm_orig)"
    printf '\nE. 限制与风险\n'
    printf '  - TCP 参数影响整个网络命名空间，不只是 Snell\n'
    printf '  - 修改 OOM 优先级不能保证进程不被终止\n'
    printf '  - Snell 优先终止会提高 Snell 被终止的可能，不提高其稳定性\n'
    printf '  - memory.events 的 OOM 计数是累计值，当前 %s 次\n' "${LM_OOM_KILL:-不可用}"
    printf '    （所在 cgroup 创建以来，不是最近一次）\n'
    printf '  - 内存占用偏高不等于发生过 OOM；周期采样抓不到毫秒级峰值\n'
    printf '  - 资源本身不足时，这些保护无法替代更多内存\n'
    return 0
}

# ---- 取证记录 ----

# 从取证日志提取摘要 (只读). 结果放在 LMF_*; 日志格式解析失败的行被忽略, 原始记录始终可查看
_tui_lm_log_scan() {
    local _f _r
    _f=$(env_path "$LM_LOG")
    LMF_LINES=0; LMF_LAST=; LMF_CUR=; LMF_BEATS=0; LMF_TFIRST=; LMF_TLAST=; LMF_MIN=; LMF_MAX=
    LMF_C0=; LMF_C1=; LMF_K0=; LMF_K1=; LMF_OOM=0; LMF_LASTOOM=; LMF_START=0; LMF_FIRSTTS=
    [ -s "$_f" ] || return 0
    _r=$(awk '
        function num(s, key,   m) { if (match(s, key "=[0-9]+")) return substr(s, RSTART + length(key) + 1, RLENGTH - length(key) - 1) + 0; return "" }
        { n++ }
        $1=="START"||$1=="BEAT"||$1=="BURST"||$1=="OOM" {
            if (first == "") first = $2 " " $3
            last = $2 " " $3
            c = num($0, "cur"); if (c != "") cur = c
        }
        $1=="START" { st++ }
        $1=="OOM" { oom++; lastoom = $2 " " $3 }
        $1=="BEAT" {
            c = num($0, "cur"); k = num($0, "oom_kill")
            if (c != "") { b++; cv[b] = c; ct[b] = $2 " " $3; if (k != "") kv[b] = k }
        }
        END {
            lo = b - 11; if (lo < 1) lo = 1
            mn = ""; mx = ""
            for (i = lo; i <= b; i++) { if (mn == "" || cv[i] < mn) mn = cv[i]; if (mx == "" || cv[i] > mx) mx = cv[i] }
            print "lines=" n; print "last=" last; print "first=" first; print "cur=" cur
            print "beats=" (b - lo + 1 > 0 ? b - lo + 1 : 0)
            print "tfirst=" ct[lo]; print "tlast=" ct[b]
            print "c0=" cv[lo]; print "c1=" cv[b]; print "min=" mn; print "max=" mx
            print "k0=" kv[lo]; print "k1=" kv[b]
            print "oom=" oom; print "lastoom=" lastoom; print "start=" st
        }' "$_f" 2>/dev/null) || return 0
    LMF_LINES=$(printf '%s\n' "$_r" | sed -n 's/^lines=//p')
    LMF_LAST=$(printf '%s\n' "$_r" | sed -n 's/^last=//p')
    LMF_FIRSTTS=$(printf '%s\n' "$_r" | sed -n 's/^first=//p')
    LMF_CUR=$(printf '%s\n' "$_r" | sed -n 's/^cur=//p')
    LMF_BEATS=$(printf '%s\n' "$_r" | sed -n 's/^beats=//p')
    LMF_TFIRST=$(printf '%s\n' "$_r" | sed -n 's/^tfirst=//p')
    LMF_TLAST=$(printf '%s\n' "$_r" | sed -n 's/^tlast=//p')
    LMF_C0=$(printf '%s\n' "$_r" | sed -n 's/^c0=//p')
    LMF_C1=$(printf '%s\n' "$_r" | sed -n 's/^c1=//p')
    LMF_MIN=$(printf '%s\n' "$_r" | sed -n 's/^min=//p')
    LMF_MAX=$(printf '%s\n' "$_r" | sed -n 's/^max=//p')
    LMF_K0=$(printf '%s\n' "$_r" | sed -n 's/^k0=//p')
    LMF_K1=$(printf '%s\n' "$_r" | sed -n 's/^k1=//p')
    LMF_OOM=$(printf '%s\n' "$_r" | sed -n 's/^oom=//p')
    LMF_LASTOOM=$(printf '%s\n' "$_r" | sed -n 's/^lastoom=//p')
    LMF_START=$(printf '%s\n' "$_r" | sed -n 's/^start=//p')
    return 0
}

_tui_lm_mib_of() { # 字节
    case $1 in ''|*[!0-9]*) printf '未知' ;; *) printf '%s MiB' "$(($1 / 1048576))" ;; esac
}

_tui_lm_forensics_summary() {
    local _d _thr _pct
    _tui_lm_collect
    _tui_lm_log_scan
    printf '监控：%s\n' "$LMT_FOR_T"
    if [ "$LMF_LINES" -eq 0 ] 2>/dev/null && [ ! -s "$(env_path "$LM_LOG")" ]; then
        printf '记录：还没有取证记录（%s）\n' "$LM_LOG"
        printf '  启用保护后，取证进程每 5 分钟记录一次心跳采样\n'
    elif [ -z "$LMF_LAST" ]; then
        printf '记录：日志有内容（%s 字节），但没有可识别的采样行\n' "$(_lm_log_size)"
        printf '  请查看原始记录，摘要不做猜测\n'
    else
        printf '最近采样：%s\n' "$LMF_LAST"
        if [ -n "$LMF_CUR" ] && [ "${LM_LIMIT:-0}" -gt 0 ] 2>/dev/null; then
            _pct=$((LMF_CUR * 100 / LM_LIMIT))
            printf '内存使用：%s / %s（%s%%，最近一次采样）\n' "$(_tui_lm_mib_of "$LMF_CUR")" "$(_lm_mib "$LM_LIMIT")" "$_pct"
        elif [ -n "$LMF_CUR" ]; then
            printf '内存使用：%s（最近一次采样）\n' "$(_tui_lm_mib_of "$LMF_CUR")"
        fi
        if [ "${LMF_BEATS:-0}" -lt 2 ] 2>/dev/null; then
            printf '近期趋势：采样不足（心跳 %s 条），无法判断\n' "${LMF_BEATS:-0}"
        else
            _d=$((LMF_C1 - LMF_C0))
            _thr=2097152
            [ "${LM_LIMIT:-0}" -le 0 ] 2>/dev/null || { [ $((LM_LIMIT / 50)) -le "$_thr" ] || _thr=$((LM_LIMIT / 50)); }
            if [ "$_d" -gt "$_thr" ]; then _d="上升 $(_tui_lm_mib_of "$_d")"
            elif [ "$_d" -lt "-$_thr" ]; then _d="下降 $(_tui_lm_mib_of "$((0 - _d))")"
            else _d="基本平稳"; fi
            printf '近期趋势：%s\n' "$_d"
            printf '  统计区间：%s 到 %s\n' "$LMF_TFIRST" "$LMF_TLAST"
            printf '  共 %s 条心跳，最低 %s，最高 %s\n' "$LMF_BEATS" "$(_tui_lm_mib_of "$LMF_MIN")" "$(_tui_lm_mib_of "$LMF_MAX")"
        fi
    fi
    if [ -n "$LM_OOM_KILL" ]; then
        printf 'OOM Kill 累计：%s 次（所在 cgroup 创建以来，不是最近一次）\n' "$LM_OOM_KILL"
    else
        printf 'OOM Kill 累计：不可用（没有可读的 cgroup v2 memory.events）\n'
    fi
    if [ -n "$LMF_K0" ] && [ -n "$LMF_K1" ] && [ "${LMF_BEATS:-0}" -ge 2 ] 2>/dev/null; then
        if [ "$LMF_K1" -ge "$LMF_K0" ] 2>/dev/null; then
            printf '  观察窗口内变化：%s -> %s（新增 %s 次）\n' "$LMF_K0" "$LMF_K1" "$((LMF_K1 - LMF_K0))"
        else
            printf '  观察窗口内变化：%s -> %s（计数变小，可能是 cgroup 重建）\n' "$LMF_K0" "$LMF_K1"
        fi
    else
        printf '  观察窗口内变化：采样不足，无法判断\n'
    fi
    if [ "${LMF_OOM:-0}" -gt 0 ] 2>/dev/null; then
        printf '异常事件：%s 次 OOM 事件记录，最近一次 %s\n' "$LMF_OOM" "$LMF_LASTOOM"
        printf '  累计值不变时的重复数字不是新事件；事件以 OOM 记录为准\n'
    else
        printf '异常事件：无（日志中没有 OOM 事件记录）\n'
    fi
    [ "${LMF_START:-0}" -le 0 ] 2>/dev/null || printf '取证进程启动：%s 次（日志范围 %s 起）\n' "$LMF_START" "$LMF_FIRSTTS"
    printf '完整日志：%s（%s 字节）\n' "$LM_LOG" "$(_lm_log_size)"
}

# 分页显示一个文件: 每页按终端高度估算 (折行的长记录占多行), 回车下一页, Esc 或 q 结束
_tui_lm_pager() { # 文件
    local _rows _cols _tot _p
    _rows=${LINES:-24}
    _cols=${COLUMNS:-80}
    [ "$_rows" -ge 10 ] 2>/dev/null || _rows=24
    [ "$_cols" -ge 40 ] 2>/dev/null || _cols=80
    awk -v rows=$((_rows - 4)) -v cols="$_cols" '
        BEGIN { page = 0; used = 0 }
        { r = int((length($0) + cols - 1) / cols); if (r < 1) r = 1
          if (used + r > rows && used > 0) { page++; used = 0 }
          used += r; print page "\t" $0 }' "$1" > "$1.paged"
    _tot=$(tail -n 1 "$1.paged" | cut -f1)
    _tot=$((_tot + 1))
    _p=0
    while [ "$_p" -lt "$_tot" ]; do
        awk -F'\t' -v p="$_p" '$1 == p { sub(/^[0-9]+\t/, ""); print }' "$1.paged"
        _p=$((_p + 1))
        [ "$_p" -lt "$_tot" ] || break
        printf -- '-- 第 %s/%s 页，回车下一页，Esc 结束 --' "$_p" "$_tot"
        _tui_wait_enter
        printf '\n'
        [ "$TUI_WAITKEY" = enter ] || break
    done
    rm -f -- "$1.paged"
}

# 原始记录: 最近 N 行, 保留原始时间戳和数据; FILTER=events 时只看异常事件相关行
_tui_lm_rawlog() { # all|events
    local _f _t
    _f=$(env_path "$LM_LOG")
    if [ ! -s "$_f" ]; then printf '还没有取证记录（%s）\n' "$LM_LOG"; return 0; fi
    _t=$(mktemp "${TMPDIR:-/tmp}/apm-lmlog.XXXXXX") || { printf '无法创建临时文件\n'; return 1; }
    if [ "$1" = events ]; then
        grep -a -E '^(OOM|PROCS|BURST|START) ' "$_f" | tail -n 100 > "$_t"
        [ -s "$_t" ] || { printf '没有 OOM、进程表或事件后加密采样记录\n'; rm -f -- "$_t"; return 0; }
        printf '异常事件相关记录（OOM、PROCS、BURST、START，最近 100 行）\n\n'
    else
        tail -n 100 "$_f" > "$_t"
        printf '原始记录（最近 100 行；完整日志 %s）\n\n' "$LM_LOG"
    fi
    _tui_lm_pager "$_t"
    rm -f -- "$_t"
    return 0
}

tui_lm_log_menu() {
    while :; do
        _tui_clear
        _tui_header "Snell · 取证记录"
        _tui_do _tui_lm_forensics_summary
        printf '\n'
        tui_choose "raw|查看原始记录（最近 100 行，分页）
events|只看异常事件相关记录（OOM、进程表、事件后采样）" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            raw) _tui_clear; _tui_header "取证记录 · 原始记录"; _tui_do _tui_lm_rawlog all; _tui_wait ;;
            events) _tui_clear; _tui_header "取证记录 · 异常事件"; _tui_do _tui_lm_rawlog events; _tui_wait ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
    done
}

# ---- 启用 ----

_tui_lm_tcp_changed() { # 来自原始设置的 原值 -> 目标
    local _k _o _t
    for _k in rmem wmem; do
        _o=$(kv_get "$(_lm_orig)" "tcp_${_k}_orig" 2>/dev/null)
        [ -n "$_o" ] || continue
        _t=$(kv_get "$(_lm_orig)" "tcp_${_k}_target" 2>/dev/null)
        printf '      tcp_%s：%s -> %s\n' "$_k" "$_o" "$_t"
    done
}

# 启用 (含可选的 Snell 优先终止): 执行前显示环境检查与预计启用项, 执行后只显示真正发生的结果
_tui_lm_enable() { # [sac]
    local _sac _rc _will _before_en _b_tcp _b_ssh _b_for _b_sac
    _sac=${1:-}
    _tui_lm_collect
    _before_en=$LMT_EN; _b_tcp=$LMT_TCP_S; _b_ssh=$LMT_SSH_S; _b_for=$LMT_FOR_S; _b_sac=$LMT_SAC_S
    printf '环境检查\n'
    _tui_lm_row "$LMT_TCP_S" "TCP 缓冲" "$LMT_TCP_T"
    _tui_lm_row "$LMT_SSH_S" "SSH 进程保护" "$LMT_SSH_T"
    _tui_lm_row "$LMT_FOR_S" "内存取证" "$LMT_FOR_T"
    if [ "$_sac" = sac ] || [ "$LMT_SAC_S" = ok ] || [ "$LMT_SAC_S" = part ]; then _tui_lm_row "$LMT_SAC_S" "Snell 优先终止" "$LMT_SAC_T"; fi
    _will=
    [ "$LMT_TCP_S" != avail ] || _will="$_will
  - TCP 缓冲优化"
    case $LMT_SSH_S in avail|fine) _will="$_will
  - SSH 进程保护" ;; esac
    [ "$LMT_FOR_S" != avail ] || _will="$_will
  - 内存取证"
    if [ "$_sac" = sac ]; then
        case $LMT_SAC_S in off) [ "$LM_P_SAC" = na ] || _will="$_will
  - Snell 优先终止（高级选项）" ;; esac
    fi
    if [ -n "$_will" ]; then printf '\n本次预计启用：%s\n' "$_will"; else printf '\n本次没有可启用的机制\n'; fi
    if [ "$_sac" = sac ]; then lowmem_enable --snell-sacrifice >/dev/null; else lowmem_enable >/dev/null; fi
    _rc=$?
    _tui_lm_collect
    printf '\n启用结果\n'
    if [ "$LMT_EN" != yes ]; then
        printf '  没有任何机制生效，没有保留设置\n'
        return "$_rc"
    fi
    case $LMT_TCP_S in
        ok) if [ "$_before_en" = yes ] && [ "$_b_tcp" = ok ]; then _tui_lm_row ok "TCP 缓冲" "已生效（与之前相同，未改变）"; else _tui_lm_row ok "TCP 缓冲" "成功"; _tui_lm_tcp_changed; fi ;;
        bad) _tui_lm_row bad "TCP 缓冲" "$LMT_TCP_T" ;;
        fine) _tui_lm_row fine "TCP 缓冲" "未调整（缓冲上限合理）" ;;
        *) _tui_lm_row "$LMT_TCP_S" "TCP 缓冲" "未应用（${LMT_TCP_T}）" ;;
    esac
    case $LMT_SSH_S in
        ok) if [ "$_before_en" = yes ] && [ "$_b_ssh" = ok ]; then _tui_lm_row ok "SSH 进程保护" "已生效（未改变）"; else _tui_lm_row ok "SSH 进程保护" "$LMT_SSH_T"; fi ;;
        na) _tui_lm_row na "SSH 进程保护" "未应用（$LMT_SSH_R）" ;;
        *) _tui_lm_row "$LMT_SSH_S" "SSH 进程保护" "$LMT_SSH_T" ;;
    esac
    case $LMT_FOR_S in
        ok) if [ "$_before_en" = yes ] && [ "$_b_for" = ok ]; then _tui_lm_row ok "内存取证" "运行中（未改变）"; else _tui_lm_row ok "内存取证" "已启动"; fi ;;
        na) _tui_lm_row na "内存取证" "未应用（需要 cgroup v2 的 memory.events）" ;;
        *) _tui_lm_row "$LMT_FOR_S" "内存取证" "$LMT_FOR_T" ;;
    esac
    if [ "$_sac" = sac ] || [ "$LMT_SAC_S" = ok ] || [ "$LMT_SAC_S" = part ] || [ "$LMT_SAC_S" = bad ]; then
        case $LMT_SAC_S in
            ok) if [ "$_before_en" = yes ] && [ "$_b_sac" = ok ]; then _tui_lm_row ok "Snell 优先终止" "已生效（未改变）"; else _tui_lm_row ok "Snell 优先终止" "$LMT_SAC_T"; fi ;;
            na) _tui_lm_row na "Snell 优先终止" "未应用（$LMT_SAC_T）" ;;
            *) _tui_lm_row "$LMT_SAC_S" "Snell 优先终止" "$LMT_SAC_T" ;;
        esac
    fi
    case $LMT_PER_S in
        ok) _tui_lm_row ok "开机持久化" "已配置" ;;
        *) _tui_lm_row bad "开机持久化" "$LMT_PER_T" ;;
    esac
    printf '\n'
    if [ "$LMT_BAD" -gt 0 ]; then
        printf '! 保护已启用，但有 %s 项配置了却没有完全生效，详见「查看保护详情」\n' "$LMT_BAD"
    elif [ "$LMT_NA" -gt 0 ]; then
        printf '保护已启用，实际生效 %s 项；%s 项因环境限制不可用\n' "$LMT_OK" "$LMT_NA"
    else
        printf '保护已启用，已配置的 %s 项机制全部生效\n' "$LMT_OK"
    fi
    return "$_rc"
}

# ---- 恢复 ----

_tui_lm_disable() {
    local _ev _rc _bad _file _line _code _val _a _b _any _un
    _tui_lm_collect
    if [ "$LMT_EN" != yes ] && [ ! -f "$(_lm_orig)" ] && ! _lm_init_ours; then
        printf '网络与进程保护（低内存环境）没有启用，没有需要恢复的内容\n'
        return 0
    fi
    _file=$(mktemp "${TMPDIR:-/tmp}/apm-lmev.XXXXXX") || { printf '无法创建临时文件\n'; return 1; }
    LM_EVENTS_FILE=$_file lowmem_disable >/dev/null
    _rc=$?
    printf '恢复结果\n'
    _bad=0
    _un=0
    printf '\n  TCP 参数\n'
    _any=0
    while IFS='|' read -r _code _val; do
        case $_code in
            tcp-restored-*) _any=1; printf '    tcp_%s：已恢复（%s）\n' "${_code#tcp-restored-}" "$_val" ;;
            tcp-same-*) _any=1; printf '    tcp_%s：当前已是原值 %s，无需恢复\n' "${_code#tcp-same-}" "$_val" ;;
            tcp-failed-*) _any=1; _bad=$((_bad + 1)); printf '! 写回原值失败：tcp_%s 当前仍是 %s\n' "${_code#tcp-failed-}" "$_val" ;;
            tcp-external-*) _any=1; _un=$((_un + 1)); printf '! tcp_%s：当前值 %s 已被外部修改，没有覆盖，未恢复\n' "${_code#tcp-external-}" "$_val" ;;
        esac
    done < "$_file"
    [ "$_any" = 1 ] || printf '    没有调整过 TCP 参数，无需恢复\n'
    printf '\n  进程保护\n'
    _any=0
    while IFS='|' read -r _code _val; do
        case $_code in
            ssh-restored) _any=1; printf '    SSH 进程保护：已把 %s 个进程的 oom_score_adj 恢复为原值\n' "$_val" ;;
            ssh-none) _any=1; printf '    SSH 进程保护：没有需要恢复的进程\n' ;;
            sac-restored)
                _any=1
                _a=${_val%% *}; _b=${_val##* }
                if [ "$_a" -gt 0 ] 2>/dev/null; then printf '    Snell 优先终止：已把 %s 个进程恢复为原值\n' "$_a"; else printf '    Snell 优先终止：没有可恢复的进程记录\n'; fi
                if [ "$_b" -gt 0 ] 2>/dev/null; then _un=$((_un + 1)); printf '! %s 个进程因权限无法降低，需在 Snell 下次重启后恢复\n' "$_b"; fi
                ;;
        esac
    done < "$_file"
    [ "$_any" = 1 ] || printf '    没有需要恢复的进程设置\n'
    if grep -q '^sac-norecord|' "$_file"; then
        printf '\n  未修改的项目（没有原始记录，不是已恢复）\n'
        while IFS='|' read -r _code _val; do
            [ "$_code" = sac-norecord ] || continue
            _un=$((_un + 1))
            printf '! Snell 优先终止：%s 个进程的 oom_score_adj 是 %s，没有原值记录，没有改动\n' "${_val%% *}" "${_val##* }"
            printf '    Snell 下次重启后恢复默认\n'
        done < "$_file"
    fi
    printf '\n  OpenRC 与配置\n'
    if grep -q '^service-removed|' "$_file"; then
        printf '    apm-lowmem 服务和设置文件：已删除\n'
        printf '    取证日志：保留在 %s\n' "$LM_LOG"
    else
        printf '! 没有完成：服务和设置文件可能仍在，见上面的提示\n'
        _bad=$((_bad + 1))
    fi
    rm -f -- "$_file"
    printf '\n最终状态：'
    if lm_enabled; then
        printf '保护仍处于启用状态\n'
        return 1
    fi
    if [ "$_bad" -gt 0 ] || [ "$_un" -gt 0 ]; then
        printf '保护已停用，但有 %s 项没有恢复到原始状态，见上面标 ! 的行\n' "$((_bad + _un))"
    else
        printf '保护已停用，已恢复到启用前的状态\n'
    fi
    return "$_rc"
}

# ---- 高级保护选项 ----

_tui_lm_adv_info() {
    _tui_lm_collect
    printf 'Snell 优先终止（OOM）\n'
    _tui_lm_row "$LMT_SAC_S" "当前策略" "$LMT_SAC_T"
    printf '  Snell 进程：\n'
    _tui_lm_proc_list _lm_snell_procs
    printf '  目标策略：把 Snell 进程的 oom_score_adj 提高到 %s\n' "$LM_SNELL_ADJ"
    printf '  预期效果：内存不足时，内核优先终止 Snell，\n'
    printf '    而不是 sshd 等其他进程；这是为了保护管理入口\n'
    printf '! 代价与风险：\n'
    printf '    - 这不会提高 Snell 的稳定性，而是让它更容易被终止\n'
    printf '    - Snell 即使不是内存压力的来源，也会最先被终止\n'
    printf '    - memory.oom.group 为 1 时调整无效\n'
    printf '  只影响 Snell 的 supervise-daemon 的后代进程，不动\n'
    printf '    supervise-daemon、sshd、sing-box 与 AnyTLS Gateway\n'
    if [ "$LMT_SAC_S" = ok ] || [ "$LMT_SAC_S" = part ] || [ "$LMT_SAC_S" = bad ]; then
        printf '  关闭方式：「停用保护并恢复设置」会一并关闭\n    （目前没有单独关闭该选项的命令）\n'
    fi
}

tui_lm_adv_menu() {
    local _items
    while :; do
        _tui_clear
        _tui_header "Snell · 高级保护选项"
        _tui_do _tui_lm_adv_info
        printf '\n'
        _tui_lm_collect >/dev/null 2>&1
        _items=
        case $LMT_SAC_S in
            off) _items="sac|启用 Snell 优先终止（代价见上，未启用保护时会一并启用默认保护）" ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            sac)
                _tui_need_root || continue
                _tui_clear
                _tui_header "高级保护选项 · 启用 Snell 优先终止"
                _tui_do _tui_lm_enable sac
                _tui_page
                ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
    done
}

# ---- 入口 ----

tui_lowmem_menu() {
    local _items _t
    while :; do
        _tui_clear
        _tui_header "Snell · 网络与进程保护（低内存环境）"
        _tui_do _tui_lm_home
        printf '\n'
        if lm_enabled; then _t="off|停用保护并恢复设置"; else _t="on|启用保护（自动检测，只调整需要调整的项目）"; fi
        _items="detail|查看保护详情
log|查看取证记录
adv|高级保护选项
$_t"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            detail) _tui_clear; _tui_header "保护详情"; _tui_do _tui_lm_detail; _tui_page ;;
            log) tui_lm_log_menu ;;
            adv) tui_lm_adv_menu ;;
            on) _tui_need_root || continue; _tui_clear; _tui_header "启用保护"; _tui_do _tui_lm_enable; _tui_page ;;
            off) _tui_need_root || continue; _tui_clear; _tui_header "停用保护并恢复设置"; _tui_do _tui_lm_disable; _tui_page ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
    done
}

# Manager 自更新: 选择 更新 就是确认, 只更新 Manager 本身, 实际升级由 manager_cli update 复用现有安装器完成
# 成功后当前 TUI 进程仍是旧代码, 所以提示重新运行 apm 并退出, 避免误以为已经进入新版
_tui_manager_confirm_update() { # 目标版本
    _tui_need_root || return 0
    printf '更新 Manager：%s -> %s（只更新 Manager，不改动 Snell、sing-box、实例、Profile 与凭据）\n' "$(apm_version)" "$1"
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
        _tui_wait
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
        _tui_wait
    fi
}

tui_manager_menu() {
    while :; do
        _tui_clear
        _tui_header "Manager 管理"
        printf '当前版本：%s\nBuild：%s\n\n' "$(apm_version)" "$(apm_build)"
        tui_choose "check|检查更新
update|更新 Manager
help|查看帮助" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            check) tui_manager_check ;;
            update) tui_manager_update ;;
            help)
                if command -v usage >/dev/null 2>&1; then _tui_do usage; else printf '帮助：proxy-manager help\n'; TUI_RC=0; fi
                _tui_page
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
            _tui_do singbox_cli uninstall
            ;;
    esac
    _tui_page
}

_tui_core_uninstall() { # key
    local _cli
    case $1 in snell) _cli=snell_cli ;; anytlsgw) _cli=agw_cli ;; *) _cli=singbox_cli ;; esac
    _tui_need_root || return 0
    tui_choose "keep|卸载程序（保留配置与日志，可重新安装）
purge|完全卸载（同时删除配置、日志与证书，不可恢复）" "返回"
    case $TUI_KEY in
        back) return 0 ;;
        keep) _tui_do "$_cli" uninstall ;;
        purge)
            tui_confirm "即将完全卸载 $CF_NAME 并删除配置、日志与证书，此操作不可恢复" || { _tui_pause; return 0; }
            _tui_do "$_cli" uninstall --purge
            ;;
    esac
    _tui_page
}

_tui_core_lifecycle() { # key op
    local _cli
    case $1 in snell) _cli=snell_cli ;; anytlsgw) _cli=agw_cli ;; *) _cli=singbox_cli ;; esac
    _tui_need_root || return 0
    case $2 in
        stop) tui_confirm "即将停止 $CF_NAME，所有连接会中断" || { _tui_pause; return 0; } ;;
    esac
    _tui_do "$_cli" "$2"
    _tui_done
}

# 配置里的 地址:端口 翻译成 范围加端口 (这是配置里写的监听地址, 不是实际检测结果)
_tui_listen_text() {
    local _a _p
    case $1 in
        -|'') printf '未配置'; return 0 ;;
        *:*) ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    _p=${1##*:}
    _a=${1%:*}
    case $_p in ''|*[!0-9]*) printf '%s' "$1"; return 0 ;; esac
    printf '%s，端口 %s' "$(_rpt_scope "$_a")" "$_p"
}

# Release 与二进制自报的版本只在不一样时才多显示一行 (例如 v6.0.0rc2 与 v6.0.0)
_tui_release_line() {
    [ -n "$CF_VERSION_EXACT" ] && [ "$CF_VERSION_EXACT" != unknown ] || return 0
    [ "${CF_VERSION_EXACT#v}" != "${CF_VERSION_REPORTED#v}" ] || return 0
    printf 'Release：%s\n' "$CF_VERSION_EXACT"
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
                tui_read_secret "新的 PSK（留空自动生成）：" || { _tui_wait; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                if [ -z "$_pw" ]; then
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
    tui_ask "端口（留空随机选择）："
    _port=$TUI_IN
    tui_read_secret "PSK（留空自动生成）：" || { _tui_wait; return 0; }
    _pw=$TUI_SECRET
    TUI_SECRET=
    set --
    [ -z "$_port" ] || set -- --port "$_port"
    if [ -z "$_pw" ]; then
        _tui_do snell_cli install "$@"
    else
        _tui_do_secret "$_pw" snell_cli install "$@" --psk-stdin
    fi
    _pw=
    _tui_page
}

# Snell 的客户端信息: 一步直达, 直接显示完整连接信息 (含 PSK), 不需要先设置客户端连接地址
# 经 snell export info --secret 按需查询服务器公网 IP, 端口与版本来自 Snell 现有配置, 只读, 查询失败时其余信息照常显示
_tui_snell_info() {
    APM_CX_NOWARN=1
    export APM_CX_NOWARN
    snell_cli export info --secret
}

# Snell 网络功能: SOCKS5 出口 与 目标访问限制, 两者互斥, 各自可以单独启用与禁用
_tui_snn_status() {
    local _f _e
    _f=$(_snn_egress_file)
    if [ ! -f "$_f" ]; then
        printf 'SOCKS5 出口：未配置\n'
    else
        _e=未启用
        [ "$(kv_get "$_f" enabled)" = true ] && _e=已启用
        printf 'SOCKS5 出口：%s，上游 %s:%s\n' "$_e" "$(kv_get "$_f" host)" "$(kv_get "$_f" port)"
    fi
    _f=$(_snn_access_file)
    if [ ! -f "$_f" ]; then
        printf '目标访问限制：未配置\n'
    else
        _e=未启用
        [ "$(kv_get "$_f" enabled)" = true ] && _e=已启用
        printf '目标访问限制：%s，名单 %s 条\n' "$_e" "$(_snn_dests "$_f" | grep -c . || true)"
    fi
}

# 启用前的确认: 说明将要安装的组件, 互斥时直接解释并返回失败
_tui_snn_enable() { # egress|access
    local _cur _miss _item _txt
    _cur=$(snn_mode)
    if [ "$_cur" = "$1" ]; then
        printf '%s已经启用\n' "$(snn_mode_label "$1")"
        _tui_pause
        return 0
    fi
    if [ "$_cur" != none ]; then
        printf '已启用 %s，它与 %s 互斥，两者不能同时启用\n请先在对应菜单里禁用 %s\n' "$(snn_mode_label "$_cur")" "$(snn_mode_label "$1")" "$(snn_mode_label "$_cur")"
        _tui_wait
        return 0
    fi
    _tui_need_root || return 0
    _miss=$(snn_deps_missing "$1")
    _txt="将启用 $(snn_mode_label "$1")，Snell 会重启一次"
    if [ -n "$_miss" ]; then
        _txt="$_txt
需要安装以下组件："
        for _item in $_miss; do
            case $_item in
                graftcp) _txt="$_txt
  graftcp $SNN_GRAFTCP_VER（固定 SHA256 校验，来自本项目 Release）" ;;
                apk:*) _txt="$_txt
  ${_item#apk:}（Alpine 官方软件包）" ;;
            esac
        done
    fi
    printf '%s\n' "$_txt"
    _tui_do snell_cli "$1" enable --yes
    _tui_page
}

tui_snell_egress_menu() {
    local _srv _port _user _pw _dns
    while :; do
        _tui_clear
        _tui_header "Snell · SOCKS5 出口"
        _tui_do snell_cli egress show
        printf '\n'
        tui_choose "set|设置上游
enable|启用
disable|禁用" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            set)
                _tui_need_root || continue
                _tui_socks_target "上游地址或完整 socks5:// 链接（IPv4、IPv6 或域名，留空取消）：" || continue
                _srv=$TUI_SK_HOST
                _tui_socks_port "上游端口："
                _port=$TUI_SK_PORT
                _tui_socks_auth "用户名（留空表示无认证）：" "密码（输入不回显）：" 1 || { _tui_socks_clear; _tui_wait; continue; }
                _user=$TUI_SK_USER
                _pw=$TUI_SK_PASS
                _tui_socks_clear
                tui_ask "解析用的 DNS 服务器 IP（留空使用 $SNN_DNS_SERVER_DEFAULT，查询经由上游）："
                _dns=$TUI_IN
                set -- --server "$_srv" --port "$_port"
                [ -z "$_dns" ] || set -- "$@" --dns-server "$_dns"
                if [ -z "$_user" ]; then
                    _tui_do snell_cli egress set "$@" --no-auth
                else
                    _tui_do_secret "$_pw" snell_cli egress set "$@" --username "$_user" --password-stdin
                    _pw=
                fi
                _tui_done
                ;;
            enable) _tui_snn_enable egress ;;
            disable)
                _tui_need_root || continue
                _tui_do snell_cli egress disable
                _tui_done
                ;;
        esac
    done
}

tui_snell_access_menu() {
    local _host _port
    while :; do
        _tui_clear
        _tui_header "Snell · 目标访问限制"
        _tui_do snell_cli access show
        printf '\n'
        tui_choose "add|添加目标
delete|删除目标
clear|清空名单
refresh|刷新域名解析
enable|启用
disable|禁用" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            add|delete)
                _tui_need_root || continue
                tui_ask "目标主机（IPv4、IPv6 或域名，留空取消）："
                _host=$TUI_IN
                [ -n "$_host" ] || continue
                tui_ask "目标端口："
                _port=$TUI_IN
                _tui_do snell_cli access "$TUI_KEY" "$_host" "$_port"
                _tui_done
                ;;
            clear)
                _tui_need_root || continue
                tui_confirm "将清空名单，启用时会拒绝所有目标" || { _tui_pause; continue; }
                _tui_do snell_cli access clear
                _tui_done
                ;;
            refresh)
                _tui_need_root || continue
                _tui_do snell_cli access refresh
                _tui_done
                ;;
            enable) _tui_snn_enable access ;;
            disable)
                _tui_need_root || continue
                _tui_do snell_cli access disable
                _tui_done
                ;;
        esac
    done
}

tui_snell_net_menu() {
    while :; do
        _tui_clear
        _tui_header "Snell · SOCKS5 出口与目标访问限制"
        _tui_snn_status
        printf '两个功能互斥，各自可以单独启用与禁用；都关闭时 Snell 使用原来的启动方式，没有任何辅助进程\n\n'
        tui_choose "egress|SOCKS5 出口
access|目标访问限制" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            egress) tui_snell_egress_menu ;;
            access) tui_snell_access_menu ;;
        esac
    done
}

# Snell 的网络相关入口: 网络功能 (SOCKS5 出口 目标访问限制) 与 网络与进程保护 (TCP 缓冲 SSH 的 OOM 优先级 内存取证)
# 后者只调整网络参数与进程策略, 不是内存清理或回收工具
tui_snell_netgroup_menu() {
    while :; do
        _tui_clear
        _tui_header "Snell · 网络功能"
        tui_choose "net|Snell 网络功能（SOCKS5 出口、目标访问限制）
protect|网络与进程保护（低内存环境）" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            net) tui_snell_net_menu ;;
            protect) tui_lowmem_menu ;;
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
                printf '版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
                _tui_release_line
                printf '监听：%s\n' "$(_tui_listen_text "${CF_SNELL_LISTEN:--}")"
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
net|网络功能
log|查看日志
client|查看连接信息（含 PSK）
update|更新
uninstall|卸载"
                ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            install) _tui_snell_install ;;
            info) _tui_do snell_cli info; _tui_page ;;
            start|stop|restart) _tui_core_lifecycle snell "$TUI_KEY" ;;
            config) tui_snell_config_menu ;;
            net) tui_snell_netgroup_menu ;;
            log) _tui_log snell ;;
            client) _tui_do _tui_snell_info; _tui_page ;;
            update)
                _tui_need_root || continue
                _tui_do snell_cli update
                _tui_page
                ;;
            uninstall) _tui_core_uninstall snell ;;
        esac
    done
}

# ---- AnyTLS Gateway ----

# 客户端配置: 每条转发线路是一个客户端入口 (各有自己的端口与 AnyTLS 密码), 先选线路, 只有一条时直接进入
tui_agw_client_menu() {
    local _items _id _n _f
    while :; do
        _f=$(_agw_state)
        _items=
        _n=0
        for _id in $(_agw_ids "$_f" 2>/dev/null); do
            _n=$((_n + 1))
            _items="${_items}line:$_id|转发线路 $_id（端口 $(_agw_get "$_f" "$_id" listen | sed 's/.*://')）
"
        done
        if [ "$_n" = 0 ]; then
            printf '当前没有转发线路，请先在 转发线路管理 里添加\n'
            _tui_wait
            return 0
        fi
        if [ "$_n" = 1 ]; then
            _id=$(printf '%s' "$_items" | sed -n 's/^line:\([0-9]*\)|.*/\1/p' | head -n 1)
            tui_export_menu "$_id" agw
            return 0
        fi
        _tui_clear
        _tui_header "AnyTLS Gateway · 客户端配置"
        printf '选择要导出客户端配置的转发线路\n\n'
        tui_choose "${_items%?}" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            line:*) tui_export_menu "${TUI_KEY#line:}" agw ;;
        esac
    done
}

tui_agw_listener_menu() {
    local _pw _srv _port _user _bind _lp
    while :; do
        _tui_clear
        _tui_header "AnyTLS Gateway · 转发线路管理"
        _tui_do agw_cli listener list
        printf '\n'
        tui_choose "add|添加转发线路
delete|删除转发线路
upstream|修改 SOCKS5 出口
newpw|重新生成 AnyTLS 密码
secret|查看 AnyTLS 密码" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            add)
                _tui_need_root || continue
                tui_ask "AnyTLS 监听端口（留空随机选择）："
                _lp=$TUI_IN
                _tui_socks_target "SOCKS5 出口地址或完整 socks5:// 链接（留空取消）：" || continue
                _srv=$TUI_SK_HOST
                _tui_socks_port "SOCKS5 出口端口："
                _port=$TUI_SK_PORT
                _tui_socks_auth "SOCKS5 用户名：" "SOCKS5 密码（输入不回显）：" 0 || { _tui_socks_clear; _tui_wait; continue; }
                _user=$TUI_SK_USER
                _pw=$TUI_SK_PASS
                _tui_socks_clear
                set -- --socks-server "$_srv" --socks-port "$_port" --socks-username "$_user" --socks-password-stdin
                [ -z "$_lp" ] || set -- "$@" --port "$_lp"
                _tui_do_secret "$_pw" agw_cli listener add "$@"
                _pw=
                _tui_page
                ;;
            delete)
                _tui_need_root || continue
                tui_ask "要删除的转发线路 ID 或端口（留空取消）："
                [ -n "$TUI_IN" ] || continue
                tui_confirm "即将删除转发线路 $TUI_IN，使用它的客户端会断开" || { _tui_pause; continue; }
                _tui_do agw_cli listener delete "$TUI_IN"
                _tui_done
                ;;
            upstream)
                _tui_need_root || continue
                tui_ask "转发线路 ID 或端口（留空取消）："
                _lp=$TUI_IN
                [ -n "$_lp" ] || continue
                TUI_SK_HASUSER=0; TUI_SK_HASPASS=0; TUI_SK_PORT=; TUI_SK_USER=; TUI_SK_PASS=
                _srv=
                if _tui_socks_target "新的 SOCKS5 出口地址或完整 socks5:// 链接（留空保持）："; then _srv=$TUI_SK_HOST; fi
                _tui_socks_port "新的 SOCKS5 出口端口（留空保持）："
                _port=$TUI_SK_PORT
                if [ "$TUI_SK_HASUSER" = 0 ]; then
                    tui_ask "新的 SOCKS5 用户名（留空保持）："
                    TUI_SK_USER=$TUI_IN
                fi
                _user=$TUI_SK_USER
                if [ "$TUI_SK_HASPASS" = 0 ]; then
                    tui_read_secret "新的 SOCKS5 密码（留空保持）：" || { _tui_socks_clear; _tui_wait; continue; }
                    TUI_SK_PASS=$TUI_SECRET
                    TUI_SECRET=
                fi
                _pw=$TUI_SK_PASS
                _tui_socks_clear
                set --
                [ -z "$_srv" ] || set -- "$@" --socks-server "$_srv"
                [ -z "$_port" ] || set -- "$@" --socks-port "$_port"
                [ -z "$_user" ] || set -- "$@" --socks-username "$_user"
                if [ -n "$_pw" ]; then
                    _tui_do_secret "$_pw" agw_cli listener set "$_lp" "$@" --socks-password-stdin
                else
                    _tui_do agw_cli listener set "$_lp" "$@"
                fi
                _pw=
                _tui_done
                ;;
            newpw)
                _tui_need_root || continue
                tui_ask "转发线路 ID 或端口（留空取消）："
                [ -n "$TUI_IN" ] || continue
                tui_confirm "将生成新的 AnyTLS 密码并显示一次，旧密码立即失效" || { _tui_pause; continue; }
                _tui_do agw_cli listener set "$TUI_IN" --new-password
                _tui_page
                ;;
            secret)
                _tui_clear
                _tui_header "AnyTLS Gateway · 查看 AnyTLS 密码"
                _tui_do agw_export_secrets
                _tui_page
                ;;
        esac
    done
}

tui_agw_cert_menu() {
    local _c _k
    while :; do
        _tui_clear
        _tui_header "AnyTLS Gateway · 证书管理"
        _tui_do agw_cli cert show
        printf '\n'
        tui_choose "generate|重新生成自签证书
import|导入已有证书" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            generate)
                _tui_need_root || continue
                tui_confirm "将重新生成自签证书，客户端需要更新指纹，服务会重启" || { _tui_pause; continue; }
                _tui_do agw_cli cert generate
                _tui_page
                ;;
            import)
                _tui_need_root || continue
                tui_ask "证书文件路径（留空取消）："
                _c=$TUI_IN
                [ -n "$_c" ] || continue
                tui_ask "私钥文件路径："
                _k=$TUI_IN
                _tui_do agw_cli cert import --cert-file "$_c" --key-file "$_k"
                _tui_page
                ;;
        esac
    done
}

tui_anytlsgw_menu() {
    local _items _pw _srv _port _user
    while :; do
        _tui_clear
        _tui_header "AnyTLS Gateway"
        _tui_core_kind anytlsgw
        printf '状态：'
        _tui_state_dot
        printf '\n'
        case $TUI_CK in
            none) printf '管理：未安装\n' ;;
            unverified) printf '管理：未确认\n'; _tui_warn "检测到名为 anytls-socks-gateway 的入口，但它不是已确认的 ELF，拒绝写操作" ;;
            external) printf '管理：现有部署，未接管\n'; printf '本项目不会修改现有部署，只提供只读信息\n' ;;
            managed)
                printf '管理：已接管\n'
                printf '版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
                ;;
        esac
        case $CF_STATE in crashed|broken) _tui_warn "AnyTLS Gateway 状态异常，详情见详细信息与日志" ;; esac
        _tui_core_notes
        printf '\n'
        case $TUI_CK in
            none) _items="install|安装 AnyTLS Gateway" ;;
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
listener|转发线路管理
cert|证书管理
client|客户端配置
log|查看日志
update|更新
uninstall|卸载"
                ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            install)
                _tui_need_root || continue
                if ! _tui_socks_target "要同时创建第一条转发线路吗？SOCKS5 出口地址或完整 socks5:// 链接（留空只安装）："; then
                    _tui_do agw_cli install
                else
                    _srv=$TUI_SK_HOST
                    _tui_socks_port "SOCKS5 出口端口："
                    _port=$TUI_SK_PORT
                    _tui_socks_auth "SOCKS5 用户名：" "SOCKS5 密码（输入不回显）：" 0 || { _tui_socks_clear; _tui_wait; continue; }
                    _user=$TUI_SK_USER
                    _pw=$TUI_SK_PASS
                    _tui_socks_clear
                    _tui_do_secret "$_pw" agw_cli install --socks-server "$_srv" --socks-port "$_port" --socks-username "$_user" --socks-password-stdin
                    _pw=
                fi
                _tui_page
                ;;
            info) _tui_do agw_cli info; _tui_page ;;
            start|stop|restart) _tui_core_lifecycle anytlsgw "$TUI_KEY" ;;
            listener) tui_agw_listener_menu ;;
            cert) tui_agw_cert_menu ;;
            client) tui_agw_client_menu ;;
            log) _tui_log anytlsgw ;;
            update)
                _tui_need_root || continue
                _tui_do agw_cli update
                _tui_page
                ;;
            uninstall) _tui_core_uninstall anytlsgw ;;
        esac
    done
}

# ---- sing-box Core ----

# ---- sing-box 页面的用户视角展示 ----
# 原则: 显示用户需要理解和操作的信息 (实例 协议 监听端口 运行状态 出口 上游健康), 底层的绑定地址 内部 Listener 原始标签只在 诊断详情 里出现
# 没有开启的可选功能不占一行, 但服务停止 出口异常 实际生效的限制 影响连接的监听范围 配置无效 一律显示

_tui_type_label() {
    case $1 in
        anytls) printf 'AnyTLS' ;;
        hysteria2) printf 'Hysteria2' ;;
        tuic) printf 'TUIC' ;;
        shadowsocks) printf 'Shadowsocks' ;;
        *) printf '%s' "$1" ;;
    esac
}

# 监听端口, 只有监听范围会影响连接时才加说明 (默认的全部接口不显示 ::)
_tui_listen_port_text() { # FILE
    local _p _l
    _p=$(kv_get "$1" listen_port)
    _l=$(kv_get "$1" listen)
    case $_l in
        ''|::) printf '%s' "$_p" ;;
        0.0.0.0) printf '%s（仅 IPv4）' "$_p" ;;
        127.0.0.1) printf '%s（仅本机访问）' "$_p" ;;
        ::1) printf '%s（仅本机访问）' "$_p" ;;
        *) printf '%s（仅监听 %s）' "$_p" "$_l" ;;
    esac
}

# 实例的运行状态, 需要先 core_discover singbox
_tui_inst_state() { # FILE
    if [ "$(kv_get "$1" enabled)" != true ]; then printf '○ 已禁用'; return 0; fi
    if ! sb_instance_validate "$1" >/dev/null 2>&1; then printf '! 配置无效'; return 0; fi
    if [ "$CF_STATE" != running ]; then printf '○ sing-box 未运行'; return 0; fi
    if _sb_inst_listening "$1"; then printf '● 运行中'; else printf '! 没有监听'; fi
}

# 出口: TUI_X_NAME 为空表示直连; TUI_X_PROBLEM 非空表示绑定有问题 (流量会被拒绝, 不会回退直连); TUI_X_HEALTH 是上游健康摘要
_tui_exit_parts() { # FILE
    local _n _pf
    TUI_X_NAME=; TUI_X_PROBLEM=; TUI_X_HEALTH=
    kv_keys "$1" | grep -qx egress_socks || return 0
    _n=$(kv_get "$1" egress_socks)
    TUI_X_NAME=${_n:-(空)}
    _pf=$(state_socks_dir)/$_n.conf
    if [ -z "$_n" ] || ! is_ident "$_n" || [ ! -f "$_pf" ] || ! _sb_socks_check "$_pf" >/dev/null 2>&1; then
        TUI_X_PROBLEM='配置异常，流量会被拒绝，不会回退直连'
    elif [ "$(kv_get "$_pf" enabled)" != true ]; then
        TUI_X_PROBLEM='已禁用，流量会被拒绝，不会回退直连'
    else
        TUI_X_HEALTH=$(sbh_summary "$_n")
    fi
}

# 列表里的实例卡片 (两到三行)
_tui_inst_card() { # FILE
    local _d
    printf '%s  %s  监听端口 %s  %s\n' "$(kv_get "$1" id)" "$(_tui_type_label "$(kv_get "$1" type)")" "$(_tui_listen_port_text "$1")" "$(_tui_inst_state "$1")"
    _tui_exit_parts "$1"
    if [ -n "$TUI_X_NAME" ]; then
        if [ -n "$TUI_X_PROBLEM" ]; then
            printf '  SOCKS5 出口：%s  ! %s\n' "$TUI_X_NAME" "$TUI_X_PROBLEM"
        else
            printf '  SOCKS5 出口：%s  上游健康：%s\n' "$TUI_X_NAME" "$TUI_X_HEALTH"
        fi
    fi
    if _sb_policy_present "$1"; then
        if ! _sb_policy_check "$1" >/dev/null 2>&1; then
            printf '  ! 目标访问限制配置无效，生成配置会被拒绝\n'
        elif _sb_policy_on "$1"; then
            _d=$(_sb_policy_dests "$1" | grep -c .)
            if [ "$_d" -eq 0 ]; then printf '  ! 目标访问限制：允许名单为空，所有目标都会被拒绝\n'; else printf '  目标访问限制：只允许 %s 个目标\n' "$_d"; fi
        fi
    fi
}

_tui_add_menu() {
    _tui_sb_managed || return 0
    _tui_clear
    _tui_header "sing-box · 添加实例"
    tui_choose "anytls|AnyTLS
hysteria2|Hysteria2
tuic|TUIC
shadowsocks|Shadowsocks" "返回"
    [ "$TUI_KEY" = back ] || _tui_add_instance "$TUI_KEY"
}

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

tui_singbox_menu() {
    local _items _f _any
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
                printf '管理：已接管\n'
                printf '版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
                _tui_release_line
                printf '\n'
                _any=0
                for _f in $(state_list_confs "$(state_instances_dir)"); do
                    _any=1
                    _tui_inst_card "$_f"
                done
                [ "$_any" = 1 ] || printf '还没有协议实例，选择 添加实例 创建\n'
                ;;
        esac
        case $CF_STATE in crashed|broken) _tui_warn "sing-box 状态异常，详情见诊断详情与日志" ;; esac
        _tui_core_notes
        printf '\n'
        case $TUI_CK in
            none) _items="install|安装 sing-box" ;;
            unverified) _items="info|诊断详情" ;;
            external) _items="info|诊断详情
log|查看日志" ;;
            managed)
                _items=
                for _f in $(state_list_confs "$(state_instances_dir)"); do
                    _items="${_items}inst:$(kv_get "$_f" id)|管理 $(kv_get "$_f" id)
"
                done
                _items="${_items}add|添加实例
socks|SOCKS5 出口"
                if [ "$CF_STATE" = running ]; then
                    _items="$_items
stop|停止
restart|重启"
                else
                    _items="$_items
start|启动"
                fi
                _items="$_items
log|查看日志
update|更新
info|诊断详情
uninstall|卸载"
                ;;
        esac
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            install) _tui_singbox_install ;;
            info) _tui_do singbox_cli info; _tui_page ;;
            inst:*) tui_instance_menu "${TUI_KEY#inst:}" ;;
            add) _tui_add_menu ;;
            socks) tui_socks_menu ;;
            start|stop|restart) _tui_core_lifecycle singbox "$TUI_KEY" ;;
            log) _tui_log singbox ;;
            update)
                _tui_need_root || continue
                _tui_do singbox_cli update
                _tui_page
                ;;
            uninstall) _tui_singbox_uninstall ;;
        esac
    done
}

_tui_singbox_install() {
    _tui_need_root || return 0
    _tui_do singbox_cli install
    _tui_page
}

_tui_sb_managed() {
    _tui_core_kind singbox
    if [ "$TUI_CK" = managed ]; then return 0; fi
    case $TUI_CK in
        none) printf 'sing-box 尚未安装，请先在 sing-box 菜单中安装\n' ;;
        external) printf 'sing-box 是现有部署，未接管，本项目不会修改它\n' ;;
        *) printf 'sing-box 状态未确认，拒绝写操作\n' ;;
    esac
    _tui_wait
    return 1
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
            tui_ask "TLS 服务名（SNI，留空使用默认）："
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
    tui_read_secret "密码或密钥（留空自动生成）：" || { _tui_wait; return 0; }
    _pw=$TUI_SECRET
    TUI_SECRET=
    if [ -z "$_pw" ]; then
        _tui_do singbox_cli add "$_t" "$@"
    else
        _tui_do_secret "$_pw" singbox_cli add "$_t" "$@" --password-stdin
    fi
    _pw=
    _tui_page
}

# ---- 实例页 ----

# 实例页头部: 只显示用户需要的信息
_tui_inst_header() { # FILE
    local _t _pol _ep
    _t=$(kv_get "$1" type)
    printf '状态：%s\n' "$(_tui_inst_state "$1")"
    printf '监听端口：%s\n' "$(_tui_listen_port_text "$1")"
    if _sb_type_tls "$_t"; then printf 'TLS 服务名（SNI）：%s\n' "$(kv_get "$1" tls.server_name)"; fi
    _tui_exit_parts "$1"
    if [ -z "$TUI_X_NAME" ]; then
        printf '出口：直连\n'
    elif [ -n "$TUI_X_PROBLEM" ]; then
        printf 'SOCKS5 出口：%s\n! %s\n' "$TUI_X_NAME" "$TUI_X_PROBLEM"
    else
        printf 'SOCKS5 出口：%s\n上游健康：%s\n' "$TUI_X_NAME" "$TUI_X_HEALTH"
        sbh_detail_lines "$TUI_X_NAME"
    fi
    if _sb_policy_present "$1"; then
        if ! _sb_policy_check "$1" >/dev/null 2>&1; then
            printf '! 目标访问限制配置无效，生成配置会被拒绝（不会退回不限制）\n'
        elif _sb_policy_on "$1"; then
            _pol=$(_sb_policy_dests "$1" | grep -c .)
            if [ "$_pol" -eq 0 ]; then printf '! 目标访问限制：允许名单为空，所有目标都会被拒绝\n'; else printf '目标访问限制：只允许 %s 个目标\n' "$_pol"; fi
        fi
    fi
    _ep=$(kv_get "$1" public.host)
    [ -z "$_ep" ] || printf '客户端连接地址：%s:%s\n' "$_ep" "$(kv_get "$1" public.port)"
}

# 修改动作, 取消（留空）不改变任何东西
_tui_inst_edit() { # ID KEY
    local _pw _m
    case $2 in
        port|server-name|congestion-control)
            _tui_need_root || return 0
            case $2 in
                port) tui_ask "新的监听端口（留空取消）：" ;;
                server-name) tui_ask "新的 TLS 服务名（SNI，留空取消）：" ;;
                congestion-control) tui_ask "拥塞控制 ($SB_TUIC_CC，留空取消)：" ;;
            esac
            [ -n "$TUI_IN" ] || return 0
            _tui_do singbox_cli set "$1" "$2" "$TUI_IN"
            _tui_done
            ;;
        uuid)
            _tui_need_root || return 0
            tui_ask "新的 UUID（留空自动生成）："
            if [ -z "$TUI_IN" ]; then _tui_do singbox_cli set "$1" uuid --generate; else _tui_do singbox_cli set "$1" uuid "$TUI_IN"; fi
            _tui_page
            ;;
        password)
            _tui_need_root || return 0
            tui_read_secret "新的密码（留空自动生成）：" || { _tui_wait; return 0; }
            _pw=$TUI_SECRET
            TUI_SECRET=
            if [ -z "$_pw" ]; then
                _tui_do singbox_cli set "$1" password --generate
            else
                _tui_do_secret "$_pw" singbox_cli set "$1" password --stdin
            fi
            _pw=
            _tui_page
            ;;
        method)
            _tui_need_root || return 0
            tui_ask "method（$SB_SS_METHODS，留空取消）："
            _m=$TUI_IN
            [ -n "$_m" ] || return 0
            tui_read_secret "该 method 的密钥（留空自动生成）：" || { _tui_wait; return 0; }
            _pw=$TUI_SECRET
            TUI_SECRET=
            if [ -z "$_pw" ]; then
                _tui_do singbox_cli set "$1" method "$_m" --generate
            else
                _tui_do_secret "$_pw" singbox_cli set "$1" method "$_m" --stdin
            fi
            _pw=
            _tui_page
            ;;
    esac
}

tui_instance_menu() { # ID
    local _f _t _items
    _f=$(state_instances_dir)/$1.conf
    while [ -f "$_f" ]; do
        _t=$(kv_get "$_f" type)
        _tui_clear
        _tui_header "$1 · $(_tui_type_label "$_t")"
        _tui_core_kind singbox
        _tui_inst_header "$_f"
        printf '\n'
        if [ "$(kv_get "$_f" enabled)" = true ]; then _items="toggle|禁用"; else _items="toggle|启用"; fi
        _items="$_items
port|修改监听端口"
        if _sb_type_tls "$_t"; then _items="$_items
server-name|修改 TLS 服务名（SNI）"; fi
        if [ "$_t" = tuic ]; then _items="$_items
uuid|修改 UUID
congestion-control|修改拥塞控制"; fi
        if [ "$_t" = shadowsocks ]; then
            _items="$_items
method|修改 method 与密钥"
        else
            _items="$_items
password|修改密码"
        fi
        _items="$_items
export|客户端配置
policy|目标访问限制
delete|删除实例"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            toggle)
                _tui_need_root || continue
                if [ "$(kv_get "$_f" enabled)" = true ]; then _tui_do singbox_cli disable "$1"; else _tui_do singbox_cli enable "$1"; fi
                _tui_done
                ;;
            port|server-name|congestion-control|uuid|password|method) _tui_inst_edit "$1" "$TUI_KEY" ;;
            policy) tui_policy_menu "$1" ;;
            export) tui_export_menu "$1" ;;
            delete)
                _tui_need_root || continue
                tui_confirm "即将删除实例 $1，客户端将无法再连接" || { _tui_pause; continue; }
                _tui_do singbox_cli delete "$1"
                _tui_done
                ;;
        esac
    done
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
            show) _tui_do singbox_cli access "$1" show; _tui_page ;;
            unrestricted|allowlist|clear)
                _tui_need_root || continue
                _tui_sb_managed || continue
                if [ "$TUI_KEY" = clear ]; then
                    tui_confirm "将清空全部允许目标" || { _tui_pause; continue; }
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

_tui_socks_add() {
    local _srv _port _name _user _pw
    _tui_need_root || return 0
    _tui_sb_managed || return 0
    _tui_socks_target "SOCKS5 服务器地址或完整 socks5:// 链接（IPv4 或 IPv6，留空取消）：" || return 0
    _srv=$TUI_SK_HOST
    _tui_socks_port "端口："
    [ -n "$TUI_SK_PORT" ] || { _tui_socks_clear; return 0; }
    _port=$TUI_SK_PORT
    tui_ask "Profile 名称（留空自动编号）："
    _name=$TUI_IN
    _tui_socks_auth "用户名（留空表示无认证）：" "密码（输入不回显）：" 1 || { _tui_socks_clear; _tui_wait; return 0; }
    _user=$TUI_SK_USER
    _pw=$TUI_SK_PASS
    _tui_socks_clear
    set -- --server "$_srv" --port "$_port"
    [ -z "$_name" ] || set -- "$@" --name "$_name"
    if [ -z "$_user" ]; then
        _tui_do singbox_cli socks add "$@" --no-auth
    else
        if [ -z "$_pw" ]; then
            printf '密码不能为空\n'
            _tui_wait
            return 0
        fi
        _tui_do_secret "$_pw" singbox_cli socks add "$@" --username "$_user" --password-stdin
        _pw=
    fi
    _tui_done
}

# ---- SOCKS5 出口 ----

# 实例的出口绑定: 直连与全部 Profile 一次列出（带上游健康）, 选一次即完成

# Profile 的卡片: 名称 上游 健康 使用它的实例
_tui_profile_card() { # NAME
    local _pf _u
    _pf=$(state_socks_dir)/$1.conf
    _u=$(_sb_socks_users "$1" "$(state_instances_dir)")
    printf '%s\n' "$1"
    printf '  上游：%s:%s\n' "$(kv_get "$_pf" host)" "$(kv_get "$_pf" port)"
    if ! _sb_socks_check "$_pf" >/dev/null 2>&1; then
        printf '  ! 配置无效\n'
    elif [ "$(kv_get "$_pf" enabled)" != true ]; then
        printf '  ○ 已禁用\n'
    elif [ -z "$_u" ]; then
        printf '  未被任何实例使用\n'
    else
        printf '  上游健康：%s\n' "$(sbh_summary "$1")"
        sbh_detail_lines "$1" | sed 's/^/  /'
    fi
    [ -z "$_u" ] || printf '  使用它的实例：%s\n' "$_u"
}

tui_socks_profile_menu() { # 名称
    local _f _items _pw _u
    _f=$(state_socks_dir)/$1.conf
    while [ -f "$_f" ]; do
        _tui_clear
        _tui_header "SOCKS5 服务器 · $1"
        _tui_core_kind singbox
        _tui_profile_card "$1"
        if sbh_profile_on "$1"; then printf '  健康监控：已开启\n'; else printf '  健康监控：已关闭\n'; fi
        if [ -n "$(kv_get "$_f" username)" ]; then printf '  认证：用户名与密码\n'; else printf '  认证：无认证\n'; fi
        printf '\n'
        if [ "$(kv_get "$_f" enabled)" = true ]; then _items="toggle|禁用"; else _items="toggle|启用"; fi
        _items="$_items
server|修改服务器地址
port|修改端口
credential|修改用户名与密码
noauth|改为无认证
delete|删除"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            toggle)
                _tui_need_root || continue
                if [ "$(kv_get "$_f" enabled)" = true ]; then
                    printf '禁用后，绑定该出口的实例流量会被拒绝，不会回落 DIRECT\n'
                    _tui_do singbox_cli socks disable "$1"
                else
                    _tui_do singbox_cli socks enable "$1"
                fi
                _tui_done
                ;;
            server|port)
                _tui_need_root || continue
                if [ "$TUI_KEY" = server ]; then tui_ask "新的服务器地址（留空取消）："; else tui_ask "新的端口（留空取消）："; fi
                [ -n "$TUI_IN" ] || continue
                _tui_do singbox_cli socks set "$1" "$TUI_KEY" "$TUI_IN"
                _tui_done
                ;;
            credential)
                _tui_need_root || continue
                tui_ask "用户名（留空取消）："
                [ -n "$TUI_IN" ] || continue
                _u=$TUI_IN
                tui_read_secret "密码（输入不回显）：" || { _tui_wait; continue; }
                _pw=$TUI_SECRET
                TUI_SECRET=
                [ -n "$_pw" ] || { printf '密码不能为空\n'; _tui_wait; continue; }
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
                _u=$(_sb_socks_users "$1" "$(state_instances_dir)")
                if [ -n "$_u" ]; then
                    printf '%s 仍被这些实例使用：%s\n请先在 分配实例出口 里把它们改成其他服务器或 DIRECT，不会自动改成 DIRECT\n' "$1" "$_u"
                    _tui_wait
                    continue
                fi
                tui_confirm "即将删除 SOCKS5 服务器 $1" || { _tui_pause; continue; }
                _tui_do singbox_cli socks delete "$1"
                _tui_done
                ;;
        esac
    done
}

# ---- SOCKS5 出口管理中心 ----
# 职责分界: 实例页管理协议本身 (端口 密码 server-name 客户端配置 访问限制), SOCKS5 管理中心负责出口资源与分配
# 一个中心完成三件事: 管理 SOCKS5 服务器, 为全部实例分配出口, 健康监控开关

# 健康监控整体状态的一行说明, 监控服务异常与上游故障、监控关闭与没有连接证据都分开显示
_tui_health_global_text() {
    local _f _n _k _any _kn
    if ! sbh_enabled; then printf '已关闭（命令行整体关闭，sing-box health enable 重新开启）'; return 0; fi
    _n=0
    _k=0
    for _f in $(state_list_confs "$(state_socks_dir)"); do
        _n=$((_n + 1))
        sbh_profile_on "$(kv_get "$_f" name)" && _k=$((_k + 1))
    done
    _any=0
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _tui_exit_parts "$_f"
        if [ -n "$TUI_X_NAME" ] && sbh_profile_on "$TUI_X_NAME"; then _any=1; break; fi
    done
    if [ "$_any" = 0 ]; then printf '已开启（现在没有需要监控的服务器）'; return 0; fi
    core_discover singbox
    _kn=
    if [ "$(sbh_mode)" = custom ]; then _kn="自定义监控 $_k/$_n 台，"; fi
    if [ "$CF_STATE" != running ]; then printf '已开启（%ssing-box 未运行）' "$_kn"; return 0; fi
    if sbh_monitor_up; then printf '已开启（%s事件驱动）' "$_kn"; else printf '已开启 ! 监控服务没有运行，上游状态显示为未知，sing-box 的转发不受影响'; fi
}

# 服务器一览里的简要卡片: 名称 上游 健康
_tui_profile_brief() { # NAME
    local _pf _u
    _pf=$(state_socks_dir)/$1.conf
    _u=$(_sb_socks_users "$1" "$(state_instances_dir)")
    printf '%s\n' "$1"
    printf '  上游：%s:%s\n' "$(kv_get "$_pf" host)" "$(kv_get "$_pf" port)"
    if ! _sb_socks_check "$_pf" >/dev/null 2>&1; then
        printf '  ! 配置无效\n'
    elif [ "$(kv_get "$_pf" enabled)" != true ]; then
        printf '  ○ 已禁用\n'
    elif [ -z "$_u" ]; then
        printf '  未被任何实例使用\n'
    else
        printf '  健康：%s\n' "$(sbh_summary "$1")"
    fi
}

# 一行出口去向: SOCKS-01 或 DIRECT, 绑定有问题时说明
_tui_assign_text() { # FILE
    _tui_exit_parts "$1"
    if [ -z "$TUI_X_NAME" ]; then
        printf 'DIRECT'
    elif [ -n "$TUI_X_PROBLEM" ]; then
        printf '%s  ! %s' "$TUI_X_NAME" "$TUI_X_PROBLEM"
    else
        printf '%s' "$TUI_X_NAME"
    fi
}

# 静默执行一个会刷新页面的操作: 成功且没有需要看的信息就直接返回, 失败或发生了 sing-box 重启才显示输出并等待
_tui_quiet() { # 命令...
    local _out
    _out=$( ( "$@" ) </dev/null 2>&1 )
    TUI_RC=$?
    case $TUI_RC:$_out in
        0:*重启*) printf '%s\n' "$_out" ;;
        0:*) return 0 ;;
        *) printf '%s\n' "$_out" ;;
    esac
    _tui_done
}

# ---- 分配实例出口 ----

# 为一个实例选择出口: 全部 SOCKS5 服务器和 DIRECT 一次列出, 选一次即完成 (自动校验并应用, 失败保留原配置)
_tui_assign_pick() { # 实例 ID
    local _f _items _p _n _cur _lab
    _f=$(state_instances_dir)/$1.conf
    _tui_clear
    _tui_header "为 $1 选择出口"
    _tui_core_kind singbox
    _tui_exit_parts "$_f"
    _cur=$TUI_X_NAME
    printf '当前：%s\n\n' "$(_tui_assign_text "$_f")"
    _items=
    for _p in $(state_list_confs "$(state_socks_dir)"); do
        _n=$(kv_get "$_p" name)
        if [ "$(kv_get "$_p" enabled)" = true ]; then
            _lab="$_n  $(sbh_summary "$_n")"
        else
            _lab="$_n  ○ 已禁用"
        fi
        [ "$_n" != "$_cur" ] || _lab="$_lab（当前）"
        _items="${_items}socks:$_n|$_lab
"
    done
    if [ -z "$_cur" ]; then _lab='DIRECT（当前）'; else _lab='DIRECT'; fi
    _items="${_items}direct|$_lab"
    tui_choose "$_items" "返回"
    case $TUI_KEY in
        back) return 0 ;;
        direct)
            _tui_need_root || return 0
            _tui_sb_managed || return 0
            _tui_do singbox_cli egress "$1" direct
            _tui_done
            ;;
        socks:*)
            _tui_need_root || return 0
            _tui_sb_managed || return 0
            printf '该实例流量将通过 %s 出口，不会自动回落 DIRECT\n' "${TUI_KEY#socks:}"
            _tui_do singbox_cli egress "$1" socks "${TUI_KEY#socks:}"
            _tui_done
            ;;
    esac
}

tui_assign_menu() {
    local _f _items _id _n
    while :; do
        _tui_clear
        _tui_header "实例出口分配"
        _tui_core_kind singbox
        _items=
        _n=0
        for _f in $(state_list_confs "$(state_instances_dir)"); do
            _n=$((_n + 1))
            _id=$(kv_get "$_f" id)
            _items="${_items}${_id}|${_id}  → $(_tui_assign_text "$_f")
"
        done
        if [ "$_n" -eq 0 ]; then
            printf '还没有协议实例，请先添加实例\n'
            _tui_wait
            return 0
        fi
        printf '选择要修改出口的实例：\n\n'
        tui_choose "$_items" "返回"
        [ "$TUI_KEY" != back ] || return 0
        _tui_assign_pick "$TUI_KEY"
    done
}

# ---- 健康监控开关 ----
# 监控范围两种互斥的模式: 全部监控 (所有服务器都监控) 和 自定义监控 (逐台设置)
# 自定义监控里每台服务器的设置独立保存, 切换模式不改写它们

tui_health_menu() {
    local _f _items _n _on _mode
    while :; do
        _tui_clear
        _tui_header "SOCKS5 · 健康监控管理"
        _tui_core_kind singbox
        _mode=$(sbh_mode)
        if [ "$_mode" = all ]; then
            printf '全部监控：已开启\n当前模式：全部监控\n'
        else
            printf '全部监控：已关闭\n当前模式：自定义监控\n'
        fi
        sbh_enabled || printf '! 健康监控被命令行整体关闭（sing-box health disable），重新开启 sing-box health enable 后才会生效\n'
        case $(_tui_health_global_text) in *'!'*服务*) printf '! 监控服务没有运行，上游状态显示为未知，sing-box 的转发不受影响\n' ;; esac
        printf '\n'
        _items=
        for _f in $(state_list_confs "$(state_socks_dir)"); do
            _n=$(kv_get "$_f" name)
            if sbh_profile_on "$_n"; then _on='已开启'; else _on='已关闭'; fi
            _items="${_items}profile:$_n|$_n    $_on
"
        done
        [ -n "$_items" ] || printf '还没有 SOCKS5 服务器\n\n'
        _items="${_items}mode|全部监控开关"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            mode)
                _tui_need_root || continue
                _tui_sb_managed || continue
                if [ "$_mode" = all ]; then _tui_quiet singbox_cli health mode custom; else _tui_quiet singbox_cli health mode all; fi
                ;;
            profile:*)
                if [ "$_mode" = all ]; then
                    printf '当前是全部监控模式，所有服务器都在监控，不能单独修改。\n请先选择 全部监控开关 切换到自定义监控，各服务器再单独设置。\n'
                    _tui_wait
                    continue
                fi
                _tui_need_root || continue
                _tui_sb_managed || continue
                _n=${TUI_KEY#profile:}
                if sbh_profile_on "$_n"; then _tui_quiet singbox_cli health profile "$_n" off; else _tui_quiet singbox_cli health profile "$_n" on; fi
                ;;
        esac
    done
}

# ---- 自动故障切换 ----

# 列出每台 SOCKS5 服务器的开关, 选编号切换; 恢复验证地址在同一页里设置
tui_failover_menu() {
    local _f _items _n _on _u
    while :; do
        _tui_clear
        _tui_header "SOCKS5 · 自动故障切换"
        _tui_core_kind singbox
        printf '! 开启后，这台服务器的 SOCKS5 上游确认故障时，新连接会临时通过 VPS 自己的 IP 直连，目标网站会看到 VPS 的出口 IP\n'
        printf '  上游恢复后自动切回 SOCKS5，已建立的连接不迁移；默认关闭，需要健康监控开启才生效\n\n'
        _items=
        for _f in $(state_list_confs "$(state_socks_dir)"); do
            _n=$(kv_get "$_f" name)
            if sbh_failover_pref "$_n"; then _on='已开启'; else _on='已关闭'; fi
            _u=
            if sbh_failover_pref "$_n" && ! sbh_failover_effective "$_n"; then _u='（健康监控已关闭，暂不生效）'; fi
            _items="${_items}profile:$_n|$_n    $_on$_u
"
        done
        [ -n "$_items" ] || printf '还没有 SOCKS5 服务器\n\n'
        printf '恢复验证地址 1：%s\n恢复验证地址 2：%s\n\n' "$(sbh_probe_url_get 1)" "$(sbh_probe_url_get 2)"
        _items="${_items}urls|设置恢复验证地址"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            urls) _tui_failover_urls ;;
            profile:*)
                _tui_need_root || continue
                _tui_sb_managed || continue
                _n=${TUI_KEY#profile:}
                if sbh_failover_pref "$_n"; then
                    _tui_quiet singbox_cli health failover "$_n" off
                elif tui_confirm "开启后 $_n 的上游故障时，新连接会临时通过 VPS 自己的 IP 直连"; then
                    _tui_quiet singbox_cli health failover "$_n" on
                fi
                ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
    done
}

# 两个独立的 https 地址, 任意一个经该 SOCKS5 请求成功就算恢复; 留空保持不变, 输入 default 恢复默认
_tui_failover_urls() {
    local _i
    for _i in 1 2; do
        tui_ask "恢复验证地址 $_i（留空不改，default 恢复默认）："
        [ "${TUI_EOF:-0}" != 1 ] || return 0
        [ -n "$TUI_IN" ] || continue
        _tui_need_root || return 0
        _tui_sb_managed || return 0
        _tui_quiet singbox_cli health probe-url "$_i" "$TUI_IN"
    done
}

# ---- 管理 SOCKS5 服务器 ----

tui_socks_servers_menu() {
    local _f _any _items
    while :; do
        _tui_clear
        _tui_header "SOCKS5 服务器"
        _tui_core_kind singbox
        _any=0
        for _f in $(state_list_confs "$(state_socks_dir)"); do
            _any=1
            _tui_profile_card "$(kv_get "$_f" name)"
            printf '\n'
        done
        [ "$_any" = 1 ] || printf '还没有 SOCKS5 服务器\n\n'
        _items="add|添加 SOCKS5 服务器"
        for _f in $(state_list_confs "$(state_socks_dir)"); do
            _items="$_items
prof:$(kv_get "$_f" name)|管理 $(kv_get "$_f" name)（$(kv_get "$_f" host):$(kv_get "$_f" port)）"
        done
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            prof:*) tui_socks_profile_menu "${TUI_KEY#prof:}" ;;
            add) _tui_socks_add ;;
        esac
    done
}

tui_socks_menu() {
    local _f _any
    while :; do
        _tui_clear
        _tui_header "sing-box · SOCKS5 出口管理"
        _tui_core_kind singbox
        printf '健康监控：%s\n\n' "$(_tui_health_global_text)"
        printf 'SOCKS5 服务器：\n\n'
        _any=0
        for _f in $(state_list_confs "$(state_socks_dir)"); do
            _any=1
            _tui_profile_brief "$(kv_get "$_f" name)"
            printf '\n'
        done
        [ "$_any" = 1 ] || printf '还没有 SOCKS5 服务器\n\n'
        printf '实例出口分配：\n\n'
        _any=0
        for _f in $(state_list_confs "$(state_instances_dir)"); do
            _any=1
            printf '%s  → %s\n' "$(kv_get "$_f" id)" "$(_tui_assign_text "$_f")"
        done
        [ "$_any" = 1 ] || printf '还没有协议实例\n'
        printf '\n'
        tui_choose "servers|管理 SOCKS5 服务器
assign|分配实例出口
health|健康监控开关
failover|自动故障切换" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            servers) tui_socks_servers_menu ;;
            assign) tui_assign_menu ;;
            health) tui_health_menu ;;
            failover) tui_failover_menu ;;
        esac
    done
}

# ---- 客户端配置 ----

# ---- 服务器公网地址输入 (Enter 自动获取 / 手动输入 / Esc 取消) ----

# 读一个字节, 十六进制放 TUI_K, 超时或 EOF 为空
_tui_getbyte() {
    TUI_K=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
}

# 读一行服务器地址. 结果在 TUI_IN, 取消 (Esc 或 EOF) 置 TUI_ESC=1
# 交互终端: 逐键读取, Enter 提交, 单独的 Esc 立即取消; 方向键等转义序列被吞掉, 不会当成取消也不会混进输入
# 非交互 (测试与管道): 按行读取, 行首的真实 ESC 字符视为取消, EOF 视为取消
_tui_read_host_line() {
    local _buf _k _n _nonascii
    _nonascii=0
    TUI_IN=
    TUI_ESC=0
    if _tui_in_tty && [ "${APM_TUI_NO_RAW:-0}" != 1 ]; then
        TUI_STTY_SAVED=$(_snell_run stty -g 2>/dev/null) || TUI_STTY_SAVED=
        if [ -n "$TUI_STTY_SAVED" ] && _snell_run stty -icanon -echo min 1 time 0 2>/dev/null; then
            _buf=
            while :; do
                _tui_getbyte
                if [ -z "$TUI_K" ]; then TUI_EOF=1; TUI_ESC=1; break; fi
                case $TUI_K in
                    0a|0d) break ;;
                    1b)
                        _snell_run stty min 0 time 1 2>/dev/null
                        _tui_getbyte
                        if [ -z "$TUI_K" ]; then
                            TUI_ESC=1
                            break
                        fi
                        while [ -n "$TUI_K" ]; do _tui_getbyte; done
                        _snell_run stty min 1 time 0 2>/dev/null
                        ;;
                    7f|08)
                        if [ -n "$_buf" ]; then
                            _buf=${_buf%?}
                            printf '\b \b'
                        fi
                        ;;
                    04) if [ -z "$_buf" ]; then TUI_ESC=1; break; fi ;;
                    *)
                        _n=$((0x$TUI_K))
                        # 非 ASCII (中文等) 不可能是合法的 IP 或域名: 记下来, Enter 时按无效输入处理, 而不是悄悄丢掉后变成"自动获取"
                        if [ "$_n" -ge 128 ]; then _nonascii=1; fi
                        if [ "$_n" -ge 32 ] && [ "$_n" -le 126 ] && [ "${#_buf}" -lt 253 ]; then
                            _k=$(printf '%b' "$(printf '\\%03o' "$_n")")
                            _buf=$_buf$_k
                            printf '%s' "$_k"
                        fi
                        ;;
                esac
            done
            _tui_restore
            printf '\n'
            [ "$TUI_ESC" = 1 ] || TUI_IN=$(printf '%s' "$_buf" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ "$_nonascii" = 0 ] || TUI_IN="含非 ASCII 字符的输入"
            return 0
        fi
        _tui_restore
    fi
    if IFS= read -r TUI_IN; then
        case $TUI_IN in
            "$(printf '\033')"*) TUI_ESC=1; TUI_IN= ;;
            *) TUI_IN=$(printf '%s' "$TUI_IN" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') ;;
        esac
    else
        TUI_EOF=1
        TUI_ESC=1
        TUI_IN=
    fi
    return 0
}

# 统一的服务器公网地址选择: 所有需要"客户端连接用的服务器 IP 或域名"的入口都走这里
# Enter 自动获取公网 IP, 输入合法 IPv4 IPv6 域名则使用输入值, Esc 取消并返回上级
# 成功返回 0, 规范化后的主机在 TUI_HOST; 取消返回 1. 自动获取只读查询, 不修改服务器的任何网络配置
tui_ask_server_host() {
    local _ip _msg _norm
    TUI_HOST=
    while :; do
        printf '\n服务器公网 IP / 域名\n\n'
        printf '直接按 Enter：自动获取公网 IP\n'
        printf '输入 IP 或域名：使用自定义地址\n'
        printf '输入 0 或按 Esc：取消并返回\n\n'
        printf '请选择：'
        _tui_read_host_line
        # 0 必须在 Enter 提交后才生效; 它不是合法的主机, 所以不会与真实输入冲突
        if [ "$TUI_ESC" = 1 ] || [ "$TUI_IN" = 0 ]; then
            printf '已取消\n'
            return 1
        fi
        if [ -z "$TUI_IN" ]; then
            printf '正在查询服务器公网 IP（只读查询，不会修改服务器网络）...\n'
            if _ip=$(client_public_ip_auto); then
                printf '已自动获取服务器公网 IP：%s\n' "$_ip"
                printf '提示：服务器在 NAT 后面或使用了端口映射时，这个地址客户端可能连不上，请改用手动输入\n'
                TUI_HOST=$_ip
                return 0
            fi
            printf '自动获取失败：无法从查询服务得到有效的公网 IP（网络不可用 查询超时 或返回的不是公网地址）\n'
            printf '可以再按 Enter 重试，或手动输入 IP 或域名，或输入 0 / 按 Esc 返回\n'
            continue
        fi
        if _norm=$(client_host_norm "$TUI_IN"); then
            TUI_HOST=$_norm
            return 0
        fi
        _msg=$_norm
        printf '输入无效：%s\n请重新输入\n' "$_msg"
    done
}

# 导出客户端配置需要客户端连接地址（服务器的公网 IP 或域名）, 没有保存过就在需要的这一刻询问并保存, 之后不再询问
# 已保存的地址不会被改动; 它只用于生成客户端配置, 不配置 NAT 与防火墙
# sing-box 实例与 AnyTLS Gateway 的转发线路共用这一套界面与地址选择, 区别只在数据来源 (KIND sb | agw)

_tui_cx_file() { # KIND ID -> 保存客户端连接地址的文件
    if [ "$1" = agw ]; then _cx_agw_ep_file "$2"; else printf '%s/%s.conf' "$(state_instances_dir)" "$2"; fi
}

_tui_cx_lport() { # KIND ID -> 内部监听端口 (客户端连接端口的默认值)
    if [ "$1" = agw ]; then
        _agw_get "$(_agw_state)" "$2" listen | sed 's/.*://'
    else
        kv_get "$(state_instances_dir)/$2.conf" listen_port
    fi
}

# 总是经 _tui_do 在子 shell 里调用: 管理员在自己的终端上直接查看自己的凭据, 不再逐次警告
_tui_cx_cli() { # KIND ID 参数... -> 导出命令
    local _k _i
    APM_CX_NOWARN=1
    export APM_CX_NOWARN
    _k=$1
    _i=$2
    shift 2
    if [ "$_k" = agw ]; then agw_cli client "$_i" "$@"; else singbox_cli export "$_i" "$@"; fi
}

_tui_cx_endpoint_set() { # KIND ID 主机 端口
    if [ "$1" = agw ]; then agw_cli endpoint "$2" set "$3" "$4"; else singbox_cli endpoint "$2" set "$3" "$4"; fi
}

_tui_cx_sni() { # KIND ID set 名称 | clear
    if [ "$1" = agw ]; then agw_cli endpoint "$2" sni "$3" ${4:+"$4"}; else singbox_cli endpoint "$2" sni "$3" ${4:+"$4"}; fi
}

_tui_need_endpoint() { # ID [KIND]
    local _f _h _p _k
    _k=${2:-sb}
    _f=$(_tui_cx_file "$_k" "$1")
    [ -z "$(kv_get "$_f" public.host 2>/dev/null)" ] || return 0
    _tui_need_root || return 1
    printf '生成客户端配置需要客户端连接的服务器地址，它只用于生成配置，不会修改服务器网络\n'
    tui_ask_server_host || return 1
    _h=$TUI_HOST
    tui_ask "客户端连接端口（留空使用监听端口 $(_tui_cx_lport "$_k" "$1")）："
    _p=${TUI_IN:-$(_tui_cx_lport "$_k" "$1")}
    _tui_do _tui_cx_endpoint_set "$_k" "$1" "$_h" "$_p"
    if [ "$TUI_RC" -ne 0 ]; then _tui_done; return 1; fi
    return 0
}

# 客户端连接地址的修改 (已有地址时才需要, 没有保存过时在第一次查看或导出的那一刻自动询问)
_tui_cx_set_addr() { # KIND ID
    local _h
    _tui_need_root || return 0
    tui_ask_server_host || return 0
    _h=$TUI_HOST
    tui_ask "客户端连接端口（留空使用监听端口 $(_tui_cx_lport "$1" "$2")）："
    _tui_do _tui_cx_endpoint_set "$1" "$2" "$_h" "${TUI_IN:-$(_tui_cx_lport "$1" "$2")}"
    _tui_done
}

_tui_cx_set_sni() { # KIND ID
    _tui_need_root || return 0
    printf 'TLS 服务名只影响客户端导出，不会修改证书、服务端配置，也不会重启服务。\n默认不填写 SNI。跳过证书验证时，客户端发送你指定的域名，不会验证该域名对应网站的身份，也不等于网站伪装。\n'
    tui_ask "客户端 TLS 服务名（域名；留空恢复默认，即不指定）："
    [ "${TUI_EOF:-0}" != 1 ] || return 0
    if [ -n "$TUI_IN" ]; then _tui_do _tui_cx_sni "$1" "$2" set "$TUI_IN"; else _tui_do _tui_cx_sni "$1" "$2" clear; fi
    _tui_done
}

# 不常用的导出: 隐藏凭据的 JSON (展示与调试) 与嵌入证书固定校验的 JSON (可选, 不强制)
_tui_cx_more_menu() { # KIND ID TYPE
    local _items
    while :; do
        _tui_clear
        _tui_header "客户端配置 · 更多导出选项"
        _items="redacted|导出 sing-box JSON（隐藏凭据，用于展示与调试）"
        if _sb_type_tls "$3"; then _items="$_items
pin|导出 sing-box JSON（嵌入证书固定校验，可选）"; fi
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            redacted|pin)
                _tui_need_endpoint "$2" "$1" || continue
                if [ "$TUI_KEY" = redacted ]; then _tui_do _tui_cx_cli "$1" "$2" sing-box --redacted; else _tui_do _tui_cx_cli "$1" "$2" sing-box --embed-cert; fi
                _tui_page
                ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
    done
}

# 客户端配置: 查看与导出一步直达, 没有二次确认, 管理员选择就是授权
#   查看完整连接信息 = 连接信息加完整凭据 导出 JSON 与分享 URL 与二维码都直接输出
tui_export_menu() { # ID [KIND]
    local _f _t _items _ep _k _title
    _k=${2:-sb}
    _f=$(_tui_cx_file "$_k" "$1")
    if [ "$_k" = agw ]; then
        _t=anytls
        _title="客户端配置 · AnyTLS Gateway 线路 $1（端口 $(_tui_cx_lport agw "$1")）"
    else
        _t=$(kv_get "$_f" type)
        _title="客户端配置 · $1"
    fi
    while [ "$_k" = agw ] || [ -f "$_f" ]; do
        if [ "$_k" = agw ] && ! _agw_find_id "$1" >/dev/null 2>&1; then return 0; fi
        _tui_clear
        _tui_header "$_title"
        _ep=$(kv_get "$_f" public.host 2>/dev/null)
        [ -z "$_ep" ] || printf '客户端连接地址：%s:%s\n' "$_ep" "$(kv_get "$_f" public.port)"
        if _sb_type_tls "$_t"; then
            if [ "$_k" = agw ] && _cx_load_agw_creds "$1" >/dev/null 2>&1 && [ "$CX_TLSINS" = no ]; then
                printf '证书校验：由 CA 签发，客户端按证书链校验\n'
            else
                printf '证书校验：跳过（自签名，免维护）\n'
            fi
            if [ -n "$(kv_get "$_f" public.sni 2>/dev/null)" ]; then
                printf '客户端 TLS 服务名：%s（用户指定）\n' "$(kv_get "$_f" public.sni)"
            else
                printf '客户端 TLS 服务名：未指定（默认，不填写 SNI）\n'
            fi
        fi
        printf '\n'
        _items="info|查看完整连接信息
json|导出 sing-box JSON"
        case $_t in
            tuic) printf '说明：TUIC 没有稳定的通用分享 URL，请使用 sing-box JSON\n\n' ;;
            *) _items="$_items
url|导出分享 URL
qr|显示二维码（首次使用会自动安装 qrencode）" ;;
        esac
        _items="$_items
addr|修改客户端连接地址与端口"
        if _sb_type_tls "$_t"; then _items="$_items
sni|修改客户端 TLS 服务名（SNI）"; fi
        _items="$_items
more|更多导出选项"
        tui_choose "$_items" "返回"
        case $TUI_KEY in
            back) return 0 ;;
            more) _tui_cx_more_menu "$_k" "$1" "$_t" ;;
            addr) _tui_cx_set_addr "$_k" "$1" ;;
            sni) _tui_cx_set_sni "$_k" "$1" ;;
            info|json|url|qr)
                _tui_need_endpoint "$1" "$_k" || continue
                case $TUI_KEY in
                    info) _tui_do _tui_cx_cli "$_k" "$1" show --secret ;;
                    json) _tui_do _tui_cx_cli "$_k" "$1" sing-box ;;
                    url) _tui_do _tui_cx_cli "$_k" "$1" url ;;
                    qr) _tui_do _tui_cx_cli "$_k" "$1" qr ;;
                esac
                _tui_page
                ;;
        esac
        [ "${TUI_EOF:-0}" != 1 ] || return 0
        _f=$(_tui_cx_file "$_k" "$1")
    done
}

# ---- 主菜单 ----

tui_main_menu() {
    local _extra _note
    _note=
    while :; do
        _tui_clear_hard
        _tui_header "Alpine Proxy Manager"
        printf '版本：%s\nBuild：%s\n\n' "$(apm_version)" "$(apm_build)"
        printf '%s\n\n' "$(_tui_mem_text)"
        printf 'Core 状态：\n'
        _tui_core_line snell
        _tui_core_line singbox
        _tui_core_line anytlsgw
        _extra=0
        if ! env_is_root; then _tui_warn "当前不是 root，只能查看，写操作不可用"; _extra=$((_extra + 1)); fi
        _tui_rule
        if [ -n "$_note" ]; then printf '%s\n' "$_note"; _note=; _extra=$((_extra + 1)); fi
        # 清屏后提示符固定在第 20 行, 警告与提示各多一行
        _tui_tick_init $((21 + _extra))
        tui_choose "snell|Snell
singbox|sing-box
anytlsgw|AnyTLS Gateway
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
            anytlsgw) tui_anytlsgw_menu ;;
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
    _tui_onekey_init
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
