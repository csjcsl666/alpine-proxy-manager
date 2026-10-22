# shellcheck shell=sh
# 低内存环境保护: 检测 策略 启用 恢复 状态 取证 SSH 保护
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

# ============ 1. 同一套代码对不同配额的判断 (连续, 非查表) ============
printf '== 策略: 配额不同, 缓冲同样偏大\n'
for mb in 32 64 96 128 192 256 300 384; do
    A="$T_TMP/p$mb"
    mk_lm "$A" $((mb * MIB)) "$HYT_R" "$HYT_W"
    out=$(lm status)
    assert_contains "${mb} MiB: 识别内存上限" "$out" "内存上限：$mb MiB"
    assert_contains "${mb} MiB: 缓冲偏大" "$out" "偏大"
    assert_contains "${mb} MiB: 未启用" "$out" "保护状态：未启用"
done

printf '== 策略: 缓冲已经合理就不动 (任意配额)\n'
for mb in 33 64 100 128 256 300 700 1024; do
    A="$T_TMP/f$mb"
    mk_lm "$A" $((mb * MIB)) "$KD_R" "$KD_W"
    out=$(lm status)
    if [ "$mb" -ge 40 ]; then
        assert_contains "${mb} MiB 内核默认缓冲: 无需调整" "$out" "无需调整"
    fi
    before=$(snap)
    out=$(lm enable)
    # 没有 tcp 需要调整; ssh 在 deny 下不适用; 取证可用
    assert_eq "${mb} MiB 内核默认缓冲: tcp 文件原样" "$KD_R" "$(cat "$A/proc/sys/net/ipv4/tcp_rmem")"
    assert_not_contains "${mb} MiB: 没有 tcp 修改记录" "$out" "tcp_rmem：原值"
done

printf '== 策略: 阈值随配额连续变化 (同一组缓冲在 249 和 251 MiB 处翻转)\n'
# 收发上限之和 64 MiB: 阈值 = 配额/4, 255 MiB 以下超过, 256 MiB 及以上不超过
HK_R="4096	87380	33554432"
HK_W="4096	65536	33554432"
A="$T_TMP/b249"; mk_lm "$A" $((249 * MIB)) "$HK_R" "$HK_W"
assert_contains "249 MiB: 64 MiB 的缓冲偏大" "$(lm status)" "偏大"
A="$T_TMP/b255"; mk_lm "$A" $((255 * MIB)) "$HK_R" "$HK_W"
assert_contains "255 MiB: 64 MiB 的缓冲偏大" "$(lm status)" "偏大"
A="$T_TMP/b256"; mk_lm "$A" $((256 * MIB)) "$HK_R" "$HK_W"
assert_contains "256 MiB: 64 MiB 的缓冲刚好不超过" "$(lm status)" "无需调整"
A="$T_TMP/b300"; mk_lm "$A" $((300 * MIB)) "$HK_R" "$HK_W"
assert_contains "300 MiB: 非标准容量同样处理" "$(lm status)" "无需调整"

printf '== 策略: 内存很大但缓冲异常也提示, 内存很小但合理不动\n'
A="$T_TMP/big"; mk_lm "$A" $((2048 * MIB)) "4096 1048576 1073741824" "4096 1048576 1073741824"
assert_contains "2 GiB 但单连接可占 2 GiB: 偏大" "$(lm status)" "偏大"
A="$T_TMP/tiny"; mk_lm "$A" $((32 * MIB)) "$KD_R" "$KD_W"
out=$(lm status)
assert_contains "32 MiB 内核默认: 不再缩小" "$out" "已经不高于内核默认值"
assert_contains "32 MiB: 说明资源本身有限" "$out" "资源本身有限"

printf '== 策略: 无法识别内存上限\n'
A="$T_TMP/unk"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
rm -f "$A/sys/fs/cgroup/memory.max" "$A/sys/fs/cgroup/memory.events" "$A/sys/fs/cgroup/memory.stat" "$A/sys/fs/cgroup/memory.current"
: > "$A/proc/meminfo"
: > "$A/.deny-oom-lower"
out=$(lm status)
assert_contains "未知上限: 不调整" "$out" "无法可靠识别内存上限"
before=$(snap)
out=$(lm enable)
assert_eq "未知上限: 启用不改任何文件" "$before" "$(snap)"

