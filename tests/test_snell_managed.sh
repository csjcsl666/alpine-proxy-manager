# shellcheck shell=sh
# Snell Managed Core 完整生命周期: install start stop restart config update uninstall
# 全部在模拟系统中进行 (假的 rc-service apk adduser 等, 只在 sysroot 内查找)
# 使用真实的最小 ELF 桩作为 snell-server, PSK 与日志均为虚构
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_snell_managed.sh 全部跳过"
    t_done
    exit $?
fi

MSG_OK='2026-01-01 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.0 (Aug  7 2026)'
ZIPS=$T_TMP/zips
DL=$T_TMP/dl
mk_dl_shim "$DL"
mk_snell_zip "$ZIPS" v6.0.0rc2 "$MSG_OK"
mk_snell_zip "$ZIPS" v6.0.0rc3 '2026-02-01 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.1 (Sep  1 2026)'
mk_snell_zip "$ZIPS" v6.0.0rc9 'BADBIN 2026-01-01 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.2 (Sep  2 2026)'
mk_snell_zip "$ZIPS" v6.0.0rc5 'garbage output without version'
printf 'this is not a zip file\n' > "$ZIPS/snell-server-v6.0.0rc8-linux-amd64.zip"
# 不含 snell-server 的 zip
W=$T_TMP/zipw
mkdir -p "$W"
printf 'x' > "$W/other"
git -C "$W" init -q
git -C "$W" add other
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q -m x
git -C "$W" archive --format=zip -o "$ZIPS/snell-server-v6.0.0rc7-linux-amd64.zip" HEAD
# snell-server 是脚本的 zip, 不得被执行
SM=$T_TMP/scriptmarker
mkdir -p "$SM" "$T_TMP/zipw2"
printf '#!/bin/sh\ntouch "%s/SHOULD_NOT_EXIST"\necho snell-server v6.0.0\n' "$SM" > "$T_TMP/zipw2/snell-server"
chmod +x "$T_TMP/zipw2/snell-server"
git -C "$T_TMP/zipw2" init -q
git -C "$T_TMP/zipw2" add snell-server
git -C "$T_TMP/zipw2" -c user.name=t -c user.email=t@example.invalid commit -q -m x
git -C "$T_TMP/zipw2" archive --format=zip -o "$ZIPS/snell-server-v6.0.0rc6-linux-amd64.zip" HEAD

new_m() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_sim_system "$A"
    K=$A/fake-rc
    mkdir -p "$K"
    echo stopped > "$K/state"
    : > "$K/dl.log"
    APM_SYSROOT=$A
    APM_FAKE_RC_DIR=$K
    APM_EUID=0
    APM_ARCH=x86_64
    APM_DOWNLOADER=$DL
    APM_TEST_ZIPS=$ZIPS
    APM_TEST_DL_LOG=$K/dl.log
    APM_SNELL_WAIT=1
    export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER APM_TEST_ZIPS APM_TEST_DL_LOG APM_SNELL_WAIT
    unset APM_VAR APM_ETC APM_BACKUP_DIR APM_BACKUP_KEEP
}

# 文件树与账户快照 (排除模拟旋钮, 记录文件与临时目录内容)
snap() { (cd "$A" && find . \( -path ./fake-rc -o -path ./.chown.log -o -path ./.apk-installed -o -path './var/tmp/*' \) -prune -o -print | sort; cat etc/passwd etc/group; ls -A var/tmp | wc -l); }
conf=/etc/snell/snell-server.conf
psk_of() { sed -n 's/^psk = //p' "$A$conf"; }
calls() { cat "$K/calls" 2>/dev/null; }
count_calls() { grep -c "^snell $1\$" "$K/calls" 2>/dev/null || true; }
running() { core_discover snell; [ "$CF_STATE" = running ]; }

