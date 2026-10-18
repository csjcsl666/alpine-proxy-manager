#!/bin/sh
# shellcheck shell=sh
# sing-box SOCKS5 上游健康监控的常驻进程 (OpenRC 服务 apm-sbhealth 通过 proxy-manager sing-box health run 启动)
# 独立的最小脚本, 不加载 Manager 的任何模块, 常驻内存只有一个很小的 sh
# 工作: 订阅 sing-box 的 Clash API /logs 事件流, 交给 sbhealth.awk 状态机; 流断开时等待并重新订阅 (退避只针对本机 API, 不针对上游)
# 没有事件时整条流水线阻塞在读上, 不产生任何网络活动
set -u

APM_HOME=${APM_HOME:?}
R=${APM_SYSROOT:-}
SBH_RUN=$R/run/apm-sbhealth
SB_CONF=$R/etc/sing-box/config.json
SBH_API_HOST=127.0.0.1
SBH_HIST_DIR=$R/var/lib/sing-box/apm-health
SBH_BACKOFF_MAX=30
mkdir -p -- "$SBH_HIST_DIR" 2>/dev/null

env_path() { printf '%s%s' "$R" "$1"; }


# 守护进程被强制结束 (SIGKILL) 时来不及清理子进程, 下一次启动先回收上一次留下的 状态机 nc 与检查进程 (按命令行核对, 避免误杀 PID 复用的无关进程)
_sbh_reap_stale() {
    local _p _c
    [ -f "$SBH_RUN/children" ] || return 0
    while read -r _p; do
        case $_p in ''|*[!0-9]*) continue ;; esac
        _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null) || continue
        case $_c in *sbhealth.awk*|"nc $SBH_API_HOST "*|sleep*) kill "$_p" 2>/dev/null ;; esac
    done < "$SBH_RUN/children"
    rm -f -- "$SBH_RUN/children"
}

_sbh_stop_children() {
    local _p _i
    # 先停 nc (订阅断开) 与检查进程, 让状态机读到 EOF 后自己执行 END (保留最近一次可靠判断, 仍在 DIRECT 的 selector 复位为 SOCKS5), 最多等 3 秒再强制结束
    _p=${SBH_PIDS#* }
    for _p in $_p; do kill "$_p" 2>/dev/null; done
    _i=0
    while [ "$_i" -lt 15 ] && [ -n "${SBH_PIDS%% *}" ] && kill -0 "${SBH_PIDS%% *}" 2>/dev/null; do sleep 0.2; _i=$((_i + 1)); done
    [ -z "${SBH_PIDS%% *}" ] || kill "${SBH_PIDS%% *}" 2>/dev/null
    SBH_PIDS=
    rm -f -- "$SBH_RUN/connected"
    rm -f -- "$SBH_RUN/children"
    [ -z "${SBH_FIFO:-}" ] || rm -f -- "$SBH_FIFO"
}

# 订阅一次, 订阅断开 (sing-box 停止 重启 密钥错误) 时返回
_sbh_stream() { # 端口 密钥
    local _d _aw _nc _w _x
    _d=$SBH_RUN
    SBH_FIFO=$_d/stream.$$
    rm -f -- "$SBH_FIFO"
    mkfifo -m 600 -- "$SBH_FIFO" || return 1
    # 恢复确认脚本需要的参数经环境变量传递 (密钥不出现在命令行)
    SBH_DIR=$_d SBH_API_PORT=$1 SBH_API_SECRET=$2 SBH_FIFO=$SBH_FIFO SBH_CONFIRM="$APM_HOME/lib/sbhealth-confirm.sh" SBH_FAILOVER="$APM_HOME/lib/sbhealth-failover.sh" SBH_HIST="$SBH_HIST_DIR" awk -f "$APM_HOME/lib/sbhealth.awk" < "$SBH_FIFO" &
    _aw=$!
    printf 'GET /logs?level=debug HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n' "$SBH_API_HOST" "$2" | nc "$SBH_API_HOST" "$1" > "$SBH_FIFO" 2>/dev/null &
    _nc=$!
    # Clash API 在第一个事件之前不会发送响应头 (空闲时流是沉默的), 所以订阅成功不能靠响应头判断: nc 与状态机在连接 1 秒后仍然存活就是订阅在位
    # 这是一次性的检查, 不是周期性的; 密钥错误时服务器会立刻回 401, 状态机会马上退出
    ( sleep 1; kill -0 "$_nc" 2>/dev/null && kill -0 "$_aw" 2>/dev/null && [ ! -f "$_d/connected" ] && date +%s > "$_d/connected" ) &
    _w=$!
    SBH_PIDS="$_aw $_nc $_w"
    for _x in $SBH_PIDS; do printf '%s\n' "$_x"; done > "$SBH_RUN/children"
    wait "$_aw"
    SBH_RC=$?
    _sbh_stop_children
    return 0
}

# 常驻主循环 由 OpenRC 服务调用: proxy-manager sing-box health run
sbh_run() {
    local _d _cfg _port _sec _bo _t0 _t1
    _d=$SBH_RUN
    mkdir -p -- "$_d" 2>/dev/null
    SBH_PIDS=
    SBH_FIFO=
    trap '_sbh_stop_children; rm -f -- "$_d/daemon.pid"; exit 0' TERM INT
    trap '_sbh_stop_children' EXIT
    printf '%s\n' "$$" > "$_d/daemon.pid" || { printf "无法写入 %s\n" "$_d" >&2; exit 1; }
    _sbh_reap_stale
    _bo=1
    while :; do
        _cfg=$SB_CONF
        _port=$(sed -n 's/.*"external_controller": *"127\.0\.0\.1:\([0-9][0-9]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -n 1)
        _sec=$(sed -n 's/.*"secret": *"\([0-9a-f]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -n 1)
        if [ -n "$_port" ] && [ -n "$_sec" ]; then
            _t0=$(date +%s)
            _sbh_stream "$_port" "$_sec"
            _t1=$(date +%s)
            if [ "${SBH_RC:-0}" -eq 3 ]; then
                printf '%s 订阅被拒绝 (密钥不匹配), sing-box 配置需要重新应用\n' "$(date '+%F %T')" >&2
                _bo=$SBH_BACKOFF_MAX
            elif [ $((_t1 - _t0)) -ge 10 ]; then
                printf '%s 事件流已断开 (sing-box 停止或重启), 等待重新订阅\n' "$(date '+%F %T')" >&2
                _bo=1
            fi
        else
            printf '%s sing-box 配置里没有健康监控的 API, 等待配置\n' "$(date '+%F %T')" >&2
            _bo=$SBH_BACKOFF_MAX
        fi
        sleep "$_bo" &
        wait $!
        [ "$_bo" -ge "$SBH_BACKOFF_MAX" ] || _bo=$((_bo * 2))
        [ "$_bo" -le "$SBH_BACKOFF_MAX" ] || _bo=$SBH_BACKOFF_MAX
    done
}


sbh_run
