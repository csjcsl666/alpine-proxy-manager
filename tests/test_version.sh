# shellcheck shell=sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
PM="$T_ROOT/bin/proxy-manager"

out=$("$PM" --version)
ver=$(cat "$T_ROOT/VERSION")
assert_eq "第一行是名称加 VERSION 文件内容" "Alpine Proxy Manager $ver" "$(printf '%s\n' "$out" | sed -n 1p)"
case $(printf '%s\n' "$out" | sed -n 2p) in
    "Build: unknown"|"Build: "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) t_pass "Build 是 short SHA 或 unknown" ;;
    *) t_fail "Build 格式" "$(printf '%s\n' "$out" | sed -n 2p)" ;;
esac

assert_ok "VERSION 是 semver 形式" sh -c "grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\$' '$T_ROOT/VERSION'"
if grep -rn -F "$ver" "$T_ROOT/bin" "$T_ROOT/lib" "$T_ROOT/install.sh" >/dev/null 2>&1; then
    t_fail "版本号不得在代码中重复写死"
else
    t_pass "版本号不得在代码中重复写死"
fi

# 无 git 与 BUILD 时回退 unknown
cp_tree="$T_TMP/tree"
mkdir -p "$cp_tree"
cp -R "$T_ROOT/bin" "$T_ROOT/lib" "$T_ROOT/VERSION" "$cp_tree/"
assert_eq "无 .git 与 BUILD 时 Build 为 unknown" "Build: unknown" "$("$cp_tree/bin/proxy-manager" --version | sed -n 2p)"
echo abc1234 > "$cp_tree/BUILD"
assert_eq "BUILD 文件优先" "Build: abc1234" "$("$cp_tree/bin/proxy-manager" --version | sed -n 2p)"

# 通过符号链接调用也能找到 lib
ln -s "$cp_tree/bin/proxy-manager" "$T_TMP/pm-link"
assert_eq "符号链接调用" "Alpine Proxy Manager $ver" "$("$T_TMP/pm-link" --version | sed -n 1p)"

assert_rc "未知命令返回 2" 2 "$PM" no-such-command
assert_rc "help 返回 0" 0 "$PM" help
t_done
