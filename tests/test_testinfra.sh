# shellcheck shell=sh
# 测试基础设施的资源安全: 测试自己创建的进程与终端会话在正常 失败 超时 中断时都被回收, 不留在开发电脑上
# 背景: 一次临时的负载命令 (无退出条件的空转进程 加上在 zsh 里 kill $PIDS 不拆分导致清理失败) 让开发电脑 CPU 满载了一个多小时
# 这里全部用不消耗 CPU 的 sleep 代替空转 (APM_CPULOAD_IDLE=1), 只验证清理与上限逻辑
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
LOAD=$T_ROOT/tests/tools/cpuload.sh
export APM_CPULOAD_IDLE=1

alive() { [ -d "/proc/$1" ] && [ -z "$(sed -n 's/^State:[[:space:]]*Z.*/z/p' "/proc/$1/status" 2>/dev/null)" ]; }
pids_of() { sed -n 's/.*(PID:\(.*\))$/\1/p' "$1"; }
all_gone() { for _p in $1; do alive "$_p" && return 1; done; return 0; }
wait_gone() { # PID列表 最多等待秒数
    _w=0
    while [ "$_w" -lt $(($2 * 10)) ]; do all_gone "$1" && return 0; sleep 0.1; _w=$((_w + 1)); done
    all_gone "$1"
}

printf '== cpuload: 命令正常结束\n'
sh "$LOAD" --workers 1 --seconds 30 -- true 2> "$T_TMP/e1"
rc=$?
P=$(pids_of "$T_TMP/e1")
assert_eq "正常结束: 返回码 0" 0 "$rc"
assert_eq "正常结束: 报告了负载进程" 1 "$([ -n "$P" ] && echo 1 || echo 0)"
assert_eq "正常结束: 负载进程都已退出" yes "$(wait_gone "$P" 3 && echo yes || echo no)"

printf '== cpuload: 命令失败\n'
sh "$LOAD" --workers 1 --seconds 30 -- sh -c 'exit 3' 2> "$T_TMP/e2"
rc=$?
P=$(pids_of "$T_TMP/e2")
assert_eq "命令失败: 返回命令的返回码" 3 "$rc"
assert_eq "命令失败: 负载进程都已退出" yes "$(wait_gone "$P" 3 && echo yes || echo no)"

printf '== cpuload: 运行期间被 TERM 中断\n'
sh "$LOAD" --workers 2 --seconds 60 -- sleep 30 2> "$T_TMP/e3" &
LP=$!
t_own_pid "$LP"
_w=0; while [ "$_w" -lt 50 ] && ! grep -q 'PID:' "$T_TMP/e3" 2>/dev/null; do sleep 0.1; _w=$((_w + 1)); done
P=$(pids_of "$T_TMP/e3")
assert_eq "TERM: 启动了负载进程" 1 "$([ -n "$P" ] && alive "${P%% *}" && echo 1 || echo 0)"
kill -TERM "$LP" 2>/dev/null
wait "$LP" 2>/dev/null
assert_eq "TERM: 负载进程都已退出" yes "$(wait_gone "$P" 3 && echo yes || echo no)"

printf '== cpuload: 被 kill -9 时负载进程仍在时限内自行结束\n'
sh "$LOAD" --workers 1 --seconds 2 -- sleep 30 2> "$T_TMP/e4" &
LP=$!
t_own_pid "$LP"
_w=0; while [ "$_w" -lt 50 ] && ! grep -q 'PID:' "$T_TMP/e4" 2>/dev/null; do sleep 0.1; _w=$((_w + 1)); done
P=$(pids_of "$T_TMP/e4")
kill -KILL "$LP" 2>/dev/null
wait "$LP" 2>/dev/null
assert_eq "kill -9: 负载进程在 2 秒时限后自行退出" yes "$(wait_gone "$P" 6 && echo yes || echo no)"
# 被杀掉的脚本没有机会回收其中的 sleep 命令 (命令是 sleep 30), 这里替它收尾, 只回收这一个已确认的 PID
for _p in $(pgrep -P "$LP" 2>/dev/null); do kill -TERM "$_p" 2>/dev/null; done