# ============ 2. 启用 恢复 ============
printf '== 启用与恢复: 128 MiB, Hytron 类缓冲\n'
A="$T_TMP/e128"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
mk_sshd "$A" 524 0 sshd
mk_sshd "$A" 600 0 sshd-session
mk_sshd "$A" 601 0 bash
out=$(lm enable)
assert_eq "启用后 tcp_rmem" "4096 131072 6291456" "$(tcp rmem)"
assert_eq "启用后 tcp_wmem" "4096 16384 4194304" "$(tcp wmem)"
assert_contains "输出整体状态" "$out" "保护状态：已启用（3/3 项生效）"
assert_contains "TCP 已生效" "$out" "TCP 缓冲：已生效"
assert_contains "SSH 已生效" "$out" "SSH 保护：已生效"
assert_eq "sshd 监听进程降到 -500" -500 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "sshd-session 降到 -500" -500 "$(cat "$A/proc/600/oom_score_adj")"
assert_eq "其他进程不动" 0 "$(cat "$A/proc/601/oom_score_adj")"
assert_contains "服务安装" "$(cat "$A/.rc.log")" "add apm-lowmem default"
assert_ok "服务脚本带标记" grep -q '^# apm-managed: apm-lowmem' "$A/etc/init.d/apm-lowmem"
assert_ok "服务脚本在 sshd 之前" grep -q 'before snell sing-box anytls-socks-gateway sshd' "$A/etc/init.d/apm-lowmem"
assert_eq "设置文件权限" 600 "$(stat -c %a "$A/etc/alpine-proxy-manager/lowmem.conf")"
assert_eq "原值文件权限" 600 "$(stat -c %a "$A/var/lib/alpine-proxy-manager/lowmem.orig")"
orig=$(cat "$A/var/lib/alpine-proxy-manager/lowmem.orig")
assert_contains "原值记录 rmem" "$orig" "tcp_rmem_orig=4096 1048576 128516096"
assert_contains "目标记录 rmem" "$orig" "tcp_rmem_target=4096 131072 6291456"
assert_contains "依据记录" "$orig" "tcp_rmem_why="
out=$(lm detail)
assert_contains "详情: 原值目标当前" "$out" "tcp_rmem：原值 [4096 1048576 128516096]，目标 [4096 131072 6291456]，当前 [4096 131072 6291456]"
assert_contains "详情: 网络命名空间说明" "$out" "是否与宿主机共享：不共享"
assert_contains "详情: 不作承诺" "$out" "不承诺启用后 SSH 一定不被 OOM 杀死"
assert_contains "OOM 计数范围" "$(lm status)" "累计"

printf '== 重复启用: 原值不被覆盖\n'
o1=$(cksum < "$A/var/lib/alpine-proxy-manager/lowmem.orig")
out=$(lm enable)
o2=$(cksum < "$A/var/lib/alpine-proxy-manager/lowmem.orig")
assert_eq "重复启用不改原值文件" "$o1" "$o2"
assert_contains "重复启用仍是已启用" "$out" "保护状态：已启用（3/3 项生效）"
assert_eq "重复启用 tcp 不变" "4096 131072 6291456" "$(tcp rmem)"

printf '== 开机应用: lowmem boot 重新写入\n'
printf '4096\t1048576\t128516096\n' > "$A/proc/sys/net/ipv4/tcp_rmem"
out=$(lm boot)
assert_eq "boot 重新应用" "4096 131072 6291456" "$(tcp rmem)"

printf '== 外部修改: 状态如实显示, 恢复不覆盖\n'
printf '4096\t65536\t1000000\n' > "$A/proc/sys/net/ipv4/tcp_wmem"
out=$(lm status)
assert_contains "状态显示不一致" "$out" "tcp_wmem 当前 [4096 65536 1000000] 与设置"
assert_contains "不是全部成功" "$out" "部分启用"
out=$(lm disable)
assert_eq "外部修改的 wmem 不被覆盖" "4096 65536 1000000" "$(tcp wmem)"
assert_contains "说明已被外部修改" "$out" "已被外部修改，没有覆盖"
assert_eq "未被改动的 rmem 恢复" "4096 1048576 128516096" "$(tcp rmem)"
assert_eq "sshd 恢复" 0 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "sshd-session 恢复" 0 "$(cat "$A/proc/600/oom_score_adj")"
assert_fail "服务脚本已删除" test -e "$A/etc/init.d/apm-lowmem"
assert_fail "设置文件已删除" test -e "$A/etc/alpine-proxy-manager/lowmem.conf"
assert_fail "原值文件已删除" test -e "$A/var/lib/alpine-proxy-manager/lowmem.orig"
assert_contains "状态回到未启用" "$(lm status)" "保护状态：未启用"
out=$(lm disable)
assert_contains "重复关闭是空操作" "$out" "没有启用"

