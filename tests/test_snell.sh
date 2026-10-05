# shellcheck shell=sh
# Snell 只读 Adapter: 发现, 版本, 状态, 配置, 日志, 监听, 归属
# 全部使用虚构数据 PSK 与日志内容均为占位
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy

PM="$T_ROOT/bin/proxy-manager"
SECRET=FAKE-PSK-DO-NOT-LEAK-0123456789abcdef

if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_snell.sh 的断言需要真实 ELF, 全部跳过"
    t_done
    exit $?
fi

# new_sys NAME 创建全新 sysroot 并导出, 带假的 rc-service 与状态目录
new_sys() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_fake_rcservice "$A"
    APM_FAKE_RC_DIR=$A/fake-rc
    mkdir -p "$APM_FAKE_RC_DIR"
    APM_SYSROOT=$A
    export APM_SYSROOT APM_FAKE_RC_DIR
    mkdir -p "$A/usr/local/bin" "$A/run" "$A/var/log"
}

mk_snell_bin() { mk_elf_stub "$A/usr/local/bin/snell-server" "$(date +%Y-%m-%d) 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.0 (Aug  7 2026)"; }

mk_conf() { # 路径 listen
    mkdir -p "$(dirname "$A$1")"
    printf '[snell-server]\nlisten = %s\npsk = %s\nmode = default\n' "$2" "$SECRET" > "$A$1"
    chmod 640 "$A$1"
}

# tw-home 形态: 监督进程加 gcompat 子进程
mk_external_procs() {
    printf '23754\n' > "$A/run/snell.pid"
    mk_proc "$A" 23754 1 supervise-daemo supervise-daemon snell --start --stdout /var/log/snell/access.log --pidfile /run/snell.pid --user snell snell /usr/local/bin/snell-server -- -c /etc/snell-server.conf
    mk_proc "$A" 23755 23754 ld-musl-x86_64. ld-linux-x86-64.so.2 --argv0 /usr/local/bin/snell-server --preload /lib/libgcompat.so.0 -- /usr/local/bin/snell-server -c /etc/snell-server.conf
}

mk_listeners() {
    mk_net "$A" tcp "   0: 00000000:AB29 00000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 12345 1 0000000000000000 100 0 0 10 0
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 777 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000     0        0 888 1 0000000000000000 100 0 0 10 0"
    mk_net "$A" tcp6 "   0: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 778 1 0000000000000000 100 0 0 10 0"
    mkdir -p "$A/proc/23755/fd"
    ln -s 'socket:[12345]' "$A/proc/23755/fd/12"
    ln -s 'socket:[999]' "$A/proc/23755/fd/13"
    ln -s '/dev/null' "$A/proc/23755/fd/0"
}

# ---- 未安装 ----
new_sys s0
core_discover snell
assert_eq "未安装: installed" no "$CF_INSTALLED"
assert_eq "未安装: state" not-installed "$CF_STATE"
assert_eq "未安装: deployment" none "$CF_DEPLOYMENT"
out=$("$PM" snell status)
assert_contains "未安装: snell status" "$out" "状态：未安装"
assert_not_contains "未安装: 不输出版本" "$out" "版本"
assert_fail "未安装时不调用 rc-service" test -e "$APM_FAKE_RC_DIR/calls"

# ---- 有二进制 没有服务 ----
new_sys s1
mk_snell_bin
core_discover snell
assert_eq "无服务: installed" yes "$CF_INSTALLED"
assert_eq "无服务: 服务为空" "" "$CF_SERVICE"
assert_eq "无服务: 服务状态" none "$CF_SERVICE_STATE"
assert_eq "无服务: 无进程时未运行" stopped "$CF_STATE"
assert_eq "无服务: 版本" v6.0.0 "$CF_VERSION_REPORTED"
assert_fail "无服务时不调用 rc-service" test -e "$APM_FAKE_RC_DIR/calls"
mk_proc "$A" 500 1 ld-musl-x86_64. ld-linux-x86-64.so.2 --argv0 /usr/local/bin/snell-server -- /usr/local/bin/snell-server -c /x.conf
core_discover snell
assert_eq "无服务: 命令行匹配到进程则运行中" running "$CF_STATE"
assert_eq "无服务: 来源是进程" process "$CF_RUNNING_SOURCE"
assert_eq "无服务: 进程号" 500 "$CF_PID"
rm -rf "$A/proc/500"
mk_proc "$A" 501 1 snell-server /bin/sleep 100
core_discover snell
assert_eq "只有 comm 等于 snell-server 不算运行" stopped "$CF_STATE"
rm -rf "$A/proc/501"
# 版本查询留下的瞬时 timeout 进程命令行里也有二进制路径, 不能算服务进程 (HK-IXP2 真机发现)
mk_proc "$A" 502 1 timeout timeout 5 /usr/local/bin/snell-server -v
core_discover snell
assert_eq "timeout 包着的版本查询进程不算服务进程" stopped "$CF_STATE"
assert_eq "timeout 包着的版本查询进程没有 PID" "" "$CF_PID"
rm -rf "$A/proc/502"

