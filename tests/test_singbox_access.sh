# shellcheck shell=sh
# 目标访问限制 (Relay Access Policy): 按实例, 跨协议, allowlist 默认拒绝, fail-closed, 事务回滚, 旧实例兼容
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_access.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
CFG() { cat "$A/etc/sing-box/config.json"; }
PW_OF() { kv_get "$(INST "$1")" credential.password; }
UU_OF() { kv_get "$(INST "$1")" credential.uuid; }
leaks() { # 秘密 允许的位置
    grep -rl "$1" "$A" 2>/dev/null | while IFS= read -r f; do
        ok=0
        for a in $2; do
            # shellcheck disable=SC2254
            case $f in $a) ok=1 ;; esac
        done
        [ "$ok" = 1 ] || printf '%s\n' "$f"
    done
}
ready() { new_s "$1"; "$PM" sing-box install >/dev/null 2>&1; }
listen_of() { core_discover singbox; printf '%s' "$CF_LISTEN"; }
hex4() { printf '%04X' "$1"; }
foreign() {
    local _st _row
    _st=0A
    [ "$1" = udp ] && _st=07
    _row=$(printf '   9: %s:%s 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 %s 1 0' "${3:-00000000}" "$(hex4 "$2")" "$_st" "${4:-9999}")
    printf '%s\n' "$_row" >> "$K/foreign.$1"
    [ -f "$A/proc/net/$1" ] || printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "$A/proc/net/$1"
    printf '%s\n' "$_row" >> "$A/proc/net/$1"
}

# ---- 目标规范化 ----
nm() { _sb_dest_normalize "$1" "$2" 2>/dev/null; }
assert_eq "IPv4 规范化" 192.0.2.10:8080 "$(nm 192.0.2.10 8080)"
assert_eq "IPv6 带方括号" "[2001:db8::1]:443" "$(nm '[2001:db8::1]' 443)"
assert_eq "IPv6 不带方括号也接受并加上" "[2001:db8::1]:443" "$(nm 2001:db8::1 443)"
assert_eq "IPv6 大写转小写" "[2001:db8::abcd]:443" "$(nm 2001:DB8::ABCD 443)"
assert_eq "IPv6 回环" "[::1]:80" "$(nm ::1 80)"
assert_eq "IPv6 完整八组" "[1:2:3:4:5:6:7:8]:9" "$(nm 1:2:3:4:5:6:7:8 9)"
bn() { _sb_dest_normalize "$1" "$2" >/dev/null 2>&1 && echo ok || echo bad; }
for h in 256.1.1.1 1.2.3 1.2.3.4.5 010.0.0.1 10.0.0.01 example.com localhost '' abc ::: 1::2::3 12345::1 1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7 :1:2:3:4:5:6:7 1:2:3:4:5:6:7: 'fe80::1%eth0' 1.2.3.4/32 '[1.2.3.4]' gggg::1 '*'; do
    assert_eq "非法地址 [$h]" bad "$(bn "$h" 80)"
done
for p in 0 65536 99999 abc '' -1 '8 0' 080a; do
    assert_eq "非法端口 [$p]" bad "$(bn 10.0.0.1 "$p")"
done
assert_eq "端口 1 合法" ok "$(bn 10.0.0.1 1)"
assert_eq "端口 65535 合法" ok "$(bn 10.0.0.1 65535)"
assert_eq "域名给出明确原因" "目标访问限制第一版只支持 IP 地址, 不支持域名: example.com" "$(_sb_dest_normalize example.com 80)"
assert_eq "端口错误给出原因" "端口无效: 70000 (需要 1 到 65535)" "$(_sb_dest_normalize 10.0.0.1 70000)"

