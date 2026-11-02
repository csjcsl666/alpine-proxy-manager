# shellcheck shell=sh
# shellcheck disable=SC2031,SC2030
# TUI 页面渲染: 在真实终端模拟器 (tmux) 里检查当前可见屏幕, 不看滚动历史
# 不变量: 任何时刻屏幕上只有一份页面 (至多一个 "请选择" 提示, 至多一组标题横线), 操作结果在页面顶部出现一次, 返回后旧页面不残留
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui
PM="$T_ROOT/bin/proxy-manager"
if ! command -v tmux >/dev/null 2>&1; then t_skip "没有 tmux, 页面渲染测试跳过"; t_done; exit $?; fi
if ! mk_elf_stub "$T_TMP/probe" "probe"; then t_skip "ELF 桩只支持 x86_64"; t_done; exit $?; fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"
new_s r1
"$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1 <<PSK
TuiSnellPskNotSecret0123456789ab
PSK
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1

TS=apmr$$
cap() { tmux capture-pane -t "$TS" -p; }
key() { tmux send-keys -t "$TS" "$@"; sleep 0.5; }
# 等待屏幕出现某段文字, 最多 6 秒
waitfor() {
    _i=0
    while [ "$_i" -lt 30 ]; do cap | grep -q -F -- "$1" && return 0; sleep 0.2; _i=$((_i + 1)); done
    return 1
}
# 等重绘完成: 屏幕第一行就是结果提示 (操作输出先打印一次, 清屏重绘后才出现在页面顶部)
waitnotice() {
    _i=0
    while [ "$_i" -lt 100 ]; do
        [ "$(cap | head -n 1)" = "$1" ] && cap | grep -q '^请选择' && { sleep 0.3; return 0; }
        sleep 0.2; _i=$((_i + 1))
    done
    printf "  首行实际: [%s]\n" "$(cap | head -n 3 | tr "\n" "|")"
    assert_eq "等到结果提示 $1" ok 超时
    return 1
}
# 当前屏幕只有一份页面
single() { # 说明
    _s=$(cap)
    _p=$(printf '%s\n' "$_s" | grep -c '^请选择')
    _h=$(printf '%s\n' "$_s" | grep -c '^====')
    [ "$_p" -le 1 ] && [ "$_h" -le 2 ] && return 0
    printf '  屏幕:\n%s\n' "$_s" | head -60
    return 1
}
ok() { # 说明
    if single; then assert_eq "$1" ok ok; else assert_eq "$1" ok "页面叠加"; fi
}
has() { assert_contains "$1" "$(cap)" "$2"; }
hasnot() { assert_not_contains "$1" "$(cap)" "$2"; }
count_of() { cap | grep -c -F -- "$1" || true; }