# ---- External + OpenRC running (tw-home 形态, gcompat) ----
new_sys s2
mk_snell_bin
mk_snell_init "$A" external
mk_conf /etc/snell-server.conf 0.0.0.0:43817
mkdir -p "$A/var/log/snell"
: > "$A/var/log/snell/access.log"
printf '2026-01-01 00:00:00.000000 [server_tunnel-1] <WARN> fictional warning one\n2026-01-01 00:00:01.000000 [server_tunnel-2] <WARN> fictional warning two\n' > "$A/var/log/snell/error.log"
mk_external_procs
mk_listeners
printf 'started' > "$APM_FAKE_RC_DIR/snell"
core_discover snell
assert_eq "external running: state" running "$CF_STATE"
assert_eq "external running: 状态来源是 rc-service" rc-service "$CF_SERVICE_SOURCE"
assert_eq "external running: 服务名" snell "$CF_SERVICE"
assert_eq "external running: 服务脚本" /etc/init.d/snell "$CF_SERVICE_FILE"
assert_eq "external running: 是 openrc-run 脚本" yes "$CF_SERVICE_OPENRC"
assert_eq "external running: 托管" supervise-daemon "$CF_SUPERVISOR"
assert_eq "external running: 用户" snell:snell "$CF_SERVICE_USER"
assert_eq "external running: pidfile 变量展开" /run/snell.pid "$CF_PIDFILE"
assert_eq "external running: 监督进程" 23754 "$CF_SUP_PID"
assert_eq "external running: 服务进程是监督进程的子进程而不是 pidfile 里的进程" 23755 "$CF_PID"
assert_eq "external running: comm 是 ld-musl 也判为运行" ld-musl-x86_64. "$(cat "$A/proc/23755/comm")"
assert_eq "external running: 版本" v6.0.0 "$CF_VERSION_REPORTED"
assert_eq "external running: 精确发布未知" unknown "$CF_VERSION_EXACT"
assert_eq "external running: 版本来源" binary "$CF_VERSION_SOURCE"
assert_eq "external running: 未接管" no "$CF_MANAGED"
assert_eq "external running: 部署类型" external "$CF_DEPLOYMENT"
assert_eq "external running: 配置路径来自服务脚本" /etc/snell-server.conf "$CF_CONFIG"
assert_eq "external running: 配置来源" service "$CF_CONFIG_SOURCE"
assert_eq "external running: 配置存在" yes "$CF_CONFIG_EXISTS"
assert_contains "external running: 权限" "$CF_CONFIG_PERM" "640"
assert_eq "external running: 字段名" "listen psk mode" "$CF_CONFIG_KEYS"
assert_eq "external running: listen" 0.0.0.0:43817 "$CF_SNELL_LISTEN"
assert_eq "external running: mode" default "$CF_SNELL_MODE"
assert_eq "external running: psk 只记录是否配置" configured "$CF_PSK"
assert_eq "external running: access 日志" /var/log/snell/access.log "$CF_LOG_OUT"
assert_eq "external running: error 日志" /var/log/snell/error.log "$CF_LOG_ERR"
assert_eq "external running: access 日志存在且大小为 0" "yes 0" "$CF_LOG_OUT_EXISTS $CF_LOG_OUT_SIZE"
assert_eq "external running: error 日志存在" yes "$CF_LOG_ERR_EXISTS"
assert_eq "external running: 监听按进程 socket 归属" pid "$CF_LISTEN_ATTRIB"
assert_eq "external running: 只包含该进程的监听" "tcp 0.0.0.0:43817 12345" "$CF_LISTEN"
assert_eq "无 PSK 的变量保存 (不得出现完整值)" "" "$(printf '%s' "$CF_SNELL_LISTEN$CF_SNELL_MODE$CF_CONFIG_KEYS" | grep -o 'FAKE-PSK' )"
assert_fail "只调用了 status, 没有违规操作" test -e "$APM_FAKE_RC_DIR/violations"
assert_eq "rc-service 被调用且仅为 status" "snell status" "$(sort -u "$APM_FAKE_RC_DIR/calls")"

