# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy

I="$T_TMP/instances"
S="$T_TMP/socks"
mkdir -p "$I" "$S"

# 写实例文件: inst ID [额外行...]
inst() {
    _id=$1
    shift
    {
        printf 'id=%s\nname=%s\ntype=anytls\nenabled=true\nlisten=::\nlisten_port=52147\n' "$_id" "$_id"
        for _l in "$@"; do printf '%s\n' "$_l"; done
    } > "$I/$_id.conf"
}
valid_inst() { instance_validate "$I/$1.conf" 2>/dev/null; }

# ---- Protocol Instance ----
inst AnyTLS-01 credential.password=example-secret
assert_ok "基本实例有效" valid_inst AnyTLS-01
inst AnyTLS-02 relay_access.enabled=false
assert_ok "关闭的目标访问限制有效" valid_inst AnyTLS-02

for t in snell anytls hysteria2 tuic shadowsocks; do
    inst "T-$t"
    sed -i "s/^type=.*/type=$t/" "$I/T-$t.conf"
    assert_ok "type $t 有效" valid_inst "T-$t"
done
inst Bad-Type
sed -i 's/^type=.*/type=both/' "$I/Bad-Type.conf"
assert_fail "type=both 被拒绝" valid_inst Bad-Type

inst Bad-Port
sed -i 's/^listen_port=.*/listen_port=70000/' "$I/Bad-Port.conf"
assert_fail "端口越界被拒绝" valid_inst Bad-Port
sed -i 's/^listen_port=.*/listen_port=0/' "$I/Bad-Port.conf"
assert_fail "端口 0 被拒绝" valid_inst Bad-Port
sed -i 's/^listen_port=.*/listen_port=80a/' "$I/Bad-Port.conf"
assert_fail "端口含字母被拒绝" valid_inst Bad-Port

inst Bad-En
sed -i 's/^enabled=.*/enabled=yes/' "$I/Bad-En.conf"
assert_fail "enabled 非布尔被拒绝" valid_inst Bad-En

inst Bad-Listen
sed -i 's/^listen=.*/listen=not an addr/' "$I/Bad-Listen.conf"
assert_fail "listen 无效被拒绝" valid_inst Bad-Listen
inst V4-Listen
sed -i 's/^listen=.*/listen=0.0.0.0/' "$I/V4-Listen.conf"
assert_ok "listen=0.0.0.0 有效" valid_inst V4-Listen

inst Name-Mismatch
cp "$I/Name-Mismatch.conf" "$I/Other.conf"
assert_fail "id 与文件名不一致被拒绝" valid_inst Other

inst Unknown-Key foo=bar
assert_fail "未知 key 被拒绝" valid_inst Unknown-Key
inst Dup-Key listen_port=1
assert_fail "重复 key 被拒绝" valid_inst Dup-Key
printf 'id=Junk\nthis is not kv\n' > "$I/Junk.conf"
assert_fail "语法错误被拒绝" valid_inst Junk

inst Egress egress_socks=SOCKS-A
assert_ok "明确绑定 SOCKS Profile 有效" valid_inst Egress
inst Egress-Bad "egress_socks=../x"
assert_fail "egress_socks 含路径被拒绝" valid_inst Egress-Bad
assert_eq "egress_socks 读取" "SOCKS-A" "$(kv_get "$I/Egress.conf" egress_socks)"

# ---- Relay Access Policy ----
inst GLB relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.1=192.0.2.10:8080
assert_ok "完整的 allowlist 有效" valid_inst GLB
assert_ok "policy_enabled" policy_enabled "$I/GLB.conf"
assert_eq "destinations 输出 host port" "192.0.2.10 8080" "$(policy_destinations "$I/GLB.conf")"
assert_eq "摘要" "allowlist (1 项)" "$(policy_summary "$I/GLB.conf")"
assert_eq "关闭时摘要" "关闭" "$(policy_summary "$I/AnyTLS-02.conf")"

inst GLB2 relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject "relay_access.destination.2=[2001:db8::1]:443" relay_access.destination.10=example.com:8443 relay_access.destination.1=192.0.2.10:8080
assert_ok "IPv4, IPv6, 主机名混合有效" valid_inst GLB2
assert_eq "destination 按序号数值排序" "192.0.2.10 8080
[2001:db8::1] 443
example.com 8443" "$(policy_destinations "$I/GLB2.conf")"

