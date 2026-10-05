# shellcheck shell=sh
# 极简测试框架, 仅依赖 POSIX sh 与 BusyBox 工具
# 每个 test_*.sh 先 source 本文件, 末尾调用 t_done

T_ROOT=$(cd "$(dirname "$0")/.." && pwd)
APM_HOME=$T_ROOT
export APM_HOME
T_PASS=0
T_FAIL=0
T_TMP=$(mktemp -d)
trap 'rm -rf "$T_TMP"' EXIT

t_pass() { T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; shift; [ $# -eq 0 ] || printf '       %s\n' "$@"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
    if [ "$2" = "$3" ]; then t_pass "$1"; else t_fail "$1" "期望: [$2]" "实际: [$3]"; fi
}

# assert_contains NAME HAYSTACK NEEDLE (固定字符串)
assert_contains() {
    case $2 in
        *"$3"*) t_pass "$1" ;;
        *) t_fail "$1" "未找到: [$3]" "输出: [$2]" ;;
    esac
}

assert_not_contains() {
    case $2 in
        *"$3"*) t_fail "$1" "不应出现: [$3]" ;;
        *) t_pass "$1" ;;
    esac
}

# assert_ok NAME CMD...   与   assert_fail NAME CMD...
assert_ok() {
    _n=$1
    shift
    if "$@" >/dev/null 2>&1; then t_pass "$_n"; else t_fail "$_n" "命令应成功: $*"; fi
}
assert_fail() {
    _n=$1
    shift
    if "$@" >/dev/null 2>&1; then t_fail "$_n" "命令应失败: $*"; else t_pass "$_n"; fi
}

# assert_rc NAME EXPECTED_RC CMD...
assert_rc() {
    _n=$1
    _e=$2
    shift 2
    "$@" >/dev/null 2>&1
    _r=$?
    if [ "$_r" -eq "$_e" ]; then t_pass "$_n"; else t_fail "$_n" "期望返回码 $_e, 实际 $_r"; fi
}

# 加载被测库
t_load() {
    for _m in "$@"; do
        # shellcheck source=/dev/null
        . "$T_ROOT/lib/$_m.sh"
    done
}

# mk_sysroot DIR [alpine|debian], 构造最小的 mock 根目录
mk_sysroot() {
    mkdir -p "$1/etc" "$1/sbin" "$1/usr/bin" "$1/proc/self" "$1/sys/fs/cgroup"
    if [ "${2:-alpine}" = alpine ]; then
        echo 3.24.1 > "$1/etc/alpine-release"
        printf 'NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.24.1\n' > "$1/etc/os-release"
        printf '#!/bin/sh\n' > "$1/sbin/openrc"
        chmod +x "$1/sbin/openrc"
    else
        printf 'ID=debian\n' > "$1/etc/os-release"
    fi
    printf 'MemTotal:        1048576 kB\nMemFree:          200000 kB\nMemAvailable:     600000 kB\nSwapTotal:             0 kB\nSwapFree:              0 kB\n' > "$1/proc/meminfo"
}

t_skip() { printf '  skip %s\n' "$1"; }

# mk_elf_stub FILE MESSAGE, 生成一个真实可执行的最小 x86_64 ELF, 运行时忽略参数并打印 MESSAGE
# 用于测试 "只执行已确认的 ELF" 的路径, 其他架构返回 1
# shellcheck disable=SC2059
mk_elf_stub() {
    local _len _total _lo _hi
    [ "$(uname -m)" = x86_64 ] || return 1
    _len=$(printf '%s\n' "$2" | wc -c | tr -d ' ')
    _total=$((153 + _len))
    _lo=$((_total % 256))
    _hi=$((_total / 256))
    {
        printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000'
        printf '\002\000\076\000\001\000\000\000'
        printf '\170\000\100\000\000\000\000\000'
        printf '\100\000\000\000\000\000\000\000'
        printf '\000\000\000\000\000\000\000\000'
        printf '\000\000\000\000'
        printf '\100\000\070\000\001\000\000\000\000\000\000\000'
        printf '\001\000\000\000\005\000\000\000'
        printf '\000\000\000\000\000\000\000\000'
        printf '\000\000\100\000\000\000\000\000'
        printf '\000\000\100\000\000\000\000\000'
        printf "\\$(printf '%03o' "$_lo")\\$(printf '%03o' "$_hi")\\000\\000\\000\\000\\000\\000"
        printf "\\$(printf '%03o' "$_lo")\\$(printf '%03o' "$_hi")\\000\\000\\000\\000\\000\\000"
        printf '\000\020\000\000\000\000\000\000'
        printf '\270\001\000\000\000'
        printf '\277\001\000\000\000'
        printf '\110\215\065\020\000\000\000'
        printf "\\272\\$(printf '%03o' "$_len")\\000\\000\\000"
        printf '\017\005'
        printf '\270\074\000\000\000'
        printf '\061\377'
        printf '\017\005'
        printf '%s\n' "$2"
    } > "$1"
    chmod +x "$1"
}

