# shellcheck shell=sh
# 阅读暂停: 零确认不等于零停留. 需要阅读的独立信息页输出完成后必须停在 按回车返回, 用户按回车才回到上级菜单
# 管道驱动用 APM_TUI_PAUSE=1 打开阅读暂停 (每个暂停消耗一行输入), 真实终端用 tmux 证明不按回车就不会返回
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_tui_reading.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL
printf '#!/bin/sh\nexit 1\n' > "$T_TMP/dl-fail"
chmod +x "$T_TMP/dl-fail"
APM_DOWNLOADER=$T_TMP/dl-fail
export APM_DOWNLOADER

new_s r1
"$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1 <<EOF
ReadPauseSnellPsk0123456789abcdef
EOF
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box endpoint AnyTLS-01 set vpn.example.com 20443 >/dev/null 2>&1
mkdir -p "$A/var/log/sing-box" "$A/var/log/snell"
printf 'read-pause-log-line\n' > "$A/var/log/sing-box/error.log"

P() { printf '%b' "$1" | ( APM_TUI_PAUSE=1; export APM_TUI_PAUSE; tui_run ) 2>&1; }
count() { printf '%s\n' "$1" | grep -c -- "$2" || :; }

# ---- 管道驱动: 页面之后有 按回车返回, 吃掉一行输入, 然后才是上级菜单 ----
# 状态与诊断(4) 状态总览(1) 回车 返回(0) 退出(0)
out=$(P '4\n1\n\n0\n0\n')
assert_contains "状态总览: 提示按回车返回" "$out" "按回车返回..."
assert_contains "状态总览: 有内容" "$out" "Snell"
# 输出之后紧跟提示, 提示之后才出现第二次 状态与诊断 菜单
n_menu=$(count "$out" '状态总览（服务、功能、资源）')
assert_eq "状态总览: 回车前菜单只出现一次, 回车后又出现一次" 2 "$n_menu"
# 没有回车: 输入在状态总览后结束 (EOF), 不得无限阻塞也不得重复输出内容
out=$(P '4\n1\n')
assert_contains "状态总览: 无回车时停在提示" "$out" "按回车返回..."
assert_eq "状态总览: EOF 时只重画一次菜单并退出, 不会死循环" 2 "$(count "$out" '状态总览（服务、功能、资源）')"
assert_contains "状态总览: EOF 后正常退出" "$out" "已退出"

# doctor
out=$(P '4\n2\n\n0\n0\n')
assert_contains "doctor: 提示按回车返回" "$out" "按回车返回..."

# Snell 详细信息 (1): 重复进入多次, 每次都要一个回车, 菜单不会在没有回车时自动重复
out=$(P '1\n1\n\n1\n\n0\n0\n')
assert_eq "Snell 详细信息: 两次进入各有一次提示" 2 "$(count "$out" '按回车返回\.\.\.')"
out=$(P '1\n1\n1\n1\n')
assert_eq "Snell 详细信息: 管道里每个提示各消耗一行, 不会因为后面还有输入就自动连续追加" 2 "$(count "$out" '按回车返回\.\.\.')"

# 其他只读页: Snell 日志 客户端信息, sing-box 日志与诊断详情, 日志菜单, Manager 帮助
for seq in '1\n6\n\n0\n0\n' '1\n8\n\n0\n0\n' '5\n2\n\n0\n0\n' '5\n1\n\n0\n0\n' '6\n3\n\n0\n0\n'; do
    out=$(P "$seq")
    assert_contains "只读页 $(printf '%s' "$seq" | tr '\n' ' ') 有阅读暂停" "$out" "按回车返回..."
done

# 不开启阅读暂停 (管道默认) 完全不提示, 也不消耗输入
out=$(printf '4\n1\n0\n0\n' | ( tui_run ) 2>&1)
assert_not_contains "管道默认: 不出现阅读暂停" "$out" "按回车返回..."
assert_contains "管道默认: 脚本照常走完" "$out" "已退出"

# ---- 菜单归属: 全局状态与诊断没有保护入口, Snell 的 网络功能 里有两项 ----
out=$(P '4\n0\n0\n')
assert_not_contains "状态与诊断: 没有网络与进程保护入口" "$out" "网络与进程保护"
assert_not_contains "状态与诊断: 没有旧名称" "$out" "低内存环境保护"
out=$(P '1\n0\n0\n')
assert_contains "Snell 菜单仍有 网络功能" "$out" ". 网络功能"
nn=$(printf '%s\n' "$out" | sed -n 's/^\([0-9]*\)\. 网络功能$/\1/p' | head -n 1)
case $nn in [1-9]) _ok=1 ;; *) _ok=0 ;; esac
assert_eq "Snell 菜单: 网络功能 有编号 ($nn)" 1 "$_ok"
out=$(P "1\n$nn\n0\n0\n0\n")
assert_contains "网络功能下一级: Snell 网络功能" "$out" "1. Snell 网络功能（SOCKS5 出口、目标访问限制）"
assert_contains "网络功能下一级: 网络与进程保护" "$out" "2. 网络与进程保护（低内存环境）"
out=$(P "1\n$nn\n1\n0\n0\n0\n0\n")
assert_contains "原 Snell 网络功能可达" "$out" "Snell · SOCKS5 出口与目标访问限制"
out=$(P "1\n$nn\n2\n0\n0\n0\n0\n")
assert_contains "网络与进程保护页可达" "$out" "Snell · 网络与进程保护（低内存环境）"
# ---- 真实终端 (tmux) ----
if command -v tmux >/dev/null 2>&1; then
    mkdir -p "$A/usr/bin"
    ln -sf "$(command -v stty)" "$A/usr/bin/stty"
    DRV=$T_TMP/drv.sh
    cat > "$DRV" <<EOD
