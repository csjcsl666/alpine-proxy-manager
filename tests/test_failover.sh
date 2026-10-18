# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# sing-box SOCKS5 自动故障切换 (v0.8.2) 的产品集成: 默认关闭 逐台授权 配置生成 selector 关闭恢复严格 SOCKS5 恢复验证地址 TUI 页面 升级兼容 回滚
# 真实的切换与恢复由 tests/e2e/failover.sh 用官方 sing-box 覆盖, 状态机由 test_sbhealth.sh 覆盖
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_failover.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

CFG() { cat "$A/etc/sing-box/config.json"; }
CONF() { printf '%s/etc/alpine-proxy-manager/sbhealth.conf' "$A"; }
INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
CFGSUM() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
RUND() { printf '%s/run/apm-sbhealth' "$A"; }
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

new_s f1
"$PM" sing-box install >/dev/null 2>&1
"$PM" sing-box add anytls --port 20443 >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20500 >/dev/null 2>&1
SPW=FictSocksPassNotReal0001
printf '%s\n' "$SPW" | "$PM" sing-box socks add --name SOCKS-01 --server 192.0.2.10 --port 1080 --username fictuser --password-stdin >/dev/null 2>&1
printf '%s\n' "$SPW" | "$PM" sing-box socks add --name socks2 --server 192.0.2.11 --port 1081 --username fictuser --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 socks socks2 >/dev/null 2>&1

# ---- 升级兼容: 没有任何 failover 设置时, 行为与 v0.8.1 完全相同 ----
assert_eq "默认没有任何授权" "" "$(kv_get "$(CONF)" failover_on)"
assert_not_contains "默认运行配置没有 selector" "$(CFG)" selector
assert_contains "默认路由直接指向 SOCKS5 出站" "$(CFG)" '"outbound": "apm-socks-SOCKS-01"'
assert_not_contains "默认没有 DIRECT 回退规则" "$(CFG)" 'apm-sel-'
OUT=$("$PM" sing-box health failover 2>&1)
assert_contains "列表显示 SOCKS-01 已关闭" "$OUT" "SOCKS-01  已关闭"
assert_contains "列表显示 socks2 已关闭" "$OUT" "socks2  已关闭"
BASE=$(CFGSUM)
# 带有 v0.8.1 sbhealth.conf (没有任何 failover 键) 的升级: 重新生成配置仍然逐字节相同
"$PM" sing-box restart >/dev/null 2>&1
assert_eq "重新生成配置逐字节相同 (升级不会开启 DIRECT)" "$BASE" "$(CFGSUM)"

# ---- 命令行: 参数校验 ----
OUT=$("$PM" sing-box health failover SOCKS-01 2>&1); assert_eq "缺少 on/off 返回 2" 2 "$?"
OUT=$("$PM" sing-box health failover SOCKS-01 maybe 2>&1); assert_eq "无效取值返回 2" 2 "$?"
OUT=$("$PM" sing-box health failover nope on 2>&1); assert_eq "不存在的 Profile 返回 1" 1 "$?"
assert_contains "不存在提示" "$OUT" "不存在"
assert_eq "校验失败没有改动配置" "$BASE" "$(CFGSUM)"
assert_eq "校验失败没有产生授权" "" "$(kv_get "$(CONF)" failover_on)"

