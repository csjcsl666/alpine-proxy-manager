# shellcheck shell=sh
# sing-box Managed Core 完整生命周期 (不含协议实例, 实例见 test_singbox_anytls.sh)
# 二进制是真实的 ELF, 行为由 sidecar 脚本模拟 version check generate, 服务由模拟的 rc-service 提供
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox.sh 全部跳过"
    t_done
    exit $?
fi

# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

# ---- install 成功 ----
new_s i1
OUT=$("$PM" sing-box install 2>&1)
RC=$?
assert_eq "install 成功" 0 "$RC"
assert_contains "install 输出完成" "$OUT" "sing-box 安装完成并已验证"
assert_contains "install 输出 release" "$OUT" "release：v1.13.14 (二进制自报 1.13.14)"
assert_eq "二进制是 ELF" elf "$(core_file_kind "$A/usr/local/bin/sing-box")"
assert_eq "二进制权限" 755 "$(stat -c %a "$A/usr/local/bin/sing-box")"
assert_eq "配置根权限" 750 "$(stat -c %a "$A/etc/sing-box")"
assert_eq "配置权限" 640 "$(stat -c %a "$A/etc/sing-box/config.json")"
assert_eq "tls 目录权限" 750 "$(stat -c %a "$A/etc/sing-box/tls")"
assert_eq "日志目录权限" 750 "$(stat -c %a "$A/var/log/sing-box")"
assert_eq "工作目录权限" 750 "$(stat -c %a "$A/var/lib/sing-box")"
assert_contains "配置属主" "$(cat "$A/.chown.log")" "root:sing-box /etc/sing-box"
assert_contains "日志属主" "$(cat "$A/.chown.log")" "sing-box:sing-box /var/log/sing-box"
assert_contains "生成的配置含 direct 出站" "$(cat "$A/etc/sing-box/config.json")" '"type": "direct"'
assert_contains "生成的配置没有实例时 inbounds 为空" "$(cat "$A/etc/sing-box/config.json")" '"inbounds": []'
assert_contains "日志级别为 warn" "$(cat "$A/etc/sing-box/config.json")" '"level": "warn"'
assert_contains "服务脚本有 Manager 标记" "$(cat "$A/etc/init.d/sing-box")" "# apm-managed: sing-box"
assert_contains "服务脚本是 openrc-run" "$(head -n 1 "$A/etc/init.d/sing-box")" "openrc-run"
assert_contains "服务脚本使用 supervise-daemon" "$(cat "$A/etc/init.d/sing-box")" 'supervisor="supervise-daemon"'
assert_contains "服务脚本启动前 check" "$(cat "$A/etc/init.d/sing-box")" "/usr/local/bin/sing-box check -c /etc/sing-box/config.json"
assert_contains "服务脚本指定配置" "$(cat "$A/etc/init.d/sing-box")" "-c /etc/sing-box/config.json"
assert_contains "服务脚本使用专用用户" "$(cat "$A/etc/init.d/sing-box")" 'command_user="sing-box:sing-box"'
assert_ok "加入 default 运行级别" test -L "$A/etc/runlevels/default/sing-box"
assert_ok "管理标记" test -f "$A/etc/sing-box/.apm-managed"
assert_ok "用户创建标记" test -f "$A/etc/sing-box/.apm-created-user"
assert_contains "用户已创建" "$(cat "$A/etc/passwd")" "sing-box:x:"
assert_eq "元数据 managed" true "$(kv_get "$(META)" managed)"
assert_eq "元数据 core" singbox "$(kv_get "$(META)" core)"
assert_eq "元数据 exact_release" v1.13.14 "$(kv_get "$(META)" exact_release)"
assert_eq "元数据 reported_version" 1.13.14 "$(kv_get "$(META)" reported_version)"
assert_eq "元数据 binary_path" /usr/local/bin/sing-box "$(kv_get "$(META)" binary_path)"
assert_eq "元数据 config_path" /etc/sing-box/config.json "$(kv_get "$(META)" config_path)"
assert_eq "元数据 config_root" /etc/sing-box "$(kv_get "$(META)" config_root)"
assert_eq "元数据 service_name" sing-box "$(kv_get "$(META)" service_name)"
assert_eq "元数据 log_dir" /var/log/sing-box "$(kv_get "$(META)" log_dir)"
assert_eq "元数据 created_user" yes "$(kv_get "$(META)" created_user)"
assert_eq "元数据权限" 600 "$(stat -c %a "$(META)")"
assert_eq "压缩包已删除, staging 已清理" 0 "$(ls -A "$A/var/tmp" | wc -l | tr -d ' ')"
assert_contains "下载地址" "$(cat "$K/dl.log")" "/v1.13.14/sing-box-1.13.14-linux-amd64-musl.tar.gz"
core_discover singbox
assert_eq "发现: managed" yes "$CF_MANAGED"
assert_eq "发现: 状态" running "$CF_STATE"
assert_eq "发现: 精确发布来自元数据" v1.13.14 "$CF_VERSION_EXACT"
assert_eq "发现: 自报版本" 1.13.14 "$CF_VERSION_REPORTED"
assert_eq "发现: 服务进程" 33002 "$CF_PID"
assert_eq "发现: 配置路径" /etc/sing-box/config.json "$CF_CONFIG"
assert_eq "发现: 日志" /var/log/sing-box/error.log "$CF_LOG_ERR"
out=$("$PM" sing-box status)
assert_contains "status: 运行中" "$out" "状态：运行中"
assert_contains "status: 已接管" "$out" "Manager 部署, 已接管"
out=$("$PM" sing-box info)
assert_contains "info: 部署类型" "$out" "部署类型：managed"
assert_contains "info: 精确发布" "$out" "精确发布：v1.13.14"
assert_contains "info: 版本来源" "$out" "版本来源：manager-metadata"
assert_contains "info: 配置路径" "$out" "配置：/etc/sing-box/config.json"
out=$("$PM" core list)
assert_contains "core list 含 sing-box 已接管" "$out" "管理状态：已接管"
assert_fail "没有违规的 rc-service 动作" test -e "$K/violations"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "重复 install 返回 4" 4 $?
assert_contains "重复 install 提示" "$OUT" "已经由 Alpine Proxy Manager 安装"
assert_eq "重复 install 不改变任何文件" "$BEFORE" "$(snap)"
out=$("$PM" sing-box check)
assert_eq "check 成功" 0 $?
assert_contains "check 输出" "$out" "配置通过 sing-box check"
touch "$K/check_fail"
"$PM" sing-box check >/dev/null 2>&1
assert_eq "check 失败返回 1" 1 $?
rm -f "$K/check_fail"