printf '== 完整恢复: 启用后关闭, 文件内容与启用前逐字节相同\n'
A="$T_TMP/rt"
mk_lm "$A" $((64 * MIB)) "$HYT_R" "$HYT_W"
mk_sshd "$A" 524 0 sshd
cp "$A/proc/sys/net/ipv4/tcp_rmem" "$T_TMP/rmem.before"
cp "$A/proc/sys/net/ipv4/tcp_wmem" "$T_TMP/wmem.before"
lm enable >/dev/null
assert_eq "64 MiB 启用后 rmem" "4096 131072 6291456" "$(tcp rmem)"
lm disable >/dev/null
assert_eq "关闭后 rmem 内容一致" "$(tr -s '\t ' ' ' < "$T_TMP/rmem.before")" "$(tcp rmem)"
assert_eq "关闭后 wmem 内容一致" "$(tr -s '\t ' ' ' < "$T_TMP/wmem.before")" "$(tcp wmem)"

# ============ 3. 权限与冲突 ============
printf '== 权限受限: sysctl 只读\n'
A="$T_TMP/ro"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
: > "$A/.deny-sysctl-write"
out=$(lm status)
assert_contains "只读 sysctl: 明确不支持" "$out" "不允许修改"
before=$(snap)
out=$(lm enable)
assert_eq "只读 sysctl: tcp 原样" "4096 1048576 128516096" "$(tcp rmem)"
assert_contains "只读 sysctl: 仍可启用取证" "$out" "内存取证：运行中"
assert_not_contains "只读 sysctl: 不显示 TCP 已生效" "$out" "TCP 缓冲：已生效"
assert_contains "只读 sysctl: 部分启用或已启用的计数只含适用项" "$out" "保护状态："
lm disable >/dev/null

printf '== 权限受限: 不允许降低 oom_score_adj (无特权容器)\n'
A="$T_TMP/nolower"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
: > "$A/.deny-oom-lower"
mk_sshd "$A" 524 0 sshd
out=$(lm enable)
assert_contains "说明内核限制" "$out" "不允许降低 oom_score_adj"
assert_eq "不尝试修改 sshd" 0 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "tcp 仍然调整" "4096 131072 6291456" "$(tcp rmem)"
assert_contains "SSH 不计入生效项" "$out" "保护状态：已启用（"
assert_not_contains "不显示 SSH 已生效" "$out" "SSH 保护：已生效"
lm disable >/dev/null

printf '== sshd 已受保护 / 没有 sshd\n'
A="$T_TMP/prot"
mk_lm "$A" $((128 * MIB)) "$KD_R" "$KD_W"
mk_sshd "$A" 524 -1000 sshd
out=$(lm status)
assert_contains "已受保护: 无需修改" "$out" "无需修改"
lm enable >/dev/null
assert_eq "不把 -1000 抬高" -1000 "$(cat "$A/proc/524/oom_score_adj")"
lm disable >/dev/null
assert_eq "关闭后仍是 -1000" -1000 "$(cat "$A/proc/524/oom_score_adj")"
A="$T_TMP/nosshd"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
assert_contains "没有 sshd" "$(lm status)" "没有检测到运行中的 sshd"

