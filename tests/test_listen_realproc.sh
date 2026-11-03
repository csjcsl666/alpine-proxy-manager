# shellcheck shell=sh
# 真实内核版本的受限 /proc 测试, 不用模拟器
# 做法: 把一个真实的监听程序复制成只有执行权限 (0111) 的文件再启动, 内核对读不了自己映像的进程置 dumpable=0,
# 之后没有 CAP_SYS_PTRACE 的调用者 (普通用户, 或没有该能力的容器 root, 例如 us-n-home 与 Docker 默认) 读它的 /proc/PID/fd 链接会被拒绝,
# 与降权运行的 snell 用户进程被容器 root 读取时的拒绝是同一个内核检查 (ptrace_may_access)
# 前提不成立时 (调用者有 CAP_SYS_PTRACE) 跳过, 不伪造结果
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui
unset APM_SYSROOT APM_FAKE_RC_DIR
export APM_TUI_ANSI=0

# 找一个能监听 TCP 的真实 ELF 程序: busybox nc 优先 (Alpine 自带), 其次 python3 (开发电脑)
LK=
BB=$(command -v busybox 2>/dev/null)
if [ -n "$BB" ] && "$BB" nc --help 2>&1 | grep -q -- '-l'; then
    LK=bb
    LBIN=$(readlink -f "$BB")
elif command -v python3 >/dev/null 2>&1; then
    LK=py
    LBIN=$(readlink -f "$(command -v python3)")
fi
if [ -z "$LK" ] || [ "$(head -c 4 "$LBIN" 2>/dev/null | od -An -c | tr -d ' ')" != '177ELF' ]; then
    t_skip "没有可用的 ELF 监听程序 (busybox 或 python3), 真实 /proc 用例跳过"
    t_done
    exit $?
fi
mkdir -p "$T_TMP/real"
cp "$LBIN" "$T_TMP/real/readable-bin"
cp "$LBIN" "$T_TMP/real/hidden-bin"
chmod 755 "$T_TMP/real/readable-bin"
chmod 111 "$T_TMP/real/hidden-bin"

# 空闲端口
pick_port() {
    _p=$(( 41000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000 ))
    if grep -qi ":$(printf '%04X' "$_p") " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then pick_port; else printf '%s' "$_p"; fi
}
PORT=$(pick_port)
PORT2=$(pick_port)

# 启动监听并登记, 设置 _lp 为监听进程的 PID (后台直接 exec 程序, PID 就是监听进程), 最长存活 60 秒
start_listener() { # 程序 端口
    if [ "$LK" = bb ]; then
        "$1" nc -l -p "$2" -s 127.0.0.1 -e /bin/true > /dev/null 2>&1 &
    else
        "$1" -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$2" > /dev/null 2>&1 &
    fi
    _lp=$!
    t_own_pid "$_lp"
    _i=0
    while [ "$_i" -lt 50 ]; do
        grep -qi ":$(printf '%04X' "$2") " /proc/net/tcp 2>/dev/null && return 0
        sleep 0.1
        _i=$((_i + 1))
    done
    return 1
}
fd_readable() { # PID
    for _f in /proc/$1/fd/*; do
        readlink "$_f" >/dev/null 2>&1 && return 0
    done
    return 1
}

printf 'listen = 127.0.0.1:%s\nmode = default\npsk = RealProcPskNotSecret0123456789ab\n' "$PORT" > "$T_TMP/real/snell.conf"
chmod 644 "$T_TMP/real/snell.conf"

discover() { # PID
    CF_INIT_ARGS="-c $T_TMP/real/snell.conf"
    CF_STATE=running
    CF_PID=$1
    CF_NOTES=
    CF_LOG_OUT=
    CF_LOG_ERR=
    core_snell_discover_extra
}

printf '== 对照: 可读映像的监听进程, 归属 pid\n'
if ! start_listener "$T_TMP/real/readable-bin" "$PORT"; then
    t_skip "无法启动监听进程, 真实 /proc 用例跳过"
    t_done
    exit $?
fi
P1=$_lp
assert_eq "前提: 对照进程的 fd 可读" yes "$(fd_readable "$P1" && echo yes || echo no)"
discover "$P1"
assert_eq "对照: 归属 pid" pid "$CF_LISTEN_ATTRIB"
assert_contains "对照: 监听来自内核 /proc/net" "$CF_LISTEN" "tcp 127.0.0.1:$PORT"
kill "$P1" 2>/dev/null
wait "$P1" 2>/dev/null

printf '== 真实受限: 监听进程的 fd 链接不可读\n'
if ! start_listener "$T_TMP/real/hidden-bin" "$PORT"; then
    t_skip "无法启动不可读映像的监听进程, 真实 /proc 用例跳过"
    t_done
    exit $?
fi
P2=$_lp
if fd_readable "$P2"; then
    t_skip "调用者有 CAP_SYS_PTRACE (特权环境), 读得到 fd 链接, 无法构造受限场景, 跳过"
    kill "$P2" 2>/dev/null
    wait "$P2" 2>/dev/null
    t_done
    exit $?
fi
assert_eq "前提: 内核确实拒绝读取 fd 链接" no "$(fd_readable "$P2" && echo yes || echo no)"
discover "$P2"
assert_eq "降级为 config-port" config-port "$CF_LISTEN_ATTRIB"
assert_contains "真实内核: 配置端口在监听" "$CF_LISTEN" "tcp 127.0.0.1:$PORT"
OUT=$(_tui_snell_listen_line)
assert_contains "TUI: 实际监听" "$OUT" "TCP  IPv4  127.0.0.1:$PORT"
assert_contains "TUI: 判定一致" "$OUT" "状态说明：实际监听与配置一致"
assert_contains "TUI: 归属未确认" "$OUT" "未确认归属于该进程"
assert_not_contains "TUI: 不报检测失败" "$OUT" "检测失败"
assert_not_contains "TUI: 不报没有检测到" "$OUT" "实际监听：没有检测到"
assert_contains "CLI 报告: 同一端口" "$(_rpt_listeners)" "$PORT TCP"

printf '== 真实受限: 配置端口没有监听\n'
printf 'listen = 127.0.0.1:%s\nmode = default\npsk = RealProcPskNotSecret0123456789ab\n' "$PORT2" > "$T_TMP/real/snell.conf"
discover "$P2"
assert_eq "没有监听: 降级 config-port" config-port "$CF_LISTEN_ATTRIB"
assert_eq "没有监听: 没有监听信息" "" "$CF_LISTEN"
OUT=$(_tui_snell_listen_line)
assert_contains "没有监听: 指出配置的端口没有在监听" "$OUT" "配置的端口 $PORT2 没有在监听"
assert_not_contains "没有监听: 不报检测失败" "$OUT" "检测失败"

printf '== 真实受限: 服务已停止\n'
CF_STATE=stopped
OUT=$(_tui_snell_listen_line)
assert_contains "停止: 实际监听是没有" "$OUT" "实际监听：服务已停止，没有监听"
kill "$P2" 2>/dev/null
wait "$P2" 2>/dev/null
t_done