# ---- 参数, 校验和 ----
new_s i2
OUT=$("$PM" sing-box install --release 1.13.14 2>&1)
assert_eq "不带 v 的 release 被规范化" 0 $?
assert_eq "元数据记录带 v 的标签" v1.13.14 "$(kv_get "$(META)" exact_release)"
new_s i3
BEFORE=$(snap)
for a in "--release 2.0.0" "--release abc" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" sing-box install $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
assert_eq "参数错误没有改动" "$BEFORE" "$(snap)"
OUT=$(APM_EUID=1000 "$PM" sing-box install 2>&1)
assert_eq "非 root 拒绝" 4 $?
assert_contains "非 root 提示" "$OUT" "需要 root"
# 未内置校验和的 release 通过发布页 digest 校验
new_s i4
mk_sb_release "$ZIPS" 1.13.70; SHA70=$SB_LAST_SHA
printf '{\n  "assets": [\n    {\n      "name": "sing-box-1.13.70-linux-arm64-musl.tar.gz",\n      "size": 1,\n      "digest": "sha256:%s"\n    },\n    {\n      "name": "sing-box-1.13.70-linux-amd64-musl.tar.gz",\n      "size": 2,\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' "0000000000000000000000000000000000000000000000000000000000000000" "$SHA70" > "$ZIPS/v1.13.70"
unset APM_SB_SHA256
APM_SB_API_BASE=https://example.invalid/api "$PM" sing-box install --release v1.13.70 >/dev/null 2>&1
assert_eq "未内置的 release 用发布页 digest 校验并安装" 0 $?
assert_eq "该 release 已安装" v1.13.70 "$(kv_get "$(META)" exact_release)"
new_s i5
unset APM_SB_SHA256
BEFORE=$(snap)
APM_SB_API_BASE=https://example.invalid/api "$PM" sing-box install --release v1.13.71 >/dev/null 2>&1
fail_case "既没有内置校验和也查不到 digest" $?
use_sha "$SHA_D"

