# shellcheck shell=sh
# shellcheck disable=SC2015 # 测试里 A && B || C 用来记录通过或失败
# AnyTLS Gateway Core: 安装 listener 配置 证书 导出 启停 更新 卸载 在模拟系统中的完整生命周期
# 真实的最小 ELF 桩代替网关二进制 真实的 openssl 行为由模拟脚本代替 真实进程行为由 tests/e2e/gw_behavior.sh 覆盖
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet anytlsgw singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_anytlsgw.sh 全部跳过"
    t_done
    exit $?
fi

ZIPS=$T_TMP/zips
DL=$T_TMP/dl
mkdir -p "$ZIPS"
mk_dl_shim "$DL"
mk_elf_stub "$ZIPS/anytls-socks-gateway-v0.1.0-linux-x86_64" "anytls-socks-gateway v0.1.0"
mk_elf_stub "$ZIPS/gw-wrong-version" "anytls-socks-gateway v9.9.9"
GW_SHA=$(sha256sum "$ZIPS/anytls-socks-gateway-v0.1.0-linux-x86_64" | awk '{ print $1 }')
printf 'not an elf\n' > "$ZIPS/gw-not-elf"
SOCKSPW=FakeSocksPassNotSecret0001

new_g() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_sim_system "$A"
    # 模拟 openssl: 证书与私钥是带 PUB: 行的文本, 匹配关系由 PUB 行决定
    mkdir -p "$A/usr/bin"
    cat > "$A/usr/bin/openssl" <<'EOS'
#!/bin/sh
case $1 in
    req)
        out=; key=
        while [ $# -gt 0 ]; do case $1 in -keyout) key=$2; shift ;; -out) out=$2; shift ;; esac; shift; done
        id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
        printf 'CERT\nPUB:%s\n' "$id" > "$out"; printf 'KEY\nPUB:%s\n' "$id" > "$key" ;;
    x509)
        f=; mode=
        while [ $# -gt 0 ]; do case $1 in -in) f=$2; shift ;; -pubkey) mode=pub ;; -fingerprint) mode=fp ;; -subject) mode=${mode:-subj} ;; esac; shift; done
        case $mode in
            pub) grep '^PUB:' "$f" ;;
            fp) printf 'sha256 Fingerprint=%s\n' "$(grep '^PUB:' "$f" | sed 's/PUB://' | tr a-f A-F)" ;;
            *) printf 'subject=CN = anytls-gateway\nnotBefore=Oct  1 00:00:00 2026 GMT\nnotAfter=Sep 28 00:00:00 2036 GMT\n' ;;
        esac ;;
    pkey) f=; while [ $# -gt 0 ]; do case $1 in -in) f=$2; shift ;; esac; shift; done; grep '^PUB:' "$f" ;;
    *) exit 1 ;;
esac
EOS
    chmod +x "$A/usr/bin/openssl"
    K=$A/fake-rc
    mkdir -p "$K"
    echo stopped > "$K/state-anytls-socks-gateway"
    : > "$K/dl.log"
    APM_SYSROOT=$A
    APM_FAKE_RC_DIR=$K
    APM_EUID=0
    APM_ARCH=x86_64
    APM_DOWNLOADER=$DL
    APM_TEST_ZIPS=$ZIPS
    APM_TEST_DL_LOG=$K/dl.log
    APM_SNELL_WAIT=1
    APM_AGW_URL=http://example.invalid/anytls-socks-gateway-v0.1.0-linux-x86_64
    APM_AGW_SHA256=$GW_SHA
    export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER APM_TEST_ZIPS APM_TEST_DL_LOG APM_SNELL_WAIT APM_AGW_URL APM_AGW_SHA256
    unset APM_VAR APM_ETC APM_BACKUP_DIR APM_BACKUP_KEEP
}
snap() { (cd "$A" && find . \( -path ./fake-rc -o -path ./.chown.log -o -path ./.apk-installed -o -path './var/tmp/*' \) -prune -o -print | sort; cat etc/passwd etc/group; ls -A var/tmp | wc -l); }
CONF=/etc/anytls-socks-gateway/config.json
ST=/etc/alpine-proxy-manager/anytlsgw.conf
INIT=/etc/init.d/anytls-socks-gateway
gw() { "$PM" anytls-gateway "$@"; }

# ---- 未安装 ----
new_g n0
OUT=$(gw status)
assert_contains "未安装状态" "$OUT" "未安装"
BEFORE=$(snap)
OUT=$(gw start 2>&1)
assert_eq "未安装时 start 被拒绝" 4 "$?"
OUT=$(gw listener add --socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password-stdin </dev/null 2>&1)
assert_eq "未安装时 listener add 被拒绝" 4 "$?"
assert_eq "未安装时没有改动" "$BEFORE" "$(snap)"

