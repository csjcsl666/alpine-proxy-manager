# shellcheck shell=sh
# sing-box SOCKS5 上游健康监控
#
# 架构: 事件驱动, 没有任何定时探测
#   sing-box 的 Clash API /logs 是一个订阅流 (HTTP 分块): sing-box 每处理一个真实连接就推送日志事件, 订阅者的日志级别独立于 sing-box 自己的日志级别
#   常驻进程 (OpenRC 服务 apm-sbhealth) 用 nc 订阅这个流, 由 lib/sbhealth.awk 的状态机根据真实连接的 拨号 失败 完成 事件更新每个 SOCKS Profile 的状态
#   没有事件时整条流水线阻塞在读上, 不产生任何网络活动, 也绝不连接任何上游 SOCKS 服务器
#   状态文件在 tmpfs 的 /run/apm-sbhealth 里, 只有状态 原因代码 时间戳, 没有目标地址 域名 用户名 密码
#   API 只监听 127.0.0.1 并要求 secret (随机 128 位, 保存在 root 才可读的 sbhealth.conf 与 sing-box 配置里), 不在命令行出现
#   监控只是观察: 不修改 sing-box 的路由 出口绑定 不回退 DIRECT 不重启 sing-box
# 重连退避只针对本机 API (sing-box 停止 重启时), 不针对上游

SBH_SVC=apm-sbhealth
SBH_INIT=/etc/init.d/apm-sbhealth
SBH_RUN=/run/apm-sbhealth
SBH_LOG=/var/log/sing-box/apm-health.log
SBH_API_HOST=127.0.0.1
SBH_SEL_PREFIX=apm-sel-
SBH_HIST_DIR=/var/lib/sing-box/apm-health
SBH_BACKOFF_MAX=30

_sbh_conf() { printf '%s/sbhealth.conf' "$(state_etc)"; }

# 默认启用, 只有显式 disable 才关闭
sbh_enabled() {
    [ ! -f "$(_sbh_conf)" ] && return 0
    [ "$(kv_get "$(_sbh_conf)" enabled)" != false ]
}

# 监控范围有两种互斥的模式 (sbhealth.conf 的 mode): all 全部监控 (默认), custom 自定义监控
# 自定义监控的每台服务器的设置独立保存 (monitor_off 记录被关闭的名称, 空格分隔), 切换模式不会改写它, 在全部监控模式下也完整保留
# enabled 是命令行 enable / disable 的整体开关 (v0.8.0 的含义不变): 整体关闭时不监控任何服务器, 范围设置原样保留
sbh_mode() {
    local _m
    _m=
    [ ! -f "$(_sbh_conf)" ] || _m=$(kv_get "$(_sbh_conf)" mode)
    case $_m in custom) printf 'custom' ;; *) printf 'all' ;; esac
}
_sbh_off_list() { [ -f "$(_sbh_conf)" ] && kv_get "$(_sbh_conf)" monitor_off; return 0; }
# 自动故障切换 (默认关闭, 逐台授权, sbhealth.conf 的 failover_on 记录开启的名称): 故障后新连接临时走 DIRECT, 恢复后自动切回
# 只有 整体开关开启 并且 这台服务器在监控范围内 时才会生效, 否则回到严格的 SOCKS5 (不会静默依据旧的故障状态继续 DIRECT)
_sbh_fo_list() { [ -f "$(_sbh_conf)" ] && kv_get "$(_sbh_conf)" failover_on; return 0; }
sbh_failover_pref() { # NAME, 返回 0 表示已授权
    case " $(_sbh_fo_list) " in *" $1 "*) return 0 ;; esac
    return 1
}
sbh_failover_effective() { # NAME
    sbh_failover_pref "$1" && sbh_enabled && sbh_profile_on "$1"
}

# 这台服务器是否在监控范围内 (只看监控范围, 不看整体开关)
sbh_profile_on() { # NAME, 返回 0 表示在范围内
    [ "$(sbh_mode)" != custom ] && return 0
    case " $(_sbh_off_list) " in *" $1 "*) return 1 ;; esac
    return 0
}
# 自定义监控里这台服务器自己的设置 (和当前模式无关)
sbh_custom_pref_on() { # NAME
    case " $(_sbh_off_list) " in *" $1 "*) return 1 ;; esac
    return 0
}

# 运行配置里是否还有需要监控的 Profile: 全部关闭时不需要 Clash API 也不需要常驻进程
_sbh_any_monitored() { # SOCKS_OUTBOUNDS_TEXT
    local _t
    for _t in $(printf '%s\n' "$1" | sed -n 's/.*"tag": "apm-socks-\([^"]*\)".*/\1/p'); do
        sbh_profile_on "$_t" && return 0
    done
    return 1
}

_sbh_rc() { _snell_run rc-service "$SBH_SVC" "$1"; }

