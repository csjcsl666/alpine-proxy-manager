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
assert_contains "报告 cgroup 上限而不是 meminfo" "$out" "内存上限：128 MiB (cgroup-v2)"
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
t_done
