#!/bin/sh
# shellcheck shell=sh
# 低内存环境保护的常驻进程 (OpenRC 服务 apm-lowmem 通过 /bin/sh 直接运行本文件)
# 独立的最小脚本, 不加载 Manager 的任何模块, 稳态不 fork 外部命令 (全部使用 sh 内建), 常驻内存只有一个很小的 sh
# 两件事
#   内存取证  读 cgroup v2 的 memory.events, oom_kill 计数变化时立即追加一条带内存组成的记录, 另外每隔一段时间写一条心跳
#   SSH 保护  sshd 相关进程的 oom_score_adj 高于目标时降到目标 (只降不升, 容器没有权限降低时配置里 ssh=off, 本进程不会尝试)
# 局限
#   周期采样抓不到毫秒级的峰值, 只能抓到事件之后的第一个采样点
#   不记录连接地址 端口 流量内容 配置与凭据, 进程表只有进程名和 RSS
#   本进程自己也可能被 OOM 杀死, 由 OpenRC 的 supervise-daemon 拉起
# 测试用环境变量  APM_SYSROOT (路径前缀)  APM_LOWMEM_ONCE=1 (只执行一轮并写一条心跳后退出)
set -u

R=${APM_SYSROOT:-}
CONF=$R/etc/alpine-proxy-manager/lowmem.conf
RUN=$R/run/apm-lowmem
LOG=$R/var/log/apm-lowmem.log
LOGMAX=${APM_LOWMEM_LOGMAX:-524288}

SSH=off
SSH_ADJ=-500
FORENSICS=on
INTERVAL=5
HEARTBEAT=300

mkdir -p -- "$RUN" 2>/dev/null

_is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }

load_conf() {
    local _k _v
    SSH=off
    FORENSICS=on
    INTERVAL=5
    HEARTBEAT=300
    [ -r "$CONF" ] || return 0
    while IFS='=' read -r _k _v; do
        case $_k in
            ssh) SSH=$_v ;;
            ssh_adj) case $_v in -[0-9]*) SSH_ADJ=$_v ;; esac ;;
            forensics) FORENSICS=$_v ;;
            interval) _is_uint "$_v" && [ "$_v" -ge 2 ] && [ "$_v" -le 60 ] && INTERVAL=$_v ;;
            heartbeat) _is_uint "$_v" && [ "$_v" -ge 60 ] && [ "$_v" -le 3600 ] && HEARTBEAT=$_v ;;
        esac
    done < "$CONF"
}