# ---- 生成: 模型 ----
G=$T_TMP/gen
mkdir -p "$G"
mkinst() { # 目录 ID 类型 端口 启用
    case $3 in
        shadowsocks) printf 'id=%s\nname=%s\ntype=shadowsocks\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.method=2022-blake3-aes-128-gcm\ncredential.password=AAAAAAAAAAAAAAAAAAAAAA==\ntransport.type=tcp+udp\n' "$2" "$2" "$5" "$4" > "$1/$2.conf" ;;
        tuic) printf 'id=%s\nname=%s\ntype=tuic\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.uuid=11111111-2222-4333-8444-555555555555\ncredential.password=TuicPasswordNumberOne0123456789abc\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\ntransport.type=udp\n' "$2" "$2" "$5" "$4" "$2" "$2" > "$1/$2.conf" ;;
        *) printf 'id=%s\nname=%s\ntype=%s\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.password=PasswordNumberOne0123456789abcd\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\n' "$2" "$2" "$3" "$5" "$4" "$2" "$2" > "$1/$2.conf" ;;
    esac
}
pol() { # 目录 ID 行...   追加 relay_access 键
    _d=$1; _i=$2; shift 2
    for _l in "$@"; do printf '%s\n' "$_l" >> "$_d/$_i.conf"; done
}
ALLOW='relay_access.enabled=true
relay_access.mode=allowlist
relay_access.default_action=reject'
mkinst "$G" AnyTLS-01 anytls 20001 true
mkinst "$G" AnyTLS-02 anytls 20002 true
mkinst "$G" Hysteria2-01 hysteria2 20003 true
mkinst "$G" TUIC-01 tuic 20004 true
mkinst "$G" Shadowsocks-01 shadowsocks 20005 true
BASE=$(sb_generate_config "$G")
assert_not_contains "没有任何限制时不生成 route" "$BASE" '"route"'
mkdir -p "$G.nopol"
cp "$G"/*.conf "$G.nopol/"
assert_eq "无限制配置稳定" "$(printf '%s\n' "$BASE" | cksum)" "$(sb_generate_config "$G.nopol" | cksum)"
assert_eq "花括号配平 (无限制)" 0 "$(printf '%s' "$BASE" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
# enabled=false 与没有任何键等价
mkdir -p "$G.off"
cp "$G"/*.conf "$G.off/"
pol "$G.off" AnyTLS-02 relay_access.enabled=false
assert_eq "relay_access.enabled=false 不生成 route" "$(printf '%s\n' "$BASE" | cksum)" "$(sb_generate_config "$G.off" | cksum)"
# 多实例矩阵
M=$T_TMP/matrix
mkdir -p "$M"
cp "$G"/*.conf "$M/"
pol "$M" AnyTLS-02 "$ALLOW" relay_access.destination.1=192.0.2.10:8080
pol "$M" Hysteria2-01 "$ALLOW" relay_access.destination.1=203.0.113.5:9000
pol "$M" Shadowsocks-01 "$ALLOW" relay_access.destination.1=198.51.100.20:1080
OUT=$(sb_generate_config "$M")
assert_eq "花括号配平 (多实例)" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c ',[]}]')"
RT=$(printf '%s\n' "$OUT" | awk '/"route"/,0')
assert_contains "AnyTLS-02 的允许规则" "$(printf '%s' "$RT" | tr -d ' \n')" '{"inbound":["AnyTLS-02"],"ip_cidr":["192.0.2.10/32"],"port":[8080],"action":"route","outbound":"direct"}'
assert_contains "Hysteria2-01 的允许规则" "$(printf '%s' "$RT" | tr -d ' \n')" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.5/32"],"port":[9000],"action":"route","outbound":"direct"}'
assert_contains "Shadowsocks-01 的允许规则" "$(printf '%s' "$RT" | tr -d ' \n')" '{"inbound":["Shadowsocks-01"],"ip_cidr":["198.51.100.20/32"],"port":[1080],"action":"route","outbound":"direct"}'
for t in AnyTLS-02 Hysteria2-01 Shadowsocks-01; do
    assert_eq "$t 有且只有一条 reject 兜底" 1 "$(printf '%s' "$RT" | tr -d ' \n' | grep -o "{\"inbound\":\[\"$t\"\],\"action\":\"reject\"}" | wc -l | tr -d ' ')"
done
for t in AnyTLS-01 TUIC-01; do
    assert_not_contains "不限制的 $t 不出现在 route 里" "$RT" "\"$t\""
done
assert_eq "route 里没有全局 reject" 0 "$(printf '%s' "$RT" | tr -d ' \n' | grep -c '{"action":"reject"}')"
assert_eq "route 里没有 final 与 default" 0 "$(printf '%s' "$RT" | grep -c 'final')"
# 入站块逐字节不变
INB() { printf '%s\n' "$1" | awk '/"inbounds"/,/"outbounds"/'; }
assert_eq "加上 Policy 后入站块逐字节不变" "$(INB "$BASE" | cksum)" "$(INB "$OUT" | cksum)"
# 修改一个实例的 Policy 不改其他实例的规则
M2=$T_TMP/matrix2
mkdir -p "$M2"
cp "$M"/*.conf "$M2/"
pol "$M2" AnyTLS-02 relay_access.destination.2=192.0.2.20:8081
OUT2=$(sb_generate_config "$M2")
for t in Hysteria2-01 Shadowsocks-01; do
    assert_eq "修改 AnyTLS-02 不改变 $t 的规则" "$(printf '%s\n' "$OUT" | tr -d ' \n' | grep -o "{\"inbound\":\[\"$t\"\][^}]*}" | cksum)" "$(printf '%s\n' "$OUT2" | tr -d ' \n' | grep -o "{\"inbound\":\[\"$t\"\][^}]*}" | cksum)"
done
assert_eq "修改后入站块不变" "$(INB "$OUT" | cksum)" "$(INB "$OUT2" | cksum)"
# 每个实例每个目标一条规则, 排序稳定
S1=$T_TMP/sort1
S2=$T_TMP/sort2
mkdir -p "$S1" "$S2"
mkinst "$S1" AnyTLS-01 anytls 20001 true
mkinst "$S2" AnyTLS-01 anytls 20001 true
pol "$S1" AnyTLS-01 "$ALLOW" relay_access.destination.1=192.0.2.90:9 relay_access.destination.2=192.0.2.10:8080 relay_access.destination.3=192.0.2.10:80 "relay_access.destination.4=[2001:db8::1]:443"
pol "$S2" AnyTLS-01 "$ALLOW" "relay_access.destination.7=[2001:db8::1]:443" relay_access.destination.3=192.0.2.10:80 relay_access.destination.1=192.0.2.10:8080 relay_access.destination.2=192.0.2.90:9
assert_eq "目标顺序不同的两个实例文件生成逐字节相同的配置" "$(sb_generate_config "$S1" | cksum)" "$(sb_generate_config "$S2" | cksum)"
assert_eq "规则按地址再按端口排序" "192.0.2.10:80 192.0.2.10:8080 192.0.2.90:9 [2001:db8::1]:443" "$(_sb_policy_dests "$S1/AnyTLS-01.conf" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "IPv6 规则用 /128" "$(sb_generate_config "$S1")" '"2001:db8::1/128"'
assert_eq "4 个目标加 1 条 reject 共 5 条规则" 5 "$(sb_generate_config "$S1" | awk '/"route"/,0' | grep -c '"inbound"')"
# 空 allowlist: 只有 reject
E=$T_TMP/empty
mkdir -p "$E"
mkinst "$E" AnyTLS-01 anytls 20001 true
pol "$E" AnyTLS-01 "$ALLOW"
OUTE=$(sb_generate_config "$E")
assert_eq "空 allowlist 只有一条规则" 1 "$(printf '%s\n' "$OUTE" | awk '/"route"/,0' | grep -c '"inbound"')"
assert_contains "空 allowlist 是拒绝全部" "$(printf '%s' "$OUTE" | tr -d ' \n')" '"rules":[{"inbound":["AnyTLS-01"],"action":"reject"}]'
assert_not_contains "空 allowlist 没有 direct 规则" "$OUTE" '"action": "route"'
# 禁用的实例不产生规则
D=$T_TMP/dis
mkdir -p "$D"
cp "$M"/*.conf "$D/"
sed -i 's/^enabled=.*/enabled=false/' "$D/Hysteria2-01.conf"
OUTD=$(sb_generate_config "$D")
assert_not_contains "禁用实例没有 inbound" "$OUTD" '"tag": "Hysteria2-01"'
assert_not_contains "禁用实例没有规则" "$OUTD" 'Hysteria2-01'
assert_contains "其他实例的规则仍在" "$OUTD" '"AnyTLS-02"'
sed -i 's/^enabled=.*/enabled=true/' "$D/Hysteria2-01.conf"
assert_eq "重新启用后恢复完全相同" "$(printf '%s\n' "$OUT" | cksum)" "$(sb_generate_config "$D" | cksum)"
# 删除实例后没有孤儿规则
rm -f "$D/Shadowsocks-01.conf"
assert_not_contains "删除实例后没有孤儿规则" "$(sb_generate_config "$D")" 'Shadowsocks-01'
# 只有一个实例有限制时的结构
assert_eq "route 在 outbounds 之后" 1 "$(printf '%s\n' "$OUT" | awk '/"outbounds"/{o=NR} /"route"/{r=NR} END{print (r>o)}')"

