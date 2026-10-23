# shellcheck shell=sh
# 网络与进程保护（低内存环境）的 TUI: 首页 详情 取证 启用 高级选项 恢复 全部页面与操作路径
# 内存配额只是样本 (64 128 256 300 MiB 等), 策略对任意配额连续判断, 这里用若干非整档数值证明没有查表
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth manager lowmem tui
PM="$T_ROOT/bin/proxy-manager"
DAEMON="$T_ROOT/lib/lowmem-daemon.sh"

MIB=1048576
HYT_R="4096	1048576	128516096"
HYT_W="4096	1048576	128516096"
KD_R="4096	131072	6291456"
KD_W="4096	16384	4194304"

# mk_lm DIR 上限字节 rmem wmem [own|host]: 最小的低内存系统
mk_lm() {
    local _d
    _d=$1
    mk_sysroot "$_d" alpine
    mkdir -p "$_d/sys/fs/cgroup" "$_d/proc/sys/net/ipv4" "$_d/proc/sys/net/core" "$_d/run" "$_d/var/log" "$_d/etc/init.d" "$_d/etc/runlevels/default"
    printf '0::/\n' > "$_d/proc/self/cgroup"
    printf '%s\n' "$2" > "$_d/sys/fs/cgroup/memory.max"
    printf '%s\n' $(($2 / 2)) > "$_d/sys/fs/cgroup/memory.current"
    printf 'low 0\nhigh 0\nmax 35811\noom 175\noom_kill 38\noom_group_kill 0\n' > "$_d/sys/fs/cgroup/memory.events"
    printf 'anon 9000000\nfile 3000000\nkernel 1000000\nkernel_stack 100000\nsock 4000000\nslab 500000\npagetables 200000\nshmem 0\n' > "$_d/sys/fs/cgroup/memory.stat"
    printf '%s\n' "$3" > "$_d/proc/sys/net/ipv4/tcp_rmem"
    printf '%s\n' "$4" > "$_d/proc/sys/net/ipv4/tcp_wmem"
    printf 'MemTotal: %s kB\nMemFree: 1 kB\nMemAvailable: 1 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' $(($2 / 1024)) > "$_d/proc/meminfo"
    # 5: core 表示 /proc/sys/net/core/rmem_default 存在 (新内核容器里也有)  6: 用户命名空间映射 userns(默认) | identity | none
    [ "${5:-}" != core ] || printf '212992\n' > "$_d/proc/sys/net/core/rmem_default"
    case ${6:-userns} in
        userns) printf '         0    1000000 1000000000\n' > "$_d/proc/self/uid_map" ;;
        identity) printf '         0          0 4294967295\n' > "$_d/proc/self/uid_map" ;;
        none) rm -f "$_d/proc/self/uid_map" ;;
    esac
    mkdir -p "$_d/proc/1"
    printf 'HOME=/\0container=lxc\0' > "$_d/proc/1/environ"
    mkdir -p "$_d/proc/self/ns"
    printf 'net:[4026532711]\n' > "$_d/proc/self/ns/net.txt"
    mkdir -p "$_d/proc/net" "$_d/etc/alpine-proxy-manager"
    printf '1000.00 900.00\n' > "$_d/proc/uptime"
    printf '%s\n' $(($2 / 3)) > "$_d/sys/fs/cgroup/memory.peak"
    printf 'sockets: used 10\nTCP: inuse 3 orphan 0 tw 0 alloc 5 mem 2\n' > "$_d/proc/net/sockstat"
    # 假的 rc-service 与 rc-update: 状态用文件表示
    cat > "$_d/sbin/rc-service" <<'EOS'
#!/bin/sh
r=$(dirname "$0")/..
echo "$*" >> "$r/.rc.log"
case $2 in
    status) [ -e "$r/.svc-running" ] && exit 0; exit 3 ;;
    start) : > "$r/.svc-running" ;;
    stop) rm -f "$r/.svc-running" ;;
esac
exit 0
EOS
    cat > "$_d/sbin/rc-update" <<'EOS'
#!/bin/sh
r=$(dirname "$0")/..
echo "$*" >> "$r/.rc.log"
case $1 in
    add) : > "$r/etc/runlevels/default/$2" ;;
    del) rm -f "$r/etc/runlevels/default/$2" ;;
esac
exit 0
EOS
    chmod +x "$_d/sbin/rc-service" "$_d/sbin/rc-update"
}

# mk_sshd DIR PID ADJ COMM
mk_sshd() {
    mk_proc "$1" "$2" 1 "$4" "$4"
    printf '%s\n' "$3" > "$1/proc/$2/oom_score_adj"
}

lm() { APM_SYSROOT="$A" APM_EUID=0 APM_HOME="$T_ROOT" "$PM" lowmem "$@" 2>&1; }
tcp() { tr -s '\t ' ' ' < "$A/proc/sys/net/ipv4/tcp_$1" | sed 's/ $//'; }
snap() { (cd "$A" && find . -type f | sort | xargs cksum 2>/dev/null); }


mk_msnell() { mkdir -p "$1/usr/local/bin"; mk_elf_stub "$1/usr/local/bin/snell-server" "snell-server" || return 1; mkdir -p "$1/var/lib/alpine-proxy-manager/cores"; printf 'core=snell\nmanaged=true\n' > "$1/var/lib/alpine-proxy-manager/cores/snell.meta"; }
if ! mk_msnell "$T_TMP/probe"; then
    t_skip "ELF 桩只支持 x86_64, test_lowmem_tui.sh 全部跳过"
    t_done
    exit $?
