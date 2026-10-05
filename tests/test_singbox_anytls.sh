# shellcheck shell=sh
# Protocol Instance 框架与 AnyTLS 实例: add list show set enable disable delete, 配置生成, 事务回滚, 密码安全
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_singbox_anytls.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
CFG() { cat "$A/etc/sing-box/config.json"; }
PW_OF() { kv_get "$(INST "$1")" credential.password; }
# 除允许的位置外, 文件系统里是否还有含该密码的文件
leaks() { # 密码 允许的文件(空格分隔, 精确路径或前缀*)
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

# ---- 配置生成与实例校验 (纯函数) ----
G=$T_TMP/gen
mkdir -p "$G"
assert_eq "没有实例的配置" 0 "$(sb_generate_config "$G" | grep -c '"type": "anytls"')"
mkinst() { # 目录 ID 端口 启用 密码
    printf 'id=%s\nname=%s\ntype=anytls\nenabled=%s\nlisten=::\nlisten_port=%s\ncredential.password=%s\ntls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=/etc/sing-box/tls/%s.crt\ntls.key_path=/etc/sing-box/tls/%s.key\n' "$2" "$2" "$4" "$3" "$5" "$2" "$2" > "$1/$2.conf"
}
mkinst "$G" AnyTLS-01 20001 true PasswordNumberOne0123456789abc
mkinst "$G" AnyTLS-02 20002 false PasswordNumberTwo0123456789abc
mkinst "$G" AnyTLS-03 20003 true PasswordNumberThree01234567abc
OUT=$(sb_generate_config "$G")
assert_eq "只生成启用的实例" 2 "$(printf '%s\n' "$OUT" | grep -c '"type": "anytls"')"
assert_contains "含 AnyTLS-01" "$OUT" '"tag": "AnyTLS-01"'
assert_not_contains "不含禁用的 AnyTLS-02" "$OUT" 'AnyTLS-02'
assert_contains "含 AnyTLS-03" "$OUT" '"tag": "AnyTLS-03"'
assert_contains "监听端口是数字" "$OUT" '"listen_port": 20001,'
assert_contains "证书路径" "$OUT" '"certificate_path": "/etc/sing-box/tls/AnyTLS-01.crt"'
assert_contains "用户密码" "$OUT" '"password": "PasswordNumberOne0123456789abc"'
assert_contains "保留 direct 出站" "$OUT" '"tag": "direct"'
# JSON 结构: 括号与逗号配平 (无 jq, 用 awk 数括号)
assert_eq "花括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")d++; if(c=="}")d--}} END{print d}')"
assert_eq "方括号配平" 0 "$(printf '%s' "$OUT" | awk 'BEGIN{d=0} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="[")d++; if(c=="]")d--}} END{print d}')"
assert_eq "没有多余的尾逗号" 0 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c ',[]}]')"
assert_eq "实例之间有逗号" 1 "$(printf '%s' "$OUT" | tr -d '\n ' | grep -c '},{"type":"anytls"')"
sbv() { sb_instance_validate "$1" >/dev/null 2>&1; }
assert_ok "有效实例通过校验" sbv "$G/AnyTLS-01.conf"
bad() { # 名称 sed 表达式
    cp "$G/AnyTLS-01.conf" "$G/Bad-01.conf"
    sed -i 's/^id=.*/id=Bad-01/; s/^name=.*/name=Bad-01/' "$G/Bad-01.conf"
    sed -i "$2" "$G/Bad-01.conf"
    assert_fail "无效实例被拒绝: $1" sbv "$G/Bad-01.conf"
}
bad "密码太短" 's/^credential.password=.*/credential.password=short/'
bad "密码含非法字符" 's/^credential.password=.*/credential.password=bad password with spaces!!/'
bad "端口低于 1025" 's/^listen_port=.*/listen_port=443/'
bad "端口越界" 's/^listen_port=.*/listen_port=70000/'
bad "server_name 无效" 's/^tls.server_name=.*/tls.server_name=bad name/'
bad "证书路径是相对路径" 's#^tls.certificate_path=.*#tls.certificate_path=cert.pem#'
bad "证书路径含引号" 's#^tls.key_path=.*#tls.key_path=/etc/a"b#'
bad "缺少密码" '/^credential.password=/d'
bad "缺少 key_path" '/^tls.key_path=/d'
bad "类型不支持" 's/^type=anytls/type=hysteria2/'
bad "listen 无效" 's/^listen=.*/listen=not an addr/'
rm -f "$G/Bad-01.conf"
assert_eq "下一个编号" AnyTLS-04 "$(_sb_next_id "$G" AnyTLS)"
assert_eq "端口占用检测" yes "$(_sb_port_taken_by_instance "$G" 20002 && echo yes || echo no)"
assert_eq "排除自身的端口占用检测" no "$(_sb_port_taken_by_instance "$G" 20002 AnyTLS-02 && echo yes || echo no)"
assert_eq "期望端口只含启用的" "20001 20003" "$(_sb_expected_ports "$G")"