# ---- fail-closed ----
fc() { # 名称 要追加的行...   在 AnyTLS-02 的副本上追加后生成必须失败
    _n=$1; shift
    rm -rf "$T_TMP/fc"; mkdir -p "$T_TMP/fc"
    mkinst "$T_TMP/fc" AnyTLS-01 anytls 20001 true
    for _l in "$@"; do printf '%s\n' "$_l" >> "$T_TMP/fc/AnyTLS-01.conf"; done
    sb_generate_config "$T_TMP/fc" >/dev/null 2>&1
    assert_eq "fail-closed: $_n 时生成失败" 1 $?
    sbv "$T_TMP/fc/AnyTLS-01.conf" 2>/dev/null
    assert_eq "fail-closed: $_n 时实例校验失败" 1 $?
}
sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
fc "enabled 不是布尔" relay_access.enabled=yes relay_access.mode=allowlist relay_access.default_action=reject
fc "缺少 enabled 只有目标" relay_access.destination.1=192.0.2.10:8080
fc "缺少 mode" relay_access.enabled=true relay_access.default_action=reject
fc "mode 是 denylist" relay_access.enabled=true relay_access.mode=denylist relay_access.default_action=reject
fc "default_action 是 allow" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=allow
fc "目标是域名" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=example.com:80
fc "目标端口为 0" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=10.0.0.1:0
fc "目标不是规范形式 (前导零)" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=010.0.0.1:80
fc "IPv6 目标没有方括号" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=2001:db8::1:80
fc "目标重复" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=10.0.0.1:80 relay_access.destination.2=10.0.0.1:80
fc "未知的 relay_access 键" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.bogus=1
fc "序号为 0" relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.0=10.0.0.1:80
fc "enabled 为空" relay_access.enabled= relay_access.mode=allowlist
# 第二个实例有问题也整体失败, 不会只丢掉那个实例的限制
rm -rf "$T_TMP/fc2"; mkdir -p "$T_TMP/fc2"
cp "$M"/*.conf "$T_TMP/fc2/"
sed -i 's/^relay_access.mode=.*/relay_access.mode=denylist/' "$T_TMP/fc2/Hysteria2-01.conf"
sb_generate_config "$T_TMP/fc2" >/dev/null 2>&1
assert_eq "一个实例的限制无效时整体生成失败" 1 $?
# 损坏的实例不会让 show 说成未启用
out=$(. /dev/null; kv_get "$T_TMP/fc2/Hysteria2-01.conf" id >/dev/null; _sb_policy_show "$T_TMP/fc2/Hysteria2-01.conf")
assert_contains "show 对无效限制明确报告而不是未启用" "$out" "配置无效"
assert_not_contains "show 对无效限制不说未启用" "$out" "未启用"

