#!/bin/sh
# 运行 tests/test_*.sh, 任一失败则整体失败
cd "$(dirname "$0")" || exit 1
failed=0
for t in test_*.sh; do
    printf '== %s\n' "$t"
    sh "./$t" || failed=$((failed + 1))
done
if [ "$failed" -ne 0 ]; then
    printf '失败的测试文件: %s\n' "$failed"
    exit 1
fi
printf '全部测试通过\n'