# ---- 开启: 只影响这一台, 生成 selector, 路由指向 selector, 绑定与凭据不变 ----
OUT=$("$PM" sing-box health failover SOCKS-01 on 2>&1)
assert_eq "开启成功" 0 "$?"
assert_contains "提示会通过 VPS 自己的 IP" "$OUT" "VPS 自己的 IP"
assert_eq "授权记录" SOCKS-01 "$(kv_get "$(CONF)" failover_on)"
assert_contains "生成 selector" "$(CFG)" '"type": "selector"'
assert_contains "selector 标签" "$(CFG)" '"tag": "apm-sel-SOCKS-01"'
assert_contains "selector 成员是 SOCKS5 与 direct" "$(CFG)" '"outbounds": ["apm-socks-SOCKS-01", "direct"]'
assert_contains "selector 默认 SOCKS5" "$(CFG)" '"default": "apm-socks-SOCKS-01"'
assert_contains "selector 切换不中断已有连接" "$(CFG)" '"interrupt_exist_connections": false'
assert_contains "路由指向 selector" "$(CFG)" '"outbound": "apm-sel-SOCKS-01"'
assert_not_contains "未授权的 socks2 没有 selector" "$(CFG)" 'apm-sel-socks2'
assert_contains "未授权的 socks2 仍然直接走 SOCKS5" "$(CFG)" '"outbound": "apm-socks-socks2"'
assert_eq "出口绑定不变" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
assert_eq "另一实例绑定不变" socks2 "$(kv_get "$(INST Hysteria2-01)" egress_socks)"
assert_eq "Profile 密码不变" "$SPW" "$(kv_get "$(PROF SOCKS-01)" password)"
assert_eq "Profile 仍然启用" true "$(kv_get "$(PROF SOCKS-01)" enabled)"
assert_contains "运行目录 profiles 带 fo 标记" "$(cat "$(RUND)/profiles")" " fo"
assert_not_contains "未授权的 socks2 没有 fo 标记" "$(grep '^socks2 ' "$(RUND)/profiles")" " fo"
OUT=$("$PM" sing-box health failover 2>&1)
assert_contains "列表显示已开启" "$OUT" "SOCKS-01  已开启"
assert_contains "列表显示另一台仍关闭" "$OUT" "socks2  已关闭"
OUT=$("$PM" sing-box health failover SOCKS-01 on 2>&1)
assert_contains "重复开启没有改动" "$OUT" "已经是开启"
# 状态显示
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "状态显示已开启" "$OUT" "自动故障切换：已开启"
assert_contains "状态显示首选出口" "$OUT" "首选出口：SOCKS5"
assert_contains "状态显示最近故障" "$OUT" "最近故障："
assert_contains "状态显示最近恢复" "$OUT" "最近恢复："
# 同一个 Profile 被多个实例共享时语义一致: 再让 Hysteria2 也用 SOCKS-01
"$PM" sing-box egress Hysteria2-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "共享时两条路由都指向同一个 selector" 2 "$(CFG | grep -c '"outbound": "apm-sel-SOCKS-01"')"
assert_eq "共享时只有一个 selector 定义" 1 "$(CFG | grep -c '"tag": "apm-sel-SOCKS-01"')"
"$PM" sing-box egress Hysteria2-01 socks socks2 >/dev/null 2>&1

# ---- 失败回滚: 校验失败时授权设置完整恢复 ----
CS=$(CFGSUM)
cp "$A/usr/local/bin/sing-box" "$T_TMP/sb.good.fo"
printf 'BADBIN\n' >> "$A/usr/local/bin/sing-box"
OUT=$("$PM" sing-box health failover socks2 on 2>&1)
RC=$?
cp "$T_TMP/sb.good.fo" "$A/usr/local/bin/sing-box"
echo started > "$K/state-sing-box"; "$PM" sing-box restart >/dev/null 2>&1
assert_eq "配置校验失败返回非零" 1 "$([ "$RC" -ne 0 ] && echo 1)"
assert_eq "校验失败保持原配置" "$CS" "$(CFGSUM)"
assert_eq "校验失败保持原授权" SOCKS-01 "$(kv_get "$(CONF)" failover_on)"

# ---- 与监控范围的关系: 监控关闭则不生效 (严格 SOCKS5), 设置保留 ----
"$PM" sing-box health failover socks2 on >/dev/null 2>&1
assert_eq "两台都授权" "SOCKS-01 socks2" "$(kv_get "$(CONF)" failover_on)"
"$PM" sing-box health mode custom >/dev/null 2>&1
"$PM" sing-box health profile socks2 off >/dev/null 2>&1
assert_not_contains "socks2 监控关闭后没有它的 selector" "$(CFG)" 'apm-sel-socks2'
assert_contains "socks2 监控关闭后路由回到严格 SOCKS5" "$(CFG)" '"outbound": "apm-socks-socks2"'
assert_contains "SOCKS-01 仍有 selector" "$(CFG)" 'apm-sel-SOCKS-01'
assert_eq "socks2 的授权设置仍然保留" "SOCKS-01 socks2" "$(kv_get "$(CONF)" failover_on)"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "状态说明没有生效的原因" "$OUT" "现在没有生效"
"$PM" sing-box health profile socks2 on >/dev/null 2>&1
assert_contains "监控重新开启后 selector 回来" "$(CFG)" 'apm-sel-socks2'
"$PM" sing-box health mode all >/dev/null 2>&1
"$PM" sing-box health disable >/dev/null 2>&1
assert_not_contains "整体关闭监控后没有任何 selector" "$(CFG)" selector
assert_contains "整体关闭监控后严格 SOCKS5" "$(CFG)" '"outbound": "apm-socks-SOCKS-01"'
assert_eq "整体关闭监控后授权设置保留" "SOCKS-01 socks2" "$(kv_get "$(CONF)" failover_on)"
"$PM" sing-box health enable >/dev/null 2>&1
assert_contains "整体重新开启后 selector 回来" "$(CFG)" 'apm-sel-SOCKS-01'