# ---- install 成功 ----
new_m i1
OUT=$("$PM" snell install --port 20000 2>&1)
RC=$?
assert_eq "install 成功" 0 "$RC"
assert_contains "install 输出完成" "$OUT" "Snell 安装完成并已验证"
assert_contains "install 输出 release" "$OUT" "release：v6.0.0rc2 (二进制自报 v6.0.0)"
assert_eq "二进制是 ELF" elf "$(core_file_kind "$A/usr/local/bin/snell-server")"
assert_eq "二进制权限" 755 "$(stat -c %a "$A/usr/local/bin/snell-server")"
assert_eq "配置目录权限" 750 "$(stat -c %a "$A/etc/snell")"
assert_eq "配置文件权限" 640 "$(stat -c %a "$A$conf")"
assert_contains "配置内容 listen" "$(cat "$A$conf")" "listen = 0.0.0.0:20000"
assert_contains "配置内容 mode" "$(cat "$A$conf")" "mode = default"
assert_eq "配置属主被设置" "root:snell /etc/snell" "$(grep ' /etc/snell$' "$A/.chown.log" | head -n 1)"
assert_contains "日志目录属主" "$(cat "$A/.chown.log")" "snell:snell /var/log/snell"
assert_eq "日志目录权限" 750 "$(stat -c %a "$A/var/log/snell")"
assert_contains "服务脚本有 Manager 标记" "$(cat "$A/etc/init.d/snell")" "# apm-managed: snell"
assert_contains "服务脚本是 openrc-run" "$(head -n 1 "$A/etc/init.d/snell")" "openrc-run"
assert_contains "服务脚本使用 supervise-daemon" "$(cat "$A/etc/init.d/snell")" 'supervisor="supervise-daemon"'
assert_contains "服务脚本含 gcompat" "$(cat "$A/etc/init.d/snell")" "libgcompat.so.0"
assert_eq "服务脚本权限" 755 "$(stat -c %a "$A/etc/init.d/snell")"
assert_ok "加入 default 运行级别" test -L "$A/etc/runlevels/default/snell"
assert_contains "安装了 gcompat" "$(cat "$A/.apk-installed")" "gcompat"
assert_eq "只安装缺失的依赖" 1 "$(grep -c '^libgcc$' "$A/.apk-installed")"
assert_contains "用户已创建" "$(cat "$A/etc/passwd")" "snell:x:"
assert_contains "用户组已创建" "$(cat "$A/etc/group")" "snell:x:"
assert_ok "用户创建标记" test -f "$A/etc/snell/.apm-created-user"
assert_ok "用户组创建标记" test -f "$A/etc/snell/.apm-created-group"
M=$A/var/lib/alpine-proxy-manager/cores/snell.meta
assert_ok "元数据存在" test -f "$M"
assert_eq "元数据权限" 600 "$(stat -c %a "$M")"
assert_eq "元数据 managed" true "$(kv_get "$M" managed)"
assert_eq "元数据 core" snell "$(kv_get "$M" core)"
assert_eq "元数据 exact_release" v6.0.0rc2 "$(kv_get "$M" exact_release)"
assert_eq "元数据 reported_version" v6.0.0 "$(kv_get "$M" reported_version)"
assert_eq "元数据 binary_path" /usr/local/bin/snell-server "$(kv_get "$M" binary_path)"
assert_eq "元数据 config_path" /etc/snell/snell-server.conf "$(kv_get "$M" config_path)"
assert_eq "元数据 service_name" snell "$(kv_get "$M" service_name)"
assert_eq "元数据 log_dir" /var/log/snell "$(kv_get "$M" log_dir)"
assert_eq "元数据 created_user" yes "$(kv_get "$M" created_user)"
assert_eq "元数据 schema" 1 "$(kv_get "$M" schema)"
PSK=$(psk_of)
assert_eq "PSK 长度" 32 "${#PSK}"
assert_contains "自动生成的 PSK 只显示一次" "$OUT" "PSK：$PSK"
assert_eq "PSK 在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$PSK")"
assert_not_contains "元数据不含 PSK" "$(cat "$M")" "$PSK"
assert_eq "除配置文件外没有任何文件含 PSK" "$A$conf" "$(grep -rl "$PSK" "$A" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "临时目录已清理" 0 "$(ls -A "$A/var/tmp" | wc -l | tr -d ' ')"
assert_contains "下载地址使用官方格式" "$(cat "$K/dl.log")" "https://dl.nssurge.com/snell/snell-server-v6.0.0rc2-linux-amd64.zip"
core_discover snell
assert_eq "发现: managed" yes "$CF_MANAGED"
assert_eq "发现: deployment" managed "$CF_DEPLOYMENT"
assert_eq "发现: 状态" running "$CF_STATE"
assert_eq "发现: 精确发布来自元数据" v6.0.0rc2 "$CF_VERSION_EXACT"
assert_eq "发现: 自报版本" v6.0.0 "$CF_VERSION_REPORTED"
assert_eq "发现: 版本来源" manager-metadata "$CF_VERSION_SOURCE"
assert_eq "发现: 服务进程" 23755 "$CF_PID"
assert_contains "发现: 监听" "$CF_LISTEN" "0.0.0.0:20000"
assert_contains "发现: 日志路径" "$CF_LOG_ERR" "/var/log/snell/error.log"
out=$("$PM" core list)
assert_contains "core list: 已接管" "$out" "管理状态：已接管"
assert_contains "core list: Manager 部署" "$out" "来源：Manager 部署"
assert_fail "没有违规的 rc-service 动作" test -e "$K/violations"

# 重复 install 被拒绝, 不隐式更新
BEFORE=$(snap)
OUT=$("$PM" snell install 2>&1)
RC=$?
assert_eq "重复 install 返回 4" 4 "$RC"
assert_contains "重复 install 提示" "$OUT" "已经由 Alpine Proxy Manager 安装"
assert_eq "重复 install 不改变任何文件" "$BEFORE" "$(snap)"

# ---- install 参数 ----
new_m i2
OUT=$("$PM" snell install --listen "0.0.0.0:20001,[::]:20001" --release v6.0.0-rc2 2>&1)
assert_eq "install --listen --release 带连字符" 0 $?
assert_contains "多地址 listen" "$(cat "$A$conf")" "listen = 0.0.0.0:20001,[::]:20001"
assert_contains "连字符 release 规范化为官方写法" "$(cat "$K/dl.log")" "snell-server-v6.0.0rc2-linux-amd64.zip"
assert_eq "元数据记录规范化的 release" v6.0.0rc2 "$(kv_get "$A/var/lib/alpine-proxy-manager/cores/snell.meta" exact_release)"
new_m i3
OUT=$(printf 'MyOwnPskForTest0123456789abcdef\n' | "$PM" snell install --port 20002 --psk-stdin 2>&1)
assert_eq "install --psk-stdin" 0 $?
assert_eq "使用提供的 PSK" MyOwnPskForTest0123456789abcdef "$(psk_of)"
assert_not_contains "提供的 PSK 不回显" "$OUT" "MyOwnPskForTest"
assert_contains "提示使用了提供的值" "$OUT" "已使用你提供的值"
new_m i4
OUT=$("$PM" snell install 2>&1)
assert_eq "不指定端口时随机端口安装" 0 $?
P=$(sed -n 's/^listen = 0.0.0.0://p' "$A$conf")
if [ "$P" -ge 10240 ] && [ "$P" -le 31999 ]; then t_pass "随机端口在 10240 到 31999"; else t_fail "随机端口范围" "$P"; fi
# 参数错误: 返回 2 且没有任何改动
new_m i5
BEFORE=$(snap)
for a in "--port 80" "--port abc" "--listen bad" "--release 7.0" "--release v5.0.1" "--port 20000 --listen 0.0.0.0:20001" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" snell install $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
printf 'short\n' | "$PM" snell install --psk-stdin >/dev/null 2>&1
assert_eq "无效 PSK 返回 2" 2 $?
assert_eq "参数错误没有改动任何文件" "$BEFORE" "$(snap)"
# 端口被占用
new_m i6
mk_net "$A" tcp "   0: 00000000:4E20 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 7 1 0"
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
assert_eq "端口被占用拒绝" 1 $?
assert_eq "端口被占用没有改动" "$BEFORE" "$(snap)"
# 非 root
new_m i7
OUT=$(APM_EUID=1000 "$PM" snell install --port 20000 2>&1)
assert_eq "非 root 拒绝" 4 $?
assert_contains "非 root 提示" "$OUT" "需要 root"