# 找到带 memory.events 的 cgroup 目录: 从本进程所在的 cgroup 向上, 第一个有该文件的目录 (子组没有 memory 控制器时回到容器根)
find_cg() {
    local _p _d _l
    CG=
    _p=
    while IFS= read -r _l; do
        case $_l in 0::*) _p=${_l#0::} ;; esac
    done < "$R/proc/self/cgroup" 2>/dev/null
    [ "$_p" = / ] && _p=
    _d=$_p
    while :; do
        if [ -r "$R/sys/fs/cgroup$_d/memory.events" ]; then CG=$R/sys/fs/cgroup$_d; return 0; fi
        [ -n "$_d" ] || break
        _d=${_d%/*}
    done
    return 1
}

# 一行内读取文件第一行, 不 fork
first_line() { # 文件 -> V
    V=
    { IFS= read -r V < "$1"; } 2>/dev/null || :
}

LOGSZ=0
log_line() {
    printf '%s\n' "$1" >> "$LOG" 2>/dev/null || return 0
    LOGSZ=$((LOGSZ + ${#1} + 1))
    if [ "$LOGSZ" -gt "$LOGMAX" ]; then
        # 只保留一个旧文件, 总上限约 1 MiB
        mv -f -- "$LOG" "$LOG.1" 2>/dev/null
        LOGSZ=0
    fi
}

stamp() {
    local _t
    _t=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || _t=-
    first_line "$R/proc/uptime"
    UPT=${V%% *}
    TS="${_t:--} up=${UPT:--}"
}

# memory.events -> EV_OOMKILL 与整行 EV_LINE
read_events() {
    local _k _v
    EV_OOMKILL=
    EV_LINE=
    [ -n "$CG" ] || return 1
    while read -r _k _v; do
        [ -n "$_k" ] || continue
        EV_LINE="$EV_LINE $_k=$_v"
        [ "$_k" != oom_kill ] || EV_OOMKILL=$_v
    done < "$CG/memory.events" 2>/dev/null
    EV_LINE=${EV_LINE# }
    _is_uint "$EV_OOMKILL"
}

# memory.stat 里的几项, 单位字节
read_stat() {
    local _k _v
    ST_LINE=
    ST_SOCK=-
    ST_ANON=-
    [ -n "$CG" ] || return 0
    while read -r _k _v; do
        case $_k in
            anon|file|kernel|kernel_stack|sock|slab|pagetables|shmem)
                ST_LINE="$ST_LINE $_k=$_v"
                [ "$_k" != sock ] || ST_SOCK=$_v
                [ "$_k" != anon ] || ST_ANON=$_v
                ;;
        esac
    done < "$CG/memory.stat" 2>/dev/null
    ST_LINE=${ST_LINE# }
}

# /proc/net/sockstat 的 TCP 行 (只有计数, 没有地址)
read_sockstat() {
    local _l
    SS_TCP=-
    while IFS= read -r _l; do
        case $_l in 'TCP:'*) SS_TCP=${_l#TCP: }; return 0 ;; esac
    done < "$R/proc/net/sockstat" 2>/dev/null
}

# 进程表: 只有进程名和 RSS (kB), 看哪些进程在, 谁最大
proc_table() {
    local _p _n _l _rss _t
    PT=
    for _p in "$R"/proc/[0-9]*; do
        [ -r "$_p/status" ] || continue
        _n=
        _rss=0
        while IFS= read -r _l; do
            case $_l in
                'Name:'*) _n=${_l#Name:}; _n=${_n#"${_n%%[![:space:]]*}"} ;;
                'VmRSS:'*) _t=${_l#VmRSS:}; _rss=${_t%%[!0-9 	]*}; _rss=${_rss#"${_rss%%[![:space:]]*}"}; _rss=${_rss%% *} ;;
            esac
        done < "$_p/status"
        PT="$PT ${_n:-?}=${_rss:-0}"
    done
    PT=${PT# }
}

# 结果放在 SNAP (不用命令替换，避免多一次 fork)
build_snapshot() { # 前缀
    local _cur _max _peak
    first_line "$CG/memory.current"; _cur=${V:--}
    first_line "$CG/memory.max"; _max=${V:--}
    first_line "$CG/memory.peak"; _peak=${V:--}
    read_events
    read_stat
    read_sockstat
    stamp
    SNAP="$1 $TS cur=$_cur max=$_max peak=$_peak events[$EV_LINE] stat[$ST_LINE] tcp[$SS_TCP]"
}

# SSH 保护: 所有 sshd 相关进程的 oom_score_adj 不高于目标
# 登记 PID 与原值在运行目录, 关闭保护时据此恢复 (登记只在本次开机内有效)
ssh_protect() {
    local _p _c _a
    for _p in "$R"/proc/[0-9]*; do
        [ -r "$_p/comm" ] || continue
        IFS= read -r _c < "$_p/comm" 2>/dev/null || continue
        case $_c in sshd|sshd-session|sshd-auth) ;; *) continue ;; esac
        IFS= read -r _a < "$_p/oom_score_adj" 2>/dev/null || continue
        _is_uint "${_a#-}" || continue
        [ "$_a" -gt "$SSH_ADJ" ] || continue
        if printf '%s\n' "$SSH_ADJ" > "$_p/oom_score_adj" 2>/dev/null; then
            printf '%s %s %s\n' "${_p##*/}" "$_a" "$_c" >> "$RUN/ssh.adj"
        fi
    done
}

