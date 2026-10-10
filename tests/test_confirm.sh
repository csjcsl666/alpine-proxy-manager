# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# 所有交互式 Yes/No 确认统一默认 Yes: 空回车是 Yes, y/Y 是 Yes, n/N 是 No, 无效输入重新询问, EOF 不是 Yes
# 覆盖公共确认函数 tui_confirm 与 Snell 命令行的安装确认, 并扫描源码防止出现默认 No 的残留
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet singbox anytlsgw tui

# C 输入 -> 输出 返回码
C() { printf '%b' "$1" | ( tui_confirm "测试操作" ); }
R() { printf '%b' "$1" | ( tui_confirm "测试操作" >/dev/null 2>&1 ); echo $?; }

assert_eq "空回车 -> Yes" 0 "$(R '\n')"
assert_eq "y -> Yes" 0 "$(R 'y\n')"
assert_eq "Y -> Yes" 0 "$(R 'Y\n')"
assert_eq "yes -> Yes" 0 "$(R 'yes\n')"
assert_eq "前后空白的 y -> Yes" 0 "$(R '  y  \n')"
assert_eq "只有空白 -> Yes" 0 "$(R '   \n')"
assert_eq "CRLF 空回车 -> Yes" 0 "$(R '\r\n')"
assert_eq "n -> No" 1 "$(R 'n\n')"
assert_eq "N -> No" 1 "$(R 'N\n')"
assert_eq "no -> No" 1 "$(R 'no\n')"
assert_eq "无效输入后空回车 -> Yes" 0 "$(R 'x\n\n')"
assert_eq "无效输入后 n -> No" 1 "$(R 'maybe\nn\n')"
assert_eq "多次无效输入后 y -> Yes" 0 "$(R '1\n2\nabc\ny\n')"
out=$(C 'x\ny\n')
assert_contains "提示显示 Y/n" "$out" "继续？[Y/n]"
assert_not_contains "提示不再显示 y/N" "$out" "[y/N]"
assert_contains "无效输入有明确提示" "$out" "输入无效，请输入 y 或 n"
assert_contains "无效输入后重新询问" "$(printf '%s' "$out" | grep -c '继续？\[Y/n\]')" "2"
out=$(C 'n\n')
assert_contains "No 显示已取消" "$out" "已取消"
# EOF 和读取失败不是空回车
assert_eq "完全空的输入 (立即 EOF) -> 中止" 1 "$(R '')"
assert_eq "无效输入后 EOF -> 中止" 1 "$(R 'x\n')"
assert_eq "无效输入多次后 EOF -> 中止" 1 "$(R 'x\ny y\n')"
assert_eq "无换行的 y 仍是 Yes" 0 "$(R 'y')"
assert_eq "无换行的 n 仍是 No" 1 "$(R 'n')"
assert_eq "/dev/null 作为输入 -> 中止" 1 "$( ( tui_confirm "测试操作" </dev/null >/dev/null 2>&1 ); echo $? )"
assert_eq "关闭的标准输入 -> 中止" 1 "$( ( tui_confirm "测试操作" <&- >/dev/null 2>&1 ); echo $? )"
out=$( ( tui_confirm "测试操作" </dev/null 2>&1 ) )
assert_contains "EOF 提示已取消" "$out" "已取消"
# EOF 不会无限循环: 带超时运行
assert_eq "EOF 不会死循环" 1 "$(printf 'x\nx\nx\n' | ( timeout 10 sh -c '. "$1/lib/common.sh"; . "$1/lib/environment.sh"; . "$1/lib/tui.sh"; tui_confirm 测试 >/dev/null 2>&1' _ "$T_ROOT" ); echo $?)"

# 调用方: 确认返回 Yes 才执行, 返回 No 不执行
ran=no
( tui_confirm "测试" </dev/null >/dev/null 2>&1 ) && ran=yes
assert_eq "EOF 时调用方不执行" no "$ran"
ran=no
printf '\n' | ( tui_confirm "测试" >/dev/null 2>&1 ) && ran=yes
assert_eq "空回车时调用方执行" yes "$ran"

# Snell 命令行安装确认: 只在交互终端出现 回车 Yes, 非终端不算确认
assert_eq "非交互环境不会被当成确认" 1 "$( ( _snn_confirm_tty "安装？" </dev/null >/dev/null 2>&1 ); echo $? )"
assert_eq "管道输入 y 也不算交互确认" 1 "$(printf 'y\n' | ( _snn_confirm_tty "安装？" >/dev/null 2>&1 ); echo $?)"


# Snell 命令行确认在真实终端 (pty) 里: 回车 Yes, n No, 无效重问, EOF 不算确认
PTYC() { # 输入
    printf '%b' "$1" | timeout 20 script -qec "sh -c '. \"$T_ROOT/lib/common.sh\"; . \"$T_ROOT/lib/environment.sh\"; . \"$T_ROOT/lib/snell.sh\"; . \"$T_ROOT/lib/snellnet.sh\"; _snn_confirm_tty 安装 >/dev/null; echo RC=\$?'" /dev/null 2>&1 | tr -d '\r' | sed -n 's/.*RC=//p'
}
if command -v script >/dev/null 2>&1 && [ -n "$(PTYC '\n')" ]; then
    assert_eq "pty: 回车 -> Yes" 0 "$(PTYC '\n')"
    assert_eq "pty: y -> Yes" 0 "$(PTYC 'y\n')"
    assert_eq "pty: n -> No" 1 "$(PTYC 'n\n')"
    assert_eq "pty: 无效输入后回车 -> Yes" 0 "$(PTYC 'zz\n\n')"
else
    t_skip "没有可用的 script, 跳过 pty 确认测试"
fi

# 源码扫描: 任何地方都不得再出现默认 No 的提示或判断
SRC="$T_ROOT/lib/*.sh $T_ROOT/bin/proxy-manager $T_ROOT/install.sh"
# shellcheck disable=SC2086
assert_eq "源码里没有 [y/N] 提示" "" "$(grep -n '\[y/N\]' $SRC 2>/dev/null)"
# shellcheck disable=SC2086
assert_eq "源码里没有 默认 N 的确认注释" "" "$(grep -n '默认 N' $SRC 2>/dev/null)"
# 所有 TUI 确认都经过公共函数: 只有 tui_confirm 与 Snell 命令行确认读取 yes/no
# shellcheck disable=SC2086
assert_eq "只有两处解析 y/n" "2" "$(grep -c "y|Y|yes|YES" $SRC 2>/dev/null | awk -F: '{ s += $2 } END { print s }')"
T=$(sed -n '/^tui_confirm()/,/^}/p' "$T_ROOT/lib/tui.sh")
assert_contains "空串走 Yes 分支" "$T" "''|y|Y|yes|YES|Yes) return 0"
assert_contains "读取失败有独立的中止分支" "$T" 'TUI_EOF=1'

# 各 Core 的 TUI 入口都使用同一个公共函数
for f in 'tui_snell_menu' 'tui_anytlsgw_menu' 'tui_agw_listener_menu' 'tui_agw_cert_menu' '_tui_core_uninstall' '_tui_core_lifecycle'; do
    body=$(sed -n "/^$f()/,/^}/p" "$T_ROOT/lib/tui.sh")
    case $body in
        *'read -r'*'y|Y'*) t_fail "$f 自己解析 y/n, 应使用 tui_confirm" ;;
        *) t_pass "$f 不自行解析 y/n" ;;
    esac
done

t_done