# ---- 拒绝 External 与残留 ----
# 233boy 形态: /usr/local/bin/sing-box 是 bash 管理脚本的符号链接, /etc/sing-box 里有它的目录
new_s e1
mkdir -p "$A/etc/sing-box/sh" "$A/etc/sing-box/bin" "$A/etc/sing-box/conf"
printf '#!/bin/bash\ntouch "%s/SHOULD_NOT_EXIST"\n' "$SM" > "$A/etc/sing-box/sh/sing-box.sh"
chmod +x "$A/etc/sing-box/sh/sing-box.sh"
ln -s /etc/sing-box/sh/sing-box.sh "$A/usr/local/bin/sing-box"
mk_sb_sidecar "$T_TMP/real-side.sh" 1.13.14
mk_elf_exec "$A/etc/sing-box/bin/sing-box" "$T_TMP/real-side.sh"
printf '#!/sbin/openrc-run\ncommand="/etc/sing-box/bin/sing-box"\ncommand_args="run -c /etc/sing-box/config.json -C /etc/sing-box/conf"\nsupervisor=supervise-daemon\n' > "$A/etc/init.d/sing-box"
chmod +x "$A/etc/init.d/sing-box"
printf '{"log":{}}\n' > "$A/etc/sing-box/config.json"
echo started > "$K/state-sing-box"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "233boy 形态 install 拒绝" 4 $?
assert_contains "233boy 形态提示" "$OUT" "发现现有 sing-box 部署"
assert_fail "233boy 管理脚本没有被执行" test -e "$SM/SHOULD_NOT_EXIST"
assert_eq "233boy 形态没有改动" "$BEFORE" "$(snap)"
core_discover singbox
assert_eq "233boy 形态: 采用 OpenRC command 指向的 ELF" /etc/sing-box/bin/sing-box "$CF_BINARY"
assert_eq "233boy 形态: external" external "$CF_DEPLOYMENT"
assert_eq "233boy 形态: 版本来自 ELF" 1.13.14 "$CF_VERSION_REPORTED"
assert_contains "233boy 形态: 被忽略的脚本入口有提示" "$CF_NOTES" "/usr/local/bin/sing-box"
for c in start stop restart check "update" "update --force" uninstall "uninstall --purge" "add anytls" "enable X" "disable X" "delete X" "set X port 20000"; do
    # shellcheck disable=SC2086
    OUT=$("$PM" sing-box $c 2>&1)
    assert_eq "External: $c 拒绝返回 4" 4 $?
    assert_contains "External: $c 提示未被管理" "$OUT" "不是由 Alpine Proxy Manager 管理"
