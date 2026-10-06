# shellcheck shell=sh
# Shadowsocks Protocol Instance (TCP 与 UDP 双传输, method 加按 method 决定格式的密钥, 无 TLS): 双协议端口模型, 事务回滚, 密钥安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_shadowsocks.sh 全部跳过"
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

K16=AAAAAAAAAAAAAAAAAAAAAA==
K32=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
PSKA=ClassicPasswordForAes128Gcm0123456789

# ---- 纯函数: method, 密钥规格 ----
mth() { _sb_ss_method_valid "$1" && echo yes || echo no; }
for m in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
    assert_eq "允许的 method $m" yes "$(mth $m)"
done
for m in none rc4-md5 aes-192-gcm xchacha20-ietf-poly1305 AES-128-GCM '' 2022-blake3-aes-512-gcm; do
    assert_eq "拒绝的 method [$m]" no "$(mth "$m")"
done
assert_eq "默认 method" 2022-blake3-aes-128-gcm "$SB_SS_DEFAULT_METHOD"
assert_eq "2022 aes-128 密钥规格" b64:16 "$(_sb_secret_kind shadowsocks 2022-blake3-aes-128-gcm)"
assert_eq "2022 aes-256 密钥规格" b64:32 "$(_sb_secret_kind shadowsocks 2022-blake3-aes-256-gcm)"
assert_eq "2022 chacha 密钥规格" b64:32 "$(_sb_secret_kind shadowsocks 2022-blake3-chacha20-poly1305)"
assert_eq "传统 aes-128-gcm 是普通密码" psk "$(_sb_secret_kind shadowsocks aes-128-gcm)"
assert_eq "传统 chacha 是普通密码" psk "$(_sb_secret_kind shadowsocks chacha20-ietf-poly1305)"
sv() { _sb_valid_secret "$1" "$2" && echo yes || echo no; }
assert_eq "16 字节密钥有效" yes "$(sv b64:16 "$K16")"
assert_eq "32 字节密钥有效" yes "$(sv b64:32 "$K32")"
assert_eq "16 字节规格拒绝 32 字节密钥" no "$(sv b64:16 "$K32")"
assert_eq "32 字节规格拒绝 16 字节密钥" no "$(sv b64:32 "$K16")"
assert_eq "base64 规格拒绝普通密码" no "$(sv b64:16 "$PSKA")"
assert_eq "base64 规格拒绝空值" no "$(sv b64:16 '')"
assert_eq "base64 规格拒绝缺少填充" no "$(sv b64:16 AAAAAAAAAAAAAAAAAAAAAA)"
assert_eq "base64 规格拒绝非法字符" no "$(sv b64:16 'AAAAAAAAAAAAAAAAAAAA!!==')"
assert_eq "psk 规格拒绝过短" no "$(sv psk short)"
assert_eq "psk 规格接受普通密码" yes "$(sv psk "$PSKA")"
g16=$(_sb_gen_secret b64:16)
g32=$(_sb_gen_secret b64:32)
assert_eq "生成的 16 字节密钥长度与有效性" "24 yes" "${#g16} $(sv b64:16 "$g16")"
assert_eq "生成的 32 字节密钥长度与有效性" "44 yes" "${#g32} $(sv b64:32 "$g32")"
if [ "$g16" != "$(_sb_gen_secret b64:16)" ]; then t_pass "两次生成的密钥不同"; else t_fail "两次生成的密钥不同"; fi
assert_eq "类型到传输层" "tcp udp" "$(_sb_type_protos shadowsocks)"
assert_eq "传输层名称" tcp+udp "$(_sb_type_transport shadowsocks)"
assert_eq "类型到前缀" Shadowsocks "$(_sb_type_prefix shadowsocks)"
assert_fail "Shadowsocks 不使用 TLS" _sb_type_tls shadowsocks
assert_ok "TUIC 使用 TLS" _sb_type_tls tuic