# ---- add ----
ready a1
OUT=$("$PM" sing-box add anytls --port 20443 2>&1)
RC=$?
assert_eq "add 成功" 0 "$RC"
assert_contains "add 输出实例名" "$OUT" "已添加实例 AnyTLS-01"
PW=$(PW_OF AnyTLS-01)
assert_eq "密码长度" 32 "${#PW}"
assert_contains "自动生成的密码只显示一次" "$OUT" "密码：$PW"
assert_eq "密码在输出中只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$PW")"
assert_eq "实例文件权限" 600 "$(stat -c %a "$(INST AnyTLS-01)")"
assert_eq "实例 type" anytls "$(kv_get "$(INST AnyTLS-01)" type)"
assert_eq "实例 enabled" true "$(kv_get "$(INST AnyTLS-01)" enabled)"
assert_eq "实例 listen 默认 ::" "::" "$(kv_get "$(INST AnyTLS-01)" listen)"
assert_eq "实例 port" 20443 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
assert_eq "实例 tls.mode" self-signed "$(kv_get "$(INST AnyTLS-01)" tls.mode)"
assert_eq "实例 tls.server_name 默认值" apm.local "$(kv_get "$(INST AnyTLS-01)" tls.server_name)"
assert_ok "证书文件存在" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_ok "私钥文件存在" test -f "$A/etc/sing-box/tls/AnyTLS-01.key"
assert_eq "证书权限" 640 "$(stat -c %a "$A/etc/sing-box/tls/AnyTLS-01.crt")"
assert_eq "私钥权限 (组 sing-box 可读, 其他人不可读)" 640 "$(stat -c %a "$A/etc/sing-box/tls/AnyTLS-01.key")"
assert_contains "证书属主" "$(cat "$A/.chown.log")" "root:sing-box /etc/sing-box/tls/AnyTLS-01.key"
assert_contains "私钥内容" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.key")" "BEGIN PRIVATE KEY"
assert_contains "证书内容" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")" "BEGIN CERTIFICATE"
assert_contains "配置含该实例" "$(CFG)" '"tag": "AnyTLS-01"'
assert_contains "配置含端口" "$(CFG)" '"listen_port": 20443'
assert_contains "配置含密码" "$(CFG)" "$PW"
assert_eq "配置权限" 640 "$(stat -c %a "$A/etc/sing-box/config.json")"
core_discover singbox
assert_eq "add 后运行中" running "$CF_STATE"
assert_contains "add 后监听 20443" "$CF_LISTEN" "0.0.0.0:20443"
assert_ok "配置通过官方 check" "$A/usr/local/bin/sing-box" check -c "$A/etc/sing-box/config.json"
assert_eq "密码只存在于实例文件, 配置与受限的配置备份" "" "$(leaks "$PW" "$A/etc/alpine-proxy-manager/instances/AnyTLS-01.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_not_contains "元数据不含密码" "$(cat "$(META)")" "$PW"
out=$("$PM" sing-box status; "$PM" sing-box info; "$PM" sing-box list; "$PM" sing-box show AnyTLS-01; "$PM" core list; "$PM" status)
assert_not_contains "任何只读输出都不含密码" "$out" "$PW"
assert_not_contains "任何只读输出都不含密码片段" "$out" "$(printf '%s' "$PW" | cut -c1-8)"
out=$("$PM" sing-box list)
assert_contains "list 含实例" "$out" "AnyTLS-01  anytls  启用, 监听中"
out=$("$PM" sing-box show AnyTLS-01)
assert_contains "show 密码已配置" "$out" "密码：已配置"
assert_contains "show 端口" "$out" "端口：20443"
assert_contains "show 当前监听" "$out" "当前监听：是"
assert_eq "备份目录权限" 700 "$(stat -c %a "$A/var/lib/alpine-proxy-manager/backups")"
assert_eq "配置备份权限" 600 "$(stat -c %a "$A/var/lib/alpine-proxy-manager/backups"/config.json.bak.* | head -n 1)"
assert_eq "没有遗留候选文件" 0 "$(ls -A "$A/etc/sing-box" | grep -c 'cand')"
assert_fail "没有违规动作" test -e "$K/violations"