# mk_fake_singbox SYSROOT, 安装一个真实 ELF 的 sing-box 桩, version 输出固定
# 非 x86_64 时返回 1
mk_fake_singbox() {
    mk_elf_stub "$1/usr/bin/sing-box" "sing-box version 1.13.11" || return 1
}

# mk_script_bin FILE MARKER_DIR, 安装一个恶意样式的脚本, 一旦被执行就在 MARKER_DIR 下创建 SHOULD_NOT_EXIST
mk_script_bin() {
    printf '#!/bin/sh\ntouch "%s/SHOULD_NOT_EXIST"\necho "snell-server v9.9.9"\n' "$2" > "$1"
    chmod +x "$1"
}

# 假的 rc-service: 只允许 status, 状态取自 $APM_FAKE_RC_DIR/<服务名>, 任何其他动作记入 violations 并失败
mk_fake_rcservice() {
    cat > "$1/sbin/rc-service" <<'EOS'
#!/bin/sh
d=${APM_FAKE_RC_DIR:?}
if [ "${2:-}" != status ]; then
    echo "$*" >> "$d/violations"
    exit 99
fi
echo "$*" >> "$d/calls"
st=$(cat "$d/$1" 2>/dev/null || echo stopped)
echo " * status: $st"
case $st in
    started) exit 0 ;;
    crashed) exit 32 ;;
    *) exit 3 ;;
esac
EOS
    chmod +x "$1/sbin/rc-service"
}

# mk_snell_init SYSROOT [external|alpine], 写入 OpenRC 脚本
mk_snell_init() {
    mkdir -p "$1/etc/init.d"
    if [ "${2:-external}" = external ]; then
        cat > "$1/etc/init.d/snell" <<'EOS'
#!/sbin/openrc-run
name="snell"
description="Official Snell Server v6.0.0-rc2"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell-server.conf"
command_user="snell:snell"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/snell/access.log"
error_log="/var/log/snell/error.log"
supervisor=supervise-daemon
export LD_PRELOAD="/lib/libgcompat.so.0"
depend() {
    need net
}
EOS
    else
        cat > "$1/etc/init.d/snell" <<'EOS'
#!/sbin/openrc-run
name="Snell"
command="/usr/local/bin/snell-server"
command_args="-l notify -c /etc/snell/snell-server.conf"
command_user="snell:snell"
supervisor="supervise-daemon"
output_log="/var/log/snell.log"
error_log="/var/log/snell.log"
required_files="/etc/snell/snell-server.conf"
depend() {
    need net
}
EOS
    fi
    chmod +x "$1/etc/init.d/snell"
}

# mk_proc SYSROOT PID PPID COMM ARG...  写入 /proc/PID/{stat,comm,cmdline}
mk_proc() {
    local _r _pid _ppid _comm
    _r=$1
    _pid=$2
    _ppid=$3
    _comm=$4
    shift 4
    mkdir -p "$_r/proc/$_pid"
    printf '%s (%s) S %s 1 1 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 100 15292000 1047 18446744073709551615\n' "$_pid" "$_comm" "$_ppid" > "$_r/proc/$_pid/stat"
    printf '%s\n' "$_comm" > "$_r/proc/$_pid/comm"
    printf '%s\0' "$@" > "$_r/proc/$_pid/cmdline"
}