_sbh_rand_hex() { # 字节数
    od -An -N"$1" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# 在 29000 到 29999 里选一个没被占用的回环端口
_sbh_pick_port() {
    local _i _p
    _i=0
    while [ "$_i" -lt 50 ]; do
        _p=$((29000 + $(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ') % 1000))
        _sb_port_busy tcp "$_p" 127.0.0.1 || { printf '%s' "$_p"; return 0; }
        _i=$((_i + 1))
    done
    return 1
}

# 确保 sbhealth.conf 有端口与密钥, 只创建一次, 权限 600
sbh_conf_ensure() {
    local _f _en _p _s _c
    _f=$(_sbh_conf)
    _en=true
    [ ! -f "$_f" ] || _en=$(kv_get "$_f" enabled)
    _p=
    _s=
    if [ -f "$_f" ]; then _p=$(kv_get "$_f" api_port); _s=$(kv_get "$_f" secret); fi
    if [ -n "$_p" ] && [ -n "$_s" ]; then return 0; fi
    state_ensure_dirs || return 1
    [ -n "$_p" ] || _p=$(_sbh_pick_port) || return 1
    [ -n "$_s" ] || _s=$(_sbh_rand_hex 16)
    [ "${#_s}" -eq 32 ] || return 1
    _c=$(txn_new_candidate "$_f") || return 1
    printf 'schema=1\nenabled=%s\napi_port=%s\nsecret=%s\n' "${_en:-true}" "$_p" "$_s" > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# 运行配置里的 experimental 段, 只有健康监控启用 且 配置里确实有 SOCKS 出站 时才输出, 否则为空 (配置与没有这个功能时逐字节相同)
_sbh_experimental() { # SOCKS_OUTBOUNDS_TEXT
    local _p _s
    [ -n "$1" ] || return 0
    sbh_enabled || return 0
    _sbh_any_monitored "$1" || return 0
    [ -f "$(_sbh_conf)" ] || return 0
    _p=$(kv_get "$(_sbh_conf)" api_port)
    _s=$(kv_get "$(_sbh_conf)" secret)
    [ -n "$_p" ] && [ -n "$_s" ] || return 0
    printf ',\n  "experimental": {\n    "clash_api": {\n      "external_controller": "%s:%s",\n      "secret": "%s"\n    }\n  }' "$SBH_API_HOST" "$_p" "$_s"
}

# ---- OpenRC 服务 ----

_sbh_write_init() {
    local _t
    _t=$(env_path "$SBH_INIT")
    mkdir -p -- "$(dirname "$_t")" || return 1
    cat > "$_t" <<'EOF'
#!/sbin/openrc-run
# apm-managed: apm-sbhealth
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager sing-box health 管理, 手工修改可能被覆盖
# sing-box SOCKS5 上游健康监控: 订阅 sing-box 的事件流, 没有事件时不产生任何网络活动

name="apm-sbhealth"
description="sing-box SOCKS5 upstream health monitor (event-driven, managed by Alpine Proxy Manager)"
command="/usr/local/bin/proxy-manager"
command_args="sing-box health run"
command_user="sing-box:sing-box"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=10
respawn_period=60
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/apm-health.log"
error_log="/var/log/sing-box/apm-health.log"

depend() {
    need sing-box
}

start_pre() {
    checkpath -d -m 0755 -o sing-box:sing-box /run/apm-sbhealth
    checkpath -f -m 0640 -o sing-box:sing-box /var/log/sing-box/apm-health.log
    # 监控范围: 运行目录是内存盘, 开机时从配置恢复 (守护进程是 sing-box 用户, 读不了 root 才可读的配置)
    # 全部监控模式没有任何关闭项; 自定义监控模式把被关闭的服务器写进去
    checkpath -d -m 0755 -o sing-box:sing-box /var/lib/sing-box/apm-health
    : > /run/apm-sbhealth/profiles
    _c=/etc/alpine-proxy-manager/sbhealth.conf
    _custom=no
    [ "$(sed -n 's/^mode=//p' $_c 2>/dev/null)" = custom ] && _custom=yes
    _on=yes
    [ "$(sed -n 's/^enabled=//p' $_c 2>/dev/null)" = false ] && _on=no
    _off=
    [ "$_custom" = yes ] && _off=$(sed -n 's/^monitor_off=//p' $_c 2>/dev/null)
    for _n in $_off; do
        printf '%s off 0\n' "$_n" >> /run/apm-sbhealth/profiles
    done
    # 已授权自动故障切换的服务器带 fo 标记 (整体关闭或被排除出监控范围的不带)
    if [ "$_on" = yes ]; then
        for _n in $(sed -n 's/^failover_on=//p' $_c 2>/dev/null); do
            case " $_off " in *" $_n "*) continue ;; esac
            printf '%s on 0 fo\n' "$_n" >> /run/apm-sbhealth/profiles
        done
    fi
    { sed -n 's/^probe_url=//p' $_c 2>/dev/null | head -n 1; sed -n 's/^probe_url2=//p' $_c 2>/dev/null | head -n 1; } > /run/apm-sbhealth/probe_url
    chmod 644 /run/apm-sbhealth/profiles
}
EOF
    chmod 755 -- "$_t"
}

# 让监控服务跟随 sing-box 当前状态: 配置里有 clash_api 且 sing-box 在运行 才需要服务. 监控只是观察, 任何失败都只警告, 不影响主操作
sbh_follow() {
    local _cfg
    env_is_root || return 0
    _cfg=$(env_path "$SB_CONF")
    if sbh_enabled && [ -f "$_cfg" ] && grep -q '"clash_api"' "$_cfg" 2>/dev/null; then
        core_discover singbox
        if [ ! -f "$(env_path "$SBH_INIT")" ] || ! grep -q '^# apm-managed: apm-sbhealth' "$(env_path "$SBH_INIT")" 2>/dev/null; then
            _sbh_write_init || { apm_warn "无法写入健康监控服务脚本"; return 0; }
        fi
        _snell_run rc-update add "$SBH_SVC" default >/dev/null 2>&1 || :
        _sbh_prune
        _sbh_runfile_sync
        if [ "$CF_STATE" = running ]; then
            # 已经在运行就不重启: 重启会让所有服务器的状态回到未知, 范围的变化已经通过运行目录里的 profiles 通知状态机
            _sbh_rc status >/dev/null 2>&1 || _sbh_rc start >/dev/null 2>&1 || apm_warn "健康监控服务没有启动, sing-box 的转发不受影响"
        else
            _sbh_rc stop >/dev/null 2>&1 || :
        fi
    else
        sbh_remove
    fi
    return 0
}

# 停止并移除监控服务与运行时状态, 保留 sbhealth.conf (启用设置与密钥)
sbh_remove() {
    env_is_root || return 0
    if [ -f "$(env_path "$SBH_INIT")" ]; then
        _sbh_rc stop >/dev/null 2>&1 || :
        _snell_run rc-update del "$SBH_SVC" default >/dev/null 2>&1 || :
        rm -f -- "$(env_path "$SBH_INIT")"
    fi
    rm -rf -- "$(env_path "$SBH_RUN")"
}

# 卸载 sing-box 时用: 连同配置一起清除
sbh_purge() {
    local _f
    sbh_remove
    rm -f -- "$(_sbh_conf)" "$(env_path "$SBH_LOG")"
    rm -rf -- "$(env_path "$SBH_HIST_DIR")"
    # 配置的事务备份里也含有密钥, 一并删除
    for _f in "$(state_backup_dir)"/sbhealth.conf.bak.*; do
        [ -e "$_f" ] && rm -f -- "$_f"
    done
    return 0
}

# ---- 常驻进程 ----
# 订阅与状态机的主循环在独立的最小脚本 lib/sbhealth-daemon.sh 里 (不加载 Manager 模块 常驻内存最小), bin/proxy-manager 对 sing-box health run 直接转交给它

# ---- 读取状态 (TUI 与 CLI 共用, 只读) ----

# 监控进程是否在运行并已订阅: 守护进程存活 且 订阅标记存在
sbh_monitor_up() {
    local _d _pid
    _d=$(env_path "$SBH_RUN")
    [ -f "$_d/daemon.pid" ] && [ -f "$_d/connected" ] || return 1
    _pid=$(cat "$_d/daemon.pid" 2>/dev/null)
    [ -n "$_pid" ] && [ -d "$(env_path /proc)/$_pid" ]
}

# sbh_view 名称 -> SBH_V_STATE (healthy degraded unhealthy recovering off down stopped) SBH_V_REASON SBH_V_OK SBH_V_FAIL SBH_V_NOTE
#   SBH_V_EXIT socks|direct (当前出口) SBH_V_FO on|off (自动故障切换是否生效) SBH_V_HFAULT SBH_V_HREC 最近一次故障与恢复 SBH_V_VERIFIED yes|no 是否有过真实连接证据
# 界面语义: 没有发现故障就是 正常, 不因为一段时间没有流量而变成未知; 监控关闭显示 监控已关闭, 监控服务没有运行显示 监控异常
sbh_view() {
    local _f _h
    SBH_V_STATE=healthy; SBH_V_REASON=; SBH_V_OK=0; SBH_V_FAIL=0; SBH_V_NOTE=; SBH_V_EXIT=socks; SBH_V_FO=off; SBH_V_HFAULT=0; SBH_V_HREC=0; SBH_V_VERIFIED=no
    _h=$(env_path "$SBH_HIST_DIR")/$1.hist
    if [ -f "$_h" ]; then
        SBH_V_HFAULT=$(kv_get "$_h" last_fault)
        SBH_V_HREC=$(kv_get "$_h" last_recover)
        SBH_V_HFAULT=${SBH_V_HFAULT:-0}
        SBH_V_HREC=${SBH_V_HREC:-0}
    fi
    sbh_enabled || { SBH_V_STATE=off; SBH_V_NOTE="健康监控已关闭"; return 0; }
    sbh_profile_on "$1" || { SBH_V_STATE=off; SBH_V_NOTE="这台服务器没有开启监控"; return 0; }
    if sbh_failover_effective "$1"; then SBH_V_FO=on; fi
    _f=$(env_path "$SBH_RUN")/${SB_SOCKS_TAG_PREFIX}$1.state
    if [ -f "$_f" ]; then
        SBH_V_STATE=$(kv_get "$_f" state)
        SBH_V_REASON=$(kv_get "$_f" reason)
        SBH_V_OK=$(kv_get "$_f" last_ok)
        SBH_V_FAIL=$(kv_get "$_f" last_fail)
        [ -n "$SBH_V_REASON" ] || SBH_V_REASON=$(kv_get "$_f" last_fail_reason)
        [ "$(kv_get "$_f" exit)" != direct ] || SBH_V_EXIT=direct
        [ "${SBH_V_OK:-0}" = 0 ] || SBH_V_VERIFIED=yes
    fi
    case $SBH_V_STATE in
        healthy|degraded|unhealthy|recovering) ;;
        *) SBH_V_STATE=healthy ;;
    esac
    core_discover singbox
    if [ "$CF_STATE" != running ]; then
        SBH_V_STATE=stopped; SBH_V_NOTE="sing-box 未运行"; SBH_V_EXIT=socks; return 0
    fi
    if ! sbh_monitor_up; then
        SBH_V_STATE=down; SBH_V_NOTE="监控服务没有运行，上游状态无法更新，sing-box 的转发不受影响"; SBH_V_EXIT=socks
        return 0
    fi
    return 0
}

_sbh_reason_text() {
    case $1 in
        auth) printf 'SOCKS5 认证失败' ;;
        refused) printf '上游拒绝连接' ;;
        unreachable) printf '上游网络不可达' ;;
        timeout) printf '连接上游超时' ;;
        dns) printf '上游域名解析失败' ;;
        protocol) printf 'SOCKS5 握手失败' ;;
        *) printf '%s' "$1" ;;
    esac
}