# ---- install 拒绝: External 与残留 ----
new_m e1
mk_snell_init "$A" external
mk_elf_stub "$A/usr/local/bin/snell-server" "$MSG_OK"
mkdir -p "$A/etc" "$A/var/log/snell"
printf '[snell-server]\nlisten = 0.0.0.0:43817\npsk = FAKEPSKFAKEPSKFAKEPSK1234\nmode = default\n' > "$A/etc/snell-server.conf"
BEFORE=$(snap)
OUT=$("$PM" snell install --port 20000 2>&1)
assert_eq "External 存在时 install 拒绝" 4 $?
assert_contains "External 提示" "$OUT" "发现现有 Snell 部署"
assert_eq "External 存在时没有改动" "$BEFORE" "$(snap)"
assert_eq "没有调用 rc-service 写动作" "" "$(grep -v ' status$' "$K/calls" 2>/dev/null)"
new_m e2
mk_snell_init "$A" external
BEFORE=$(snap)
"$PM" snell install >/dev/null 2>&1
assert_eq "只有服务脚本残留也拒绝" 4 $?
assert_eq "服务脚本残留没有改动" "$BEFORE" "$(snap)"
new_m e3
mkdir -p "$A/var/lib/alpine-proxy-manager/cores"
printf 'managed=true\ncore=snell\n' > "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
BEFORE=$(snap)
OUT=$("$PM" snell install 2>&1)
assert_eq "只有元数据残留也拒绝" 4 $?
assert_contains "元数据残留提示" "$OUT" "残留的 Manager 元数据"
assert_eq "元数据残留没有改动" "$BEFORE" "$(snap)"
new_m e4
mk_script_bin "$A/usr/local/bin/snell-server" "$SM"
BEFORE=$(snap)
"$PM" snell install >/dev/null 2>&1
assert_eq "同名脚本入口存在时拒绝" 4 $?
assert_eq "脚本入口没有被执行" "" "$(ls "$SM")"
assert_eq "脚本入口没有改动" "$BEFORE" "$(snap)"
# 元数据损坏而二进制与服务都在: 不得当作 external 覆盖
new_m e5
"$PM" snell install --port 20000 >/dev/null 2>&1
printf 'this is not key value\n' > "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
BEFORE=$(snap)
OUT=$("$PM" snell install 2>&1)
assert_eq "元数据损坏时 install 拒绝" 4 $?
assert_contains "元数据损坏提示归属不明" "$OUT" "归属不明"
for c in start stop restart "config set mode default" update uninstall; do
    # shellcheck disable=SC2086
    "$PM" snell $c >/dev/null 2>&1
    assert_eq "元数据损坏时 $c 拒绝" 4 $?
done
assert_eq "元数据损坏时没有任何改动" "$BEFORE" "$(snap)"
out=$("$PM" snell status)
assert_contains "元数据损坏的 status 提示归属不明" "$(printf '%s' "$out"; "$PM" snell info)" "元数据"

# 保留的有效配置会被沿用, 无效配置被拒绝
new_m r1
mkdir -p "$A/etc/snell"
printf '[snell-server]\nlisten = 0.0.0.0:20010\npsk = ReusedPskReusedPsk1234567890ab\nmode = default\n' > "$A/etc/snell/snell-server.conf"
OUT=$("$PM" snell install 2>&1)
assert_eq "沿用保留的配置" 0 $?
assert_contains "沿用提示" "$OUT" "沿用已保留的配置"
assert_not_contains "沿用配置时不显示 PSK" "$OUT" "ReusedPsk"
assert_eq "沿用配置的 PSK 未变" ReusedPskReusedPsk1234567890ab "$(psk_of)"
assert_contains "沿用配置的监听" "$CF_LISTEN$(cat "$A$conf")" "0.0.0.0:20010"
new_m r2
mkdir -p "$A/etc/snell"
printf '[snell-server]\nlisten = nonsense\npsk = x\n' > "$A/etc/snell/snell-server.conf"
BEFORE=$(snap)
"$PM" snell install >/dev/null 2>&1
assert_eq "无效的保留配置拒绝" 4 $?
assert_eq "无效的保留配置没有改动" "$BEFORE" "$(snap)"

