# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment

A="$T_TMP/alpine"
D="$T_TMP/debian"
mk_sysroot "$A" alpine
mk_sysroot "$D" debian

APM_SYSROOT=$A
assert_ok "Alpine 被识别" env_is_alpine
assert_eq "Alpine 版本" "3.24.1" "$(env_alpine_version)"
assert_ok "OpenRC 被识别" env_has_openrc
APM_SYSROOT=$D
assert_fail "Debian 不被识别为 Alpine" env_is_alpine
assert_fail "无 OpenRC" env_has_openrc

# os-release 与 alpine-release 矛盾时拒绝
APM_SYSROOT=$A
printf 'ID=ubuntu\n' > "$A/etc/os-release"
assert_fail "os-release 非 alpine 时拒绝" env_is_alpine
printf 'ID=alpine\n' > "$A/etc/os-release"

APM_EUID=0
assert_ok "uid 0 是 root" env_is_root
APM_EUID=1000
assert_fail "uid 1000 不是 root" env_is_root

APM_ARCH=aarch64
assert_ok "aarch64 已知" env_arch_known
APM_ARCH=riscv64
assert_fail "riscv64 未验证" env_arch_known
assert_eq "架构覆盖" "riscv64" "$(env_arch)"

# 内存: 无 cgroup 时使用 meminfo
APM_SYSROOT=$A
env_probe_memory
assert_eq "meminfo 上限" "1073741824" "$ENV_MEM_LIMIT"
assert_eq "meminfo 来源" "meminfo" "$ENV_MEM_LIMIT_SRC"
assert_eq "meminfo 当前=总量-可用" "$(( (1048576 - 600000) * 1024 ))" "$ENV_MEM_CUR"

# cgroup v2, 128 MiB
echo 134217728 > "$A/sys/fs/cgroup/memory.max"
echo 100000000 > "$A/sys/fs/cgroup/memory.current"
printf 'anon 41943040\nfile 1000\n' > "$A/sys/fs/cgroup/memory.stat"
env_probe_memory
assert_eq "cgroup v2 上限优先" "134217728" "$ENV_MEM_LIMIT"
assert_eq "cgroup v2 来源" "cgroup-v2" "$ENV_MEM_LIMIT_SRC"
assert_eq "cgroup v2 当前" "100000000" "$ENV_MEM_CUR"
assert_eq "cgroup v2 anon" "41943040" "$ENV_MEM_ANON"

# max 视为未限制
echo max > "$A/sys/fs/cgroup/memory.max"
env_probe_memory
assert_eq "memory.max=max 回退 meminfo" "meminfo" "$ENV_MEM_LIMIT_SRC"

# 上限大于物理内存视为未限制
echo 9223372036854771712 > "$A/sys/fs/cgroup/memory.max"
env_probe_memory
assert_eq "超大上限回退 meminfo" "meminfo" "$ENV_MEM_LIMIT_SRC"
rm -f "$A/sys/fs/cgroup/memory.max" "$A/sys/fs/cgroup/memory.current" "$A/sys/fs/cgroup/memory.stat"

# 通过 /proc/self/cgroup 定位子 cgroup
mkdir -p "$A/sys/fs/cgroup/vps1"
echo 67108864 > "$A/sys/fs/cgroup/vps1/memory.max"
echo 1000 > "$A/sys/fs/cgroup/vps1/memory.current"
echo '0::/vps1' > "$A/proc/self/cgroup"
env_probe_memory
assert_eq "子 cgroup 上限" "67108864" "$ENV_MEM_LIMIT"
rm -rf "$A/sys/fs/cgroup/vps1" "$A/proc/self/cgroup"

# cgroup v1
mkdir -p "$A/sys/fs/cgroup/memory"
echo 100663296 > "$A/sys/fs/cgroup/memory/memory.limit_in_bytes"
echo 5000 > "$A/sys/fs/cgroup/memory/memory.usage_in_bytes"
env_probe_memory
assert_eq "cgroup v1 上限" "100663296" "$ENV_MEM_LIMIT"
assert_eq "cgroup v1 来源" "cgroup-v1" "$ENV_MEM_LIMIT_SRC"
rm -rf "$A/sys/fs/cgroup/memory"

# swap
printf 'MemTotal: 1048576 kB\nMemAvailable: 600000 kB\nSwapTotal: 262144 kB\nSwapFree: 131072 kB\n' > "$A/proc/meminfo"
env_probe_memory
assert_eq "swap 总量" "268435456" "$ENV_SWAP_TOTAL"
assert_eq "swap 空闲" "134217728" "$ENV_SWAP_FREE"

t_done
