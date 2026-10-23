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
    # 真实终端的节奏由画面决定, 不由睡眠决定:
    #   按键写成 键=期望文字 时, 发完键必须等到期望的页面出现 (最多 15 秒, 超时记一行 PTY 超时 并停止后续按键, 防止按键错位), 再等画面稳定
    #   没有写期望文字的键 (例如只输入数字) 只等画面稳定: 连续三次轮询 (0.1 秒一次) 不变才算, 最多 8 秒
    #   键间隔测试 (ptyseq) 本来就要精确控制时间, 不使用它
    settle() {
        _sp=; _sn=0; _st=0
        while [ "$_st" -lt 80 ]; do
            sleep 0.1; _st=$((_st + 1))
            _sc=$(tmux capture-pane -p -t apmflow$$ 2>/dev/null | cksum)
            if [ "$_sc" = "$_sp" ]; then _sn=$((_sn + 1)); [ "$_sn" -ge 3 ] && break; else _sn=0; _sp=$_sc; fi
        done
    }
    ptywait() { # 期望文字
        _pw=0
        while [ "$_pw" -lt 150 ]; do
            tmux capture-pane -p -t apmflow$$ 2>/dev/null | grep -qF -- "$1" && return 0
            sleep 0.1; _pw=$((_pw + 1))
        done
        return 1
    }
    ptystart() { # 宽 高
        tmux kill-session -t apmflow$$ 2>/dev/null
        tmux new-session -d -s apmflow$$ -x "$1" -y "$2" "sh $DRV" || return 1
        ptywait '请选择：' || return 1
        settle
    }
    ptyrun() { # 宽 高 按键[=期望文字]...
        _w=$1; _h=$2; shift 2
        ptystart "$_w" "$_h" || { echo "PTY 超时: 主菜单没有出现"; return 0; }
        _bad=
        for _k in "$@"; do
            _key=${_k%%=*}
            _exp=
            case $_k in *=*) _exp=${_k#*=} ;; esac
            tmux send-keys -t apmflow$$ -- "$_key"
            if [ -n "$_exp" ]; then
                ptywait "$_exp" || { _bad="PTY 超时: 按 $_key 后没有出现 [$_exp]"; break; }
            fi
            settle
        done
        sleep 0.3
        tmux capture-pane -p -S -200 -t apmflow$$
        [ -z "$_bad" ] || echo "$_bad"
        tmux kill-session -t apmflow$$ 2>/dev/null
    }
    scr=$(ptyrun 100 40 2 "Enter=管理 AnyTLS-01" 1 "Enter=AnyTLS-01 · AnyTLS" 5 "Enter=客户端配置 · AnyTLS-01" 1 "Enter=按回车返回")
    assert_contains "真实终端 100 列: 每次选择都是数字加 Enter, 2 1 5 1 后看到完整连接信息" "$scr" "密码：$APW"
    scr=$(ptyrun 50 40 2 "Enter=管理 AnyTLS-01" 1 "Enter=AnyTLS-01 · AnyTLS" 5 "Enter=客户端配置 · AnyTLS-01" 1 "Enter=按回车返回")
    assert_contains "真实终端 50 列: 同样可用" "$scr" "客户端连接信息 AnyTLS-01"
    scr=$(ptyrun 100 40 2 "Enter=管理 AnyTLS-01" 1 "Enter=AnyTLS-01 · AnyTLS" 5 "Enter=客户端配置 · AnyTLS-01" 2 "Enter=按回车返回")
    assert_contains "真实终端: 同样的流程选 2 得到 JSON" "$scr" '"type": "anytls"'
    scr=$(ptyrun 100 40 2 "Enter=管理 AnyTLS-01" 2 "Enter=Hysteria2-01 · Hysteria2" 1 "Enter=已禁用")
    assert_contains "真实终端: 三次选择 (数字加 Enter) 禁用实例且没有额外确认" "$scr" "实例 Hysteria2-01 已禁用"
    "$PM" sing-box enable Hysteria2-01 >/dev/null 2>&1
    # 输入可靠性: 数字只进入输入行, Enter 才提交; 粘贴的多行只取第一行, 其余丢弃
    ptyburst() { # 字面字符串 [期望文字]  (一次写入; 有期望文字时等它出现, 再等画面稳定, 之后还有多余的跳转会被截图抓到)
        ptystart 100 40 || { echo "PTY 超时: 主菜单没有出现"; return 0; }
        tmux send-keys -t apmflow$$ -l -- "$1"
        if [ -n "${2:-}" ]; then ptywait "$2" || echo "PTY 超时: 粘贴后没有出现 [$2]"; fi
        settle
        sleep 0.5
        settle
        tmux capture-pane -p -S -200 -t apmflow$$
        tmux kill-session -t apmflow$$ 2>/dev/null
    }
    scr=$(ptyrun 100 40 2)
    assert_not_contains "只输入数字不跳转" "$scr" "管理 AnyTLS-01"
    assert_contains "输入的数字显示在输入行" "$scr" "请选择：2"
    scr=$(ptyrun 100 40 2 BSpace 1)
    assert_contains "Backspace 能删掉输入再改" "$scr" "请选择：1"
    scr=$(ptyrun 100 40 2 BSpace 2 "Enter=管理 AnyTLS-01")
    assert_contains "改正后 Enter 进入对应页" "$scr" "管理 AnyTLS-01"
    scr=$(ptyrun 100 40 Enter Enter Enter)
    assert_not_contains "没有输入时 Enter 不执行任何默认项" "$scr" "输入无效"
    assert_eq "没有输入时 Enter 不进入任何菜单" 0 "$(printf '%s\n' "$scr" | grep -c '管理 AnyTLS-01')"
    scr=$(ptyrun 100 40 9 "Enter=输入无效")
    assert_contains "无效选项给出提示且不执行任何功能" "$scr" "输入无效"
    scr=$(ptyrun 100 40 0)
    assert_not_contains "0 也要 Enter 才返回: 只输入 0 不退出" "$scr" "已退出"
    scr=$(ptyrun 100 40 0 Enter)
    assert_eq "0 加 Enter 退出 (程序结束, 终端会话随之关闭)" "" "$(printf '%s' "$scr" | tr -d ' \n')"
    scr=$(ptyburst 21)
    assert_not_contains "粘贴 21 不带 Enter: 不跳转" "$scr" "管理 AnyTLS-01"
    scr=$(ptyburst "$(printf '2\n1\n')" "管理 AnyTLS-01")
    assert_contains "粘贴 2 回车 1 回车: 只进入第一个菜单" "$scr" "管理 AnyTLS-01"
    assert_not_contains "粘贴 2 回车 1 回车: 第二行被丢弃, 没有进入实例页" "$scr" "客户端配置 · AnyTLS-01"
    assert_not_contains "粘贴的多行不产生无效输入提示" "$scr" "输入无效"
    # 长粘贴: 超过一次读取 (原来是 256 字节) 的残余不能变成下一个菜单的输入, 其中合法的编号也不能被执行
    for _n in 300 3000; do
        _junk=$(head -c "$_n" /dev/zero | tr '\0' x)
        scr=$(ptyburst "$(printf '2\n%s\n1\n' "$_junk")" "管理 AnyTLS-01")
        assert_contains "长粘贴 $_n 字节: 只进入第一个菜单" "$scr" "管理 AnyTLS-01"
        assert_not_contains "长粘贴 $_n 字节: 残余没有产生无效输入提示" "$scr" "输入无效"
        assert_not_contains "长粘贴 $_n 字节: 残余里的 1 没有进入实例页" "$scr" "客户端配置 · AnyTLS-01"
    done
    # 两次分开的粘贴: 第二次在第一次处理完之后到达, 照常作为输入 (清理不会吞掉之后的正常输入)
    scr=$(ptyrun 100 40 2 "Enter=管理 AnyTLS-01" 1 "Enter=AnyTLS-01 · AnyTLS")
    assert_contains "清理之后的正常输入照常生效" "$scr" "AnyTLS-01 · AnyTLS"
    scr=$(ptyrun 100 40 Up Down 2 "Enter=管理 AnyTLS-01")
    assert_not_contains "方向键: 不产生无效输入提示" "$scr" "输入无效"
    assert_not_contains "方向键: 不进入输入行" "$scr" "请选择：^"
    assert_contains "方向键: 之后的选择照常" "$scr" "管理 AnyTLS-01"
    scr=$(ptyrun 100 40 2 "Enter=管理 AnyTLS-01" "Escape=6. Manager 管理")
    assert_eq "单独 Esc 等同返回: 回到主菜单, sing-box 页只出现一次" 1 "$(printf '%s\n' "$scr" | grep -c '管理 AnyTLS-01')"
    assert_contains "单独 Esc 返回后仍在主菜单" "$scr" "状态与诊断"
    # 通用: 启动后先执行 PRE 命令 (例如改变窗口尺寸), 再按键, 每个按键之间的等待可指定
    ptyseq() { # 等待秒数 PRE 按键...  (PRE 为 - 表示不做)
        _gap=$1; _pre=$2; shift 2
        tmux kill-session -t apmflow$$ 2>/dev/null
        tmux new-session -d -s apmflow$$ -x 100 -y 40 "sh $DRV" || return 1
        _i=0
        while [ "$_i" -lt 50 ] && ! tmux capture-pane -p -t apmflow$$ | grep -q '请选择：'; do sleep 0.1; _i=$((_i + 1)); done
        sleep 0.5
        [ "$_pre" = - ] || eval "tmux $_pre"
        sleep 0.5
        for _k in "$@"; do tmux send-keys -t apmflow$$ -- "$_k"; sleep "$_gap"; done
        sleep 1.5
        tmux capture-pane -p -S -200 -t apmflow$$
        tmux kill-session -t apmflow$$ 2>/dev/null
    }
    # 终端窗口在菜单等待输入时改变尺寸 (SIGWINCH 不能被当成输入结束或误选)
    scr=$(ptyseq 0.4 "resize-window -t apmflow$$ -x 60 -y 24" 2 Enter)
    assert_contains "窗口尺寸变化后按键仍然有效" "$scr" "管理 AnyTLS-01"
    assert_not_contains "窗口尺寸变化没有让程序退出" "$scr" "已退出"
    # 10 项菜单里的 10: 输入 1 0 再 Enter 才是第 10 项 (卸载), 只输入 1 和 0 不提交, 输入间隔长也不会变成别的项
    scr=$(ptyseq 2 - 2 Enter 1 0)
    assert_not_contains "不按 Enter 的 1 0 不会进入卸载" "$scr" "完整卸载：删除 sing-box"
    scr=$(ptyseq 0.1 - 2 Enter 1 0 Enter)
    assert_contains "1 0 Enter 是第 10 项, 进入卸载选择页 (未执行任何删除)" "$scr" "完整卸载：删除 sing-box"
    scr=$(ptyseq 2 - 2 Enter 1 Enter 0 Enter)
    assert_contains "间隔很长的 1 Enter 0 Enter 是进入实例再返回, 不是第 10 项" "$scr" "管理 AnyTLS-01"
    assert_not_contains "间隔很长的 1 Enter 0 Enter 不进入卸载" "$scr" "完整卸载：删除 sing-box"
    # 缺少 stty: 自动退回整行输入, 单独一个数字不会生效, 必须按 Enter
    rm -f "$A/usr/bin/stty"
    scr=$(ptyseq 0.5 - 2)
    assert_not_contains "无 stty: 单个数字不生效 (整行输入等待 Enter)" "$scr" "管理 AnyTLS-01"
    scr=$(ptyseq 0.5 - 2 Enter)
    assert_contains "无 stty: 数字加 Enter 可用" "$scr" "管理 AnyTLS-01"
    ln -sf "$(command -v stty)" "$A/usr/bin/stty"
else
    t_skip "没有 tmux, 真实终端流程测试跳过 (apk add tmux)"
fi
t_done
