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

# ---- 内存与 cgroup ----
CG=$A/sys/fs/cgroup
MIB=1048576

# reset_cg [MemTotal kB] [SwapTotal kB], 清空 cgroup 与 /proc/self/cgroup 并重写 meminfo
reset_cg() {
    rm -rf "$CG" "$A/proc/self/cgroup"
    mkdir -p "$CG"
    printf 'MemTotal: %s kB\nMemFree: 1000 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' \
        "${1:-1048576}" "$((${1:-1048576} / 2))" "${2:-0}" "${2:-0}" > "$A/proc/meminfo"
}
APM_SYSROOT=$A

# D 没有任何 cgroup 文件: 安全回退 meminfo
reset_cg
env_probe_memory
assert_eq "D 无 cgroup: 上限取 MemTotal" "$((1048576 * 1024))" "$ENV_MEM_LIMIT"
assert_eq "D 无 cgroup: 来源 meminfo" meminfo "$ENV_MEM_LIMIT_SRC"
assert_eq "D 无 cgroup: ENV_CG_VER" none "$ENV_CG_VER"
assert_eq "D 无 cgroup: 无 cgroup 上限" "" "$ENV_CG_LIMIT"
assert_eq "D 无 cgroup: 当前为总量减可用" "$((1048576 * 1024 / 2))" "$ENV_MEM_CUR"
assert_eq "D 无 cgroup: 当前来源" meminfo "$ENV_MEM_CUR_SRC"
assert_eq "D 无 cgroup: swap 来源" meminfo "$ENV_SWAP_SRC"

# A MemTotal 256 MiB, memory.max 128 MiB
reset_cg 262144
echo $((128 * MIB)) > "$CG/memory.max"
env_probe_memory
assert_eq "A cgroup 更小: 有效上限" "$((128 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "A cgroup 更小: 来源" cgroup-v2 "$ENV_MEM_LIMIT_SRC"
assert_eq "A cgroup 更小: 检测到的上限" "$((128 * MIB))" "$ENV_CG_LIMIT"
assert_eq "A cgroup 更小: MemTotal 保持不变" "$((256 * MIB))" "$ENV_MEM_TOTAL"

# B HK-IXP2 真机 bug: MemTotal 与 memory.max 完全相等 (LXCFS 虚拟化)
reset_cg 125000
echo 128000000 > "$CG/memory.max"
env_probe_memory
assert_eq "B 相等: 有效上限" 128000000 "$ENV_MEM_LIMIT"
assert_eq "B 相等: 来源必须是 cgroup" cgroup-v2 "$ENV_MEM_LIMIT_SRC"
assert_eq "B 相等: 保留检测到的 cgroup 上限" 128000000 "$ENV_CG_LIMIT"
assert_eq "B 相等: ENV_CG_VER" v2 "$ENV_CG_VER"

# C memory.max=max: 无数值上限, 仍知道有 cgroup v2
reset_cg 131072
echo max > "$CG/memory.max"
env_probe_memory
assert_eq "C max: 有效上限取 MemTotal" "$((128 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "C max: 来源 meminfo" meminfo "$ENV_MEM_LIMIT_SRC"
assert_eq "C max: 无数值上限" "" "$ENV_CG_LIMIT"
assert_eq "C max: 仍识别出 cgroup v2" v2 "$ENV_CG_VER"

# cgroup 上限大于 MemTotal: 有效上限是 MemTotal, 但保留 cgroup 信息
reset_cg 1048576
echo $((2048 * MIB)) > "$CG/memory.max"
env_probe_memory
assert_eq "宽松 cgroup: 有效上限取 MemTotal" "$((1024 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "宽松 cgroup: 来源 meminfo" meminfo "$ENV_MEM_LIMIT_SRC"
assert_eq "宽松 cgroup: 保留检测到的上限" "$((2048 * MIB))" "$ENV_CG_LIMIT"

# E memory.current 存在时优先
reset_cg 125000
echo 128000000 > "$CG/memory.max"
echo 10870784 > "$CG/memory.current"
printf 'anon 4046848\nfile 4464640\n' > "$CG/memory.stat"
env_probe_memory
assert_eq "E current: 取 memory.current" 10870784 "$ENV_MEM_CUR"
assert_eq "E current: 来源 cgroup" cgroup "$ENV_MEM_CUR_SRC"
assert_eq "E current: anon" 4046848 "$ENV_MEM_ANON"
rm -f "$CG/memory.current" "$CG/memory.stat"
env_probe_memory
assert_eq "E 无 memory.current: 回退 meminfo" meminfo "$ENV_MEM_CUR_SRC"
assert_eq "E 无 memory.stat: anon 为空" "" "$ENV_MEM_ANON"
echo 0 > "$CG/memory.current"
env_probe_memory
assert_eq "E memory.current 为 0 也有效" 0 "$ENV_MEM_CUR"

