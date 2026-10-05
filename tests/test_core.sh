# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy

A="$T_TMP/alpine"
mk_sysroot "$A" alpine
APM_SYSROOT=$A
export APM_SYSROOT

assert_eq "初始 Snell 状态" "not-installed" "$(core_state snell)"
assert_eq "初始 sing-box 状态" "not-installed" "$(core_state singbox)"

mk_fake_singbox "$A"
assert_eq "已安装未运行" "stopped" "$(core_state singbox)"
assert_eq "sing-box 版本" "1.13.11" "$(core_version singbox)"

mkdir -p "$A/proc/321"
echo sing-box > "$A/proc/321/comm"
assert_eq "进程存在即运行中" "running" "$(core_state singbox)"
assert_eq "Snell 不受 sing-box 进程影响" "not-installed" "$(core_state snell)"

# 二进制存在但无法给出版本 -> broken
printf '#!/bin/sh\nexit 1\n' > "$A/usr/bin/sing-box"
assert_eq "无法执行 version 视为异常" "broken" "$(core_state singbox)"

# Snell 独立安装, 与 sing-box 互不影响
printf '#!/bin/sh\n' > "$A/usr/bin/snell-server"
chmod +x "$A/usr/bin/snell-server"
assert_eq "Snell 已安装未运行" "stopped" "$(core_state snell)"
assert_fail "Snell 版本方式未调查, 不猜测" core_version snell
mkdir -p "$A/proc/400"
echo snell-server > "$A/proc/400/comm"
assert_eq "Snell 运行中" "running" "$(core_state snell)"

# 不可执行的同名文件不算已安装
rm -f "$A/usr/bin/snell-server"
printf 'x' > "$A/usr/bin/snell-server"
assert_fail "不可执行文件不算安装" core_installed snell

# 生命周期未实现
assert_rc "未实现操作返回 3" 3 core_op snell install
assert_rc "未知 Core 返回 2" 2 core_op both install

# list 输出
mk_fake_singbox "$A"
out=$("$T_ROOT/bin/proxy-manager" core list)
assert_contains "list 含 Snell" "$out" "Snell"
assert_contains "list 含 sing-box 版本" "$out" "1.13.11"
assert_rc "core 未知子命令返回 2" 2 "$T_ROOT/bin/proxy-manager" core nope

# status
out=$(APM_SYSROOT=$A "$T_ROOT/bin/proxy-manager" status)
assert_contains "status 含 Core 段" "$out" "Core"
assert_contains "status 含 Server SOCKS Egress" "$out" "Server SOCKS Egress"
assert_contains "status 未配置" "$out" "未配置"

# sing-box check 作为 validator
echo 'valid' > "$T_TMP/ok.json"
echo 'broken' > "$T_TMP/bad.json"
mk_fake_singbox "$A"
assert_ok "check 通过" core_singbox_check_config "$T_TMP/ok.json"
assert_fail "check 失败" core_singbox_check_config "$T_TMP/bad.json"
t_done
