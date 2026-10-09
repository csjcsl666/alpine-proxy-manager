#!/bin/sh
# Snell 网络功能的运行时包装脚本, 由 OpenRC 的 supervise-daemon 以 root 运行
# 只依赖 POSIX sh 与 BusyBox, 不加载 Manager 的库, 常驻时只占一个很小的 sh
#
# 进程树
#   supervise-daemon
#     本脚本 (root)
#       tinyproxy              仅目标访问限制, 内部网关
#       graftcp (root, 追踪者)  追踪下面的整棵进程树, 退出时内核杀掉被追踪者 (PTRACE_O_EXITKILL)
#         run.sh
#           unbound            仅 SOCKS5 出口, Snell 专用的解析器
#           snell-server (snell 用户)
#
# 任何一个组件退出, 整套都被拆除并以失败状态退出, 由 supervise-daemon 决定是否重启
# 没有任何一种情况会回到直连: 被追踪的 Snell 只在 graftcp 存活时存在

set -u

RUN=${APM_SNN_RUN:-/run/apm-snell}
[ -r "$RUN/runner.env" ] || { echo "snellnet-run: 缺少 $RUN/runner.env" >&2; exit 1; }
# shellcheck source=/dev/null
. "$RUN/runner.env"

GC_PID=
TP_PID=

say() { echo "snellnet-run: $*" >&2; }

alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

# 命令行里有一个参数恰好等于 STR 的进程 PID, 取第一个
pid_with_arg() { # STR
    local _d _p
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ "$_p" = "$$" ] && continue
        tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | grep -Fxq -- "$1" && { echo "$_p"; return 0; }
    done
    return 1
}

# 记录的 PID 是否仍是我们的进程 (命令行里有预期的参数), 防止 PID 被复用后误杀
owned() { # PID ARG
    alive "$1" && tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -Fxq -- "$2"
}

term() { # PID ARG
    owned "$1" "$2" || return 0
    kill "$1" 2>/dev/null
    local _n=0
    while [ "$_n" -lt 30 ] && owned "$1" "$2"; do sleep 0.1; _n=$((_n + 1)); done
    owned "$1" "$2" && kill -9 "$1" 2>/dev/null
    return 0
}

# 上一次异常结束 (例如本脚本被 kill -9) 留下的进程, 只处理记录过且命令行仍然吻合的
cleanup_stale() {
    local _f _p
    for _f in snell:$RUN/snell.conf helper:$RUN/unbound.conf gateway:$RUN/tinyproxy.conf graftcp:$RUN/graftcp.conf; do
        _p=$(head -n 1 "$RUN/${_f%%:*}.pid" 2>/dev/null | tr -d ' \r\n')
        [ -n "$_p" ] && term "$_p" "${_f#*:}"
    done
}

teardown() {
    local _p
    # 先停追踪者: 内核随之杀掉整棵被追踪的进程树
    [ -z "$GC_PID" ] || term "$GC_PID" "$RUN/graftcp.conf"
    # 兜底: 仍存在的 Snell 与解析器
    for _f in snell:$RUN/snell.conf helper:$RUN/unbound.conf; do
        _p=$(head -n 1 "$RUN/${_f%%:*}.pid" 2>/dev/null | tr -d ' \r\n')
        [ -n "$_p" ] && term "$_p" "${_f#*:}"
    done
    [ -z "$TP_PID" ] || term "$TP_PID" "$RUN/tinyproxy.conf"
    rm -f "$RUN"/*.pid
}

# shellcheck disable=SC2329,SC2317 # 由 trap 调用
on_signal() { teardown; exit 0; }
trap on_signal TERM INT HUP

listening_tcp() { # 端口 (十进制), 127.0.0.1
    grep -qi "^ *[0-9]*: 0100007F:$(printf '%04X' "$1") " /proc/net/tcp 2>/dev/null
}

cleanup_stale

if [ "$MODE" = access ]; then
    tinyproxy -d -c "$RUN/tinyproxy.conf" &
    TP_PID=$!
    echo "$TP_PID" > "$RUN/gateway.pid"
    n=0
    while [ "$n" -lt 100 ] && ! listening_tcp "$GW_PORT"; do
        alive "$TP_PID" || { say "内部网关启动失败"; exit 1; }
        n=$((n + 1)); sleep 0.1
    done
    [ "$n" -lt 100 ] || { say "内部网关没有在预期时间内监听"; teardown; exit 1; }
fi

if [ "$MODE" = egress ]; then
    GRAFTCP_DIRECT_ENDPOINTS="tcp:$DNS:53,udp:$DNS:53" GRAFTCP_LOOPBACK_UDP_COMM=unbound \
        "$GC" --config "$RUN/graftcp.conf" /bin/sh "$RUN/run.sh" &
else
    "$GC" --config "$RUN/graftcp.conf" /bin/sh "$RUN/run.sh" &
fi
GC_PID=$!
echo "$GC_PID" > "$RUN/graftcp.pid"

# 等 Snell 出现; 出现后记录其 PID
SN_PID=
n=0
while [ "$n" -lt 150 ]; do
    alive "$GC_PID" || { say "graftcp 提前退出"; teardown; exit 1; }
    SN_PID=$(pid_with_arg "$RUN/snell.conf") && break
    SN_PID=
    n=$((n + 1)); sleep 0.1
done
[ -n "$SN_PID" ] || { say "Snell 没有启动"; teardown; exit 1; }
echo "$SN_PID" > "$RUN/snell.pid"
if [ "$MODE" = egress ]; then
    HP=$(pid_with_arg "$RUN/unbound.conf") || { say "解析器没有运行"; teardown; exit 1; }
    echo "$HP" > "$RUN/helper.pid"
fi

# 监视: 任何一个必需组件消失就拆除整套
while :; do
    sleep 1 &
    wait $! 2>/dev/null
    alive "$GC_PID" || { say "graftcp 已退出"; break; }
    owned "$SN_PID" "$RUN/snell.conf" || { say "Snell 已退出"; break; }
    [ "$MODE" != egress ] || owned "$HP" "$RUN/unbound.conf" || { say "解析器已退出"; break; }
    [ "$MODE" != access ] || owned "$TP_PID" "$RUN/tinyproxy.conf" || { say "内部网关已退出"; break; }
done
teardown
exit 1