fi
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

# 一个带受管 Snell 的最小系统. 参数 名称 [deny]
mk_sys() {
    A="$T_TMP/$1"
    mk_lm "$A" $((122 * MIB)) "4096 87380 67108864" "4096 65536 67108864"
    mk_sshd "$A" 524 0 sshd
    mk_msnell "$A"
    mkdir -p "$A/proc/1" "$A/etc/init.d"
    printf '1 (init) S 0 1\n' > "$A/proc/1/stat"
    printf '#!/sbin/openrc-run\n' > "$A/etc/init.d/snell"
    printf '800\n' > "$A/run/snell.pid"
    mk_proc "$A" 800 1 supervise-daemo supervise-daemo
    mk_proc "$A" 801 800 ld-musl-x86_64. ld-musl-x86_64.
    printf '0\n' > "$A/proc/801/oom_score_adj"
    [ "${2:-}" != deny ] || : > "$A/.deny-oom-lower"
}
# 在子 shell 里以该系统的环境运行函数或命令
V() { ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; export APM_SYSROOT APM_EUID APM_HOME; "$@" ) </dev/null 2>&1; }
# 按键驱动整个 TUI (管道, 不开阅读暂停)
TUI() { printf '%b' "$1" | ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; APM_TUI_ANSI=0; export APM_SYSROOT APM_EUID APM_HOME APM_TUI_ANSI; tui_run ) 2>&1; }
# 显示宽度: ASCII 1 列, 中日韩 2 列 (UTF-8 里 3 字节), 最大行宽
maxw() {
    printf '%s\n' "$1" | while IFS= read -r l; do
        b=$(printf '%s' "$l" | LC_ALL=C wc -c | tr -d ' ')
        c=$(printf '%s' "$l" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
        printf '%s\n' $((c + (b - c) / 2))
    done | sort -n | tail -n 1
}
VW() { ( LINES=60; COLUMNS=200; export LINES COLUMNS; V "$@" ); }
nl_count() { printf '%s\n' "$1" | grep -c -- "$2" || :; }

# ============ 1. 首页: 未启用 ============
printf '== 首页: 未启用\n'
mk_sys h1
out=$(V _tui_lm_home)
assert_contains "未启用: 状态" "$out" "保护状态：未启用"
assert_contains "未启用: TCP 一行" "$out" "TCP 缓冲优化：可调整"
assert_contains "未启用: SSH 一行" "$out" "SSH 进程保护：可启用"
assert_contains "未启用: 取证一行" "$out" "内存取证：可启用"
assert_contains "未启用: Snell 优先终止一行" "$out" "Snell 优先终止：未启用"
assert_not_contains "首页不展开 cgroup 路径" "$out" "/sys/fs/cgroup"
assert_not_contains "首页不展开 TCP 原始参数" "$out" "4096"
assert_not_contains "首页不展开作用范围长解释" "$out" "同一命名空间里的所有服务"
assert_not_contains "未启用时不显示开机持久化" "$out" "开机持久化"
assert_contains "首页说明不是内存清理工具" "$out" "不清理或回收内存"
mk_sys h2 deny
out=$(V _tui_lm_home)
assert_contains "权限不足: 未启用时写不可用" "$out" "SSH 进程保护：不可用（权限不足"

# ============ 2. 启用: 环境检查 预计启用 结果 ============
printf '== 启用: 权限不足的环境\n'
mk_sys e1 deny
out=$(V _tui_lm_enable)
assert_contains "启用前: 环境检查" "$out" "环境检查"
assert_contains "启用前: 预计启用 TCP" "$out" "- TCP 缓冲优化"
assert_contains "启用前: 预计启用取证" "$out" "- 内存取证"
assert_not_contains "启用前: 不预计启用 SSH" "$out" "- SSH 进程保护"
assert_contains "结果: 标题" "$out" "启用结果"
assert_contains "结果: TCP 成功并列出变化" "$out" "tcp_rmem：4096 87380 67108864 -> 4096 87380 6291456"
assert_contains "结果: SSH 未应用且标 !" "$out" "! SSH 进程保护：未应用（权限不足"
assert_contains "结果: 取证已启动" "$out" "内存取证：已启动"
assert_contains "结果: 持久化已配置" "$out" "开机持久化：已配置"
assert_contains "结果: 不把部分生效写成全部成功" "$out" "实际生效 2 项；1 项因环境限制不可用"
assert_not_contains "结果: 不再打印整份状态报告" "$out" "历史 OOM Kill"
assert_not_contains "结果: 不重复适用范围说明" "$out" "适用范围"
assert_eq "实际: tcp_rmem 已改" "4096 87380 6291456" "$(tcp rmem)"
assert_eq "实际: sshd 分数未动" 0 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "实际: 服务已加入 default" 1 "$([ -e "$A/etc/runlevels/default/apm-lowmem" ] && echo 1 || echo 0)"
out=$(V _tui_lm_home)
assert_contains "已启用首页: 口径写明" "$out" "已启用（配置 2 项，生效 2 项；环境限制 1 项）"
assert_contains "已启用首页: 统计口径说明" "$out" "配置项：设置里启用的机制"
assert_contains "已启用首页: SSH 未生效标 !" "$out" "! SSH 进程保护：未生效（权限不足"
assert_contains "已启用首页: TCP 已生效" "$out" "TCP 缓冲优化：已生效"
assert_contains "已启用首页: 取证运行中" "$out" "内存取证：运行中"
assert_contains "已启用首页: 持久化" "$out" "开机持久化：已启用"
assert_contains "已启用首页: 直接提示有项没生效" "$out" "! 有 1 项没有生效"
assert_not_contains "已启用首页: 没有 2/2 之类的计数" "$out" "2/2"

printf '== 启用: 权限齐全 加 Snell 优先终止\n'
mk_sys e2
out=$(V _tui_lm_enable sac)
assert_contains "sac: 预计启用 SSH" "$out" "- SSH 进程保护"
assert_contains "sac: 预计启用 Snell 优先终止" "$out" "- Snell 优先终止（高级选项）"
assert_contains "sac: SSH 已生效" "$out" "SSH 进程保护：已生效（1 个进程，oom_score_adj <= -500）"
assert_contains "sac: Snell 已启用" "$out" "Snell 优先终止：已启用（1 个进程，oom_score_adj >= 300）"
assert_contains "sac: 结论全部生效" "$out" "已配置的 4 项机制全部生效"
assert_eq "实际: sshd 分数 -500" -500 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "实际: Snell 进程 300" 300 "$(cat "$A/proc/801/oom_score_adj")"
assert_eq "实际: supervise-daemon 没有被写入" 0 "$([ -e "$A/proc/800/oom_score_adj" ] && echo 1 || echo 0)"
out=$(V _tui_lm_home)
assert_contains "sac 首页: 代价警告" "$out" "! Snell 优先终止不提高 Snell 的稳定性，"
out=$(V _tui_lm_enable sac)
assert_contains "重复启用: 标明未改变" "$out" "TCP 缓冲：已生效（与之前相同，未改变）"
assert_contains "重复启用: Snell 未改变" "$out" "Snell 优先终止：已生效（未改变）"
assert_contains "重复启用: 没有可启用的机制" "$out" "本次没有可启用的机制"
assert_eq "重复启用: 原值不被覆盖" "4096 87380 67108864" "$(kv_get "$A/var/lib/alpine-proxy-manager/lowmem.orig" tcp_rmem_orig)"

# ============ 3. 高级选项页 ============
printf '== 高级保护选项页\n'
out=$(V _tui_lm_adv_info)
assert_contains "高级: 当前策略" "$out" "当前策略：已启用"
assert_contains "高级: 现有 oom_score_adj" "$out" "PID 801（ld-musl-x86_64.）：oom_score_adj 300"
assert_contains "高级: 目标策略" "$out" "提高到 300"
assert_contains "高级: 预期效果" "$out" "预期效果"
assert_contains "高级: 代价不是稳定性" "$out" "这不会提高 Snell 的稳定性"
assert_contains "高级: 范围边界" "$out" "不动其监督进程"
assert_contains "高级: 关闭方式如实说明" "$out" "目前没有单独关闭该选项的命令"
mk_sys a1
out=$(V _tui_lm_adv_info)
assert_contains "高级: 未启用时说明" "$out" "当前策略：未启用"
assert_not_contains "高级: 未启用时没有关闭方式" "$out" "关闭方式"

# ============ 4. 恢复页 ============
printf '== 恢复: 分组 如实区分 已恢复 未修改 失败\n'
mk_sys d0
out=$(V _tui_lm_disable)
assert_contains "未启用: 恢复页如实说明" "$out" "没有启用，没有需要恢复的内容"
mk_sys d1
V _tui_lm_enable sac >/dev/null
out=$(V _tui_lm_disable)
assert_contains "恢复: 标题" "$out" "恢复结果"
assert_contains "恢复: TCP 分组" "$out" "TCP 参数"
assert_contains "恢复: 进程保护分组" "$out" "进程保护"
assert_contains "恢复: OpenRC 分组" "$out" "OpenRC 与配置"
assert_contains "恢复: tcp_rmem 已恢复" "$out" "4096 87380 6291456 -> 4096 87380 67108864"
assert_contains "恢复: SSH 恢复" "$out" "SSH 进程保护：已把 1 个进程的 oom_score_adj 恢复为原值"
assert_contains "恢复: Snell 恢复" "$out" "Snell 优先终止：已把 1 个进程恢复为原值"
assert_contains "恢复: 服务删除" "$out" "apm-lowmem 服务和设置文件：已删除"
assert_contains "恢复: 日志保留" "$out" "取证日志：保留在"
assert_contains "恢复: 最终状态" "$out" "最终状态：保护已停用，已恢复到启用前的状态"
assert_eq "实际: tcp 回到原值" "4096 87380 67108864" "$(tcp rmem)"
assert_eq "实际: sshd 回到 0" 0 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "实际: Snell 回到 0" 0 "$(cat "$A/proc/801/oom_score_adj")"
assert_eq "实际: 设置文件删除" 0 "$([ -e "$A/etc/alpine-proxy-manager/lowmem.conf" ] && echo 1 || echo 0)"
mk_sys d2
V _tui_lm_enable >/dev/null
printf '4096 99999 33554432\n' > "$A/proc/sys/net/ipv4/tcp_rmem"
out=$(V _tui_lm_disable)
assert_contains "外部修改: 标 ! 并说明没有覆盖" "$out" "! tcp_rmem：当前值 4096 99999 33554432 已被外部修改，没有覆盖，未恢复"
assert_contains "外部修改: 最终状态不说已恢复" "$out" "没有恢复到原始状态"
assert_not_contains "外部修改: 不显示已恢复到启用前" "$out" "已恢复到启用前的状态"
assert_eq "外部修改: 值保持" "4096 99999 33554432" "$(tcp rmem)"
mk_sys d3
V _tui_lm_enable sac >/dev/null
: > "$A/run/apm-lowmem/snell.adj"
out=$(V _tui_lm_disable)
assert_contains "无原值记录: 单独列为未修改" "$out" "未修改的项目（没有原始记录，不是已恢复）"
assert_contains "无原值记录: 说明没有改动" "$out" "! Snell 优先终止：1 个进程的 oom_score_adj 是 300，没有原值记录，没有改动"
assert_not_contains "无原值记录: 不写成已恢复" "$out" "Snell 优先终止：已把"
assert_contains "无原值记录: 如实说没有可恢复的记录" "$out" "Snell 优先终止：没有可恢复的进程记录"
assert_contains "无原值记录: 最终状态提示" "$out" "没有恢复到原始状态"
assert_eq "无原值记录: Snell 分数保持" 300 "$(cat "$A/proc/801/oom_score_adj")"

# ============ 5. 状态如实反映 ============
printf '== 状态如实: 外部修改 常驻进程停止\n'
mk_sys s1
V _tui_lm_enable >/dev/null
printf '4096 99999 33554432\n' > "$A/proc/sys/net/ipv4/tcp_rmem"
out=$(V _tui_lm_home)
assert_contains "TCP 被改: 首页标 ! 未生效" "$out" "! TCP 缓冲优化：未生效（当前值与设置不一致"
assert_contains "TCP 被改: 口径含未完全生效" "$out" "1 项未完全生效"
printf '4096 87380 6291456\n' > "$A/proc/sys/net/ipv4/tcp_rmem"
rm -f "$A/.svc-running"
out=$(V _tui_lm_home)
assert_contains "常驻进程停止: 取证标 ! 未运行" "$out" "! 内存取证：未运行"

# ============ 6. 详情页 ============
printf '== 详情页: 五个分组\n'
mk_sys t1
V _tui_lm_enable sac >/dev/null
out=$(V _tui_lm_detail)
for h in "A. 运行环境" "B. TCP 缓冲区" "C. 进程保护" "D. 取证与持久化" "E. 限制与风险"; do
    assert_contains "详情分组 $h" "$out" "$h"
done
assert_contains "详情: cgroup 与内存上限" "$out" "内存上限：122 MiB（cgroup v2）"
assert_contains "详情: 共享状态与依据分行" "$out" "网络命名空间：与宿主机不共享"
assert_contains "详情: 影响范围" "$out" "TCP 参数影响范围：当前网络命名空间内的所有服务"
assert_contains "详情: rmem 当前原始目标" "$out" "原始：4096 87380 67108864（上限 64 MiB）"
assert_contains "详情: 目标" "$out" "目标：4096 87380 6291456（上限 6 MiB）"
assert_contains "详情: 依据分行" "$out" "依据：单个连接的缓冲上限之和 128 MiB"
assert_contains "详情: 依据续行" "$out" "超过内存上限 122 MiB 的四分之一"
assert_contains "详情: wmem" "$out" "tcp_wmem（发送缓冲）"
assert_contains "详情: SSH 实际 oom_score_adj" "$out" "PID 524（sshd）：oom_score_adj -500"
assert_contains "详情: Snell 实际 oom_score_adj" "$out" "PID 801（ld-musl-x86_64.）：oom_score_adj 300"
assert_contains "详情: 记录位置" "$out" "记录文件：/var/log/apm-lowmem.log"
assert_contains "详情: 持久化" "$out" "开机持久化：已启用"
assert_contains "详情: 累计性质" "$out" "OOM 计数是累计值，当前 38 次"
assert_contains "详情: 不保证存活" "$out" "不能保证进程不被终止"
assert_contains "详情: Snell 代价" "$out" "不提高其稳定性"
assert_contains "详情: 影响整个命名空间" "$out" "TCP 参数影响整个网络命名空间，不只是 Snell"
mk_sys t2
out=$(V _tui_lm_detail)
assert_contains "详情 (未启用): 没有保存的原始值" "$out" "原始 / 目标：没有保存（没有调整过）"
assert_contains "详情 (未启用): 内核默认参照" "$out" "内核默认（参照）：4096 131072 6291456"
mk_sys t3
rm -f "$A/proc/self/uid_map"
out=$(V _tui_lm_detail)
assert_contains "详情: 作用范围未确认" "$out" "是否与宿主机共享未确认"

# ============ 7. 取证记录 ============
printf '== 取证: 摘要 与 原始记录\n'
mk_sys f1
V _tui_lm_enable >/dev/null
out=$(V _tui_lm_forensics_summary)
assert_contains "无日志: 说明" "$out" "还没有取证记录"
assert_contains "无日志: 趋势不编造" "$out" "采样不足，无法判断"
assert_contains "无日志: 累计 OOM" "$out" "OOM Kill 累计：38 次（所在 cgroup 创建以来，不是最近一次）"
LOGF="$A/var/log/apm-lowmem.log"
beat() { printf 'BEAT 2026-10-22 %02d:%02d:00 up=%s cur=%s sock=100 anon=200 oom_kill=%s\n' $((10 + $1 * 5 / 60)) $(($1 * 5 % 60)) "$1" "$2" "$3"; }
{
    printf 'START 2026-10-22 10:00:00 up=100.00 cur=40000000 max=127926272 events[oom_kill=38]\n'
    i=0
    while [ "$i" -lt 14 ]; do beat "$i" $((40000000 + i * 1000000)) 38; i=$((i + 1)); done
} > "$LOGF"
out=$(V _tui_lm_forensics_summary)
assert_contains "只有心跳: 最近采样" "$out" "最近采样：2026-10-22 11:05:00"
assert_contains "只有心跳: 趋势上升" "$out" "近期趋势：上升"
assert_contains "只有心跳: 统计区间" "$out" "统计区间：2026-10-22 10:10:00 到 2026-10-22 11:05:00"
assert_contains "只有心跳: 最低最高" "$out" "共 12 条心跳，最低 40 MiB，最高 50 MiB"
assert_contains "只有心跳: 当前使用与比例" "$out" "内存使用：50 MiB / 122 MiB"
assert_contains "重复的累计值不是新事件" "$out" "观察窗口内变化：38 -> 38（新增 0 次）"
assert_contains "没有 OOM 记录就是无异常" "$out" "异常事件：无"
assert_not_contains "不把累计值当成事件" "$out" "次 OOM 事件记录"
{
    cat "$LOGF"
    printf 'OOM 2026-10-22 11:12:00 up=300 cur=127000000 events[oom_kill=39] 新增_oom_kill=1\nPROCS 2026-10-22 11:12:00 snell=2000 sshd=900\nBURST 2026-10-22 11:12:02 cur=120000000 sock=1 anon=2\n'
    beat 15 80000000 39
} > "$LOGF.new"
mv "$LOGF.new" "$LOGF"
out=$(V _tui_lm_forensics_summary)
assert_contains "有 OOM: 事件记录与时间" "$out" "异常事件：1 次 OOM 事件记录，最近一次 2026-10-22 11:12:00"
assert_contains "有 OOM: 窗口内新增 1 次" "$out" "38 -> 39（新增 1 次）"
sum0=$(cksum "$LOGF")
out=$(VW _tui_lm_rawlog all)
assert_contains "原始记录: 保留原始时间戳和数据" "$out" "BEAT 2026-10-22 10:05:00 up=1 cur=41000000 sock=100 anon=200 oom_kill=38"
assert_contains "原始记录: 含事件行" "$out" "OOM 2026-10-22 11:12:00"
out=$(VW _tui_lm_rawlog events)
assert_contains "异常事件视图: OOM" "$out" "OOM 2026-10-22 11:12:00"
assert_contains "异常事件视图: PROCS" "$out" "PROCS 2026-10-22 11:12:00 snell=2000"
assert_contains "异常事件视图: BURST" "$out" "BURST 2026-10-22 11:12:02"
assert_not_contains "异常事件视图: 不含普通心跳" "$out" "BEAT 2026-10-22 10:05:00"
assert_eq "查看记录不改日志" "$sum0" "$(cksum "$LOGF")"
# 日志无法解析: 摘要不编造, 原始记录仍可查看
printf 'garbage line one\n\200\201 not a log\n' > "$LOGF"
out=$(V _tui_lm_forensics_summary)
assert_contains "无法解析: 说明没有可识别的采样" "$out" "没有可识别的采样行"
out=$(VW _tui_lm_rawlog all)
assert_contains "无法解析: 原始记录仍可看" "$out" "garbage line one"
# 分页: 长日志在矮终端分多页, 回车下一页, q 结束
i=0; : > "$LOGF"
while [ "$i" -lt 60 ]; do beat "$i" $((40000000 + i)) 38 >> "$LOGF"; i=$((i + 1)); done
out=$(printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; LINES=14; COLUMNS=80; export APM_SYSROOT APM_EUID APM_HOME LINES COLUMNS; _tui_lm_rawlog all ) 2>&1)
assert_contains "分页: 有页码提示" "$out" "-- 第 1/"
assert_contains "分页: 最后一页的内容也能看到" "$out" "BEAT 2026-10-22 14:55:00 up=59"
out=$(printf 'q\n' | ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; LINES=14; COLUMNS=80; export APM_SYSROOT APM_EUID APM_HOME LINES COLUMNS; _tui_lm_rawlog all ) 2>&1)
assert_not_contains "分页: q 结束后不再显示后面的页" "$out" "BEAT 2026-10-22 14:55:00 up=59"
rc7=$(printf 'q\n' | ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; LINES=14; COLUMNS=80; export APM_SYSROOT APM_EUID APM_HOME LINES COLUMNS; _tui_lm_rawlog all >/dev/null 2>&1; echo $? ))
assert_eq "分页: 中途结束返回 7 (调用方不再追加 按回车返回)" 7 "$rc7"
rc0=$(printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | ( APM_SYSROOT="$A"; APM_EUID=0; APM_HOME="$T_ROOT"; LINES=14; COLUMNS=80; export APM_SYSROOT APM_EUID APM_HOME LINES COLUMNS; _tui_lm_rawlog all >/dev/null 2>&1; echo $? ))
assert_eq "分页: 翻到最后一页返回 0 (调用方再停一次读完)" 0 "$rc0"
assert_eq "分页: 临时文件已清理" 0 "$(ls "${TMPDIR:-/tmp}"/apm-lmlog.* 2>/dev/null | wc -l | tr -d ' ')"