# ---- CLI: 四种协议 ----
ROUTE() { CFG | awk '/"route"/,0'; }
add4() {
    "$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
    "$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
    "$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
    "$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
}
ready a1
add4
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_eq "$id 升级后没有 relay_access 键 (旧实例自然不限制)" 0 "$(grep -c '^relay_access' "$(INST $id)")"
    assert_contains "$id show 显示未启用" "$("$PM" sing-box show $id)" "目标访问限制：未启用"
    assert_contains "$id access show 显示未启用" "$("$PM" sing-box access $id)" "目标访问限制：未启用"
done
assert_not_contains "未设置任何限制时没有 route" "$(CFG)" '"route"'
sumcfg() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
W0=$(sumcfg)
OUT=$("$PM" sing-box access AnyTLS-01 unrestricted 2>&1)
assert_eq "已经不限制时 unrestricted 成功且不改动" 0 $?
assert_contains "不改动的提示" "$OUT" "没有改动"
assert_eq "配置没变" "$W0" "$(sumcfg)"
"$PM" sing-box access AnyTLS-01 add 192.0.2.10 8080 >/dev/null 2>&1
assert_eq "不限制时直接 add 被拒绝 (必须先显式 allowlist)" 2 $?
assert_eq "被拒绝后没有写入 relay_access" 0 "$(grep -c '^relay_access' "$(INST AnyTLS-01)")"
"$PM" sing-box access AnyTLS-01 clear >/dev/null 2>&1
assert_eq "不限制时 clear 被拒绝" 2 $?
"$PM" sing-box access Nope-01 allowlist >/dev/null 2>&1
assert_eq "实例不存在返回 1" 1 $?
"$PM" sing-box access >/dev/null 2>&1
assert_eq "缺少实例 ID 返回 2" 2 $?
"$PM" sing-box access AnyTLS-01 frobnicate >/dev/null 2>&1
assert_eq "未知操作返回 2" 2 $?
assert_eq "没有违规动作" 0 "$([ -e "$K/violations" ] && echo 1 || echo 0)"