printf '== 管理员自定义 sysctl: 不覆盖\n'
A="$T_TMP/cust"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
mkdir -p "$A/etc/sysctl.d"
printf '# 管理员设置\nnet.ipv4.tcp_rmem = 4096 87380 16777216\n' > "$A/etc/sysctl.d/90-mine.conf"
out=$(lm status)
assert_contains "只跳过有冲突的参数" "$out" "tcp_rmem（管理员已在 /etc/sysctl.d/90-mine.conf 设置，APM 不覆盖）"
lm enable >/dev/null
assert_eq "冲突参数 rmem 不改" "4096 1048576 128516096" "$(tcp rmem)"
assert_eq "无冲突参数 wmem 调整" "4096 16384 4194304" "$(tcp wmem)"
assert_eq "管理员文件不被修改" "$(printf '# 管理员设置\nnet.ipv4.tcp_rmem = 4096 87380 16777216\n' | cksum)" "$(cksum < "$A/etc/sysctl.d/90-mine.conf")"
lm disable >/dev/null
assert_eq "关闭后 wmem 恢复" "4096 1048576 128516096" "$(tcp wmem)"
printf 'net.ipv4.tcp_wmem=4096 65536 8388608\n' >> "$A/etc/sysctl.d/90-mine.conf"
before=$(snap)
out=$(lm enable)
assert_contains "全部被管理员设置占用: 说明原因" "$out" "APM 不覆盖"
assert_eq "全部冲突: 缓冲不改" "4096 1048576 128516096" "$(tcp rmem)"

printf '== 其他防护\n'
A="$T_TMP/foreign"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
printf '#!/sbin/openrc-run\n# 别人的服务\n' > "$A/etc/init.d/apm-lowmem"
out=$(lm enable)
assert_contains "拒绝覆盖不是 APM 生成的服务脚本" "$out" "不是 APM 生成的"
assert_contains "别人的脚本保持原样" "$(cat "$A/etc/init.d/apm-lowmem")" "别人的服务"
out=$(APM_SYSROOT="$A" APM_EUID=1000 "$PM" lowmem enable 2>&1)
assert_rc "非 root 拒绝" 4 sh -c "APM_SYSROOT='$A' APM_EUID=1000 '$PM' lowmem enable >/dev/null 2>&1"
assert_contains "非 root 提示" "$out" "需要 root"
out=$(lm bogus)
assert_contains "未知子命令" "$out" "用法"
A="$T_TMP/ver"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
echo 1 > "$A/sys/fs/cgroup/.nothing"
rm -f "$A/sys/fs/cgroup/memory.events"
out=$(lm status)
assert_contains "cgroup 数据不可读: 取证不适用" "$out" "需要 cgroup v2 的 memory.events"
assert_contains "cgroup 数据不可读: OOM 计数不可用" "$out" "历史 OOM Kill：不可用"

# ============ 4. 取证常驻进程 ============
printf '== 取证: OOM 计数变化时记录, 平时不写\n'
A="$T_TMP/fx"
mk_lm "$A" $((64 * MIB)) "$HYT_R" "$HYT_W"
mk_sshd "$A" 524 0 sshd
printf 'forensics=on\nssh=off\n' > "$A/etc/alpine-proxy-manager/lowmem.conf"
mkdir -p "$A/proc/700" "$A/proc/701"
printf 'Name:\tld-musl-x86_64.\nVmRSS:\t   5120 kB\n' > "$A/proc/700/status"
printf 'Name:\tsshd\nVmRSS:\t   3800 kB\n' > "$A/proc/701/status"
printf 'Name:\tsnell-server\nVmRSS:\t   5600 kB\nSECRET_CMDLINE_SHOULD_NOT_APPEAR\n' > "$A/proc/702-ignored" 2>/dev/null
rm -f "$A/var/log/apm-lowmem.log"
APM_SYSROOT="$A" APM_LOWMEM_ONCE=1 sh "$DAEMON"
log=$(cat "$A/var/log/apm-lowmem.log")
assert_contains "启动记录" "$log" "START "
assert_contains "启动记录含 memory.events" "$log" "oom_kill=38"
assert_contains "启动记录含 sock 与 anon" "$log" "sock=4000000"
assert_not_contains "计数不变时没有 OOM 记录" "$log" "OOM "
APM_SYSROOT="$A" APM_LOWMEM_ONCE=1 APM_LOWMEM_TEST_LAST=30 sh "$DAEMON"
log=$(cat "$A/var/log/apm-lowmem.log")
assert_contains "计数增加时记录 OOM" "$log" "OOM "
assert_contains "OOM 记录含 anon" "$log" "anon=9000000"
assert_contains "OOM 记录含新增计数" "$log" "新增_oom_kill=8"
assert_contains "进程表含进程名与 RSS" "$log" "PROCS "
assert_contains "进程表含 sshd" "$log" "sshd=3800"
assert_contains "进程表含 Snell 的加载器名" "$log" "ld-musl-x86_64.=5120"
assert_not_contains "不记录命令行" "$log" "SECRET_CMDLINE"
assert_contains "心跳记录" "$log" "BEAT "
assert_contains "心跳里的内存当前值没有被时间戳覆盖" "$log" "cur=33554432 sock=4000000"
printf '== 取证: 日志有大小上限并轮转\n'
rm -f "$A/var/log/apm-lowmem.log" "$A/var/log/apm-lowmem.log.1"
i=0
while [ "$i" -lt 12 ]; do APM_SYSROOT="$A" APM_LOWMEM_ONCE=1 APM_LOWMEM_LOGMAX=700 sh "$DAEMON"; i=$((i + 1)); done
assert_ok "产生旧日志" test -f "$A/var/log/apm-lowmem.log.1"
size=$({ wc -c < "$A/var/log/apm-lowmem.log"; } 2>/dev/null || echo 0)
assert_ok "当前日志不超过上限加一条记录" test "$size" -le 1500