done
assert_eq "External: 写操作后没有改动" "$BEFORE" "$(snap)"
assert_fail "External: 脚本仍没有被执行" test -e "$SM/SHOULD_NOT_EXIST"
assert_eq "External: 没有 rc-service 写动作" "" "$(grep -v ' status$' "$K/calls" 2>/dev/null)"
out=$("$PM" sing-box status; "$PM" sing-box info)
assert_contains "External: 状态可读" "$out" "现有部署"
# HK-GLB 形态: apk 安装在 /usr/bin 的 ELF
new_s e2
mk_elf_exec "$A/usr/bin/sing-box" "$T_TMP/real-side.sh"
mkdir -p "$A/etc/sing-box"
printf '{}\n' > "$A/etc/sing-box/config.json"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
assert_eq "apk 形态 install 拒绝" 4 $?
assert_eq "apk 形态没有改动" "$BEFORE" "$(snap)"
"$PM" sing-box restart >/dev/null 2>&1
assert_eq "apk 形态 restart 拒绝" 4 $?
# /etc/sing-box 存在但没有 Manager 标记
new_s e3
mkdir -p "$A/etc/sing-box"
echo keep > "$A/etc/sing-box/other.json"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "无标记的 /etc/sing-box 拒绝" 4 $?
assert_contains "无标记的 /etc/sing-box 提示" "$OUT" "不是由 Manager 创建的"
assert_eq "无标记的 /etc/sing-box 没有改动" "$BEFORE" "$(snap)"
# 同名脚本入口
new_s e4
mk_script_bin "$A/usr/local/bin/sing-box" "$SM"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
assert_eq "同名脚本入口拒绝" 4 $?
assert_fail "同名脚本入口没有被执行" test -e "$SM/SHOULD_NOT_EXIST"
assert_eq "同名脚本入口没有改动" "$BEFORE" "$(snap)"
# 残留服务脚本或元数据
new_s e5
printf '#!/sbin/openrc-run\n' > "$A/etc/init.d/sing-box"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
assert_eq "残留服务脚本拒绝" 4 $?
assert_eq "残留服务脚本没有改动" "$BEFORE" "$(snap)"
new_s e6
mkdir -p "$A/var/lib/alpine-proxy-manager/cores"
printf 'managed=true\ncore=singbox\n' > "$(META)"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "残留元数据拒绝" 4 $?
assert_contains "残留元数据提示" "$OUT" "残留的 Manager 元数据"
# 元数据损坏
new_s e7
"$PM" sing-box install >/dev/null 2>&1
printf 'garbage line\n' > "$(META)"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "元数据损坏 install 拒绝" 4 $?
assert_contains "元数据损坏提示归属不明" "$OUT" "归属不明"
for c in start stop restart check update uninstall "add anytls"; do
    # shellcheck disable=SC2086
    "$PM" sing-box $c >/dev/null 2>&1
    assert_eq "元数据损坏时 $c 拒绝" 4 $?
done
assert_eq "元数据损坏时没有任何改动" "$BEFORE" "$(snap)"

# ---- install 失败完整回滚 ----
new_s f1
BEFORE=$(snap)
APM_TEST_DL_FAIL=1 "$PM" sing-box install >/dev/null 2>&1
fail_case "下载失败" $?
unset APM_TEST_DL_FAIL
new_s f2
use_sha "0000000000000000000000000000000000000000000000000000000000000000"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
fail_case "sha256 不匹配" $?
assert_contains "sha256 不匹配提示" "$OUT" "sha256 不匹配"
new_s f3
use_sha "$SHA_GARBAGE"
BEFORE=$(snap)
"$PM" sing-box install --release v1.13.60 >/dev/null 2>&1
fail_case "压缩包损坏" $?
new_s f4
use_sha "$SHA_NOMEMBER"
BEFORE=$(snap)
"$PM" sing-box install --release v1.13.61 >/dev/null 2>&1
fail_case "压缩包内没有 sing-box" $?
new_s f5
use_sha "$SHA_SCRIPT"
BEFORE=$(snap)
"$PM" sing-box install --release v1.13.62 >/dev/null 2>&1
fail_case "压缩包内的 sing-box 是脚本" $?
assert_fail "压缩包内的脚本没有被执行" test -e "$SM/SHOULD_NOT_EXIST"
new_s f6
use_sha "$SHA_MIS"
BEFORE=$(snap)
OUT=$("$PM" sing-box install --release v1.13.51 2>&1)
fail_case "自报版本与 release 不一致" $?
assert_contains "版本不一致提示" "$OUT" "不一致"
new_s f7
touch "$K/fail_adduser"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
fail_case "创建用户失败" $?
assert_eq "用户组也被回滚" "" "$(cat "$A/etc/group")"
new_s f8
touch "$K/fail_rcupdate"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
fail_case "rc-update 失败" $?
new_s f9
touch "$K/fail_start-sing-box"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
fail_case "start 失败" $?
assert_contains "start 失败后调用了 stop 清理" "$(calls)" "sing-box stop"
new_s f10
touch "$K/check_fail"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
fail_case "配置未通过 check" $?
assert_contains "配置未通过 check 提示" "$OUT" "未通过 sing-box check"
new_s f11
BEFORE=$(snap)
_sb_write_init() { return 1; }
OUT=$(singbox_install 2>&1)
RC=$?
t_load singbox
fail_case "服务脚本写入失败" "$RC"
new_s f12
BEFORE=$(snap)
_sb_write_meta() { return 1; }
OUT=$(singbox_install 2>&1)
RC=$?
t_load singbox
fail_case "元数据写入失败" "$RC"
assert_contains "元数据写入失败时已启动过再被停止" "$(calls)" "sing-box stop"
new_s f13
BEFORE=$(snap)
_snell_chown() { return 1; }
OUT=$(singbox_install 2>&1)
RC=$?
t_load snell
fail_case "设置属主失败" "$RC"
new_s f14
echo 'sing-box:x:100:101::/var/empty:/sbin/nologin' > "$A/etc/passwd"
echo 'sing-box:x:101:' > "$A/etc/group"
touch "$K/fail_rcupdate"
BEFORE=$(snap)
"$PM" sing-box install >/dev/null 2>&1
fail_case "已有用户时 rc-update 失败" $?
assert_contains "已有的用户未被删除" "$(cat "$A/etc/passwd")" "sing-box:x:100"