# ---- install 失败必须完整回滚 ----
fail_case() { # 名称 期望非零
    assert_eq "$1: 返回非零" 1 "$([ "$2" -ne 0 ] && echo 1 || echo 0)"
    assert_eq "$1: 回滚后文件树与账户和安装前一致" "$BEFORE" "$(snap)"
    assert_fail "$1: 没有元数据" test -e "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
    assert_fail "$1: 没有运行级别链接" test -e "$A/etc/runlevels/default/snell"
    assert_eq "$1: 服务不在运行" stopped "$(cat "$K/state")"
}
new_m f1
BEFORE=$(snap)
APM_TEST_DL_FAIL=1 "$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "下载失败" $?
unset APM_TEST_DL_FAIL
new_m f2
BEFORE=$(snap)
"$PM" snell install --port 20000 --release v6.0.0rc8 >/dev/null 2>&1
fail_case "zip 损坏" $?
new_m f3
BEFORE=$(snap)
"$PM" snell install --port 20000 --release v6.0.0rc7 >/dev/null 2>&1
fail_case "zip 内没有 snell-server" $?
new_m f4
BEFORE=$(snap)
"$PM" snell install --port 20000 --release v6.0.0rc6 >/dev/null 2>&1
fail_case "zip 内是脚本 (非 ELF)" $?
assert_eq "zip 内的脚本没有被执行" "" "$(ls "$SM")"
new_m f5
BEFORE=$(snap)
"$PM" snell install --port 20000 --release v6.0.0rc5 >/dev/null 2>&1
fail_case "-v 给不出版本" $?
new_m f6
BEFORE=$(snap)
"$PM" snell install --port 20000 --release v6.0.0rc4 >/dev/null 2>&1
fail_case "release 不存在 (下载失败)" $?
new_m f7
touch "$K/fail_apk"
printf 'gcompat is missing\n' > /dev/null
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "依赖安装失败" $?
new_m f8
touch "$K/fail_adduser"
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "创建用户失败" $?
assert_eq "用户组也被回滚" "" "$(cat "$A/etc/group")"
new_m f9
touch "$K/fail_rcupdate"
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "rc-update 失败" $?
new_m f10
touch "$K/fail_start"
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "start 失败" $?
assert_contains "start 失败后调用过 stop 来清理" "$(calls)" "snell stop"
new_m f11
touch "$K/no_listen"
BEFORE=$(snap)
OUT=$("$PM" snell install --port 20000 2>&1)
fail_case "监听验证失败" $?
assert_contains "监听验证失败提示" "$OUT" "没有在"
assert_contains "监听验证失败后调用过 stop" "$(calls)" "snell stop"
new_m f12
BEFORE=$(snap)
snell_validate_config() { return 1; }
OUT=$(snell_install --port 20000 2>&1)
RC=$?
t_load snell
fail_case "配置校验失败" "$RC"
new_m f13
BEFORE=$(snap)
_snell_write_init() { return 1; }
OUT=$(snell_install --port 20000 2>&1)
RC=$?
t_load snell
fail_case "服务脚本写入失败" "$RC"
new_m f14
BEFORE=$(snap)
_snell_write_meta() { return 1; }
OUT=$(snell_install --port 20000 2>&1)
RC=$?
t_load snell
fail_case "元数据写入失败" "$RC"
assert_contains "元数据写入失败时已经启动过再被停止" "$(calls)" "snell stop"
new_m f15
BEFORE=$(snap)
_snell_chown() { return 1; }
OUT=$(snell_install --port 20000 2>&1)
RC=$?
t_load snell
fail_case "设置属主失败" "$RC"
# 回滚时不删除原本就存在的用户
new_m f16
echo 'snell:x:100:101::/var/empty:/sbin/nologin' > "$A/etc/passwd"
echo 'snell:x:101:' > "$A/etc/group"
touch "$K/fail_rcupdate"
BEFORE=$(snap)
"$PM" snell install --port 20000 >/dev/null 2>&1
fail_case "已有用户时 rc-update 失败" $?
assert_contains "已有的用户未被删除" "$(cat "$A/etc/passwd")" "snell:x:100"

# ---- start stop restart ----
new_m l1
"$PM" snell install --port 20000 >/dev/null 2>&1
: > "$K/calls"
OUT=$("$PM" snell start 2>&1)
assert_eq "已运行时 start 成功" 0 $?
assert_contains "已运行时 start 是空操作" "$OUT" "已经在运行"
assert_eq "已运行时没有调用 start" 0 "$(count_calls start)"
OUT=$("$PM" snell stop 2>&1)
assert_eq "stop 成功" 0 $?
assert_contains "stop 输出" "$OUT" "已停止"
core_discover snell
assert_eq "stop 后状态" stopped "$CF_STATE"
assert_eq "stop 后没有服务进程" "" "$CF_PID"
OUT=$("$PM" snell stop 2>&1)
assert_eq "已停止时 stop 成功" 0 $?
assert_contains "已停止时 stop 是空操作" "$OUT" "已经停止"
OUT=$("$PM" snell start 2>&1)
assert_eq "start 成功" 0 $?
assert_contains "start 输出" "$OUT" "已启动并验证"
assert_ok "start 后运行中" running
OUT=$("$PM" snell restart 2>&1)
assert_eq "restart 成功" 0 $?
assert_contains "restart 输出" "$OUT" "已重启并验证"
assert_ok "restart 后运行中" running
assert_fail "全程没有违规动作" test -e "$K/violations"
# 失败
touch "$K/fail_restart"
OUT=$("$PM" snell restart 2>&1)
assert_eq "restart 失败返回 1" 1 $?
assert_contains "restart 失败提示" "$OUT" "restart 失败"
rm -f "$K/fail_restart"
"$PM" snell stop >/dev/null 2>&1
touch "$K/fail_start"
OUT=$("$PM" snell start 2>&1)
assert_eq "start 失败返回 1" 1 $?
assert_contains "start 失败提示" "$OUT" "start 失败"
rm -f "$K/fail_start"
"$PM" snell start >/dev/null 2>&1
touch "$K/fail_stop"
OUT=$("$PM" snell stop 2>&1)
assert_eq "stop 失败返回 1" 1 $?
rm -f "$K/fail_stop"
touch "$K/no_listen"
"$PM" snell restart >/dev/null 2>&1
assert_eq "restart 后不监听返回 1" 1 $?
rm -f "$K/no_listen"
"$PM" snell restart >/dev/null 2>&1