# mk_net SYSROOT FILE LINES, 写 /proc/net/FILE, 带表头
mk_net() {
    mkdir -p "$1/proc/net"
    {
        printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
        printf '%s\n' "$3"
    } > "$1/proc/net/$2"
}

# ---- Snell Managed 生命周期用的模拟系统 ----
# 旋钮放在 $APM_FAKE_RC_DIR 下: fail_start fail_stop fail_restart no_listen fail_rcupdate fail_adduser fail_apk
# fail_port 文件里写一个端口, 配置监听该端口时 start 失败
# 二进制内容含 BADBIN 时 start 失败

# mk_sim_system SYSROOT, 写入模拟的 rc-service rc-update adduser addgroup deluser delgroup apk
mk_sim_system() {
    local _r
    _r=$1
    mkdir -p "$_r/sbin" "$_r/etc/runlevels/default" "$_r/run" "$_r/var/tmp" "$_r/var/lib" "$_r/var/log" "$_r/etc/init.d" "$_r/proc/net" "$_r/usr/local/bin"
    : > "$_r/etc/passwd"
    : > "$_r/etc/group"
    : > "$_r/.apk-installed"
    printf 'libstdc++\nlibgcc\n' > "$_r/.apk-installed"
    cat > "$_r/sbin/rc-service" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
K=${APM_FAKE_RC_DIR:?}
svc=$1
act=${2:-}
echo "$svc $act" >> "$K/calls"
conf=$R/etc/snell/snell-server.conf
bin=$R/usr/local/bin/snell-server
state() { cat "$K/state" 2>/dev/null || echo stopped; }
stop_proc() {
    rm -rf "$R/proc/23754" "$R/proc/23755" "$R/run/snell.pid" "$R/proc/net/tcp"
}
start_proc() {
    mkdir -p "$R/run" "$R/proc/23754" "$R/proc/23755/fd" "$R/proc/net"
    printf '23754\n' > "$R/run/snell.pid"
    printf '23754 (supervise-daemo) S 1 1 1 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 1 0 100 1148000 83 1\n' > "$R/proc/23754/stat"
    printf 'supervise-daemon\0snell\0--start\0' > "$R/proc/23754/cmdline"
    printf '23755 (ld-musl-x86_64.) S 23754 1 1 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 1 0 100 15292000 1047 1\n' > "$R/proc/23755/stat"
    printf 'ld-linux-x86-64.so.2\0--argv0\0/usr/local/bin/snell-server\0--\0/usr/local/bin/snell-server\0-c\0/etc/snell/snell-server.conf\0' > "$R/proc/23755/cmdline"
    {
        printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
        if [ ! -e "$K/no_listen" ]; then
            i=0
            for p in $(sed -n 's/^listen[[:space:]]*=[[:space:]]*//p' "$conf" | tr ',' '\n' | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'); do
                printf '   %s: 00000000:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000   100        0 %s 1 0\n' "$i" "$p" "$((50000 + i))"
                ln -sf "socket:[$((50000 + i))]" "$R/proc/23755/fd/$((10 + i))"
                i=$((i + 1))
            done
        fi
    } > "$R/proc/net/tcp"
}
do_start() {
    [ ! -e "$K/fail_start" ] || return 1
    [ -f "$conf" ] || return 1
    # BusyBox grep 对 NUL 与非法字节不可靠, 先把所有非字母数字换成空格
    tr -c 'A-Za-z0-9\n' ' ' < "$bin" 2>/dev/null | grep -q BADBIN && return 1
    if [ -s "$K/fail_port" ]; then
        grep -q ":$(cat "$K/fail_port")" "$conf" && return 1
    fi
    echo started > "$K/state"
    start_proc
    return 0
}
case $act in
    status)
        st=$(state)
        echo " * status: $st"
        case $st in started) exit 0 ;; crashed) exit 32 ;; *) exit 3 ;; esac
        ;;
    start) do_start; exit $? ;;
    stop)
        [ ! -e "$K/fail_stop" ] || exit 1
        echo stopped > "$K/state"
        stop_proc
        exit 0
        ;;
    restart)
        [ ! -e "$K/fail_restart" ] || exit 1
        echo stopped > "$K/state"
        stop_proc
        do_start
        exit $?
        ;;
    *) echo "$*" >> "$K/violations"; exit 99 ;;
