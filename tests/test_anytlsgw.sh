# shellcheck shell=sh
# shellcheck disable=SC2015 # 测试里 A && B || C 用来记录通过或失败
# AnyTLS Gateway Core: 安装 listener 配置 证书 导出 启停 更新 卸载 在模拟系统中的完整生命周期
# 真实的最小 ELF 桩代替网关二进制 真实的 openssl 行为由模拟脚本代替 真实进程行为由 tests/e2e/gw_behavior.sh 覆盖
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet anytlsgw singbox

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
assert_contains "说明没有 listener" "$OUT" "没有 listener"
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
assert_contains "info 显示 listener" "$OUT" "监听 0.0.0.0:30001"
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
assert_contains "list 显示上游" "$OUT" "上游 203.0.113.5:2080"
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
OUT=$(gw install 2>&1)
assert_eq "残留配置时拒绝重新安装" 4 "$?"
OUT=$(gw uninstall --purge 2>&1)
assert_eq "没有二进制时 uninstall 已无需处理" 4 "$?"

new_g u1
printf '%s\n' "$SOCKSPW" | gw install --port 30001 --socks-server 192.0.2.10 --socks-port 1080 --socks-username upuser --socks-password-stdin >/dev/null 2>&1
OUT=$(gw uninstall --purge 2>&1)
assert_eq "purge 成功" 0 "$?"
assert_eq "purge 删除配置目录" 0 "$([ -e "$A/etc/anytls-socks-gateway" ] && echo 1 || echo 0)"
assert_eq "purge 删除事实来源" 0 "$([ -e "$A$ST" ] && echo 1 || echo 0)"
assert_eq "purge 删除日志目录" 0 "$([ -e "$A/var/log/anytls-socks-gateway" ] && echo 1 || echo 0)"
assert_eq "purge 删除元数据" 0 "$([ -e "$A/var/lib/alpine-proxy-manager/cores/anytlsgw.meta" ] && echo 1 || echo 0)"
assert_eq "purge 删除创建的用户" 0 "$(grep -c '^anytlsgw:' "$A/etc/passwd")"
assert_eq "purge 不留任何含 SOCKS5 密码的文件" "" "$(grep -rl "$SOCKSPW" "$A" 2>/dev/null)"

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