# 第二个实例: 编号, 选项
OUT=$(printf 'ProvidedPasswordForEdge0123456789\n' | "$PM" sing-box add anytls --name Edge-01 --listen 0.0.0.0 --server-name www.example.com --port 20444 --password-stdin 2>&1)
assert_contains "自定义名称实例" "$OUT" "已添加实例 Edge-01"
assert_contains "自定义监听" "$(cat "$(INST Edge-01)")" "listen=0.0.0.0"
assert_eq "自定义 server-name" www.example.com "$(kv_get "$(INST Edge-01)" tls.server_name)"
assert_eq "使用提供的密码" ProvidedPasswordForEdge0123456789 "$(PW_OF Edge-01)"
assert_not_contains "提供的密码不回显" "$OUT" "ProvidedPassword"
assert_contains "提示使用了提供的值" "$OUT" "已使用你提供的值"
OUT=$("$PM" sing-box add anytls --port 20445 2>&1)
assert_contains "自动编号递增" "$OUT" "已添加实例 AnyTLS-02"
assert_eq "配置里有三个 inbound" 3 "$(CFG | grep -c '"type": "anytls"')"
core_discover singbox
assert_contains "三个端口都在监听" "$CF_LISTEN" "0.0.0.0:20445"
assert_eq "三个端口数量" 3 "$(printf '%s\n' "$CF_LISTEN" | grep -c tcp)"
# 拒绝
BEFORE=$(snap)
"$PM" sing-box add anytls --name AnyTLS-01 --port 20500 >/dev/null 2>&1
assert_eq "重名被拒绝" 1 $?
OUT=$("$PM" sing-box add anytls --port 20443 2>&1)
assert_eq "实例间端口重复被拒绝" 1 $?
assert_contains "端口重复提示" "$OUT" "已被其他实例使用"
mk_net "$A" tcp "$(tail -n +2 "$A/proc/net/tcp")
   9: 00000000:4E5C 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 9 1 0"
OUT=$("$PM" sing-box add anytls --port 20060 2>&1)
assert_eq "系统已占用的端口被拒绝" 1 $?
assert_contains "占用提示" "$OUT" "已被占用"
assert_eq "拒绝后没有改动" "$BEFORE" "$(snap)"
for a in "--port 80" "--port abc" "--listen bad" "--server-name bad_name" "--name bad/name" "--bogus"; do
    # shellcheck disable=SC2086
    "$PM" sing-box add anytls $a >/dev/null 2>&1
    assert_eq "参数错误 [$a] 返回 2" 2 $?
done
"$PM" sing-box add hysteria2 >/dev/null 2>&1
assert_eq "不支持的协议返回 2" 2 $?
"$PM" sing-box add >/dev/null 2>&1
assert_eq "缺少协议返回 2" 2 $?
printf 'short\n' | "$PM" sing-box add anytls --password-stdin >/dev/null 2>&1
assert_eq "无效密码返回 2" 2 $?