# ---- 生成 ----
G=$T_TMP/gen
mkdir -p "$G"
mkss() { # 目录 ID 端口 启用 method 密钥
    printf 'id=%s\nname=%s\ntype=shadowsocks\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.method=%s\ncredential.password=%s\ntransport.type=tcp+udp\n' "$2" "$2" "$4" "$3" "$5" "$6" > "$1/$2.conf"
}
mkinst() {
    printf 'id=%s\nname=%s\ntype=%s\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.password=%s\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\n' "$2" "$2" "$3" "$5" "$4" "$6" "$2" "$2" > "$1/$2.conf"
}
mkinst "$G" AnyTLS-01 anytls 20001 true AnyTlsPasswordNumberOne0123456789
mkinst "$G" Hysteria2-01 hysteria2 20001 true Hy2PasswordNumberOne0123456789abcd
mkss "$G" Shadowsocks-01 20003 true 2022-blake3-aes-128-gcm "$K16"
OUT=$(sb_generate_config "$G")
assert_contains "Shadowsocks inbound 类型" "$OUT" '"type": "shadowsocks"'
assert_contains "Shadowsocks tag" "$OUT" '"tag": "Shadowsocks-01"'
assert_contains "method 字段" "$OUT" '"method": "2022-blake3-aes-128-gcm"'
assert_contains "密钥字段" "$OUT" "\"password\": \"$K16\""
SSBLK=$(printf '%s\n' "$OUT" | awk '/"type": "shadowsocks"/,/^    }/')
assert_not_contains "Shadowsocks 块没有 tls" "$SSBLK" tls
assert_not_contains "Shadowsocks 块没有 users" "$SSBLK" users
assert_not_contains "Shadowsocks 块没有证书" "$SSBLK" certificate
assert_eq "花括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c ',[]}]')"
assert_eq "生成结果稳定" "$(sb_generate_config "$G" | cksum)" "$(sb_generate_config "$G" | cksum)"
mkdir -p "$G.old"
cp "$G/AnyTLS-01.conf" "$G/Hysteria2-01.conf" "$G.old/"
OLDOUT=$(sb_generate_config "$G.old")
assert_eq "新增 Shadowsocks 后 AnyTLS 块逐字节不变" 0 "$(sb_generate_config "$G" | awk '/"type": "anytls"/,/"key_path"/' | while IFS= read -r l; do printf '%s\n' "$OLDOUT" | grep -qF -- "$l" || echo miss; done | grep -c miss)"
assert_eq "新增 Shadowsocks 后 Hysteria2 块逐字节不变" 0 "$(sb_generate_config "$G" | awk '/"type": "hysteria2"/,/"key_path"/' | while IFS= read -r l; do printf '%s\n' "$OLDOUT" | grep -qF -- "$l" || echo miss; done | grep -c miss)"
assert_eq "期望监听 Shadowsocks 同时 tcp 与 udp" "tcp:20001 udp:20001 tcp:20003 udp:20003" "$(_sb_expected_ports "$G")"
mkss "$G" Shadowsocks-02 20004 false aes-128-gcm "$PSKA"
assert_not_contains "禁用的不生成" "$(sb_generate_config "$G")" Shadowsocks-02
assert_eq "禁用的不进入期望监听" "tcp:20001 udp:20001 tcp:20003 udp:20003" "$(_sb_expected_ports "$G")"