_sbh_hms() { # 纪元秒 -> HH:MM:SS, 0 或空显示 无
    case ${1:-0} in 0|'') printf '无' ;; *) date -d "@$1" '+%H:%M:%S' 2>/dev/null || date -r "$1" '+%H:%M:%S' 2>/dev/null || printf '%s' "$1" ;; esac
}

# 今天 10:25 / 昨天 23:15 / 10-05 08:00, 没有记录显示 无记录
_sbh_when() { # 纪元秒
    local _e _d _t _today _yest
    _e=${1:-0}
    case $_e in 0|'') printf '无记录'; return 0 ;; esac
    _d=$(date -d "@$_e" '+%Y%m%d' 2>/dev/null) || { printf '%s' "$_e"; return 0; }
    _t=$(date -d "@$_e" '+%H:%M' 2>/dev/null)
    _today=$(date '+%Y%m%d')
    _yest=$(date -d "@$(( $(date +%s) - 86400 ))" '+%Y%m%d' 2>/dev/null)
    if [ "$_d" = "$_today" ]; then printf '今天 %s' "$_t"
    elif [ "$_d" = "$_yest" ]; then printf '昨天 %s' "$_t"
    else printf '%s %s' "$(date -d "@$_e" '+%m-%d')" "$_t"; fi
}

