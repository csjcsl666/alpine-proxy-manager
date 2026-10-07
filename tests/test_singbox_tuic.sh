# shellcheck shell=sh
# TUIC Protocol Instance (UDP/QUIC, UUID 加密码, TLS): 凭据模型, 生成, 与 AnyTLS 和 Hysteria2 共存, 事务回滚, 密码安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_tuic.sh 全部跳过"
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
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# ---- 纯函数: UUID, 校验, 生成 ----
U1=$(_sb_gen_uuid)
U2=$(_sb_gen_uuid)
assert_eq "生成的 UUID 是标准 v4 格式" 1 "$(printf '%s\n' "$U1" | grep -Ec "$UUID_RE")"
assert_eq "UUID 长度 36" 36 "${#U1}"
if [ "$U1" != "$U2" ]; then t_pass "两次生成的 UUID 不同"; else t_fail "两次生成的 UUID 不同"; fi
n=0
i=0
while [ "$i" -lt 40 ]; do
    printf '%s\n' "$(_sb_gen_uuid)" | grep -Eq "$UUID_RE" && n=$((n + 1))
    i=$((i + 1))
done
assert_eq "连续 40 个 UUID 全部合法" 40 "$n"
uv() { _sb_valid_uuid "$1" && echo yes || echo no; }
assert_eq "合法 UUID" yes "$(uv 11111111-2222-4333-8444-555555555555)"
assert_eq "大写 UUID 被拒绝" no "$(uv 11111111-2222-4333-8444-55555555555A)"
assert_eq "缺少分段被拒绝" no "$(uv 111111112222433384445555)"
assert_eq "空值被拒绝" no "$(uv '')"
assert_eq "含空格被拒绝" no "$(uv '11111111-2222-4333-8444-5555555555 5')"
assert_eq "过长被拒绝" no "$(uv 11111111-2222-4333-8444-5555555555555)"

G=$T_TMP/gen
mkdir -p "$G"
mkinst() { # 目录 ID 类型 端口 启用 密码 监听
    printf 'id=%s\nname=%s\ntype=%s\nenabled=%s\nlisten=%s\nlisten_port=%s\ncredential.password=%s\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\n' "$2" "$2" "$3" "$5" "${7:-::}" "$4" "$6" "$2" "$2" > "$1/$2.conf"
}
mkinst "$G" AnyTLS-01 anytls 20001 true AnyTlsPasswordNumberOne0123456789
mkinst "$G" Hysteria2-01 hysteria2 20001 true Hy2PasswordNumberOne0123456789abcd
printf 'id=TUIC-01\nname=TUIC-01\ntype=tuic\nenabled=true\nlisten=::\nlisten_port=20002\ncredential.uuid=11111111-2222-4333-8444-555555555555\ncredential.password=TuicPasswordNumberOne0123456789abc\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/TUIC-01.crt\ntls.key_path=/etc/sing-box/tls/TUIC-01.key\ntransport.type=udp\n' > "$G/TUIC-01.conf"
OUT=$(sb_generate_config "$G")
assert_contains "TUIC inbound 类型" "$OUT" '"type": "tuic"'
assert_contains "TUIC tag" "$OUT" '"tag": "TUIC-01"'
assert_contains "TUIC uuid 字段" "$OUT" '"uuid": "11111111-2222-4333-8444-555555555555"'
assert_contains "TUIC 密码字段" "$OUT" '"password": "TuicPasswordNumberOne0123456789abc"'
assert_not_contains "默认不写 congestion_control" "$OUT" congestion_control
assert_eq "花括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c ',[]}]')"
assert_eq "生成结果稳定" "$(sb_generate_config "$G" | cksum)" "$(sb_generate_config "$G" | cksum)"
mkdir -p "$G.old"
cp "$G/AnyTLS-01.conf" "$G/Hysteria2-01.conf" "$G.old/"
OLDOUT=$(sb_generate_config "$G.old")
assert_eq "新增 TUIC 后 AnyTLS 块逐字节不变" 0 "$(sb_generate_config "$G" | awk '/"type": "anytls"/,/"key_path"/' | while IFS= read -r l; do printf '%s\n' "$OLDOUT" | grep -qF -- "$l" || echo miss; done | grep -c miss)"
assert_eq "新增 TUIC 后 Hysteria2 块逐字节不变" 0 "$(sb_generate_config "$G" | awk '/"type": "hysteria2"/,/"key_path"/' | while IFS= read -r l; do printf '%s\n' "$OLDOUT" | grep -qF -- "$l" || echo miss; done | grep -c miss)"
printf 'transport.congestion_control=bbr\n' >> "$G/TUIC-01.conf"
assert_contains "congestion_control 写入" "$(sb_generate_config "$G")" '"congestion_control": "bbr"'
assert_eq "congestion_control 后 JSON 仍配平" 0 "$(sb_generate_config "$G" | tr -d '\n ' | grep -c ',[]}]')"
assert_eq "期望监听只有 udp" "tcp:20001 udp:20001 udp:20002" "$(_sb_expected_ports "$G")"
assert_eq "类型到传输层" "udp" "$(_sb_type_protos tuic)"
assert_eq "类型到前缀" TUIC "$(_sb_type_prefix tuic)"

sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
assert_ok "有效 TUIC 实例通过校验" sbv "$G/TUIC-01.conf"
bad() { # 名称 sed 表达式
    cp "$G/TUIC-01.conf" "$G/Bad-01.conf"
    sed -i 's/^id=.*/id=Bad-01/; s/^name=.*/name=Bad-01/' "$G/Bad-01.conf"
    sed -i "$2" "$G/Bad-01.conf"
    assert_fail "无效 TUIC 实例被拒绝: $1" sbv "$G/Bad-01.conf"
}
bad "缺少 uuid" '/^credential.uuid=/d'
bad "uuid 为空" 's/^credential.uuid=.*/credential.uuid=/'
bad "uuid 格式错误" 's/^credential.uuid=.*/credential.uuid=not-a-uuid/'
bad "uuid 含大写" 's/^credential.uuid=.*/credential.uuid=11111111-2222-4333-8444-55555555555A/'
bad "缺少密码" '/^credential.password=/d'
bad "密码太短" 's/^credential.password=.*/credential.password=short/'
bad "密码含非法字符" 's/^credential.password=.*/credential.password=bad password with spaces!!/'
bad "congestion_control 不在允许范围" 's/^transport.congestion_control=.*/transport.congestion_control=reno/'
bad "缺少证书" '/^tls.certificate_path=/d'
bad "缺少私钥" '/^tls.key_path=/d'
bad "server_name 无效" 's/^tls.server_name=.*/tls.server_name=bad name/'
bad "端口低于 1025" 's/^listen_port=.*/listen_port=443/'
rm -f "$G/Bad-01.conf"