# ---- 校验 ----
sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
assert_ok "2022 实例通过校验" sbv "$G/Shadowsocks-01.conf"
assert_ok "传统 method 实例通过校验" sbv "$G/Shadowsocks-02.conf"
bad() { # 名称 源 sed
    cp "$G/$2.conf" "$G/Bad-01.conf"
    sed -i 's/^id=.*/id=Bad-01/; s/^name=.*/name=Bad-01/' "$G/Bad-01.conf"
    sed -i "$3" "$G/Bad-01.conf"
    assert_fail "无效实例被拒绝: $1" sbv "$G/Bad-01.conf"
}
bad "缺少 method" Shadowsocks-01 '/^credential.method=/d'
bad "method 不在允许范围 (none)" Shadowsocks-01 's/^credential.method=.*/credential.method=none/'
bad "method 不在允许范围 (rc4-md5)" Shadowsocks-01 's/^credential.method=.*/credential.method=rc4-md5/'
bad "缺少密钥" Shadowsocks-01 '/^credential.password=/d'
bad "2022 aes-128 配了 32 字节密钥" Shadowsocks-01 "s#^credential.password=.*#credential.password=$K32#"
bad "2022 aes-128 配了普通密码" Shadowsocks-01 "s#^credential.password=.*#credential.password=$PSKA#"
bad "2022 aes-256 配了 16 字节密钥" Shadowsocks-01 "s/^credential.method=.*/credential.method=2022-blake3-aes-256-gcm/"
bad "传统 method 配了过短密码" Shadowsocks-02 's/^credential.password=.*/credential.password=short/'
bad "传统 method 密码含非法字符" Shadowsocks-02 's/^credential.password=.*/credential.password=bad password with spaces!!/'
bad "端口低于 1025" Shadowsocks-01 's/^listen_port=.*/listen_port=443/'
rm -f "$G/Bad-01.conf"
cp "$G/Shadowsocks-01.conf" "$G/Ok-02.conf"
sed -i 's/^id=.*/id=Ok-02/; s/^name=.*/name=Ok-02/; s/^credential.method=.*/credential.method=2022-blake3-aes-256-gcm/' "$G/Ok-02.conf"
sed -i "s#^credential.password=.*#credential.password=$K32#" "$G/Ok-02.conf"
assert_ok "2022 aes-256 配 32 字节密钥通过" sbv "$G/Ok-02.conf"
rm -f "$G/Ok-02.conf"

# ---- 双协议的实例冲突模型 ----
tk() { _sb_port_taken_by_instance "$G" "$@" && echo yes || echo no; }
assert_eq "tcp 20003 被 Shadowsocks 占用" yes "$(tk tcp 20003 ::)"
assert_eq "udp 20003 被 Shadowsocks 占用" yes "$(tk udp 20003 ::)"
assert_eq "tcp 20001 被 AnyTLS 占用" yes "$(tk tcp 20001 ::)"
assert_eq "Shadowsocks 排除自身后 tcp 不冲突" no "$(tk tcp 20003 :: Shadowsocks-01)"
assert_eq "Shadowsocks 排除自身后 udp 不冲突" no "$(tk udp 20003 :: Shadowsocks-01)"
CF_LISTEN="tcp [::]:20003 1"
assert_eq "只有 tcp 监听时 Shadowsocks 不健康" no "$(printf 'x' >/dev/null; _sb_inst_listening "$G/Shadowsocks-01.conf" && echo yes || echo no)"
CF_LISTEN="tcp [::]:20003 1
udp [::]:20003 1"
assert_eq "tcp 与 udp 都在监听时健康" yes "$(_sb_inst_listening "$G/Shadowsocks-01.conf" && echo yes || echo no)"
CF_LISTEN="udp [::]:20003 1"
assert_eq "只有 udp 监听时不健康" no "$(_sb_inst_listening "$G/Shadowsocks-01.conf" && echo yes || echo no)"