# ---- start stop restart ----
new_s l1
"$PM" sing-box install >/dev/null 2>&1
: > "$K/calls"
OUT=$("$PM" sing-box start 2>&1)
assert_eq "已运行时 start 成功" 0 $?
assert_contains "已运行时 start 是空操作" "$OUT" "已经在运行"
assert_eq "已运行时没有调用 start" 0 "$(count_calls start)"
OUT=$("$PM" sing-box stop 2>&1)
assert_eq "stop 成功" 0 $?
core_discover singbox
assert_eq "stop 后状态" stopped "$CF_STATE"
assert_eq "stop 后没有服务进程" "" "$CF_PID"
OUT=$("$PM" sing-box stop 2>&1)
assert_contains "已停止时 stop 是空操作" "$OUT" "已经停止"
OUT=$("$PM" sing-box start 2>&1)
assert_eq "start 成功" 0 $?
assert_contains "start 输出" "$OUT" "已启动并验证"
OUT=$("$PM" sing-box restart 2>&1)
assert_eq "restart 成功" 0 $?
assert_ok "restart 后运行中" running
touch "$K/fail_restart-sing-box"
OUT=$("$PM" sing-box restart 2>&1)
assert_eq "restart 失败返回 1" 1 $?
rm -f "$K/fail_restart-sing-box"
"$PM" sing-box stop >/dev/null 2>&1
touch "$K/fail_start-sing-box"
OUT=$("$PM" sing-box start 2>&1)
assert_eq "start 失败返回 1" 1 $?
assert_contains "start 失败提示" "$OUT" "start 失败"
rm -f "$K/fail_start-sing-box"
"$PM" sing-box start >/dev/null 2>&1
touch "$K/fail_stop-sing-box"
"$PM" sing-box stop >/dev/null 2>&1
assert_eq "stop 失败返回 1" 1 $?
rm -f "$K/fail_stop-sing-box"
# start 前的 check 失败 (配置被改坏), 服务不会启动
"$PM" sing-box stop >/dev/null 2>&1
touch "$K/check_fail"
"$PM" sing-box start >/dev/null 2>&1
assert_eq "配置 check 失败时 start 失败" 1 $?
rm -f "$K/check_fail"
"$PM" sing-box start >/dev/null 2>&1
assert_fail "全程没有违规动作" test -e "$K/violations"
# broken
new_s l2
"$PM" sing-box install >/dev/null 2>&1
printf '#!/bin/sh\necho garbage\n' > "$T_TMP/broken-side.sh"; chmod +x "$T_TMP/broken-side.sh"
mk_elf_exec "$A/usr/local/bin/sing-box" "$T_TMP/broken-side.sh"
core_discover singbox
assert_eq "二进制给不出版本: broken" broken "$CF_STATE"
"$PM" sing-box start >/dev/null 2>&1
assert_eq "broken 时 start 拒绝" 4 $?
"$PM" sing-box restart >/dev/null 2>&1
assert_eq "broken 时 restart 拒绝" 4 $?
"$PM" sing-box add anytls >/dev/null 2>&1
assert_eq "broken 时 add 拒绝" 4 $?
"$PM" sing-box stop >/dev/null 2>&1
assert_eq "broken 时 stop 允许" 0 $?
"$PM" sing-box update >/dev/null 2>&1
assert_eq "broken 时 update 允许并修复" 0 $?
core_discover singbox
assert_eq "update 修复后版本" 1.13.14 "$CF_VERSION_REPORTED"