# 一行摘要 (实例页 管理中心 出口选择共用)
sbh_summary() { # 名称
    sbh_view "$1"
    case $SBH_V_STATE in
        healthy) printf '● 正常' ;;
        degraded) printf '● 异常（%s）' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        unhealthy)
            printf '● 故障（%s）' "$(_sbh_reason_text "$SBH_V_REASON")"
            [ "$SBH_V_EXIT" != direct ] || printf '，当前出口 DIRECT'
            ;;
        recovering) printf '● 恢复中' ;;
        off) printf '%s' '- 监控已关闭' ;;
        down) printf '%s' '! 监控异常' ;;
        stopped) printf '%s' '○ sing-box 未运行' ;;
        *) printf '● 正常' ;;
    esac
}

# 一个 Profile 的多行显示 (TUI 与 CLI 共用), 不含用户名密码
sbh_print_profile() { # 名称
    sbh_view "$1"
    case $SBH_V_STATE in
        healthy) printf '健康状态：正常\n' ;;
        degraded) printf '健康状态：异常（单次失败）\n原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        unhealthy) printf '健康状态：故障\n原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        recovering) printf '健康状态：恢复中\n原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        off) printf '健康状态：监控已关闭\n' ;;
        down) printf '健康状态：监控异常\n' ;;
        stopped) printf '健康状态：sing-box 未运行\n' ;;
    esac
    [ -z "$SBH_V_NOTE" ] || printf '说明：%s\n' "$SBH_V_NOTE"
    printf '首选出口：SOCKS5\n'
    if [ "$SBH_V_EXIT" = direct ]; then printf '当前出口：DIRECT\n'; else printf '当前出口：SOCKS5\n'; fi
    if sbh_failover_pref "$1"; then
        if [ "$SBH_V_FO" = on ]; then printf '自动故障切换：已开启\n'; else printf '自动故障切换：已开启（现在没有生效：需要整体监控和这台服务器的监控都开启）\n'; fi
    else
        printf '自动故障切换：已关闭\n'
    fi
    printf '最近故障：%s\n' "$(_sbh_when "$SBH_V_HFAULT")"
    printf '最近恢复：%s\n' "$(_sbh_when "$SBH_V_HREC")"
}