# ---- add ----
ready z1
OUT=$("$PM" sing-box add shadowsocks --port 20443 2>&1)
RC=$?
assert_eq "add shadowsocks 成功" 0 "$RC"
assert_contains "输出实例名" "$OUT" "已添加实例 Shadowsocks-01"
assert_contains "输出协议与传输层" "$OUT" "协议：shadowsocks (tcp+udp)"
assert_contains "输出不使用 TLS" "$OUT" "不使用 TLS"
assert_contains "输出默认 method" "$OUT" "method：2022-blake3-aes-128-gcm"
PW=$(PW_OF Shadowsocks-01)
assert_eq "默认 method 的密钥是 24 字符 base64" "24 yes" "${#PW} $(sv b64:16 "$PW")"
assert_contains "自动生成的密钥只显示一次" "$OUT" "密码：$PW"
assert_eq "密钥在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c -F "$PW")"
assert_eq "实例文件权限" 600 "$(stat -c %a "$(INST Shadowsocks-01)")"
assert_eq "实例 type" shadowsocks "$(kv_get "$(INST Shadowsocks-01)" type)"
assert_eq "实例 method" 2022-blake3-aes-128-gcm "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
assert_eq "实例传输层" tcp+udp "$(kv_get "$(INST Shadowsocks-01)" transport.type)"
assert_eq "实例没有 tls 字段" 0 "$(grep -c '^tls\.' "$(INST Shadowsocks-01)")"
assert_eq "没有生成证书文件" 0 "$(ls "$A/etc/sing-box/tls" 2>/dev/null | grep -c Shadowsocks)"
assert_contains "配置含 shadowsocks inbound" "$(CFG)" '"type": "shadowsocks"'
LS=$(listen_of)
assert_contains "TCP 监听出现" "$LS" "tcp 0.0.0.0:20443"
assert_contains "UDP 监听出现" "$LS" "udp 0.0.0.0:20443"
assert_eq "TCP 表里有该套接字" 1 "$(grep -c ":$(hex4 20443) " "$A/proc/net/tcp")"
assert_eq "UDP 表里有该套接字" 1 "$(grep -c ":$(hex4 20443) " "$A/proc/net/udp")"
assert_ok "官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "密钥只存在于实例文件, 配置与受限的备份" "" "$(leaks "$PW" "$A/etc/alpine-proxy-manager/instances/Shadowsocks-01.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_not_contains "元数据不含密钥" "$(cat "$(META)")" "$PW"
out=$("$PM" sing-box list)
assert_contains "list 显示 shadowsocks 监听中" "$out" "Shadowsocks-01  shadowsocks  启用, 监听中"
assert_contains "list 显示 method" "$out" "method 2022-blake3-aes-128-gcm"
out=$("$PM" sing-box show Shadowsocks-01)
assert_contains "show method" "$out" "method：2022-blake3-aes-128-gcm"
assert_contains "show TLS 不使用" "$out" "TLS：不使用"
assert_contains "show 传输层" "$out" "传输层：tcp+udp"
assert_contains "show 内部 TCP Listener" "$out" "内部 TCP Listener：正常"
assert_contains "show 内部 UDP Listener" "$out" "内部 UDP Listener：正常"
assert_contains "show 密钥已配置" "$out" "密码：已配置"
assert_not_contains "show 没有 server-name" "$out" server-name
assert_contains "show 不宣称公网可达" "$out" "公网可达性 (NAT 与防火墙) 没有验证"
all=$("$PM" sing-box status; "$PM" sing-box info; "$PM" sing-box list; "$PM" sing-box show Shadowsocks-01; "$PM" core list; "$PM" status; "$PM" sing-box log 20 2>&1)
assert_not_contains "只读输出不含密钥" "$all" "$PW"
assert_not_contains "只读输出不含密钥片段" "$all" "$(printf '%s' "$PW" | cut -c1-8)"
assert_fail "没有违规动作" test -e "$K/violations"
# 健康检查要求 TCP 与 UDP 两个监听都在
# 其中一个 listener 缺失时 show 报告未监听 (只丢掉 udp 行)
: > "$A/proc/net/udp"
out=$("$PM" sing-box show Shadowsocks-01)
assert_contains "UDP 丢失时 show 报告 UDP 未监听" "$out" "内部 UDP Listener：未监听"
assert_contains "UDP 丢失时 TCP 仍正常" "$out" "内部 TCP Listener：正常"
assert_not_contains "UDP 丢失时 list 不再显示监听中" "$("$PM" sing-box list)" "监听中"
"$PM" sing-box restart >/dev/null 2>&1

# 各 method 与密钥
PN=21000
for m in 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
    PN=$((PN + 1))
    OUT=$("$PM" sing-box add shadowsocks --method "$m" --port "$PN" 2>&1)
    assert_eq "add $m 成功" 0 $?
    id=$(printf '%s\n' "$OUT" | sed -n 's/^已添加实例 //p')
    assert_eq "$m 生成密钥有效" yes "$(sv b64:32 "$(PW_OF "$id")")"
done
for m in aes-128-gcm aes-256-gcm chacha20-ietf-poly1305; do
    PN=$((PN + 1))
    OUT=$("$PM" sing-box add shadowsocks --method "$m" --port "$PN" 2>&1)
    assert_eq "add $m 成功" 0 $?
    id=$(printf '%s\n' "$OUT" | sed -n 's/^已添加实例 //p')
    assert_eq "$m 生成的是 32 位普通密码" yes "$(sv psk "$(PW_OF "$id")")"
done
assert_ok "全部 method 合并后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
OUT=$(printf '%s\n' "$K32" | "$PM" sing-box add shadowsocks --method 2022-blake3-aes-256-gcm --port 21200 --password-stdin 2>&1)
assert_eq "stdin 密钥匹配 method 时成功" 0 $?
assert_not_contains "stdin 密钥不回显" "$OUT" "$K32"
printf '%s\n' "$K32" | "$PM" sing-box add shadowsocks --port 21201 --password-stdin >/dev/null 2>&1
assert_eq "stdin 的 32 字节密钥配默认 16 字节 method 被拒绝" 2 $?
printf '%s\n' "$K16" | "$PM" sing-box add shadowsocks --method aes-128-gcm --port 21202 --password-stdin >/dev/null 2>&1
assert_eq "stdin 的 base64 密钥作为传统密码长度不足被拒绝" 2 $?
for a in "--port 443" "--port abc" "--listen bad" "--name bad/name" "--method none" "--method rc4-md5" "--method AES-128-GCM" "--server-name x.example.com" "--uuid 11111111-2222-4333-8444-555555555555" "--congestion-control bbr" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" sing-box add shadowsocks $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
"$PM" sing-box add shadowsocks --password somesecret >/dev/null 2>&1
assert_eq "不接受命令行明文密码" 2 $?

# ---- 与其他协议共存的端口矩阵 ----
ready m1
"$PM" sing-box add anytls --port 20000 >/dev/null 2>&1
BEFORE=$(snap)
OUT=$("$PM" sing-box add shadowsocks --port 20000 2>&1)
assert_eq "AnyTLS 占 TCP 20000, Shadowsocks 同端口被拒绝" 1 $?
assert_contains "冲突提示指出 tcp" "$OUT" "tcp 端口 20000 已被其他实例使用"
assert_eq "拒绝后没有任何改动" "$BEFORE" "$(snap)"
"$PM" sing-box add hysteria2 --port 20001 >/dev/null 2>&1
OUT=$("$PM" sing-box add shadowsocks --port 20001 2>&1)
assert_eq "Hysteria2 占 UDP 20001, Shadowsocks 同端口被拒绝" 1 $?
assert_contains "冲突提示指出 udp" "$OUT" "udp 端口 20001 已被其他实例使用"
"$PM" sing-box add tuic --port 20002 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20002 >/dev/null 2>&1
assert_eq "TUIC 占 UDP 20002, Shadowsocks 同端口被拒绝" 1 $?
"$PM" sing-box add shadowsocks --port 20003 >/dev/null 2>&1
assert_eq "Shadowsocks 用空闲端口成功" 0 $?
"$PM" sing-box add anytls --port 20003 >/dev/null 2>&1
assert_eq "Shadowsocks 占 TCP 20003, AnyTLS 同端口被拒绝" 1 $?
"$PM" sing-box add hysteria2 --port 20003 >/dev/null 2>&1
assert_eq "Shadowsocks 占 UDP 20003, Hysteria2 同端口被拒绝" 1 $?
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
assert_eq "Shadowsocks 占 UDP 20003, TUIC 同端口被拒绝" 1 $?
"$PM" sing-box add shadowsocks --port 20003 >/dev/null 2>&1
assert_eq "第二个 Shadowsocks 同端口被拒绝" 1 $?
assert_eq "四种协议实例并存" "1 1 1 1" "$(CFG | grep -c '"type": "anytls"') $(CFG | grep -c '"type": "hysteria2"') $(CFG | grep -c '"type": "tuic"') $(CFG | grep -c '"type": "shadowsocks"')"
LS=$(listen_of)
assert_contains "Shadowsocks TCP 监听" "$LS" "tcp 0.0.0.0:20003"
assert_contains "Shadowsocks UDP 监听" "$LS" "udp 0.0.0.0:20003"
assert_contains "AnyTLS TCP 监听" "$LS" "tcp 0.0.0.0:20000"
assert_contains "Hysteria2 UDP 监听" "$LS" "udp 0.0.0.0:20001"
assert_contains "TUIC UDP 监听" "$LS" "udp 0.0.0.0:20002"
ready m2
"$PM" sing-box add shadowsocks --listen 127.0.0.1 --port 20020 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --listen 10.0.0.5 --port 20020 >/dev/null 2>&1
assert_eq "不同具体地址同端口两个 Shadowsocks 可以共存" 0 $?
"$PM" sing-box add shadowsocks --port 20020 >/dev/null 2>&1
assert_eq "通配地址与已有具体地址冲突" 1 $?

# ---- 系统端口占用: tcp 或 udp 任何一个被占用都整体拒绝 ----
ready o1
foreign tcp 20100 00000000 9001
BEFORE=$(snap)
OUT=$("$PM" sing-box add shadowsocks --port 20100 2>&1)
assert_eq "TCP 被占用时 Shadowsocks 被拒绝" 1 $?
assert_contains "TCP 占用提示" "$OUT" "tcp 端口 20100 已被占用"
assert_eq "拒绝后没有任何改动" "$BEFORE" "$(snap)"
: > "$K/foreign.tcp"
rm -f "$A/proc/net/tcp"
foreign udp 20101 00000000 9002
OUT=$("$PM" sing-box add shadowsocks --port 20101 2>&1)
assert_eq "UDP 被占用时 Shadowsocks 被拒绝" 1 $?
assert_contains "UDP 占用提示" "$OUT" "udp 端口 20101 已被占用"
: > "$K/foreign.udp"
rm -f "$A/proc/net/udp"

# ---- set enable disable delete ----
ready s1
"$PM" sing-box add anytls --port 20600 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20700 >/dev/null 2>&1
PW=$(PW_OF Shadowsocks-01)
ANYCFG=$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')
"$PM" sing-box set Shadowsocks-01 port 20701 >/dev/null 2>&1
assert_eq "set port 成功" 0 $?
LS=$(listen_of)
assert_contains "新端口 TCP 监听" "$LS" "tcp 0.0.0.0:20701"
assert_contains "新端口 UDP 监听" "$LS" "udp 0.0.0.0:20701"
assert_not_contains "旧端口消失" "$LS" ":20700"
assert_eq "AnyTLS 的配置块不变" "$ANYCFG" "$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')"
assert_eq "密钥保持" "$PW" "$(PW_OF Shadowsocks-01)"
"$PM" sing-box set Shadowsocks-01 port 20600 >/dev/null 2>&1
assert_eq "set port 到 AnyTLS 的 TCP 端口被拒绝" 1 $?
"$PM" sing-box set Shadowsocks-01 listen 0.0.0.0 >/dev/null 2>&1
assert_eq "set listen 成功" 0 $?
"$PM" sing-box set Shadowsocks-01 server-name x.example.com >/dev/null 2>&1
assert_eq "shadowsocks 没有 server-name 返回 2" 2 $?
"$PM" sing-box set Shadowsocks-01 uuid --generate >/dev/null 2>&1
assert_eq "shadowsocks 没有 uuid 返回 2" 2 $?
"$PM" sing-box set Shadowsocks-01 congestion-control bbr >/dev/null 2>&1
assert_eq "shadowsocks 没有 congestion-control 返回 2" 2 $?
OUT=$("$PM" sing-box set Shadowsocks-01 password --generate 2>&1)
assert_eq "set password --generate 成功" 0 $?
NEWPW=$(PW_OF Shadowsocks-01)
assert_eq "新密钥符合当前 method" yes "$(sv b64:16 "$NEWPW")"
if [ "$NEWPW" != "$PW" ]; then t_pass "密钥已更换"; else t_fail "密钥已更换"; fi
assert_eq "新密钥只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c -F "$NEWPW")"
OUT=$(printf '%s\n' "$K16" | "$PM" sing-box set Shadowsocks-01 password --stdin 2>&1)
assert_eq "set password --stdin 成功" 0 $?
assert_not_contains "stdin 密钥不回显" "$OUT" "$K16"
printf '%s\n' "$PSKA" | "$PM" sing-box set Shadowsocks-01 password --stdin >/dev/null 2>&1
assert_eq "普通密码不能用于 2022 method" 2 $?
assert_eq "被拒绝后密钥保持" "$K16" "$(PW_OF Shadowsocks-01)"
"$PM" sing-box set Shadowsocks-01 password "$K16" >/dev/null 2>&1
assert_eq "密钥不接受命令行明文" 2 $?
# method 变更: 不兼容的密钥必须同时更换
BEFORE=$(snap)
OUT=$("$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-256-gcm 2>&1)
assert_eq "16 字节密钥换 256 位 method 没给新密钥被拒绝" 2 $?
assert_contains "提示需要同时更换密钥" "$OUT" "请在 method 之后加 --generate 或 --stdin"
assert_eq "被拒绝后没有任何改动" "$BEFORE" "$(snap)"
"$PM" sing-box set Shadowsocks-01 method aes-128-gcm >/dev/null 2>&1
assert_eq "base64 密钥含 = 不是合法的传统密码, 换到传统 method 被拒绝" 2 $?
assert_eq "被拒绝后 method 保持" 2022-blake3-aes-128-gcm "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
assert_eq "被拒绝后密钥保持" "$K16" "$(PW_OF Shadowsocks-01)"
OUT=$("$PM" sing-box set Shadowsocks-01 method 2022-blake3-chacha20-poly1305 --generate 2>&1)
assert_eq "method 与 --generate 同时更换成功" 0 $?
NEWPW=$(PW_OF Shadowsocks-01)
assert_eq "新密钥为 32 字节 base64" "44 yes" "${#NEWPW} $(sv b64:32 "$NEWPW")"
assert_contains "新密钥显示一次" "$OUT" "新密码：$NEWPW"
assert_eq "新密钥只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c -F "$NEWPW")"
OUT=$("$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-256-gcm 2>&1)
assert_eq "两个 32 字节 method 之间切换且密钥兼容时成功" 0 $?
assert_contains "兼容提示" "$OUT" "已保留"
assert_eq "兼容时密钥保持" "$NEWPW" "$(PW_OF Shadowsocks-01)"
OUT=$(printf '%s\n' "$PSKA" | "$PM" sing-box set Shadowsocks-01 method aes-256-gcm --stdin 2>&1)
assert_eq "method 与 --stdin 同时更换成功" 0 $?
assert_eq "密钥是提供的值" "$PSKA" "$(PW_OF Shadowsocks-01)"
assert_not_contains "stdin 密钥不回显" "$OUT" "$PSKA"
"$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-128-gcm >/dev/null 2>&1
assert_eq "普通密码不兼容 2022 method 被拒绝" 2 $?
printf '%s\n' "$K32" | "$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-128-gcm --stdin >/dev/null 2>&1
assert_eq "密钥长度与 method 不符被拒绝" 2 $?
"$PM" sing-box set Shadowsocks-01 method none --generate >/dev/null 2>&1
assert_eq "不允许的 method 被拒绝" 2 $?
assert_eq "拒绝后 method 保持" aes-256-gcm "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
assert_ok "method 与密钥变更后官方 check 仍通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
"$PM" sing-box disable Shadowsocks-01 >/dev/null 2>&1
assert_eq "disable 成功" 0 $?
LS=$(listen_of)
assert_not_contains "禁用后 TCP 监听消失" "$LS" ":20701"
assert_eq "禁用后配置里没有 Shadowsocks-01" 0 "$(CFG | grep -c 'Shadowsocks-01')"
assert_ok "禁用后实例仍在" test -f "$(INST Shadowsocks-01)"
assert_contains "list 显示禁用" "$("$PM" sing-box list)" "Shadowsocks-01  shadowsocks  禁用"
"$PM" sing-box enable Shadowsocks-01 >/dev/null 2>&1
LS=$(listen_of)
assert_contains "启用后 TCP 监听恢复" "$LS" "tcp 0.0.0.0:20701"
assert_contains "启用后 UDP 监听恢复" "$LS" "udp 0.0.0.0:20701"
"$PM" sing-box delete Shadowsocks-01 >/dev/null 2>&1
assert_fail "删除后实例文件已删" test -e "$(INST Shadowsocks-01)"
assert_not_contains "删除后监听消失" "$(listen_of)" ":20701"
assert_ok "删除不误删 AnyTLS 的证书" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_contains "删除后 AnyTLS 仍在监听" "$(listen_of)" "tcp 0.0.0.0:20600"

# ---- 事务回滚 ----
ready t1
"$PM" sing-box add anytls --port 20900 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20901 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
rollback_ok() {
    assert_eq "$1: 配置恢复逐字节一致" "$OLDCFG" "$(CFG)"
    assert_eq "$1: 监听与旧状态一致" "$OLDLS" "$(listen_of)"
    assert_ok "$1: 服务仍在运行" running
}
BEFORE=$(snap)
touch "$K/check_fail"
OUT=$("$PM" sing-box add shadowsocks --port 20902 2>&1)
assert_eq "check 失败时 add 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
rollback_ok "check 失败"
assert_eq "check 失败后没有任何改动" "$BEFORE" "$(snap)"
echo 20902 > "$K/fail_port-sing-box"
OUT=$("$PM" sing-box add shadowsocks --port 20902 2>&1)
assert_eq "重启失败时 add 失败" 1 $?
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
: > "$K/fail_port-sing-box"
rollback_ok "重启失败"
assert_fail "重启失败后没有新实例" test -e "$(INST Shadowsocks-02)"
touch "$K/no_listen-sing-box"
"$PM" sing-box add shadowsocks --port 20903 >/dev/null 2>&1
assert_eq "没有监听时 add 失败" 1 $?
rm -f "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rollback_ok "监听验证失败"
# 只有 TCP 起来 UDP 没有监听: 健康检查必须判失败并回滚
ready t2
"$PM" sing-box add anytls --port 21900 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
touch "$K/no_udp-sing-box"
OUT=$("$PM" sing-box add shadowsocks --port 21901 2>&1)
assert_eq "UDP 没有监听时 add 失败" 1 $?
rm -f "$K/no_udp-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rollback_ok "UDP 缺失"
assert_fail "UDP 缺失后没有新实例" test -e "$(INST Shadowsocks-01)"
ready t3
"$PM" sing-box add shadowsocks --port 22000 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
OLDM=$(kv_get "$(INST Shadowsocks-01)" credential.method)
OLDPW=$(PW_OF Shadowsocks-01)
touch "$K/check_fail"
"$PM" sing-box set Shadowsocks-01 method aes-256-gcm --generate >/dev/null 2>&1
assert_eq "check 失败时 set method 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "method 保持旧值" "$OLDM" "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
assert_eq "密钥保持旧值" "$OLDPW" "$(PW_OF Shadowsocks-01)"
rollback_ok "set method 失败"
touch "$K/check_fail"
"$PM" sing-box set Shadowsocks-01 password --generate >/dev/null 2>&1
assert_eq "check 失败时 set password 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "密钥保持旧值" "$OLDPW" "$(PW_OF Shadowsocks-01)"
echo 22001 > "$K/fail_port-sing-box"
"$PM" sing-box set Shadowsocks-01 port 22001 >/dev/null 2>&1
assert_eq "set port 无法启动时失败" 1 $?
: > "$K/fail_port-sing-box"
assert_eq "实例文件保持旧端口" 22000 "$(kv_get "$(INST Shadowsocks-01)" listen_port)"
rollback_ok "set port 失败"

# ---- purge ----
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_fail "purge 后 Shadowsocks 实例已删" test -e "$(INST Shadowsocks-01)"
assert_fail "没有违规动作" test -e "$K/violations"
t_done