# ---- update ----
new_s u1
"$PM" sing-box install >/dev/null 2>&1
: > "$K/calls"
: > "$K/dl.log"
OUT=$("$PM" sing-box update 2>&1)
assert_eq "同版本 update 成功" 0 $?
assert_contains "同版本 update 提示" "$OUT" "已经是目标版本"
assert_eq "同版本 update 没有停服务" 000 "$(count_calls stop)$(count_calls restart)$(count_calls start)"
assert_eq "同版本 update 没有下载" 0 "$(wc -l < "$K/dl.log" | tr -d ' ')"
BIN1=$(cksum < "$A/usr/local/bin/sing-box")
: > "$K/calls"
OUT=$("$PM" sing-box update --force 2>&1)
assert_eq "--force 成功" 0 $?
assert_contains "--force 输出" "$OUT" "更新完成并已验证"
assert_eq "--force 停止并启动" "1 1" "$(count_calls stop) $(count_calls start)"
assert_eq "--force 二进制内容相同" "$BIN1" "$(cksum < "$A/usr/local/bin/sing-box")"
assert_ok "--force 后运行中" running
assert_fail "--force 后没有 .old 遗留" test -e "$A/usr/local/bin/sing-box.old"
# 更新到新 release
use_sha "$SHA_N"
OUT=$("$PM" sing-box update v1.14.2 2>&1)
assert_eq "更新到新 release 成功" 0 $?
core_discover singbox
assert_eq "更新后精确发布" v1.14.2 "$CF_VERSION_EXACT"
assert_eq "更新后自报版本" 1.14.2 "$CF_VERSION_REPORTED"
assert_eq "更新后元数据 reported_version" 1.14.2 "$(kv_get "$(META)" reported_version)"
assert_ok "更新后运行中" running
assert_contains "更新输出说明检查了当前配置" "$OUT" "用新二进制检查当前配置"
# 新版本不接受当前配置: 拒绝升级, 不停服务
use_sha "$SHA_D"
OLDBIN=$(cksum < "$A/usr/local/bin/sing-box")
OLDMETA=$(cat "$(META)")
echo 1.13.14 > "$K/check_reject_version"
: > "$K/calls"
OUT=$("$PM" sing-box update v1.13.14 2>&1)
assert_eq "新版本拒绝当前配置时 update 失败" 1 $?
assert_contains "拒绝原因" "$OUT" "无法通过当前配置的 sing-box check"
assert_eq "新版本拒绝当前配置时没有停服务" 0 "$(count_calls stop)"
assert_eq "二进制没有被替换" "$OLDBIN" "$(cksum < "$A/usr/local/bin/sing-box")"
assert_eq "元数据没有被改" "$OLDMETA" "$(cat "$(META)")"
assert_ok "仍然运行" running
: > "$K/check_reject_version"
# 其他失败路径
APM_TEST_DL_FAIL=1 "$PM" sing-box update v1.13.14 >/dev/null 2>&1
assert_eq "update 下载失败返回 1" 1 $?
unset APM_TEST_DL_FAIL
use_sha "$SHA_SCRIPT"
"$PM" sing-box update v1.13.62 >/dev/null 2>&1
assert_eq "update 新二进制是脚本拒绝" 1 $?
assert_fail "update 的脚本没有被执行" test -e "$SM/SHOULD_NOT_EXIST"
use_sha "$SHA_MIS"
"$PM" sing-box update v1.13.51 >/dev/null 2>&1
assert_eq "update 自报版本不一致拒绝" 1 $?
use_sha "0000000000000000000000000000000000000000000000000000000000000000"
"$PM" sing-box update v1.13.14 >/dev/null 2>&1
assert_eq "update sha256 不匹配拒绝" 1 $?
assert_eq "失败后二进制不变" "$OLDBIN" "$(cksum < "$A/usr/local/bin/sing-box")"
assert_eq "失败后元数据不变" "$OLDMETA" "$(cat "$(META)")"
assert_ok "失败后仍运行" running
use_sha "$SHA_D"
touch "$K/fail_stop-sing-box"
OUT=$("$PM" sing-box update --force 2>&1)
assert_eq "update stop 失败返回 1" 1 $?
assert_contains "update stop 失败提示" "$OUT" "停止 sing-box 失败"
rm -f "$K/fail_stop-sing-box"
assert_eq "update stop 失败后二进制不变" "$OLDBIN" "$(cksum < "$A/usr/local/bin/sing-box")"
assert_fail "update stop 失败后没有 .old" test -e "$A/usr/local/bin/sing-box.old"
# 新版启动失败: 回滚旧二进制与服务
use_sha "$SHA_BAD"
OUT=$("$PM" sing-box update v1.13.99 2>&1)
assert_eq "新版启动失败返回 1" 1 $?
assert_contains "新版启动失败提示回滚" "$OUT" "回滚到旧版本"
assert_contains "回滚后恢复运行" "$OUT" "已回滚并恢复运行"
assert_eq "回滚后二进制恢复" "$OLDBIN" "$(cksum < "$A/usr/local/bin/sing-box")"
assert_eq "回滚后元数据恢复" "$OLDMETA" "$(cat "$(META)")"
assert_ok "回滚后运行中" running
assert_fail "回滚后没有 .old" test -e "$A/usr/local/bin/sing-box.old"
use_sha "$SHA_D"
# 之前没在运行: 更新但不启动
"$PM" sing-box stop >/dev/null 2>&1
: > "$K/calls"
"$PM" sing-box update --force >/dev/null 2>&1
assert_eq "停止状态下 update 成功且不启动" 0 "$(count_calls start)"
core_discover singbox
assert_eq "停止状态下 update 后状态" stopped "$CF_STATE"
"$PM" sing-box update bogus >/dev/null 2>&1
assert_eq "update 参数错误返回 2" 2 $?