# CLI 输出与脱敏
out=$("$PM" core list)
assert_contains "core list: 运行中" "$out" "状态：运行中"
assert_contains "core list: 版本" "$out" "版本：v6.0.0 (二进制自报)"
assert_contains "core list: 来源" "$out" "来源：现有部署"
assert_contains "core list: 管理状态" "$out" "管理状态：未接管"
out=$("$PM" status)
assert_contains "status: Core 行" "$out" "运行中 (现有部署, 未接管)"
out=$("$PM" snell status)
assert_contains "snell status: 运行中" "$out" "状态：运行中"
assert_contains "snell status: OpenRC 来源" "$out" "服务 snell 状态 started (来源 rc-service)"
assert_contains "snell status: 监听" "$out" "tcp 0.0.0.0:43817"
assert_contains "snell status: 监听归属说明" "$out" "按进程 23755 的 socket 确认"
assert_not_contains "snell status: 不含其他进程的 22 端口" "$out" "0.0.0.0:22"
assert_contains "snell status: 提示不是公网映射" "$out" "不是公网映射端口"
out=$("$PM" snell info)
assert_contains "info: 部署类型" "$out" "部署类型：external"
assert_contains "info: 版本来源" "$out" "版本来源：binary"
assert_contains "info: 精确发布" "$out" "精确发布：unknown"
assert_contains "info: 二进制类型" "$out" "类型 elf"
assert_contains "info: 监督进程" "$out" "监督进程 PID：23754"
assert_contains "info: 服务进程" "$out" "服务进程 PID：23755"
assert_contains "info: 配置权限" "$out" "配置权限：640"
assert_contains "info: 字段名" "$out" "配置字段：listen psk mode"
assert_contains "info: psk 状态" "$out" "psk：已配置"
assert_contains "info: error 日志 metadata" "$out" "error 日志：/var/log/snell/error.log ("
assert_not_contains "info: 不泄露 PSK 完整值" "$out" "$SECRET"
assert_not_contains "info: 不泄露 PSK 片段" "$out" "FAKE-PSK"
assert_not_contains "info: 不泄露 PSK 末尾" "$out" "abcdef"
assert_not_contains "info: 不泄露 PSK 数字段" "$out" "0123456789"
for c in status info; do
    out=$("$PM" snell "$c" 2>&1)
    assert_not_contains "snell $c: 不泄露 PSK" "$out" "DO-NOT-LEAK"
done
assert_fail "整个过程没有违规的 rc-service 调用" test -e "$APM_FAKE_RC_DIR/violations"

# ---- 日志 ----
out=$("$PM" snell log)
assert_contains "log: 带敏感提示" "$out" "可能包含访问的目标域名"
assert_contains "log: 默认读取 error 日志" "$out" "fictional warning two"
out=$("$PM" snell log 1)
assert_contains "log 1: 只有最后一行" "$out" "fictional warning two"
assert_not_contains "log 1: 不含前一行" "$out" "fictional warning one"
i=0
: > "$A/var/log/snell/error.log"
while [ "$i" -lt 300 ]; do printf 'line %s\n' "$i" >> "$A/var/log/snell/error.log"; i=$((i + 1)); done
out=$("$PM" snell log 999)
assert_eq "log 上限 200 行加一行标题" 201 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_contains "log 上限取最后 200 行" "$out" "line 299"
assert_not_contains "log 上限不含更早的行" "$out" "line 99"
assert_rc "log 非数字拒绝" 2 "$PM" snell log abc
assert_rc "log 0 拒绝" 2 "$PM" snell log 0
rm -f "$A/var/log/snell/error.log"
assert_rc "log 文件不存在返回 1" 1 "$PM" snell log
core_discover snell
assert_eq "日志不存在: exists" no "$CF_LOG_ERR_EXISTS"
out=$("$PM" snell info)
assert_contains "日志不存在: info" "$out" "error 日志：/var/log/snell/error.log (不存在)"

