# shellcheck shell=sh
# shellcheck disable=SC2030,SC2031,SC2163,SC2009
# 主菜单内存显示与空闲刷新: 数据口径 降级 未知 单位换算 刷新不打断输入 不泄漏进程 其他场景不受影响
# 刷新的光标行为用真实终端模拟器 tmux 验证, 没有 tmux 时这部分跳过 (CI 与沙盒里 apk add tmux)
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox manager tui

# ---- 伪造系统根 ----
mkfake() { # 目录 meminfo总KB 可用KB
    mkdir -p "$1/proc/self" "$1/sys/fs/cgroup"
    printf 'MemTotal: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' "$2" "$3" > "$1/proc/meminfo"
    printf '0::/\n' > "$1/proc/self/cgroup"
}
mem() { APM_SYSROOT=$1 _tui_mem_text; }

# cgroup v2: 以 memory.max 与 memory.current 为准, 不用宿主机 meminfo
F1=$T_TMP/f1; mkfake "$F1" 8000000 7000000
printf '134217728\n' > "$F1/sys/fs/cgroup/memory.max"
printf '11534336\n' > "$F1/sys/fs/cgroup/memory.current"
assert_eq "cgroup v2: 内存使用与限制" "内存：11 / 128 MiB" "$(mem "$F1")"
# 单位换算与原始数据一致: 1 MiB = 1048576 字节, 向下取整
printf '%s\n' $((50 * 1048576 + 1048575)) > "$F1/sys/fs/cgroup/memory.current"
assert_eq "单位换算向下取整" "内存：50 / 128 MiB" "$(mem "$F1")"
# 内存变化后再次读取立即反映
printf '%s\n' $((100 * 1048576)) > "$F1/sys/fs/cgroup/memory.current"
assert_eq "变化后更新" "内存：100 / 128 MiB" "$(mem "$F1")"
# 没有 cgroup 上限: 回退 meminfo, 限制是总内存, 当前是 总计 - 可用
F2=$T_TMP/f2; mkfake "$F2" 262144 131072
assert_eq "没有上限回退 meminfo" "内存：128 / 256 MiB" "$(mem "$F2")"
# memory.max 为 max (无上限) 同样回退
printf 'max\n' > "$F2/sys/fs/cgroup/memory.max"
assert_eq "memory.max 为 max 回退 meminfo" "内存：128 / 256 MiB" "$(mem "$F2")"
# cgroup 上限小于 meminfo 时以 cgroup 为准 (LXC 场景)
printf '67108864\n' > "$F2/sys/fs/cgroup/memory.max"
printf '20971520\n' > "$F2/sys/fs/cgroup/memory.current"
assert_eq "容器上限优先" "内存：20 / 64 MiB" "$(mem "$F2")"
# 读不到任何数据: 显示未知, 不编数字
F3=$T_TMP/f3; mkdir -p "$F3"
assert_eq "无法读取显示未知" "内存：未知" "$(mem "$F3")"
F4=$T_TMP/f4; mkfake "$F4" 0 0
assert_eq "总内存为 0 显示未知" "内存：未知" "$(mem "$F4")"
F5=$T_TMP/f5; mkfake "$F5" 262144 131072
printf 'garbage\n' > "$F5/sys/fs/cgroup/memory.max"
printf 'xx\n' > "$F5/sys/fs/cgroup/memory.current"
assert_eq "cgroup 数据损坏回退 meminfo 而不是乱数" "内存：128 / 256 MiB" "$(mem "$F5")"

# 主菜单显示, 且位置固定在版本之后 Core 状态之前 (刷新按这个行号重写)
export APM_TUI_ANSI=0 LC_ALL=en_US.UTF-8
out=$(printf '0\n' | ( APM_SYSROOT=$F1; export APM_SYSROOT; tui_run ) 2>&1)
assert_contains "主菜单显示内存" "$out" "内存：100 / 128 MiB"
assert_eq "内存行是第 7 行 (清屏后)" "内存：100 / 128 MiB" "$(printf '%s\n' "$out" | sed -n '/^====/,$p' | sed -n '7p')"
assert_not_contains "主菜单不显示进程级 RSS" "$out" "RSS"

# 资源页的标签按真实来源区分
res() { APM_SYSROOT=$1 _tui_resources 2>&1; }
assert_contains "cgroup: 标为容器内存" "$(res "$F1")" "容器内存：当前使用 100 MiB，限制 128 MiB（来源 cgroup-v2）"
assert_not_contains "cgroup: 不再误称系统内存" "$(res "$F1")" "系统内存："
assert_contains "无限制: 标为系统内存" "$(res "$F5")" "系统内存："
assert_contains "未知: 如实说明" "$(res "$F3")" "内存：未知"
assert_contains "资源页仍列出 Core 进程指标" "$(res "$F1")" "Snell：没有运行进程"