LSB=$(listen_of)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    before_inst=$(grep -v '^relay_access' "$(INST $id)" | cksum)
    OUT=$("$PM" sing-box access $id allowlist 2>&1)
    assert_eq "$id 切到 allowlist 成功" 0 $?
    assert_contains "$id 提示白名单之外一律拒绝" "$OUT" "白名单之外的目标一律拒绝"
    assert_contains "$id 空 allowlist 明确提示拒绝全部" "$OUT" "当前 allowlist 为空, 所有目标将被拒绝"
    assert_eq "$id relay_access.enabled" true "$(kv_get "$(INST $id)" relay_access.enabled)"
    assert_eq "$id relay_access.mode" allowlist "$(kv_get "$(INST $id)" relay_access.mode)"
    assert_eq "$id relay_access.default_action" reject "$(kv_get "$(INST $id)" relay_access.default_action)"
    assert_contains "$id 空 allowlist 生成 reject 规则" "$(ROUTE | tr -d ' \n')" "{\"inbound\":[\"$id\"],\"action\":\"reject\"}"
    assert_contains "$id show 空 allowlist 提示" "$("$PM" sing-box show $id)" "当前 allowlist 为空, 所有目标将被拒绝"
    OUT=$("$PM" sing-box access $id allowlist 2>&1)
    assert_contains "$id 重复切换幂等" "$OUT" "已经是 allowlist"
    "$PM" sing-box access $id add 192.0.2.10 8080 >/dev/null 2>&1
    assert_eq "$id add 成功" 0 $?
    assert_contains "$id 规则含目标" "$(ROUTE | tr -d ' \n')" "{\"inbound\":[\"$id\"],\"ip_cidr\":[\"192.0.2.10/32\"],\"port\":[8080],\"action\":\"route\",\"outbound\":\"direct\"}"
    OUT=$("$PM" sing-box access $id add 192.0.2.10 8080 2>&1)
    assert_eq "$id 重复 add 被拒绝" 1 $?
    assert_contains "$id 重复提示" "$OUT" "已经在 allowlist 里"
    "$PM" sing-box access $id add '[2001:DB8::1]' 443 >/dev/null 2>&1
    assert_eq "$id add IPv6 成功" 0 $?
    assert_contains "$id IPv6 规则" "$(ROUTE | tr -d ' \n')" "\"ip_cidr\":[\"2001:db8::1/128\"],\"port\":[443]"
    OUT=$("$PM" sing-box access $id add 2001:db8::1 443 2>&1)
    assert_eq "$id 同一 IPv6 不同写法算重复" 1 $?
    for bad in "256.1.1.1 80" "192.0.2.10 0" "192.0.2.10 65536" "example.com 80" "192.0.2.10 abc"; do
        # shellcheck disable=SC2086
        OUT=$("$PM" sing-box access $id add $bad 2>&1)
        assert_eq "$id add [$bad] 被拒绝" 2 $?
        assert_contains "$id add [$bad] 给出具体原因" "$OUT" "错误: "
        assert_not_contains "$id add [$bad] 没有 shell 报错" "$OUT" "parameter not set"
    done
    OUT=$("$PM" sing-box access $id add example.com 80 2>&1)
    assert_contains "$id 域名的原因" "$OUT" "第一版只支持 IP 地址, 不支持域名: example.com"
    "$PM" sing-box access $id add 192.0.2.10 >/dev/null 2>&1
    assert_eq "$id add 缺少端口返回 2" 2 $?
    OUT=$("$PM" sing-box show $id)
    assert_contains "$id show Allowlist" "$OUT" "目标访问限制：Allowlist"
    assert_contains "$id show 允许目标" "$OUT" "    192.0.2.10:8080"
    assert_contains "$id show IPv6 目标" "$OUT" "    [2001:db8::1]:443"
    assert_contains "$id show 默认动作" "$OUT" "默认动作：拒绝"
    assert_not_contains "$id show 不出现 GLB" "$OUT" GLB
    "$PM" sing-box access $id delete 192.0.2.10 9999 >/dev/null 2>&1
    assert_eq "$id delete 不存在的目标返回 1" 1 $?
    "$PM" sing-box access $id delete 192.0.2.10 8080 >/dev/null 2>&1
    assert_eq "$id delete 成功" 0 $?
    assert_not_contains "$id 规则里没有已删目标" "$(ROUTE)" "192.0.2.10/32"
    assert_contains "$id 另一个目标仍在" "$(ROUTE)" "2001:db8::1/128"
    OUT=$("$PM" sing-box access $id clear 2>&1)
    assert_eq "$id clear 成功" 0 $?
    assert_contains "$id clear 后提示全部拒绝" "$OUT" "所有目标将被拒绝"
    assert_not_contains "$id clear 后没有 direct 规则" "$(ROUTE | grep -c "\"$id\"" >/dev/null; ROUTE | tr -d ' \n' | grep -o "{\"inbound\":\[\"$id\"\],\"ip_cidr\"[^}]*}")" "$id"
    assert_eq "$id clear 后仍是 allowlist" true "$(kv_get "$(INST $id)" relay_access.enabled)"
    "$PM" sing-box access $id add 192.0.2.10 8080 >/dev/null 2>&1
    assert_eq "$id clear 之后可以重新 add" 0 $?
    assert_eq "$id 协议字段不受影响" "$before_inst" "$(grep -v '^relay_access' "$(INST $id)" | cksum)"
    assert_eq "$id 切换期间监听保持" "$LSB" "$(listen_of)"
    OUT=$("$PM" sing-box access $id unrestricted 2>&1)
    assert_eq "$id 切回 unrestricted 成功" 0 $?
    assert_eq "$id 切回后实例文件没有 relay_access 键" 0 "$(grep -c '^relay_access' "$(INST $id)")"
    assert_not_contains "$id 切回后 route 没有它" "$(ROUTE)" "\"$id\""
    assert_eq "$id 协议字段仍不受影响" "$before_inst" "$(cksum < "$(INST $id)")"