# ---- External stopped / crashed ----
printf 'stopped' > "$APM_FAKE_RC_DIR/snell"
rm -rf "$A/proc/23754" "$A/proc/23755"
core_discover snell
assert_eq "external stopped" stopped "$CF_STATE"
assert_eq "stopped 时不报告监听" "" "$CF_LISTEN"
out=$("$PM" snell status)
assert_contains "stopped: snell status" "$out" "状态：未运行"
printf 'crashed' > "$APM_FAKE_RC_DIR/snell"
core_discover snell
assert_eq "external crashed" crashed "$CF_STATE"
printf 'started' > "$APM_FAKE_RC_DIR/snell"

# OpenRC running 但找不到进程 (pidfile 失效): 仍以 OpenRC 为准
core_discover snell
assert_eq "OpenRC started 但没有进程信息: 仍判运行中" running "$CF_STATE"
assert_eq "没有进程信息: PID 为空" "" "$CF_PID"
assert_eq "没有进程信息: 监听按配置端口匹配" config-port "$CF_LISTEN_ATTRIB"
assert_contains "没有进程信息: 监听包含配置端口" "$CF_LISTEN" "0.0.0.0:43817"
assert_not_contains "按配置端口匹配不会带入其他端口" "$CF_LISTEN" ":22 "
mk_external_procs

# ---- 无监听 ----
mk_net "$A" tcp ""
mk_net "$A" tcp6 ""
core_discover snell
assert_eq "无监听" "" "$CF_LISTEN"
out=$("$PM" snell status)
assert_contains "无监听: 输出" "$out" "监听：未观察到"
# UDP
mk_net "$A" udp "   0: 00000000:AB29 00000000:0000 07 00000000:00000000 00:00000000 00000000   100        0 54321 2 0000000000000000 0"
mk_net "$A" tcp ""
mkdir -p "$A/proc/23755/fd"
ln -s 'socket:[54321]' "$A/proc/23755/fd/20"
core_discover snell
assert_eq "UDP 监听可被识别" "udp 0.0.0.0:43817 54321" "$CF_LISTEN"
# IPv6 监听
mk_net "$A" tcp6 "   0: 00000000000000000000000000000000:AB29 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 6006 1 0"
ln -s 'socket:[6006]' "$A/proc/23755/fd/21"
core_discover snell
assert_contains "IPv6 监听可被识别" "$CF_LISTEN" "tcp [::]:43817 6006"
mk_net "$A" tcp6 "   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 6007 1 0"
ln -s 'socket:[6007]' "$A/proc/23755/fd/22"
core_discover snell
assert_contains "IPv6 回环监听" "$CF_LISTEN" "tcp [::1]:8080 6007"
mk_net "$A" udp ""
mk_net "$A" tcp6 ""

# ---- 配置: Snell-Alpine 风格 ----
new_sys s3
mk_snell_bin
mk_snell_init "$A" alpine
mk_conf /etc/snell/snell-server.conf "0.0.0.0:20000,[::]:20000"
printf 'one\ntwo\n' > "$A/var/log/snell.log"
printf 'started' > "$APM_FAKE_RC_DIR/snell"
core_discover snell
assert_eq "alpine 风格: 配置路径来自 command_args" /etc/snell/snell-server.conf "$CF_CONFIG"
assert_eq "alpine 风格: 配置来源" service "$CF_CONFIG_SOURCE"
assert_eq "alpine 风格: listen 含多个地址" "0.0.0.0:20000,[::]:20000" "$CF_SNELL_LISTEN"
assert_eq "alpine 风格: 日志同一文件" "/var/log/snell.log /var/log/snell.log" "$CF_LOG_OUT $CF_LOG_ERR"
assert_eq "alpine 风格: 状态" running "$CF_STATE"
assert_eq "alpine 风格: 无进程时 PID 为空" "" "$CF_PID"
out=$("$PM" snell log 1)
assert_contains "alpine 风格: 读取日志" "$out" "two"
mk_net "$A" tcp "   0: 00000000:4E20 00000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 31 1 0"
mk_net "$A" tcp6 "   0: 00000000000000000000000000000000:4E20 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 32 1 0"
core_discover snell
assert_contains "alpine 风格: 双栈端口均被匹配" "$CF_LISTEN" "tcp [::]:20000"
assert_contains "alpine 风格: IPv4 端口被匹配" "$CF_LISTEN" "tcp 0.0.0.0:20000"