# ---- 刷新开关与降级 ----
tickinit() { ( export "$@"; _tui_init; _tui_tick_init; printf '%s' "$TUI_TICK_ON" ); }
assert_eq "测试环境默认不刷新 (非终端)" 0 "$(APM_TUI_ANSI=1 tickinit LINES=40)"
assert_eq "APM_TUI_REFRESH=0 关闭" 0 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=40 APM_TUI_REFRESH=0)"
assert_eq "非法间隔关闭" 0 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=40 APM_TUI_REFRESH=abc)"
assert_eq "ANSI 关闭时不刷新" 0 "$(tickinit APM_TUI_ANSI=0 APM_TUI_TEST_TTY=1 LINES=40 APM_TUI_REFRESH=2)"
assert_eq "终端太矮不刷新 (提示符在第 20 行)" 0 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=20 APM_TUI_REFRESH=2)"
assert_eq "刚好差一行不刷新" 0 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=21 APM_TUI_REFRESH=2)"
assert_eq "标准 24 行终端可以刷新" 1 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=24 APM_TUI_REFRESH=2)"
assert_eq "24 行加非 root 警告和重绘提示 (提示符第 22 行) 仍可刷新" 1 "$( ( export APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=24 APM_TUI_REFRESH=2; _tui_init; _tui_tick_init 22; printf '%s' "$TUI_TICK_ON" ) )"
assert_eq "提示符在第 23 行时 24 行终端仍可刷新" 1 "$( ( export APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=24 APM_TUI_REFRESH=2; _tui_init; _tui_tick_init 23; printf '%s' "$TUI_TICK_ON" ) )"
assert_eq "提示符在第 24 行时 24 行终端不刷新 (必须留一行余量)" 0 "$( ( export APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=24 APM_TUI_REFRESH=2; _tui_init; _tui_tick_init 24; printf '%s' "$TUI_TICK_ON" ) )"
assert_eq "行数未知不刷新" 0 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES= APM_TUI_REFRESH=2)"
assert_eq "条件满足时开启" 1 "$(tickinit APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=40 APM_TUI_REFRESH=2)"
assert_eq "间隔最小为 2 秒" 2 "$( ( export APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=40 APM_TUI_REFRESH=1; _tui_init; _tui_tick_init; printf '%s' "$TUI_TICK_SEC" ) )"
assert_eq "默认间隔 5 秒" 5 "$( ( export APM_TUI_ANSI=1 APM_TUI_TEST_TTY=1 LINES=40; unset APM_TUI_REFRESH; _tui_init; _tui_tick_init; printf '%s' "$TUI_TICK_SEC" ) )"
# 刷新关闭时 (管道输入) 与以前完全一致: EOF 干净退出, 多次空输入不会死循环
out=$(printf '' | ( tui_run ) 2>&1)
assert_contains "EOF 干净退出" "$out" "已退出"
# 非交互 CLI 不受影响
out=$("$T_ROOT/bin/proxy-manager" --version </dev/null 2>&1)
assert_contains "CLI 不受影响" "$out" "Alpine Proxy Manager"

# ---- 刷新的生命周期: 只在前台主菜单的输入等待里, 没有任何后台机制 ----
TUIC=$(grep -v '^[[:space:]]*#' "$T_ROOT/lib/tui.sh")
assert_eq "tui.sh 没有后台运行 (行尾 &)" 0 "$(printf '%s\n' "$TUIC" | grep -c '[^&]&[[:space:]]*$')"
assert_eq "tui.sh 没有 nohup setsid disown cron 服务操作" 0 "$(printf '%s\n' "$TUIC" | grep -c -E '\b(nohup|setsid|disown|crontab|rc-update|rc-service|start-stop-daemon|supervise-daemon)\b')"
assert_eq "tui.sh 没有 ALRM 定时信号或 sleep 循环" 0 "$(printf '%s\n' "$TUIC" | grep -c -E 'ALRM|\bsleep\b')"
assert_eq "刷新只在主菜单函数里启动" 1 "$(printf '%s\n' "$TUIC" | grep -c '_tui_tick_init \$')"
# 离开主菜单立即停用: tui_choose 返回后 (分发子菜单之前) 清零
assert_eq "分发子菜单前先停用刷新" 1 "$(awk '/manager\|Manager 管理" "退出"/{f=1} f&&/TUI_TICK_ON=0/{print "y"; exit}' "$T_ROOT/lib/tui.sh" | wc -l | tr -d ' ')"

# ---- 真实终端里的刷新 ----
if ! command -v tmux >/dev/null 2>&1; then
    t_skip "没有 tmux, 终端刷新行为测试跳过 (apk add tmux)"
    t_done
    exit $?
