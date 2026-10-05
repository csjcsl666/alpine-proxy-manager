# shellcheck shell=sh
# Core Discovery 通用部分: 文件类型, 状态, 安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy

A="$T_TMP/alpine"
mk_sysroot "$A" alpine
APM_SYSROOT=$A
export APM_SYSROOT

# ---- 文件类型识别 ----
K="$T_TMP/kinds"
mkdir -p "$K"
printf '\177ELF' > "$K/elf"
printf '#!/bin/sh\necho hi\n' > "$K/script"
printf '#!' > "$K/script2"
printf 'just text\n' > "$K/text"
: > "$K/empty"
mkdir "$K/dir"
ln -s elf "$K/link-elf"
ln -s script "$K/link-script"
ln -s no-such "$K/dangling"
ln -s loop2 "$K/loop1"
ln -s loop1 "$K/loop2"
ln -s link-elf "$K/link-link-elf"
assert_eq "ELF 文件头" elf "$(core_file_kind "$K/elf")"
assert_eq "shell 脚本" script "$(core_file_kind "$K/script")"
assert_eq "只有 #! 两字节也是脚本" script "$(core_file_kind "$K/script2")"
assert_eq "普通文本是 unknown" unknown "$(core_file_kind "$K/text")"
assert_eq "空文件是 unknown" unknown "$(core_file_kind "$K/empty")"
assert_eq "目录是 unknown" unknown "$(core_file_kind "$K/dir")"
assert_eq "符号链接指向 ELF" elf "$(core_file_kind "$K/link-elf")"
assert_eq "符号链接指向脚本" script "$(core_file_kind "$K/link-script")"
assert_eq "多层符号链接指向 ELF" elf "$(core_file_kind "$K/link-link-elf")"
assert_eq "悬空链接是 missing" missing "$(core_file_kind "$K/dangling")"
assert_eq "循环链接不卡死" unknown "$(core_file_kind "$K/loop1")"
assert_eq "不存在的路径" missing "$(core_file_kind "$K/nope")"
core_resolve "$K/link-elf"
assert_eq "解析链接标记" yes "$CORE_IS_LINK"
assert_eq "解析链接目标" "$K/elf" "$CORE_RESOLVED"
# 绝对符号链接按 APM_SYSROOT 解析, 与真实系统语义一致
mkdir -p "$A/etc/sing-box/sh" "$A/usr/local/bin"
printf '#!/bin/bash\n' > "$A/etc/sing-box/sh/sing-box.sh"
ln -s /etc/sing-box/sh/sing-box.sh "$A/usr/local/bin/sb"
assert_eq "绝对链接落在 sysroot 内" script "$(core_file_kind "$A/usr/local/bin/sb")"

# ---- 初始状态 ----
assert_eq "初始 Snell 状态" not-installed "$(core_state snell)"
assert_eq "初始 sing-box 状态" not-installed "$(core_state singbox)"
core_discover snell
assert_eq "未安装 deployment" none "$CF_DEPLOYMENT"
assert_eq "未安装 managed" no "$CF_MANAGED"

# ---- ELF 桩 ----
if mk_fake_singbox "$A"; then
    assert_eq "ELF 已安装且无服务 无进程时未运行" stopped "$(core_state singbox)"
    assert_eq "sing-box 版本" 1.13.11 "$(core_version singbox)"
    core_discover singbox
    assert_eq "二进制类型" elf "$CF_BINARY_KIND"
    assert_eq "二进制逻辑路径不含 sysroot" /usr/bin/sing-box "$CF_BINARY"
    assert_eq "无服务时 service 为空" "" "$CF_SERVICE"
    assert_eq "无服务时 running 来源" process "$CF_RUNNING_SOURCE"
    assert_eq "无元数据时是 external" external "$CF_DEPLOYMENT"
    assert_eq "无元数据时未接管" no "$CF_MANAGED"

    # 无 OpenRC 信息时按命令行匹配, comm 不参与判断
    mk_proc "$A" 321 1 sing-box /usr/bin/sing-box run -c /etc/sing-box/config.json
    assert_eq "命令行含二进制路径即运行中" running "$(core_state singbox)"
    rm -rf "$A/proc/321"
    mk_proc "$A" 322 1 sing-box /bin/sleep 100
    assert_eq "只有 comm 等于名字但命令行不同 不算运行" stopped "$(core_state singbox)"
    rm -rf "$A/proc/322"
    mk_proc "$A" 323 1 ld-musl-x86_64. ld-linux-x86-64.so.2 --argv0 /usr/bin/sing-box --preload /lib/libgcompat.so.0 -- /usr/bin/sing-box run
    assert_eq "gcompat 形态 comm 为 ld-musl 仍判为运行中" running "$(core_state singbox)"
    rm -rf "$A/proc/323"
    mk_proc "$A" 324 1 supervise-daemon supervise-daemon sing-box --start /usr/bin/sing-box -- run
    assert_eq "supervise-daemon 自身不算服务进程" stopped "$(core_state singbox)"
    rm -rf "$A/proc/324"

    # ELF 但版本输出无法解析 -> broken
    mk_elf_stub "$A/usr/bin/sing-box" "garbage output" || :
    assert_eq "ELF 给不出版本视为异常" broken "$(core_state singbox)"
    # 文件头是 ELF 但不可执行 -> 版本为空 -> broken, 不崩溃
    printf '\177ELF' > "$A/usr/bin/sing-box"
    chmod -x "$A/usr/bin/sing-box"
    assert_eq "不可执行的 ELF 文件头视为异常" broken "$(core_state singbox)"
    mk_fake_singbox "$A"
else
    t_skip "ELF 桩只支持 x86_64, 跳过需要真实执行的断言"
fi