# broken (managed 但二进制给不出版本): start 与 restart 拒绝, stop 与 update 允许
new_m l2
"$PM" snell install --port 20000 >/dev/null 2>&1
mk_elf_stub "$A/usr/local/bin/snell-server" "garbage"
core_discover snell
assert_eq "managed 二进制损坏: 状态 broken" broken "$CF_STATE"
"$PM" snell start >/dev/null 2>&1
assert_eq "broken 时 start 拒绝" 4 $?
"$PM" snell restart >/dev/null 2>&1
assert_eq "broken 时 restart 拒绝" 4 $?
"$PM" snell config set mode default >/dev/null 2>&1
assert_eq "broken 时 config set 拒绝" 4 $?
"$PM" snell stop >/dev/null 2>&1
assert_eq "broken 时 stop 允许" 0 $?
OUT=$("$PM" snell update 2>&1)
assert_eq "broken 时 update 允许并修复" 0 $?
core_discover snell
assert_eq "update 修复后状态" stopped "$CF_STATE"
assert_eq "update 修复后版本" v6.0.0 "$CF_VERSION_REPORTED"

# ---- External 保护 ----
new_m x1
mk_snell_init "$A" external
mk_elf_stub "$A/usr/local/bin/snell-server" "$MSG_OK"
printf '[snell-server]\nlisten = 0.0.0.0:43817\npsk = FAKEPSKFAKEPSKFAKEPSK1234\nmode = default\n' > "$A/etc/snell-server.conf"
echo started > "$K/state"
BEFORE=$(snap)
for c in start stop restart "config set mode default" "config set listen 0.0.0.0:20000" update "update --force" uninstall "uninstall --purge"; do
    # shellcheck disable=SC2086
    OUT=$("$PM" snell $c 2>&1)
    assert_eq "External: $c 拒绝返回 4" 4 $?
    assert_contains "External: $c 提示未被管理" "$OUT" "不是由 Alpine Proxy Manager 管理"
done
assert_eq "External: 所有写操作都没有改动文件" "$BEFORE" "$(snap)"
assert_eq "External: 没有调用 rc-service 写动作" "" "$(grep -v ' status$' "$K/calls" 2>/dev/null | grep -v '^$')"
assert_eq "External: 状态仍可读取" 0 "$("$PM" snell status >/dev/null 2>&1; echo $?)"
assert_eq "adopt 未实现" 3 "$("$PM" snell adopt >/dev/null 2>&1; echo $?)"
assert_eq "migrate 未实现" 3 "$("$PM" snell migrate >/dev/null 2>&1; echo $?)"

# ---- config ----
new_m c1
"$PM" snell install --port 20000 >/dev/null 2>&1
PSK=$(psk_of)
OUT=$("$PM" snell config 2>&1)
assert_contains "config show: listen" "$OUT" "listen：0.0.0.0:20000"
assert_contains "config show: psk 已配置" "$OUT" "psk：已配置"
assert_not_contains "config show: 不泄露 PSK" "$OUT" "$PSK"
assert_not_contains "config show: 不泄露 PSK 片段" "$OUT" "$(printf '%s' "$PSK" | cut -c1-6)"
OUT=$("$PM" snell config show 2>&1)
assert_contains "config show 标题" "$OUT" "PSK 已脱敏"
# 修改 listen
: > "$K/calls"
OUT=$("$PM" snell config set listen 0.0.0.0:20020 2>&1)
assert_eq "set listen 成功" 0 $?
assert_contains "set listen 输出" "$OUT" "listen 已更新为 0.0.0.0:20020"
assert_contains "配置已改" "$(cat "$A$conf")" "listen = 0.0.0.0:20020"
assert_eq "set listen 保留 PSK" "$PSK" "$(psk_of)"
core_discover snell
assert_eq "旧端口消失新端口监听" "tcp 0.0.0.0:20020 50000" "$CF_LISTEN"
assert_eq "set listen 触发 restart" 1 "$(count_calls restart)"
assert_eq "元数据没有被改乱" v6.0.0rc2 "$(kv_get "$A/var/lib/alpine-proxy-manager/cores/snell.meta" exact_release)"
assert_eq "配置权限保持" 640 "$(stat -c %a "$A$conf")"
BK=$(ls "$A/var/lib/alpine-proxy-manager/backups"/snell-server.conf.bak.* 2>/dev/null | head -n 1)
assert_ok "修改前备份了旧配置" test -f "$BK"
assert_eq "配置备份权限 0600" 600 "$(stat -c %a "$BK")"
assert_eq "没有遗留候选文件" 0 "$(ls -A "$A/etc/snell" | grep -c 'cand')"
# 端口被占用
mk_net "$A" tcp6 "   0: 00000000000000000000000000000000:4E2C 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 9 1 0"
OUT=$("$PM" snell config set listen 0.0.0.0:20012 2>&1)
assert_eq "set listen 到已占用端口拒绝" 1 $?
assert_contains "占用提示" "$OUT" "已被占用"
mk_net "$A" tcp6 ""
# mode
OUT=$("$PM" snell config set mode default 2>&1)
assert_eq "set mode default 成功" 0 $?
"$PM" snell config set mode turbo >/dev/null 2>&1
assert_eq "未确认的 mode 被拒绝" 2 $?
# 参数错误
"$PM" snell config set listen bad >/dev/null 2>&1
assert_eq "listen 无效返回 2" 2 $?
"$PM" snell config set bogus x >/dev/null 2>&1
assert_eq "未知键返回 2" 2 $?
"$PM" snell config set psk SomePlainTextSecret1234567890 >/dev/null 2>&1
assert_eq "psk 不接受命令行明文" 2 $?
assert_eq "拒绝后配置未改" "$PSK" "$(psk_of)"
# psk
OUT=$(printf 'NewPskFromStdin0123456789abcd\n' | "$PM" snell config set psk --stdin 2>&1)
assert_eq "set psk --stdin 成功" 0 $?
assert_eq "psk 已更新" NewPskFromStdin0123456789abcd "$(psk_of)"
assert_not_contains "psk --stdin 不回显" "$OUT" "NewPskFromStdin"
OUT=$("$PM" snell config set psk --generate 2>&1)
assert_eq "set psk --generate 成功" 0 $?
NEWP=$(psk_of)
assert_eq "生成的 PSK 长度" 32 "${#NEWP}"
assert_contains "生成的 PSK 显示一次" "$OUT" "新 PSK：$NEWP"
assert_eq "生成的 PSK 只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$NEWP")"
printf 'short\n' | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "无效 psk 返回 2" 2 $?
assert_eq "无效 psk 没有改配置" "$NEWP" "$(psk_of)"
assert_ok "全程仍在运行" running
BN=$(ls "$A/var/lib/alpine-proxy-manager/backups"/snell-server.conf.bak.* | wc -l | tr -d ' ')
assert_eq "配置备份最多保留 2 份 (含凭据, 限制份数)" 2 "$BN"
assert_eq "元数据始终不含 PSK" 0 "$(grep -c "$NEWP" "$A/var/lib/alpine-proxy-manager/cores/snell.meta")"