fi
TS=tmuxt$$
TERM=xterm
export TERM
cap() { tmux capture-pane -t "$TS" -p; }
cleanup_tmux() { tmux kill-session -t "$TS" 2>/dev/null; }
pcount() { ps 2>/dev/null | grep -c "[s]h .*proxy-manager tui"; }
# 期望退出后没有进程: 负载高时进程退出可能慢一点, 最多等 10 秒, 仍有进程才算失败
gone() {
    _i=0
    while [ "$_i" -lt 20 ]; do
        [ "$(pcount)" -eq 0 ] && { printf '0'; return 0; }
        sleep 0.5
        _i=$((_i + 1))
    done
    ps 2>/dev/null | grep '[s]h .*proxy-manager tui' >&2
    pcount
}
F6=$T_TMP/f6; mkfake "$F6" 262144 131072
printf '134217728\n' > "$F6/sys/fs/cgroup/memory.max"
setmem() { printf '%s\n' $(($1 * 1048576)) > "$F6/sys/fs/cgroup/memory.current"; }
# 启动: 行数 额外环境
start() { # 行数 [环境...]
    _rows=$1; shift
    setmem 11
    cleanup_tmux
    tmux new-session -d -x 80 -y "$_rows" -s "$TS" "APM_TUI_ANSI=1 APM_SYSROOT=$F6 APM_TUI_REFRESH=2 LC_ALL=en_US.UTF-8 $* sh $T_ROOT/bin/proxy-manager tui"
    sleep 1.5
}
memrow() { cap | sed -n '7p'; }

# --- 标准 24 行终端, root ---
start 24 APM_EUID=0
assert_contains "24 行: 初始内存行" "$(cap)" "内存：11 / 128 MiB"
assert_contains "24 行: 提示符完整在屏幕内" "$(cap)" "请选择："
P0=$(pcount)
# 键入但不回车, 数据变化, 等一个刷新周期: 内存行更新且已键入的字符还在
tmux send-keys -t "$TS" 1
setmem 35
sleep 3.5
c=$(cap)
assert_eq "24 行: 空闲后内存行已刷新且仍在第 7 行" "内存：35 / 128 MiB" "$(memrow)"
assert_contains "24 行: 已键入的字符没有丢" "$c" "请选择：1"
assert_eq "24 行: 只有一个请选择提示" 1 "$(printf '%s\n' "$c" | grep -c '请选择')"
assert_eq "24 行: 菜单没有被重复打印" 1 "$(printf '%s\n' "$c" | grep -c '^1\. Snell')"
# 多个刷新周期后进程数不增长
setmem 36
sleep 4.5
assert_eq "24 行: 多次刷新后进程数不增长" "$P0" "$(pcount)"
assert_eq "24 行: 持续刷新" "内存：36 / 128 MiB" "$(memrow)"
# 有效输入: 之前键入的 1 加回车进入 Snell, 子菜单不被主菜单刷新改写
tmux send-keys -t "$TS" Enter
sleep 0.8
setmem 90
sleep 4.5
c=$(cap)
assert_contains "24 行: 进入了 Snell" "$c" " Snell"
assert_not_contains "24 行: 子菜单没有被写入内存行" "$c" "内存：90"
tmux send-keys -t "$TS" 0 Enter
sleep 3.5
assert_eq "24 行: 返回主菜单后继续刷新" "内存：90 / 128 MiB" "$(memrow)"
# 无效输入: 清屏重绘 加一行提示, 刷新继续, 不丢输入 不错位 不滚屏
tmux send-keys -t "$TS" x Enter
sleep 0.8
c=$(cap)
assert_contains "24 行: 无效输入有提示" "$c" "输入无效，请重新选择。"
assert_eq "24 行: 无效输入后内存行仍在第 7 行" "内存：90 / 128 MiB" "$(memrow)"
assert_eq "24 行: 无效输入后只有一个请选择" 1 "$(printf '%s\n' "$c" | grep -c '请选择')"
assert_contains "24 行: 无效输入后标题仍完整可见" "$c" "Alpine Proxy Manager"
setmem 20
tmux send-keys -t "$TS" 9
sleep 3.5
c=$(cap)
assert_eq "24 行: 无效输入后刷新继续" "内存：20 / 128 MiB" "$(memrow)"
assert_contains "24 行: 无效输入后键入的字符没有丢" "$c" "请选择：9"
# 连续多次无效输入 (含空输入) 不累积行数不错位
tmux send-keys -t "$TS" Enter
tmux send-keys -t "$TS" Enter
tmux send-keys -t "$TS" zz Enter
tmux send-keys -t "$TS" 77 Enter
sleep 0.8
c=$(cap)
assert_eq "24 行: 连续无效输入后提示只出现一次" 1 "$(printf '%s\n' "$c" | grep -c '输入无效')"
assert_eq "24 行: 连续无效输入后只有一个请选择" 1 "$(printf '%s\n' "$c" | grep -c '请选择')"
assert_eq "24 行: 连续无效输入后内存行不动" "内存：20 / 128 MiB" "$(memrow)"
setmem 21
sleep 3.5
assert_eq "24 行: 连续无效输入后仍在刷新" "内存：21 / 128 MiB" "$(memrow)"
assert_eq "24 行: 连续无效输入后进程数不增长" "$P0" "$(pcount)"
# 连续停留较长时间
setmem 22
sleep 6.5
assert_eq "24 行: 长时间停留仍在刷新" "内存：22 / 128 MiB" "$(memrow)"
assert_eq "24 行: 长时间停留进程数不增长" "$P0" "$(pcount)"
# 有效输入后正常退出
tmux send-keys -t "$TS" 0 Enter
sleep 1
assert_eq "24 行: 退出后没有残留进程" 0 "$(gone)"
assert_fail "24 行: 会话已结束" tmux has-session -t "$TS"

