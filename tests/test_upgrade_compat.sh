# shellcheck shell=sh
# 历史版本升级兼容: tests/fixtures/legacy/devN 是由 0.1.0-dev.N 自己的命令生成的真实数据 (实例 SOCKS Profile 元数据 Snell 配置 以及该版本自己生成的 sing-box 运行配置)
# 凭据已替换为虚构值, 证书与私钥不在其中
# 验证当前版本读取旧数据: 不改写 不误解释 不 fail-open, 缺少新字段时使用安全默认, 候选运行配置与该版本自己的输出一致
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_upgrade_compat.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

FX=$T_ROOT/tests/fixtures/legacy
INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
sum_all() { ( cd "$A" && cat etc/alpine-proxy-manager/instances/*.conf etc/alpine-proxy-manager/socks/*.conf etc/sing-box/config.json etc/snell/snell-server.conf var/lib/alpine-proxy-manager/cores/*.meta 2>/dev/null | cksum ); }
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

# 把某个历史版本的数据放进一个已由当前版本安装好 Core 的模拟系统
restore_legacy() { # 版本目录名
    local _v _f
    _v=$FX/$1
    new_s "u$1"
    printf 'CurrentSnellPsk0123456789abcdef\n' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
    "$PM" sing-box install >/dev/null 2>&1
    rm -rf "$A/etc/alpine-proxy-manager"
    cp -R "$_v/apm-etc" "$A/etc/alpine-proxy-manager"
    chmod 700 "$A/etc/alpine-proxy-manager" "$A/etc/alpine-proxy-manager/instances" "$A/etc/alpine-proxy-manager/socks" 2>/dev/null
    for _f in "$A"/etc/alpine-proxy-manager/instances/*.conf "$A"/etc/alpine-proxy-manager/socks/*.conf; do [ -f "$_f" ] && chmod 600 "$_f"; done
    cp "$_v/meta/snell.meta" "$_v/meta/singbox.meta" "$A/var/lib/alpine-proxy-manager/cores/"
    chmod 600 "$A"/var/lib/alpine-proxy-manager/cores/*.meta
    cp "$_v/snell/snell-server.conf" "$A/etc/snell/snell-server.conf"
    cp "$_v/sing-box/config.json" "$A/etc/sing-box/config.json"
    mkdir -p "$A/etc/sing-box/tls"
    for _f in "$A"/etc/alpine-proxy-manager/instances/*.conf; do
        [ "$(kv_get "$_f" tls.mode)" = self-signed ] || continue
        printf 'fake certificate placeholder\n' > "$A/etc/sing-box/tls/$(kv_get "$_f" id).crt"
        printf 'fake key placeholder\n' > "$A/etc/sing-box/tls/$(kv_get "$_f" id).key"
    done
}

for V in dev2 dev3 dev4 dev5 dev6 dev7 dev8; do
    N=${V#dev}
    restore_legacy "$V"
    BASE=$(sum_all)
    # 发现与归属
    core_discover snell
    assert_eq "$V: Snell 仍是 Manager 部署" managed "$CF_DEPLOYMENT"
    assert_eq "$V: Snell exact_release 保留" v6.0.0rc2 "$CF_VERSION_EXACT"
    core_discover singbox
    assert_eq "$V: sing-box 仍是 Manager 部署" managed "$CF_DEPLOYMENT"
    assert_eq "$V: sing-box 元数据有效" valid "$CF_META_STATE"
    # 当前版本对旧实例生成的运行配置与该版本自己生成的逐字节一致
    sb_generate_config "$A/etc/alpine-proxy-manager/instances" > "$T_TMP/gen.json"
    if cmp -s "$T_TMP/gen.json" "$FX/$V/sing-box/config.json"; then t_pass "$V: 运行配置与该版本自己生成的逐字节一致"; else t_fail "$V: 运行配置与该版本自己生成的不一致" "$(diff "$FX/$V/sing-box/config.json" "$T_TMP/gen.json" | head -10)"; fi
    # 全部实例有效
    for f in "$A"/etc/alpine-proxy-manager/instances/*.conf; do
        assert_ok "$V: $(kv_get "$f" id) 通过当前校验" sb_instance_validate "$f"
    done
    # 只读命令不改变任何东西
    "$PM" sing-box list >/dev/null 2>&1
    "$PM" sing-box check >/dev/null 2>&1
    assert_eq "$V: sing-box check 通过" 0 "$("$PM" sing-box check >/dev/null 2>&1; echo $?)"
    for f in "$A"/etc/alpine-proxy-manager/instances/*.conf; do
        id=$(kv_get "$f" id)
        "$PM" sing-box show "$id" >/dev/null 2>&1
        assert_eq "$V: show $id" 0 $?
        "$PM" sing-box access "$id" show >/dev/null 2>&1
        "$PM" sing-box egress "$id" show >/dev/null 2>&1
        "$PM" sing-box endpoint "$id" show >/dev/null 2>&1
        "$PM" sing-box export "$id" secret >/dev/null 2>&1
        assert_eq "$V: export secret $id" 0 $?
    done
    "$PM" snell info >/dev/null 2>&1
    "$PM" snell export secret >/dev/null 2>&1
    assert_eq "$V: snell export secret" 0 $?
    "$PM" socks list >/dev/null 2>&1
    "$PM" status >/dev/null 2>&1
    "$PM" doctor >/dev/null 2>&1
    T '2\n1\n1\n3\n0\n4\n0\n5\n0\n0\n0\n0\n6\n1\n\n0\n0\n' >/dev/null
    assert_eq "$V: 只读命令与 TUI 浏览没有改动任何数据" "$BASE" "$(sum_all)"
    # 缺少新字段时使用安全默认
    out=$("$PM" sing-box access AnyTLS-01 show 2>&1)
    if [ "$N" -ge 5 ]; then
        assert_contains "$V: 保留已有的目标访问限制" "$out" "Allowlist"
    else
        assert_contains "$V: 没有 relay_access 就是不限制" "$out" "未启用"
        assert_not_contains "$V: 旧实例没有被补上 relay_access" "$(cat "$(INST AnyTLS-01)")" relay_access
    fi
    if [ "$N" -ge 6 ]; then
        assert_contains "$V: 保留已有的 SOCKS 出口" "$("$PM" sing-box egress TUIC-01 show 2>&1)" "SOCKS-01"
    else
        assert_contains "$V: 没有 egress_socks 就是 DIRECT" "$("$PM" sing-box egress AnyTLS-01 show 2>&1)" "DIRECT"
        assert_not_contains "$V: 旧实例没有被补上 egress_socks" "$(cat "$(INST AnyTLS-01)")" egress_socks
    fi
    out=$("$PM" sing-box export AnyTLS-01 show 2>&1)
    if [ "$N" -ge 7 ]; then
        assert_contains "$V: 保留已有的客户端连接地址" "$out" "服务器：example.com"
        assert_contains "$V: Snell 保留客户端连接地址" "$("$PM" snell export show 2>&1)" "服务器：example.com"
    else
        assert_contains "$V: 没有 Public Endpoint 时导出拒绝" "$out" "尚未配置客户端连接地址"
        assert_eq "$V: 拒绝时没有任何 JSON 输出" "" "$("$PM" sing-box export AnyTLS-01 sing-box 2>/dev/null)"
        assert_fail "$V: Snell 没有 endpoint 时导出拒绝" "$PM" snell export show
    fi
    # 空的允许目标列表仍然拒绝全部 (fail-closed 不因升级改变)
    if [ "$N" -ge 5 ]; then
        assert_contains "$V: 旧的 allowlist 在运行配置里仍有 reject" "$(cat "$A/etc/sing-box/config.json")" '"action": "reject"'
    fi
    # 写操作: 往返后其他实例的文件逐字节不变, 被改实例也恢复原样
    ORIG_ANY=$(cat "$(INST AnyTLS-01)")
    OTHERS=$(cat "$(INST Hysteria2-01)" 2>/dev/null; cat "$(INST TUIC-01)" 2>/dev/null; cat "$(INST Shadowsocks-01)" 2>/dev/null)
    if [ "$N" -lt 7 ]; then
        "$PM" sing-box endpoint AnyTLS-01 set example.com 32001 >/dev/null 2>&1
        assert_eq "$V: 在旧实例上设置 endpoint" example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
        "$PM" sing-box endpoint AnyTLS-01 clear >/dev/null 2>&1
        assert_eq "$V: clear 之后旧实例文件逐字节恢复" "$ORIG_ANY" "$(cat "$(INST AnyTLS-01)")"
    fi
    "$PM" sing-box disable Hysteria2-01 >/dev/null 2>&1
    "$PM" sing-box enable Hysteria2-01 >/dev/null 2>&1
    sb_generate_config "$A/etc/alpine-proxy-manager/instances" > "$T_TMP/gen2.json"
    assert_eq "$V: 禁用再启用之后运行配置恢复为该版本自己的输出" "$(cksum < "$FX/$V/sing-box/config.json")" "$(cksum < "$A/etc/sing-box/config.json")"
    assert_eq "$V: 写操作没有改动其他实例" "$OTHERS" "$(cat "$(INST Hysteria2-01)" 2>/dev/null; cat "$(INST TUIC-01)" 2>/dev/null; cat "$(INST Shadowsocks-01)" 2>/dev/null)"
    assert_eq "$V: 写操作没有改动 AnyTLS-01" "$ORIG_ANY" "$(cat "$(INST AnyTLS-01)")"
    # 旧版本写下的凭据原样可用 (没有被重新生成)
    assert_eq "$V: 凭据没有被重新生成" "$(kv_get "$FX/$V/apm-etc/instances/AnyTLS-01.conf" credential.password)" "$(kv_get "$(INST AnyTLS-01)" credential.password)"
    assert_eq "$V: 权限仍是 0600" 600 "$(stat -c %a "$(INST AnyTLS-01)")"
done
t_done