on_term() {
    [ -z "${FIFO:-}" ] || rm -f -- "$FIFO"
    exit 0
}
trap on_term TERM INT HUP

# 不 fork 的等待: 在一个永远不会有数据的 FIFO 上带超时读取
FIFO=
wait_sec() {
    if [ -n "$FIFO" ]; then
        # shellcheck disable=SC3045
        read -r -t "$1" _x <> "$FIFO" 2>/dev/null
        [ $? -le 128 ] && [ $? -ne 0 ] 2>/dev/null
        return 0
    fi
    sleep "$1"
}

setup_wait() {
    FIFO=$RUN/tick
    rm -f -- "$FIFO"
    if mkfifo -m 600 -- "$FIFO" 2>/dev/null; then
        # 探测 read -t 能否在 FIFO 上超时返回
        # shellcheck disable=SC3045
        ( read -r -t 1 _x <> "$FIFO" ) 2>/dev/null
        [ $? -ge 1 ] || FIFO=
    else
        FIFO=
    fi
}

main() {
    local _last _now _hb_at _since _burst _first
    load_conf
    find_cg || CG=
    if [ -f "$LOG" ]; then
        # shellcheck disable=SC2034
        LOGSZ=$(wc -c < "$LOG" 2>/dev/null)
        _is_uint "$LOGSZ" || LOGSZ=0
    fi
    : > "$RUN/ssh.adj" 2>/dev/null
    setup_wait
    _last=
    if [ "$FORENSICS" = on ] && [ -n "$CG" ] && read_events; then _last=$EV_OOMKILL; fi
    # 测试用: 预设 "上一次" 的计数，模拟启动之后发生了 OOM
    [ -z "${APM_LOWMEM_TEST_LAST:-}" ] || _last=$APM_LOWMEM_TEST_LAST
    if [ "$FORENSICS" = on ]; then
        if [ -n "$CG" ]; then build_snapshot START; log_line "$SNAP"; else log_line "START 无法读取 cgroup v2 的 memory.events, 只记录进程表"; fi
    fi
    _since=0
    _burst=0
    _first=1
    while :; do
        load_conf
        [ "$SSH" != on ] || ssh_protect
        if [ "$FORENSICS" = on ] && [ -n "$CG" ]; then
            if read_events; then
                if [ -n "$_last" ] && [ "$EV_OOMKILL" -gt "$_last" ]; then
                    proc_table
                    build_snapshot OOM
                    log_line "$SNAP 新增_oom_kill=$((EV_OOMKILL - _last))"
                    log_line "PROCS $TS $PT"
                    _burst=15
                fi
                _last=$EV_OOMKILL
            fi
            if [ "$_burst" -gt 0 ]; then
                # 事件之后一小段时间加密采样, 看内存是否在回落
                first_line "$CG/memory.current"
                read_stat
                stamp
                log_line "BURST $TS cur=${V:--} sock=$ST_SOCK anon=$ST_ANON"
                _burst=$((_burst - 1))
            fi
            if [ "$_since" -ge "$HEARTBEAT" ] || [ "${APM_LOWMEM_ONCE:-0}" = 1 ]; then
                first_line "$CG/memory.current"
                read_stat
                stamp
                log_line "BEAT $TS cur=${V:--} sock=$ST_SOCK anon=$ST_ANON oom_kill=${EV_OOMKILL:--}"
                _since=0
            fi
        fi
        [ "${APM_LOWMEM_ONCE:-0}" != 1 ] || break
        if [ "$_burst" -gt 0 ]; then wait_sec 2; _since=$((_since + 2)); else wait_sec "$INTERVAL"; _since=$((_since + INTERVAL)); fi
        _first=0
    done
    [ "$_first" = 0 ] || :
    [ -z "$FIFO" ] || rm -f -- "$FIFO"
}

main
