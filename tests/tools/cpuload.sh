#!/bin/sh
# 受限的 CPU 负载: 在负载下运行一条命令, 用来验证时间敏感的测试 (真实终端按键 超时 竞态)
# 用法  cpuload.sh [--workers N] [--seconds S] -- 命令 参数...
#
# 为什么要有这个脚本: 临时手写的 while :; do :; done 没有退出条件 也没有受控的清理, 一旦清理那一步出错 (例如在 zsh 里 kill $PIDS
# 不会按空格拆分, kill 报 illegal pid 被 2>/dev/null 吞掉) 空转进程就一直留在开发电脑上
#
# 约束 (写死, 不能用参数放开)
#   进程数  最多 2 个, 并且不超过逻辑 CPU 数的四分之一 (至少 1 个); 开发电脑上永远留出大部分 CPU
#   持续时间  默认 120 秒, 最多 600 秒; 每个空转进程自己也由 timeout 限时, 即使本脚本被 kill -9 也会在时限内自行结束
#   优先级  nice 19, 不抢交互与桌面
#   清理  命令正常结束 失败 超时 或本脚本收到 INT TERM HUP 都只回收自己启动的空转进程 (按 PID 加启动时间确认), 不按名字匹配
#   结束前确认没有残留, 仍有存活就返回失败并报告
# APM_CPULOAD_IDLE=1  空转进程改为 sleep, 不消耗 CPU, 只用于测试本脚本的清理逻辑
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/reap.sh
. "$here/../reap.sh"

W=1
S=120
while [ $# -gt 0 ]; do
    case $1 in
        --workers) W=$2; shift 2 ;;
        --seconds) S=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "cpuload: 未知参数 $1" >&2; exit 2 ;;
    esac
done
[ $# -gt 0 ] || { echo "cpuload: 需要在 -- 之后给出要运行的命令" >&2; exit 2; }
case $W in ''|*[!0-9]*) echo "cpuload: --workers 必须是数字" >&2; exit 2 ;; esac
case $S in ''|*[!0-9]*) echo "cpuload: --seconds 必须是数字" >&2; exit 2 ;; esac
CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ "${CPUS:-0}" -ge 1 ] || CPUS=1
CAP=$((CPUS / 4))
[ "$CAP" -ge 1 ] || CAP=1
[ "$CAP" -le 2 ] || CAP=2
[ "$W" -ge 1 ] || W=1
if [ "$W" -gt "$CAP" ]; then echo "cpuload: 进程数 $W 超过上限 $CAP, 已降到 $CAP" >&2; W=$CAP; fi
[ "$S" -ge 1 ] || S=1
if [ "$S" -gt 600 ]; then echo "cpuload: 持续时间 $S 秒超过上限 600, 已降到 600" >&2; S=600; fi

T_REG=$(mktemp -d)
PIDS=
cleanup() {
    local _n
    _n=$(t_reap_dir "$T_REG")
    rm -rf "$T_REG"
    CLEANED=${_n:-0}
}
trap 'cleanup; exit 130' INT TERM HUP
trap 'cleanup' EXIT

i=0
while [ "$i" -lt "$W" ]; do
    if [ "${APM_CPULOAD_IDLE:-0}" = 1 ]; then
        nice -n 19 timeout "$S" sleep "$S" &
    else
        nice -n 19 timeout "$S" sh -c 'while :; do :; done' &
    fi
    t_own_pid "$!"
    PIDS="$PIDS $!"
    i=$((i + 1))
done
# shellcheck disable=SC2086
printf 'cpuload: %s 个进程 最长 %s 秒 (PID:%s)\n' "$W" "$S" "$PIDS" >&2

"$@"
rc=$?

# 先收尾再确认
cleanup
trap - EXIT
left=0
for p in $PIDS; do
    [ -d "/proc/$p" ] && [ "$(tr -d '\0' < "/proc/$p/comm" 2>/dev/null)" != "" ] && [ -z "$(sed -n 's/^State:[[:space:]]*Z.*/z/p' "/proc/$p/status" 2>/dev/null)" ] && left=$((left + 1))
done
if [ "$left" -gt 0 ]; then echo "cpuload: 仍有 $left 个负载进程没有退出" >&2; [ "$rc" -ne 0 ] || rc=70; fi
exit "$rc"