APM_SYSROOT=$A
APM_TUI_ANSI=1
LC_ALL=en_US.UTF-8
export APM_SYSROOT APM_TUI_ANSI LC_ALL
exec sh $T_ROOT/bin/proxy-manager tui
EOD
    S=aprd$$
    start() { # 固定 100x40
        tmux kill-session -t "$S" 2>/dev/null
        tmux new-session -d -s "$S" -x 100 -y 40 "sh $DRV" || return 1
        _i=0
        while [ "$_i" -lt 50 ] && ! tmux capture-pane -p -t "$S" | grep -q '请选择：'; do sleep 0.1; _i=$((_i + 1)); done
        sleep 0.5
    }
    keys() { for _k in "$@"; do tmux send-keys -t "$S" -- "$_k"; settle; done; }
    # 菜单选择: 数字加 Enter (D154); 阅读暂停里的键用 keys 直接发
    settle() {
        _sp=; _sn=0; _st=0
        while [ "$_st" -lt 80 ]; do
            sleep 0.1; _st=$((_st + 1))
            _sc=$(tmux capture-pane -p -t "$S" 2>/dev/null | cksum)
            if [ "$_sc" = "$_sp" ]; then _sn=$((_sn + 1)); [ "$_sn" -ge 3 ] && break; else _sn=0; _sp=$_sc; fi
        done
    }
    pick() { for _k in "$@"; do tmux send-keys -t "$S" -- "$_k"; settle; tmux send-keys -t "$S" -- Enter; settle; done; }
    pane() { tmux capture-pane -p -S -300 -t "$S"; }
    stop() { tmux kill-session -t "$S" 2>/dev/null; }
    pcount() { pane | grep -c -- "$1" || :; }

    # 状态总览: 按 4 1 后停在提示, 等 3 秒仍然没有菜单; 回车后才返回
    start
    pick 4 1
    sleep 3
    scr=$(pane)
    assert_contains "tmux 状态总览: 停在 按回车返回" "$scr" "按回车返回..."
    assert_eq "tmux 状态总览: 3 秒后没有自动出现菜单 (菜单只有进入时的一次)" 1 "$(printf '%s\n' "$scr" | grep -c '状态总览（服务、功能、资源）')"
    keys Enter
    sleep 0.5
    scr=$(pane)
    assert_contains "tmux 状态总览: 回车后回到状态与诊断菜单" "$scr" "doctor 环境检查"
    stop

    # Snell 详细信息: 连续进入, 未按回车时字符不会把菜单追加出来
    start
    pick 1 1
    sleep 3
    assert_contains "tmux Snell 详细信息: 停在提示" "$(pane)" "按回车返回..."
    assert_eq "tmux Snell 详细信息: 3 秒后菜单没有重复 (只有进入时的一次)" 1 "$(pcount '查看详细信息')"
    # 阅读暂停里按数字 方向键 都不返回
    keys 1 1 Up Down
    sleep 1
    assert_eq "tmux Snell 详细信息: 数字与方向键不会返回也不会追加菜单" 1 "$(pcount '查看详细信息')"
    keys Enter
    sleep 0.5
    assert_eq "tmux Snell 详细信息: 回车后回到 Snell 菜单" 2 "$(pcount '查看详细信息')"
    # 重复进入: 1 回车 1 回车
    pick 1; keys Enter; pick 1; keys Enter
    sleep 0.5
    assert_eq "tmux Snell 详细信息: 反复进入每次都要回车 (每次回车后各出现一次菜单)" 4 "$(pcount '查看详细信息')"
    stop

    # 单独 Esc 也可结束阅读暂停; Esc 返回菜单规则不变
    start
    pick 4 1
    sleep 1
    keys Escape
    sleep 0.6
    assert_contains "tmux Esc 结束阅读暂停回到上级菜单" "$(pane)" "doctor 环境检查"
    keys Escape
    sleep 0.6
    vis=$(tmux capture-pane -p -t "$S")
    assert_contains "tmux 之后的 Esc 仍是返回: 当前画面是主菜单" "$vis" "6. Manager 管理"
    assert_not_contains "tmux 之后的 Esc 仍是返回: 不在状态与诊断" "$vis" "doctor 环境检查"
    stop

    # 阅读暂停期间键入的字符 (包括粘贴) 不会结束暂停, 暂停前已到达的残余输入也不会跳过它
    start
    pick 4 1
    tmux send-keys -t "$S" -l -- "xyz"
    sleep 1.5
    assert_contains "tmux 阅读暂停期间键入的字符不会结束暂停" "$(pane)" "按回车返回..."
    stop

    # 无 stty: 退回整行输入, 阅读暂停仍然等待回车
    rm -f "$A/usr/bin/stty"
    start
    keys 4 Enter 1 Enter
    sleep 2
    assert_contains "tmux 无 stty: 仍停在提示" "$(pane)" "按回车返回..."
    keys Enter
    sleep 0.5
    assert_contains "tmux 无 stty: 回车后返回" "$(pane)" "doctor 环境检查"
    stop
    ln -sf "$(command -v stty)" "$A/usr/bin/stty"
else
    t_skip "没有 tmux, 真实终端阅读暂停测试跳过 (apk add tmux)"
fi

t_done