# ---- uninstall ----
new_s n1
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "未安装 uninstall 返回 0" 0 $?
assert_contains "未安装提示" "$OUT" "未安装"
"$PM" sing-box install >/dev/null 2>&1
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "普通 uninstall 成功" 0 $?
assert_contains "uninstall 输出已保留" "$OUT" "已保留"
assert_fail "服务脚本已删" test -e "$A/etc/init.d/sing-box"
assert_fail "运行级别链接已删" test -e "$A/etc/runlevels/default/sing-box"
assert_fail "二进制已删" test -e "$A/usr/local/bin/sing-box"
assert_fail "元数据已删" test -e "$(META)"
assert_ok "配置保留" test -f "$A/etc/sing-box/config.json"
assert_ok "管理标记保留" test -f "$A/etc/sing-box/.apm-managed"
assert_ok "日志目录保留" test -d "$A/var/log/sing-box"
assert_contains "用户保留" "$(cat "$A/etc/passwd")" "sing-box:x:"
assert_eq "服务已停止" stopped "$(cat "$K/state-sing-box")"
core_discover singbox
assert_eq "卸载后发现为未安装" not-installed "$CF_STATE"
OUT=$("$PM" sing-box install 2>&1)
assert_eq "卸载后重新安装" 0 $?
assert_eq "重新安装后元数据仍记录创建了用户" yes "$(kv_get "$(META)" created_user)"
assert_ok "重新安装后运行中" running
OUT=$("$PM" sing-box uninstall --purge 2>&1)
assert_eq "uninstall --purge 成功" 0 $?
assert_fail "purge 删除配置根" test -e "$A/etc/sing-box"
assert_fail "purge 删除日志目录" test -e "$A/var/log/sing-box"
assert_fail "purge 删除工作目录" test -e "$A/var/lib/sing-box"
assert_eq "purge 删除由 Manager 创建的用户" "" "$(cat "$A/etc/passwd")"
assert_eq "purge 删除由 Manager 创建的用户组" "" "$(cat "$A/etc/group")"
assert_fail "purge 后元数据已删" test -e "$(META)"
assert_not_contains "purge 没有警告" "$OUT" "警告"
OUT=$("$PM" sing-box install 2>&1)
assert_eq "purge 后全新安装" 0 $?
# 不删除原本就存在的用户
new_s n2
echo 'sing-box:x:100:101::/var/empty:/sbin/nologin' > "$A/etc/passwd"
echo 'sing-box:x:101:' > "$A/etc/group"
"$PM" sing-box install >/dev/null 2>&1
assert_eq "已有用户时 created_user" no "$(kv_get "$(META)" created_user)"
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_contains "purge 保留原本就存在的用户" "$(cat "$A/etc/passwd")" "sing-box:x:100"
# stop 失败: 中止, 不删任何东西
new_s n3
"$PM" sing-box install >/dev/null 2>&1
BEFORE=$(snap)
touch "$K/fail_stop-sing-box"
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "uninstall stop 失败返回 1" 1 $?
assert_contains "uninstall stop 失败提示" "$OUT" "没有删除任何文件"
rm -f "$K/fail_stop-sing-box"
assert_eq "uninstall stop 失败没有删除任何东西" "$BEFORE" "$(snap)"
# 服务脚本没有标记: 保留
new_s n4
"$PM" sing-box install >/dev/null 2>&1
printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/sing-box"\n' > "$A/etc/init.d/sing-box"
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "无标记的服务脚本时 uninstall 仍成功" 0 $?
assert_ok "无标记的服务脚本被保留" test -f "$A/etc/init.d/sing-box"
assert_contains "无标记警告" "$OUT" "没有 Manager 标记"
# 二进制已丢失
new_s n5
"$PM" sing-box install >/dev/null 2>&1
rm -f "$A/usr/local/bin/sing-box"
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "二进制已丢失时 uninstall 清理残留" 0 $?
assert_contains "清理提示" "$OUT" "清理 Manager 记录的残留"
assert_fail "清理后元数据已删" test -e "$(META)"
# purge 在没有标记的配置根上保留它
new_s n6
"$PM" sing-box install >/dev/null 2>&1
rm -f "$A/etc/sing-box/.apm-managed"
echo keep > "$A/etc/sing-box/other.json"
OUT=$("$PM" sing-box uninstall --purge 2>&1)
assert_eq "无标记的配置根 purge 仍成功" 0 $?
assert_ok "无标记的配置根被保留" test -f "$A/etc/sing-box/other.json"
assert_contains "无标记警告" "$OUT" "没有 Manager 标记"

