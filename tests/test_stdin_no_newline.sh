# shellcheck shell=sh
# 标准输入的密码或密钥没有末尾换行符时仍然必须被接受 (printf 'secret' | ... --stdin)
# 回归: read -r 在没有末尾换行时返回非零, 旧写法 read || VAR= 会把已读到的数据清空, 误报密码无效
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_stdin_no_newline.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }

new_s n1
"$PM" sing-box install >/dev/null 2>&1

# sing-box 实例密码
printf 'NoNewlinePasswordAbc0123456789' | "$PM" sing-box add anytls --port 20001 --password-stdin >/dev/null 2>&1
assert_eq "add --password-stdin 接受没有末尾换行的密码" 0 $?
assert_eq "密码内容完整" NoNewlinePasswordAbc0123456789 "$(kv_get "$(INST AnyTLS-01)" credential.password)"
printf 'AnotherNoNewlinePw012345678901' | "$PM" sing-box set AnyTLS-01 password --stdin >/dev/null 2>&1
assert_eq "set password --stdin 接受没有末尾换行的密码" 0 $?
assert_eq "set password 内容完整" AnotherNoNewlinePw012345678901 "$(kv_get "$(INST AnyTLS-01)" credential.password)"
printf 'WithNewlinePassword01234567890\n' | "$PM" sing-box set AnyTLS-01 password --stdin >/dev/null 2>&1
assert_eq "有末尾换行时仍然接受" WithNewlinePassword01234567890 "$(kv_get "$(INST AnyTLS-01)" credential.password)"
printf '' | "$PM" sing-box set AnyTLS-01 password --stdin >/dev/null 2>&1
assert_eq "空输入仍被拒绝" 2 $?
printf '\n' | "$PM" sing-box set AnyTLS-01 password --stdin >/dev/null 2>&1
assert_eq "只有换行仍被拒绝" 2 $?
assert_eq "被拒绝后密码保持" WithNewlinePassword01234567890 "$(kv_get "$(INST AnyTLS-01)" credential.password)"

# Shadowsocks method 加密钥
"$PM" sing-box add shadowsocks --port 20004 >/dev/null 2>&1
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' | "$PM" sing-box set Shadowsocks-01 method 2022-blake3-aes-256-gcm --stdin >/dev/null 2>&1
assert_eq "set method --stdin 接受没有末尾换行的密钥" 0 $?
assert_eq "method 已更新" 2022-blake3-aes-256-gcm "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
assert_eq "密钥内容完整" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$(kv_get "$(INST Shadowsocks-01)" credential.password)"

# SOCKS Profile
printf 'SocksNoNewlinePassword01' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u --password-stdin >/dev/null 2>&1
assert_eq "socks add --password-stdin 接受没有末尾换行的密码" 0 $?
assert_eq "SOCKS 密码内容完整" SocksNoNewlinePassword01 "$(kv_get "$(PROF SOCKS-01)" password)"
printf 'SocksSetNoNewlinePw02' | "$PM" sing-box socks set SOCKS-01 password --password-stdin >/dev/null 2>&1
assert_eq "socks set password 接受没有末尾换行的密码" 0 $?
assert_eq "set password 内容完整" SocksSetNoNewlinePw02 "$(kv_get "$(PROF SOCKS-01)" password)"
printf 'SocksCredNoNewlinePw03' | "$PM" sing-box socks set SOCKS-01 credential bob --password-stdin >/dev/null 2>&1
assert_eq "socks set credential 接受没有末尾换行的密码" 0 $?
assert_eq "credential 用户名与密码完整" "bob SocksCredNoNewlinePw03" "$(kv_get "$(PROF SOCKS-01)" username) $(kv_get "$(PROF SOCKS-01)" password)"
printf '' | "$PM" sing-box socks set SOCKS-01 password --password-stdin >/dev/null 2>&1
assert_eq "socks 空输入仍被拒绝" 2 $?

# Snell
new_s n2
printf 'SnellNoNewlinePsk0123456789ab' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
assert_eq "snell install --psk-stdin 接受没有末尾换行的 psk" 0 $?
assert_contains "psk 内容完整" "$(cat "$A/etc/snell/snell-server.conf")" "psk = SnellNoNewlinePsk0123456789ab"
printf 'SnellSetNoNewlinePsk012345678' | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "snell config set psk --stdin 接受没有末尾换行的 psk" 0 $?
assert_contains "set psk 内容完整" "$(cat "$A/etc/snell/snell-server.conf")" "psk = SnellSetNoNewlinePsk012345678"
printf '' | "$PM" snell config set psk --stdin >/dev/null 2>&1
assert_eq "snell 空输入仍被拒绝" 2 $?
assert_fail "没有违规动作" test -e "$K/violations"
t_done