# ============ 8. 无 cgroup v2 ============
printf '== 环境: 没有 cgroup v2 的 memory.events\n'
mk_sys n1
rm -f "$A/sys/fs/cgroup/memory.events"
out=$(V _tui_lm_home)
assert_contains "无 memory.events: 取证不可用" "$out" "内存取证：不可用（需要 cgroup v2 的 memory.events）"
out=$(V _tui_lm_forensics_summary)
assert_contains "无 memory.events: 累计不可用" "$out" "OOM Kill 累计：不可用"

# ============ 9. 版面宽度: 80 列内 ============
printf '== 版面: 每页每行不超过 80 列\n'
mk_sys w1
V _tui_lm_enable sac >/dev/null
for f in _tui_lm_home _tui_lm_detail _tui_lm_forensics_summary _tui_lm_adv_info; do
    out=$(V "$f")
    assert_eq "$f 最大行宽不超过 60 (窄终端不折行)" 1 "$([ "$(maxw "$out")" -le 60 ] && echo 1 || echo 0)"
done
mk_sys w2 deny
out=$(V _tui_lm_enable)
assert_eq "启用页最大行宽不超过 60" 1 "$([ "$(maxw "$out")" -le 60 ] && echo 1 || echo 0)"
out=$(V _tui_lm_disable)
assert_eq "恢复页最大行宽不超过 60" 1 "$([ "$(maxw "$out")" -le 60 ] && echo 1 || echo 0)"