esac
EOS
    cat > "$_r/sbin/rc-update" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
K=${APM_FAKE_RC_DIR:?}
echo "rc-update $*" >> "$K/calls"
[ ! -e "$K/fail_rcupdate" ] || exit 1
case $1 in
    add) mkdir -p "$R/etc/runlevels/$3"; ln -sf "/etc/init.d/$2" "$R/etc/runlevels/$3/$2" ;;
    del) rm -f "$R/etc/runlevels/$3/$2" ;;
esac
EOS
    cat > "$_r/sbin/addgroup" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
[ ! -e "${APM_FAKE_RC_DIR:?}/fail_addgroup" ] || exit 1
for last; do :; done
echo "$last:x:101:" >> "$R/etc/group"
EOS
    cat > "$_r/sbin/adduser" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
[ ! -e "${APM_FAKE_RC_DIR:?}/fail_adduser" ] || exit 1
for last; do :; done
echo "$last:x:100:101::/var/empty:/sbin/nologin" >> "$R/etc/passwd"
EOS
    cat > "$_r/sbin/deluser" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
grep -v "^$1:" "$R/etc/passwd" > "$R/etc/passwd.new"; mv "$R/etc/passwd.new" "$R/etc/passwd"
EOS
    cat > "$_r/sbin/delgroup" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
grep -v "^$1:" "$R/etc/group" > "$R/etc/group.new"; mv "$R/etc/group.new" "$R/etc/group"
EOS
    cat > "$_r/sbin/apk" <<'EOS'
#!/bin/sh
R=${APM_SYSROOT:?}
K=${APM_FAKE_RC_DIR:?}
case $1 in
    info) grep -qx "$3" "$R/.apk-installed" ;;
    add)
        [ ! -e "$K/fail_apk" ] || exit 1
        shift
        for a; do case $a in -*) ;; *) echo "$a" >> "$R/.apk-installed" ;; esac; done
        ;;
    *) exit 99 ;;
esac
EOS
    chmod +x "$_r"/sbin/rc-service "$_r"/sbin/rc-update "$_r"/sbin/addgroup "$_r"/sbin/adduser "$_r"/sbin/deluser "$_r"/sbin/delgroup "$_r"/sbin/apk
}

# mk_snell_zip DIR TAG MESSAGE, 在 DIR 生成 snell-server-TAG-linux-amd64.zip, 内含一个输出 MESSAGE 的真实 ELF 桩
# 用 git archive 生成 zip, 不需要 zip 命令
mk_snell_zip() {
    local _w
    _w=$(mktemp -d)
    mkdir -p "$1"
    mk_elf_stub "$_w/snell-server" "$3" || { rm -rf "$_w"; return 1; }
    git -C "$_w" init -q
    git -C "$_w" add snell-server
    git -C "$_w" -c user.name=t -c user.email=t@example.invalid commit -q -m x
    git -C "$_w" archive --format=zip -o "$1/snell-server-$2-linux-amd64.zip" HEAD
    rm -rf "$_w"
}

# 下载 shim: 与 wget 同形的参数, 按 URL 文件名在 $APM_TEST_ZIPS 里找文件, 记录 URL
mk_dl_shim() {
    cat > "$1" <<'EOS'
#!/bin/sh
while [ $# -gt 1 ]; do
    case $1 in
        -O) dest=$2; shift 2 ;;
        -T) shift 2 ;;
        *) shift ;;
    esac
done
echo "$1" >> "${APM_TEST_DL_LOG:?}"
[ -z "${APM_TEST_DL_FAIL:-}" ] || exit 1
f=${APM_TEST_ZIPS:?}/${1##*/}
[ -f "$f" ] || exit 1
cp "$f" "$dest"
EOS
    chmod +x "$1"
}

t_done() {
    printf '%s: %s 通过, %s 失败\n' "$(basename "$0")" "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
