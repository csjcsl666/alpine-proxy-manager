# shellcheck shell=sh
# 0.5.0 Release Hardening 回归: 二进制属主, 写操作期间忽略中断信号, External Core 的写操作全面拒绝, 文件权限, 重复执行, 秘密不进 argv
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_release_hardening.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
ready() { new_s "$1"; printf 'HardeningSnellPsk0123456789abcd\n' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1; "$PM" sing-box install >/dev/null 2>&1; }
mode() { stat -c %a "$1" 2>/dev/null; }
datasum() { ( cd "$A" && cat etc/alpine-proxy-manager/instances/*.conf etc/alpine-proxy-manager/socks/*.conf etc/sing-box/config.json etc/snell/snell-server.conf 2>/dev/null | cksum ); }

# ---- 二进制属主: 上游压缩包里的 uid 不能被保留 ----
ready h1
assert_contains "sing-box 二进制被设为 root" "$(cat "$A/.chown.log")" "root:root /var/tmp/apm-snell."
grep -E '^root:root /var/tmp/apm-snell\.[A-Za-z0-9]+/x/sing-box-[0-9.]+-linux-[a-z0-9]+-musl/sing-box$' "$A/.chown.log" >/dev/null
assert_eq "sing-box 暂存二进制精确设为 root:root" 0 $?
grep -E '^root:root /var/tmp/apm-snell\.[A-Za-z0-9]+/x/snell-server$' "$A/.chown.log" >/dev/null
assert_eq "snell-server 暂存二进制精确设为 root:root" 0 $?
: > "$A/.chown.log"
"$PM" sing-box update v1.14.2 >/dev/null 2>&1
use_sha "$SHA_N"
APM_SB_SHA256=$SHA_N "$PM" sing-box update v1.14.2 --force >/dev/null 2>&1
grep -E '^root:root /var/tmp/apm-snell\.[A-Za-z0-9]+/x/sing-box-1\.14\.2-linux-[a-z0-9]+-musl/sing-box$' "$A/.chown.log" >/dev/null
assert_eq "sing-box update 同样设为 root:root" 0 $?

# ---- 写操作期间忽略中断, 下载阶段可中断并清理 ----
ready h2
r=$( (_me=$(sh -c 'echo $PPID'); _snell_lock; trap '_snell_cleanup' EXIT; kill -HUP "$_me"; kill -INT "$_me"; kill -TERM "$_me"; printf survived) 2>&1)
assert_eq "持锁期间 HUP INT TERM 被忽略" survived "$r"
assert_fail "正常结束后锁被释放" test -d "$A/var/lib/alpine-proxy-manager/snell.lock"
slow=$T_TMP/slowdl
printf '#!/bin/sh\nsleep 3\nexit 1\n' > "$slow"
chmod +x "$slow"
( APM_DOWNLOADER=$slow; export APM_DOWNLOADER
  _snell_lock; trap '_snell_cleanup' EXIT; _snell_ensure_staging
  printf '%s\n' "$SNELL_STAGING" > "$T_TMP/stg"
  _snell_fetch https://example.invalid/x "$SNELL_STAGING/f"; echo "fetch-returned" > "$T_TMP/fetch.ret" ) &
BG=$!
sleep 1
kill -TERM "$BG" 2>/dev/null
wait "$BG" 2>/dev/null
assert_eq "下载阶段被 TERM 中止, 没有继续执行" "" "$(cat "$T_TMP/fetch.ret" 2>/dev/null)"
assert_fail "中止后锁已清理" test -d "$A/var/lib/alpine-proxy-manager/snell.lock"
assert_fail "中止后临时目录已清理" test -d "$(cat "$T_TMP/stg")"
# 下载结束后恢复为忽略
r=$( (_me=$(sh -c 'echo $PPID'); APM_DOWNLOADER=true; export APM_DOWNLOADER; _snell_lock; trap '_snell_cleanup' EXIT; printf x > "$T_TMP/ok.bin"; _snell_fetch https://example.invalid/x "$T_TMP/ok.bin" >/dev/null 2>&1; kill -TERM "$_me"; printf survived) 2>&1)
assert_eq "下载之后信号重新被忽略" survived "$r"

# ---- 二进制属主告警 (0.5.0 之前安装的 sing-box 保留了上游 uid) ----
ready h2b
out=$("$PM" core list 2>&1)
assert_not_contains "属主是 root 时不告警" "$out" "二进制属主是 uid"
if chown 1001 "$A/usr/local/bin/sing-box" 2>/dev/null && [ "$(stat -c %u "$A/usr/local/bin/sing-box")" = 1001 ]; then
    out=$("$PM" core list 2>&1)
    assert_contains "属主不是 root 时告警" "$out" "二进制属主是 uid 1001 而不是 root"
    assert_contains "告警给出修复命令" "$out" "proxy-manager sing-box update --force"
    assert_not_contains "Snell 属主正常不告警" "$(printf '%s' "$out" | sed -n '/^Snell/,/^sing-box/p')" "二进制属主"
    assert_contains "doctor 同样告警" "$("$PM" doctor 2>&1)" "二进制属主是 uid 1001"
else
    t_skip "当前环境不能 chown 到非 root uid, 属主告警的正例跳过"
fi

# ---- 并发写操作: 第二个被拒绝, 数据不被覆盖, 释放后恢复 ----
ready h2c
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
HELD=$T_TMP/held
( _snell_lock; trap '_snell_cleanup' EXIT; : > "$HELD"; sleep 4 ) &
LB=$!
i=0; while [ ! -e "$HELD" ] && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
B4=$(datasum)
out=$("$PM" sing-box set AnyTLS-01 port 20555 2>&1)
rc=$?
assert_eq "持锁期间另一个写操作被拒绝" 4 $rc
assert_contains "说明另一个写操作在运行" "$out" "另一个 Manager 写操作正在运行"
printf 'x\n' | "$PM" sing-box socks add --server 192.0.2.9 --port 1080 --no-auth >/dev/null 2>&1
assert_eq "持锁期间 SOCKS 写操作也被拒绝" 4 $?
assert_eq "被拒绝的写操作没有改动数据" "$B4" "$(datasum)"
wait "$LB"
assert_fail "持有者退出后锁已释放" test -d "$A/var/lib/alpine-proxy-manager/snell.lock"
"$PM" sing-box set AnyTLS-01 port 20555 >/dev/null 2>&1
assert_eq "锁释放后写操作成功" 20555 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
# 持有者已经死亡的残留锁会被回收
mkdir -p "$A/var/lib/alpine-proxy-manager/snell.lock"
printf '99999999\n' > "$A/var/lib/alpine-proxy-manager/snell.lock/pid"
"$PM" sing-box set AnyTLS-01 port 20556 >/dev/null 2>&1
assert_eq "残留的死锁被回收" 20556 "$(kv_get "$(INST AnyTLS-01)" listen_port)"

# ---- External Core: 所有写操作拒绝, 且不留下任何改动 ----
ext_sweep() { # 标签
    local _l _before _snap _rc
    _l=$1
    _snap=$(snap)
    _before=$(datasum)
    for c in \
        "snell install" "snell start" "snell stop" "snell restart" "snell update" "snell uninstall" "snell uninstall --purge" \
        "snell config set listen 20999" "snell config set mode default" "snell endpoint set example.com 443" "snell endpoint clear" \
        "sing-box install" "sing-box start" "sing-box stop" "sing-box restart" "sing-box update" "sing-box uninstall" "sing-box uninstall --purge" \
        "sing-box add anytls --port 20443" "sing-box add shadowsocks --port 20444" "sing-box enable AnyTLS-01" "sing-box disable AnyTLS-01" "sing-box delete AnyTLS-01" \
        "sing-box set AnyTLS-01 port 20555" "sing-box access AnyTLS-01 allowlist" "sing-box access AnyTLS-01 add 192.0.2.1 80" \
        "sing-box socks add --server 192.0.2.9 --port 1080 --no-auth" "sing-box socks delete SOCKS-01" "sing-box socks enable-all" "sing-box socks disable-all" \
        "sing-box egress AnyTLS-01 direct" "sing-box egress AnyTLS-01 socks SOCKS-01" "sing-box endpoint AnyTLS-01 set example.com 443" "sing-box endpoint AnyTLS-01 clear"; do
        # shellcheck disable=SC2086
        "$PM" $c </dev/null >/dev/null 2>&1
        _rc=$?
        if [ "$_rc" -ne 0 ]; then t_pass "$_l: $c 被拒绝"; else t_fail "$_l: $c 应被拒绝, 实际成功"; fi
    done
    assert_eq "$_l: 全部写操作之后文件系统没有变化" "$_snap" "$(snap)"
    assert_eq "$_l: 全部写操作之后数据没有变化" "$_before" "$(datasum)"
    assert_eq "$_l: 服务脚本与调用没有被触碰" 0 "$(grep -c -E '^(snell|sing-box) (start|stop|restart)$' "$K/calls" 2>/dev/null || true)"
}
# 变体一: 曾经由 Manager 安装, 元数据丢失后视为现有部署
ready h3
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
: > "$K/calls"
rm -f "$A/var/lib/alpine-proxy-manager/cores/snell.meta" "$A/var/lib/alpine-proxy-manager/cores/singbox.meta"
ext_sweep "无元数据"
# 变体二: 元数据存在但损坏
ready h4
printf 'managed=true\ncore=wrong\n' > "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
printf 'not a key value line\n' > "$A/var/lib/alpine-proxy-manager/cores/singbox.meta"
: > "$K/calls"
ext_sweep "元数据损坏"
# 变体三: apk 形态的 sing-box 与独立的 Snell, 路径看起来像但没有 Manager 元数据
new_s h5
mk_elf_stub "$A/usr/bin/sing-box" "sing-box version 1.13.11"
mk_elf_stub "$A/usr/local/bin/snell-server" "snell-server v6.0.0 (Aug  7 2026)"
mkdir -p "$A/etc/sing-box" "$A/etc/snell"
printf '{"log":{}}\n' > "$A/etc/sing-box/config.json"
printf '[snell-server]\nlisten = 0.0.0.0:20000\npsk = ExistingPskNotManagedByApm01\n' > "$A/etc/snell/snell-server.conf"
: > "$K/calls"
ext_sweep "apk 形态"
assert_eq "apk 形态的 sing-box 配置未被改动" '{"log":{}}' "$(cat "$A/etc/sing-box/config.json")"
assert_contains "apk 形态的 Snell 配置未被改动" "$(cat "$A/etc/snell/snell-server.conf")" "ExistingPskNotManagedByApm01"
# 只读仍然可用
assert_ok "External 下 core list 可用" "$PM" core list
assert_ok "External 下 doctor 可用" "$PM" doctor
assert_ok "External 下 snell info 可用" "$PM" snell info
# TUI 也不能绕过
out=$(printf '1\n2\n0\n0\n0\n' | ( APM_TUI_ANSI=0 tui_run ) 2>&1)
assert_contains "TUI 显示未接管" "$out" "现有部署，未接管"
assert_not_contains "TUI 不提供启动" "$out" ". 启动"
assert_not_contains "TUI 不提供卸载" "$out" ". 卸载"
assert_not_contains "TUI 不提供更新" "$out" ". 更新"

# ---- 文件权限审计 ----
ready h6
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20600 >/dev/null 2>&1
printf 'PermSocksPassword0123456789\n' | "$PM" sing-box socks add --server 192.0.2.50 --port 1080 --username u --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
"$PM" snell endpoint set example.com 32100 >/dev/null 2>&1
E=$A/etc/alpine-proxy-manager
assert_eq "etc/alpine-proxy-manager 目录 0700" 700 "$(mode "$E")"
assert_eq "instances 目录 0700" 700 "$(mode "$E/instances")"
assert_eq "socks 目录 0700" 700 "$(mode "$E/socks")"
assert_eq "实例文件 0600" 600 "$(mode "$(INST AnyTLS-01)")"
assert_eq "SOCKS Profile 0600" 600 "$(mode "$(PROF SOCKS-01)")"
assert_eq "Snell endpoint 文件 0600" 600 "$(mode "$E/snell-endpoint.conf")"
V=$A/var/lib/alpine-proxy-manager
assert_eq "数据目录 0700" 700 "$(mode "$V")"
assert_eq "备份目录 0700" 700 "$(mode "$V/backups")"
assert_eq "cores 目录 0700" 700 "$(mode "$V/cores")"
assert_eq "元数据 0600" 600 "$(mode "$V/cores/singbox.meta")"
for b in "$V"/backups/*; do
    [ -f "$b" ] || continue
    assert_eq "备份 $(basename "$b" | cut -c1-24) 不可被组与其他用户读取" 0 "$(mode "$b" | grep -c '[0-7][1-7][0-7]$\|[0-7][0-7][1-7]$')"
done
assert_eq "sing-box 配置 0640" 640 "$(mode "$A/etc/sing-box/config.json")"
assert_eq "Snell 配置 0640" 640 "$(mode "$A/etc/snell/snell-server.conf")"
assert_eq "TLS 私钥 0640" 640 "$(mode "$A/etc/sing-box/tls/AnyTLS-01.key")"
assert_contains "配置与私钥的属主是 root 与服务组" "$(cat "$A/.chown.log")" "root:sing-box /etc/sing-box/tls/AnyTLS-01.key"
# 没有任何包含秘密的文件对 other 可读
bad=$(find "$A/etc/alpine-proxy-manager" "$A/var/lib/alpine-proxy-manager" "$A/etc/sing-box" "$A/etc/snell" -type f -perm -004 2>/dev/null | grep -v '\.apm-\|\.crt$' | head -3)
assert_eq "etc 与数据目录下没有 other 可读的文件" "" "$bad"

# ---- 重复执行与幂等 ----
CS=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)
RS=$(count_calls restart)
out=$("$PM" sing-box endpoint AnyTLS-01 set example.com 32001 2>&1)
assert_contains "相同 endpoint 不改动" "$out" "没有变化"
out=$("$PM" sing-box egress AnyTLS-01 socks SOCKS-01 2>&1)
assert_eq "重复绑定同一出口不重复生成规则" 1 "$(grep -c '"outbound": "apm-socks-SOCKS-01"' "$A/etc/sing-box/config.json")"
assert_eq "重复绑定同一出口只有一个 SOCKS 出站" 1 "$(grep -c '"type": "socks"' "$A/etc/sing-box/config.json")"
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
"$PM" sing-box access AnyTLS-01 add 192.0.2.77 8080 >/dev/null 2>&1
CS2=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)
RS2=$(count_calls restart)
out=$("$PM" sing-box access AnyTLS-01 add 192.0.2.77 8080 2>&1)
assert_eq "重复添加同一允许目标不改变配置" "$CS2" "$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)"
assert_eq "重复添加同一允许目标不重启" "$RS2" "$(count_calls restart)"
assert_eq "允许目标没有重复" 1 "$(grep -c '192.0.2.77:8080' "$(INST AnyTLS-01)")"
"$PM" sing-box socks set SOCKS-01 port 1080 >/dev/null 2>&1
assert_eq "相同的 Profile 值不改变实例文件" 1 "$(grep -c '^port=1080$' "$(PROF SOCKS-01)")"
"$PM" sing-box enable AnyTLS-01 >/dev/null 2>&1
assert_eq "重复启用已启用的实例不重复写入" 1 "$(grep -c '^enabled=true$' "$(INST AnyTLS-01)")"
assert_eq "OpenRC 默认运行级别没有重复登记" 1 "$(grep -c '^sing-box$' "$A/etc/runlevels/default/.list" 2>/dev/null || echo 1)"

# ---- 秘密不进 argv: 静态审计 ----
assert_eq "库代码没有把秘密作为命令行参数传给子命令" 0 "$(grep -n -E -- '(--password|--psk|--key)[ =]"?\$[A-Za-z_{]' "$T_ROOT"/lib/*.sh "$T_ROOT"/bin/proxy-manager | grep -v 'apm_err\|用法\|printf\|usage\|#' | wc -l | tr -d ' ')"
assert_eq "库代码没有 shell 跟踪" 0 "$(grep -n -E 'set -x|sh -x|set -o xtrace' "$T_ROOT"/lib/*.sh "$T_ROOT"/bin/proxy-manager | wc -l | tr -d ' ')"
assert_eq "库代码不使用 awk -v 传递凭据" 0 "$(grep -n -E 'awk .*-v [a-z]*(pw|psk|pass|secret)' "$T_ROOT"/lib/*.sh | wc -l | tr -d ' ')"
assert_eq "不修改防火墙与网络" 0 "$(grep -n -E '\b(iptables|ip6tables|nft|ufw|sysctl|ip route|ip rule)\b' "$T_ROOT"/lib/*.sh "$T_ROOT"/bin/proxy-manager "$T_ROOT"/install.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v 'printf\|apm_err\|说明\|不' | wc -l | tr -d ' ')"
t_done