# ============ 10. 菜单路径 (管道) ============
printf '== 菜单路径\n'
mk_sys m1
snellmenu=$(TUI '1\n0\n0\n')
nn=$(printf '%s\n' "$snellmenu" | sed -n 's/^\([0-9]*\)\. 网络功能$/\1/p' | head -n 1)
assert_eq "Snell 菜单里的 网络功能 有编号" 1 "$([ -n "$nn" ] && echo 1 || echo 0)"
out=$(TUI "1\n$nn\n2\n0\n0\n0\n0\n")
assert_contains "保护页: 标题" "$out" "Snell · 网络与进程保护（低内存环境）"
assert_contains "保护页菜单 1" "$out" "1. 查看保护详情"
assert_contains "保护页菜单 2" "$out" "2. 查看取证记录"
assert_contains "保护页菜单 3" "$out" "3. 高级保护选项"
assert_contains "未启用: 菜单 4 是启用" "$out" "4. 启用保护"
assert_not_contains "未启用: 没有恢复项" "$out" "停用保护并恢复设置"
out=$(TUI "1\n$nn\n2\n1\n0\n0\n0\n0\n")
assert_contains "菜单 1 进入详情页" "$out" "A. 运行环境"
out=$(TUI "1\n$nn\n2\n2\n0\n0\n0\n0\n0\n")
assert_contains "菜单 2 进入取证记录" "$out" "Snell · 取证记录"
assert_contains "取证记录: 原始记录入口" "$out" "1. 查看原始记录（最近 100 行，分页）"
assert_contains "取证记录: 异常事件入口" "$out" "2. 只看异常事件相关记录"
out=$(TUI "1\n$nn\n2\n3\n0\n0\n0\n0\n0\n")
assert_contains "菜单 3 进入高级保护选项" "$out" "Snell · 高级保护选项"
assert_contains "高级页: 启用入口" "$out" "1. 启用 Snell 优先终止"
out=$(TUI "1\n$nn\n2\n4\n0\n0\n0\n0\n")
assert_contains "菜单 4 启用保护: 环境检查" "$out" "环境检查"
assert_contains "菜单 4 启用保护: 结果" "$out" "启用结果"
assert_eq "菜单启用: tcp 实际改变" "4096 87380 6291456" "$(tcp rmem)"
out=$(TUI "1\n$nn\n2\n0\n0\n0\n0\n")
assert_contains "已启用: 菜单 4 是停用" "$out" "4. 停用保护并恢复设置"
assert_not_contains "已启用: 不再有启用项" "$out" "4. 启用保护"
out=$(TUI "1\n$nn\n2\n4\n0\n0\n0\n0\n")
assert_contains "菜单停用: 恢复结果" "$out" "恢复结果"
assert_eq "菜单停用: tcp 实际恢复" "4096 87380 67108864" "$(tcp rmem)"
# 高级页启用 Snell 优先终止, 再次进入后不再有启用入口
out=$(TUI "1\n$nn\n2\n3\n1\n0\n0\n0\n0\n0\n")
assert_contains "高级页启用: 结果含 Snell 优先终止" "$out" "Snell 优先终止：已启用"
assert_eq "高级页启用: 实际提高到 300" 300 "$(cat "$A/proc/801/oom_score_adj")"
out=$(TUI "1\n$nn\n2\n3\n0\n0\n0\n0\n")
assert_not_contains "已启用 sac: 高级页不再给启用入口" "$out" "1. 启用 Snell 优先终止"
TUI "1\n$nn\n2\n4\n0\n0\n0\n0\n" >/dev/null
# 非 root: 写操作被拒绝并提示, 状态不变
mk_sys m2
out=$(printf '1\n%s\n2\n4\n0\n0\n0\n0\n' "$nn" | ( APM_SYSROOT="$A"; APM_EUID=1000; APM_HOME="$T_ROOT"; APM_TUI_ANSI=0; export APM_SYSROOT APM_EUID APM_HOME APM_TUI_ANSI; tui_run ) 2>&1)
assert_contains "非 root: 拒绝并说明" "$out" "此操作需要 root"
assert_eq "非 root: tcp 不变" "4096 87380 67108864" "$(tcp rmem)"
# 全局状态与诊断没有保护入口, CLI 不变
out=$(TUI '4\n0\n0\n')
assert_not_contains "状态与诊断: 没有保护入口" "$out" "网络与进程保护"
assert_contains "CLI: lowmem status 仍可用" "$(lm status)" "保护状态：未启用"