# ---- 与 Snell 共存 ----
new_s c1
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" sing-box install >/dev/null 2>&1
core_discover snell
SPID=$CF_PID
SLISTEN=$CF_LISTEN
SCONF=$(cksum < "$A/etc/snell/snell-server.conf")
assert_eq "共存: Snell 运行中" running "$CF_STATE"
core_discover singbox
SBPID=$CF_PID
assert_eq "共存: sing-box 运行中" running "$CF_STATE"
"$PM" sing-box restart >/dev/null 2>&1
core_discover snell
assert_eq "sing-box restart 不影响 Snell: PID" "$SPID" "$CF_PID"
assert_eq "sing-box restart 不影响 Snell: 监听" "$SLISTEN" "$CF_LISTEN"
"$PM" snell restart >/dev/null 2>&1
core_discover singbox
assert_eq "Snell restart 不影响 sing-box: 状态" running "$CF_STATE"
assert_eq "Snell restart 不影响 sing-box: PID" "$SBPID" "$CF_PID"
"$PM" sing-box update --force >/dev/null 2>&1
assert_eq "sing-box 更新不改 Snell 配置" "$SCONF" "$(cksum < "$A/etc/snell/snell-server.conf")"
assert_ok "更新 sing-box 后 Snell 仍运行" test "$(cat "$K/state")" = started
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_ok "卸载 sing-box 后 Snell 仍运行" test "$(cat "$K/state")" = started
core_discover snell
assert_eq "卸载 sing-box 后 Snell 仍受管" yes "$CF_MANAGED"
out=$("$PM" status)
assert_contains "status 同时显示两个 Core" "$out" "Snell       运行中 (Manager 部署, 已接管)"
assert_contains "status 显示 sing-box 未安装" "$out" "sing-box    未安装"
assert_fail "整个过程没有违规动作" test -e "$K/violations"
assert_eq "没有任何脚本被执行" "" "$(ls "$SM")"
t_done