done
assert_not_contains "全部切回后没有 route" "$(CFG)" '"route"'
assert_eq "全部切回后配置与最初逐字节相同" "$W0" "$(sumcfg)"
assert_eq "监听全程保持" "$LSB" "$(listen_of)"
assert_ok "官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"

# ---- 目标与具体地址无关: 任意 IPv4 与 IPv6 加端口, 一个实例多个目标 ----
ready g1
add4
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
"$PM" sing-box access AnyTLS-01 add 192.0.2.10 1080 >/dev/null 2>&1
"$PM" sing-box access TUIC-01 allowlist >/dev/null 2>&1
"$PM" sing-box access TUIC-01 add 203.0.113.5 9000 >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 allowlist >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 add 198.51.100.20 8080 >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 add 198.51.100.21 8080 >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 add 2001:db8::5 1080 >/dev/null 2>&1
RT=$(ROUTE | tr -d ' \n')
assert_contains "AnyTLS 任意目标" "$RT" '{"inbound":["AnyTLS-01"],"ip_cidr":["192.0.2.10/32"],"port":[1080],"action":"route","outbound":"direct"}'
assert_contains "TUIC 任意目标" "$RT" '{"inbound":["TUIC-01"],"ip_cidr":["203.0.113.5/32"],"port":[9000],"action":"route","outbound":"direct"}'
assert_contains "Shadowsocks 第一个目标" "$RT" '{"inbound":["Shadowsocks-01"],"ip_cidr":["198.51.100.20/32"],"port":[8080],"action":"route","outbound":"direct"}'
assert_contains "Shadowsocks 第二个目标" "$RT" '{"inbound":["Shadowsocks-01"],"ip_cidr":["198.51.100.21/32"],"port":[8080],"action":"route","outbound":"direct"}'
assert_contains "Shadowsocks IPv6 目标" "$RT" '{"inbound":["Shadowsocks-01"],"ip_cidr":["2001:db8::5/128"],"port":[1080],"action":"route","outbound":"direct"}'
assert_eq "Shadowsocks 三个目标加一条 reject" 4 "$(printf '%s' "$RT" | grep -o '"inbound":\["Shadowsocks-01"\]' | wc -l | tr -d ' ')"
assert_ok "官方 check 通过 (任意目标)" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "源码不含任何内置目标地址" 0 "$(grep -rl '10\.91\.' "$(dirname "$0")/../lib" "$(dirname "$0")/../bin" | wc -l | tr -d ' ')"

