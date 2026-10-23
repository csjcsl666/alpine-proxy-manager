#!/bin/sh
# 运行 tests/test_*.sh, 任一失败则整体失败
# 每个测试文件结束后 (正常 失败 超时) 回收它登记的进程与 tmux 会话; 回收到东西说明它没有自己收尾, 记为失败
# 整次运行共用一个登记目录, 结束时检查没有残留, 不使用 pkill killall 或 tmux kill-server
cd "$(dirname "$0")" || exit 1
T_ROOT=$(cd .. && pwd)
APM_TEST_REG=$(mktemp -d)
export APM_TEST_REG
# shellcheck source=tests/reap.sh
. ./reap.sh
trap 't_reap_dir "$APM_TEST_REG" >/dev/null; rm -rf "$APM_TEST_REG"' EXIT
trap 'exit 130' INT TERM HUP
failed=0
leaked=0
for t in test_*.sh; do
    printf '== %s\n' "$t"
    # 单个测试文件最多 20 分钟 防止交互式菜单的按键序号变化后无限等待输入
    if command -v timeout >/dev/null 2>&1; then timeout 1200 sh "./$t" || failed=$((failed + 1)); else sh "./$t" || failed=$((failed + 1)); fi
    _n=$(t_reap_dir "$APM_TEST_REG")  # 被超时杀掉或中断的测试没来得及自己回收
    if [ "${_n:-0}" -gt 0 ]; then
        printf '  FAIL %s 结束后仍有 %s 个登记的进程或 tmux 会话, 已回收\n' "$t" "$_n"
        leaked=$((leaked + 1))
    fi
done
if [ "$failed" -ne 0 ] || [ "$leaked" -ne 0 ]; then
    printf '失败的测试文件: %s 残留进程的测试文件: %s\n' "$failed" "$leaked"
    exit 1
fi
printf '全部测试通过\n'
