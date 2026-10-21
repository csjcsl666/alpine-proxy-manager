# shellcheck shell=sh
# 管理员常用任务的最少按键流程: 每个场景用最少的菜单选择完成, 并确认没有多余的确认与等待
# 输入由 stdin 驱动, tui_run 不检查 TTY (生产入口 tui_cli 才检查), 业务函数全部走真实实现
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_tui.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
CFGSUM() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
# 在子 shell 里运行 TUI, 避免它的 trap 覆盖测试框架的清理
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }
# 服务端证书用真实 openssl 生成, 客户端导出按真实证书解析 TLS 服务名
APM_FAKE_REAL_CERT=1
export APM_FAKE_REAL_CERT
ready() { new_s "$1"; if [ -x /usr/bin/openssl ]; then mkdir -p "$A/usr/bin"; printf '#!/bin/sh\nexec /usr/bin/openssl "$@"\n' > "$A/usr/bin/openssl"; chmod +x "$A/usr/bin/openssl"; fi; "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1 <<EOF
TuiSnellPskNotSecret0123456789ab
EOF
    "$PM" sing-box install >/dev/null 2>&1; }
leaks() {
    grep -rlF -- "$1" "$A" 2>/dev/null | while IFS= read -r f; do
        ok=0
        for a in $2; do
            # shellcheck disable=SC2254
            case $f in $a) ok=1 ;; esac
        done
        [ "$ok" = 1 ] || printf '%s\n' "$f"
    done
}
export APM_TUI_ANSI=0
# 默认下载器: 总是失败的 mock, TUI 测试绝不访问真实网络 (需要成功结果的用例自己指定 APM_DOWNLOADER)
printf '#!/bin/sh\nexit 1\n' > "$T_TMP/dl-fail"
chmod +x "$T_TMP/dl-fail"
APM_DOWNLOADER=$T_TMP/dl-fail
export APM_DOWNLOADER
LC_ALL=en_US.UTF-8
export LC_ALL

# ---- 主菜单 ----
ready t1
out=$(T '0\n')
assert_contains "主菜单标题" "$out" "Alpine Proxy Manager"
assert_contains "主菜单版本" "$out" "版本：$(cat "$T_ROOT/VERSION")"
assert_contains "主菜单 Build" "$out" "Build："
for item in "1. Snell" "2. sing-box" "3. AnyTLS Gateway" "4. 状态与诊断" "5. 日志" "6. Manager 管理" "0. 退出"; do
    assert_contains "主菜单项 $item" "$out" "$item"
done
mainmenu=$(printf '%s\n' "$out" | sed -n '/^请选择/q;/^----/,$p')
ready f1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20500 >/dev/null 2>&1
printf 'FlowSocksPw0123456789abcdef\n' | "$PM" sing-box socks add --server 192.0.2.10 --port 1080 --username u1 --password-stdin --name SOCKS-01 >/dev/null 2>&1
"$PM" sing-box endpoint AnyTLS-01 set vpn.example.com 20443 >/dev/null 2>&1
mkdir -p "$A/var/log/sing-box"; printf 'flow-log-line\n' > "$A/var/log/sing-box/error.log"
APW=$(kv_get "$(INST AnyTLS-01)" credential.password)

# flow 名称 菜单选择(空格分隔, 数字就是真实按键数) 期望出现的文字 [期望按键数]
flow() {
    _n=$1; _keys=$2; _want=$3; _cnt=$4
    # shellcheck disable=SC2086
    _in=$(printf '%s\n' $_keys; printf '0\n0\n0\n0\n0\n')
    _out=$(printf '%s' "$_in" | ( tui_run ) 2>&1)
    assert_contains "流程 $_n" "$_out" "$_want"
    # shellcheck disable=SC2086
    assert_eq "流程 $_n 的按键数" "$_cnt" "$(printf '%s\n' $_keys | wc -l | tr -d ' ')"
    assert_not_contains "流程 $_n 没有确认" "$_out" "继续？[Y/n]"
    assert_not_contains "流程 $_n 没有等待 Enter" "$_out" "按 Enter 返回"
    FLOW_OUT=$_out
}
flow "查看完整连接信息" "2 1 5 1" "密码：$APW" 4
flow "导出 sing-box JSON" "2 1 5 2" '"type": "anytls"' 4
flow "获取分享 URL" "2 1 5 3" "anytls://" 4
flow "查看实例与实际出口" "2" "AnyTLS-01  AnyTLS  监听端口 20443" 1
flow "排查: 诊断详情" "2 9" "服务：sing-box (OpenRC" 2
flow "排查: 查看日志" "2 7" "flow-log-line" 2
flow "Snell 配置与 PSK" "1 7" "PSK：TuiSnellPskNotSecret0123456789ab" 2
flow "Snell 详情" "1 1" "配置内容：监听地址" 2
flow "故障切换状态" "2 4 4" "自动故障切换" 3
flow "状态总览" "4 1" "SOCKS5 出口：" 2
RB=$(grep -c 'sing-box.*restart' "$K/calls" 2>/dev/null || true)
flow "重启 sing-box" "2 6" "sing-box" 2
assert_eq "重启 sing-box 选择即执行" "$((RB + 1))" "$(grep -c 'sing-box.*restart' "$K/calls" 2>/dev/null || true)"
flow "禁用实例" "2 2 1" "实例 Hysteria2-01 已禁用" 3
assert_eq "禁用后确实禁用" false "$(kv_get "$(INST Hysteria2-01)" enabled)"
flow "启用实例" "2 2 1" "实例 Hysteria2-01 已启用" 3
assert_eq "启用后确实启用" true "$(kv_get "$(INST Hysteria2-01)" enabled)"
flow "分配上游" "2 4 2 1 1" "SOCKS-01" 5
assert_eq "上游已分配" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
flow "修改监听端口" "2 1 2" "监听端口" 3

