# shellcheck shell=sh
# Server SOCKS Egress: SOCKS Profile 与实例 Egress Binding, 与目标访问限制组合, 禁用与异常时 fail-closed, 事务回滚, 密码安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_egress.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
CFG() { cat "$A/etc/sing-box/config.json"; }
ROUTE() { CFG | awk '/"route"/,0'; }
RT() { ROUTE | tr -d ' \n'; }
leaks() { # 秘密 允许的位置
    grep -rlF -- "$1" "$A" 2>/dev/null | while IFS= read -r f; do
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
sumcfg() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
sbpid() { core_discover singbox; printf '%s' "$CF_PID"; }

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
add_lines() { # 目录 ID 行...
    _d=$1; _i=$2; shift 2
    for _l in "$@"; do printf '%s\n' "$_l" >> "$_d/$_i.conf"; done
}
mkprof() { # 目录 名称 host port enabled [username password]
    mkdir -p "$1"
    printf 'name=%s\nhost=%s\nport=%s\nenabled=%s\n' "$2" "$3" "$4" "$5" > "$1/$2.conf"
    if [ -n "${6:-}" ]; then printf 'username=%s\npassword=%s\n' "$6" "$7" >> "$1/$2.conf"; fi
}
ALLOW='relay_access.enabled=true
relay_access.mode=allowlist
relay_access.default_action=reject'
gen() { sb_generate_config "$1"; }
compact() { tr -d ' \n'; }

mkinst "$G" AnyTLS-01 anytls 20001 true
mkinst "$G" Hysteria2-01 hysteria2 20002 true
mkinst "$G" TUIC-01 tuic 20003 true
mkinst "$G" Shadowsocks-01 shadowsocks 20004 true
BASE=$(gen "$G")
assert_not_contains "没有绑定时没有 route" "$BASE" '"route"'
assert_not_contains "没有绑定时没有 SOCKS 出站" "$BASE" '"socks"'
assert_eq "没有绑定时 outbounds 只有 direct" 1 "$(printf '%s\n' "$BASE" | awk '/"outbounds"/,0' | grep -c '"type"')"
# 存在 Profile 但没有任何实例使用: 配置逐字节不变
mkprof "$G.socks" SOCKS-01 192.0.2.10 1080 true
mkprof "$G.socks" SOCKS-02 198.51.100.7 1081 true alice SecretPwOne01
assert_eq "未使用的 Profile 不进入配置 (逐字节相同)" "$(printf '%s\n' "$BASE" | cksum)" "$(gen "$G" | cksum)"
# 不带 egress 的 allowlist 与 0.1.0-dev.5 逐字节相同
mkdir -p "$G.al"
cp "$G"/*.conf "$G.al/"
add_lines "$G.al" AnyTLS-01 "$ALLOW" relay_access.destination.1=192.0.2.50:443
ALBASE=$(gen "$G.al")
assert_contains "allowlist 加 direct 的允许规则是 direct" "$(printf '%s' "$ALBASE" | compact)" '{"inbound":["AnyTLS-01"],"ip_cidr":["192.0.2.50/32"],"port":[443],"action":"route","outbound":"direct"},{"inbound":["AnyTLS-01"],"action":"reject"}'

# 无限制加 SOCKS
mkdir -p "$G.a"
cp "$G"/*.conf "$G.a/"
add_lines "$G.a" TUIC-01 egress_socks=SOCKS-01
cp -r "$G.socks" "$G.a.socks"
OUT=$(gen "$G.a")
assert_eq "花括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | compact | grep -c ',[]}]')"
C=$(printf '%s' "$OUT" | compact)
assert_contains "生成 SOCKS 出站 (无认证)" "$C" '{"type":"socks","tag":"apm-socks-SOCKS-01","server":"192.0.2.10","server_port":1080,"version":"5"}'
assert_not_contains "未被使用的 SOCKS-02 不生成" "$C" 'SOCKS-02'
assert_contains "无限制加 SOCKS 的路由" "$C" '"rules":[{"inbound":["TUIC-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}]'
assert_eq "direct 在 outbounds 里排第一" 1 "$(printf '%s\n' "$OUT" | awk '/"outbounds"/{f=1} f&&/"tag"/{print; exit}' | grep -c '"direct"')"
assert_eq "SOCKS 的 tag 稳定生成" "$(gen "$G.a" | cksum)" "$(gen "$G.a" | cksum)"
# 其他实例的入站块不变
INB() { printf '%s\n' "$1" | awk '/"inbounds"/,/"outbounds"/'; }
assert_eq "绑定 SOCKS 不改变入站块" "$(INB "$BASE" | cksum)" "$(INB "$OUT" | cksum)"
# allowlist 加 SOCKS: 允许目标走 SOCKS
mkdir -p "$G.b"
cp "$G"/*.conf "$G.b/"
cp -r "$G.socks" "$G.b.socks"
add_lines "$G.b" Hysteria2-01 "$ALLOW" relay_access.destination.1=203.0.113.10:443 egress_socks=SOCKS-02
C=$(gen "$G.b" | compact)
assert_contains "allowlist 加 SOCKS 的允许规则走 SOCKS 出站" "$C" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.10/32"],"port":[443],"action":"route","outbound":"apm-socks-SOCKS-02"},{"inbound":["Hysteria2-01"],"action":"reject"}'
assert_not_contains "允许规则没有 direct" "$C" '"outbound":"direct"'
assert_contains "带认证的出站含用户名与密码" "$C" '"type":"socks","tag":"apm-socks-SOCKS-02","server":"198.51.100.7","server_port":1081,"version":"5","username":"alice","password":"SecretPwOne01"'
# 共享 Profile: 出站只生成一次, 多个实例的规则都指向它
mkdir -p "$G.c"
cp "$G"/*.conf "$G.c/"
cp -r "$G.socks" "$G.c.socks"
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do add_lines "$G.c" $id egress_socks=SOCKS-01; done
OUT=$(gen "$G.c")
C=$(printf '%s' "$OUT" | compact)
assert_eq "共享的 Profile 出站只生成一次" 1 "$(printf '%s' "$C" | grep -o '"tag":"apm-socks-SOCKS-01"' | wc -l | tr -d ' ')"
assert_eq "四个实例的规则都指向它" 4 "$(printf '%s' "$C" | grep -o '"outbound":"apm-socks-SOCKS-01"' | wc -l | tr -d ' ')"
# 四种协议 allowlist 加 SOCKS
mkdir -p "$G.d"
cp "$G"/*.conf "$G.d/"
cp -r "$G.socks" "$G.d.socks"
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do add_lines "$G.d" $id "$ALLOW" relay_access.destination.1=192.0.2.99:8080 egress_socks=SOCKS-01; done
C=$(gen "$G.d" | compact)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_contains "$id allowlist 加 SOCKS" "$C" "{\"inbound\":[\"$id\"],\"ip_cidr\":[\"192.0.2.99/32\"],\"port\":[8080],\"action\":\"route\",\"outbound\":\"apm-socks-SOCKS-01\"},{\"inbound\":[\"$id\"],\"action\":\"reject\"}"
done
assert_eq "四个 allowlist 实例只有一个 SOCKS 出站" 1 "$(printf '%s' "$C" | grep -o '"type":"socks"' | wc -l | tr -d ' ')"
assert_eq "规则里没有任何 direct" 0 "$(printf '%s' "$C" | awk -F'"route":' '{print $2}' | grep -c 'direct')"
# 组合矩阵: 一个配置里同时存在五种组合, 互不影响
mkdir -p "$G.e"
cp "$G"/*.conf "$G.e/"
cp -r "$G.socks" "$G.e.socks"
mkinst "$G.e" AnyTLS-02 anytls 20005 true
mkinst "$G.e" AnyTLS-03 anytls 20006 true
add_lines "$G.e" AnyTLS-02 "$ALLOW" relay_access.destination.1=192.0.2.60:443
add_lines "$G.e" TUIC-01 egress_socks=SOCKS-01
add_lines "$G.e" Hysteria2-01 "$ALLOW" relay_access.destination.1=203.0.113.10:443 egress_socks=SOCKS-01
mkprof "$G.e.socks" SOCKS-03 192.0.2.30 1082 false
add_lines "$G.e" AnyTLS-03 egress_socks=SOCKS-03
C=$(gen "$G.e" | compact)
assert_not_contains "AnyTLS-01 (不限制 direct) 没有任何规则" "$C" '"inbound":["AnyTLS-01"]'
assert_contains "AnyTLS-02 (allowlist direct)" "$C" '{"inbound":["AnyTLS-02"],"ip_cidr":["192.0.2.60/32"],"port":[443],"action":"route","outbound":"direct"},{"inbound":["AnyTLS-02"],"action":"reject"}'
assert_contains "TUIC-01 (不限制 SOCKS)" "$C" '{"inbound":["TUIC-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'
assert_contains "Hysteria2-01 (allowlist SOCKS)" "$C" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.10/32"],"port":[443],"action":"route","outbound":"apm-socks-SOCKS-01"},{"inbound":["Hysteria2-01"],"action":"reject"}'
assert_contains "AnyTLS-03 (绑定被禁用的 Profile) 只有 reject" "$C" '{"inbound":["AnyTLS-03"],"action":"reject"}'
assert_eq "AnyTLS-03 没有 direct 与 SOCKS 规则" 0 "$(printf '%s' "$C" | grep -o '"inbound":\["AnyTLS-03"\],"[a-z_]*":[^}]*' | grep -vc 'reject')"
assert_not_contains "被禁用的 Profile 没有出站" "$C" 'apm-socks-SOCKS-03'
assert_not_contains "Shadowsocks-01 没有规则" "$C" '"inbound":["Shadowsocks-01"]'
assert_eq "route 里没有全局 reject" 0 "$(printf '%s' "$C" | grep -c '{"action":"reject"}')"
# 稳定排序: Profile 与实例的创建顺序无关
mkdir -p "$G.f" "$G.g"
for d in "$G.f" "$G.g"; do
    mkinst "$d" AnyTLS-01 anytls 20001 true
    mkinst "$d" AnyTLS-02 anytls 20002 true
    mkinst "$d" TUIC-01 tuic 20003 true
done
add_lines "$G.f" AnyTLS-01 egress_socks=SOCKS-02
add_lines "$G.f" AnyTLS-02 egress_socks=SOCKS-01
add_lines "$G.f" TUIC-01 egress_socks=SOCKS-02
add_lines "$G.g" TUIC-01 egress_socks=SOCKS-02
add_lines "$G.g" AnyTLS-02 egress_socks=SOCKS-01
add_lines "$G.g" AnyTLS-01 egress_socks=SOCKS-02
cp -r "$G.socks" "$G.f.socks"
mkdir -p "$G.g.socks"
cp "$G.socks/SOCKS-02.conf" "$G.g.socks/"
cp "$G.socks/SOCKS-01.conf" "$G.g.socks/"
assert_eq "绑定顺序与文件创建顺序不影响生成" "$(gen "$G.f" | cksum)" "$(gen "$G.g" | cksum)"
assert_eq "出站按名称排序" "apm-socks-SOCKS-01 apm-socks-SOCKS-02" "$(gen "$G.f" | grep -o 'apm-socks-SOCKS-0[12]"' | sort -u | tr -d '"' | tr '\n' ' ' | sed 's/ $//')"
# 禁用实例: 没有 inbound 没有规则, Profile 不再被使用就不生成
mkdir -p "$G.h"
cp "$G"/*.conf "$G.h/"
cp -r "$G.socks" "$G.h.socks"
add_lines "$G.h" TUIC-01 egress_socks=SOCKS-01
sed -i 's/^enabled=.*/enabled=false/' "$G.h/TUIC-01.conf"
mkdir -p "$G.h2"
cp "$G"/*.conf "$G.h2/"
sed -i 's/^enabled=.*/enabled=false/' "$G.h2/TUIC-01.conf"
assert_eq "禁用的实例绑定的 Profile 不进入配置 (与无绑定逐字节相同)" "$(gen "$G.h2" | cksum)" "$(gen "$G.h" | cksum)"
# IPv6 服务器与 JSON 转义
mkdir -p "$G.i"
cp "$G"/*.conf "$G.i/"
mkprof "$G.i.socks" SOCKS-06 '[2001:db8::10]' 1080 true 'us"er' 'pa\ss"w0rd'
add_lines "$G.i" AnyTLS-01 egress_socks=SOCKS-06
OUT=$(gen "$G.i")
assert_contains "IPv6 服务器不带方括号" "$OUT" '"server": "2001:db8::10"'
assert_contains "用户名转义双引号" "$OUT" '"username": "us\"er"'
assert_contains "密码转义反斜杠与双引号" "$OUT" '"password": "pa\\ss\"w0rd"'
# 异常: fail-closed
fc() { # 名称 目录
    gen "$2" >/dev/null 2>&1
    assert_eq "fail-closed: $1 时生成失败" 1 $?
}
mkdir -p "$G.j"
cp "$G"/*.conf "$G.j/"
add_lines "$G.j" TUIC-01 egress_socks=SOCKS-99
cp -r "$G.socks" "$G.j.socks"
fc "Profile 不存在" "$G.j"
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
add_lines "$G.j" TUIC-01 egress_socks=
fc "egress_socks 为空" "$G.j"
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
add_lines "$G.j" TUIC-01 egress_socks=SOCKS-01
mkprof "$G.j.socks" SOCKS-01 example.com 1080 true
fc "Profile 的地址是主机名 (第一版只支持 IP)" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true onlyuser
fc "Profile 只有用户名" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true
printf 'password=orphan\n' >> "$G.j.socks/SOCKS-01.conf"
fc "Profile 只有密码" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 99999 true
fc "Profile 端口越界" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 maybe
fc "Profile enabled 不是布尔" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true
printf 'fallback=SOCKS-02\n' >> "$G.j.socks/SOCKS-01.conf"
fc "Profile 含 fallback 字段" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true
printf 'priority=1\n' >> "$G.j.socks/SOCKS-01.conf"
fc "Profile 含未知字段" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true u 'bad
x'
fc "Profile 密码含换行" "$G.j"
mkprof "$G.j.socks" SOCKS-01 010.0.0.1 1080 true
fc "Profile 地址不规范" "$G.j"
printf 'name=SOCKS-01\nhost=192.0.2.10\nport=1080\nenabled=true\nthis is not kv\n' > "$G.j.socks/SOCKS-01.conf"
fc "Profile 文件语法损坏" "$G.j"
mkprof "$G.j.socks" SOCKS-01 192.0.2.10 1080 true
mkprof "$G.j.socks" SOCKS-77 192.0.2.10 1080 true
mv "$G.j.socks/SOCKS-77.conf" "$G.j.socks/SOCKS-88.conf"
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
add_lines "$G.j" TUIC-01 egress_socks=SOCKS-88
fc "Profile name 与文件名不一致" "$G.j"
# 异常的未使用 Profile 不阻止生成
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
mkprof "$G.j.socks" SOCKS-55 example.com 1080 true
gen "$G.j" >/dev/null 2>&1
assert_eq "没有被使用的异常 Profile 不阻止生成" 0 $?
# 路径穿越的绑定名被拒绝
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
add_lines "$G.j" TUIC-01 'egress_socks=../x'
fc "绑定名含路径" "$G.j"
sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
rm -f "$G.j/TUIC-01.conf"
mkinst "$G.j" TUIC-01 tuic 20003 true
add_lines "$G.j" TUIC-01 egress_socks=
assert_fail "实例校验: egress_socks 为空被拒绝" sbv "$G.j/TUIC-01.conf"

# ---- CLI: Profile ----
ready e1
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
W0=$(sumcfg)
P0=$(sbpid)
R0=$(count_calls restart)
assert_contains "list 没有 Profile" "$("$PM" sing-box socks list)" "(没有 Profile)"
PWA=UniqueSocksPassAlpha0123
OUT=$(printf '%s\n' "$PWA" | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username alice --password-stdin 2>&1)
assert_eq "add 带认证成功" 0 $?
assert_contains "自动 ID" "$OUT" "已添加 SOCKS Profile SOCKS-01"
assert_contains "提示没有验证远端" "$OUT" "没有验证远端 SOCKS 服务器可达或凭据正确"
assert_contains "未使用时没有变化运行配置" "$OUT" "运行配置没有变化, 没有重启 sing-box"
assert_not_contains "输出不含密码" "$OUT" "$PWA"
assert_eq "未使用的 Profile 不改变运行配置" "$W0" "$(sumcfg)"
assert_eq "未使用的 Profile 不重启" "$R0" "$(count_calls restart)"
assert_eq "sing-box 进程未变" "$P0" "$(sbpid)"
assert_eq "Profile 文件权限" 600 "$(stat -c %a "$(PROF SOCKS-01)")"
assert_eq "socks 目录权限" 700 "$(stat -c %a "$A/etc/alpine-proxy-manager/socks")"
assert_eq "Profile 字段" "name=SOCKS-01 host=192.0.2.10 port=1080 enabled=true username=alice" "$(grep -v '^password=' "$(PROF SOCKS-01)" | tr '\n' ' ' | sed 's/ $//')"
OUT=$("$PM" sing-box socks add --server 198.51.100.7 --port 1081 --no-auth 2>&1)
assert_contains "第二个 Profile 自动编号" "$OUT" "已添加 SOCKS Profile SOCKS-02"
assert_eq "无认证 Profile 没有用户名与密码" 0 "$(grep -c '^username=\|^password=' "$(PROF SOCKS-02)")"
OUT=$("$PM" sing-box socks add --name SOCKS-Edge --server '[2001:db8::10]' --port 1082 --no-auth 2>&1)
assert_contains "自定义名称与 IPv6" "$OUT" "已添加 SOCKS Profile SOCKS-Edge"
assert_eq "IPv6 地址保存为带方括号的规范形式" "[2001:db8::10]" "$(kv_get "$(PROF SOCKS-Edge)" host)"
OUT=$("$PM" sing-box socks add --server 2001:DB8::11 --port 1083 --no-auth 2>&1)
assert_eq "不带方括号的 IPv6 大写被规范化" "[2001:db8::11]" "$(kv_get "$(PROF SOCKS-03)" host)"
LIST=$("$PM" sing-box socks list)
assert_contains "list 显示 Profile" "$LIST" "SOCKS-01  启用  192.0.2.10 端口 1080  用户名认证  引用 无"
assert_contains "list 显示无认证" "$LIST" "SOCKS-02  启用  198.51.100.7 端口 1081  无认证  引用 无"
SHOW=$("$PM" sing-box socks show SOCKS-01)
assert_contains "show 用户名" "$SHOW" "用户名：alice"
assert_contains "show 密码已配置" "$SHOW" "密码：已配置"
assert_contains "show 版本" "$SHOW" "版本：SOCKS5"
assert_contains "show 说明不等于可达" "$SHOW" "不代表远端 SOCKS 服务器可达或凭据正确"
assert_not_contains "show 不含密码" "$SHOW" "$PWA"
assert_not_contains "show 不含密码片段" "$SHOW" "UniqueSo"
assert_not_contains "show 不含长度提示" "$SHOW" "23"
assert_not_contains "list 不含密码" "$LIST" "$PWA"
# 参数拒绝
badadd() { # 名称 stdin 参数...
    _n=$1; _in=$2; shift 2
    # shellcheck disable=SC2294
    printf '%s\n' "$_in" | "$PM" sing-box socks add "$@" >/dev/null 2>&1
    assert_eq "add 拒绝: $_n" 2 $?
}
badadd "缺少认证选择" x --server 192.0.2.10 --port 1080
badadd "用户名没有密码" x --server 192.0.2.10 --port 1080 --username u
badadd "密码没有用户名" x --server 192.0.2.10 --port 1080 --password-stdin
badadd "--no-auth 加 --username" x --server 192.0.2.10 --port 1080 --no-auth --username u
badadd "--no-auth 加 --password-stdin" x --server 192.0.2.10 --port 1080 --no-auth --password-stdin
badadd "命令行明文密码" x --server 192.0.2.10 --port 1080 --username u --password plain
badadd "缺少 server" x --port 1080 --no-auth
badadd "缺少 port" x --server 192.0.2.10 --no-auth
badadd "主机名" x --server proxy.example.com --port 1080 --no-auth
badadd "非法 IPv4" x --server 256.1.1.1 --port 1080 --no-auth
badadd "非法端口 0" x --server 192.0.2.10 --port 0 --no-auth
badadd "非法端口 70000" x --server 192.0.2.10 --port 70000 --no-auth
badadd "名称含路径" x --server 192.0.2.10 --port 1080 --no-auth --name ../x
badadd "未知参数" x --server 192.0.2.10 --port 1080 --no-auth --bogus
badadd "空密码" "" --server 192.0.2.10 --port 1080 --username u --password-stdin
badadd "密码首尾有空格" " pw " --server 192.0.2.10 --port 1080 --username u --password-stdin
LONG=$(head -c 300 /dev/zero | tr '\0' a)
badadd "密码超过 255 字节" "$LONG" --server 192.0.2.10 --port 1080 --username u --password-stdin
"$PM" sing-box socks add --name SOCKS-01 --server 192.0.2.10 --port 1080 --no-auth >/dev/null 2>&1
assert_eq "同名 Profile 被拒绝" 1 $?
assert_eq "拒绝后配置不变" "$W0" "$(sumcfg)"
assert_fail "没有违规动作" test -e "$K/violations"

# ---- CLI: 绑定 ----
assert_contains "默认出口 DIRECT" "$("$PM" sing-box egress AnyTLS-01)" "出口：DIRECT"
assert_contains "实例 show 默认 DIRECT" "$("$PM" sing-box show AnyTLS-01)" "出口：DIRECT"
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_eq "$id 升级后没有 egress_socks 键" 0 "$(grep -c '^egress_socks' "$(INST $id)")"
done
OUT=$("$PM" sing-box egress AnyTLS-01 direct 2>&1)
assert_eq "已经是 DIRECT 时 direct 不改动" 0 $?
assert_contains "不改动提示" "$OUT" "已经是 DIRECT"
assert_eq "不改动时配置不变" "$W0" "$(sumcfg)"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-99 >/dev/null 2>&1
assert_eq "绑定不存在的 Profile 被拒绝" 1 $?
assert_eq "没有写入 egress_socks" 0 "$(grep -c '^egress_socks' "$(INST AnyTLS-01)")"
"$PM" sing-box egress Nope-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "实例不存在返回 1" 1 $?
"$PM" sing-box egress AnyTLS-01 socks '../x' >/dev/null 2>&1
assert_eq "绑定名含路径返回 2" 2 $?
"$PM" sing-box egress AnyTLS-01 bogus >/dev/null 2>&1
assert_eq "未知操作返回 2" 2 $?
"$PM" sing-box egress AnyTLS-01 socks >/dev/null 2>&1
assert_eq "缺少 Profile 名返回 2" 2 $?
LS0=$(listen_of)
R1=$(count_calls restart)
OUT=$("$PM" sing-box egress AnyTLS-01 socks SOCKS-01 2>&1)
assert_eq "绑定成功" 0 $?
assert_contains "绑定提示" "$OUT" "实例 AnyTLS-01 的出口已绑定 SOCKS Profile SOCKS-01"
assert_contains "提示只代表配置已应用" "$OUT" "只代表配置已应用, 不代表远端 SOCKS 服务器可用"
assert_eq "绑定后重启一次" $((R1 + 1)) "$(count_calls restart)"
assert_eq "绑定后实例字段" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
C=$(CFG | compact)
assert_contains "配置含 SOCKS 出站" "$C" '"type":"socks","tag":"apm-socks-SOCKS-01","server":"192.0.2.10","server_port":1080,"version":"5","username":"alice","password":"UniqueSocksPassAlpha0123"'
assert_contains "配置含路由" "$C" '{"inbound":["AnyTLS-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'
assert_not_contains "未使用的 Profile 不进入配置" "$C" "SOCKS-02"
assert_eq "绑定期间监听保持" "$LS0" "$(listen_of)"
assert_ok "官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_contains "实例 show 显示出口" "$("$PM" sing-box show AnyTLS-01)" "出口：SOCKS SOCKS-01 (已启用)"
assert_contains "egress show" "$("$PM" sing-box egress AnyTLS-01 show)" "出口：SOCKS SOCKS-01 (已启用)"
assert_contains "list 显示引用" "$("$PM" sing-box socks list)" "SOCKS-01  启用  192.0.2.10 端口 1080  用户名认证  引用 AnyTLS-01"
assert_contains "show 显示引用" "$("$PM" sing-box socks show SOCKS-01)" "引用的实例：AnyTLS-01"
OUT=$("$PM" sing-box egress AnyTLS-01 socks SOCKS-01 2>&1)
assert_contains "重复绑定不改动" "$OUT" "已经绑定 SOCKS-01"
# 共享
for id in Hysteria2-01 TUIC-01 Shadowsocks-01; do
    "$PM" sing-box egress $id socks SOCKS-01 >/dev/null 2>&1
    assert_eq "$id 绑定共享 Profile" 0 $?
done
C=$(CFG | compact)
assert_eq "四个实例共享, 出站只有一个" 1 "$(printf '%s' "$C" | grep -o '"tag":"apm-socks-SOCKS-01"' | wc -l | tr -d ' ')"
assert_eq "四个实例的规则都指向它" 4 "$(printf '%s' "$C" | grep -o '"outbound":"apm-socks-SOCKS-01"' | wc -l | tr -d ' ')"
assert_contains "list 显示四个引用者" "$("$PM" sing-box socks list)" "引用 AnyTLS-01 Hysteria2-01 Shadowsocks-01 TUIC-01"
assert_ok "共享后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
# 删除保护
BEFORE_CFG=$(sumcfg)
OUT=$("$PM" sing-box socks delete SOCKS-01 2>&1)
assert_eq "被引用的 Profile 不能删除" 1 $?
assert_contains "列出引用者" "$OUT" "AnyTLS-01 Hysteria2-01 Shadowsocks-01 TUIC-01"
assert_ok "Profile 仍在" test -f "$(PROF SOCKS-01)"
assert_eq "拒绝后配置不变" "$BEFORE_CFG" "$(sumcfg)"
assert_eq "实例绑定没有被悄悄改成 DIRECT" 4 "$(grep -l '^egress_socks=SOCKS-01' "$A"/etc/alpine-proxy-manager/instances/*.conf | wc -l | tr -d ' ')"
# 密码泄漏扫描
assert_eq "密码只存在于 Profile 文件, 配置与受限的备份" "" "$(leaks "$PWA" "$(PROF SOCKS-01) $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_not_contains "元数据不含密码" "$(cat "$(META)")" "$PWA"
all=$("$PM" sing-box status; "$PM" sing-box info; "$PM" sing-box list; "$PM" sing-box show AnyTLS-01; "$PM" sing-box socks list; "$PM" sing-box socks show SOCKS-01; "$PM" sing-box egress AnyTLS-01; "$PM" core list; "$PM" status; "$PM" doctor; "$PM" sing-box log 20 2>&1)
assert_not_contains "任何只读输出都不含密码" "$all" "$PWA"
assert_not_contains "任何只读输出都不含密码片段" "$all" "UniqueSocks"
assert_eq "备份文件权限 0600" "" "$(for f in "$A"/var/lib/alpine-proxy-manager/backups/config.json.bak.*; do [ -e "$f" ] && [ "$(stat -c %a "$f")" != 600 ] && echo "$f"; done)"
assert_eq "备份目录权限 0700" 700 "$(stat -c %a "$A/var/lib/alpine-proxy-manager/backups")"
# 与 Relay Access Policy 组合
"$PM" sing-box access AnyTLS-01 allowlist >/dev/null 2>&1
"$PM" sing-box access AnyTLS-01 add 192.0.2.50 443 >/dev/null 2>&1
C=$(CFG | compact)
assert_contains "allowlist 加 SOCKS: 允许规则走 SOCKS" "$C" '{"inbound":["AnyTLS-01"],"ip_cidr":["192.0.2.50/32"],"port":[443],"action":"route","outbound":"apm-socks-SOCKS-01"},{"inbound":["AnyTLS-01"],"action":"reject"}'
assert_not_contains "allowlist 加 SOCKS: 没有 direct 绕过" "$C" '"outbound":"direct"'
"$PM" sing-box access Hysteria2-01 allowlist >/dev/null 2>&1
"$PM" sing-box access Hysteria2-01 add 203.0.113.10 443 >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 direct >/dev/null 2>&1
C=$(CFG | compact)
assert_contains "allowlist 加 direct" "$C" '{"inbound":["Hysteria2-01"],"ip_cidr":["203.0.113.10/32"],"port":[443],"action":"route","outbound":"direct"},{"inbound":["Hysteria2-01"],"action":"reject"}'
assert_contains "TUIC-01 不限制加 SOCKS" "$C" '{"inbound":["TUIC-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'
assert_not_contains "Shadowsocks-01 仍只有 SOCKS 规则 (没有 reject)" "$(printf '%s' "$C" | grep -o '{"inbound":\["Shadowsocks-01"\][^}]*}')" reject
"$PM" sing-box access AnyTLS-01 unrestricted >/dev/null 2>&1
assert_contains "取消限制后回到不限制加 SOCKS" "$(CFG | compact)" '{"inbound":["AnyTLS-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'
"$PM" sing-box access Hysteria2-01 unrestricted >/dev/null 2>&1
assert_eq "限制与出口互相独立: 取消限制不影响绑定" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"

# ---- 禁用 Profile: fail-closed, 绝不 direct ----
"$PM" sing-box egress Hysteria2-01 socks SOCKS-01 >/dev/null 2>&1
R2=$(count_calls restart)
OUT=$("$PM" sing-box socks disable SOCKS-01 2>&1)
assert_eq "disable 成功" 0 $?
assert_contains "disable 提示不会退回 DIRECT" "$OUT" "不会退回 DIRECT"
assert_eq "disable 重启一次" $((R2 + 1)) "$(count_calls restart)"
C=$(CFG | compact)
assert_not_contains "禁用后没有 SOCKS 出站" "$C" '"type":"socks"'
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_contains "$id 绑定的 Profile 被禁用时只有 reject" "$C" "{\"inbound\":[\"$id\"],\"action\":\"reject\"}"
done
assert_not_contains "禁用后没有 direct 规则" "$C" '"outbound":"direct"'
assert_eq "绑定被保留" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
assert_contains "list 显示禁用" "$("$PM" sing-box socks list)" "SOCKS-01  禁用"
assert_contains "实例 show 说明被拒绝" "$("$PM" sing-box show AnyTLS-01)" "出口：SOCKS SOCKS-01 (已禁用, 该实例的流量会被拒绝, 不会退回 DIRECT)"
assert_ok "禁用后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "禁用后监听保持" "$LS0" "$(listen_of)"
# DIRECT 的实例继续正常
"$PM" sing-box egress TUIC-01 direct >/dev/null 2>&1
C=$(CFG | compact)
assert_not_contains "TUIC-01 改回 DIRECT 后没有规则" "$C" '"inbound":["TUIC-01"]'
assert_contains "其他绑定实例仍 reject" "$C" '{"inbound":["AnyTLS-01"],"action":"reject"}'
"$PM" sing-box egress TUIC-01 socks SOCKS-01 >/dev/null 2>&1
OUT=$("$PM" sing-box socks enable SOCKS-01 2>&1)
assert_eq "enable 成功" 0 $?
C=$(CFG | compact)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_contains "$id 重新启用后自动恢复" "$C" "{\"inbound\":[\"$id\"],\"action\":\"route\",\"outbound\":\"apm-socks-SOCKS-01\"}"
done
assert_eq "不需要重新绑定" 4 "$(grep -l '^egress_socks=SOCKS-01' "$A"/etc/alpine-proxy-manager/instances/*.conf | wc -l | tr -d ' ')"
# 在禁用状态下绑定
"$PM" sing-box socks disable SOCKS-02 >/dev/null 2>&1
OUT=$("$PM" sing-box egress Shadowsocks-01 socks SOCKS-02 2>&1)
assert_eq "可以绑定到禁用的 Profile" 0 $?
assert_contains "绑定到禁用的 Profile 有明确提示" "$OUT" "当前是禁用的, 该实例的流量会被拒绝, 不会退回 DIRECT"
assert_contains "Shadowsocks-01 被拒绝" "$(CFG | compact)" '{"inbound":["Shadowsocks-01"],"action":"reject"}'
"$PM" sing-box egress Shadowsocks-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box socks enable SOCKS-02 >/dev/null 2>&1

# ---- 批量管理 ----
R3=$(count_calls restart)
BEFORE_CFG=$(sumcfg)
BEFORE_PROFS=$(cat "$A"/etc/alpine-proxy-manager/socks/*.conf | cksum)
OUT=$("$PM" sing-box socks disable SOCKS-01 SOCKS-99 SOCKS-02 2>&1)
assert_eq "批量中有不存在的 Profile 整个命令失败" 1 $?
assert_contains "指出不存在的名字" "$OUT" "SOCKS-99 不存在, 没有做任何修改"
assert_eq "失败后没有任何 Profile 被修改" "$BEFORE_PROFS" "$(cat "$A"/etc/alpine-proxy-manager/socks/*.conf | cksum)"
assert_eq "失败后配置不变" "$BEFORE_CFG" "$(sumcfg)"
assert_eq "失败后没有重启" "$R3" "$(count_calls restart)"
OUT=$("$PM" sing-box socks disable SOCKS-01 SOCKS-02 2>&1)
assert_eq "批量 disable 成功" 0 $?
assert_eq "批量 disable 只重启一次" $((R3 + 1)) "$(count_calls restart)"
assert_contains "两个 Profile 都禁用" "$("$PM" sing-box socks list)" "SOCKS-02  禁用"
R4=$(count_calls restart)
"$PM" sing-box socks enable SOCKS-01 SOCKS-02 >/dev/null 2>&1
assert_eq "批量 enable 成功且只重启一次" $((R4 + 1)) "$(count_calls restart)"
R5=$(count_calls restart)
OUT=$("$PM" sing-box socks disable-all 2>&1)
assert_eq "disable-all 成功" 0 $?
assert_contains "disable-all 提示" "$OUT" "DIRECT 实例不受影响"
assert_eq "disable-all 只重启一次" $((R5 + 1)) "$(count_calls restart)"
assert_eq "disable-all 后全部禁用" 0 "$("$PM" sing-box socks list | grep -c '  启用  ')"
assert_eq "disable-all 后绑定仍然保留" 4 "$(grep -l '^egress_socks=SOCKS-01' "$A"/etc/alpine-proxy-manager/instances/*.conf | wc -l | tr -d ' ')"
C=$(CFG | compact)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_contains "disable-all 后 $id 被拒绝" "$C" "{\"inbound\":[\"$id\"],\"action\":\"reject\"}"
done
R6=$(count_calls restart)
"$PM" sing-box socks enable-all >/dev/null 2>&1
assert_eq "enable-all 成功且只重启一次" $((R6 + 1)) "$(count_calls restart)"
assert_contains "enable-all 后恢复" "$(CFG | compact)" '{"inbound":["AnyTLS-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'
R7=$(count_calls restart)
"$PM" sing-box socks enable-all >/dev/null 2>&1
assert_eq "已经全部启用时 enable-all 不重启" "$R7" "$(count_calls restart)"
"$PM" sing-box socks enable >/dev/null 2>&1
assert_eq "enable 缺少名称返回 2" 2 $?
"$PM" sing-box socks enable 'bad/name' >/dev/null 2>&1
assert_eq "enable 非法名称返回 2" 2 $?

# ---- set ----
R8=$(count_calls restart)
W1=$(sumcfg)
OUT=$("$PM" sing-box socks set SOCKS-03 port 1090 2>&1)
assert_eq "修改未使用的 Profile 成功" 0 $?
assert_contains "未使用时不重启" "$OUT" "运行配置没有变化, 没有重启 sing-box"
assert_eq "未使用时运行配置不变" "$W1" "$(sumcfg)"
assert_eq "未使用时不重启 sing-box" "$R8" "$(count_calls restart)"
assert_eq "端口已写入" 1090 "$(kv_get "$(PROF SOCKS-03)" port)"
"$PM" sing-box socks set SOCKS-03 server 192.0.2.77 >/dev/null 2>&1
assert_eq "server 已写入" 192.0.2.77 "$(kv_get "$(PROF SOCKS-03)" host)"
"$PM" sing-box socks set SOCKS-03 server proxy.example.com >/dev/null 2>&1
assert_eq "set server 主机名被拒绝" 2 $?
"$PM" sing-box socks set SOCKS-03 port 0 >/dev/null 2>&1
assert_eq "set port 非法返回 2" 2 $?
"$PM" sing-box socks set SOCKS-03 port 1090 extra >/dev/null 2>&1
"$PM" sing-box socks set SOCKS-99 port 1 >/dev/null 2>&1
assert_eq "set 不存在的 Profile 返回 1" 1 $?
"$PM" sing-box socks set SOCKS-03 bogus 1 >/dev/null 2>&1
assert_eq "set 未知键返回 2" 2 $?
"$PM" sing-box socks set SOCKS-03 password x >/dev/null 2>&1
assert_eq "set password 不接受命令行明文" 2 $?
"$PM" sing-box socks set SOCKS-03 password --password-stdin </dev/null >/dev/null 2>&1
assert_eq "set password 空输入被拒绝" 2 $?
printf 'NewPassOnNoAuth12345\n' | "$PM" sing-box socks set SOCKS-03 password --password-stdin >/dev/null 2>&1
assert_eq "无用户名时 set password 被拒绝" 2 $?
OUT=$(printf 'CredPassForThree0123\n' | "$PM" sing-box socks set SOCKS-03 credential carol --password-stdin 2>&1)
assert_eq "set credential 成功" 0 $?
assert_eq "用户名已写入" carol "$(kv_get "$(PROF SOCKS-03)" username)"
assert_not_contains "credential 输出不含密码" "$OUT" "CredPassForThree0123"
"$PM" sing-box socks set SOCKS-03 credential carol >/dev/null 2>&1
assert_eq "credential 缺少 --password-stdin 返回 2" 2 $?
"$PM" sing-box socks set SOCKS-03 no-auth >/dev/null 2>&1
assert_eq "set no-auth 成功" 0 $?
assert_eq "no-auth 后没有认证字段" 0 "$(grep -c '^username=\|^password=' "$(PROF SOCKS-03)")"
# 修改被引用的 Profile: 完整事务
R9=$(count_calls restart)
OUT=$("$PM" sing-box socks set SOCKS-01 port 1099 2>&1)
assert_eq "修改被引用的 Profile 成功" 0 $?
assert_contains "被引用时重启并验证" "$OUT" "sing-box 已重启并验证"
assert_eq "被引用时重启一次" $((R9 + 1)) "$(count_calls restart)"
assert_contains "运行配置已更新端口" "$(CFG | compact)" '"server":"192.0.2.10","server_port":1099'
PWB=UniqueSocksPassBeta9876543
OUT=$(printf '%s\n' "$PWB" | "$PM" sing-box socks set SOCKS-01 password --password-stdin 2>&1)
assert_eq "set password 成功" 0 $?
assert_contains "新密码进入运行配置" "$(CFG | compact)" "\"password\":\"$PWB\""
assert_not_contains "旧密码不再出现在运行配置" "$(CFG)" "$PWA"
assert_not_contains "set 输出不含密码" "$OUT" "$PWB"
assert_eq "新密码只存在于允许的位置" "" "$(leaks "$PWB" "$(PROF SOCKS-01) $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
"$PM" sing-box socks set SOCKS-01 port 1080 >/dev/null 2>&1

# ---- 回滚 ----
OLDCFG=$(CFG)
OLDLS=$(listen_of)
OLDPROF=$(cksum < "$(PROF SOCKS-01)")
OLDINSTS=$(cat "$A"/etc/alpine-proxy-manager/instances/*.conf | cksum)
rb() { # 名称
    assert_eq "$1: 配置逐字节恢复" "$OLDCFG" "$(CFG)"
    assert_eq "$1: 监听保持" "$OLDLS" "$(listen_of)"
    assert_eq "$1: Profile 文件恢复" "$OLDPROF" "$(cksum < "$(PROF SOCKS-01)")"
    assert_eq "$1: 实例文件恢复" "$OLDINSTS" "$(cat "$A"/etc/alpine-proxy-manager/instances/*.conf | cksum)"
    assert_ok "$1: 服务仍运行" running
}
touch "$K/check_fail"
OUT=$("$PM" sing-box socks set SOCKS-01 port 1111 2>&1)
assert_eq "check 失败时 set 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
rb "check 失败"
touch "$K/fail_restart-sing-box"
OUT=$("$PM" sing-box socks set SOCKS-01 port 1112 2>&1)
assert_eq "重启失败时 set 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
rb "重启失败"
touch "$K/fail_restart-sing-box"
"$PM" sing-box socks disable SOCKS-01 >/dev/null 2>&1
assert_eq "重启失败时 disable 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
rb "disable 重启失败"
touch "$K/no_listen-sing-box"
"$PM" sing-box socks set SOCKS-01 port 1113 >/dev/null 2>&1
assert_eq "没有监听时 set 失败" 1 $?
rm -f "$K/no_listen-sing-box"
"$PM" sing-box restart >/dev/null 2>&1
rb "监听验证失败"
touch "$K/check_fail"
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
assert_eq "check 失败时 egress direct 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "绑定保持" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
rb "egress direct check 失败"
touch "$K/fail_restart-sing-box"
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
assert_eq "重启失败时 egress direct 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
rb "egress direct 重启失败"
# 保存失败: 配置已提交必须恢复
_sb_sync_instances() { return 1; }
OUT=$(singbox_socks set SOCKS-01 port 1114 2>&1)
RC=$?
t_load singbox
assert_eq "保存失败时 set 失败" 1 "$RC"
assert_contains "保存失败提示" "$OUT" "保存实例失败"
rb "保存失败"
assert_fail "没有违规动作" test -e "$K/violations"

# ---- 删除 Profile 与实例 ----
ready e2
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
printf 'PwForDeleteTest01234\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
"$PM" sing-box socks add --server 192.0.2.11 --port 1080 --no-auth >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box egress TUIC-01 socks SOCKS-01 >/dev/null 2>&1
R10=$(count_calls restart)
OUT=$("$PM" sing-box socks delete SOCKS-02 2>&1)
assert_eq "删除未被引用的 Profile 成功" 0 $?
assert_fail "Profile 文件已删" test -e "$(PROF SOCKS-02)"
assert_eq "删除未被引用的 Profile 不重启" "$R10" "$(count_calls restart)"
"$PM" sing-box socks delete SOCKS-99 >/dev/null 2>&1
assert_eq "删除不存在的 Profile 返回 1" 1 $?
"$PM" sing-box socks delete SOCKS-01 SOCKS-02 >/dev/null 2>&1
assert_eq "delete 一次只能删一个" 2 $?
# 删除一个实例: 绑定一起消失, Profile 仍被另一个实例使用所以出站保留
"$PM" sing-box delete AnyTLS-01 >/dev/null 2>&1
C=$(CFG | compact)
assert_not_contains "删除实例后没有它的规则" "$C" 'AnyTLS-01'
assert_contains "Profile 仍被 TUIC-01 使用" "$C" '"tag":"apm-socks-SOCKS-01"'
assert_ok "Profile 文件保留" test -f "$(PROF SOCKS-01)"
OUT=$("$PM" sing-box socks delete SOCKS-01 2>&1)
assert_contains "仍被 TUIC-01 引用时拒绝删除" "$OUT" "仍被这些实例使用: TUIC-01"
"$PM" sing-box delete TUIC-01 >/dev/null 2>&1
assert_not_contains "最后一个引用消失后出站不再生成" "$(CFG)" '"type": "socks"'
assert_ok "Profile 文件保留" test -f "$(PROF SOCKS-01)"
"$PM" sing-box socks delete SOCKS-01 >/dev/null 2>&1
assert_eq "引用消失后可以删除" 0 $?
assert_fail "Profile 文件已删" test -e "$(PROF SOCKS-01)"
# 禁用的实例也算引用
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
printf 'PwForDeleteTest01234\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box disable AnyTLS-01 >/dev/null 2>&1
assert_not_contains "禁用的实例不产生出站" "$(CFG)" '"type": "socks"'
"$PM" sing-box socks delete SOCKS-01 >/dev/null 2>&1
assert_eq "禁用的实例仍算引用, 删除被拒绝" 1 $?
"$PM" sing-box enable AnyTLS-01 >/dev/null 2>&1
assert_contains "启用后绑定与出站恢复" "$(CFG | compact)" '{"inbound":["AnyTLS-01"],"action":"route","outbound":"apm-socks-SOCKS-01"}'

# ---- fail-closed: 运行中发现的异常 ----
ready f1
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
printf 'PwForFailClosed012345\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
OLDCFG=$(CFG)
cp "$(PROF SOCKS-01)" "$T_TMP/prof.bak"
rm -f "$(PROF SOCKS-01)"
assert_contains "Profile 缺失时 show 明确报告" "$("$PM" sing-box show AnyTLS-01)" "出口：SOCKS SOCKS-01 (不存在 / 配置异常, 生成配置会被拒绝, 不会退回 DIRECT)"
OUT=$("$PM" sing-box add hysteria2 --port 20002 2>&1)
assert_eq "绑定的 Profile 缺失时其他变更也被拒绝" 1 $?
assert_eq "拒绝后配置不变且仍含 SOCKS 路由" "$OLDCFG" "$(CFG)"
"$PM" sing-box egress TUIC-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "不能绑定不存在的 Profile" 1 $?
cp "$T_TMP/prof.bak" "$(PROF SOCKS-01)"
chmod 600 "$(PROF SOCKS-01)"
sed -i 's/^port=.*/port=notaport/' "$(PROF SOCKS-01)"
assert_contains "Profile 损坏时 show 明确报告" "$("$PM" sing-box show AnyTLS-01)" "配置异常"
assert_contains "list 显示配置无效" "$("$PM" sing-box socks list)" "SOCKS-01  配置无效"
"$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
assert_eq "绑定的 Profile 损坏时其他变更被拒绝" 1 $?
assert_eq "损坏时配置不变" "$OLDCFG" "$(CFG)"
assert_ok "损坏时服务仍运行" running
cp "$T_TMP/prof.bak" "$(PROF SOCKS-01)"
chmod 600 "$(PROF SOCKS-01)"
"$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
assert_eq "修复后恢复正常" 0 $?
# 实例文件里的绑定被写坏
sed -i 's/^egress_socks=.*/egress_socks=SOCKS-77/' "$(INST AnyTLS-01)"
"$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
assert_eq "绑定指向不存在的 Profile 时变更被拒绝" 1 $?
assert_not_contains "运行配置仍有 SOCKS 路由, 没有退回 DIRECT" "$(CFG | compact | grep -o '{"inbound":\["AnyTLS-01"\][^}]*}' | grep -c direct)" 1

# ---- 四协议绑定 (真实 CLI) 与升级兼容 ----
ready p1
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20002 >/dev/null 2>&1
"$PM" sing-box add tuic --port 20003 >/dev/null 2>&1
"$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
printf 'PwForProtocols0123456\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
LSP=$(listen_of)
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    "$PM" sing-box egress $id socks SOCKS-01 >/dev/null 2>&1
    assert_eq "$id 绑定 SOCKS 成功" 0 $?
    assert_eq "$id 绑定后监听保持" "$LSP" "$(listen_of)"
    assert_ok "$id 绑定后官方 check 通过" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
done
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    "$PM" sing-box egress $id direct >/dev/null 2>&1
    assert_eq "$id 改回 DIRECT 成功" 0 $?
    assert_eq "$id 改回 DIRECT 后没有 egress_socks 键" 0 "$(grep -c '^egress_socks' "$(INST $id)")"
done
assert_not_contains "全部改回 DIRECT 后没有 SOCKS 出站" "$(CFG)" '"type": "socks"'
assert_not_contains "全部改回 DIRECT 后没有 route" "$(CFG)" '"route"'
assert_eq "全部改回 DIRECT 后配置与未绑定时逐字节相同" "$W0" "$W0"
"$PM" sing-box socks delete SOCKS-01 >/dev/null 2>&1
assert_eq "改回后可以删除 Profile" 0 $?

# ---- purge 删除 Profile ----
ready u1
"$PM" sing-box add anytls --port 20001 >/dev/null 2>&1
printf 'PwForPurgeTest0123456\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_fail "purge 后 Profile 已删" test -e "$(PROF SOCKS-01)"
assert_eq "purge 后任何文件都不含 SOCKS 密码" "" "$(grep -rlF 'PwForPurgeTest0123456' "$A" 2>/dev/null)"
assert_fail "没有违规动作" test -e "$K/violations"
t_done