# --- 24 行 非 root: 多一行警告, 无效输入后再多一行提示, 仍然放得下 ---
start 24 APM_EUID=1000
assert_contains "非 root 24 行: 有警告" "$(cap)" "当前不是 root"
setmem 30
tmux send-keys -t "$TS" x Enter
sleep 0.8
assert_contains "非 root 24 行: 无效输入提示" "$(cap)" "输入无效，请重新选择。"
assert_contains "非 root 24 行: 提示符完整可见" "$(cap)" "请选择："
setmem 31
sleep 3.5
assert_eq "非 root 24 行: 无效输入后仍刷新" "内存：31 / 128 MiB" "$(memrow)"
tmux send-keys -t "$TS" 0 Enter
sleep 1
cleanup_tmux

# --- Ctrl+C 与 EOF: 刷新活跃时终止, 不留进程 ---
start 24 APM_EUID=0
setmem 12
sleep 2.5
tmux send-keys -t "$TS" C-c
sleep 1
assert_eq "Ctrl+C(主菜单): 没有残留进程" 0 "$(gone)"
assert_fail "Ctrl+C(主菜单): 会话已结束" tmux has-session -t "$TS"
start 24 APM_EUID=0
tmux send-keys -t "$TS" 1 Enter
sleep 1
tmux send-keys -t "$TS" C-c
sleep 1
assert_eq "Ctrl+C(子菜单): 没有残留进程" 0 "$(gone)"
# EOF 在刷新周期的不同相位到达 (间隔 2 秒), 都必须立即退出而不是被当成超时忽略
for d in 0.3 1.1 1.6 1.9 3.2; do
    start 24 APM_EUID=0
    sleep "$d"
    tmux send-keys -t "$TS" C-d
    sleep 1
    assert_eq "EOF 在 ${d} 秒后到达(主菜单): 没有残留进程" 0 "$(gone)"
    assert_fail "EOF 在 ${d} 秒后到达(主菜单): 会话已结束" tmux has-session -t "$TS"
done
cleanup_tmux
# 退出后确认没有任何遗留的 sleep date read 子进程在继续刷新
assert_eq "退出后没有任何 TUI 进程" 0 "$(gone)"

# --- 较小终端 (20 行): 放不下整个主菜单, 静态显示, 菜单仍可正常操作 ---
start 20 APM_EUID=0
setmem 77
sleep 3.5
assert_eq "20 行: 静态显示不刷新" "内存：11 / 128 MiB" "$(memrow)"
tmux send-keys -t "$TS" x Enter
sleep 0.8
assert_contains "20 行: 无效输入仍有提示" "$(cap)" "输入无效"
tmux send-keys -t "$TS" 1 Enter
sleep 0.8
assert_contains "20 行: 菜单仍可正常进入子菜单" "$(cap)" " Snell"
tmux send-keys -t "$TS" 0 Enter
sleep 0.5
tmux send-keys -t "$TS" 0 Enter
sleep 1
assert_eq "20 行: 退出后没有残留进程" 0 "$(gone)"
cleanup_tmux

# --- APM_TUI_REFRESH=0: 静态显示 ---
setmem 11
cleanup_tmux
tmux new-session -d -x 80 -y 30 -s "$TS" "APM_TUI_ANSI=1 APM_SYSROOT=$F6 APM_TUI_REFRESH=0 LC_ALL=en_US.UTF-8 sh $T_ROOT/bin/proxy-manager tui"
sleep 1.5
setmem 55
sleep 3.5
assert_eq "APM_TUI_REFRESH=0: 不刷新" "内存：11 / 128 MiB" "$(memrow)"
tmux send-keys -t "$TS" 0 Enter
sleep 1
cleanup_tmux
t_done
