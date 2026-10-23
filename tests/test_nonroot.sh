# shellcheck shell=sh
# 非 root 只读查看: 读不到的东西写 需要 root 才能判断, 不能当成 不存在 未接管 已停止 或 环境不支持
# 本机测试以普通用户运行, 用 000 目录制造权限不足; 以 root 运行时 (CI) 切换到 nobody 执行, root 本身不受目录权限限制
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth lowmem tui
PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_nonroot.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

if [ "$(id -u)" = 0 ]; then
    if ! id nobody >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
        t_skip "以 root 运行且没有 nobody 或 su, 非 root 测试跳过"
        t_done
        exit $?
    fi
    AS_ROOT=1
else
    AS_ROOT=0
fi

new_s nr1
printf 'NonRootPskNotSecret0123456789abcd\n' | "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
out=$("$PM" status 2>&1)
assert_contains "root: Snell 运行中且已接管" "$out" "Snell：运行中 (Manager 部署, 已接管)"
: > "$K/noroot_status"
mkdir -p "$A/proc/sys/net/ipv4"
printf '4096\t87380\t67108864\n' > "$A/proc/sys/net/ipv4/tcp_rmem"
printf '4096\t65536\t67108864\n' > "$A/proc/sys/net/ipv4/tcp_wmem"

# 以非 root 身份运行 (EUID 判断与真实权限都是普通用户)
NR() {
    if [ "$AS_ROOT" = 1 ]; then
        su -s /bin/sh nobody -c "APM_SYSROOT='$A' APM_FAKE_RC_DIR='$K' APM_EUID=65534 APM_FAKE_NOROOT=1 APM_TUI_ANSI=0 LC_ALL=$LC_ALL APM_HOME='$T_ROOT' sh '$PM' $*" 2>&1
    else
        ( APM_EUID=1000; APM_FAKE_NOROOT=1; export APM_EUID APM_FAKE_NOROOT; sh "$PM" "$@" ) 2>&1
    fi
}
if [ "$AS_ROOT" = 1 ]; then
    # nobody 要能走到 sysroot 与代码 (测试目录默认只有 root 能进)
    _p=$A; while [ "$_p" != / ]; do chmod o+x "$_p" 2>/dev/null; _p=$(dirname "$_p"); done
    chmod -R o+rX "$A" "$T_ROOT" 2>/dev/null
fi
# 与真实部署一样无权进入的目录: Snell 与 sing-box 配置目录 Manager 数据与设置目录 服务进程的 fd
chmod 000 "$A/etc/snell" "$A/etc/sing-box" "$A/var/lib/alpine-proxy-manager" "$A/etc/alpine-proxy-manager"
for _d in "$A"/proc/[0-9]*/fd; do chmod 000 "$_d" 2>/dev/null; done

printf '== 状态总览\n'
out=$(NR status)
assert_contains "非 root: Snell 仍判断为运行中" "$out" "Snell：运行中"
assert_contains "非 root: sing-box 仍判断为运行中" "$out" "sing-box：运行中"
assert_contains "非 root: 归属写需要 root" "$out" "需要 root 才能判断"
assert_not_contains "非 root: 不写未接管" "$out" "未接管"
assert_not_contains "非 root: 不写配置不存在" "$out" "不存在"
assert_contains "非 root: 保护状态写需要 root" "$out" "网络与进程保护：需要 root 才能判断"
assert_not_contains "非 root: 保护不写未启用" "$out" "网络与进程保护：未启用"

printf '== Snell 与 sing-box 详情\n'
out=$(NR snell status)
assert_contains "非 root snell: 状态运行中" "$out" "状态：运行中"
assert_contains "非 root snell: 部署需要 root" "$out" "部署：需要 root 才能判断, 无权读取 Manager 元数据"
assert_contains "非 root snell: 监听需要 root" "$out" "监听：需要 root 才能确认"
assert_not_contains "非 root snell: 不说没有监听" "$out" "没有检测到监听端口"
assert_not_contains "非 root snell: 不说配置不存在" "$out" "不存在"
out=$(NR sing-box status)
assert_contains "非 root sing-box: 状态运行中" "$out" "状态：运行中"
assert_contains "非 root sing-box: 监听需要 root" "$out" "监听：需要 root 才能确认"

printf '== 网络与进程保护\n'
out=$(NR lowmem status)
assert_contains "非 root lowmem: TCP 写需要 root" "$out" "TCP 缓冲：需要 root 才能判断能否调整"
assert_contains "非 root lowmem: SSH 写需要 root" "$out" "SSH 保护：需要 root 才能判断"
assert_not_contains "非 root lowmem: 不说无特权容器" "$out" "无特权容器"
assert_not_contains "非 root lowmem: 不说只读" "$out" "（只读）"
assert_contains "非 root lowmem: 作用范围写需要 root" "$out" "是否与宿主机共享：需要 root 才能判断"
assert_contains "非 root lowmem: 保护状态写需要 root" "$out" "保护状态：需要 root 才能判断"
# 只取 stderr: 读不到的 /proc 项 文件消失 PID 1 的环境变量 都不能在页面上打出 shell 的报错
NRE() {
    if [ "$AS_ROOT" = 1 ]; then
        su -s /bin/sh nobody -c "APM_SYSROOT='$A' APM_FAKE_RC_DIR='$K' APM_EUID=65534 APM_FAKE_NOROOT=1 APM_TUI_ANSI=0 LC_ALL=$LC_ALL APM_HOME='$T_ROOT' sh '$PM' $* 2>&1 >/dev/null"
    else
        ( APM_EUID=1000; APM_FAKE_NOROOT=1; export APM_EUID APM_FAKE_NOROOT; sh "$PM" "$@" 2>&1 >/dev/null )
    fi
}
# 一个刚退出的进程: 目录还在, comm 等文件已经没有了 (扫描 /proc 时的真实竞争)
mkdir -p "$A/proc/31999"
for c in status "snell status" "sing-box status" "lowmem status" "lowmem detail" doctor; do
    # shellcheck disable=SC2086
    assert_eq "非 root: $c 没有 stderr" "" "$(NRE $c)"
done

printf '== TUI (管道)\n'
if [ "$AS_ROOT" = 1 ]; then
    t_skip "以 root 运行时 TUI 用例跳过 (管道驱动的 TUI 需要在同一 shell 里以非 root 运行), 状态来源与命令行相同"
else
    out=$(printf '1\n0\n0\n' | ( APM_EUID=1000; APM_FAKE_NOROOT=1; export APM_EUID APM_FAKE_NOROOT; tui_run ) 2>&1)
    assert_contains "非 root TUI: 主菜单 Snell 运行中且归属需要 root" "$out" "运行中  需要 root 才能判断归属"
    assert_contains "非 root TUI: Snell 页管理行" "$out" "管理：需要 root 才能判断"
    assert_contains "非 root TUI: Snell 页只读项" "$out" "1. 查看详细信息"
    assert_contains "非 root TUI: 有非 root 提示" "$out" "当前不是 root，只能查看"
fi

# 恢复权限后 root 视角不受影响
chmod 755 "$A/etc/snell" "$A/etc/sing-box" "$A/etc/alpine-proxy-manager"; chmod 700 "$A/var/lib/alpine-proxy-manager"
for _d in "$A"/proc/[0-9]*/fd; do chmod 755 "$_d" 2>/dev/null; done
rm -f "$K/noroot_status"
out=$("$PM" status 2>&1)
assert_contains "root 视角不变: Snell 已接管" "$out" "Snell：运行中 (Manager 部署, 已接管)"
t_done