# 新配置导致 Snell 无法启动: 恢复旧配置与服务
echo 20030 > "$K/fail_port"
OLDCONF=$(cat "$A$conf")
OLDSTAT=$(stat -c '%a' "$A$conf")
OUT=$("$PM" snell config set listen 0.0.0.0:20030 2>&1)
assert_eq "新配置无法启动返回 1" 1 $?
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
assert_contains "回滚后服务恢复提示" "$OUT" "已恢复旧配置并验证 Snell 正常运行"
assert_eq "旧配置内容恢复" "$OLDCONF" "$(cat "$A$conf")"
assert_eq "旧配置权限恢复" "$OLDSTAT" "$(stat -c '%a' "$A$conf")"
assert_ok "回滚后服务运行" running
core_discover snell
assert_contains "回滚后监听是旧端口" "$CF_LISTEN" "0.0.0.0:20020"
: > "$K/fail_port"
# 服务停止时修改配置: 不启动服务
"$PM" snell stop >/dev/null 2>&1
OUT=$("$PM" snell config set listen 0.0.0.0:20040 2>&1)
assert_eq "停止时 set 成功" 0 $?
assert_contains "停止时提示下次启动生效" "$OUT" "下次启动生效"
core_discover snell
assert_eq "停止时 set 不会启动服务" stopped "$CF_STATE"
"$PM" snell start >/dev/null 2>&1
# 配置里的未知键被保留 (dns-ip-preference)
"$PM" snell stop >/dev/null 2>&1
printf 'dns-ip-preference = default\n' >> "$A$conf"
"$PM" snell config set mode default >/dev/null 2>&1
assert_contains "已验证的其他键被保留" "$(cat "$A$conf")" "dns-ip-preference = default"
printf 'unknown-key = 1\n' >> "$A$conf"
"$PM" snell config set mode default >/dev/null 2>&1
assert_eq "含未确认键的配置被校验器拒绝" 1 $?
assert_contains "未确认键没有被写入新配置之外" "$(cat "$A$conf")" "unknown-key = 1"