# ---- 跨协议隔离 ----
ready a2
add4
"$PM" sing-box add anytls --port 20005 >/dev/null 2>&1
"$PM" sing-box access AnyTLS-02 allowlist >/dev/null 2>&1
"$PM" sing-box access AnyTLS-02 add 192.0.2.10 8080 >/dev/null 2>&1
"$PM" sing-box access Hysteria2-01 allowlist >/dev/null 2>&1
"$PM" sing-box access Hysteria2-01 add 203.0.113.5 9000 >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 allowlist >/dev/null 2>&1
"$PM" sing-box access Shadowsocks-01 add 198.51.100.20 1080 >/dev/null 2>&1
RT=$(ROUTE | tr -d ' \n')
assert_contains "AnyTLS-02 规则" "$RT" '{"inbound":["AnyTLS-02"],"ip_cidr":["192.0.2.10/32"],"port":[8080],"action":"route","outbound":"direct"},{"inbound":["AnyTLS-02"],"action":"reject"}'
assert_contains "Hysteria2-01 规则" "$RT" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.5/32"],"port":[9000],"action":"route","outbound":"direct"},{"inbound":["Hysteria2-01"],"action":"reject"}'
assert_contains "Shadowsocks-01 规则" "$RT" '{"inbound":["Shadowsocks-01"],"ip_cidr":["198.51.100.20/32"],"port":[1080],"action":"route","outbound":"direct"},{"inbound":["Shadowsocks-01"],"action":"reject"}'
assert_not_contains "AnyTLS-01 不受限制" "$RT" '"AnyTLS-01"'
assert_not_contains "TUIC-01 不受限制" "$RT" '"TUIC-01"'
assert_eq "route 里正好 3 个 reject" 3 "$(printf '%s' "$RT" | grep -o '"action":"reject"' | wc -l | tr -d ' ')"
assert_ok "官方 check 通过 (多实例)" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
for id in AnyTLS-01 TUIC-01; do
    assert_eq "$id 的实例文件仍没有 relay_access" 0 "$(grep -c '^relay_access' "$(INST $id)")"