# ---- 关闭: 立刻恢复严格 SOCKS5, 配置里不再有 selector ----
OUT=$("$PM" sing-box health failover SOCKS-01 off 2>&1)
assert_eq "关闭成功" 0 "$?"
assert_contains "关闭提示严格 SOCKS5" "$OUT" "严格的 SOCKS5"
assert_not_contains "关闭后没有 SOCKS-01 的 selector" "$(CFG)" 'apm-sel-SOCKS-01'
assert_contains "关闭后路由回到 SOCKS5 出站" "$(CFG)" '"outbound": "apm-socks-SOCKS-01"'
assert_eq "关闭后只剩 socks2 授权" socks2 "$(kv_get "$(CONF)" failover_on)"
"$PM" sing-box health failover socks2 off >/dev/null 2>&1
assert_eq "全部关闭" "" "$(kv_get "$(CONF)" failover_on)"
assert_not_contains "全部关闭后没有 selector" "$(CFG)" selector
assert_eq "全部关闭后配置与默认逐字节相同" "$BASE" "$(CFGSUM)"

# ---- 删除 Profile: 授权设置同步清理 ----
"$PM" sing-box health failover socks2 on >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 direct >/dev/null 2>&1
"$PM" sing-box socks delete socks2 >/dev/null 2>&1
assert_eq "删除 Profile 后授权被清理" "" "$(kv_get "$(CONF)" failover_on)"
assert_eq "删除 Profile 后历史文件被清理" "" "$(ls "$A/var/lib/sing-box/apm-health/socks2.hist" 2>/dev/null)"