# ---- update ----
new_m u1
"$PM" snell install --port 20000 >/dev/null 2>&1
BIN1=$(cksum < "$A/usr/local/bin/snell-server")
: > "$K/calls"
OUT=$("$PM" snell update 2>&1)
assert_eq "同版本 update 成功" 0 $?
assert_contains "同版本 update 提示" "$OUT" "已经是目标版本"
assert_eq "同版本 update 没有停服务" 000 "$(count_calls stop)$(count_calls restart)$(count_calls start)"
assert_fail "同版本 update 没有下载" test -s "$K/dl.log.after"
OUT=$("$PM" snell update v6.0.0-rc2 2>&1)
assert_contains "连字符写法同样识别为已是目标版本" "$OUT" "已经是目标版本"
: > "$K/calls"
OUT=$("$PM" snell update --force 2>&1)
assert_eq "--force 成功" 0 $?
assert_contains "--force 输出" "$OUT" "更新完成并已验证"
assert_eq "--force 停止并启动" "1 1" "$(count_calls stop) $(count_calls start)"
assert_eq "--force 二进制内容相同 (同 release)" "$BIN1" "$(cksum < "$A/usr/local/bin/snell-server")"
assert_ok "--force 后运行中" running
assert_fail "--force 后没有 .old 与 .new 遗留" test -e "$A/usr/local/bin/snell-server.old"
assert_fail "--force 后没有 .new 遗留" test -e "$A/usr/local/bin/snell-server.new"
# 更新到新 release
OUT=$("$PM" snell update v6.0.0rc3 2>&1)
assert_eq "更新到新 release 成功" 0 $?
core_discover snell
assert_eq "更新后精确发布" v6.0.0rc3 "$CF_VERSION_EXACT"
assert_eq "更新后自报版本" v6.0.1 "$CF_VERSION_REPORTED"
assert_eq "更新后元数据 reported_version" v6.0.1 "$(kv_get "$A/var/lib/alpine-proxy-manager/cores/snell.meta" reported_version)"
assert_ok "更新后运行中" running
assert_eq "更新后配置未动" 0 "$(grep -c 'listen = 0.0.0.0:20000' "$A$conf" | awk '{print ($1==1)?0:1}')"
# 失败情形
OLDBIN=$(cksum < "$A/usr/local/bin/snell-server")
OLDMETA=$(cat "$A/var/lib/alpine-proxy-manager/cores/snell.meta")
: > "$K/calls"
APM_TEST_DL_FAIL=1 "$PM" snell update v6.0.0rc2 >/dev/null 2>&1
assert_eq "update 下载失败返回 1" 1 $?
unset APM_TEST_DL_FAIL
assert_eq "update 下载失败没有停服务" 0 "$(count_calls stop)"
"$PM" snell update v6.0.0rc5 >/dev/null 2>&1
assert_eq "update 新二进制 -v 失败返回 1" 1 $?
assert_eq "update 新二进制 -v 失败没有停服务" 0 "$(count_calls stop)"
"$PM" snell update v6.0.0rc6 >/dev/null 2>&1
assert_eq "update 新二进制是脚本拒绝" 1 $?
assert_eq "update 的脚本没有被执行" "" "$(ls "$SM")"
"$PM" snell update v6.0.0rc8 >/dev/null 2>&1
assert_eq "update zip 损坏返回 1" 1 $?
assert_eq "update 失败后二进制不变" "$OLDBIN" "$(cksum < "$A/usr/local/bin/snell-server")"
assert_eq "update 失败后元数据不变" "$OLDMETA" "$(cat "$A/var/lib/alpine-proxy-manager/cores/snell.meta")"
assert_ok "update 失败后仍运行" running
touch "$K/fail_stop"
OUT=$("$PM" snell update v6.0.0rc2 2>&1)
assert_eq "update stop 失败返回 1" 1 $?
assert_contains "update stop 失败提示" "$OUT" "停止 Snell 失败"
rm -f "$K/fail_stop"
assert_eq "update stop 失败后二进制不变" "$OLDBIN" "$(cksum < "$A/usr/local/bin/snell-server")"
assert_fail "update stop 失败后没有 .old 遗留" test -e "$A/usr/local/bin/snell-server.old"
# 新版启动失败: 回滚旧二进制并恢复运行
OUT=$("$PM" snell update v6.0.0rc9 2>&1)
assert_eq "update 新版启动失败返回 1" 1 $?
assert_contains "update 新版启动失败提示回滚" "$OUT" "回滚到旧版本"
assert_contains "update 回滚后恢复运行" "$OUT" "已回滚并恢复运行"
assert_eq "update 回滚后二进制恢复" "$OLDBIN" "$(cksum < "$A/usr/local/bin/snell-server")"
assert_eq "update 回滚后元数据恢复" "$OLDMETA" "$(cat "$A/var/lib/alpine-proxy-manager/cores/snell.meta")"
assert_ok "update 回滚后运行中" running
assert_fail "update 回滚后没有 .old 遗留" test -e "$A/usr/local/bin/snell-server.old"
# 之前没在运行: 更新但不启动
"$PM" snell stop >/dev/null 2>&1
: > "$K/calls"
OUT=$("$PM" snell update v6.0.0rc2 2>&1)
assert_eq "停止状态下 update 成功" 0 $?
assert_eq "停止状态下 update 不启动服务" 0 "$(count_calls start)"
core_discover snell
assert_eq "停止状态下 update 后状态" stopped "$CF_STATE"
assert_eq "停止状态下 update 后精确发布" v6.0.0rc2 "$CF_VERSION_EXACT"
"$PM" snell update v6.0.0rc9 >/dev/null 2>&1
assert_eq "停止状态下新版二进制验证失败也不启动" 0 "$(count_calls start)"
"$PM" snell update bogus >/dev/null 2>&1
assert_eq "update 参数错误返回 2" 2 $?

