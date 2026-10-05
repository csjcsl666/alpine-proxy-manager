# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

P="$T_TMP/prefix/alpine-proxy-manager"
B="$T_TMP/bin"
export APM_PREFIX="$P" APM_BINDIR="$B"

out=$(sh "$T_ROOT/install.sh")
assert_eq "安装成功" 0 $?
assert_contains "安装后可执行 --version" "$out" "Alpine Proxy Manager $(cat "$T_ROOT/VERSION")"
assert_ok "命令链接存在" test -L "$B/proxy-manager"
assert_eq "安装目录不含测试文件" "" "$(ls "$P" | grep -E '^(tests|install.sh)$')"

# 重复安装覆盖, 不残留临时目录
sh "$T_ROOT/install.sh" >/dev/null
assert_eq "重复安装无残留" 0 "$(ls "$T_TMP/prefix" | grep -c '\.new\.')"

# 卸载保留配置目录
mkdir -p "$T_TMP/etc-keep"
echo keep > "$T_TMP/etc-keep/f"
sh "$T_ROOT/install.sh" --uninstall >/dev/null
assert_fail "卸载后目录被删除" test -e "$P"
assert_fail "卸载后链接被删除" test -e "$B/proxy-manager"
assert_ok "不触碰其他目录" test -e "$T_TMP/etc-keep/f"

# 危险的安装目录被拒绝
assert_fail "拒绝根目录" env APM_PREFIX=/ sh "$T_ROOT/install.sh"
assert_fail "拒绝非 alpine-proxy-manager 结尾的目录" env APM_PREFIX="$T_TMP/prefix/other" sh "$T_ROOT/install.sh"
assert_fail "未知参数" sh "$T_ROOT/install.sh" --bogus
t_done
