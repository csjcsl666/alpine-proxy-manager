# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
PM="$T_ROOT/bin/proxy-manager"

A="$T_TMP/alpine"
mk_sysroot "$A" alpine
echo 134217728 > "$A/sys/fs/cgroup/memory.max"
echo 100000000 > "$A/sys/fs/cgroup/memory.current"
export APM_SYSROOT="$A" APM_EUID=0 APM_ARCH=x86_64

snapshot() { (cd "$A" && find . | sort && find . -type f | sort | xargs cksum); }
before=$(snapshot)
out=$("$PM" doctor)
rc=$?
after=$(snapshot)
assert_eq "全部满足时退出码 0" 0 "$rc"
assert_contains "Alpine OK" "$out" "Alpine Linux：OK (3.24.1)"
assert_contains "OpenRC OK" "$out" "OpenRC：OK"
assert_contains "root OK" "$out" "root：OK"
assert_contains "架构" "$out" "架构：x86_64"
assert_contains "报告 cgroup 上限而不是 meminfo" "$out" "内存上限：128 MiB (cgroup v2)"
assert_contains "当前内存" "$out" "当前内存：95 MiB (cgroup memory.current"
assert_contains "swap" "$out" "swap：未启用"
assert_contains "Snell 未安装" "$out" "Snell：Not installed"
assert_contains "sing-box 未安装" "$out" "sing-box：Not installed"
assert_contains "sing-box version 占位" "$out" "sing-box version：-"
assert_eq "doctor 不修改文件系统" "$before" "$after"
assert_fail "doctor 不创建配置目录" test -e "$A/etc/alpine-proxy-manager"

mk_fake_singbox "$A"
out=$("$PM" doctor)
assert_contains "sing-box Installed" "$out" "sing-box：Installed"
assert_contains "sing-box 版本" "$out" "sing-box version：1.13.11"

# 非 root 仅 WARN
out=$(APM_EUID=1000 "$PM" doctor)
rc=$?
assert_eq "非 root 不影响退出码" 0 "$rc"
assert_contains "非 root WARN" "$out" "root：WARN"

# 非 Alpine 为 FAIL 且退出码 1
D="$T_TMP/debian"
mk_sysroot "$D" debian
out=$(APM_SYSROOT="$D" "$PM" doctor)
rc=$?
assert_eq "非 Alpine 退出码 1" 1 "$rc"
assert_contains "非 Alpine FAIL" "$out" "Alpine Linux：FAIL"
assert_contains "无 OpenRC FAIL" "$out" "OpenRC：FAIL"

# 低于 64 MiB 基线
echo 33554432 > "$A/sys/fs/cgroup/memory.max"
out=$("$PM" doctor)
assert_contains "64 MiB 基线 WARN" "$out" "64 MiB 基线：WARN"

# ---- HK-IXP2 回归: LXCFS 虚拟化使 MemTotal 等于 memory.max ----
H="$T_TMP/hk"
mk_sysroot "$H" alpine
printf 'MemTotal: 125000 kB\nMemFree: 114472 kB\nMemAvailable: 119122 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$H/proc/meminfo"
echo 128000000 > "$H/sys/fs/cgroup/memory.max"
echo 10870784 > "$H/sys/fs/cgroup/memory.current"
printf 'anon 4046848\nfile 4464640\n' > "$H/sys/fs/cgroup/memory.stat"
echo 0 > "$H/sys/fs/cgroup/memory.swap.max"
echo '0::/openrc.sshd' > "$H/proc/self/cgroup"
mkdir -p "$H/sys/fs/cgroup/openrc.sshd"
echo max > "$H/sys/fs/cgroup/openrc.sshd/memory.max"
echo 1234567 > "$H/sys/fs/cgroup/openrc.sshd/memory.current"
out=$(APM_SYSROOT="$H" "$PM" doctor)
assert_contains "HK-IXP2: 内存上限与来源" "$out" "内存上限：122 MiB (cgroup v2)"
assert_not_contains "HK-IXP2: 不再声称未检测到 cgroup 限制" "$out" "未检测到"
assert_not_contains "HK-IXP2: 来源不是 meminfo" "$out" "内存上限：122 MiB (/proc/meminfo"
assert_contains "HK-IXP2: 当前取外层 cgroup 而不是子服务 cgroup" "$out" "当前内存：10 MiB (cgroup memory.current, 含页缓存)"
assert_contains "HK-IXP2: 匿名内存" "$out" "其中匿名内存：3 MiB"
assert_contains "HK-IXP2: swap 由 cgroup 限制为 0" "$out" "swap：未启用 (cgroup memory.swap.max 为 0)"
assert_contains "HK-IXP2: 64 MiB 基线 OK" "$out" "64 MiB 基线：OK"

# 来源措辞: 无 cgroup, 无数值上限, cgroup 更宽松
N="$T_TMP/nocg"
mk_sysroot "$N" alpine
out=$(APM_SYSROOT="$N" "$PM" doctor)
assert_contains "无 cgroup 的措辞" "$out" "/proc/meminfo, 未找到 cgroup 内存控制器"
assert_contains "无 cgroup 时当前内存来自 meminfo" "$out" "当前内存：438 MiB (/proc/meminfo 已用"
echo max > "$N/sys/fs/cgroup/memory.max"
out=$(APM_SYSROOT="$N" "$PM" doctor)
assert_contains "cgroup 无数值上限的措辞" "$out" "/proc/meminfo, cgroup 无数值上限"
echo 2147483648 > "$N/sys/fs/cgroup/memory.max"
out=$(APM_SYSROOT="$N" "$PM" doctor)
assert_contains "cgroup 更宽松的措辞" "$out" "cgroup 限制 2048 MiB 更宽松"

# swap 有真实数值时显示来源
printf 'MemTotal: 1048576 kB\nMemAvailable: 600000 kB\nSwapTotal: 262144 kB\nSwapFree: 131072 kB\n' > "$N/proc/meminfo"
out=$(APM_SYSROOT="$N" "$PM" doctor)
assert_contains "swap 数值与来源" "$out" "swap：128 MiB / 256 MiB (空闲 / 总计, meminfo)"

# 异常 cgroup 内容时 doctor 不崩溃
printf 'garbage\n' > "$N/sys/fs/cgroup/memory.max"
APM_SYSROOT="$N" "$PM" doctor >/dev/null 2>&1
assert_eq "异常 cgroup 内容 doctor 退出码 0" 0 $?
t_done