# ---- 配置: 无服务脚本时的默认候选 ----
new_sys s4
mk_snell_bin
mk_conf /etc/snell/snell-server.conf 0.0.0.0:21000
core_discover snell
assert_eq "默认候选: 路径" /etc/snell/snell-server.conf "$CF_CONFIG"
assert_eq "默认候选: 来源" default-candidate "$CF_CONFIG_SOURCE"
rm -f "$A/etc/snell/snell-server.conf"
mk_conf /etc/snell-server.conf 0.0.0.0:21001
core_discover snell
assert_eq "默认候选: 平铺路径" /etc/snell-server.conf "$CF_CONFIG"
rm -f "$A/etc/snell-server.conf"
core_discover snell
assert_eq "默认候选: 都不存在" "" "$CF_CONFIG"
out=$("$PM" snell info)
assert_contains "无配置: info" "$out" "配置：未找到"

# ---- 配置: 不存在 与 无权限 ----
new_sys s5
mk_snell_bin
mk_snell_init "$A" external
printf 'started' > "$APM_FAKE_RC_DIR/snell"
core_discover snell
assert_eq "服务声明了配置但文件不存在: 路径" /etc/snell-server.conf "$CF_CONFIG"
assert_eq "服务声明了配置但文件不存在: exists" no "$CF_CONFIG_EXISTS"
assert_contains "配置不存在提示" "$CF_NOTES" "不存在"
mk_conf /etc/snell-server.conf 0.0.0.0:43817
# shellcheck disable=SC2317,SC2329
_core_can_read() { case $1 in */snell-server.conf) return 1 ;; *) [ -r "$1" ] ;; esac; }
core_discover snell
assert_eq "无读取权限: exists" yes "$CF_CONFIG_EXISTS"
assert_eq "无读取权限: readable" no "$CF_CONFIG_READABLE"
assert_eq "无读取权限: 不读取字段" "" "$CF_CONFIG_KEYS"
assert_eq "无读取权限: 不读取 listen" "" "$CF_SNELL_LISTEN"
assert_eq "无读取权限: psk 状态未知" unknown "$CF_PSK"
assert_contains "无读取权限提示" "$CF_NOTES" "无读取权限"
unset -f _core_can_read
t_load core

# ---- 归属: 元数据 ----
new_sys s6
mk_snell_bin
mk_snell_init "$A" external
mk_conf /etc/snell-server.conf 0.0.0.0:43817
printf 'started' > "$APM_FAKE_RC_DIR/snell"
APM_VAR=$A/var/lib/alpine-proxy-manager
export APM_VAR
mkdir -p "$APM_VAR/cores"
core_discover snell
assert_eq "无元数据: 未接管" no "$CF_MANAGED"
assert_eq "无元数据: external" external "$CF_DEPLOYMENT"
# 二进制路径相同不等于 managed
printf 'managed=true\ncore=snell\nbinary=/usr/local/bin/snell-server\nexact_release=v6.0.0rc2\n' > "$APM_VAR/cores/snell.meta"
core_discover snell
assert_eq "有元数据: 接管" yes "$CF_MANAGED"
assert_eq "有元数据: managed" managed "$CF_DEPLOYMENT"
assert_eq "有元数据: 精确发布优先于二进制自报" v6.0.0rc2 "$CF_VERSION_EXACT"
assert_eq "有元数据: 版本来源" manager-metadata "$CF_VERSION_SOURCE"
assert_eq "有元数据: 自报版本仍是 binary 的" v6.0.0 "$CF_VERSION_REPORTED"
out=$("$PM" core list)
assert_contains "managed: core list" "$out" "管理状态：已接管"
assert_contains "managed: 来源" "$out" "来源：Manager 部署"
printf 'managed=false\ncore=snell\n' > "$APM_VAR/cores/snell.meta"
core_discover snell
assert_eq "managed=false: 未接管" no "$CF_MANAGED"
printf 'managed=true\ncore=singbox\n' > "$APM_VAR/cores/snell.meta"
core_discover snell
assert_eq "core 字段不匹配: 未接管" no "$CF_MANAGED"
printf 'this is not key value\n' > "$APM_VAR/cores/snell.meta"
core_discover snell
assert_eq "语法错误的元数据: 未接管" no "$CF_MANAGED"
printf 'managed=true\ncore=snell\nbinary=/opt/other/snell-server\n' > "$APM_VAR/cores/snell.meta"
core_discover snell
assert_eq "路径不一致的元数据仍然有效" yes "$CF_MANAGED"
assert_contains "路径不一致有提示" "$CF_NOTES" "不一致"
assert_eq "无 exact_release 时仍为 unknown" unknown "$CF_VERSION_EXACT"
rm -f "$A/usr/local/bin/snell-server"
core_discover snell
assert_eq "未安装时即使有元数据也不是 managed" no "$CF_MANAGED"
assert_eq "未安装时 deployment" none "$CF_DEPLOYMENT"
unset APM_VAR

