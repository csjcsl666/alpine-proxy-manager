# shellcheck shell=sh
# TUI 的屏幕生命周期: 备用屏幕 (进入 退出 信号) 页面不叠加 终端尺寸 长内容分页 退出恢复
# 序列和降级用管道验证, 其余用真实终端模拟器 tmux 验证 (alternate_on 是 tmux 自己对终端状态的判断, 不是脚本的自述)
# 没有 tmux 的环境里终端部分跳过 (CI 与沙盒里 apk add tmux)
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_tui_screen.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

LC_ALL=en_US.UTF-8
export LC_ALL
printf '#!/bin/sh\nexit 1\n' > "$T_TMP/dl-fail"
chmod +x "$T_TMP/dl-fail"
APM_DOWNLOADER=$T_TMP/dl-fail
export APM_DOWNLOADER

new_s sc1
printf 'ScreenSnellPskNotSecret0123456789\n' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
mkdir -p "$A/var/log/snell" "$A/var/log/sing-box"
ESC=$(printf '\033')

# ---- 序列与降级 (管道) ----
printf '== 备用屏幕序列\n'
run() { # 输入 环境...
    _in=$1; shift
    printf '%b' "$_in" | ( for _e in "$@"; do export "${_e?}"; done; tui_run ) 2>&1
}
out=$(run '0\n' APM_TUI_ANSI=1 APM_TUI_ALTSCREEN=1)
assert_contains "强制启用: 进入备用屏幕" "$out" "${ESC}[?1049h"
assert_contains "强制启用: 退出备用屏幕" "$out" "${ESC}[?1049l"
assert_eq "强制启用: 进入一次" 1 "$(printf '%s' "$out" | grep -a -o "${ESC}\[?1049h" | wc -l | tr -d ' ')"
assert_eq "强制启用: 退出一次" 1 "$(printf '%s' "$out" | grep -a -o "${ESC}\[?1049l" | wc -l | tr -d ' ')"
# 退出提示写在切回原屏幕之后, 留在 shell 里
tail_part=${out##*"${ESC}[?1049l"}
assert_contains "强制启用: 已退出写在切回原屏幕之后" "$tail_part" "已退出"
# 子菜单往返不产生更多的切换序列
out=$(run '6\n0\n4\n0\n5\n0\n0\n' APM_TUI_ANSI=1 APM_TUI_ALTSCREEN=1)
assert_eq "子菜单往返: 仍只进入一次" 1 "$(printf '%s' "$out" | grep -a -o "${ESC}\[?1049h" | wc -l | tr -d ' ')"
# EOF 也切回
out=$(printf '6\n' | ( APM_TUI_ANSI=1 APM_TUI_ALTSCREEN=1; export APM_TUI_ANSI APM_TUI_ALTSCREEN; tui_run ) 2>&1)
assert_contains "EOF: 切回原屏幕" "$out" "${ESC}[?1049l"
# 降级: 默认管道 (stdout 不是终端) 不输出切换序列, 其他开关也一样
out=$(run '0\n' APM_TUI_ANSI=1)
assert_not_contains "管道: 不输出切换序列" "$out" "?1049"
out=$(run '0\n' APM_TUI_ANSI=1 APM_TUI_ALTSCREEN=0)
assert_not_contains "显式关闭: 不输出切换序列" "$out" "?1049"
out=$(run '0\n' APM_TUI_ANSI=0 APM_TUI_ALTSCREEN=1)
assert_not_contains "无 ANSI: 即使强制也不输出" "$out" "?1049"
out=$(run '0\n' APM_TUI_ANSI=1 APM_TUI_ALTSCREEN=1 TERM=dumb)
assert_not_contains "TERM=dumb: 不输出" "$out" "?1049"

# 终端名单: 不支持备用屏幕的 TERM 不启用 (自动模式要求 stdout 是终端, 所以直接测判断函数)
for _t in dumb linux vt100 vt102 vt52 unknown ''; do
    assert_fail "自动模式 TERM=$_t: 不启用" sh -c ". '$T_ROOT/lib/common.sh'; . '$T_ROOT/lib/tui.sh'; TUI_ANSI=1; TERM='$_t'; _tui_alt_wanted"
done

# ---- 分页 (函数级) ----
printf '== 长内容分页的页数估算\n'
_t=
i=1
while [ "$i" -le 30 ]; do _t="$_t
line-$i"; i=$((i + 1)); done
_t=${_t#
}
pg=$(printf '%s\n' "$_t" | _tui_paginate 21 80 | tail -n 1 | cut -f1)
assert_eq "30 行 21 行/页: 2 页" 1 "$pg"
pg=$(printf '%s\n' "$_t" | _tui_paginate 40 80 | tail -n 1 | cut -f1)
assert_eq "30 行放得下: 1 页" 0 "$pg"
# 长行按列宽折行占多行: 100 个 ASCII 字符在 60 列占 2 行
longl=$(awk 'BEGIN { for (i = 0; i < 100; i++) printf "x" }')
pg=$(printf '%s\n%s\n%s\n' "$longl" "$longl" "$longl" | _tui_paginate 4 60 | tail -n 1 | cut -f1)
assert_eq "长行折行: 3 行 x 2 = 6 行, 每页 4 行 -> 2 页" 1 "$pg"
# ANSI 颜色序列不占宽度: 70 个字符加颜色在 80 列仍是一行
colored=$(printf '\033[31m%s\033[0m' "$(awk 'BEGIN { for (i = 0; i < 70; i++) printf "y" }')")
pg=$(printf '%s\n%s\n' "$colored" "$colored" | _tui_paginate 2 80 | tail -n 1 | cut -f1)
assert_eq "ANSI 不占宽: 两行一页" 0 "$pg"
# 中文每字占 2 列: 30 个汉字 = 60 列, 在 60 列刚好一行, 31 个就折行
han30=$(awk 'BEGIN { for (i = 0; i < 30; i++) printf "中" }')
han31=${han30}中
pg=$(printf '%s\n%s\n' "$han30" "$han30" | _tui_paginate 2 60 | tail -n 1 | cut -f1)
assert_eq "中文 30 字 60 列: 一行一页放两行" 0 "$pg"
pg=$(printf '%s\n%s\n' "$han31" "$han31" | _tui_paginate 2 60 | tail -n 1 | cut -f1)
assert_eq "中文 31 字 60 列: 折成两行, 需要两页" 1 "$pg"

# 非备用屏幕: 报告函数与 _tui_do 完全一致
TUI_ALT=0
out=$(_tui_do_view "标题" printf 'hello\n' 2>&1)
assert_eq "非备用屏幕: _tui_do_view 等同 _tui_do" "hello" "$out"

if ! command -v tmux >/dev/null 2>&1; then
    t_skip "没有 tmux, 真实终端部分跳过 (apk add tmux)"
    t_done
    exit $?
fi

# ---- 真实终端 (tmux) ----
printf '== 真实终端: 备用屏幕\n'
mkdir -p "$A/usr/bin"
ln -sf "$(command -v stty)" "$A/usr/bin/stty"
# 日志: 30 行带编号, 超过一屏
i=1
: > "$A/var/log/snell/error.log"
while [ "$i" -le 30 ]; do printf '2026-01-01 00:00:%02d.000000 [server] <WARN> screen-log-line-%02d\n' "$i" "$i" >> "$A/var/log/snell/error.log"; i=$((i + 1)); done
ENVF=$T_TMP/screen.env
{
    printf 'APM_SYSROOT=%s\nAPM_FAKE_RC_DIR=%s\nAPM_EUID=0\nAPM_ARCH=x86_64\nAPM_DOWNLOADER=%s\nLC_ALL=en_US.UTF-8\n' "$A" "$K" "$T_TMP/dl-fail"
    printf 'export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER LC_ALL\n'
} > "$ENVF"
DRV=$T_TMP/screen-drv.sh
cat > "$DRV" <<EOD
. $ENVF
# 包装脚本自己不能被 Ctrl-C 杀掉 (用陷阱而不是忽略, 忽略会被子进程继承而无法再捕获)
trap : INT
i=1
while [ \$i -le 30 ]; do echo shell-history-\$i; i=\$((i + 1)); done
stty -g > $T_TMP/stty.before
sh $T_ROOT/bin/proxy-manager tui
echo "tui-rc=\$?"
stty -g > $T_TMP/stty.after
echo AFTER-EXIT
sleep 60
EOD
TS=apscr$$
TERM=xterm
export TERM
cap() { tmux capture-pane -p -t "$TS" 2>/dev/null; }
full() { tmux capture-pane -p -S - -t "$TS" 2>/dev/null; }
altn() { tmux display-message -p -t "$TS" '#{alternate_on}' 2>/dev/null; }
stop() { tmux kill-session -t "$TS" 2>/dev/null; }
waitfor() { # 文字 [秒*10]
    _w=0
    while [ "$_w" -lt "${2:-60}" ]; do cap | grep -q -- "$1" && return 0; sleep 0.1; _w=$((_w + 1)); done
    return 1
}
start() { # 列 行 [额外环境]
    stop
    rm -f "$T_TMP/stty.before" "$T_TMP/stty.after"
    tmux new-session -d -s "$TS" -x "$1" -y "$2" "${3:+$3 }sh $DRV" || return 1
    t_own_tmux "$TS"
    waitfor '请选择：'
    sleep 0.3
}
pick() { for _k in "$@"; do tmux send-keys -t "$TS" -- "$_k" Enter; sleep 0.4; done; }
count_full() { full | grep -c -- "$1" || :; }

start 80 24
assert_eq "运行中: tmux 判断处于备用屏幕" 1 "$(altn)"
assert_contains "运行中: 菜单在屏幕上" "$(cap)" "Alpine Proxy Manager"
assert_not_contains "运行中: 屏幕上没有 shell 历史" "$(cap)" "shell-history"
assert_eq "运行中: 首次启动只有一个标题" 1 "$(cap | grep -c 'Alpine Proxy Manager')"
assert_eq "运行中: 只显示当前版本" 1 "$(cap | grep -c "版本：$(cat "$T_ROOT/VERSION")")"
# 主菜单与子菜单往返 10 次
n=0
while [ "$n" -lt 10 ]; do pick 6 0; n=$((n + 1)); done
sleep 0.5
assert_eq "往返 10 次后: 仍是备用屏幕" 1 "$(altn)"
assert_eq "往返 10 次后: 屏幕上仍只有一个标题" 1 "$(cap | grep -c 'Alpine Proxy Manager')"
assert_eq "往返 10 次后: 一个提示符" 1 "$(cap | grep -c '请选择：')"
assert_not_contains "往返 10 次后: 没有 shell 历史混入" "$(cap)" "shell-history"
# 滚动回看: 备用屏幕没有回滚, 全部历史里看不到菜单
assert_eq "往返 10 次后: 备用屏幕全部内容里只有当前这一份标题 (没有回滚历史)" 1 "$(count_full 'Alpine Proxy Manager')"
# 正常退出
pick 0
sleep 1
assert_eq "退出后: 回到原屏幕" 0 "$(altn)"
assert_eq "退出后: shell 历史完整保留" 30 "$(full | grep -c '^shell-history-')"
assert_contains "退出后: 退出码 0" "$(full)" "tui-rc=0"
assert_contains "退出后: 已退出提示留在原屏幕" "$(full)" "已退出"
assert_eq "退出后: 原屏幕里没有菜单残留" 0 "$(count_full 'Alpine Proxy Manager')"
assert_eq "退出后: 终端设置与进入前一致" "$(cat "$T_TMP/stty.before")" "$(cat "$T_TMP/stty.after")"
assert_eq "退出后: 光标可见" 1 "$(tmux display-message -p -t "$TS" '#{cursor_flag}')"
stop

# 对照: 关闭备用屏幕 (等同 v0.9.3) 往返 10 次后历史里堆满菜单
start 80 24 APM_TUI_ALTSCREEN=0
assert_eq "对照(关闭): 不在备用屏幕" 0 "$(altn)"
n=0
while [ "$n" -lt 10 ]; do pick 6 0; n=$((n + 1)); done
sleep 0.5
more=$(count_full 'Alpine Proxy Manager')
if [ "$more" -ge 5 ]; then t_pass "对照(关闭): 滚动历史里有 $more 份菜单, 与 v0.9.3 现象一致"; else t_fail "对照(关闭): 滚动历史里只有 $more 份菜单, 对照失效"; fi
stop

# ---- 退出路径 ----
printf '== 真实终端: 退出路径\n'
leave_checks() { # 标签
    sleep 1
    assert_eq "$1: 回到原屏幕" 0 "$(altn)"
    assert_eq "$1: shell 历史完整" 30 "$(full | grep -c '^shell-history-')"
    assert_eq "$1: 原屏幕没有菜单残留" 0 "$(count_full 'Alpine Proxy Manager')"
    assert_eq "$1: 终端设置恢复" "$(cat "$T_TMP/stty.before" 2>/dev/null)" "$(cat "$T_TMP/stty.after" 2>/dev/null)"
    assert_contains "$1: 已退出" "$(full)" "已退出"
    assert_eq "$1: 光标可见" 1 "$(tmux display-message -p -t "$TS" '#{cursor_flag}')"
}
start 80 24
tmux send-keys -t "$TS" C-c
leave_checks "Ctrl+C(主菜单)"
assert_contains "Ctrl+C(主菜单): 退出码 130" "$(full)" "tui-rc=130"
stop
start 80 24
pick 6
tmux send-keys -t "$TS" C-c
leave_checks "Ctrl+C(子菜单)"
stop
start 80 24
pick 4 1
sleep 0.3
tmux send-keys -t "$TS" C-c
leave_checks "Ctrl+C(阅读暂停)"
stop
start 80 24
tmux send-keys -t "$TS" C-d
leave_checks "EOF"
stop
# SIGTERM: 目标是 tmux 窗格里的 TUI 进程, 先核对命令行再发送
start 80 24
tuipid=$(for p in /proc/[0-9]*; do
    p=${p#/proc/}
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "proxy-manager tui"; then printf '%s\n' "$p"; fi
done | head -n 1)
if [ -n "$tuipid" ] && [ "$(tr '\0' ' ' < "/proc/$tuipid/cmdline")" != "${tuipid}" ]; then
    kill -TERM "$tuipid"
    leave_checks "SIGTERM"
    assert_contains "SIGTERM: 退出码 143" "$(full)" "tui-rc=143"
else
    t_fail "SIGTERM: 找不到窗格里的 TUI 进程"
fi
stop

# ---- 降级: 不支持的终端类型不使用备用屏幕 ----
printf '== 真实终端: 降级\n'
start 80 24 TERM=linux
assert_eq "TERM=linux: 不在备用屏幕" 0 "$(altn)"
pick 0
stop

# ---- 终端尺寸 ----
printf '== 真实终端: 60 列与 80 列\n'
for cols in 60 80; do
    start "$cols" 30
    assert_eq "${cols} 列: 备用屏幕" 1 "$(altn)"
    pick 1
    scr=$(tmux capture-pane -p -J -t "$TS")
    assert_contains "${cols} 列: Snell 页有配置监听" "$scr" "配置监听："
    assert_contains "${cols} 列: Snell 页有实际监听" "$scr" "实际监听："
    assert_contains "${cols} 列: 配置行完整" "$scr" "TCP  IPv4  0.0.0.0:20000"
    assert_contains "${cols} 列: 状态说明完整" "$scr" "状态说明：实际监听与配置一致"
    assert_contains "${cols} 列: 菜单项完整" "$scr" "9. 卸载"
    assert_contains "${cols} 列: 提示符完整" "$scr" "请选择："
    # 逐行宽度: 窗格里没有被截断的汉字 (tmux 会把超宽字符整体换行, 这里确认关键行没有被拆开)
    assert_not_contains "${cols} 列: 状态说明没有被拆断" "$(tmux capture-pane -p -t "$TS")" "状态说明：实际监听与$"
    pick 0
    stop
done

# ---- 终端尺寸变化 ----
printf '== 真实终端: 尺寸变化\n'
start 80 24
tmux resize-window -t "$TS" -x 60 -y 20
sleep 0.5
pick 6
assert_contains "缩小后: 仍可操作进入子菜单" "$(cap)" "Manager"
pick 0
tmux resize-window -t "$TS" -x 100 -y 40
sleep 0.5
pick 4
assert_contains "放大后: 仍可操作" "$(cap)" "状态与诊断"
pick 0 0
sleep 1
assert_eq "尺寸变化后: 正常退出" 0 "$(altn)"
stop

# ---- 长内容分页 ----
printf '== 真实终端: 长日志分页\n'
start 80 24
pick 5 1
# 日志 30 行 + 提示在 24 行终端里放不下: 第一页有页脚
scr=$(cap)
assert_contains "长日志: 第一页有页脚" "$scr" "回车下一页，Esc 结束"
assert_contains "长日志: 第一页有开头" "$scr" "screen-log-line-01"
assert_not_contains "长日志: 第一页没有末尾" "$scr" "screen-log-line-30"
pages=$(printf '%s\n' "$scr" | sed -n 's/.*第 1\/\([0-9]*\) 页.*/\1/p' | head -n 1)
seen=$scr
n=1
while [ "$n" -lt "${pages:-1}" ]; do
    tmux send-keys -t "$TS" Enter
    sleep 0.4
    seen="$seen
$(cap)"
    n=$((n + 1))
done
miss=0
i=1
while [ "$i" -le 30 ]; do
    ln=$(printf 'screen-log-line-%02d' "$i")
    printf '%s\n' "$seen" | grep -q -- "$ln" || { miss=$((miss + 1)); printf '    缺少 %s\n' "$ln" >&2; }
    i=$((i + 1))
done
assert_eq "长日志: 逐页看完 30 行一行不少" 0 "$miss"
assert_contains "长日志: 看完最后一页停在 按回车返回" "$(cap)" "按回车返回..."
tmux send-keys -t "$TS" Enter
sleep 0.5
assert_contains "长日志: 回车后回到日志菜单" "$(cap)" "Snell 日志"
assert_eq "长日志: 仍在备用屏幕" 1 "$(altn)"
# Esc 在分页中途结束并返回上级菜单, 不再多停一次
pick 1
sleep 0.2
tmux send-keys -t "$TS" Escape
sleep 0.8
assert_contains "长日志: Esc 直接回到日志菜单" "$(cap)" "Snell 日志"
assert_not_contains "长日志: Esc 之后没有多余的 按回车返回" "$(cap)" "按回车返回"
pick 0 0
sleep 1
assert_eq "长日志: 正常退出" 0 "$(altn)"
stop

# 短内容不分页: 一屏放得下原样显示
printf 'short-one\nshort-two\n' > "$A/var/log/snell/error.log"
start 80 40
pick 5 1
scr=$(cap)
assert_contains "短日志: 直接显示" "$scr" "short-two"
assert_not_contains "短日志: 没有分页页脚" "$scr" "回车下一页"
assert_contains "短日志: 停在 按回车返回" "$scr" "按回车返回..."
tmux send-keys -t "$TS" Enter
sleep 0.4
pick 0 0
stop

t_done