# ============ 11. 真实终端 (tmux) ============
if command -v tmux >/dev/null 2>&1; then
    printf '== 真实终端: 导航 阅读暂停 宽窄终端\n'
    mk_sys p1
    mkdir -p "$A/usr/bin"
    ln -sf "$(command -v stty)" "$A/usr/bin/stty"
    DRV=$T_TMP/lmtui-drv.sh
    cat > "$DRV" <<EOD
APM_SYSROOT=$A
APM_EUID=0
APM_HOME=$T_ROOT
APM_TUI_ANSI=1
LC_ALL=en_US.UTF-8
export APM_SYSROOT APM_EUID APM_HOME APM_TUI_ANSI LC_ALL
exec sh $T_ROOT/bin/proxy-manager tui
EOD
    S=lmtui$$
    start() { # 宽 高
        tmux kill-session -t "$S" 2>/dev/null
        tmux new-session -d -s "$S" -x "$1" -y "$2" "sh $DRV" || return 1
        _i=0
        while [ "$_i" -lt 50 ] && ! tmux capture-pane -p -t "$S" | grep -q '请选择：'; do sleep 0.1; _i=$((_i + 1)); done
        sleep 0.5
    }
    vis() { tmux capture-pane -p -t "$S"; }
    # 等待屏幕出现某段文字 (最多 15 秒): 操作耗时不固定, 提前发键会被输入丢弃机制清掉, 所以每步先确认画面
    waitfor() { _w=0; while [ "$_w" -lt 150 ] && ! vis | grep -q -- "$1"; do sleep 0.1; _w=$((_w + 1)); done; }
    pick() { for _k in "$@"; do tmux send-keys -t "$S" -- "$_k"; sleep 0.3; tmux send-keys -t "$S" -- Enter; sleep 0.6; done; }
    key() { for _k in "$@"; do tmux send-keys -t "$S" -- "$_k"; sleep 0.5; done; }
    for dim in "80 24" "60 30" "100 50"; do
        # shellcheck disable=SC2086
        set -- $dim
        start "$1" "$2"
        pick 1 "$nn" 2
        waitfor "4. 启用保护"
        v=$(vis)
        assert_contains "tmux $dim: 进入保护首页" "$v" "Snell · 网络与进程保护"
        assert_contains "tmux $dim: 首页状态" "$v" "保护状态：未启用"
        assert_contains "tmux $dim: 菜单" "$v" "4. 启用保护"
        pick 1; waitfor "按回车返回"
        v=$(vis)
        assert_contains "tmux $dim: 详情页停在 按回车返回" "$v" "按回车返回..."
        key Enter; waitfor "4. 启用保护"
        assert_contains "tmux $dim: 回车后回到保护首页" "$(vis)" "4. 启用保护"
        stop() { tmux kill-session -t "$S" 2>/dev/null; }
        stop
    done
    start 80 24
    pick 1 "$nn" 2 4; waitfor "按回车返回"
    v=$(vis)
    assert_contains "tmux: 启用结果页停在 按回车返回" "$v" "按回车返回..."
    assert_contains "tmux: 启用结果" "$v" "启用结果"
    assert_eq "tmux: 启用实际改了 tcp_rmem" "4096 87380 6291456" "$(tcp rmem)"
    key Enter; waitfor "4. 停用保护并恢复设置"
    assert_contains "tmux: 回车后首页变成已启用" "$(vis)" "4. 停用保护并恢复设置"
    pick 2; waitfor "Snell · 取证记录"
    assert_contains "tmux: 取证摘要页" "$(vis)" "Snell · 取证记录"
    pick 1; waitfor "取证记录 · 原始记录"
    assert_contains "tmux: 原始记录页" "$(vis)" "取证记录 · 原始记录"
    key Enter; waitfor "查看原始记录"
    assert_contains "tmux: 原始记录读完回车返回取证页" "$(vis)" "Snell · 取证记录"
    # 多页原始记录: 真实终端里每页都要停住等键, 回车翻页, Esc 结束且不再追加一次暂停 (此前分页的输入接到了 /dev/null)
    i=0; : > "$A/var/log/apm-lowmem.log"
    while [ "$i" -lt 60 ]; do beat "$i" $((40000000 + i)) 38 >> "$A/var/log/apm-lowmem.log"; i=$((i + 1)); done
    pick 1; waitfor "第 1/"
    sleep 2
    assert_contains "tmux: 多页原始记录停在第 1 页提示" "$(vis)" "回车下一页，Esc 结束"
    assert_not_contains "tmux: 分页期间没有自行返回取证菜单" "$(vis)" "只看异常事件相关记录"
    key Enter; waitfor "第 2/"
    assert_contains "tmux: 回车翻到第 2 页" "$(vis)" "第 2/"
    key Escape; waitfor "只看异常事件相关记录"
    sleep 0.5
    assert_contains "tmux: Esc 结束分页直接回到取证菜单" "$(vis)" "查看原始记录"
    assert_not_contains "tmux: Esc 结束分页后没有多余的 按回车返回" "$(vis)" "按回车返回"
    key Escape; waitfor "4. 停用保护并恢复设置"
    assert_contains "tmux: Esc 回到保护首页" "$(vis)" "4. 停用保护并恢复设置"
    pick 3; waitfor "Snell · 高级保护选项"
    v=$(vis)
    assert_contains "tmux: 高级保护选项页" "$v" "Snell · 高级保护选项"
    assert_contains "tmux: 高级页说明代价" "$v" "这不会提高 Snell 的稳定性"
    key Escape; waitfor "4. 停用保护并恢复设置"
    assert_contains "tmux: Esc 回到保护首页 (高级页)" "$(vis)" "4. 停用保护并恢复设置"
    pick 4; waitfor "按回车返回"
    v=$(vis)
    assert_contains "tmux: 恢复结果页停在 按回车返回" "$v" "按回车返回..."
    assert_contains "tmux: 恢复结果" "$v" "最终状态：保护已停用"
    assert_eq "tmux: 恢复实际写回 tcp_rmem" "4096 87380 67108864" "$(tcp rmem)"
 key Enter; waitfor "4. 启用保护"
    assert_contains "tmux: 回车后首页变回未启用" "$(vis)" "4. 启用保护"
    # 窄矮终端 (60x24): 一页内容加提示必须放进一屏, 第一行不能被滚出去 (页高按终端实际大小估算, 脚本里 LINES 与 COLUMNS 没有导出)
    start 60 24
    pick 1 "$nn" 2 2; waitfor "查看原始记录"
    pick 1; waitfor "第 1/"
    v=$(vis)
    assert_contains "tmux 60x24: 分页提示在屏幕上" "$v" "回车下一页，Esc 结束"
    assert_contains "tmux 60x24: 页标题没有被滚出屏幕" "$v" "取证记录 · 原始记录"
    key Escape; waitfor "只看异常事件相关记录"
    # 中断: 分页中 Ctrl-C 与会话断开 (SIGHUP) 都要删除临时目录并恢复终端; 查看期间临时目录 700 文件 600
    TD=$T_TMP/tmpd; mkdir -p "$TD"
    DRV2=$T_TMP/lmtui-drv2.sh
    cat > "$DRV2" <<EOD