# ---- 不信任的服务脚本 ----
new_sys s7
mk_snell_bin
printf '#!/bin/sh\ntouch "%s/RC_SHOULD_NOT_RUN"\n' "$T_TMP" > "$A/etc/init.d-tmp"
mkdir -p "$A/etc/init.d"
mv "$A/etc/init.d-tmp" "$A/etc/init.d/snell"
chmod +x "$A/etc/init.d/snell"
core_discover snell
assert_eq "非 openrc-run 脚本不交给 rc-service" no "$CF_SERVICE_OPENRC"
assert_fail "没有调用 rc-service" test -e "$APM_FAKE_RC_DIR/calls"
assert_fail "没有执行服务脚本" test -e "$T_TMP/RC_SHOULD_NOT_RUN"
# OpenRC 状态文件回退
new_sys s8
mk_snell_bin
mk_snell_init "$A" external
rm -f "$A/sbin/rc-service"
mkdir -p "$A/run/openrc/started"
core_discover snell
assert_eq "无 rc-service 且无 started 文件: 未运行" stopped "$CF_STATE"
assert_eq "状态文件来源" openrc-files "$CF_SERVICE_SOURCE"
ln -s /etc/init.d/snell "$A/run/openrc/started/snell"
core_discover snell
assert_eq "started 状态文件: 运行中" running "$CF_STATE"
assert_eq "started 状态文件来源" openrc-files "$CF_RUNNING_SOURCE"

# ---- 写操作一律拒绝 ----
new_sys s9
mk_snell_bin
mk_snell_init "$A" external
mk_conf /etc/snell-server.conf 0.0.0.0:43817
printf 'started' > "$APM_FAKE_RC_DIR/snell"
BEFORE=$(cd "$A" && find . -type f | sort | xargs cksum)
for v in install uninstall start stop restart update; do
    assert_rc "External: snell $v 被拒绝返回 4" 4 "$PM" snell "$v"
done
for v in reload adopt migrate; do
    assert_rc "snell $v 尚未实现返回 3" 3 "$PM" snell "$v"
done
assert_rc "snell config 只读显示" 0 "$PM" snell config
assert_rc "未知 snell 子命令返回 2" 2 "$PM" snell bogus
assert_eq "写操作被拒绝时只调用过 status" "" "$(grep -v ' status$' "$APM_FAKE_RC_DIR/calls" 2>/dev/null)"
"$PM" snell info >/dev/null
"$PM" snell status >/dev/null
"$PM" snell log >/dev/null 2>&1
"$PM" core list >/dev/null
"$PM" doctor >/dev/null 2>&1
AFTER=$(cd "$A" && find . -type f | sort | xargs cksum)
assert_eq "只读命令不改变任何文件内容" "$BEFORE" "$(printf '%s\n' "$AFTER" | grep -v 'fake-rc/calls')"
assert_fail "只读命令不创建 Manager 目录" test -e "$A/var/lib/alpine-proxy-manager"
assert_fail "没有违规调用" test -e "$APM_FAKE_RC_DIR/violations"
t_done