# 无数值上限但处在容器级 cgroup 根 (根下有 memory.current): 用 cgroup 的当前用量
reset_cg 131072
echo max > "$CG/memory.max"
echo 5000000 > "$CG/memory.current"
env_probe_memory
assert_eq "无上限但有 memory.current: 取 cgroup 用量" 5000000 "$ENV_MEM_CUR"
rm -f "$CG/memory.current"
env_probe_memory
assert_eq "无上限且无 memory.current: 回退 meminfo" meminfo "$ENV_MEM_CUR_SRC"

# F swap
reset_cg 125000 262144
echo 128000000 > "$CG/memory.max"
echo 0 > "$CG/memory.swap.max"
env_probe_memory
assert_eq "F swap.max=0: 可用 swap 为 0" 0 "$ENV_SWAP_TOTAL"
assert_eq "F swap.max=0: 空闲为 0" 0 "$ENV_SWAP_FREE"
assert_eq "F swap.max=0: 来源 cgroup" cgroup-v2 "$ENV_SWAP_SRC"
assert_eq "F swap.max=0: 记录原值" 0 "$ENV_SWAP_CG_MAX"
echo max > "$CG/memory.swap.max"
env_probe_memory
assert_eq "swap.max=max: 保留 meminfo 总量" "$((256 * MIB))" "$ENV_SWAP_TOTAL"
assert_eq "swap.max=max: 来源 meminfo" meminfo "$ENV_SWAP_SRC"
echo $((64 * MIB)) > "$CG/memory.swap.max"
env_probe_memory
assert_eq "swap.max 小于 meminfo: 取 swap.max" "$((64 * MIB))" "$ENV_SWAP_TOTAL"
assert_eq "swap.max 小于 meminfo: 空闲不超过总量" "$((64 * MIB))" "$ENV_SWAP_FREE"
rm -f "$CG/memory.swap.max"
env_probe_memory
assert_eq "无 swap.max: 保留 meminfo" "$((256 * MIB))" "$ENV_SWAP_TOTAL"
reset_cg 125000 0
echo 7 > "$CG/memory.swap.max"
env_probe_memory
assert_eq "meminfo 无 swap 时 swap.max 不会凭空增加" 0 "$ENV_SWAP_TOTAL"

# G 异常内容不得崩溃, 也不得被当成上限
for bad in '' abc -5 99999999999999999999 '12 34' 0x10; do
    reset_cg 131072
    printf '%s\n' "$bad" > "$CG/memory.max"
    printf '%s\n' "$bad" > "$CG/memory.current"
    printf '%s\n' "$bad" > "$CG/memory.swap.max"
    printf 'garbage\nanon\nanon xyz\n' > "$CG/memory.stat"
    env_probe_memory
    assert_eq "G 异常内容 [$bad]: 回退 MemTotal" "$((128 * MIB))" "$ENV_MEM_LIMIT"
    assert_eq "G 异常内容 [$bad]: 来源 meminfo" meminfo "$ENV_MEM_LIMIT_SRC"
    assert_eq "G 异常内容 [$bad]: 当前回退 meminfo" meminfo "$ENV_MEM_CUR_SRC"
    assert_eq "G 异常内容 [$bad]: anon 为空" "" "$ENV_MEM_ANON"
    assert_eq "G 异常内容 [$bad]: swap 回退" meminfo "$ENV_SWAP_SRC"
done
# memory.max=0 不是有效上限, 但 memory.current 与 swap.max 的 0 是合法值
reset_cg 131072
echo 0 > "$CG/memory.max"
env_probe_memory
assert_eq "memory.max=0 被忽略" meminfo "$ENV_MEM_LIMIT_SRC"
reset_cg 131072
rm -f "$A/proc/meminfo"
env_probe_memory
assert_eq "meminfo 缺失不崩溃" 0 "$ENV_MEM_TOTAL"
reset_cg 131072
echo $((64 * MIB)) > "$CG/memory.max"
rm -f "$A/proc/meminfo"
env_probe_memory
assert_eq "meminfo 缺失时用 cgroup 上限" "$((64 * MIB))" "$ENV_MEM_LIMIT"