# ---- set ----
ready s1
"$PM" sing-box add anytls --port 20600 >/dev/null 2>&1
PW=$(PW_OF AnyTLS-01)
OUT=$("$PM" sing-box set AnyTLS-01 port 20601 2>&1)
assert_eq "set port 成功" 0 $?
assert_contains "set port 输出" "$OUT" "port 已更新为 20601"
core_discover singbox
assert_eq "旧端口消失, 新端口监听" "tcp 0.0.0.0:20601 60000" "$CF_LISTEN"
assert_eq "密码保持" "$PW" "$(PW_OF AnyTLS-01)"
assert_contains "配置端口更新" "$(CFG)" '"listen_port": 20601'
assert_eq "set port 保持实例文件权限" 600 "$(stat -c %a "$(INST AnyTLS-01)")"
OUT=$("$PM" sing-box set AnyTLS-01 listen 0.0.0.0 2>&1)
assert_eq "set listen 成功" 0 $?
assert_contains "配置 listen 更新" "$(CFG)" '"listen": "0.0.0.0"'
OLDCRT=$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")
OUT=$("$PM" sing-box set AnyTLS-01 server-name www.example.org 2>&1)
assert_eq "set server-name 成功" 0 $?
assert_eq "server-name 已写入" www.example.org "$(kv_get "$(INST AnyTLS-01)" tls.server_name)"
assert_contains "证书按新名字重新生成" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")" "FAKECERTFOR_www.example.org"
assert_not_contains "旧证书被替换" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")" "apm.local"
OUT=$("$PM" sing-box set AnyTLS-01 password --generate 2>&1)
assert_eq "set password --generate 成功" 0 $?
NEWPW=$(PW_OF AnyTLS-01)
assert_ne() { if [ "$2" != "$3" ]; then t_pass "$1"; else t_fail "$1" "两者相同: $2"; fi; }
assert_ne "密码已更换" "$PW" "$NEWPW"
assert_contains "新密码显示一次" "$OUT" "新密码：$NEWPW"
assert_eq "新密码只出现一次" 1 "$(printf '%s\n' "$OUT" | grep -c "$NEWPW")"
assert_contains "配置中的密码已更新" "$(CFG)" "$NEWPW"
OUT=$(printf 'StdinPasswordForTest0123456789\n' | "$PM" sing-box set AnyTLS-01 password --stdin 2>&1)
assert_eq "set password --stdin 成功" 0 $?
assert_eq "密码已设置" StdinPasswordForTest0123456789 "$(PW_OF AnyTLS-01)"
assert_not_contains "stdin 密码不回显" "$OUT" "StdinPassword"
"$PM" sing-box set AnyTLS-01 password PlainTextOnCommandLine0123456 >/dev/null 2>&1
assert_eq "密码不接受命令行明文" 2 $?
"$PM" sing-box set AnyTLS-01 port 80 >/dev/null 2>&1
assert_eq "set port 无效返回 2" 2 $?
"$PM" sing-box set AnyTLS-01 listen bad >/dev/null 2>&1
assert_eq "set listen 无效返回 2" 2 $?
"$PM" sing-box set AnyTLS-01 bogus x >/dev/null 2>&1
assert_eq "set 未知键返回 2" 2 $?
"$PM" sing-box set Nope-01 port 20700 >/dev/null 2>&1
assert_eq "set 不存在的实例返回 1" 1 $?
"$PM" sing-box add anytls --port 20602 >/dev/null 2>&1
"$PM" sing-box set AnyTLS-01 port 20602 >/dev/null 2>&1
assert_eq "set port 到其他实例的端口被拒绝" 1 $?
assert_ok "全程仍运行" running
assert_eq "密码只存在于允许的位置" "" "$(leaks "$NEWPW" "$A/etc/alpine-proxy-manager/instances/*.conf $A/etc/sing-box/config.json $A/var/lib/alpine-proxy-manager/backups/config.json.bak.*")"
assert_eq "配置备份最多 2 份" 2 "$(ls "$A/var/lib/alpine-proxy-manager/backups"/config.json.bak.* | wc -l | tr -d ' ')"

# ---- enable disable delete ----
ready d1
"$PM" sing-box add anytls --port 20700 >/dev/null 2>&1
"$PM" sing-box add anytls --port 20701 >/dev/null 2>&1
OUT=$("$PM" sing-box disable AnyTLS-01 2>&1)
assert_eq "disable 成功" 0 $?
assert_eq "禁用后 enabled=false" false "$(kv_get "$(INST AnyTLS-01)" enabled)"
assert_not_contains "禁用后配置不含该实例" "$(CFG)" "AnyTLS-01"
assert_contains "禁用后配置仍含另一个" "$(CFG)" "AnyTLS-02"
core_discover singbox
assert_not_contains "禁用后端口不再监听" "$CF_LISTEN" ":20700"
assert_contains "禁用后另一个端口监听" "$CF_LISTEN" ":20701"
assert_ok "禁用后实例文件与证书仍在" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
out=$("$PM" sing-box list)
assert_contains "list 显示禁用" "$out" "AnyTLS-01  anytls  禁用"
OUT=$("$PM" sing-box enable AnyTLS-01 2>&1)
assert_eq "enable 成功" 0 $?
assert_contains "启用后配置含该实例" "$(CFG)" "AnyTLS-01"
core_discover singbox
assert_contains "启用后端口监听" "$CF_LISTEN" ":20700"
OUT=$("$PM" sing-box delete AnyTLS-01 2>&1)
assert_eq "delete 成功" 0 $?
assert_fail "删除后实例文件已删" test -e "$(INST AnyTLS-01)"
assert_fail "删除后证书已删" test -e "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_fail "删除后私钥已删" test -e "$A/etc/sing-box/tls/AnyTLS-01.key"
assert_not_contains "删除后配置不含该实例" "$(CFG)" "AnyTLS-01"
core_discover singbox
assert_not_contains "删除后端口不再监听" "$CF_LISTEN" ":20700"
OUT=$("$PM" sing-box add anytls --name AnyTLS-01 --port 20700 2>&1)
assert_eq "删除后可以用同名重新创建" 0 $?
"$PM" sing-box delete Nope-01 >/dev/null 2>&1
assert_eq "删除不存在的实例返回 1" 1 $?
"$PM" sing-box enable >/dev/null 2>&1
assert_eq "缺少实例 ID 返回 2" 2 $?
"$PM" sing-box delete AnyTLS-01 >/dev/null 2>&1
"$PM" sing-box delete AnyTLS-02 >/dev/null 2>&1
assert_contains "全部删除后 inbounds 为空" "$(CFG)" '"inbounds": []'
assert_ok "全部删除后 sing-box 仍运行" running
out=$("$PM" sing-box list)
assert_contains "没有实例的 list" "$out" "(没有实例)"

# ---- 服务停止时修改配置: 只写入, 不启动 ----
ready p1
"$PM" sing-box stop >/dev/null 2>&1
: > "$K/calls"
OUT=$("$PM" sing-box add anytls --port 20800 2>&1)
assert_eq "停止时 add 成功" 0 $?
assert_contains "停止时提示下次启动生效" "$OUT" "下次启动生效"
core_discover singbox
assert_eq "停止时 add 不启动服务" stopped "$CF_STATE"
assert_eq "停止时没有调用 start 与 restart" 00 "$(count_calls start)$(count_calls restart)"
"$PM" sing-box start >/dev/null 2>&1
assert_eq "启动后实例端口监听" 0 "$(core_discover singbox; printf '%s\n' "$CF_LISTEN" | grep -c ':20800 ' | awk '{print ($1==1)?0:1}')"

# ---- 事务回滚 ----
# 官方 check 失败: 实例不保存, 证书清理, 旧配置与服务保持
ready t1
"$PM" sing-box add anytls --port 20900 >/dev/null 2>&1
OLDCFG=$(CFG)
BEFORE=$(snap)
touch "$K/check_fail"
OUT=$("$PM" sing-box add anytls --port 20901 2>&1)
assert_eq "check 失败时 add 失败" 1 $?
rm -f "$K/check_fail"
assert_contains "check 失败提示" "$OUT" "未通过 sing-box check"
assert_eq "check 失败后配置未变" "$OLDCFG" "$(CFG)"
assert_fail "check 失败后没有新实例" test -e "$(INST AnyTLS-02)"
assert_fail "check 失败后新证书已清理" test -e "$A/etc/sing-box/tls/AnyTLS-02.crt"
assert_eq "check 失败后没有任何改动" "$BEFORE" "$(snap)"
assert_ok "check 失败后仍运行" running
# 重启失败: 恢复旧配置并重新启动
echo 20902 > "$K/fail_port-sing-box"
BEFORE=$(snap)
OUT=$("$PM" sing-box add anytls --port 20902 2>&1)
assert_eq "新配置无法启动时 add 失败" 1 $?
assert_contains "回滚提示" "$OUT" "已恢复旧配置"
assert_contains "回滚后恢复运行提示" "$OUT" "已恢复旧配置并验证 sing-box 正常运行"
assert_eq "回滚后配置恢复" "$OLDCFG" "$(CFG)"
assert_fail "回滚后没有新实例" test -e "$(INST AnyTLS-02)"
assert_fail "回滚后新证书已清理" test -e "$A/etc/sing-box/tls/AnyTLS-02.crt"
assert_ok "回滚后运行中" running
core_discover singbox
assert_contains "回滚后旧端口仍监听" "$CF_LISTEN" ":20900"
assert_not_contains "回滚后新端口不监听" "$CF_LISTEN" ":20902"
# set port 失败: 实例文件保持旧值
OLDPORT=$(kv_get "$(INST AnyTLS-01)" listen_port)
echo 20903 > "$K/fail_port-sing-box"
"$PM" sing-box set AnyTLS-01 port 20903 >/dev/null 2>&1
assert_eq "set port 无法启动时失败" 1 $?
assert_eq "实例文件保持旧端口" "$OLDPORT" "$(kv_get "$(INST AnyTLS-01)" listen_port)"
assert_eq "配置保持不变" "$OLDCFG" "$(CFG)"
assert_ok "set 失败后仍运行" running
# set server-name 失败: 旧证书放回
echo 1 > "$K/check_fail"
OLDCRT=$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")
"$PM" sing-box set AnyTLS-01 server-name other.example.com >/dev/null 2>&1
assert_eq "check 失败时 set server-name 失败" 1 $?
rm -f "$K/check_fail"
assert_eq "旧证书被放回" "$OLDCRT" "$(cat "$A/etc/sing-box/tls/AnyTLS-01.crt")"
assert_eq "server-name 保持旧值" apm.local "$(kv_get "$(INST AnyTLS-01)" tls.server_name)"
# 证书生成失败
touch "$K/gen_fail"
BEFORE=$(snap)
"$PM" sing-box add anytls --port 20904 >/dev/null 2>&1
assert_eq "证书生成失败时 add 失败" 1 $?
assert_eq "证书生成失败没有任何改动" "$BEFORE" "$(snap)"
rm -f "$K/gen_fail"
# delete 失败: 实例保留
echo 20900 > "$K/fail_port-sing-box"
: > "$K/fail_port-sing-box"
touch "$K/fail_restart-sing-box"
BEFORE=$(snap)
"$PM" sing-box delete AnyTLS-01 >/dev/null 2>&1
assert_eq "重启失败时 delete 失败" 1 $?
rm -f "$K/fail_restart-sing-box"
assert_ok "delete 失败后实例仍在" test -f "$(INST AnyTLS-01)"
assert_ok "delete 失败后证书仍在" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
assert_eq "delete 失败后配置不变" "$OLDCFG" "$(CFG)"

# ---- 归属保护 ----
new_s x1
mkdir -p "$A/etc/sing-box"
mk_elf_exec "$A/usr/local/bin/sing-box" "$T_TMP/real-side.sh"
printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/sing-box"\ncommand_args="run -c /etc/sing-box/config.json"\nsupervisor=supervise-daemon\n' > "$A/etc/init.d/sing-box"
printf '{}\n' > "$A/etc/sing-box/config.json"
BEFORE=$(snap)
for c in "add anytls" "enable AnyTLS-01" "disable AnyTLS-01" "delete AnyTLS-01" "set AnyTLS-01 port 20000"; do
    # shellcheck disable=SC2086
    "$PM" sing-box $c >/dev/null 2>&1
    assert_eq "External: $c 拒绝返回 4" 4 $?
done
assert_eq "External: 实例命令没有改动" "$BEFORE" "$(snap)"
assert_fail "External: 没有创建实例目录" test -e "$A/etc/alpine-proxy-manager"

# ---- 卸载与 purge 对实例的处理 ----
ready z1
"$PM" sing-box add anytls --port 21000 >/dev/null 2>&1
PW=$(PW_OF AnyTLS-01)
"$PM" sing-box uninstall >/dev/null 2>&1
assert_ok "普通卸载保留实例" test -f "$(INST AnyTLS-01)"
assert_ok "普通卸载保留证书" test -f "$A/etc/sing-box/tls/AnyTLS-01.crt"
OUT=$("$PM" sing-box install 2>&1)
assert_eq "重新安装沿用实例" 0 $?
assert_contains "重新安装后配置含该实例" "$(CFG)" "$PW"
core_discover singbox
assert_contains "重新安装后实例端口监听" "$CF_LISTEN" ":21000"
assert_not_contains "重新安装不显示密码" "$OUT" "$PW"
"$PM" sing-box uninstall --purge >/dev/null 2>&1
assert_fail "purge 删除实例" test -e "$(INST AnyTLS-01)"
assert_fail "purge 删除证书" test -e "$A/etc/sing-box"
assert_eq "purge 删除配置备份" 0 "$(ls "$A/var/lib/alpine-proxy-manager/backups" 2>/dev/null | grep -c config.json)"
assert_eq "purge 后没有任何文件含密码" "" "$(grep -rl "$PW" "$A" 2>/dev/null)"
# 已保留的实例无效: 拒绝安装, 不改动
ready z2
"$PM" sing-box add anytls --port 21001 >/dev/null 2>&1
"$PM" sing-box uninstall >/dev/null 2>&1
printf 'garbage\n' > "$(INST AnyTLS-01)"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "已保留的实例无效时 install 拒绝" 4 $?
assert_contains "无效实例提示" "$OUT" "已保留的实例"
assert_eq "无效实例没有改动" "$BEFORE" "$(snap)"
# 已保留实例的端口被占用: 拒绝安装
ready z3
"$PM" sing-box add anytls --port 21002 >/dev/null 2>&1
"$PM" sing-box uninstall >/dev/null 2>&1
mk_net "$A" tcp "   0: 00000000:520A 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 9 1 0"
BEFORE=$(snap)
OUT=$("$PM" sing-box install 2>&1)
assert_eq "已保留实例的端口被占用时 install 拒绝" 1 $?
assert_contains "端口占用提示" "$OUT" "已被占用"
assert_eq "端口占用没有改动" "$BEFORE" "$(snap)"

# ---- 与 Snell 共存时修改实例不影响 Snell ----
new_s c2
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" sing-box install >/dev/null 2>&1
core_discover snell
SPID=$CF_PID
SCONF=$(cksum < "$A/etc/snell/snell-server.conf")
: > "$K/calls"
"$PM" sing-box add anytls --port 21100 >/dev/null 2>&1
"$PM" sing-box set AnyTLS-01 port 21101 >/dev/null 2>&1
"$PM" sing-box disable AnyTLS-01 >/dev/null 2>&1
core_discover snell
assert_eq "实例变更不影响 Snell: PID" "$SPID" "$CF_PID"
assert_eq "实例变更不影响 Snell: 配置" "$SCONF" "$(cksum < "$A/etc/snell/snell-server.conf")"
assert_eq "实例变更没有触碰 Snell 服务" "" "$(grep '^snell ' "$K/calls" | grep -v ' status$')"
assert_fail "没有违规动作" test -e "$K/violations"
t_done
