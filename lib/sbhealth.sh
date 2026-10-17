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
# 健康状态超过这个秒数没有新的连接证据就按 未知 显示 (只影响显示, 不产生任何探测)
SBH_STALE_SECS=900
SBH_BACKOFF_MAX=30

_sbh_conf() { printf '%s/sbhealth.conf' "$(state_etc)"; }

# 默认启用, 只有显式 disable 才关闭
sbh_enabled() {
    [ ! -f "$(_sbh_conf)" ] && return 0
    [ "$(kv_get "$(_sbh_conf)" enabled)" != false ]
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
        if [ "$CF_STATE" = running ]; then
            _sbh_rc restart >/dev/null 2>&1 || apm_warn "健康监控服务没有启动, sing-box 的转发不受影响"
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

# sbh_view 名称 -> SBH_V_STATE (healthy degraded unhealthy recovering unknown off) SBH_V_REASON SBH_V_OK SBH_V_FAIL SBH_V_NOTE
sbh_view() {
    local _f _now _ok _fail
    SBH_V_STATE=unknown; SBH_V_REASON=; SBH_V_OK=0; SBH_V_FAIL=0; SBH_V_NOTE=
    sbh_enabled || { SBH_V_STATE=off; SBH_V_NOTE="健康监控已关闭"; return 0; }
    _f=$(env_path "$SBH_RUN")/${SB_SOCKS_TAG_PREFIX}$1.state
    if [ -f "$_f" ]; then
        SBH_V_STATE=$(kv_get "$_f" state)
        SBH_V_REASON=$(kv_get "$_f" reason)
        SBH_V_OK=$(kv_get "$_f" last_ok)
        SBH_V_FAIL=$(kv_get "$_f" last_fail)
        [ -n "$SBH_V_REASON" ] || SBH_V_REASON=$(kv_get "$_f" last_fail_reason)
    fi
    case $SBH_V_STATE in healthy|degraded|unhealthy|recovering|unknown) ;; *) SBH_V_STATE=unknown ;; esac
    core_discover singbox
    if [ "$CF_STATE" != running ]; then
        SBH_V_STATE=unknown; SBH_V_NOTE="sing-box 未运行"; return 0
    fi
    if ! sbh_monitor_up; then
        SBH_V_STATE=unknown; SBH_V_NOTE="监控未运行"; return 0
    fi
    _now=$(date +%s)
    _ok=${SBH_V_OK:-0}
    case $SBH_V_STATE in
        healthy)
            if [ $((_now - _ok)) -gt "$SBH_STALE_SECS" ]; then
                SBH_V_STATE=unknown; SBH_V_NOTE="最近成功已超过 $((SBH_STALE_SECS / 60)) 分钟，之后没有新连接可以证明"
            fi
            ;;
        unknown) SBH_V_NOTE="尚无真实连接证据" ;;
    esac
    _fail=${SBH_V_FAIL:-0}
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

# 一个 Profile 的多行显示 (TUI 与 CLI 共用), 不含用户名密码
sbh_print_profile() { # 名称
    sbh_view "$1"
    case $SBH_V_STATE in
        healthy) printf '状态：● 健康\n' ;;
        degraded) printf '状态：● 异常（单次失败）\n'; printf '原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        unhealthy) printf '状态：● 不可用\n'; printf '原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        recovering) printf '状态：● 恢复中（等待真实连接确认）\n'; printf '原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        off) printf '状态：- 健康监控已关闭\n' ;;
        *) printf '状态：○ 未知\n' ;;
    esac
    [ -z "$SBH_V_NOTE" ] || printf '说明：%s\n' "$SBH_V_NOTE"
    printf '最近成功：%s\n' "$(_sbh_hms "$SBH_V_OK")"
    if [ "${SBH_V_FAIL:-0}" = 0 ]; then printf '最近失败：无\n'; else printf '最近失败：%s\n' "$(_sbh_hms "$SBH_V_FAIL")"; fi
}

# 一行摘要, 用于实例出口绑定显示
sbh_summary() { # 名称
    sbh_view "$1"
    case $SBH_V_STATE in
        healthy) printf '● 健康' ;;
        degraded) printf '● 异常（%s）' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        unhealthy) printf '● 不可用（%s）' "$(_sbh_reason_text "$SBH_V_REASON")" ;;
        recovering) printf '● 恢复中' ;;
        off) printf '%s' '- 已关闭' ;;
        *) printf '○ 未知' ;;
    esac
}

# ---- 命令行 ----

sbh_cli() {
    local _sub _n _f _dir _was
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        run) exec sh "$APM_HOME/lib/sbhealth-daemon.sh" ;;
        status)
            if sbh_enabled; then printf '健康监控：启用\n'; else printf '健康监控：已关闭\n'; fi
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
        *) apm_err "用法: sing-box health [status | enable | disable]"; return 2 ;;
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
        degraded|unhealthy|recovering)
            printf '原因：%s\n' "$(_sbh_reason_text "$SBH_V_REASON")"
            [ "${SBH_V_FAIL:-0}" = 0 ] || printf '最近失败：%s\n' "$(_sbh_hms "$SBH_V_FAIL")"
            ;;
    esac
    [ -z "$SBH_V_NOTE" ] || printf '说明：%s\n' "$SBH_V_NOTE"
}