printf '== cpuload: 固定在一个 CPU 上\n'
sh "$LOAD" --workers 1 --seconds 30 --pin 0 -- sh -c 'grep -i cpus_allowed_list /proc/self/status' > "$T_TMP/pin.out" 2> "$T_TMP/e6"
assert_eq "被测命令只允许在指定 CPU 上运行" "Cpus_allowed_list:	0" "$(cat "$T_TMP/pin.out")"
P=$(pids_of "$T_TMP/e6")
assert_eq "固定 CPU 时负载进程也都已退出" yes "$(wait_gone "$P" 3 && echo yes || echo no)"
assert_eq "--pin 超出范围时拒绝" 2 "$(sh "$LOAD" --pin 9999 -- true >/dev/null 2>&1; echo $?)"

printf '== cpuload: 上限写死\n'
sh "$LOAD" --workers 99 --seconds 9999 -- true 2> "$T_TMP/e5"
n=$(pids_of "$T_TMP/e5" | wc -w | tr -d ' ')
assert_eq "进程数不超过 2" 1 "$([ "$n" -ge 1 ] && [ "$n" -le 2 ] && echo 1 || echo 0)"
assert_contains "进程数被降低时有说明" "$(cat "$T_TMP/e5")" "超过上限"
assert_contains "持续时间被降低时有说明" "$(cat "$T_TMP/e5")" "超过上限 600"
assert_eq "没有命令时拒绝" 2 "$(sh "$LOAD" --seconds 1 >/dev/null 2>&1; echo $?)"
assert_eq "参数不是数字时拒绝" 2 "$(sh "$LOAD" --workers x -- true >/dev/null 2>&1; echo $?)"

printf '== 登记与回收: 只回收登记且身份确认的进程\n'
D=$T_TMP/reg
mkdir -p "$D"
sleep 60 &
OWN=$!
sleep 60 &
OTHER=$!
T_REG=$D t_own_pid "$OWN"
# 记录里的启动时间被改成不匹配 (模拟 PID 被别的进程复用): 不能回收
printf '%s 1\n' "$OTHER" > "$D/pid.$OTHER"
n=$(t_reap_dir "$D")
assert_eq "回收了登记的那一个" 1 "$n"
sleep 0.3
assert_eq "登记的进程已退出" no "$(alive "$OWN" && echo yes || echo no)"
assert_eq "启动时间不匹配的进程没有被回收" yes "$(alive "$OTHER" && echo yes || echo no)"
assert_eq "登记文件已清除" 0 "$(ls "$D" | wc -l | tr -d ' ')"
kill -TERM "$OTHER" 2>/dev/null
wait "$OWN" "$OTHER" 2>/dev/null

if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s "apminfra$$" "sleep 60"
    assert_eq "tmux new-session 自动登记会话名" 1 "$(ls "$T_REG" | grep -c "tmux.apminfra$$")"
    assert_eq "会话存在" yes "$(command tmux has-session -t "apminfra$$" 2>/dev/null && echo yes)"
    n=$(t_reap_dir "$T_REG")
    assert_eq "回收了会话" yes "$(command tmux has-session -t "apminfra$$" 2>/dev/null && echo no || echo yes)"
else
    t_skip "没有 tmux, 会话登记用例跳过"
fi