# ---- 恢复验证地址 ----
OUT=$("$PM" sing-box health probe-url 2>&1)
assert_contains "默认地址 1" "$OUT" "恢复验证地址 1：https://cp.cloudflare.com/generate_204"
assert_contains "默认地址 2" "$OUT" "恢复验证地址 2：https://www.gstatic.com/generate_204"
OUT=$("$PM" sing-box health probe-url 1 http://example.test/x 2>&1); assert_eq "http 被拒绝" 2 "$?"
assert_contains "拒绝原因" "$OUT" "必须以 https:// 开头"
OUT=$("$PM" sing-box health probe-url 1 'https://example.test/a b' 2>&1); assert_eq "含空格被拒绝" 2 "$?"
OUT=$("$PM" sing-box health probe-url 3 https://example.test/x 2>&1); assert_eq "编号只能是 1 或 2" 2 "$?"
assert_eq "被拒绝时没有保存" "" "$(kv_get "$(CONF)" probe_url)"
"$PM" sing-box health probe-url 1 https://example.test/a >/dev/null 2>&1
"$PM" sing-box health probe-url 2 https://example.test/b >/dev/null 2>&1
assert_eq "地址 1 保存" https://example.test/a "$(kv_get "$(CONF)" probe_url)"
assert_eq "地址 2 保存" https://example.test/b "$(kv_get "$(CONF)" probe_url2)"
assert_eq "运行目录同步两个地址" "https://example.test/a https://example.test/b" "$(tr '\n' ' ' < "$(RUND)/probe_url" | sed 's/ $//')"
"$PM" sing-box health probe-url 1 default >/dev/null 2>&1
assert_eq "default 恢复默认" "" "$(kv_get "$(CONF)" probe_url)"
"$PM" sing-box health probe-url 2 default >/dev/null 2>&1

# ---- TUI: 管理中心 4. 自动故障切换 ----
"$PM" sing-box egress Hysteria2-01 socks SOCKS-01 >/dev/null 2>&1
out=$(T '2\n3\n0\n0\n0\n')
assert_contains "管理中心含 4. 自动故障切换" "$out" "4. 自动故障切换"
out=$(T '2\n3\n4\n0\n0\n0\n0\n')
assert_contains "页面标题" "$out" "SOCKS5 · 自动故障切换"
assert_contains "页面警告会通过 VPS 自己的 IP" "$out" "VPS 自己的 IP"
assert_contains "页面说明默认关闭" "$out" "默认关闭"
assert_contains "服务器一览默认已关闭" "$out" "1. SOCKS-01    已关闭"
assert_contains "页面显示恢复验证地址 1" "$out" "恢复验证地址 1：https://cp.cloudflare.com/generate_204"
assert_contains "页面显示恢复验证地址 2" "$out" "恢复验证地址 2：https://www.gstatic.com/generate_204"
assert_contains "设置恢复验证地址入口在同一页" "$out" "2. 设置恢复验证地址"
FB=$(CFGSUM)
T '2\n3\n4\n1' >/dev/null
assert_eq "确认处 EOF 不开启" "" "$(kv_get "$(CONF)" failover_on)"
assert_eq "确认处 EOF 不改配置" "$FB" "$(CFGSUM)"
T '2\n3\n4\n1\nn\n0\n0\n0\n0\n' >/dev/null
assert_eq "确认处回答 n 不开启" "" "$(kv_get "$(CONF)" failover_on)"
out=$(T '2\n3\n4\n1\n\n0\n0\n0\n0\n')
assert_eq "回车默认 Yes 开启" SOCKS-01 "$(kv_get "$(CONF)" failover_on)"
assert_contains "运行配置带 selector" "$(CFG)" '"tag": "apm-sel-SOCKS-01"'
out=$(T '2\n3\n4\n0\n0\n0\n0\n')
assert_contains "开启后一览显示已开启" "$out" "1. SOCKS-01    已开启"
out=$(T '2\n3\n1\n2\n1\n0\n0\n0\n0\n0\n')
assert_contains "服务器页显示首选出口" "$out" "首选出口：SOCKS5"
assert_contains "服务器页显示当前出口" "$out" "当前出口：SOCKS5"
assert_contains "服务器页显示最近故障" "$out" "最近故障："
assert_contains "服务器页显示最近恢复" "$out" "最近恢复："
T '2\n3\n4\n1\n0\n0\n0\n0\n' >/dev/null
assert_eq "再选一次关闭 (不需要确认)" "" "$(kv_get "$(CONF)" failover_on)"
assert_not_contains "关闭后没有 selector" "$(CFG)" selector
out=$(T '2\n3\n4\n2\nhttp://example.test/x\n\n0\n0\n0\n0\n')
assert_contains "TUI 拒绝 http 地址" "$out" "必须以 https:// 开头"
assert_eq "被拒绝时不保存" "" "$(kv_get "$(CONF)" probe_url)"
T '2\n3\n4\n2\nhttps://example.test/a\nhttps://example.test/b\n0\n0\n0\n0\n' >/dev/null
assert_eq "TUI 保存地址 1" https://example.test/a "$(kv_get "$(CONF)" probe_url)"
assert_eq "TUI 保存地址 2" https://example.test/b "$(kv_get "$(CONF)" probe_url2)"
T '2\n3\n4\n2\ndefault\ndefault\n0\n0\n0\n0\n' >/dev/null
assert_eq "TUI default 恢复默认" "" "$(kv_get "$(CONF)" probe_url)"
assert_not_contains "TUI 页面不含密码" "$out" "$SPW"

# ---- 卸载 / purge 不留下 failover 数据 ----
"$PM" sing-box health failover SOCKS-01 on >/dev/null 2>&1
mkdir -p "$A/var/lib/sing-box/apm-health"
printf 'version=1\nlast_fault=1\nlast_recover=2\n' > "$A/var/lib/sing-box/apm-health/SOCKS-01.hist"
"$PM" sing-box uninstall --purge >/dev/null 2>&1 <<EOF
y
EOF
assert_eq "purge 后历史目录被清理" no "$([ -e "$A/var/lib/sing-box/apm-health" ] && echo yes || echo no)"

t_done
