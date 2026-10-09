# shellcheck shell=sh
# shellcheck disable=SC2016 # 断言里的 $ 是要匹配的原文
# 端到端安全回归不能被悄悄删除: 原先的 "空名单加 127.0.0.53 通配 TCP UDP 服务" 绕过测试
# 与 SOCKS5 出口的回环不直连测试必须一直在, 并且由 CI 运行
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

E=$T_ROOT/tests/e2e
W=$T_ROOT/.github/workflows/ci.yml
A=$(cat "$E/net_access.sh")
G=$(cat "$E/net_egress.sh")
assert_contains "CI 运行端到端脚本" "$(cat "$W")" "tests/e2e/ci-net.sh"
assert_contains "CI 给了 ptrace 能力" "$(cat "$W")" "--cap-add SYS_PTRACE"
assert_contains "ci-net 运行 access 场景" "$(cat "$E/ci-net.sh")" "net_access.sh"
assert_contains "ci-net 运行 egress 场景" "$(cat "$E/ci-net.sh")" "net_egress.sh"
assert_contains "ci-net 使用官方 Snell 安装" "$(cat "$E/ci-net.sh")" "proxy-manager snell install"
assert_contains "ci-net 核对 sing-box 校验和" "$(cat "$E/ci-net.sh")" "8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297"
# access: 通配服务 + 空名单 + 127.0.0.53
assert_contains "access 有通配地址服务" "$A" "start_targets 0.0.0.0,24001"
assert_contains "access 空名单测试 127.0.0.53 TCP" "$A" 'expect_denied "空名单 TCP $a:24001"'
assert_contains "access 空名单覆盖 127.0.0.53" "$A" "for a in 127.0.0.1 127.0.0.2 127.0.0.53 0.0.0.0 ::1"
assert_contains "access 空名单测试 UDP" "$A" 'expect_denied "空名单 UDP $a:24001"'
assert_contains "access 通配 53 端口服务" "$A" "0.0.0.0,53"
assert_contains "access 测 127.0.0.53:53 TCP" "$A" "tcp 127.0.0.53 53"
assert_contains "access 测 127.0.0.53:53 UDP" "$A" "udp 127.0.0.53 53"
assert_contains "access 同地址其他端口" "$A" "同地址其他端口"
assert_contains "access 其他地址同端口" "$A" "其他地址同端口"
assert_contains "access 交叉组合" "$A" "交叉 A 地址 B 端口"
assert_contains "access 零命中断言" "$(cat "$E/net_lib.sh")" "目标零命中"
# egress: 回环对端必须是上游, 上游拒绝回环时目标零命中
assert_contains "egress 通配服务" "$G" "start_targets 0.0.0.0,24001"
assert_contains "egress 回环对端是上游" "$G" 'expect_peer "127.0.0.1:24001 对端是上游"'
assert_contains "egress 127.0.0.53 对端是上游" "$G" 'expect_peer "127.0.0.53:24001 对端是上游"'
assert_contains "egress UDP 127.0.0.53" "$G" 'expect_peer "UDP 127.0.0.53:24001 对端是上游"'
assert_contains "egress 上游拒绝回环时零命中" "$G" "上游拒绝回环 TCP"
assert_contains "egress 诱饵解析器零查询" "$G" "诱饵系统解析器零查询"
assert_contains "egress 上游关闭" "$G" "上游关闭时 30 次探测目标始终零命中"
t_done