# ---- 命令行 ----

sbh_cli() {
    local _sub _n _f _dir _was
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        run) exec sh "$APM_HOME/lib/sbhealth-daemon.sh" ;;
        profile) sbh_profile_cmd "$@" ;;
        mode) sbh_mode_cmd "$@" ;;
        failover) sbh_failover_cmd "$@" ;;
        probe-url) sbh_probe_cmd "$@" ;;
        status)
            if sbh_enabled; then printf '健康监控：启用\n'; else printf '健康监控：已关闭\n'; fi
            if [ "$(sbh_mode)" = custom ]; then printf '监控范围：自定义监控（各服务器按自己的设置）\n'; else printf '监控范围：全部监控\n'; fi
            if sbh_monitor_up; then printf '监控进程：运行中，已订阅 sing-box 事件\n'; else printf '监控进程：未运行或未订阅\n'; fi
            printf '说明：状态来自真实连接事件，没有事件时不做任何主动探测\n'
            _n=0
            for _f in $(state_list_confs "$(state_socks_dir)"); do
                _n=$((_n + 1))
                printf '\n%s\n' "$(basename "$_f" .conf)"
                sbh_print_profile "$(basename "$_f" .conf)"
            done
            [ "$_n" -gt 0 ] || printf '\n没有 SOCKS Profile\n'
            ;;
        enable|disable)
            _snell_need_root || return 4
            _snell_lock || return 4
            trap '_snell_cleanup' EXIT
            _sb_require_managed no || return 4
            if [ "$_sub" = enable ]; then
                sbh_conf_ensure || { apm_err "无法创建 sbhealth.conf"; return 1; }
                _f=$(_sbh_conf)
                [ "$(kv_get "$_f" enabled)" = true ] || sbh_conf_set enabled true || return 1
            else
                [ -f "$(_sbh_conf)" ] || sbh_conf_ensure || return 1
                sbh_conf_set enabled false || return 1
            fi
            _was=$CF_STATE
            _snell_ensure_staging || return 1
            _dir=$(_sb_propose_dir) || return 1
            _sb_apply "$_dir" "$_was" || return 1
            if [ "$_sub" = enable ]; then _sb_say "SOCKS5 上游健康监控已启用"; else _sb_say "SOCKS5 上游健康监控已关闭"; fi
            if [ "$SB_APPLY_RESTARTED" = yes ]; then _sb_say "sing-box 已重启并验证"; else _sb_say "运行配置没有变化，没有重启 sing-box"; fi
            ;;
        *) apm_err "用法: sing-box health [status | enable | disable | mode all|custom | profile 名称 on|off | failover [名称 on|off] | probe-url [1|2 地址]]"; return 2 ;;
    esac
}

# 修改 sbhealth.conf 的一个键
sbh_conf_set() { # 键 值
    local _f _c
    _f=$(_sbh_conf)
    _c=$(txn_new_candidate "$_f") || return 1
    awk -v k="$1" -v v="$2" 'BEGIN { d = 0 } index($0, k "=") == 1 { print k "=" v; d = 1; next } { print } END { if (!d) print k "=" v }' "$_f" > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# 只在有信息价值时输出的补充行: 原因 / 最近失败 / 说明 (用于实例页与出口页, 健康时不输出任何东西)
sbh_detail_lines() { # 名称
    sbh_view "$1"
    case $SBH_V_STATE in
        degraded|unhealthy|recovering) printf '原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
    esac
    [ -z "$SBH_V_NOTE" ] || printf '说明：%s\n' "$SBH_V_NOTE"
    printf '首选出口：SOCKS5\n'
    if [ "$SBH_V_EXIT" = direct ]; then printf '当前出口：DIRECT（故障期间临时直连，恢复后自动切回 SOCKS5）\n'; else printf '当前出口：SOCKS5\n'; fi
    printf '最近故障：%s\n最近恢复：%s\n' "$(_sbh_when "$SBH_V_HFAULT")" "$(_sbh_when "$SBH_V_HREC")"
}