# ---- add ----
ready u1
OUT=$("$PM" sing-box add tuic --port 20443 2>&1)
RC=$?
assert_eq "add tuic 成功" 0 "$RC"
assert_contains "输出实例名" "$OUT" "已添加实例 TUIC-01"
assert_contains "输出协议与传输层" "$OUT" "协议：tuic (udp)"
PW=$(PW_OF TUIC-01)
UU=$(UU_OF TUIC-01)
assert_eq "密码长度" 32 "${#PW}"
assert_eq "自动生成的 UUID 合法" 1 "$(printf '%s\n' "$UU" | grep -Ec "$UUID_RE")"
assert_contains "输出 UUID" "$OUT" "UUID：$UU"
assert_contains "自动生成的密码只显示一次" "$OUT" "密码：$PW"
assert_eq "密码在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$PW")"
assert_eq "实例文件权限" 600 "$(stat -c %a "$(INST TUIC-01)")"
assert_eq "实例 type" tuic "$(kv_get "$(INST TUIC-01)" type)"
assert_eq "实例传输层" udp "$(kv_get "$(INST TUIC-01)" transport.type)"
assert_ok "证书存在" test -f "$A/etc/sing-box/tls/TUIC-01.crt"
assert_eq "私钥权限" 640 "$(stat -c %a "$A/etc/sing-box/tls/TUIC-01.key")"
assert_contains "配置含 tuic inbound" "$(CFG)" '"type": "tuic"'
assert_contains "配置含 uuid" "$(CFG)" "\"uuid\": \"$UU\""
assert_contains "配置含密码" "$(CFG)" "$PW"
LS=$(listen_of)
assert_contains "UDP 监听出现" "$LS" "udp 0.0.0.0:20443"
assert_not_contains "没有 tcp 监听 (TUIC 只用 udp)" "$LS" "tcp"
assert_ok "官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "密码只存在于实例文件, 配置与受限的备份" "" "$(leaks "$PW" "$A/etc/alpine-proxy-manager/instances/TUIC-01.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_not_contains "元数据不含密码" "$(cat "$(META)")" "$PW"
out=$("$PM" sing-box list)
assert_contains "list 显示 tuic 监听中" "$out" "TUIC-01  tuic  启用, 监听中"
out=$("$PM" sing-box show TUIC-01)
assert_contains "show 显示 UUID" "$out" "UUID：$UU"
assert_contains "show 内部 UDP Listener" "$out" "内部 UDP Listener：正常"
assert_contains "show 密码已配置" "$out" "密码：已配置"
assert_contains "show 默认拥塞控制" "$out" "拥塞控制：默认 (cubic)"
assert_contains "show 不宣称公网可达" "$out" "公网可达性 (NAT 与防火墙) 没有验证"
all=$("$PM" sing-box status; "$PM" sing-box info; "$PM" sing-box list; "$PM" sing-box show TUIC-01; "$PM" core list; "$PM" status; "$PM" sing-box log 20 2>&1)
assert_not_contains "只读输出不含密码" "$all" "$PW"
assert_not_contains "只读输出不含密码片段" "$all" "$(printf '%s' "$PW" | cut -c1-8)"
assert_fail "没有违规动作" test -e "$K/violations"

# 自定义选项
OUT=$(printf 'ProvidedTuicPasswordForTests0123456789\n' | "$PM" sing-box add tuic --name Tuic-Edge --listen 127.0.0.1 --server-name www.example.com --port 20444 --password-stdin --uuid aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee --congestion-control bbr 2>&1)
assert_contains "自定义名称" "$OUT" "已添加实例 Tuic-Edge"
assert_eq "使用提供的密码" ProvidedTuicPasswordForTests0123456789 "$(PW_OF Tuic-Edge)"
assert_not_contains "提供的密码不回显" "$OUT" "ProvidedTuicPassword"
assert_eq "使用提供的 UUID" aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee "$(UU_OF Tuic-Edge)"
assert_eq "拥塞控制写入实例" bbr "$(kv_get "$(INST Tuic-Edge)" transport.congestion_control)"
assert_contains "拥塞控制写入配置" "$(CFG)" '"congestion_control": "bbr"'
assert_ok "官方 check 通过 (含 congestion_control)" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
OUT=$("$PM" sing-box add tuic --port 20445 2>&1)
assert_contains "自动编号递增" "$OUT" "已添加实例 TUIC-02"
assert_ne_uuid() { if [ "$(UU_OF TUIC-01)" != "$(UU_OF TUIC-02)" ]; then t_pass "两个实例的 UUID 不同"; else t_fail "两个实例的 UUID 不同"; fi; }
assert_ne_uuid
for a in "--port 443" "--port abc" "--listen bad" "--server-name bad_name" "--name bad/name" "--uuid BAD" "--uuid 11111111-2222-4333-8444-55555555555A" "--congestion-control reno" "--method aes-128-gcm" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" sing-box add tuic $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
printf 'short\n' | "$PM" sing-box add tuic --password-stdin >/dev/null 2>&1
assert_eq "无效密码返回 2" 2 $?
"$PM" sing-box add tuic --password somesecret >/dev/null 2>&1
assert_eq "不接受命令行明文密码" 2 $?
BEFORE=$(snap)
OUT=$("$PM" sing-box add tuic --port 20443 2>&1)
assert_eq "UDP 端口重复被拒绝" 1 $?
assert_contains "UDP 重复提示" "$OUT" "udp 端口 20443 已被其他实例使用"
"$PM" sing-box add tuic --listen 127.0.0.1 --port 20443 >/dev/null 2>&1
assert_eq "具体地址与通配地址重叠被拒绝" 1 $?
assert_eq "拒绝后没有任何改动" "$BEFORE" "$(snap)"

# ---- 与 AnyTLS 和 Hysteria2 共存: UDP 同端口在 TUIC 与 Hysteria2 之间冲突, 与 AnyTLS 的 TCP 不冲突 ----
ready m1
"$PM" sing-box add anytls --port 20000 >/dev/null 2>&1
OUT=$("$PM" sing-box add tuic --port 20000 2>&1)
assert_eq "AnyTLS 的 TCP 20000 与 TUIC 的 UDP 20000 可以共存" 0 $?
"$PM" sing-box add hysteria2 --port 20000 >/dev/null 2>&1
assert_eq "TUIC 已占 UDP 20000, Hysteria2 同端口被拒绝" 1 $?
"$PM" sing-box add hysteria2 --port 20001 >/dev/null 2>&1
assert_eq "Hysteria2 用别的端口可以添加" 0 $?
"$PM" sing-box add tuic --port 20001 >/dev/null 2>&1
assert_eq "Hysteria2 已占 UDP 20001, TUIC 同端口被拒绝" 1 $?
assert_eq "三种协议实例并存" "1 1 1" "$(CFG | grep -c '"type": "anytls"') $(CFG | grep -c '"type": "tuic"') $(CFG | grep -c '"type": "hysteria2"')"
LS=$(listen_of)
assert_contains "TCP 20000 在监听" "$LS" "tcp 0.0.0.0:20000"
assert_contains "UDP 20000 在监听" "$LS" "udp 0.0.0.0:20000"
assert_contains "UDP 20001 在监听" "$LS" "udp 0.0.0.0:20001"
ready m2
"$PM" sing-box add tuic --listen 127.0.0.1 --port 20020 >/dev/null 2>&1
"$PM" sing-box add tuic --listen 10.0.0.5 --port 20020 >/dev/null 2>&1
assert_eq "不同具体地址同端口同协议可以共存" 0 $?
"$PM" sing-box add tuic --port 20020 >/dev/null 2>&1
assert_eq "通配地址与已有具体地址冲突" 1 $?

# ---- 系统端口占用 ----
ready o1
foreign tcp 20100 00000000 9001
"$PM" sing-box add tuic --port 20100 >/dev/null 2>&1
assert_eq "只有 TCP 占用同数字端口时 TUIC 可以添加" 0 $?
"$PM" sing-box delete TUIC-01 >/dev/null 2>&1
: > "$K/foreign.tcp"
rm -f "$A/proc/net/tcp"
foreign udp 20101 00000000 9002
OUT=$("$PM" sing-box add tuic --port 20101 2>&1)
assert_eq "UDP 占用的端口 TUIC 被拒绝" 1 $?
assert_contains "UDP 占用提示" "$OUT" "udp 端口 20101 已被占用"
: > "$K/foreign.udp"

# ---- set enable disable delete ----
ready s1
"$PM" sing-box add anytls --port 20600 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20700 >/dev/null 2>&1
PW=$(PW_OF TUIC-01)
UU=$(UU_OF TUIC-01)
ANYCFG=$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')
"$PM" sing-box set TUIC-01 port 20701 >/dev/null 2>&1
assert_eq "set port 成功" 0 $?
LS=$(listen_of)
assert_contains "UDP 新端口监听" "$LS" "udp 0.0.0.0:20701"
assert_not_contains "UDP 旧端口消失" "$LS" ":20700"
assert_eq "AnyTLS 的配置块不变" "$ANYCFG" "$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')"
assert_eq "UUID 与密码保持" "$UU $PW" "$(UU_OF TUIC-01) $(PW_OF TUIC-01)"
"$PM" sing-box set TUIC-01 listen 0.0.0.0 >/dev/null 2>&1
assert_eq "set listen 成功" 0 $?
OUT=$("$PM" sing-box set TUIC-01 server-name www.example.org 2>&1)
assert_eq "set server-name 成功" 0 $?
assert_contains "证书重新生成" "$(cat "$A/etc/sing-box/tls/TUIC-01.crt")" "FAKECERTFOR_www.example.org"
OUT=$("$PM" sing-box set TUIC-01 congestion-control new_reno 2>&1)
assert_eq "set congestion-control 成功" 0 $?
assert_contains "拥塞控制进入配置" "$(CFG)" '"congestion_control": "new_reno"'
"$PM" sing-box set TUIC-01 congestion-control reno >/dev/null 2>&1
assert_eq "无效的拥塞控制返回 2" 2 $?
OUT=$("$PM" sing-box set TUIC-01 uuid --generate 2>&1)
assert_eq "set uuid --generate 成功" 0 $?
if [ "$(UU_OF TUIC-01)" != "$UU" ]; then t_pass "UUID 已更换"; else t_fail "UUID 已更换"; fi
assert_contains "新 UUID 显示" "$OUT" "$(UU_OF TUIC-01)"
"$PM" sing-box set TUIC-01 uuid 22222222-3333-4444-8555-666666666666 >/dev/null 2>&1
assert_eq "set uuid 指定值成功" 22222222-3333-4444-8555-666666666666 "$(UU_OF TUIC-01)"
"$PM" sing-box set TUIC-01 uuid BAD >/dev/null 2>&1
assert_eq "无效 uuid 返回 2" 2 $?
OUT=$("$PM" sing-box set TUIC-01 password --generate 2>&1)
assert_eq "set password --generate 成功" 0 $?
NEWPW=$(PW_OF TUIC-01)
if [ "$NEWPW" != "$PW" ]; then t_pass "密码已更换"; else t_fail "密码已更换"; fi
assert_eq "新密码只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$NEWPW")"
OUT=$(printf 'StdinTuicPasswordForTest0123456789\n' | "$PM" sing-box set TUIC-01 password --stdin 2>&1)
assert_not_contains "stdin 密码不回显" "$OUT" "StdinTuicPassword"
"$PM" sing-box set TUIC-01 password PlainTextOnCommandLine0123456 >/dev/null 2>&1
assert_eq "密码不接受命令行明文" 2 $?
"$PM" sing-box set TUIC-01 method aes-128-gcm >/dev/null 2>&1
assert_eq "tuic 没有 method 返回 2" 2 $?
"$PM" sing-box set TUIC-01 port 80 >/dev/null 2>&1
assert_eq "set port 低于 1025 返回 2" 2 $?
"$PM" sing-box set TUIC-01 port 20600 >/dev/null 2>&1
assert_eq "set port 到 AnyTLS 的 TCP 同数字端口允许" 0 $?
"$PM" sing-box add tuic --port 20800 >/dev/null 2>&1
"$PM" sing-box set TUIC-01 port 20800 >/dev/null 2>&1
assert_eq "set port 到其他 TUIC 的端口被拒绝" 1 $?
"$PM" sing-box disable TUIC-01 >/dev/null 2>&1
assert_eq "disable 成功" 0 $?
assert_not_contains "禁用后 UDP 监听消失" "$(listen_of)" "udp 0.0.0.0:20600"
assert_eq "禁用后配置里没有 TUIC-01" 0 "$(CFG | grep -c 'TUIC-01')"
assert_ok "禁用后实例与证书仍在" test -f "$A/etc/sing-box/tls/TUIC-01.crt"
assert_contains "list 显示禁用" "$("$PM" sing-box list)" "TUIC-01  tuic  禁用"
"$PM" sing-box enable TUIC-01 >/dev/null 2>&1
assert_contains "启用后 UDP 监听恢复" "$(listen_of)" "udp 0.0.0.0:20600"
"$PM" sing-box delete TUIC-01 >/dev/null 2>&1
assert_eq "delete 成功" 1 "$([ ! -e "$(INST TUIC-01)" ] && echo 1 || echo 0)"
assert_fail "删除后证书已删" test -e "$A/etc/sing-box/tls/TUIC-01.crt"
assert_ok "删除不误删 AnyTLS 的证书" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_contains "删除后 AnyTLS 仍在监听" "$(listen_of)" "tcp 0.0.0.0:20600"