APM_SYSROOT=$A
APM_EUID=0
APM_HOME=$T_ROOT
APM_TUI_ANSI=1
LC_ALL=en_US.UTF-8
TMPDIR=$TD
export APM_SYSROOT APM_EUID APM_HOME APM_TUI_ANSI LC_ALL TMPDIR
sh $T_ROOT/bin/proxy-manager tui
stty -a > $T_TMP/stty.after 2>&1
sleep 30
EOD
    start2() { tmux kill-session -t "$S" 2>/dev/null; tmux new-session -d -s "$S" -x 60 -y 24 "sh $DRV2" || return 1; waitfor "请选择："; sleep 0.5; }
    start2
    pick 1 "$nn" 2 2; waitfor "查看原始记录"
    pick 1; waitfor "第 1/"
    assert_eq "中断前: 有一个临时目录" 1 "$(ls -d "$TD"/apm-lmlog.* 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "临时目录只有自己能进 (700)" drwx------ "$(ls -ld "$TD"/apm-lmlog.* | cut -c1-10)"
    assert_eq "目录里的文件都是 600" 0 "$(find "$TD" -type f ! -perm 600 | wc -l | tr -d ' ')"
    assert_eq "目录里有日志副本与分页文件" 2 "$(find "$TD" -type f | wc -l | tr -d ' ')"
    rm -f "$T_TMP/stty.after"
    key C-c; _w=0; while [ "$_w" -lt 50 ] && [ ! -s "$T_TMP/stty.after" ]; do sleep 0.2; _w=$((_w + 1)); done
    assert_eq "Ctrl-C 后临时目录已删除" 0 "$(ls -d "$TD"/apm-lmlog.* 2>/dev/null | wc -l | tr -d ' ')"
    assert_contains "Ctrl-C 后终端回显已恢复" "$(cat "$T_TMP/stty.after" 2>/dev/null)" " echo"
    assert_not_contains "Ctrl-C 后终端不再停在原始模式" "$(cat "$T_TMP/stty.after" 2>/dev/null)" "-icanon"
    tmux kill-session -t "$S" 2>/dev/null
    start2
    pick 1 "$nn" 2 2; waitfor "查看原始记录"
    pick 1; waitfor "第 1/"
    assert_eq "断线前: 有一个临时目录" 1 "$(ls -d "$TD"/apm-lmlog.* 2>/dev/null | wc -l | tr -d ' ')"
    tmux kill-session -t "$S" 2>/dev/null
    _w=0; while [ "$_w" -lt 50 ] && ls -d "$TD"/apm-lmlog.* >/dev/null 2>&1; do sleep 0.2; _w=$((_w + 1)); done
    assert_eq "会话断开 (SIGHUP) 后临时目录已删除" 0 "$(ls -d "$TD"/apm-lmlog.* 2>/dev/null | wc -l | tr -d ' ')"
    tmux kill-session -t "$S" 2>/dev/null
else
    t_skip "没有 tmux, 保护页的真实终端测试跳过"
fi

t_done