# ---- 父级 cgroup ----
mkdir_cg() { mkdir -p "$CG/$1"; }
# 父级 128 MiB, 子级 max: 父级限制生效, 当前用量取限制所在层
reset_cg 1048576
mkdir_cg a/b
echo '0::/a/b' > "$A/proc/self/cgroup"
echo $((128 * MIB)) > "$CG/memory.max"
echo 111 > "$CG/memory.current"
echo max > "$CG/a/b/memory.max"
echo 222 > "$CG/a/b/memory.current"
env_probe_memory
assert_eq "父 128 子 max: 取父级" "$((128 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "父 128 子 max: 来源 cgroup" cgroup-v2 "$ENV_MEM_LIMIT_SRC"
assert_eq "父 128 子 max: 当前取限制所在层" 111 "$ENV_MEM_CUR"
# 父级 256, 子级 128: 取更严格的子级
echo $((256 * MIB)) > "$CG/memory.max"
echo $((128 * MIB)) > "$CG/a/b/memory.max"
env_probe_memory
assert_eq "父 256 子 128: 取子级" "$((128 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "父 256 子 128: 当前取子级" 222 "$ENV_MEM_CUR"
# 中间层最严格
echo max > "$CG/memory.max"
echo $((32 * MIB)) > "$CG/a/memory.max"
echo 333 > "$CG/a/memory.current"
env_probe_memory
assert_eq "中间层最严格" "$((32 * MIB))" "$ENV_MEM_LIMIT"
assert_eq "中间层最严格: 当前取该层" 333 "$ENV_MEM_CUR"
# 各层相等: 取最外层, 它代表整体用量
echo $((128 * MIB)) > "$CG/memory.max"
echo $((128 * MIB)) > "$CG/a/memory.max"
echo $((128 * MIB)) > "$CG/a/b/memory.max"
env_probe_memory
assert_eq "各层相等: 当前取最外层" 111 "$ENV_MEM_CUR"
# 全部 max: 无数值上限
echo max > "$CG/memory.max"
echo max > "$CG/a/memory.max"
echo max > "$CG/a/b/memory.max"
env_probe_memory
assert_eq "全部 max: 无数值上限" "" "$ENV_CG_LIMIT"
assert_eq "全部 max: 有效上限 MemTotal" "$((1024 * MIB))" "$ENV_MEM_LIMIT"
# 子级路径不存在 (不可读层级): 跳过并仍应用父级
reset_cg 1048576
echo '0::/x/y/z' > "$A/proc/self/cgroup"
echo $((64 * MIB)) > "$CG/memory.max"
env_probe_memory
assert_eq "路径不存在: 仍应用可读的父级" "$((64 * MIB))" "$ENV_MEM_LIMIT"
# 路径为 / 与缺失
echo '0::/' > "$A/proc/self/cgroup"
env_probe_memory
assert_eq "路径为 /: 取根" "$((64 * MIB))" "$ENV_MEM_LIMIT"
rm -f "$A/proc/self/cgroup"
env_probe_memory
assert_eq "无 /proc/self/cgroup: 取根" "$((64 * MIB))" "$ENV_MEM_LIMIT"
# 含 v1 控制器行的 hybrid 内容只认 0:: 行
printf '12:memory:/old\n0::/a/b\n' > "$A/proc/self/cgroup"
mkdir_cg a/b
echo $((16 * MIB)) > "$CG/a/b/memory.max"
env_probe_memory
assert_eq "只解析 0:: 行" "$((16 * MIB))" "$ENV_MEM_LIMIT"
# 父级 swap 限制
reset_cg 1048576 262144
mkdir_cg a/b
echo '0::/a/b' > "$A/proc/self/cgroup"
echo 0 > "$CG/memory.swap.max"
echo max > "$CG/a/b/memory.swap.max"
env_probe_memory
assert_eq "父级 swap.max=0 生效" 0 "$ENV_SWAP_TOTAL"
assert_eq "父级 swap.max=0 来源" cgroup-v2 "$ENV_SWAP_SRC"

# ---- cgroup v1 ----
reset_cg 98304
V1=$CG/memory
mkdir -p "$V1"
echo 100663296 > "$V1/memory.limit_in_bytes"
echo 5000 > "$V1/memory.usage_in_bytes"
printf 'rss 1234\n' > "$V1/memory.stat"
env_probe_memory
assert_eq "v1 与 MemTotal 相等: 来源 cgroup-v1" cgroup-v1 "$ENV_MEM_LIMIT_SRC"
assert_eq "v1 当前" 5000 "$ENV_MEM_CUR"
assert_eq "v1 anon 取 rss" 1234 "$ENV_MEM_ANON"
assert_eq "v1 ENV_CG_VER" v1 "$ENV_CG_VER"
echo $((64 * MIB)) > "$V1/memory.limit_in_bytes"
env_probe_memory
assert_eq "v1 更小的上限" "$((64 * MIB))" "$ENV_MEM_LIMIT"
echo 9223372036854771712 > "$V1/memory.limit_in_bytes"
env_probe_memory
assert_eq "v1 无限制哨兵值: 来源 meminfo" meminfo "$ENV_MEM_LIMIT_SRC"
assert_eq "v1 无限制哨兵值: 无数值上限" "" "$ENV_CG_LIMIT"
assert_eq "v1 无限制哨兵值: 仍识别 v1" v1 "$ENV_CG_VER"

# swap 的 meminfo 路径
reset_cg 1048576 262144
printf 'MemTotal: 1048576 kB\nMemAvailable: 600000 kB\nSwapTotal: 262144 kB\nSwapFree: 131072 kB\n' > "$A/proc/meminfo"
env_probe_memory
assert_eq "swap 总量" "$((256 * MIB))" "$ENV_SWAP_TOTAL"
assert_eq "swap 空闲" "$((128 * MIB))" "$ENV_SWAP_FREE"

t_done