# ---- 每个 Profile 的监控开关 ----

# 按当前的监控范围重写运行目录里的 profiles (名称 on|off 版本号): 状态机处理事件时重读它
# 某台服务器的有效开关变化时版本号 +1, 让状态机丢弃它在内存里的旧状态 (关闭时不再展示旧结果, 重新开启时从未知开始)
_sbh_runfile_sync() {
    local _d _f _t _old _pf _n _s _line _os _or _r
    env_is_root || return 0
    _d=$(env_path "$SBH_RUN")
    mkdir -p -- "$_d" 2>/dev/null || return 0
    _f=$_d/profiles
    _t=$_f.new.$$
    _old=$(cat "$_f" 2>/dev/null)
    : > "$_t"
    for _pf in $(state_list_confs "$(state_socks_dir)"); do
        _n=$(kv_get "$_pf" name)
        if sbh_profile_on "$_n"; then _s=on; else _s=off; fi
        _line=$(printf '%s\n' "$_old" | awk -v n="$_n" '$1 == n { print $2, $3 }')
        if [ -n "$_line" ]; then _os=${_line%% *}; _or=${_line##* }; else _os=on; _or=0; fi
        if [ "$_os" = "$_s" ]; then _r=$_or; else _r=$((_or + 1)); fi
        if sbh_failover_effective "$_n"; then printf '%s %s %s fo\n' "$_n" "$_s" "$_r" >> "$_t"; else printf '%s %s %s\n' "$_n" "$_s" "$_r" >> "$_t"; fi
        [ "$_s" = on ] || rm -f -- "$_d/${SB_SOCKS_TAG_PREFIX}$_n.state"
    done
    chmod 644 -- "$_t"
    mv -f -- "$_t" "$_f"
    { kv_get "$(_sbh_conf)" probe_url; kv_get "$(_sbh_conf)" probe_url2; } > "$_d/probe_url" 2>/dev/null
    chmod 644 -- "$_d/probe_url" 2>/dev/null
}

# 清理: 不存在的 Profile 不再占用 monitor_off 与状态文件, 被关闭的 Profile 的状态文件也删除
_sbh_prune() {
    local _n _l _keep _f
    _keep=
    for _n in $(_sbh_off_list); do
        [ -f "$(state_socks_dir)/$_n.conf" ] && _keep="$_keep $_n"
    done
    _keep=${_keep# }
    [ "$_keep" = "$(_sbh_off_list)" ] || sbh_conf_set monitor_off "$_keep" >/dev/null 2>&1 || :
    _keep=
    for _n in $(_sbh_fo_list); do
        [ -f "$(state_socks_dir)/$_n.conf" ] && _keep="$_keep $_n"
    done
    _keep=${_keep# }
    [ "$_keep" = "$(_sbh_fo_list)" ] || sbh_conf_set failover_on "$_keep" >/dev/null 2>&1 || :
    # 已删除的服务器不留下最近故障与恢复时间
    for _f in "$(env_path "$SBH_HIST_DIR")"/*.hist; do
        [ -e "$_f" ] || continue
        _n=${_f##*/}
        _n=${_n%.hist}
        [ -f "$(state_socks_dir)/$_n.conf" ] || rm -f -- "$_f"
    done
    for _f in "$(env_path "$SBH_RUN")"/apm-socks-*.state; do
        [ -e "$_f" ] || continue
        _n=${_f##*/apm-socks-}
        _n=${_n%.state}
        if [ ! -f "$(state_socks_dir)/$_n.conf" ] || ! sbh_profile_on "$_n"; then rm -f -- "$_f"; fi
    done
    # profiles 文件与 monitor_off 对齐 (不存在的 Profile 的行被丢弃)
    if [ -f "$(env_path "$SBH_RUN")/profiles" ]; then
        awk -v d="$(state_socks_dir)" '{ f = d "/" $1 ".conf"; if ((getline x < f) >= 0) { close(f); print } else { close(f) } }' "$(env_path "$SBH_RUN")/profiles" > "$(env_path "$SBH_RUN")/profiles.new.$$" 2>/dev/null && chmod 644 "$(env_path "$SBH_RUN")/profiles.new.$$" && mv -f "$(env_path "$SBH_RUN")/profiles.new.$$" "$(env_path "$SBH_RUN")/profiles"
        rm -f -- "$(env_path "$SBH_RUN")/profiles.new.$$"
    fi
    return 0
}

# 应用一次配置变更并让监控服务跟随 (范围的变化可能让运行配置里的 Clash API 段出现或消失)
_sbh_reapply() {
    local _was _dir
    core_discover singbox
    _was=$CF_STATE
    _snell_ensure_staging || return 1
    _dir=$(_sb_propose_dir) || return 1
    _sb_apply "$_dir" "$_was" || return 1
    if [ "$SB_APPLY_RESTARTED" = yes ]; then _sb_say "sing-box 已重启并验证"; else _sb_say "运行配置没有变化，没有重启 sing-box"; fi
}

# 修改监控范围相关的设置 (模式 或 自定义监控里单台服务器的设置), 校验或应用失败就完整恢复原设置
# 参数: 键 新值 [键 新值]...
_sbh_scope_commit() {
    local _old_mode _old_off _old_fo _k
    _old_mode=$(kv_get "$(_sbh_conf)" mode)
    _old_off=$(kv_get "$(_sbh_conf)" monitor_off)
    _old_fo=$(kv_get "$(_sbh_conf)" failover_on)
    while [ $# -ge 2 ]; do
        sbh_conf_set "$1" "$2" || { apm_err "保存监控设置失败"; return 1; }
        shift 2
    done
    _sbh_runfile_sync
    if ! _sbh_reapply; then
        sbh_conf_set mode "${_old_mode:-all}" >/dev/null 2>&1
        sbh_conf_set monitor_off "$_old_off" >/dev/null 2>&1
        sbh_conf_set failover_on "$_old_fo" >/dev/null 2>&1
        _sbh_runfile_sync
        apm_err "监控设置没有改变"
        return 1
    fi
}

# health mode all|custom: 切换监控范围, 只改模式, 不改写自定义监控里各服务器的设置, 不改 Profile 的启用状态与出口绑定
sbh_mode_cmd() { # all|custom
    local _m
    _m=${1:-}
    { [ $# -eq 1 ] && { [ "$_m" = all ] || [ "$_m" = custom ]; }; } || { apm_err "用法: sing-box health mode all|custom"; return 2; }
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    sbh_conf_ensure || { apm_err "无法创建 sbhealth.conf"; return 1; }
    if [ "$(sbh_mode)" = "$_m" ]; then
        _sb_say "监控范围已经是$([ "$_m" = all ] && echo 全部监控 || echo 自定义监控)，没有改动"
        return 0
    fi
    _sbh_scope_commit mode "$_m" || return 1
    if [ "$_m" = all ]; then
        _sb_say "已切换为全部监控，所有 SOCKS5 服务器都参与健康监控，自定义监控里的设置已保留"
    else
        _sb_say "已切换为自定义监控，按各服务器自己的设置监控"
    fi
    sbh_enabled || _sb_say "注意：健康监控被整体关闭（health disable），重新执行 health enable 后才会生效"
}

# health profile 名称 on|off: 自定义监控里单台服务器的开关. 全部监控模式下不允许悄悄修改, 先用 health mode custom
sbh_profile_cmd() { # NAME on|off
    local _n _a _list _x
    _n=${1:-}
    _a=${2:-}
    { [ $# -eq 2 ] && is_ident "$_n"; } || { apm_err "用法: sing-box health profile 名称 on|off"; return 2; }
    case $_a in on|off) ;; *) apm_err "用法: sing-box health profile 名称 on|off"; return 2 ;; esac
    [ -f "$(state_socks_dir)/$_n.conf" ] || { apm_err "SOCKS Profile $_n 不存在"; return 1; }
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    sbh_conf_ensure || { apm_err "无法创建 sbhealth.conf"; return 1; }
    if [ "$(sbh_mode)" != custom ]; then
        apm_err "当前是全部监控模式，所有服务器都在监控，不能单独修改 $_n，请先执行 sing-box health mode custom 切换到自定义监控"
        return 2
    fi
    _list=
    for _x in $(_sbh_off_list); do
        [ "$_x" = "$_n" ] || _list="$_list $_x"
    done
    _list=${_list# }
    if [ "$_a" = off ]; then _list=${_list:+$_list }$_n; fi
    if [ "$_list" = "$(_sbh_off_list)" ]; then
        _sb_say "$_n 的监控已经是$([ "$_a" = on ] && echo 开启 || echo 关闭)，没有改动"
        return 0
    fi
    _sbh_scope_commit monitor_off "$_list" || return 1
    if [ "$_a" = on ]; then _sb_say "已开启 $_n 的健康监控，从「未知」开始等待真实连接"; else _sb_say "已关闭 $_n 的健康监控，不影响它的转发"; fi
    sbh_enabled || _sb_say "注意：健康监控被整体关闭（health disable），重新执行 health enable 后才会生效"
}

# health failover [名称 on|off]: 自动故障切换 (默认关闭, 逐台授权). 开启后这台服务器故障时新连接临时走 VPS 自己的 IP (DIRECT), 恢复后自动切回
# 关闭会立即取消授权并恢复严格的 SOCKS5 (重新生成运行配置, 即使上游仍然故障也不再 DIRECT)
sbh_failover_cmd() { # [NAME on|off]
    local _n _a _list _x _p
    if [ $# -eq 0 ]; then
        for _p in $(state_list_confs "$(state_socks_dir)"); do
            _n=$(kv_get "$_p" name)
            if sbh_failover_pref "$_n"; then printf '%s  已开启\n' "$_n"; else printf '%s  已关闭\n' "$_n"; fi
        done
        return 0
    fi
    _n=${1:-}
    _a=${2:-}
    { [ $# -eq 2 ] && is_ident "$_n"; } || { apm_err "用法: sing-box health failover [名称 on|off]"; return 2; }
    case $_a in on|off) ;; *) apm_err "用法: sing-box health failover [名称 on|off]"; return 2 ;; esac
    [ -f "$(state_socks_dir)/$_n.conf" ] || { apm_err "SOCKS Profile $_n 不存在"; return 1; }
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    sbh_conf_ensure || { apm_err "无法创建 sbhealth.conf"; return 1; }
    _list=
    for _x in $(_sbh_fo_list); do
        [ "$_x" = "$_n" ] || _list="$_list $_x"
    done
    _list=${_list# }
    if [ "$_a" = on ]; then _list=${_list:+$_list }$_n; fi
    if [ "$_list" = "$(_sbh_fo_list)" ]; then
        _sb_say "$_n 的自动故障切换已经是$([ "$_a" = on ] && echo 开启 || echo 关闭)，没有改动"
        return 0
    fi
    _sbh_scope_commit failover_on "$_list" || return 1
    if [ "$_a" = on ]; then
        _sb_say "已开启 $_n 的自动故障切换：它的上游确认故障后，新连接会临时通过 VPS 自己的 IP 直连（DIRECT），上游恢复后自动切回 SOCKS5"
        sbh_failover_effective "$_n" || _sb_say "注意：现在没有生效，需要整体健康监控和这台服务器的健康监控都开启"
    else
        _sb_say "已关闭 $_n 的自动故障切换，恢复严格的 SOCKS5 策略：上游故障时连接失败，不会 DIRECT"
    fi
}

# 恢复验证地址 (自动故障切换用): 两个相互独立的 https 地址, 任意一个经该 SOCKS5 出站请求成功就算恢复验证通过
# probe-url 显示; probe-url 1|2 地址 设置; probe-url 1|2 default 恢复默认. 只影响恢复验证, 不需要重启 sing-box
SBH_PROBE_DEFAULT_1=https://cp.cloudflare.com/generate_204
SBH_PROBE_DEFAULT_2=https://www.gstatic.com/generate_204
sbh_probe_url_get() { # 1|2
    local _v
    if [ "$1" = 1 ]; then _v=$(kv_get "$(_sbh_conf)" probe_url); _v=${_v:-$SBH_PROBE_DEFAULT_1}
    else _v=$(kv_get "$(_sbh_conf)" probe_url2); _v=${_v:-$SBH_PROBE_DEFAULT_2}; fi
    printf '%s' "$_v"
}
sbh_probe_cmd() { # [1|2 URL|default]
    local _k _v
    if [ $# -eq 0 ]; then
        printf '恢复验证地址 1：%s\n恢复验证地址 2：%s\n' "$(sbh_probe_url_get 1)" "$(sbh_probe_url_get 2)"
        return 0
    fi
    { [ $# -eq 2 ] && { [ "$1" = 1 ] || [ "$1" = 2 ]; }; } || { apm_err "用法: sing-box health probe-url [1|2 https地址|default]"; return 2; }
    _v=$2
    if [ "$_v" = default ]; then _v=; else
        case $_v in
            https://*) ;;
            *) apm_err "恢复验证地址必须以 https:// 开头（sing-box 的测试接口只接受 https）"; return 2 ;;
        esac
        case $_v in *[!A-Za-z0-9._~:/?\&=%@+,-]*) apm_err "恢复验证地址包含不支持的字符"; return 2 ;; esac
        [ ${#_v} -le 200 ] || { apm_err "恢复验证地址太长"; return 2; }
    fi
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    sbh_conf_ensure || { apm_err "无法创建 sbhealth.conf"; return 1; }
    if [ "$1" = 1 ]; then _k=probe_url; else _k=probe_url2; fi
    sbh_conf_set "$_k" "$_v" >/dev/null 2>&1 || { apm_err "无法写入 sbhealth.conf"; return 1; }
    [ ! -d "$(env_path "$SBH_RUN")" ] || _sbh_runfile_sync
    _sb_say "恢复验证地址 $1 已设置为 $(sbh_probe_url_get "$1")，下一次恢复验证起生效"
}