# ---- 非 ELF 一律不执行 ----
M="$T_TMP/marker"
mkdir -p "$M"
rm -f "$A/usr/bin/sing-box"
mk_script_bin "$A/usr/bin/snell-server" "$M"
assert_eq "脚本 snell-server 状态为未确认" unverified "$(core_state snell)"
assert_fail "脚本 snell-server 未被执行" test -e "$M/SHOULD_NOT_EXIST"
core_discover snell
assert_eq "脚本入口 installed" unverified "$CF_INSTALLED"
assert_eq "脚本入口类型" script "$CF_BINARY_KIND"
assert_eq "脚本入口无版本" "" "$CF_VERSION_REPORTED"
assert_contains "脚本入口提示" "$CF_NOTES" "不是已确认的 ELF"
assert_eq "脚本入口 deployment" external "$CF_DEPLOYMENT"
printf 'random bytes here\n' > "$A/usr/bin/snell-server"
chmod +x "$A/usr/bin/snell-server"
assert_eq "无法识别的可执行文件状态" unverified "$(core_state snell)"
rm -f "$A/usr/bin/snell-server"

# 233boy 形态: /usr/local/bin/sing-box 是指向 bash 管理脚本的符号链接
rm -rf "$A/usr/local/bin" "$A/etc/sing-box"
mkdir -p "$A/usr/local/bin" "$A/etc/sing-box/sh"
printf '#!/bin/bash\ntouch "%s/SHOULD_NOT_EXIST"\n' "$M" > "$A/etc/sing-box/sh/sing-box.sh"
chmod +x "$A/etc/sing-box/sh/sing-box.sh"
ln -s /etc/sing-box/sh/sing-box.sh "$A/usr/local/bin/sing-box"
ln -s /etc/sing-box/sh/sing-box.sh "$A/usr/local/bin/sb"
assert_eq "指向脚本的 sing-box 链接状态" unverified "$(core_state singbox)"
assert_fail "指向脚本的链接未被执行" test -e "$M/SHOULD_NOT_EXIST"
core_discover singbox
assert_eq "链接标记" yes "$CF_BINARY_LINK"
assert_eq "链接类型" script "$CF_BINARY_KIND"
assert_contains "实际路径 (逻辑路径) 被报告" "$CF_BINARY_REAL" "/etc/sing-box/sh/sing-box.sh"
assert_fail "sing-box version 不会被取得" core_version singbox
assert_fail "校验配置拒绝执行脚本入口" core_singbox_check_config "$T_TMP/x.json"
assert_fail "校验配置没有执行脚本" test -e "$M/SHOULD_NOT_EXIST"
out=$("$T_ROOT/bin/proxy-manager" core list)
assert_contains "core list 说明未确认" "$out" "未确认"
assert_contains "core list 解释原因" "$out" "不是已确认的 ELF"
assert_fail "core list 没有执行脚本" test -e "$M/SHOULD_NOT_EXIST"
out=$("$T_ROOT/bin/proxy-manager" doctor)
assert_contains "doctor 报告未确认" "$out" "sing-box：Unverified"
assert_fail "doctor 没有执行脚本" test -e "$M/SHOULD_NOT_EXIST"
out=$("$T_ROOT/bin/proxy-manager" status)
assert_contains "status 报告未确认" "$out" "未确认"
assert_fail "status 没有执行脚本" test -e "$M/SHOULD_NOT_EXIST"
rm -rf "$A/usr/local/bin" "$A/etc/sing-box"
mkdir -p "$A/usr/local/bin"

# 脚本入口在固定目录, 同时 OpenRC 的 command 指向真正的 ELF (tw-home 形态)
if mk_elf_stub "$A/etc/sing-box-real" "sing-box version 1.13.11"; then
    mkdir -p "$A/etc/sing-box/sh" "$A/etc/init.d"
    printf '#!/bin/bash\ntouch "%s/SHOULD_NOT_EXIST"\n' "$M" > "$A/etc/sing-box/sh/sing-box.sh"
    chmod +x "$A/etc/sing-box/sh/sing-box.sh"
    ln -s /etc/sing-box/sh/sing-box.sh "$A/usr/local/bin/sing-box"
    printf '#!/sbin/openrc-run\ncommand="/etc/sing-box-real"\nsupervisor=supervise-daemon\n' > "$A/etc/init.d/sing-box"
    core_discover singbox
    assert_eq "OpenRC command 指向的 ELF 被采用" /etc/sing-box-real "$CF_BINARY"
    assert_eq "采用后版本来自 ELF" 1.13.11 "$CF_VERSION_REPORTED"
    assert_contains "被忽略的脚本入口有提示" "$CF_NOTES" "/usr/local/bin/sing-box"
    assert_fail "脚本仍未被执行" test -e "$M/SHOULD_NOT_EXIST"
    rm -rf "$A/etc/sing-box" "$A/etc/sing-box-real" "$A/etc/init.d/sing-box" "$A/usr/local/bin/sing-box"
fi

# ---- 生命周期仍未实现 ----
assert_rc "未实现操作返回 3" 3 core_op snell install
assert_rc "未知 Core 返回 2" 2 core_op both install
assert_rc "core 未知子命令返回 2" 2 "$T_ROOT/bin/proxy-manager" core nope

# ---- sing-box check 作为 validator ----
if mk_fake_singbox "$A"; then
    echo valid > "$T_TMP/ok.json"
    assert_ok "ELF 的 check 可调用" core_singbox_check_config "$T_TMP/ok.json"
fi

# ---- 摘要块 ----
out=$("$T_ROOT/bin/proxy-manager" core list)
assert_contains "list 含 Snell" "$out" "Snell"
assert_contains "list 含 sing-box" "$out" "sing-box"
t_done