printf '== 测试文件没有自己收尾: 仍然失败并回收\n'
F=$T_TMP/fake
mkdir -p "$F/tests" "$F/bin"
cp "$T_ROOT/tests/lib.sh" "$T_ROOT/tests/reap.sh" "$F/tests/"
cp "$T_ROOT/VERSION" "$F/VERSION" 2>/dev/null
cat > "$F/tests/test_leak.sh" <<'EOS'
. "$(dirname "$0")/lib.sh"
sleep 60 &
t_own_pid "$!"
printf '%s\n' "$!" > "$LEAKPID"
assert_eq "示例用例" 1 1
t_done
EOS
LEAKPID=$T_TMP/leakpid
export LEAKPID
out=$(sh "$F/tests/test_leak.sh" 2>&1)
rc=$?
LP=$(cat "$LEAKPID" 2>/dev/null)
assert_eq "留下进程的测试文件返回失败" 1 "$rc"
assert_contains "报告了残留" "$out" "仍有 1 个登记的进程"
sleep 0.3
assert_eq "残留进程已被回收" no "$(alive "$LP" && echo yes || echo no)"
cat > "$F/tests/test_clean.sh" <<'EOS'
. "$(dirname "$0")/lib.sh"
assert_eq "示例用例" 1 1
t_done
EOS
sh "$F/tests/test_clean.sh" >/dev/null 2>&1
assert_eq "没有残留的测试文件返回成功" 0 "$?"
# 被 TERM 中断: 清理并返回 130, 不留临时目录
cat > "$F/tests/test_int.sh" <<'EOS'
. "$(dirname "$0")/lib.sh"
sleep 60 &
t_own_pid "$!"
printf '%s %s\n' "$!" "$T_TMP" > "$LEAKPID"
sleep 30
EOS
sh "$F/tests/test_int.sh" >/dev/null 2>&1 &
TP=$!
_w=0; while [ "$_w" -lt 50 ] && [ ! -s "$LEAKPID" ]; do sleep 0.1; _w=$((_w + 1)); done
LP=$(cut -d' ' -f1 "$LEAKPID"); TT=$(cut -d' ' -f2 "$LEAKPID")
kill -TERM "$TP"
for _p in $(pgrep -P "$TP" 2>/dev/null); do :; done
wait "$TP" 2>/dev/null
_rc=$?
assert_eq "中断后返回被信号终止的码 (130 或 143)" 1 "$([ "$_rc" = 130 ] || [ "$_rc" = 143 ] && echo 1 || echo 0)"
sleep 0.5
assert_eq "中断后登记的进程已被回收" no "$(alive "$LP" && echo yes || echo no)"
assert_eq "中断后临时目录已删除" no "$([ -e "$TT" ] && echo yes || echo no)"
kill -TERM "$LP" 2>/dev/null

printf '== 静态审计: 测试里没有全局清理与无限空转\n'
G=$(grep -nE '(^|[^[:alnum:]_])(pkill|killall)([[:space:]]|$)|kill-server' "$T_ROOT"/tests/*.sh "$T_ROOT"/tests/tools/*.sh 2>/dev/null | grep -vE '^[^:]*test_testinfra\.sh:|^[^:]*reap\.sh:|^[^:]*run\.sh:[0-9]+:#|^[^:]*cpuload\.sh:[0-9]+:#' )
assert_eq "测试脚本里没有 pkill killall tmux kill-server" "" "$G"
G=$(grep -nE 'while :; do :; done|while true; do :; done' "$T_ROOT"/tests/*.sh "$T_ROOT"/tests/e2e/* 2>/dev/null | grep -v 'test_testinfra.sh')
assert_eq "测试脚本里没有无限空转 (负载只通过 tools/cpuload.sh)" "" "$G"
printf '== run.sh 的退出码如实反映测试文件的失败\n'
RX=$T_TMP/rx; mkdir -p "$RX/tests"
cp "$T_ROOT/tests/run.sh" "$T_ROOT/tests/lib.sh" "$T_ROOT/tests/reap.sh" "$RX/tests/"
# shellcheck disable=SC2016
printf '. "$(dirname "$0")/lib.sh"\nassert_eq x 1 2\nt_done\n' > "$RX/tests/test_zfail.sh"
( cd "$RX/tests" && sh run.sh >/dev/null 2>&1 ); rc_f=$?
assert_eq "测试文件有失败时 run.sh 返回 1" 1 "$rc_f"
# shellcheck disable=SC2016
printf '. "$(dirname "$0")/lib.sh"\nassert_eq x 1 1\nt_done\n' > "$RX/tests/test_zfail.sh"
( cd "$RX/tests" && sh run.sh >/dev/null 2>&1 ); rc_p=$?
assert_eq "测试文件全部通过时 run.sh 返回 0" 0 "$rc_p"
t_done