run_matrix() { # 列数 行数
    tmux new-session -d -x "$1" -y "$2" -s "$TS" "APM_TUI_ANSI=1 APM_SYSROOT=$A APM_FAKE_RC_DIR=$K APM_EUID=0 APM_ARCH=x86_64 APM_SNELL_WAIT=1 APM_SB_WAIT=1 APM_TUI_REFRESH=0 LC_ALL=en_US.UTF-8 TERM=xterm-256color sh $T_ROOT/bin/proxy-manager tui"
    waitfor "请选择"
    L="[$1x$2]"
    ok "$L 主菜单"
    # 无效输入: 就地重写提示行, 不重复菜单
    key 9 9 Enter; ok "$L 主菜单无效输入"; assert_eq "$L 无效输入后菜单只有一份" 1 "$(count_of '1. Snell')"; has "$L 无效输入提示" "输入无效"
    # Snell: 连续三次重启
    key 1 Enter; waitfor "3. 重启"; ok "$L 进入 Snell"
    for _n in 1 2 3; do
        key 3 Enter; waitnotice "Snell 已重启并验证"; ok "$L Snell 重启 #$_n"
        assert_eq "$L 重启 #$_n 后 Snell 标题只有一份" 1 "$(count_of ' Snell')"
        assert_eq "$L 重启 #$_n 后结果只出现一次" 1 "$(count_of 'Snell 已重启并验证')"
        hasnot "$L 重启 #$_n 后没有旧提示残留" "请选择：3"
    done
    # 详情页 (报告) 与返回
    key 1 Enter; waitfor "按回车返回"; ok "$L Snell 详情"
    key Enter; waitfor "3. 重启"; ok "$L 详情返回 Snell"; assert_eq "$L 详情返回后标题只有一份" 1 "$(count_of ' Snell')"
    # 停止再启动
    key 2 Enter; waitfor "继续？"; ok "$L Snell 停止确认"
    key Enter; waitnotice "Snell 已停止"; ok "$L Snell 停止"; hasnot "$L 停止后确认提示不残留" "继续？"
    key 2 Enter; waitnotice "Snell 已启动并验证"; ok "$L Snell 启动"
    # 日志
    key 6 Enter; waitfor "按回车返回"; ok "$L Snell 日志"
    key Enter; waitfor "3. 重启"; ok "$L 日志返回 Snell"
    # 修改配置二级菜单与返回
    key 4 Enter; waitfor "返回"; ok "$L Snell 修改配置"
    key 0 Enter; waitfor "3. 重启"; ok "$L 配置返回 Snell"
    # 网络功能二级三级
    key 5 Enter; waitfor "网络"; ok "$L Snell 网络功能"
    key 0 Enter; waitfor "3. 重启"; ok "$L 网络返回 Snell"
    key 0 Enter; waitfor "3. AnyTLS"; ok "$L 返回主菜单"
    hasnot "$L 主菜单没有 Snell 页面残留" "监听状态"
    # sing-box
    key 2 Enter; waitfor "返回"; ok "$L 进入 sing-box"
    key 0 Enter; waitfor "3. AnyTLS"; ok "$L sing-box 返回主菜单"; hasnot "$L 主菜单没有 sing-box 残留" "sing-box 管理"
    # AnyTLS Gateway
    key 3 Enter; waitfor "返回"; ok "$L 进入 AnyTLS Gateway"
    key 0 Enter; waitfor "3. AnyTLS"; ok "$L AnyTLS 返回主菜单"
    # 状态与诊断: 重复查看
    for _n in 1 2; do key 4 Enter; waitfor "返回"; ok "$L 状态与诊断 #$_n"; key 0 Enter; waitfor "3. AnyTLS"; ok "$L 状态返回 #$_n"; done
    # 日志菜单
    key 5 Enter; waitfor "返回"; ok "$L 日志菜单"
    key 0 Enter; waitfor "3. AnyTLS"; ok "$L 日志返回"
    # Manager
    key 6 Enter; waitfor "返回"; ok "$L Manager 菜单"
    key 0 Enter; waitfor "3. AnyTLS"; ok "$L Manager 返回"
    # 反复进出 Snell
    for _n in 1 2 3 4 5; do key 1 Enter; waitfor "3. 重启"; key 0 Enter; waitfor "3. AnyTLS"; done
    ok "$L 反复进出后主菜单"; assert_eq "$L 反复进出后主菜单只有一份" 1 "$(count_of '1. Snell')"
    # 退出: 回到原屏幕
    key 0 Enter; sleep 0.5
    assert_fail "$L 退出后会话结束或回到 shell" tmux has-session -t "$TS"
    tmux kill-session -t "$TS" 2>/dev/null
}
# 终端恢复与 Shell 历史: 在一个真实的 shell 会话里启动 TUI, 切换菜单, 正常退出与 Ctrl-C 后检查
run_shell_restore() {
    _E="APM_TUI_ANSI=1 APM_SYSROOT=$A APM_FAKE_RC_DIR=$K APM_EUID=0 APM_ARCH=x86_64 APM_SNELL_WAIT=1 APM_TUI_REFRESH=0 LC_ALL=en_US.UTF-8 TERM=xterm-256color"
    tmux new-session -d -x 80 -y 24 -s "$TS" "env PS1='\$ ' sh -i"
    sleep 0.5; key "echo history-one" Enter; key "echo history-two" Enter
    key "$_E sh $T_ROOT/bin/proxy-manager tui" Enter; waitfor "请选择"
    key 1 Enter; waitfor "3. 重启"; key 3 Enter; sleep 1.5; key 0 Enter; waitfor "3. AnyTLS"; key 0 Enter; waitfor "已退出" || sleep 1
    _s=$(cap)
    assert_contains "退出后保留原有 Shell 历史 1" "$_s" "history-one"
    assert_contains "退出后保留原有 Shell 历史 2" "$_s" "history-two"
    assert_not_contains "退出后原屏幕没有菜单残留" "$_s" "请选择"
    assert_not_contains "退出后原屏幕没有 Snell 页面" "$_s" "监听状态"
    key "$_E sh $T_ROOT/bin/proxy-manager tui" Enter; waitfor "请选择"; key 1 Enter; waitfor "3. 重启"; key C-c; sleep 1
    key "echo typed-after-ctrlc" Enter
    _s=$(cap)
    assert_not_contains "Ctrl-C 后菜单不在原屏幕" "$_s" "3. 重启"
    assert_eq "Ctrl-C 后输入回显恢复" 2 "$(printf '%s\n' "$_s" | grep -c 'typed-after-ctrlc')"
    tmux kill-session -t "$TS" 2>/dev/null
}
[ "${ONLY:-}" = restore ] && { run_shell_restore; t_done; exit $?; }
run_shell_restore
[ "${ONLY:-}" = 60 ] || run_matrix 80 30
[ "${ONLY:-}" = 80 ] || run_matrix 60 30
t_done