printf '== SSH: 常驻进程维护新出现的 sshd\n'
A="$T_TMP/sx"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
mkdir -p "$A/etc/alpine-proxy-manager"
printf 'ssh=on\nssh_adj=-500\nforensics=off\n' > "$A/etc/alpine-proxy-manager/lowmem.conf"
mk_sshd "$A" 900 0 sshd-session
mk_sshd "$A" 901 -700 sshd-session
mk_sshd "$A" 902 0 sleep
APM_SYSROOT="$A" APM_LOWMEM_ONCE=1 sh "$DAEMON"
assert_eq "新出现的 sshd-session 被设置" -500 "$(cat "$A/proc/900/oom_score_adj")"
assert_eq "更低的分数不被抬高" -700 "$(cat "$A/proc/901/oom_score_adj")"
assert_eq "非 sshd 进程不动" 0 "$(cat "$A/proc/902/oom_score_adj")"
assert_contains "登记原值供恢复" "$(cat "$A/run/apm-lowmem/ssh.adj")" "900 0 sshd-session"

# 受管的 Snell (停止状态): 入口在 Snell 管理 的 网络功能 里, 没有受管 Snell 时 TUI 不显示
mk_msnell() {
    mkdir -p "$1/usr/local/bin"
    mk_elf_stub "$1/usr/local/bin/snell-server" "snell-server" || return 1
    mkdir -p "$1/var/lib/alpine-proxy-manager/cores"
    printf 'core=snell\nmanaged=true\n' > "$1/var/lib/alpine-proxy-manager/cores/snell.meta"
}

# ============ 5. 状态总览 (TUI 页面见 test_lowmem_tui.sh) ============
printf '== 状态总览里的一行\n'
A="$T_TMP/tui"
mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W"
out=$(APM_SYSROOT="$A" APM_EUID=0 APM_HOME="$T_ROOT" "$PM" status 2>&1)
assert_contains "状态总览有网络与进程保护一行" "$out" "网络与进程保护：未启用"

# ============ 6. 网络命名空间作用范围 ============
printf '== 作用范围: 同一个 sysctl 文件存在与否不影响分类\n'
# HK-IXP2 (Linux 6.8): 容器里没有 core/rmem_default  tw-home (Linux 7.0): 有  两者都在子用户命名空间里
A="$T_TMP/ns_hk"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" "" userns
out=$(lm status)
assert_contains "HK-IXP2 类 (6.8 无 core/rmem_default, 用户命名空间): 不共享" "$out" "是否与宿主机共享：不共享"
A="$T_TMP/ns_tw"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" core userns
out=$(lm status)
assert_contains "tw-home 类 (7.0 有 core/rmem_default, 用户命名空间): 同样不共享" "$out" "是否与宿主机共享：不共享"
assert_not_contains "不再出现 整台机器 的说法" "$out" "整台机器"
assert_not_contains "不再出现 整机 的说法" "$out" "整机"
A="$T_TMP/ns_id1"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" "" identity
A2="$T_TMP/ns_id2"; mk_lm "$A2" $((128 * MIB)) "$HYT_R" "$HYT_W" core identity
o1=$(lm status | grep "作用范围"); A=$A2; o2=$(lm status | grep "作用范围")
assert_eq "恒等映射下 core 文件有无不改变分类" "$o1" "$o2"
assert_contains "恒等映射: 未确认" "$o1" "是否与宿主机共享：未确认"