# ---- 参数校验 ----
new_g v0
BEFORE=$(snap)
for args in "--bogus" "--socks-server 192.0.2.1" "--socks-server 192.0.2.1 --socks-port 1080 --socks-username u" \
    "--socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password x" \
    "--socks-server bad_host! --socks-port 1080 --socks-username u --socks-password-stdin" \
    "--socks-server 192.0.2.1 --socks-port 0 --socks-username u --socks-password-stdin" \
    "--socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password-stdin --port 80" \
    "--socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password-stdin --bind not-an-ip --port 30000"; do
    # shellcheck disable=SC2086
    OUT=$(printf '%s\n' "$SOCKSPW" | gw install $args 2>&1)
    assert_eq "install 拒绝: $args" 2 "$?"
done
assert_eq "参数错误没有改动任何文件" "$BEFORE" "$(snap)"
OUT=$(printf 'bad"pw\n' | gw install --socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "密码含引号被拒绝 (会破坏 JSON)" 2 "$?"
OUT=$(APM_AGW_SHA256=0000000000000000000000000000000000000000000000000000000000000000 gw install 2>&1)
assert_eq "校验和不匹配被拒绝" 1 "$?"
assert_contains "校验和说明" "$OUT" "校验和不匹配"
OUT=$(APM_AGW_URL=http://example.invalid/gw-not-elf APM_AGW_SHA256=$(sha256sum "$ZIPS/gw-not-elf" | awk '{ print $1 }') gw install 2>&1)
assert_eq "非 ELF 被拒绝" 1 "$?"
OUT=$(APM_AGW_URL=http://example.invalid/gw-wrong-version APM_AGW_SHA256=$(sha256sum "$ZIPS/gw-wrong-version" | awk '{ print $1 }') gw install 2>&1)
assert_eq "版本不符被拒绝" 1 "$?"
assert_eq "下载校验失败没有改动任何文件" "$BEFORE" "$(snap)"
OUT=$(APM_ARCH=aarch64 gw install 2>&1)
assert_eq "不支持的架构被拒绝" 4 "$?"

# ---- 只安装 不创建 listener ----
new_g i0
OUT=$(gw install 2>&1)
assert_eq "只安装成功" 0 "$?"
assert_contains "说明没有转发线路" "$OUT" "没有转发线路"
assert_eq "二进制是 ELF" elf "$(core_file_kind "$A/usr/local/bin/anytls-socks-gateway")"
assert_eq "二进制权限" 755 "$(stat -c %a "$A/usr/local/bin/anytls-socks-gateway")"
assert_eq "没有 config.json" 0 "$([ -e "$A$CONF" ] && echo 1 || echo 0)"
assert_ok "证书存在" test -f "$A/etc/anytls-socks-gateway/cert.pem"
assert_eq "私钥权限 640" 640 "$(stat -c %a "$A/etc/anytls-socks-gateway/key.pem")"
assert_eq "证书权限 644" 644 "$(stat -c %a "$A/etc/anytls-socks-gateway/cert.pem")"
assert_eq "配置目录权限 750" 750 "$(stat -c %a "$A/etc/anytls-socks-gateway")"
assert_contains "私钥属组" "$(cat "$A/.chown.log")" "root:anytlsgw /etc/anytls-socks-gateway/key.pem"
assert_contains "用户已创建" "$(cat "$A/etc/passwd")" "anytlsgw:x:"
OUT=$(gw start 2>&1)
assert_eq "没有 listener 时 start 被拒绝" 4 "$?"
INITTXT=$(cat "$A$INIT")
assert_contains "服务脚本标记" "$INITTXT" "# apm-managed: anytls-gateway"
assert_contains "服务脚本 openrc-run" "$(head -n 1 "$A$INIT")" "openrc-run"
assert_contains "服务脚本使用 supervise-daemon" "$INITTXT" 'supervisor="supervise-daemon"'
assert_contains "服务脚本非 root 用户" "$INITTXT" 'command_user="anytlsgw:anytlsgw"'
assert_contains "服务脚本内存参数 GOMEMLIMIT" "$INITTXT" "export GOMEMLIMIT=16MiB"
assert_contains "服务脚本内存参数 GOGC" "$INITTXT" "export GOGC=50"
assert_contains "服务脚本启动前校验配置" "$INITTXT" "-check"
assert_not_contains "服务脚本不含 LD_PRELOAD" "$INITTXT" "LD_PRELOAD"
assert_ok "加入默认运行级别" test -L "$A/etc/runlevels/default/anytls-socks-gateway"
M=$A/var/lib/alpine-proxy-manager/cores/anytlsgw.meta
assert_eq "元数据 managed" true "$(kv_get "$M" managed)"
assert_eq "元数据 core" anytlsgw "$(kv_get "$M" core)"
assert_eq "元数据 exact_release" v0.1.0 "$(kv_get "$M" exact_release)"
assert_eq "元数据 service_name" anytls-socks-gateway "$(kv_get "$M" service_name)"
assert_eq "元数据 created_user" yes "$(kv_get "$M" created_user)"
core_discover anytlsgw
assert_eq "发现: managed" yes "$CF_MANAGED"
assert_eq "发现: 自报版本" v0.1.0 "$CF_VERSION_REPORTED"
assert_eq "发现: 服务用户" anytlsgw:anytlsgw "$CF_SERVICE_USER"
assert_eq "发现: 状态 stopped" stopped "$CF_STATE"
assert_contains "core list 含 AnyTLS Gateway" "$("$PM" core list)" "AnyTLS Gateway"
OUT=$(gw install 2>&1)
assert_eq "重复 install 被拒绝" 4 "$?"

# ---- 带 listener 安装 并启动 ----
new_g i1
OUT=$(printf '%s\n' "$SOCKSPW" | gw install --port 30001 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin 2>&1)
assert_eq "带 listener 安装成功" 0 "$?"
assert_contains "安装完成" "$OUT" "AnyTLS Gateway 安装完成并已验证"
assert_contains "显示监听" "$OUT" "0.0.0.0:30001"
PW1=$(printf '%s\n' "$OUT" | sed -n 's/^  AnyTLS 密码：\([A-Za-z0-9]*\) .*/\1/p')
assert_eq "AnyTLS 密码 24 位" 24 "${#PW1}"
assert_eq "密码在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$PW1")"
assert_not_contains "输出不含 SOCKS5 密码" "$OUT" "$SOCKSPW"
J=$(cat "$A$CONF")
assert_contains "JSON 含 listener 端口" "$J" '"listen": "0.0.0.0:30001"'
assert_contains "JSON 含上游" "$J" '"server": "192.0.2.10:1080"'
assert_contains "JSON 含证书路径" "$J" '"cert_file": "/etc/anytls-socks-gateway/cert.pem"'
assert_eq "config.json 权限 640" 640 "$(stat -c %a "$A$CONF")"
assert_eq "事实来源权限 600" 600 "$(stat -c %a "$A$ST")"
assert_eq "除配置与事实来源外没有文件含 SOCKS5 密码" "$(printf '%s\n%s\n' "$A$CONF" "$A$ST" | sort | tr '\n' ' ' | sed 's/ $//')" "$(grep -rl "$SOCKSPW" "$A" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
core_discover anytlsgw
assert_eq "运行中" running "$CF_STATE"
assert_contains "发现: 监听" "$CF_LISTEN" ":30001"
OUT=$(gw status)
assert_contains "status 显示运行" "$OUT" "运行中"
OUT=$(gw info)
assert_contains "info 显示转发线路" "$OUT" "30001 → 192.0.2.10:1080"
assert_not_contains "info 不含密码" "$OUT" "$PW1"
assert_not_contains "info 不含 SOCKS5 密码" "$OUT" "$SOCKSPW"
OUT=$(gw export info)
assert_not_contains "export info 不含密码" "$OUT" "$PW1"
OUT=$(gw export secret 30001)
assert_contains "export secret 显示密码" "$OUT" "$PW1"
assert_not_contains "export secret 不含 SOCKS5 密码" "$OUT" "$SOCKSPW"
OUT=$(gw export secret 99 2>&1)
assert_eq "export secret 不存在的 listener" 2 "$?"

# ---- listener 管理 ----
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --port 30002 --socks-server 2001:db8::1 --socks-port 1081 --socks-username u2 --socks-password-stdin 2>&1)
assert_eq "add 第二个 listener" 0 "$?"
assert_contains "重启并验证" "$OUT" "已重启并验证"
assert_contains "JSON 含 IPv6 上游" "$(cat "$A$CONF")" '"server": "[2001:db8::1]:1081"'
assert_eq "JSON 里两个 listener" 2 "$(grep -c '"listen"' "$A$CONF")"
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --port 30002 --socks-server 192.0.2.11 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "重复端口被拒绝" 2 "$?"
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --port 30003 --socks-server 192.0.2.11 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "add 第三个 listener (域名之外的 IPv4)" 0 "$?"
OUT=$(printf 'NewSocksPassNotSecret0002\n' | gw listener set 30001 --socks-server 203.0.113.5 --socks-port 2080 --socks-username newuser --socks-password-stdin 2>&1)
assert_eq "set 上游" 0 "$?"
assert_contains "上游已更新" "$(cat "$A$CONF")" '"server": "203.0.113.5:2080"'
assert_contains "密码已更新" "$(cat "$A$CONF")" '"password": "NewSocksPassNotSecret0002"'
assert_contains "listener 2 不受影响" "$(cat "$A$CONF")" '"server": "[2001:db8::1]:1081"'
OUT=$(gw listener set 30001 --new-password 2>&1)
assert_eq "重新生成 AnyTLS 密码" 0 "$?"
PW1B=$(printf '%s\n' "$OUT" | sed -n 's/^  新的 AnyTLS 密码：\([A-Za-z0-9]*\) .*/\1/p')
assert_eq "新密码 24 位" 24 "${#PW1B}"
assert_contains "JSON 含新密码" "$(cat "$A$CONF")" "$PW1B"
assert_not_contains "JSON 不再含旧密码" "$(cat "$A$CONF")" "$PW1"
OUT=$(gw listener delete 30003 2>&1)
assert_eq "delete listener" 0 "$?"
assert_eq "删除后 JSON 里两个 listener" 2 "$(grep -c '"listen"' "$A$CONF")"
OUT=$(gw listener delete 31000 2>&1)
assert_eq "删除不存在的 listener 被拒绝" 2 "$?"
OUT=$(gw listener list)
assert_contains "list 显示上游" "$OUT" "→ 203.0.113.5:2080"
assert_not_contains "list 不含密码" "$OUT" "NewSocksPassNotSecret0002"
# 端口被其他程序占用
printf '   9: 00000000:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 99999 1 0\n' 31111 >> "$A/proc/net/tcp"
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --port 31111 --socks-server 192.0.2.11 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "端口被占用被拒绝" 4 "$?"
grep -v ":7957 " "$A/proc/net/tcp" > "$A/proc/net/tcp.n"; mv -f "$A/proc/net/tcp.n" "$A/proc/net/tcp"

# 启动失败时回滚到旧配置
BEFORE=$(cat "$A$CONF")
BEFORES=$(cat "$A$ST")
touch "$K/fail_restart-anytls-socks-gateway"
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --port 30009 --socks-server 192.0.2.11 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "重启失败时 add 返回 1" 1 "$?"
assert_contains "说明正在恢复" "$OUT" "正在恢复"
assert_eq "config.json 恢复为修改前" "$BEFORE" "$(cat "$A$CONF")"
assert_eq "事实来源恢复为修改前" "$BEFORES" "$(cat "$A$ST")"
rm -f "$K/fail_restart-anytls-socks-gateway"

# ---- 启停 ----
OUT=$(gw stop 2>&1)
assert_eq "stop" 0 "$?"
core_discover anytlsgw
assert_eq "已停止" stopped "$CF_STATE"
assert_eq "停止后没有监听" "" "$CF_LISTEN"
OUT=$(gw start 2>&1)
assert_eq "start" 0 "$?"
OUT=$(gw restart 2>&1)
assert_eq "restart" 0 "$?"
OUT=$(gw stop 2>&1); OUT=$(gw stop 2>&1)
assert_contains "重复 stop 是空操作" "$OUT" "已经停止"

# ---- 证书 ----
OUT=$(gw cert show)
assert_contains "cert show 指纹" "$OUT" "SHA256 指纹"
FP1=$(printf '%s\n' "$OUT" | sed -n 's/.*SHA256 指纹：//p')
OUT=$(gw cert generate 2>&1)
assert_eq "cert generate" 0 "$?"
FP2=$(gw cert show | sed -n 's/.*SHA256 指纹：//p')
[ "$FP1" != "$FP2" ] && t_pass "重新生成后指纹变化" || t_fail "重新生成后指纹没有变化"
printf 'CERT\nPUB:aabbccdd\n' > "$T_TMP/my.crt"; printf 'KEY\nPUB:aabbccdd\n' > "$T_TMP/my.key"
OUT=$(gw cert import --cert-file "$T_TMP/my.crt" --key-file "$T_TMP/my.key" 2>&1)
assert_eq "cert import" 0 "$?"
assert_contains "导入后指纹" "$(gw cert show)" "AABBCCDD"
assert_eq "导入后私钥权限 640" 640 "$(stat -c %a "$A/etc/anytls-socks-gateway/key.pem")"
printf 'KEY\nPUB:11223344\n' > "$T_TMP/other.key"
BEFOREC=$(cat "$A/etc/anytls-socks-gateway/cert.pem")
OUT=$(gw cert import --cert-file "$T_TMP/my.crt" --key-file "$T_TMP/other.key" 2>&1)
assert_eq "证书与私钥不匹配被拒绝" 1 "$?"
assert_eq "不匹配时证书未改动" "$BEFOREC" "$(cat "$A/etc/anytls-socks-gateway/cert.pem")"

# ---- 更新 ----
OUT=$(gw update 2>&1)
assert_eq "update 已是固定版本" 0 "$?"
assert_contains "说明无需更新" "$OUT" "无需更新"
OUT=$(gw update --force 2>&1)
assert_eq "update --force" 0 "$?"
assert_contains "更新到固定版本" "$OUT" "已更新到 v0.1.0"
assert_eq "更新后没有 .old 残留" 0 "$([ -e "$A/usr/local/bin/anytls-socks-gateway.old" ] && echo 1 || echo 0)"

# ---- 与现有 Core 互不影响 ----
assert_contains "Snell 仍是未安装" "$("$PM" snell status)" "未安装"
assert_contains "doctor 含三个 Core" "$("$PM" doctor)" "AnyTLS Gateway"

# ---- 卸载 ----
OUT=$(gw uninstall 2>&1)
assert_eq "uninstall" 0 "$?"
assert_eq "二进制已删除" 0 "$([ -e "$A/usr/local/bin/anytls-socks-gateway" ] && echo 1 || echo 0)"
assert_eq "服务脚本已删除" 0 "$([ -e "$A$INIT" ] && echo 1 || echo 0)"
assert_ok "保留配置" test -f "$A$CONF"
assert_ok "保留事实来源" test -f "$A$ST"
OUT=$(gw uninstall --purge 2>&1)
assert_eq "卸载后 uninstall --purge 无对象可处理" 4 "$?"
OUT=$(gw install 2>&1)
assert_eq "保留配置后重新安装成功" 0 "$?"
assert_contains "沿用保留的 listener" "$OUT" "沿用已保留的转发线路记录"
assert_contains "沿用保留的证书" "$OUT" "沿用已保留的证书"
core_discover anytlsgw
assert_eq "重新安装后保留的 listener 在运行" running "$CF_STATE"
assert_contains "listener 仍在" "$(gw listener list)" "30001"

new_g u1
printf '%s\n' "$SOCKSPW" | gw install --port 30001 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
OUT=$(gw uninstall --purge 2>&1)
assert_eq "purge 成功" 0 "$?"
assert_eq "purge 删除配置目录" 0 "$([ -e "$A/etc/anytls-socks-gateway" ] && echo 1 || echo 0)"
assert_eq "purge 删除事实来源" 0 "$([ -e "$A$ST" ] && echo 1 || echo 0)"
assert_eq "purge 删除日志目录" 0 "$([ -e "$A/var/log/anytls-socks-gateway" ] && echo 1 || echo 0)"
assert_eq "purge 删除元数据" 0 "$([ -e "$A/var/lib/alpine-proxy-manager/cores/anytlsgw.meta" ] && echo 1 || echo 0)"
assert_eq "purge 删除创建的用户" 0 "$(grep -c '^anytlsgw:' "$A/etc/passwd")"
new_g u3
printf '%s\n' "$SOCKSPW" | gw install --port 30001 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
gw uninstall >/dev/null 2>&1
gw install >/dev/null 2>&1
gw uninstall --purge >/dev/null 2>&1
assert_eq "卸载 重装 再 purge 仍删除 Manager 创建的用户" 0 "$(grep -c '^anytlsgw:' "$A/etc/passwd")"
assert_eq "卸载 重装 再 purge 删除用户组" 0 "$(grep -c '^anytlsgw:' "$A/etc/group")"
assert_eq "purge 不留任何含 SOCKS5 密码的文件" "" "$(grep -rl "$SOCKSPW" "$A" 2>/dev/null)"

# ---- TUI: 转发线路管理 与 SOCKS5 链接 ----
export APM_TUI_ANSI=0
TG() { printf '%b' "$1" | ( tui_anytlsgw_menu ) 2>&1; }
TR() { printf '%b' "$1" | ( tui_agw_listener_menu ) 2>&1; }
new_g tui1
gw install >/dev/null 2>&1
out=$(TG '0\n')
assert_contains "网关主菜单标题" "$out" "AnyTLS Gateway"
for item in "1. 查看详细信息" "2. 启动" "3. 转发线路管理" "4. 证书管理" "5. 查看日志" "6. 更新" "7. 卸载" "0. 返回"; do
    assert_contains "网关主菜单项 $item" "$out" "$item"
done
assert_not_contains "网关主菜单不再出现 Listener" "$out" "Listener"
out=$(TG '3\n0\n0\n')
assert_contains "转发线路子菜单标题" "$out" "AnyTLS Gateway · 转发线路管理"
assert_contains "没有线路时显示" "$out" "当前线路：无"
for item in "1. 添加转发线路" "2. 删除转发线路" "3. 修改 SOCKS5 出口" "4. 重新生成 AnyTLS 密码" "5. 查看 AnyTLS 密码" "0. 返回"; do
    assert_contains "子菜单项 $item" "$out" "$item"
done
assert_not_contains "子菜单不再出现 listener" "$out" "listener"
assert_not_contains "子菜单不再出现 修改上游" "$out" "修改上游"
out=$(TG '4\n0\n0\n')
assert_contains "证书管理页标题" "$out" "AnyTLS Gateway · 证书管理"
# 完整链接添加
FPW='Fict%Gw:Pass01'
out=$(TR '1\n30101\nsocks5://tw-user:Fict%25Gw%3APass01@proxy.example.com:1080\n\n0\n')
assert_contains "完整链接直接添加转发线路" "$out" "已添加转发线路"
assert_contains "给出识别摘要" "$out" "已识别：主机 proxy.example.com，端口 1080"
assert_not_contains "完整链接不再询问出口端口" "$out" "SOCKS5 出口端口"
assert_not_contains "完整链接不再询问用户名" "$out" "SOCKS5 用户名"
assert_not_contains "输出不含 SOCKS5 密码" "$out" "$FPW"
assert_not_contains "输出不含编码密码" "$out" "Gw%3A"
assert_eq "状态记录 socks_server" "proxy.example.com:1080" "$(kv_get "$A$ST" listener.1.socks_server)"
assert_eq "状态记录 用户名" tw-user "$(kv_get "$A$ST" listener.1.socks_username)"
assert_eq "状态记录 密码已解码" "$FPW" "$(kv_get "$A$ST" listener.1.socks_password)"
assert_eq "状态记录 监听" "0.0.0.0:30101" "$(kv_get "$A$ST" listener.1.listen)"
assert_ok "config.json 通过校验后落盘" test -s "$A$CONF"
assert_contains "config.json 含出口" "$(cat "$A$CONF")" "proxy.example.com:1080"
assert_eq "状态文件权限 600" 600 "$(stat -c %a "$A$ST")"
assert_eq "config.json 权限不宽于 640" yes "$(case $(stat -c %a "$A$CONF") in 600|640) echo yes ;; esac)"
out=$(TR '0\n')
assert_contains "线路列表显示端口与出口" "$out" "1  30101 → proxy.example.com:1080"
assert_not_contains "线路列表不含用户名" "$out" "tw-user"
assert_not_contains "线路列表不含密码" "$out" "$FPW"
assert_contains "线路列表显示条数" "$out" "当前线路：1 条"
# 分项输入与链接得到相同配置
out=$(TR '1\n30102\nproxy.example.com\n1080\ntw-user\n'"$FPW"'\n\n0\n')
assert_contains "分项输入仍询问出口端口" "$out" "SOCKS5 出口端口"
assert_contains "分项输入仍询问用户名" "$out" "SOCKS5 用户名"
assert_contains "分项输入添加成功" "$out" "已添加转发线路"
for k in socks_server socks_username socks_password; do
    assert_eq "链接与分项输入一致: $k" "$(kv_get "$A$ST" listener.1.$k)" "$(kv_get "$A$ST" listener.2.$k)"
done
assert_contains "分项输入照常打印" "$(cat "$A$CONF")" "30102"
# 不完整链接
out=$(TR '1\n30103\nsocks5://tw2-user:FictGwPw2@192.0.2.31\n1081\n\n0\n')
assert_contains "缺端口的链接补问出口端口" "$out" "SOCKS5 出口端口"
assert_not_contains "缺端口的链接不再问用户名" "$out" "SOCKS5 用户名"
assert_eq "补全后端口" "192.0.2.31:1081" "$(kv_get "$A$ST" listener.3.socks_server)"
assert_eq "补全后保留链接里的密码" FictGwPw2 "$(kv_get "$A$ST" listener.3.socks_password)"
out=$(TR '1\n30104\nsocks5://jp-user@192.0.2.32:1082\nFictGwPw3\n\n0\n')
assert_contains "只有用户名的链接补问密码" "$out" "SOCKS5 密码"
assert_not_contains "只有用户名的链接不再问用户名" "$out" "SOCKS5 用户名"
assert_eq "补问后密码" FictGwPw3 "$(kv_get "$A$ST" listener.4.socks_password)"
out=$(TR '1\n30105\nsocks5://[2001:db8::9]:1083\nsg-user\nFictGwPw4\n\n0\n')
assert_contains "无认证链接对网关补问凭据" "$out" "SOCKS5 用户名"
assert_eq "IPv6 出口规范化" "[2001:db8::9]:1083" "$(kv_get "$A$ST" listener.5.socks_server)"
assert_eq "IPv6 出口用户名" sg-user "$(kv_get "$A$ST" listener.5.socks_username)"
# 非法链接: 配置不变, 允许重新输入
SUM=$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')
out=$(TR '1\n30106\nhttp://x:FictBadGw@192.0.2.33:1080\nsocks5://x:FictBadGw@192.0.2.33:70000\nsocks5://x:FictBadGw@[::1:1080\nsocks5://x:Fict%zz@192.0.2.33:1080\n\n0\n')
assert_contains "非法协议提示" "$out" "错误：不支持的协议"
assert_contains "非法端口提示" "$out" "错误：端口无效"
assert_contains "畸形 IPv6 提示" "$out" "错误：IPv6 地址格式无效"
assert_contains "非法编码提示" "$out" "错误：密码的百分号编码无效"
assert_not_contains "错误不回显链接" "$out" "FictBadGw"
assert_eq "非法链接后状态与配置不变" "$SUM" "$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')"
out=$(TR '1\n\n\n0\n')
assert_eq "留空取消后配置不变" "$SUM" "$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')"
# 修改 SOCKS5 出口
out=$(TR '3\n1\nsocks5://new-user:FictGwNew%21@new.example.com:2080\n\n0\n')
assert_contains "修改出口成功" "$out" "已更新转发线路"
assert_eq "修改后出口" "new.example.com:2080" "$(kv_get "$A$ST" listener.1.socks_server)"
assert_eq "修改后用户名" new-user "$(kv_get "$A$ST" listener.1.socks_username)"
assert_eq "修改后密码已解码" 'FictGwNew!' "$(kv_get "$A$ST" listener.1.socks_password)"
assert_not_contains "修改页不回显密码" "$out" "FictGwNew"
assert_eq "修改后监听端口不变" "0.0.0.0:30101" "$(kv_get "$A$ST" listener.1.listen)"
out=$(TR '3\n2\n\n3000\n\n\n\n0\n')
assert_eq "只改端口时主机保持" "proxy.example.com:3000" "$(kv_get "$A$ST" listener.2.socks_server)"
assert_eq "留空保持用户名" tw-user "$(kv_get "$A$ST" listener.2.socks_username)"
assert_eq "留空保持密码" "$FPW" "$(kv_get "$A$ST" listener.2.socks_password)"
out=$(TR '3\n3\nsocks5://x:FictBadGw@192.0.2.33:70000\n\n\n\n\n0\n')
assert_contains "修改页非法链接提示" "$out" "错误：端口无效"
assert_eq "修改页非法链接后出口不变" "192.0.2.31:1081" "$(kv_get "$A$ST" listener.3.socks_server)"
# AnyTLS 密码管理与删除
OLDPW=$(kv_get "$A$ST" listener.4.password)
out=$(TR '4\n4\ny\n\n0\n')
assert_contains "重新生成 AnyTLS 密码" "$out" "已更新转发线路"
NEWPW=$(kv_get "$A$ST" listener.4.password)
assert_eq "AnyTLS 密码确实改变" no "$([ "$OLDPW" = "$NEWPW" ] && echo yes || echo no)"
BEFORE_SUM=$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')
out=$(TR '5\n\n0\n')
assert_contains "查看 AnyTLS 密码页标题" "$out" "AnyTLS Gateway · 查看 AnyTLS 密码"
assert_contains "直接显示线路条数" "$out" "当前线路：5 条"
for n in 1 2 3 4 5; do
    assert_contains "显示线路 $n 的端口" "$out" "$n. $(kv_get "$A$ST" listener.$n.listen | sed 's/.*://')"
    assert_contains "显示线路 $n 的 AnyTLS 密码" "$out" "AnyTLS 密码：$(kv_get "$A$ST" listener.$n.password)"
done
assert_not_contains "不再询问线路 ID 或端口" "$out" "ID 或端口"
assert_not_contains "不再二次确认" "$out" "继续？"
assert_not_contains "不显示 SOCKS5 密码" "$out" "$FPW"
assert_not_contains "不显示 SOCKS5 用户名" "$out" "tw-user"
assert_eq "查看密码严格只读" "$BEFORE_SUM" "$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')"
out=$(TR '0\n')
assert_not_contains "普通线路列表不含 AnyTLS 密码" "$out" "$NEWPW"
out=$(TG '3\n0\n0\n')
assert_not_contains "子菜单不含 AnyTLS 密码" "$out" "$NEWPW"
out=$(TR '2\n5\ny\n\n0\n')
assert_contains "删除转发线路" "$out" "已删除转发线路"
assert_eq "线路已删除" "" "$(kv_get "$A$ST" listener.5.listen)"
out=$(TR '2\n4\nn\n\n0\n')
assert_eq "删除取消后线路仍在" "0.0.0.0:30104" "$(kv_get "$A$ST" listener.4.listen)"
out=$(TR '0\n')
assert_contains "多条线路列表" "$out" "当前线路：4 条"
# 凭据不泄漏: 备份与其他文件
for pw in FictGwPw2 FictGwPw3 FictGwNew; do
    leak=$(grep -rl "$pw" "$A" 2>/dev/null | grep -v "$ST\|$CONF" | grep -v '/anytlsgw\.conf\.bak\.' )
    assert_eq "$pw 只出现在受控文件" "" "$leak"
done
for f in "$A"/etc/alpine-proxy-manager/anytlsgw.conf.bak.*; do
    [ -e "$f" ] || continue
    assert_eq "事务备份权限 600: ${f##*/}" 600 "$(stat -c %a "$f")"
done
# 直接回车就是确认 (所有交互式确认统一默认 Yes)
out=$(TR '2\n4\n\n\n0\n')
assert_contains "回车确认删除转发线路" "$out" "已删除转发线路"
assert_eq "回车确认后线路已删除" "" "$(kv_get "$A$ST" listener.4.listen)"
out=$(TR '2\n3\nx\nn\n\n0\n')
assert_contains "无效输入后重新询问" "$out" "输入无效，请输入 y 或 n"
assert_eq "无效输入后 n 保留线路" "0.0.0.0:30103" "$(kv_get "$A$ST" listener.3.listen)"
BEFORE_SUM=$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')
out=$(printf '2\n3\n' | ( tui_agw_listener_menu ) 2>&1)
assert_eq "确认处遇到 EOF 不删除" "$BEFORE_SUM" "$(sha256sum "$A$ST" "$A$CONF" | awk '{ print $1 }')"
# 安装时同时创建第一条线路 (链接)
new_g tui2
out=$(TG '1\ny\nsocks5://ins-user:FictInsPw@192.0.2.40:1090\n\n0\n')
assert_contains "安装流程接受完整链接" "$out" "已识别：主机 192.0.2.40，端口 1090"
assert_eq "安装流程写入出口" "192.0.2.40:1090" "$(kv_get "$A$ST" listener.1.socks_server)"
assert_eq "安装流程写入密码" FictInsPw "$(kv_get "$A$ST" listener.1.socks_password)"
assert_not_contains "安装流程输出不含密码" "$out" "FictInsPw"
out=$(TR '5\n\n0\n')
assert_contains "单条线路直接显示" "$out" "当前线路：1 条"
assert_contains "单条线路密码" "$out" "AnyTLS 密码：$(kv_get "$A$ST" listener.1.password)"
assert_not_contains "单条线路也不询问 ID" "$out" "ID 或端口"
new_g tui3
out=$(TG '1\ny\n\n\n0\n')
assert_ok "安装流程留空只安装" test -x "$A/usr/local/bin/anytls-socks-gateway"
assert_eq "留空只安装没有线路" "" "$(kv_get "$A$ST" listener.1.listen)"
out=$(TR '5\n\n0\n')
assert_contains "没有线路时的提示" "$out" "当前没有转发线路"

# ---- 现有部署 (External) 不接管 ----
new_g x1
mkdir -p "$A/etc/anytls-socks-gateway"
mk_elf_stub "$A/usr/local/bin/anytls-socks-gateway" "anytls-socks-gateway v0.0.9"
printf '{"listeners":[{"listen":"0.0.0.0:52147"}]}\n' > "$A$CONF"
core_discover anytlsgw
assert_eq "现有部署: 未被接管" no "$CF_MANAGED"
assert_eq "现有部署: external" external "$CF_DEPLOYMENT"
BEFORE=$(snap)
for op in "start" "stop" "restart" "update" "uninstall" "listener delete 1" "cert generate"; do
    # shellcheck disable=SC2086
    OUT=$(gw $op 2>&1)
    assert_eq "现有部署拒绝: $op" 4 "$?"
done
OUT=$(gw install 2>&1)
assert_eq "现有部署拒绝 install" 4 "$?"
OUT=$(printf '%s\n' "$SOCKSPW" | gw listener add --socks-server 192.0.2.1 --socks-port 1080 --socks-username u --socks-password-stdin 2>&1)
assert_eq "现有部署拒绝 listener add" 4 "$?"
assert_eq "现有部署没有任何改动" "$BEFORE" "$(snap)"
assert_contains "info 只读显示" "$(gw info)" "管理状态：未接管"

t_done