done
# disable 与 enable
OUT=$("$PM" sing-box disable Hysteria2-01 2>&1)
assert_not_contains "禁用后规则消失" "$(CFG)" "Hysteria2-01"
assert_contains "禁用后实例仍保留限制" "$(cat "$(INST Hysteria2-01)")" "relay_access.destination.1=203.0.113.5:9000"
assert_contains "其他实例的规则仍在" "$(ROUTE)" "AnyTLS-02"
"$PM" sing-box enable Hysteria2-01 >/dev/null 2>&1
assert_contains "启用后规则恢复" "$(ROUTE | tr -d ' \n')" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.5/32"]'
# delete
"$PM" sing-box delete Shadowsocks-01 >/dev/null 2>&1
assert_not_contains "删除实例后没有孤儿规则" "$(CFG)" "Shadowsocks-01"
assert_contains "其余规则保持" "$(ROUTE)" "Hysteria2-01"
assert_ok "删除后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
# 重建同名实例不会继承旧限制
"$PM" sing-box add shadowsocks --name Shadowsocks-01 --port 20004 >/dev/null 2>&1
assert_eq "同名重建的实例没有限制" 0 "$(grep -c '^relay_access' "$(INST Shadowsocks-01)")"

# ---- 回滚 ----
ready r1
add4
"$PM" sing-box access TUIC-01 allowlist >/dev/null 2>&1
"$PM" sing-box access TUIC-01 add 192.0.2.10 8080 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
OLDINST=$(cksum < "$(INST TUIC-01)")
OLDALL=$(for id in AnyTLS-01 Hysteria2-01 Shadowsocks-01; do cksum < "$(INST $id)"; done)
rb() { # 名称
    assert_eq "$1: 配置逐字节恢复" "$OLDCFG" "$(CFG)"
    assert_eq "$1: 监听保持" "$OLDLS" "$(listen_of)"
    assert_eq "$1: 实例文件恢复" "$OLDINST" "$(cksum < "$(INST TUIC-01)")"
    assert_eq "$1: 其他实例文件不变" "$OLDALL" "$(for id in AnyTLS-01 Hysteria2-01 Shadowsocks-01; do cksum < "$(INST $id)"; done)"
    assert_ok "$1: 服务仍运行" running
}
touch "$K/check_fail"
OUT=$("$PM" sing-box access TUIC-01 add 192.0.2.20 8081 2>&1)
assert_eq "check 失败时 add 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
rb "check 失败"
touch "$K/fail_restart-sing-box"
OUT=$("$PM" sing-box access TUIC-01 add 192.0.2.20 8081 2>&1)
assert_eq "重启失败时 add 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
rb "重启失败"
touch "$K/fail_restart-sing-box"
"$PM" sing-box access TUIC-01 unrestricted >/dev/null 2>&1
assert_eq "重启失败时 unrestricted 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
rb "unrestricted 重启失败"
touch "$K/check_fail"
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
assert_eq "check 失败时 allowlist 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "失败后 AnyTLS-01 仍没有 relay_access" 0 "$(grep -c '^relay_access' "$(INST AnyTLS-01)")"
rb "allowlist check 失败"
touch "$K/no_listen-sing-box"
"$PM" sing-box access TUIC-01 add 192.0.2.30 8082 >/dev/null 2>&1
assert_eq "没有监听时 add 失败" 1 $?
rm -f "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rb "监听验证失败"
# 保存实例失败: 配置已提交必须恢复
_sb_sync_instances() { return 1; }
OUT=$(singbox_access TUIC-01 add 192.0.2.40 8083 2>&1)
RC=$?
t_load singbox
assert_eq "保存实例失败时 add 失败" 1 "$RC"
assert_contains "保存实例失败提示" "$OUT" "保存实例失败"
rb "保存实例失败"
# 实例文件被写坏时拒绝生成, 不退回不限制
sed -i 's/^relay_access.mode=.*/relay_access.mode=denylist/' "$(INST TUIC-01)"
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
assert_eq "已有实例的限制损坏时其他变更也被拒绝" 1 $?
assert_contains "配置没有被改成不限制" "$(CFG)" '"TUIC-01"'
assert_contains "show 报告配置无效" "$("$PM" sing-box show TUIC-01)" "配置无效"
OUT=$("$PM" sing-box access TUIC-01 allowlist 2>&1)
assert_eq "显式 allowlist 可以修复损坏的限制" 0 $?
assert_eq "修复后 mode 是 allowlist" allowlist "$(kv_get "$(INST TUIC-01)" relay_access.mode)"
assert_ok "修复后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "没有违规动作" 0 "$([ -e "$K/violations" ] && echo 1 || echo 0)"
t_done