printf '== 作用范围: 未确认时不自动修改 TCP\n'
A="$T_TMP/ns_unc"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" "" identity
mk_sshd "$A" 524 0 sshd
out=$(lm enable)
assert_eq "未确认: tcp_rmem 不改" "4096 1048576 128516096" "$(tcp rmem)"
assert_eq "未确认: tcp_wmem 不改" "4096 1048576 128516096" "$(tcp wmem)"
assert_contains "未确认: 仍给出只读诊断" "$out" "偏大"
assert_contains "未确认: 说明默认不自动修改" "$out" "默认不自动修改"
assert_contains "未确认: 提示显式选项" "$out" "--assume-own-netns"
assert_contains "未确认: 其他模块照常" "$out" "SSH 保护：已生效"
assert_not_contains "未确认: 不显示 TCP 已生效" "$out" "TCP 缓冲：已生效"
assert_not_contains "未确认: 原值文件不含 tcp" "$(cat "$A/var/lib/alpine-proxy-manager/lowmem.orig" 2>/dev/null)" "tcp_rmem_orig"
lm disable >/dev/null
printf '== 作用范围: 管理员显式指定后才修改, 并记录\n'
out=$(lm enable --assume-own-netns)
assert_eq "显式指定: tcp_rmem 调整" "4096 131072 6291456" "$(tcp rmem)"
assert_contains "显式指定: 记录" "$(cat "$A/etc/alpine-proxy-manager/lowmem.conf")" "netns_assumed=yes"
assert_contains "显式指定: 详情说明没有独立证据" "$(lm detail)" "没有独立证据"
lm disable >/dev/null
assert_eq "显式指定后恢复原值" "4096 1048576 128516096" "$(tcp rmem)"
out=$(lm enable --bogus)
assert_contains "未知参数" "$out" "未知参数"

printf '== 作用范围: 无法判断 (没有 uid_map)\n'
A="$T_TMP/ns_none"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" core none
out=$(lm status)
assert_contains "无 uid_map: 未确认" "$out" "是否与宿主机共享：未确认"
lm enable >/dev/null
assert_eq "无 uid_map: tcp 不改" "4096 1048576 128516096" "$(tcp rmem)"
printf '== 作用范围: 子用户命名空间但 sysctl 不可写 -> 未确认且不支持\n'
A="$T_TMP/ns_ro"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" "" userns
: > "$A/.deny-sysctl-write"
out=$(lm status)
assert_contains "不可写: 未确认" "$out" "是否与宿主机共享：未确认"
assert_contains "不可写: 不允许修改" "$out" "不允许修改"
printf '== 作用范围: 详情里辅助信息不参与判断\n'
A="$T_TMP/ns_aux"; mk_lm "$A" $((128 * MIB)) "$HYT_R" "$HYT_W" core identity
out=$(lm detail)
assert_contains "辅助信息含容器标记" "$out" "容器标记 lxc"
assert_contains "辅助信息含命名空间标识" "$out" "net:[4026532711]"
assert_contains "辅助信息说明不参与判断" "$out" "不参与判断"

