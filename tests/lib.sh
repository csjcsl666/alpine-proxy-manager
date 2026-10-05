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

# mk_fake_singbox SYSROOT, 安装一个假的 sing-box, version 固定, check 以文件内含 valid 为通过
mk_fake_singbox() {
    cat > "$1/usr/bin/sing-box" <<'EOS'
#!/bin/sh
case $1 in
    version) echo "sing-box version 1.13.11"; echo "Environment: go1.x linux/amd64" ;;
    check) grep -q valid "$3" ;;
esac
EOS
    chmod +x "$1/usr/bin/sing-box"
}

t_done() {
    printf '%s: %s 通过, %s 失败\n' "$(basename "$0")" "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ]
}