# ---- 事务回滚 ----
ready t1
"$PM" sing-box add anytls --port 20900 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20901 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
rollback_ok() {
    assert_eq "$1: 配置恢复逐字节一致" "$OLDCFG" "$(CFG)"
    assert_eq "$1: 监听与旧状态一致" "$OLDLS" "$(listen_of)"
    assert_ok "$1: 服务仍在运行" running
}
BEFORE=$(snap)
touch "$K/check_fail"
OUT=$("$PM" sing-box add tuic --port 20902 2>&1)
assert_eq "check 失败时 add 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
rollback_ok "check 失败"
assert_eq "check 失败后没有任何改动" "$BEFORE" "$(snap)"
echo 20902 > "$K/fail_port-sing-box"
OUT=$("$PM" sing-box add tuic --port 20902 2>&1)
assert_eq "重启失败时 add 失败" 1 $?
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
: > "$K/fail_port-sing-box"
rollback_ok "重启失败"
assert_fail "重启失败后没有新实例" test -e "$(INST TUIC-02)"
assert_fail "重启失败后新证书已清理" test -e "$A/etc/sing-box/tls/TUIC-02.crt"
touch "$K/no_listen-sing-box"
"$PM" sing-box add tuic --port 20903 >/dev/null 2>&1
assert_eq "UDP 没有监听时 add 失败" 1 $?
rm -f "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rollback_ok "监听验证失败"
touch "$K/gen_fail"
BEFORE=$(snap)
"$PM" sing-box add tuic --port 20904 >/dev/null 2>&1
assert_eq "证书生成失败时 add 失败" 1 $?
rm -f "$K/gen_fail"
assert_eq "证书生成失败没有任何改动" "$BEFORE" "$(snap)"
OLDUU=$(UU_OF TUIC-01)
touch "$K/check_fail"
"$PM" sing-box set TUIC-01 uuid --generate >/dev/null 2>&1
assert_eq "check 失败时 set uuid 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "UUID 保持旧值" "$OLDUU" "$(UU_OF TUIC-01)"
rollback_ok "set uuid 失败"
OLDPW=$(PW_OF TUIC-01)
touch "$K/check_fail"
"$PM" sing-box set TUIC-01 password --generate >/dev/null 2>&1
rm -f "$K/check_fail"
assert_eq "密码保持旧值" "$OLDPW" "$(PW_OF TUIC-01)"
touch "$K/check_fail"
"$PM" sing-box set TUIC-01 congestion-control bbr >/dev/null 2>&1
assert_eq "check 失败时 set congestion-control 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "拥塞控制保持未设置" "" "$(kv_get "$(INST TUIC-01)" transport.congestion_control)"
rollback_ok "set congestion-control 失败"
# 回滚后的 TUIC 实例没有被误删
assert_ok "回滚后 TUIC 实例仍在" test -f "$(INST TUIC-01)"
assert_ok "回滚后 AnyTLS 实例仍在" test -f "$(INST AnyTLS-01)"

# ---- purge 删除 TUIC 实例与证书 ----
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_fail "purge 后 TUIC 实例已删" test -e "$(INST TUIC-01)"
assert_fail "purge 后 TUIC 证书已删" test -e "$A/etc/sing-box/tls/TUIC-01.crt"
assert_fail "没有违规动作" test -e "$K/violations"
t_done
