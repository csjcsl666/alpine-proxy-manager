# shellcheck shell=sh
# Hysteria2 Protocol Instance (UDP/QUIC) 与 AnyTLS (TCP) 共存: 协议感知的端口模型, UDP 监听, 事务回滚, 密码安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_hysteria2.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
CFG() { cat "$A/etc/sing-box/config.json"; }
PW_OF() { kv_get "$(INST "$1")" credential.password; }
leaks() { # 密码 允许的位置
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
# foreign PROTO PORT [地址十六进制] [INODE]: 模拟别的进程的监听, 同时写入旋钮文件 (重建时保留) 与当前的 /proc/net 表
foreign() {
    local _st _row
    _st=0A
    [ "$1" = udp ] && _st=07
    _row=$(printf '   9: %s:%s 00000000:0000 %s 00000000:00000000 00:00000000 00000000     0        0 %s 1 0' "${3:-00000000}" "$(hex4 "$2")" "$_st" "${4:-9999}")
    printf '%s\n' "$_row" >> "$K/foreign.$1"
    [ -f "$A/proc/net/$1" ] || printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "$A/proc/net/$1"
    printf '%s\n' "$_row" >> "$A/proc/net/$1"
}

# ---- 纯函数: 模型, 生成, 地址与监听 ----
G=$T_TMP/gen
mkdir -p "$G"
mkinst() { # 目录 ID 类型 端口 启用 密码 监听
    printf 'id=%s\nname=%s\ntype=%s\nenabled=%s\nlisten=%s\nlisten_port=%s\ncredential.password=%s\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\n' "$2" "$2" "$3" "$5" "${7:-::}" "$4" "$6" "$2" "$2" > "$1/$2.conf"
}
mkinst "$G" AnyTLS-01 anytls 20001 true AnyTlsPasswordNumberOne0123456789
mkinst "$G" Hysteria2-01 hysteria2 20001 true Hy2PasswordNumberOne0123456789abcd
mkinst "$G" Hysteria2-02 hysteria2 20002 false Hy2PasswordNumberTwo0123456789abcd
OUT=$(sb_generate_config "$G")
assert_eq "同时包含 AnyTLS 与 Hysteria2" "1 1" "$(printf '%s\n' "$OUT" | grep -c '"type": "anytls"') $(printf '%s\n' "$OUT" | grep -c '"type": "hysteria2"')"
assert_contains "Hysteria2 inbound 的 tag" "$OUT" '"tag": "Hysteria2-01"'
assert_not_contains "禁用的 Hysteria2 不生成" "$OUT" 'Hysteria2-02'
assert_contains "Hysteria2 密码" "$OUT" '"password": "Hy2PasswordNumberOne0123456789abcd"'
assert_contains "Hysteria2 TLS 路径" "$OUT" '"certificate_path": "/etc/sing-box/tls/Hysteria2-01.crt"'
assert_eq "两个 inbound 的端口数字相同" 2 "$(printf '%s\n' "$OUT" | grep -c '"listen_port": 20001')"
assert_eq "生成结果稳定 (重复生成逐字节相同)" "$(sb_generate_config "$G" | cksum)" "$(sb_generate_config "$G" | cksum)"
assert_eq "花括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c ',[]}]')"
# AnyTLS 的 inbound 块与只有 AnyTLS 时逐字节相同, 说明新增协议不改变已有实例的输出
mkdir -p "$G.only"
cp "$G/AnyTLS-01.conf" "$G.only/"
assert_eq "新增协议不改变 AnyTLS 的生成块" 0 "$(sb_generate_config "$G.only" | awk '/"type": "anytls"/,/"key_path"/' | while IFS= read -r l; do printf '%s\n' "$OUT" | grep -qF -- "$l" || echo miss; done | grep -c miss)"
assert_eq "期望监听带协议" "tcp:20001 udp:20001" "$(_sb_expected_ports "$G")"
assert_eq "类型到传输层" "tcp udp" "$(_sb_type_proto anytls) $(_sb_type_proto hysteria2)"
assert_eq "类型到前缀" "AnyTLS Hysteria2" "$(_sb_type_prefix anytls) $(_sb_type_prefix hysteria2)"
assert_eq "下一个 Hysteria2 编号" Hysteria2-03 "$(_sb_next_id "$G" Hysteria2)"
sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
assert_ok "有效 Hysteria2 实例通过校验" sbv "$G/Hysteria2-01.conf"
bad() { # 名称 sed 表达式
    cp "$G/Hysteria2-01.conf" "$G/Bad-01.conf"
    sed -i 's/^id=.*/id=Bad-01/; s/^name=.*/name=Bad-01/' "$G/Bad-01.conf"
    sed -i "$2" "$G/Bad-01.conf"
    assert_fail "无效 Hysteria2 实例被拒绝: $1" sbv "$G/Bad-01.conf"
}
bad "密码太短" 's/^credential.password=.*/credential.password=short/'
bad "密码为空" 's/^credential.password=.*/credential.password=/'
bad "密码含非法字符" 's/^credential.password=.*/credential.password=bad password with spaces!!/'
bad "端口低于 1025" 's/^listen_port=.*/listen_port=443/'
bad "端口越界" 's/^listen_port=.*/listen_port=70000/'
bad "server_name 无效" 's/^tls.server_name=.*/tls.server_name=bad name/'
bad "证书路径是相对路径" 's#^tls.certificate_path=.*#tls.certificate_path=cert.pem#'
bad "私钥路径含引号" 's#^tls.key_path=.*#tls.key_path=/etc/a"b#'
bad "缺少密码" '/^credential.password=/d'
bad "缺少证书" '/^tls.certificate_path=/d'
bad "缺少私钥" '/^tls.key_path=/d'
bad "listen 无效" 's/^listen=.*/listen=not an addr/'
bad "类型未支持 (tuic)" 's/^type=hysteria2/type=tuic/'
rm -f "$G/Bad-01.conf"
# 地址重叠与协议感知的实例冲突
ov() { _sb_addr_overlap "$1" "$2" && echo yes || echo no; }
assert_eq "相同地址重叠" yes "$(ov 10.0.0.1 10.0.0.1)"
assert_eq "不同的具体地址不重叠" no "$(ov 10.0.0.1 10.0.0.2)"
assert_eq "通配 :: 与具体地址重叠" yes "$(ov '::' 10.0.0.2)"
assert_eq "通配 0.0.0.0 与具体地址重叠" yes "$(ov 10.0.0.1 0.0.0.0)"
assert_eq "IPv4 与 IPv6 的具体地址不重叠" no "$(ov 10.0.0.1 fd00::1)"
tk() { _sb_port_taken_by_instance "$G" "$@" && echo yes || echo no; }
assert_eq "同数字不同协议不冲突 (udp 20001 与 tcp 的 AnyTLS-01 不同协议, 但 udp 已被 Hysteria2-01 占用)" yes "$(tk udp 20001 ::)"
assert_eq "tcp 20002 没有任何 tcp 实例使用" no "$(tk tcp 20002 ::)"
assert_eq "udp 20002 被禁用的 Hysteria2-02 占用" yes "$(tk udp 20002 ::)"
assert_eq "排除自身后不冲突" no "$(tk udp 20002 :: Hysteria2-02)"
mkinst "$G" Hysteria2-09 hysteria2 20009 true Hy2PasswordNumberNine012345678901 127.0.0.1
assert_eq "不同具体地址同端口不冲突" no "$(tk udp 20009 10.0.0.5)"
assert_eq "通配地址与具体地址同端口冲突" yes "$(tk udp 20009 ::)"
rm -f "$G/Hysteria2-09.conf"
# 监听判断按协议与端口精确匹配
CF_LISTEN="tcp 0.0.0.0:20443 60000
tcp [::]:2044 60001"
assert_eq "tcp 监听不会被当作 udp" no "$(_sb_listening udp 20443 && echo yes || echo no)"
assert_eq "tcp 监听匹配 tcp" yes "$(_sb_listening tcp 20443 && echo yes || echo no)"
assert_eq "端口按后缀精确匹配 (2044 不等于 20443)" no "$(_sb_listening tcp 204 && echo yes || echo no)"
CF_LISTEN="udp [::]:20443 60002"
assert_eq "udp 监听匹配 udp" yes "$(_sb_listening udp 20443 && echo yes || echo no)"
assert_eq "udp 监听不会被当作 tcp" no "$(_sb_listening tcp 20443 && echo yes || echo no)"
# /proc/net/udp6 的解码
A6=$T_TMP/net6
mk_sysroot "$A6" alpine
mk_net "$A6" udp6 "   0: 00000000000000000000000000000000:4FDB 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000   100        0 777 2 0
   1: 00000000000000000000000001000000:4FDC 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000   100        0 778 2 0
   2: 00000000000000000000000000000000:4FDD 00000000000000000000000000000000:0000 01 00000000:00000000 00:00000000 00000000   100        0 779 2 0"
mk_net "$A6" udp "   0: 0100007F:4FDE 00000000:0000 07 00000000:00000000 00:00000000 00000000   100        0 780 2 0"
OLDSR=${APM_SYSROOT:-}
APM_SYSROOT=$A6
assert_eq "udp6 通配地址按 inode 过滤" "udp [::]:20443 777" "$(_core_proc_listeners " 777 " "")"
assert_eq "udp6 回环地址" "udp [::1]:20444 778" "$(_core_proc_listeners " 778 " "")"
assert_eq "已连接的 udp 套接字 (状态 01) 不算监听" "" "$(_core_proc_listeners " 779 " "")"
assert_eq "udp 回环 IPv4" "udp 127.0.0.1:20446 780" "$(_core_proc_listeners " 780 " "")"
assert_eq "按端口过滤 udp6" "udp [::]:20443 777" "$(_core_proc_listeners "" " 20443 ")"
assert_eq "系统冲突: udp 20443 在 :: 上被占用" yes "$(_sb_port_busy udp 20443 :: && echo yes || echo no)"
assert_eq "系统冲突: tcp 20443 没有被占用" no "$(_sb_port_busy tcp 20443 :: && echo yes || echo no)"
assert_eq "系统冲突: 回环 udp 与具体地址 10.0.0.1 不冲突" no "$(_sb_port_busy udp 20446 10.0.0.1 && echo yes || echo no)"
assert_eq "系统冲突: 回环 udp 与通配冲突" yes "$(_sb_port_busy udp 20446 0.0.0.0 && echo yes || echo no)"
APM_SYSROOT=$OLDSR
export APM_SYSROOT

# ---- add ----
ready h1
OUT=$("$PM" sing-box add hysteria2 --port 20443 2>&1)
RC=$?
assert_eq "add hysteria2 成功" 0 "$RC"
assert_contains "输出实例名" "$OUT" "已添加实例 Hysteria2-01"
assert_contains "输出协议与传输层" "$OUT" "协议：hysteria2 (udp)"
PW=$(PW_OF Hysteria2-01)
assert_eq "密码长度" 32 "${#PW}"
assert_contains "自动生成的密码只显示一次" "$OUT" "密码：$PW"
assert_eq "密码在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$PW")"
assert_eq "实例文件权限" 600 "$(stat -c %a "$(INST Hysteria2-01)")"
assert_eq "实例 type 是规范化的 hysteria2" hysteria2 "$(kv_get "$(INST Hysteria2-01)" type)"
assert_eq "实例传输层是 udp" udp "$(kv_get "$(INST Hysteria2-01)" transport.type)"
assert_eq "实例 tls.mode" self-signed "$(kv_get "$(INST Hysteria2-01)" tls.mode)"
assert_ok "证书存在" test -f "$A/etc/sing-box/tls/Hysteria2-01.crt"
assert_eq "私钥权限" 640 "$(stat -c %a "$A/etc/sing-box/tls/Hysteria2-01.key")"
assert_contains "配置含 hysteria2 inbound" "$(CFG)" '"type": "hysteria2"'
assert_contains "配置含密码" "$(CFG)" "$PW"
LS=$(listen_of)
assert_contains "UDP 监听出现" "$LS" "udp 0.0.0.0:20443"
assert_not_contains "没有 tcp 监听 (Hysteria2 只用 udp)" "$LS" "tcp"
assert_eq "UDP 表里有该套接字" 1 "$(grep -c ":$(hex4 20443) " "$A/proc/net/udp")"
assert_eq "TCP 表里没有该端口" 0 "$(grep -c ":$(hex4 20443) " "$A/proc/net/tcp")"
assert_ok "官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "密码只存在于实例文件, 配置与受限的备份" "" "$(leaks "$PW" "$A/etc/alpine-proxy-manager/instances/Hysteria2-01.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_not_contains "元数据不含密码" "$(cat "$(META)")" "$PW"
out=$("$PM" sing-box list)
assert_contains "list 显示 hysteria2 监听中" "$out" "Hysteria2-01  hysteria2  启用, 监听中"
out=$("$PM" sing-box show Hysteria2-01)
assert_contains "show 内部 UDP Listener" "$out" "内部 UDP Listener：正常"
assert_contains "show 密码已配置" "$out" "密码：已配置"
assert_contains "show 不宣称公网可用" "$out" "公网可达性 (NAT 与防火墙) 没有验证"
assert_not_contains "show 不含公网可用字样" "$out" "公网可用"
all=$("$PM" sing-box status; "$PM" sing-box info; "$PM" sing-box list; "$PM" sing-box show Hysteria2-01; "$PM" core list; "$PM" status; "$PM" sing-box log 20 2>&1)
assert_not_contains "任何只读输出都不含密码" "$all" "$PW"
assert_not_contains "任何只读输出都不含密码片段" "$all" "$(printf '%s' "$PW" | cut -c1-8)"
assert_fail "没有违规动作" test -e "$K/violations"

# 自定义选项与 --password-stdin
OUT=$(printf 'ProvidedHy2PasswordForTests0123456789\n' | "$PM" sing-box add hysteria2 --name Hy2-Edge --listen 127.0.0.1 --server-name www.example.com --port 20444 --password-stdin 2>&1)
assert_contains "自定义名称" "$OUT" "已添加实例 Hy2-Edge"
assert_eq "使用提供的密码" ProvidedHy2PasswordForTests0123456789 "$(PW_OF Hy2-Edge)"
assert_not_contains "提供的密码不回显" "$OUT" "ProvidedHy2Password"
assert_eq "自定义 server-name" www.example.com "$(kv_get "$(INST Hy2-Edge)" tls.server_name)"
OUT=$("$PM" sing-box add hysteria2 --port 20445 2>&1)
assert_contains "自动编号递增" "$OUT" "已添加实例 Hysteria2-02"
# 参数与拒绝
for a in "--port 443" "--port abc" "--listen bad" "--server-name bad_name" "--name bad/name" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" sing-box add hysteria2 $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
printf 'short\n' | "$PM" sing-box add hysteria2 --password-stdin >/dev/null 2>&1
assert_eq "无效密码返回 2" 2 $?
"$PM" sing-box add hysteria2 --password somesecret >/dev/null 2>&1
assert_eq "不接受命令行明文密码" 2 $?
"$PM" sing-box add hy2 >/dev/null 2>&1
assert_eq "不接受 hy2 这类别名" 2 $?
BEFORE=$(snap)
OUT=$("$PM" sing-box add hysteria2 --port 20443 2>&1)
assert_eq "UDP 端口与已有 Hysteria2 重复被拒绝" 1 $?
assert_contains "UDP 重复提示" "$OUT" "udp 端口 20443 已被其他实例使用"
"$PM" sing-box add hysteria2 --listen 127.0.0.1 --port 20443 >/dev/null 2>&1
assert_eq "具体地址与通配地址重叠被拒绝" 1 $?
assert_eq "拒绝后没有任何改动" "$BEFORE" "$(snap)"

# ---- TCP 与 UDP 同数字端口共存 ----
ready m1
"$PM" sing-box add anytls --port 20000 >/dev/null 2>&1
OUT=$("$PM" sing-box add hysteria2 --port 20000 2>&1)
assert_eq "AnyTLS 的 TCP 20000 与 Hysteria2 的 UDP 20000 可以共存" 0 $?
LS=$(listen_of)
assert_contains "TCP 20000 在监听" "$LS" "tcp 0.0.0.0:20000"
assert_contains "UDP 20000 在监听" "$LS" "udp 0.0.0.0:20000"
assert_eq "配置里两种 inbound 并存" "1 1" "$(CFG | grep -c '"type": "anytls"') $(CFG | grep -c '"type": "hysteria2"')"
assert_eq "两个 inbound 的端口相同" 2 "$(CFG | grep -c '"listen_port": 20000')"
assert_eq "AnyTLS 不受影响" 1 "$(CFG | grep -c '"tag": "AnyTLS-01"')"
"$PM" sing-box add anytls --port 20000 >/dev/null 2>&1
assert_eq "同数字的第二个 AnyTLS (tcp) 被拒绝" 1 $?
"$PM" sing-box add hysteria2 --port 20000 >/dev/null 2>&1
assert_eq "同数字的第二个 Hysteria2 (udp) 被拒绝" 1 $?
# 反向顺序
ready m2
"$PM" sing-box add hysteria2 --port 20010 >/dev/null 2>&1
OUT=$("$PM" sing-box add anytls --port 20010 2>&1)
assert_eq "先 Hysteria2 后 AnyTLS 同数字端口也可以" 0 $?
# 不同具体地址的同端口同协议实例
ready m3
"$PM" sing-box add hysteria2 --listen 127.0.0.1 --port 20020 >/dev/null 2>&1
OUT=$("$PM" sing-box add hysteria2 --listen 10.0.0.5 --port 20020 2>&1)
assert_eq "不同具体地址同端口同协议可以共存" 0 $?
"$PM" sing-box add hysteria2 --port 20020 >/dev/null 2>&1
assert_eq "通配地址与已有具体地址冲突" 1 $?

# ---- 系统端口占用按协议判断 ----
ready o1
foreign tcp 20100 00000000 9001
BEFORE=$(snap)
OUT=$("$PM" sing-box add hysteria2 --port 20100 2>&1)
assert_eq "只有 TCP 占用同数字端口时 Hysteria2 可以添加" 0 $?
"$PM" sing-box delete Hysteria2-01 >/dev/null 2>&1
OUT=$("$PM" sing-box add anytls --port 20100 2>&1)
assert_eq "TCP 占用的端口 AnyTLS 被拒绝" 1 $?
assert_contains "TCP 占用提示" "$OUT" "tcp 端口 20100 已被占用"
: > "$K/foreign.tcp"
rm -f "$A/proc/net/tcp"
foreign udp 20101 00000000 9002
OUT=$("$PM" sing-box add hysteria2 --port 20101 2>&1)
assert_eq "UDP 占用的端口 Hysteria2 被拒绝" 1 $?
assert_contains "UDP 占用提示" "$OUT" "udp 端口 20101 已被占用"
OUT=$("$PM" sing-box add anytls --port 20101 2>&1)
assert_eq "只有 UDP 占用同数字端口时 AnyTLS 可以添加" 0 $?
: > "$K/foreign.udp"
rm -f "$A/proc/net/udp"
foreign udp 20102 0100007F 9003
"$PM" sing-box add hysteria2 --listen 10.0.0.9 --port 20102 >/dev/null 2>&1
assert_eq "回环上的 UDP 占用不阻止其他具体地址" 0 $?
"$PM" sing-box add hysteria2 --listen 0.0.0.0 --port 20102 >/dev/null 2>&1
assert_eq "回环上的 UDP 占用阻止通配地址" 1 $?
: > "$K/foreign.udp"

# ---- set enable disable delete ----
ready s1
"$PM" sing-box add anytls --port 20600 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20700 >/dev/null 2>&1
PW=$(PW_OF Hysteria2-01)
ANYCFG=$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')
OUT=$("$PM" sing-box set Hysteria2-01 port 20701 2>&1)
assert_eq "set port 成功" 0 $?
LS=$(listen_of)
assert_contains "UDP 新端口监听" "$LS" "udp 0.0.0.0:20701"
assert_not_contains "UDP 旧端口消失" "$LS" ":20700"
assert_contains "AnyTLS 的 TCP 监听保持" "$LS" "tcp 0.0.0.0:20600"
assert_eq "AnyTLS 的配置块不变" "$ANYCFG" "$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')"
assert_eq "密码保持" "$PW" "$(PW_OF Hysteria2-01)"
OUT=$("$PM" sing-box set Hysteria2-01 listen 0.0.0.0 2>&1)
assert_eq "set listen 成功" 0 $?
OLDCRT=$(cat "$A/etc/sing-box/tls/Hysteria2-01.crt")
ANYCRT=$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")
OUT=$("$PM" sing-box set Hysteria2-01 server-name www.example.org 2>&1)
assert_eq "set server-name 成功" 0 $?
assert_contains "证书按新名字重新生成" "$(cat "$A/etc/sing-box/tls/Hysteria2-01.crt")" "FAKECERTFOR_www.example.org"
assert_eq "AnyTLS 的证书没有被改动" "$ANYCRT" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")"
OUT=$("$PM" sing-box set Hysteria2-01 password --generate 2>&1)
assert_eq "set password --generate 成功" 0 $?
NEWPW=$(PW_OF Hysteria2-01)
if [ "$NEWPW" != "$PW" ]; then t_pass "密码已更换"; else t_fail "密码已更换"; fi
assert_contains "新密码显示一次" "$OUT" "新密码：$NEWPW"
assert_eq "新密码只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$NEWPW")"
OUT=$(printf 'StdinHy2PasswordForTest0123456789\n' | "$PM" sing-box set Hysteria2-01 password --stdin 2>&1)
assert_eq "set password --stdin 成功" 0 $?
assert_not_contains "stdin 密码不回显" "$OUT" "StdinHy2Password"
"$PM" sing-box set Hysteria2-01 password PlainTextOnCommandLine0123456 >/dev/null 2>&1
assert_eq "密码不接受命令行明文" 2 $?
"$PM" sing-box set Hysteria2-01 port 80 >/dev/null 2>&1
assert_eq "set port 低于 1025 返回 2" 2 $?
"$PM" sing-box set Hysteria2-01 port 20600 >/dev/null 2>&1
assert_eq "set port 到 AnyTLS 的 TCP 同数字端口是允许的" 0 $?
LS=$(listen_of)
assert_contains "UDP 20600 监听" "$LS" "udp 0.0.0.0:20600"
assert_contains "TCP 20600 仍监听" "$LS" "tcp 0.0.0.0:20600"
"$PM" sing-box add hysteria2 --port 20800 >/dev/null 2>&1
"$PM" sing-box set Hysteria2-01 port 20800 >/dev/null 2>&1
assert_eq "set port 到其他 Hysteria2 的 UDP 端口被拒绝" 1 $?
OUT=$("$PM" sing-box disable Hysteria2-01 2>&1)
assert_eq "disable 成功" 0 $?
LS=$(listen_of)
assert_not_contains "禁用后 UDP 监听消失" "$LS" "udp 0.0.0.0:20600"
assert_contains "禁用后 AnyTLS 仍在监听" "$LS" "tcp 0.0.0.0:20600"
assert_eq "禁用后配置里没有 Hysteria2-01" 0 "$(CFG | grep -c 'Hysteria2-01')"
assert_ok "禁用后实例文件仍在" test -f "$(INST Hysteria2-01)"
assert_ok "禁用后证书仍在" test -f "$A/etc/sing-box/tls/Hysteria2-01.crt"
assert_eq "禁用后 AnyTLS 的配置块不变" "$ANYCFG" "$(CFG | awk '/"tag": "AnyTLS-01"/,/"key_path"/')"
out=$("$PM" sing-box list)
assert_contains "list 显示禁用" "$out" "Hysteria2-01  hysteria2  禁用"
OUT=$("$PM" sing-box enable Hysteria2-01 2>&1)
assert_eq "enable 成功" 0 $?
LS=$(listen_of)
assert_contains "启用后 UDP 监听恢复" "$LS" "udp 0.0.0.0:20600"
OUT=$("$PM" sing-box delete Hysteria2-01 2>&1)
assert_eq "delete 成功" 0 $?
assert_fail "删除后实例文件已删" test -e "$(INST Hysteria2-01)"
assert_fail "删除后证书已删" test -e "$A/etc/sing-box/tls/Hysteria2-01.crt"
assert_ok "删除不误删 AnyTLS 的证书" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_ok "删除不误删 AnyTLS 的私钥" test -f "$A/etc/sing-box/tls/AnyTLS-01.key"
LS=$(listen_of)
assert_not_contains "删除后 UDP 监听消失" "$LS" "udp 0.0.0.0:20600"
assert_contains "删除后 AnyTLS 仍在监听" "$LS" "tcp 0.0.0.0:20600"
OUT=$("$PM" sing-box add hysteria2 --name Hysteria2-01 --port 20600 2>&1)
assert_eq "删除后用同名重新创建" 0 $?
assert_eq "密码在所有只读输出之外只存在于允许的位置" "" "$(leaks "$(PW_OF Hysteria2-01)" "$A/etc/alpine-proxy-manager/instances/*.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"

# ---- 事务回滚 ----
ready t1
"$PM" sing-box add anytls --port 20900 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20901 >/dev/null 2>&1
OLDCFG=$(CFG)
OLDLS=$(listen_of)
rollback_ok() { # 名称
    assert_eq "$1: 配置恢复逐字节一致" "$OLDCFG" "$(CFG)"
    assert_eq "$1: 监听与旧状态一致" "$OLDLS" "$(listen_of)"
    assert_ok "$1: 服务仍在运行" running
}
BEFORE=$(snap)
touch "$K/check_fail"
OUT=$("$PM" sing-box add hysteria2 --port 20902 2>&1)
assert_eq "check 失败时 add 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
rollback_ok "check 失败"
assert_eq "check 失败后没有任何改动" "$BEFORE" "$(snap)"
echo 20902 > "$K/fail_port-sing-box"
OUT=$("$PM" sing-box add hysteria2 --port 20902 2>&1)
assert_eq "重启失败时 add 失败" 1 $?
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
: > "$K/fail_port-sing-box"
rollback_ok "重启失败"
assert_fail "重启失败后没有新实例" test -e "$(INST Hysteria2-02)"
assert_fail "重启失败后新证书已清理" test -e "$A/etc/sing-box/tls/Hysteria2-02.crt"
BEFORE=$(snap)
touch "$K/no_listen-sing-box"
OUT=$("$PM" sing-box add hysteria2 --port 20903 2>&1)
assert_eq "UDP 没有监听时 add 失败 (健康检查依据 UDP 监听)" 1 $?
rm -f "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rollback_ok "监听验证失败"
assert_fail "监听验证失败后没有新实例" test -e "$(INST Hysteria2-02)"
touch "$K/gen_fail"
BEFORE=$(snap)
"$PM" sing-box add hysteria2 --port 20904 >/dev/null 2>&1
assert_eq "证书生成失败时 add 失败" 1 $?
rm -f "$K/gen_fail"
assert_eq "证书生成失败没有任何改动" "$BEFORE" "$(snap)"
# 保存实例失败: 配置已经提交, 必须恢复
_sb_sync_instances() { return 1; }
BEFORE=$(snap)
OUT=$(singbox_add hysteria2 --port 20905 2>&1)
RC=$?
t_load singbox
assert_eq "保存实例失败时 add 失败" 1 "$RC"
assert_contains "保存实例失败提示" "$OUT" "保存实例失败"
assert_eq "保存实例失败后配置恢复" "$OLDCFG" "$(CFG)"
assert_fail "保存实例失败后没有实例文件" test -e "$(INST Hysteria2-02)"
assert_fail "保存实例失败后新证书已清理" test -e "$A/etc/sing-box/tls/Hysteria2-02.crt"
assert_ok "保存实例失败后服务仍运行" running
# 候选配置无法创建
txn_new_candidate() { return 1; }
OUT=$(singbox_add hysteria2 --port 20906 2>&1)
RC=$?
t_load txn
assert_eq "无法创建候选配置时 add 失败" 1 "$RC"
assert_contains "候选配置失败提示" "$OUT" "无法创建候选配置"
assert_eq "无法创建候选配置后配置不变" "$OLDCFG" "$(CFG)"
assert_fail "无法创建候选配置后没有新证书" test -e "$A/etc/sing-box/tls/Hysteria2-02.crt"
# set port 失败
OLDPORT=$(kv_get "$(INST Hysteria2-01)" listen_port)
echo 20907 > "$K/fail_port-sing-box"
"$PM" sing-box set Hysteria2-01 port 20907 >/dev/null 2>&1
assert_eq "set port 无法启动时失败" 1 $?
: > "$K/fail_port-sing-box"
assert_eq "实例文件保持旧端口" "$OLDPORT" "$(kv_get "$(INST Hysteria2-01)" listen_port)"
rollback_ok "set port 失败"
# set server-name 失败: 旧证书放回
OLDCRT=$(cat "$A/etc/sing-box/tls/Hysteria2-01.crt")
touch "$K/check_fail"
"$PM" sing-box set Hysteria2-01 server-name other.example.com >/dev/null 2>&1
assert_eq "check 失败时 set server-name 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "旧证书被放回" "$OLDCRT" "$(cat "$A/etc/sing-box/tls/Hysteria2-01.crt")"
assert_eq "server-name 保持旧值" apm.local "$(kv_get "$(INST Hysteria2-01)" tls.server_name)"
# set password 失败
OLDPW=$(PW_OF Hysteria2-01)
touch "$K/check_fail"
"$PM" sing-box set Hysteria2-01 password --generate >/dev/null 2>&1
assert_eq "check 失败时 set password 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "密码保持旧值" "$OLDPW" "$(PW_OF Hysteria2-01)"
rollback_ok "set password 失败"
# disable 失败
touch "$K/fail_restart-sing-box"
"$PM" sing-box disable Hysteria2-01 >/dev/null 2>&1
assert_eq "重启失败时 disable 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
assert_eq "disable 失败后实例仍启用" true "$(kv_get "$(INST Hysteria2-01)" enabled)"
rollback_ok "disable 失败"
# delete 失败: 实例保留
touch "$K/fail_restart-sing-box"
"$PM" sing-box delete Hysteria2-01 >/dev/null 2>&1
assert_eq "重启失败时 delete 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
assert_ok "delete 失败后实例仍在" test -f "$(INST Hysteria2-01)"
assert_ok "delete 失败后证书仍在" test -f "$A/etc/sing-box/tls/Hysteria2-01.crt"
rollback_ok "delete 失败"
assert_ok "全程 AnyTLS 的 TCP 监听保持" test -n "$(listen_of | grep 'tcp 0.0.0.0:20900')"

# ---- UDP 监听归属: 别的进程的 UDP socket 不算 Hysteria2 ----
ready u1
"$PM" sing-box add hysteria2 --port 21200 >/dev/null 2>&1
core_discover singbox
assert_ok "自己的 UDP socket 被认出" _sb_listening udp 21200
touch "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
foreign udp 21200 00000000 9100
APM_SB_WAIT=0
export APM_SB_WAIT
assert_fail "别的进程占着同端口 UDP socket 时健康检查不通过" _sb_wait_healthy
foreign tcp 21200 00000000 9101
assert_fail "别的进程的 TCP socket 也不能算 UDP" _sb_wait_healthy
rm -f "$K/no_listen-sing-box" "$K/foreign.udp" "$K/foreign.tcp"
APM_SB_WAIT=1
export APM_SB_WAIT
"$PM" sing-box restart >/dev/null 2>&1
assert_ok "恢复后健康检查通过" _sb_wait_healthy

# ---- 卸载, purge 与保留实例 ----
ready z1
"$PM" sing-box add anytls --port 21300 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 21300 >/dev/null 2>&1
HPW=$(PW_OF Hysteria2-01)
"$PM" sing-box uninstall >/dev/null 2>&1
assert_ok "普通卸载保留 Hysteria2 实例" test -f "$(INST Hysteria2-01)"
assert_ok "普通卸载保留 Hysteria2 证书" test -f "$A/etc/sing-box/tls/Hysteria2-01.crt"
OUT=$("$PM" sing-box install 2>&1)
assert_eq "重新安装沿用两个实例" 0 $?
LS=$(listen_of)
assert_contains "重新安装后 TCP 与 UDP 都监听" "$LS" "tcp 0.0.0.0:21300"
assert_contains "重新安装后 UDP 监听" "$LS" "udp 0.0.0.0:21300"
assert_not_contains "重新安装不显示密码" "$OUT" "$HPW"
"$PM" sing-box uninstall >/dev/null 2>&1
foreign udp 21300 00000000 9200
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "已保留的 Hysteria2 的 UDP 端口被占用时 install 拒绝" 1 $?
assert_contains "UDP 占用提示" "$OUT" "udp 端口 21300 已被占用"
assert_eq "UDP 占用时没有改动" "$BEFORE" "$(snap)"
rm -f "$K/foreign.udp" "$A/proc/net/udp"
foreign tcp 21300 00000000 9201
OUT=$("$PM" sing-box install 2>&1)
assert_eq "TCP 占用同数字端口时 AnyTLS 实例的端口冲突拒绝安装" 1 $?
assert_contains "TCP 占用提示" "$OUT" "tcp 端口 21300 已被占用"
rm -f "$K/foreign.tcp" "$A/proc/net/tcp"
OUT=$("$PM" sing-box install 2>&1)
assert_eq "端口空闲后安装成功" 0 $?
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_fail "purge 删除 Hysteria2 实例" test -e "$(INST Hysteria2-01)"
assert_fail "purge 删除 AnyTLS 实例" test -e "$(INST AnyTLS-01)"
assert_fail "purge 删除全部证书" test -e "$A/etc/sing-box"
assert_eq "purge 后没有任何文件含 Hysteria2 密码" "" "$(grep -rl "$HPW" "$A" 2>/dev/null)"

# ---- 外部部署与归属保护 ----
new_s x1
mkdir -p "$A/etc/sing-box"
mk_elf_exec "$A/usr/local/bin/sing-box" "$T_TMP/real-side.sh"
printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/sing-box"\ncommand_args="run -c /etc/sing-box/config.json"\nsupervisor=supervise-daemon\n' > "$A/etc/init.d/sing-box"
printf '{}\n' > "$A/etc/sing-box/config.json"
BEFORE=$(snap)
for c in "add hysteria2" "enable Hysteria2-01" "disable Hysteria2-01" "delete Hysteria2-01" "set Hysteria2-01 port 21000"; do
    # shellcheck disable=SC2086
    "$PM" sing-box $c >/dev/null 2>&1
    assert_eq "External: $c 拒绝返回 4" 4 $?
done
assert_eq "External: 没有改动" "$BEFORE" "$(snap)"

# ---- 与 Snell 共存 ----
new_s c3
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" sing-box install >/dev/null 2>&1
core_discover snell
SPID=$CF_PID
SCONF=$(cksum < "$A/etc/snell/snell-server.conf")
: > "$K/calls"
"$PM" sing-box add hysteria2 --port 21400 >/dev/null 2>&1
"$PM" sing-box set Hysteria2-01 port 21401 >/dev/null 2>&1
"$PM" sing-box disable Hysteria2-01 >/dev/null 2>&1
core_discover snell
assert_eq "Hysteria2 变更不影响 Snell: PID" "$SPID" "$CF_PID"
assert_eq "Hysteria2 变更不影响 Snell: 配置" "$SCONF" "$(cksum < "$A/etc/snell/snell-server.conf")"
assert_eq "Hysteria2 变更没有触碰 Snell 服务" "" "$(grep '^snell ' "$K/calls" | grep -v ' status$')"
assert_fail "没有违规动作" test -e "$K/violations"
t_done
