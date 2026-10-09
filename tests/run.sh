#!/bin/sh
# 运行 tests/test_*.sh, 任一失败则整体失败
cd "$(dirname "$0")" || exit 1
failed=0
for t in test_*.sh; do
    printf '== %s\n' "$t"
    # 单个测试文件最多 20 分钟 防止交互式菜单的按键序号变化后无限等待输入
    if command -v timeout >/dev/null 2>&1; then timeout 1200 sh "./$t" || failed=$((failed + 1)); else sh "./$t" || failed=$((failed + 1)); fi
done
if [ "$failed" -ne 0 ]; then
    printf '失败的测试文件: %s\n' "$failed"
    exit 1
fi
printf '全部测试通过\n'