# ---- uninstall ----
new_m n1
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "未安装 uninstall 返回 0" 0 $?
assert_contains "未安装提示" "$OUT" "未安装"
"$PM" snell install --port 20000 >/dev/null 2>&1
PSK=$(psk_of)
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "普通 uninstall 成功" 0 $?
assert_contains "uninstall 输出已保留" "$OUT" "已保留"
assert_fail "服务脚本已删" test -e "$A/etc/init.d/snell"
assert_fail "运行级别链接已删" test -e "$A/etc/runlevels/default/snell"
assert_fail "二进制已删" test -e "$A/usr/local/bin/snell-server"
assert_fail "元数据已删" test -e "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
assert_ok "配置保留" test -f "$A$conf"
assert_ok "日志目录保留" test -d "$A/var/log/snell"
assert_contains "用户保留" "$(cat "$A/etc/passwd")" "snell:x:"
assert_eq "服务已停止" stopped "$(cat "$K/state")"
assert_eq "卸载后无服务进程" "" "$(ls "$A/proc" | grep -c '^2375' | grep -v '^0$')"
core_discover snell
assert_eq "卸载后发现为未安装" not-installed "$CF_STATE"
# 重新安装沿用配置
OUT=$("$PM" snell install 2>&1)
assert_eq "卸载后重新安装" 0 $?
assert_contains "重新安装沿用配置" "$OUT" "沿用已保留的配置"
assert_eq "重新安装 PSK 不变" "$PSK" "$(psk_of)"
assert_not_contains "重新安装不显示 PSK" "$OUT" "$PSK"
assert_eq "重新安装后元数据仍记录创建了用户" yes "$(kv_get "$A/var/lib/alpine-proxy-manager/cores/snell.meta" created_user)"
assert_ok "重新安装后运行中" running
# purge
"$PM" snell config set mode default >/dev/null 2>&1
OUT=$("$PM" snell uninstall --purge 2>&1)
assert_eq "uninstall --purge 成功" 0 $?
assert_fail "purge 删除配置目录" test -e "$A/etc/snell"
assert_fail "purge 删除日志目录" test -e "$A/var/log/snell"
assert_eq "purge 删除配置备份" 0 "$(ls "$A/var/lib/alpine-proxy-manager/backups" 2>/dev/null | grep -c snell-server.conf)"
assert_eq "purge 删除由 Manager 创建的用户" "" "$(cat "$A/etc/passwd")"
assert_eq "purge 删除由 Manager 创建的用户组" "" "$(cat "$A/etc/group")"
assert_fail "purge 后元数据已删" test -e "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
assert_eq "purge 后没有任何含 PSK 的文件" "" "$(grep -rl "$PSK" "$A" 2>/dev/null)"
# deluser 不顺带删除用户组时, 仍由 delgroup 删除, 且不会重复警告
new_m n1b
touch "$K/deluser_keeps_group"
"$PM" snell install --port 20000 >/dev/null 2>&1
OUT=$("$PM" snell uninstall --purge 2>&1)
assert_eq "deluser 不删组时 purge 成功" 0 $?
assert_eq "deluser 不删组时用户组仍被删除" "" "$(cat "$A/etc/group")"
assert_not_contains "deluser 不删组时没有警告" "$OUT" "警告"
# deluser 顺带删除用户组 (Alpine 行为) 时, 不再调用 delgroup 也不警告
new_m n1c
"$PM" snell install --port 20000 >/dev/null 2>&1
OUT=$("$PM" snell uninstall --purge 2>&1)
assert_eq "deluser 顺带删组时 purge 成功" 0 $?
assert_not_contains "deluser 顺带删组时没有警告" "$OUT" "警告"
assert_eq "用户与用户组均已删除" "" "$(cat "$A/etc/passwd")$(cat "$A/etc/group")"
# 元数据备份在两种卸载中都被清理
new_m n1d
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" snell update --force >/dev/null 2>&1
assert_eq "update --force 产生了元数据备份" 1 "$(ls "$A/var/lib/alpine-proxy-manager/backups" | grep -c '^snell.meta.bak')"
"$PM" snell uninstall >/dev/null 2>&1
assert_eq "普通 uninstall 清理元数据备份" 0 "$(ls "$A/var/lib/alpine-proxy-manager/backups" 2>/dev/null | grep -c '^snell.meta.bak')"
# purge 不删除原本就存在的用户
new_m n2
echo 'snell:x:100:101::/var/empty:/sbin/nologin' > "$A/etc/passwd"
echo 'snell:x:101:' > "$A/etc/group"
"$PM" snell install --port 20000 >/dev/null 2>&1
assert_eq "已有用户时元数据 created_user" no "$(kv_get "$A/var/lib/alpine-proxy-manager/cores/snell.meta" created_user)"
"$PM" snell uninstall --purge >/dev/null 2>&1
assert_contains "purge 保留原本就存在的用户" "$(cat "$A/etc/passwd")" "snell:x:100"
assert_contains "purge 保留原本就存在的用户组" "$(cat "$A/etc/group")" "snell:x:101"
# stop 失败: 中止且不删除任何东西
new_m n3
"$PM" snell install --port 20000 >/dev/null 2>&1
BEFORE=$(snap)
touch "$K/fail_stop"
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "uninstall stop 失败返回 1" 1 $?
assert_contains "uninstall stop 失败提示" "$OUT" "没有删除任何文件"
rm -f "$K/fail_stop"
assert_eq "uninstall stop 失败没有删除任何东西" "$BEFORE" "$(snap)"
# 服务脚本被改成没有 Manager 标记: 保留
new_m n4
"$PM" snell install --port 20000 >/dev/null 2>&1
printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/snell-server"\n' > "$A/etc/init.d/snell"
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "无标记的服务脚本时 uninstall 仍成功" 0 $?
assert_ok "无标记的服务脚本被保留" test -f "$A/etc/init.d/snell"
assert_contains "无标记的服务脚本警告" "$OUT" "没有 Manager 标记"
# 部分文件已不存在
new_m n5
"$PM" snell install --port 20000 >/dev/null 2>&1
rm -f "$A/usr/local/bin/snell-server"
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "二进制已丢失时 uninstall 清理残留" 0 $?
assert_contains "清理提示" "$OUT" "清理 Manager 记录的残留"
assert_fail "清理后元数据已删" test -e "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
assert_fail "清理后服务脚本已删" test -e "$A/etc/init.d/snell"
# purge 完整后可以重新全新安装
new_m n6
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" snell uninstall --purge >/dev/null 2>&1
OUT=$("$PM" snell install --port 20001 2>&1)
assert_eq "purge 后全新安装" 0 $?
assert_contains "purge 后重新生成 PSK" "$OUT" "PSK："
assert_ok "purge 后运行中" running

# ---- 安全总检 ----
assert_fail "整个过程没有违规动作" test -e "$K/violations"
assert_eq "没有任何脚本被执行" "" "$(ls "$SM")"
t_done