# ============ 7. 可选: Snell 优先牺牲 ============
printf '== Snell 优先牺牲: 只处理 Snell 的 supervise-daemon 的后代\n'
mk_pp() { mk_proc "$1" "$2" "$3" "$5" "$5"; printf '%s\n' "$4" > "$1/proc/$2/oom_score_adj"; }
mk_snellsys() {
    mk_lm "$1" $((64 * MIB)) "$HYT_R" "$HYT_W"
    printf '#!/sbin/openrc-run\n' > "$1/etc/init.d/snell"
    printf '800\n' > "$1/run/snell.pid"
    mk_pp "$1" 800 1 0 supervise-daemo
    mk_pp "$1" 801 800 0 ld-musl-x86_64.
    mk_pp "$1" 802 801 0 snell-helper
    mk_pp "$1" 850 1 0 supervise-daemo
    mk_pp "$1" 851 850 0 sing-box
    mk_pp "$1" 524 1 0 sshd
    mk_pp "$1" 900 1 0 bash
}
A="$T_TMP/sac"; mk_snellsys "$A"
out=$(lm enable)
assert_eq "默认一键启用不动 Snell 进程" 0 "$(cat "$A/proc/801/oom_score_adj")"
assert_contains "状态说明可选项未启用" "$(lm status)" "Snell 优先牺牲（可选）：未启用"
assert_contains "默认设置文件里是关闭" "$(cat "$A/etc/alpine-proxy-manager/lowmem.conf")" "snell_sac=off"
out=$(lm enable --snell-sacrifice)
assert_eq "Snell 主进程提高到 300" 300 "$(cat "$A/proc/801/oom_score_adj")"
assert_eq "Snell 的子进程提高到 300" 300 "$(cat "$A/proc/802/oom_score_adj")"
assert_eq "Snell 的 supervise-daemon 不动" 0 "$(cat "$A/proc/800/oom_score_adj")"
assert_eq "sing-box 的 supervise-daemon 不动" 0 "$(cat "$A/proc/850/oom_score_adj")"
assert_eq "sing-box 进程不动" 0 "$(cat "$A/proc/851/oom_score_adj")"
assert_eq "sshd 不被提高 (只被降低)" -500 "$(cat "$A/proc/524/oom_score_adj")"
assert_eq "其他进程不动" 0 "$(cat "$A/proc/900/oom_score_adj")"
assert_contains "状态已生效" "$out" "Snell 优先牺牲（可选）：已生效（2 个 Snell 进程"
assert_contains "设置文件记录" "$(cat "$A/etc/alpine-proxy-manager/lowmem.conf")" "snell_sac=on"
out=$(lm enable)
assert_contains "再次一键启用沿用该选项" "$(cat "$A/etc/alpine-proxy-manager/lowmem.conf")" "snell_sac=on"
printf '== Snell 优先牺牲: 常驻进程维护重启后的新进程\n'
mk_pp "$A" 803 801 0 snell-helper
APM_SYSROOT="$A" APM_LOWMEM_ONCE=1 sh "$DAEMON"
assert_eq "新出现的 Snell 子进程被设置" 300 "$(cat "$A/proc/803/oom_score_adj")"
assert_eq "常驻进程不碰 sing-box" 0 "$(cat "$A/proc/851/oom_score_adj")"
printf '== Snell 优先牺牲: 关闭后恢复\n'
out=$(lm disable)
assert_eq "801 恢复" 0 "$(cat "$A/proc/801/oom_score_adj")"
assert_eq "802 恢复" 0 "$(cat "$A/proc/802/oom_score_adj")"
assert_eq "803 恢复" 0 "$(cat "$A/proc/803/oom_score_adj")"
assert_contains "报告恢复个数" "$out" "Snell 优先牺牲：已把 3 个进程"
printf '== Snell 优先牺牲: 没有原值记录的进程如实说明 不猜原值\n'
A="$T_TMP/sac_norec"; mk_snellsys "$A"
lm enable --snell-sacrifice >/dev/null
rm -f "$A/run/apm-lowmem/snell.adj"
out=$(lm disable)
assert_contains "无记录: 如实说明" "$out" "但没有原值记录，没有改动"
assert_eq "无记录: 不猜原值 不改" 300 "$(cat "$A/proc/801/oom_score_adj")"
printf '== Snell 优先牺牲: 不适用的环境\n'
A="$T_TMP/sac_nosnell"; mk_lm "$A" $((64 * MIB)) "$HYT_R" "$HYT_W"
out=$(lm enable --snell-sacrifice)
assert_contains "没有 Snell 服务: 说明" "$out" "没有检测到 Snell 服务"
A="$T_TMP/sac_group"; mk_snellsys "$A"
printf '1\n' > "$A/sys/fs/cgroup/memory.oom.group"
out=$(lm enable --snell-sacrifice)
assert_contains "oom.group 为 1: 说明整组终止" "$out" "memory.oom.group 为 1"
assert_eq "oom.group 为 1: 不修改 Snell" 0 "$(cat "$A/proc/801/oom_score_adj")"
assert_eq "oom.group 为 1: 不修改 sshd" 0 "$(cat "$A/proc/524/oom_score_adj")"
assert_not_contains "oom.group 为 1: 不显示 SSH 已生效" "$out" "SSH 保护：已生效"

t_done