inst P1 relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject
assert_ok "启用但无 destination 合法 (空 allowlist 拒绝全部)" valid_inst P1
inst P2 relay_access.enabled=true relay_access.mode=allowlist relay_access.destination.1=192.0.2.10:8080
assert_fail "启用但缺 default_action 被拒绝" valid_inst P2
inst P3 relay_access.enabled=true relay_access.default_action=reject relay_access.destination.1=192.0.2.10:8080
assert_fail "启用但缺 mode 被拒绝" valid_inst P3
inst P4 relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=allow relay_access.destination.1=192.0.2.10:8080
assert_fail "default_action=allow 被拒绝" valid_inst P4
inst P5 relay_access.enabled=true relay_access.mode=denylist relay_access.default_action=reject relay_access.destination.1=192.0.2.10:8080
assert_fail "mode=denylist 被拒绝" valid_inst P5
for d in 192.0.2.10 192.0.2.10:0 999.1.1.1:80 "*:80" ":80" "host:port" "a b:80"; do
    inst P6 relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject "relay_access.destination.1=$d"
    assert_fail "非法 destination [$d] 被拒绝" valid_inst P6
done
inst P7 relay_access.enabled=true relay_access.mode=allowlist relay_access.default_action=reject relay_access.destination.0=192.0.2.10:8080
assert_fail "destination 序号 0 被拒绝" valid_inst P7

# 同一实例集合内策略互相独立: 没有全局开关
assert_ok "GLB 启用" policy_enabled "$I/GLB.conf"
assert_fail "AnyTLS-01 不受 GLB 影响" policy_enabled "$I/AnyTLS-01.conf"

# ---- Server SOCKS Profile ----
sk() {
    _n=$1
    shift
    {
        printf 'name=%s\nhost=198.51.100.7\nport=1080\nenabled=true\n' "$_n"
        for _l in "$@"; do printf '%s\n' "$_l"; done
    } > "$S/$_n.conf"
}
valid_sk() { socks_validate "$S/$1.conf" 2>/dev/null; }
sk SOCKS-A
assert_ok "无认证 Profile 有效" valid_sk SOCKS-A
sk SOCKS-B username=u password=p
assert_ok "带认证 Profile 有效" valid_sk SOCKS-B
sk SOCKS-C username=u
assert_fail "只有 username 被拒绝" valid_sk SOCKS-C
sk SOCKS-D password=p
assert_fail "只有 password 被拒绝" valid_sk SOCKS-D
sk SOCKS-E fallback=SOCKS-A
assert_fail "fallback 在 v0.1 被拒绝" valid_sk SOCKS-E
sk SOCKS-F priority=1
assert_fail "未知字段被拒绝, 不存在自动选择相关字段" valid_sk SOCKS-F
sk SOCKS-G
sed -i 's/^port=.*/port=99999/' "$S/SOCKS-G.conf"
assert_fail "Profile 端口越界" valid_sk SOCKS-G
sk SOCKS-H
sed -i 's/^host=.*/host=/' "$S/SOCKS-H.conf"
assert_fail "Profile host 为空" valid_sk SOCKS-H

# ---- 状态汇总 ----
APM_ETC="$T_TMP/etc"
mkdir -p "$APM_ETC"
assert_eq "无配置时 SOCKS 未配置" "未配置" "$(state_socks_summary)"
assert_eq "无配置时 Relay 未配置" "未配置" "$(state_relay_summary)"
mkdir -p "$APM_ETC/socks" "$APM_ETC/instances"
cp "$S/SOCKS-A.conf" "$S/SOCKS-B.conf" "$S/SOCKS-C.conf" "$APM_ETC/socks/"
assert_eq "SOCKS 汇总含无效计数" "已配置 3 个 Profile (启用 2 个), 1 个无效" "$(state_socks_summary)"
cp "$I/GLB.conf" "$I/AnyTLS-01.conf" "$APM_ETC/instances/"
assert_eq "Relay 汇总" "1 个实例启用" "$(state_relay_summary)"
t_done