# 修改客户端地址与端口: 菜单 4 次选择 + 地址与端口输入
_out=$(printf '2\n1\n5\n5\nnew.example.com\n8443\n0\n0\n0\n0\n' | ( tui_run ) 2>&1)
assert_eq "修改客户端地址: 地址" new.example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_eq "修改客户端地址: 端口" 8443 "$(kv_get "$(INST AnyTLS-01)" public.port)"

# 每个页面都有明确的返回: 连续输入 0 可以逐级回到主菜单并退出
_out=$(printf '2\n1\n5\n0\n0\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "逐级返回直到退出" "$_out" "已退出"

# 输入错误后留在当前页重新选择, 不回主菜单
_out=$(printf '2\nxx\n99\n0\n0\n' | ( tui_run ) 2>&1)
assert_contains "无效输入提示" "$_out" "输入无效，请重新选择"
assert_eq "无效输入后停在当前页重新选择, 不重画整页" 1 "$(printf '%s\n' "$_out" | grep -c '^ sing-box$')"

# 窄终端: 页面内容不依赖终端宽度, 每行都是完整的文字行 (不做硬换行或截断)
_out=$(COLUMNS=40 printf '2\n1\n5\n1\n0\n0\n0\n0\n' | ( COLUMNS=40; export COLUMNS; tui_run ) 2>&1)
assert_contains "窄终端: 仍能看到完整密码" "$_out" "密码：$APW"

# 真实终端 (tmux): 逐键模式下按 2 1 5 1 直接看到完整连接信息, 宽窄两种窗口
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
    ptyrun() { # 宽 高 按键...
        _w=$1; _h=$2; shift 2
        tmux kill-session -t apmflow$$ 2>/dev/null
        tmux new-session -d -s apmflow$$ -x "$_w" -y "$_h" "sh $DRV" || return 1
        _i=0
        while [ "$_i" -lt 50 ] && ! tmux capture-pane -p -t apmflow$$ | grep -q '请选择：'; do sleep 0.1; _i=$((_i + 1)); done
        sleep 0.5
        for _k in "$@"; do tmux send-keys -t apmflow$$ -- "$_k"; sleep 0.4; done
        sleep 1
        tmux capture-pane -p -S -200 -t apmflow$$
        tmux kill-session -t apmflow$$ 2>/dev/null
    }
    scr=$(ptyrun 100 40 2 1 Enter 5 1)
    assert_contains "真实终端 100 列: 选 2 再选 1 号实例 (等同 Enter) 后按 5 1 看到完整连接信息" "$scr" "密码：$APW"
    scr=$(ptyrun 50 40 2 1 Enter 5 1)
    assert_contains "真实终端 50 列: 同样可用" "$scr" "客户端连接信息 AnyTLS-01"
    scr=$(ptyrun 100 40 2 1 Enter 5 2)
    assert_contains "真实终端: 两次选择后得到 JSON" "$scr" '"type": "anytls"'
    scr=$(ptyrun 100 40 2 2 1)
    assert_contains "真实终端: 三次按键禁用实例且没有任何确认" "$scr" "实例 Hysteria2-01 已禁用"
    "$PM" sing-box enable Hysteria2-01 >/dev/null 2>&1
    # 单键可靠性: 一次性到达的多个字符只取第一个, 其余丢弃, 不会顺势变成下一个菜单的操作
    ptyburst() { # 字面字符串 (一次写入)
        tmux kill-session -t apmflow$$ 2>/dev/null
        tmux new-session -d -s apmflow$$ -x 100 -y 40 "sh $DRV" || return 1
        _i=0
        while [ "$_i" -lt 50 ] && ! tmux capture-pane -p -t apmflow$$ | grep -q '请选择：'; do sleep 0.1; _i=$((_i + 1)); done
        sleep 0.5
        tmux send-keys -t apmflow$$ -l -- "$1"
        sleep 1
        tmux capture-pane -p -S -200 -t apmflow$$
        tmux kill-session -t apmflow$$ 2>/dev/null
    }
    scr=$(ptyburst 21)
    assert_contains "粘贴 21: 只进入 sing-box 页" "$scr" "管理 AnyTLS-01"
    assert_not_contains "粘贴 21: 第二个字符没有变成下一页的操作" "$scr" "客户端连接信息"
    assert_not_contains "粘贴 21: 丢弃的字符不产生无效输入提示" "$scr" "输入无效"
    scr=$(ptyrun 100 40 Up Down 2 0)
    assert_not_contains "方向键: 不产生无效输入提示" "$scr" "输入无效"
    assert_contains "方向键: 之后的选择照常" "$scr" "管理 AnyTLS-01"
    scr=$(ptyrun 100 40 2 Escape)
    assert_eq "单独 Esc 等同返回: 回到主菜单, sing-box 页只出现一次" 1 "$(printf '%s\n' "$scr" | grep -c '管理 AnyTLS-01')"
    assert_contains "单独 Esc 返回后仍在主菜单" "$scr" "状态与诊断"
else
    t_skip "没有 tmux, 真实终端流程测试跳过 (apk add tmux)"
fi
t_done
