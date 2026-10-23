# shellcheck shell=sh
# 测试拥有的进程与终端会话: 登记, 收尾时只回收这些
# 目的: 测试正常结束 失败 超时 被中断时, 自己创建的后台进程与 tmux 会话都被收回, 不留在开发电脑上
# 规则
#   只回收 登记过的 PID (并且启动时间和登记时一致, 防止 PID 被复用后误杀别的进程) 与登记过的 tmux 会话名
#   不按进程名或命令行匹配, 不使用 pkill killall 或 tmux kill-server
#   先 TERM 后等待, 仍存活才 KILL 这一个 PID
# 登记目录由 $T_REG 指定; run.sh 为整次运行共用一个目录, 每个测试文件结束后再回收一次

# 进程启动时间 (/proc/PID/stat 第 22 个字段; 进程名里可能有空格与括号, 先去掉最后一个右括号之前的部分)
_t_starttime() {
    local _s
    _s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    _s=${_s##*) }
    # shellcheck disable=SC2086
    set -- $_s
    printf '%s' "${20:-}"
}

# 登记一个由本测试创建的进程
t_own_pid() { # PID
    local _st
    [ -n "${T_REG:-}" ] && [ -d "$T_REG" ] || return 0
    _st=$(_t_starttime "$1") || return 0
    printf '%s %s\n' "$1" "$_st" > "$T_REG/pid.$1"
}

# 登记一个由本测试创建的 tmux 会话
t_own_tmux() { # 会话名
    [ -n "${T_REG:-}" ] && [ -d "$T_REG" ] || return 0
    : > "$T_REG/tmux.$1"
}

# 回收登记目录里仍然存在的进程与会话, 输出被回收的数量; 返回 0
t_reap_dir() { # 目录
    local _f _pid _st _now _n _i _name
    _n=0
    for _f in "$1"/pid.*; do
        [ -f "$_f" ] || continue
        read -r _pid _st < "$_f"
        _now=$(_t_starttime "$_pid") || { rm -f "$_f"; continue; }
        if [ "$_now" = "$_st" ]; then
            kill -TERM "$_pid" 2>/dev/null
            _i=0
            while [ "$_i" -lt 20 ] && [ "$(_t_starttime "$_pid" 2>/dev/null)" = "$_st" ]; do sleep 0.1; _i=$((_i + 1)); done
            if [ "$(_t_starttime "$_pid" 2>/dev/null)" = "$_st" ]; then kill -KILL "$_pid" 2>/dev/null; fi
            _n=$((_n + 1))
        fi
        rm -f "$_f"
    done
    for _f in "$1"/tmux.*; do
        [ -f "$_f" ] || continue
        _name=${_f##*/tmux.}
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$_name" 2>/dev/null; then
            tmux kill-session -t "$_name" 2>/dev/null
            _n=$((_n + 1))
        fi
        rm -f "$_f"
    done
    printf '%s' "$_n"
}

# 测试里所有 tmux new-session 自动登记会话名 (-s NAME); 其余子命令原样透传
# 这样被超时杀掉或中断的测试不会把 tmux 会话与里面的程序留在开发电脑上
tmux() {
    local _a _prev
    if [ "${1:-}" = new-session ]; then
        _prev=
        for _a in "$@"; do
            [ "$_prev" != -s ] || { t_own_tmux "$_a"; break; }
            _prev=$_a
        done
    fi
    command tmux "$@"
}
