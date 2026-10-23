# shellcheck shell=sh
# shellcheck disable=SC2015,SC2016 # 测试里 A && B || C 用来记录通过或失败
# sing-box SOCKS5 健康监控的产品集成: 配置生成 监控服务的安装与跟随 启用与关闭 卸载清理 状态显示 凭据与密钥安全
# 模拟系统里没有真实的 sing-box 与 OpenRC, 状态机与真实事件流由 test_sbhealth.sh 和 tests/e2e/sbhealth.sh 覆盖
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox sbhealth

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_sbhealth_lifecycle.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

CFG() { cat "$A/etc/sing-box/config.json"; }
CONF() { printf '%s/etc/alpine-proxy-manager/sbhealth.conf' "$A"; }
INITF() { printf '%s/etc/init.d/apm-sbhealth' "$A"; }
RUND() { printf '%s/run/apm-sbhealth' "$A"; }
INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
hcalls() { grep -c "^apm-sbhealth $1\$" "$K/calls" 2>/dev/null || true; }
hstate() { cat "$K/state-apm-sbhealth" 2>/dev/null || echo none; }
ready() { new_s "$1"; "$PM" sing-box install >/dev/null 2>&1; "$PM" sing-box add anytls --port 20443 >/dev/null 2>&1; }

# ---- 没有 SOCKS 绑定: 完全不出现健康监控 ----
ready l1
assert_not_contains "没有 SOCKS 出站时配置没有 experimental" "$(CFG)" experimental
assert_not_contains "没有 SOCKS 出站时配置没有 clash_api" "$(CFG)" clash_api
assert_eq "没有创建 sbhealth.conf" no "$([ -e "$(CONF)" ] && echo yes || echo no)"
assert_eq "没有安装监控服务脚本" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "没有调用监控服务" 0 "$(grep -c apm-sbhealth "$K/calls")"
BASE_CFG=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)

# ---- 绑定 SOCKS Profile: 配置带 Clash API, 监控服务安装并启动 ----
printf 'FictSocksPassNotReal0001\n' | "$PM" sing-box socks add --name SOCKS-01 --server 192.0.2.10 --port 1080 --username fictuser --password-stdin >/dev/null 2>&1
assert_eq "只创建 Profile 不绑定: 配置不变且没有监控" "$BASE_CFG" "$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)"
assert_eq "只创建 Profile 不绑定: 没有 sbhealth.conf" no "$([ -e "$(CONF)" ] && echo yes || echo no)"
OUT=$("$PM" sing-box egress AnyTLS-01 socks SOCKS-01 2>&1)
assert_eq "绑定成功" 0 "$?"
assert_contains "配置带 experimental" "$(CFG)" '"experimental"'
assert_contains "Clash API 只监听回环" "$(CFG)" '"external_controller": "127.0.0.1:'
PORT=$(kv_get "$(CONF)" api_port)
SEC=$(kv_get "$(CONF)" secret)
assert_contains "配置里的端口与 sbhealth.conf 一致" "$(CFG)" "127.0.0.1:$PORT"
assert_contains "配置里的密钥与 sbhealth.conf 一致" "$(CFG)" "\"secret\": \"$SEC\""
assert_eq "密钥是 32 位十六进制" 32 "$(printf '%s' "$SEC" | grep -Ec '^[0-9a-f]{32}$' | awk '{ print ($1 == 1) ? 32 : 0 }')"
assert_eq "端口在 29000 到 29999" yes "$([ "$PORT" -ge 29000 ] && [ "$PORT" -le 29999 ] && echo yes)"
assert_eq "sbhealth.conf 权限 600" 600 "$(stat -c %a "$(CONF)")"
assert_eq "默认启用" true "$(kv_get "$(CONF)" enabled)"
assert_eq "监控服务脚本存在" yes "$([ -f "$(INITF)" ] && echo yes)"
assert_eq "监控服务脚本可执行" 755 "$(stat -c %a "$(INITF)")"
assert_contains "服务脚本有 Manager 标记" "$(cat "$(INITF)")" "# apm-managed: apm-sbhealth"
assert_contains "服务以 sing-box 用户运行" "$(cat "$(INITF)")" 'command_user="sing-box:sing-box"'
assert_contains "服务命令是 proxy-manager sing-box health run" "$(cat "$(INITF)")" 'command_args="sing-box health run"'
assert_contains "服务依赖 sing-box" "$(cat "$(INITF)")" "need sing-box"
assert_not_contains "服务脚本里没有密钥" "$(cat "$(INITF)")" "$SEC"
assert_eq "加入默认运行级别" yes "$([ -L "$A/etc/runlevels/default/apm-sbhealth" ] && echo yes)"
assert_eq "监控服务已启动" started "$(hstate)"
assert_eq "密钥与 Profile 密码只在受控文件里" "" "$(grep -rlF -- "$SEC" "$A" 2>/dev/null | grep -v '/etc/sing-box/config.json$\|/etc/alpine-proxy-manager/sbhealth.conf$\|/etc/alpine-proxy-manager/backups\|config.json.bak' )"
assert_eq "SOCKS 密码没有进入 sbhealth.conf" "" "$(grep -F FictSocksPass "$(CONF)")"
assert_not_contains "命令输出不显示密钥" "$OUT" "$SEC"
assert_eq "sing-box 配置是 sing-box check 通过的" 0 "$("$PM" sing-box check >/dev/null 2>&1; echo $?)"

# ---- 稳定: 再次应用不换密钥与端口 ----
printf 'FictSocksPassNotReal0002\n' | "$PM" sing-box socks add --name SOCKS-02 --server 192.0.2.11 --port 1081 --username fictuser2 --password-stdin >/dev/null 2>&1
"$PM" sing-box add hysteria2 --port 20444 >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 socks SOCKS-02 >/dev/null 2>&1
assert_eq "再次绑定后端口不变" "$PORT" "$(kv_get "$(CONF)" api_port)"
assert_eq "再次绑定后密钥不变" "$SEC" "$(kv_get "$(CONF)" secret)"
assert_eq "配置里仍是同一个密钥" 1 "$(CFG | grep -c "$SEC")"
assert_eq "配置里每个 Profile 只有一个 SOCKS 出站且只有一个 experimental" 1 "$(CFG | grep -c '"experimental"')"

# ---- 解除全部绑定: 监控服务与运行时状态被移除, 设置保留 ----
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 direct >/dev/null 2>&1
assert_not_contains "解除绑定后配置没有 experimental" "$(CFG)" experimental
assert_eq "解除绑定后配置与从未绑定时逐字节相同 (实例集合不同则不比较, 这里只比较无 SOCKS 出站)" 0 "$(CFG | grep -c apm-socks)"
assert_eq "监控服务脚本被移除" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "运行级别链接被移除" no "$([ -L "$A/etc/runlevels/default/apm-sbhealth" ] && echo yes || echo no)"
assert_eq "监控服务已停止" stopped "$(hstate)"
assert_eq "sbhealth.conf 保留 (密钥稳定)" "$SEC" "$(kv_get "$(CONF)" secret)"
assert_eq "运行时状态目录被清除" no "$([ -e "$(RUND)" ] && echo yes || echo no)"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "重新绑定: 使用同一个密钥" "$SEC" "$(kv_get "$(CONF)" secret)"
assert_eq "重新绑定: 监控服务重新安装并启动" started "$(hstate)"

# ---- 停止失败: 不删除服务脚本与运行目录, 如实报错, 之后可以再次清理 ----
touch "$K/fail_stop-apm-sbhealth"
OUT=$("$PM" sing-box egress AnyTLS-01 direct 2>&1)
assert_contains "停止失败: 如实报错" "$OUT" "无法停止健康监控服务"
assert_eq "停止失败: 服务脚本保留 (仍能用 rc-service 管理)" yes "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "停止失败: 运行目录保留" yes "$([ -e "$(RUND)" ] && echo yes || echo no)"
assert_eq "停止失败: 监控服务仍在运行" started "$(hstate)"
assert_eq "停止失败: sing-box 出口仍已改为直连" 0 "$(CFG | grep -c apm-socks)"
rm -f "$K/fail_stop-apm-sbhealth"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
assert_eq "停止恢复正常后: 服务脚本被移除" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "停止恢复正常后: 监控服务已停止" stopped "$(hstate)"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
assert_eq "再次绑定后监控服务运行" started "$(hstate)"

# ---- 关闭与启用 ----
OUT=$("$PM" sing-box health disable 2>&1)
assert_eq "关闭成功" 0 "$?"
assert_contains "关闭提示" "$OUT" "健康监控已关闭"
assert_not_contains "关闭后配置没有 experimental" "$(CFG)" experimental
assert_eq "关闭后 enabled=false" false "$(kv_get "$(CONF)" enabled)"
assert_eq "关闭后没有监控服务" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_contains "关闭后 SOCKS 出站仍在 (转发不受影响)" "$(CFG)" "apm-socks-SOCKS-01"
assert_contains "关闭后绑定的路由规则仍在 (仍然 fail-closed 不回退 DIRECT)" "$(CFG)" '"outbound": "apm-socks-SOCKS-01"'
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "状态命令说明已关闭" "$OUT" "健康监控：已关闭"
OUT=$("$PM" sing-box health enable 2>&1)
assert_eq "启用成功" 0 "$?"
assert_contains "启用后配置带 experimental" "$(CFG)" experimental
assert_eq "启用后使用同一个密钥" "$SEC" "$(kv_get "$(CONF)" secret)"
assert_eq "启用后监控服务启动" started "$(hstate)"
OUT=$("$PM" sing-box health bogus 2>&1)
assert_eq "未知子命令返回 2" 2 "$?"

# ---- 跟随 sing-box 的启停 ----
"$PM" sing-box stop >/dev/null 2>&1
assert_eq "sing-box 停止后监控服务也停止" stopped "$(hstate)"
"$PM" sing-box start >/dev/null 2>&1
assert_eq "sing-box 启动后监控服务启动" started "$(hstate)"
"$PM" sing-box restart >/dev/null 2>&1
assert_eq "sing-box 重启后监控服务在运行" started "$(hstate)"
assert_eq "监控服务启动失败不影响 sing-box 操作" 0 "$(touch "$K/fail_start-apm-sbhealth"; "$PM" sing-box restart >/dev/null 2>&1; echo $?)"
rm -f "$K/fail_start-apm-sbhealth"

# ---- 状态显示 (构造运行时状态) ----
core_discover singbox
mkdir -p "$(RUND)/../../proc/777" 2>/dev/null
mkdir -p "$A/proc/777"
D=$(RUND)
mkdir -p "$D"
printf '777\n' > "$D/daemon.pid"
date +%s > "$D/connected"
NOW=$(date +%s)
mkst() { # 名称 状态 原因 last_ok last_fail
    printf 'version=1\nstate=%s\nreason=%s\nsince=%s\nlast_ok=%s\nlast_fail=%s\nlast_fail_reason=%s\nstreak=0\nupdated=%s\n' "$2" "$3" "$NOW" "${4:-0}" "${5:-0}" "$3" "$NOW" > "$D/apm-socks-$1.state"
}
mkst SOCKS-01 healthy "" "$NOW" 0
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "状态命令: 健康监控启用" "$OUT" "健康监控：启用"
assert_contains "状态命令: 监控进程运行中" "$OUT" "监控进程：运行中"
assert_contains "状态命令: 说明没有主动探测" "$OUT" "没有事件时不做任何主动探测"
assert_contains "状态命令: 正常" "$OUT" "健康状态：正常"
assert_contains "状态命令: 没有故障记录" "$OUT" "最近故障：无记录"
assert_contains "状态命令: 没有恢复记录" "$OUT" "最近恢复：无记录"
assert_contains "状态命令: 首选出口" "$OUT" "首选出口：SOCKS5"
assert_contains "状态命令: 默认关闭自动故障切换" "$OUT" "自动故障切换：已关闭"
mkst SOCKS-01 unhealthy auth "$((NOW - 100))" "$((NOW - 5))"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "故障" "$OUT" "健康状态：故障"
assert_contains "不可用原因" "$OUT" "原因：SOCKS5 认证失败"
mkst SOCKS-01 recovering refused "$((NOW - 100))" "$((NOW - 5))"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "恢复中" "$OUT" "健康状态：恢复中"
mkst SOCKS-01 degraded timeout "$NOW" "$NOW"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "异常" "$OUT" "健康状态：异常"
assert_contains "异常原因" "$OUT" "连接上游超时"
mkst SOCKS-01 healthy "" "$((NOW - 2000))" 0
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "很久没有流量: 保留最近一次判断而不是过期" "$OUT" "健康状态：正常"
assert_not_contains "不再有 15 分钟过期说明" "$OUT" "之后没有新连接可以证明"
mkst SOCKS-01 healthy "" "$NOW" 0
rm -f "$D/connected"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "监控未订阅: 显示监控异常" "$OUT" "健康状态：监控异常"
date +%s > "$D/connected"
rm -rf "$A/proc/777"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "监控进程不在了: 显示监控异常" "$OUT" "健康状态：监控异常"
mkdir -p "$A/proc/777"
"$PM" sing-box stop >/dev/null 2>&1
mkdir -p "$D"; printf '777\n' > "$D/daemon.pid"; date +%s > "$D/connected"; mkst SOCKS-01 healthy "" "$NOW" 0
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "sing-box 停止: 不显示上游健康" "$OUT" "sing-box 未运行"
assert_not_contains "sing-box 停止: 不显示正常" "$OUT" "健康状态：正常"
assert_not_contains "状态输出不含用户名" "$OUT" fictuser
assert_not_contains "状态输出不含 SOCKS 密码" "$OUT" FictSocksPass
assert_not_contains "状态输出不含密钥" "$OUT" "$SEC"
"$PM" sing-box start >/dev/null 2>&1

# ---- 现有页面直接显示健康状态 ----
mkst SOCKS-01 unhealthy auth "$((NOW - 100))" "$((NOW - 5))"
date +%s > "$D/connected"; mkdir -p "$A/proc/777"; printf '777\n' > "$D/daemon.pid"
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "实例出口显示上游健康" "$OUT" "上游健康：● 故障（SOCKS5 认证失败）"
assert_contains "实例出口仍显示 Profile 是否启用" "$OUT" "出口：SOCKS SOCKS-01 (已启用)"
OUT=$("$PM" sing-box socks list 2>&1)
assert_contains "Profile 列表显示上游健康" "$OUT" "上游健康：● 故障"
OUT=$("$PM" sing-box socks show SOCKS-01 2>&1)
assert_contains "Profile 详情显示健康" "$OUT" "健康状态：故障"
assert_contains "Profile 详情显示原因" "$OUT" "原因：SOCKS5 认证失败"
assert_contains "Profile 详情显示最近故障" "$OUT" "最近故障："
assert_not_contains "Profile 详情的健康块不含密码" "$OUT" FictSocksPass
mkst SOCKS-01 healthy "" "$NOW" 0
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "正常时实例出口显示" "$OUT" "上游健康：● 正常"
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
OUT=$("$PM" sing-box socks list 2>&1)
assert_not_contains "没有被引用的 Profile 不显示上游健康" "$OUT" "上游健康"
OUT=$("$PM" sing-box socks show SOCKS-01 2>&1)
assert_not_contains "没有被引用的 Profile 详情没有健康块" "$OUT" "健康状态："
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1

# ---- 监控范围: 全部监控 / 自定义监控 (v0.8.1) ----
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
"$PM" sing-box egress Hysteria2-01 socks SOCKS-02 >/dev/null 2>&1
assert_eq "新安装默认全部监控" all "$("$PM" sing-box health status 2>&1 | grep -q '监控范围：全部监控' && echo all)"
assert_eq "默认没有 mode 键 (沿用 v0.8.0 数据)" "" "$(kv_get "$(CONF)" mode)"
assert_eq "默认没有被关闭的服务器" "" "$(kv_get "$(CONF)" monitor_off)"
assert_contains "全部监控时配置带 experimental" "$(CFG)" experimental
# 全部监控模式下不允许悄悄修改单台服务器
OUT=$("$PM" sing-box health profile SOCKS-01 off 2>&1)
assert_eq "全部监控模式下单台开关被拒绝" 2 "$?"
assert_contains "提示先切换到自定义监控" "$OUT" "请先执行 sing-box health mode custom"
assert_eq "被拒绝时没有改动设置" "" "$(kv_get "$(CONF)" monitor_off)"
OUT=$("$PM" sing-box health profile SOCKS-01 on 2>&1)
assert_eq "全部监控模式下开启也被拒绝" 2 "$?"
# 切换为自定义监控: 首次默认各服务器均开启
RB0=$(count_calls restart)
HS0=$(hcalls start)
OUT=$("$PM" sing-box health mode custom 2>&1)
assert_eq "切换为自定义监控成功" 0 "$?"
assert_contains "切换提示" "$OUT" "已切换为自定义监控"
assert_eq "mode 持久化" custom "$(kv_get "$(CONF)" mode)"
assert_eq "首次进入自定义监控时各服务器默认开启" "" "$(kv_get "$(CONF)" monitor_off)"
assert_eq "切换模式没有重启 sing-box (配置没有变化)" "$RB0" "$(count_calls restart)"
assert_eq "切换模式没有重启监控服务" "$HS0" "$(hcalls start)"
assert_eq "切换模式没有改变 AnyTLS-01 的出口绑定" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
assert_eq "切换模式没有改变 Hysteria2-01 的出口绑定" SOCKS-02 "$(kv_get "$(INST Hysteria2-01)" egress_socks)"
assert_eq "切换模式没有改变 Profile 自己的启用状态" true "$(kv_get "$A/etc/alpine-proxy-manager/socks/SOCKS-01.conf" enabled)"
OUT=$("$PM" sing-box health mode custom 2>&1)
assert_contains "重复切换没有改动" "$OUT" "已经是自定义监控"
# 自定义监控: 单台开关独立生效
OUT=$("$PM" sing-box health profile SOCKS-01 off 2>&1)
assert_eq "关闭 SOCKS-01 的监控成功" 0 "$?"
assert_contains "关闭提示" "$OUT" "已关闭 SOCKS-01 的健康监控，不影响它的转发"
assert_eq "monitor_off 记录被关闭的服务器" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_eq "整体开关不受影响" true "$(kv_get "$(CONF)" enabled)"
assert_contains "还有服务器在监控: 配置仍带 experimental" "$(CFG)" experimental
assert_eq "还有服务器在监控: 没有重启 sing-box" "$RB0" "$(count_calls restart)"
assert_eq "监控服务仍在运行且没有被重启" "$HS0" "$(hcalls start)"
assert_eq "监控服务仍在运行" started "$(hstate)"
assert_contains "运行目录里有关闭记录" "$(cat "$(RUND)/profiles")" "SOCKS-01 off 1"
assert_contains "另一台服务器仍然开启" "$(cat "$(RUND)/profiles")" "SOCKS-02 on 0"
assert_eq "出口绑定没有变化" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
assert_contains "SOCKS-01 的出站和路由仍在 (转发不受影响)" "$(CFG)" '"outbound": "apm-socks-SOCKS-01"'
OUT=$("$PM" sing-box socks show SOCKS-01 2>&1)
assert_contains "关闭后详情显示监控已关闭" "$OUT" "健康状态：监控已关闭"
assert_contains "关闭后说明" "$OUT" "这台服务器没有开启监控"
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "关闭后实例出口显示监控已关闭 (不是故障也不是未知)" "$OUT" "上游健康：- 监控已关闭"
mkdir -p "$A/proc/777"; printf '777\n' > "$(RUND)/daemon.pid"; date +%s > "$(RUND)/connected"
mkst SOCKS-02 healthy "" "$(date +%s)" 0
mkst SOCKS-01 healthy "" "$(date +%s)" 0
OUT=$("$PM" sing-box egress Hysteria2-01 show 2>&1)
assert_contains "另一台服务器照常显示正常" "$OUT" "上游健康：● 正常"
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_not_contains "被排除的服务器不显示旧的正常" "$OUT" "● 正常"
OUT=$("$PM" sing-box health profile SOCKS-01 off 2>&1)
assert_contains "重复关闭没有改动" "$OUT" "已经是关闭"
# 全部都关闭: 不需要 Clash API 也不需要常驻进程
"$PM" sing-box health profile SOCKS-02 off >/dev/null 2>&1
assert_not_contains "全部关闭后配置没有 experimental" "$(CFG)" experimental
assert_eq "全部关闭后监控服务脚本被移除" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "全部关闭后监控服务已停止" stopped "$(hstate)"
assert_eq "两台都记录为关闭" "SOCKS-01 SOCKS-02" "$(kv_get "$(CONF)" monitor_off)"
assert_contains "全部关闭后 SOCKS 出站和路由仍在 (转发不受影响)" "$(CFG)" '"outbound": "apm-socks-SOCKS-02"'
# 自定义 -> 全部 -> 自定义: 原来的独立设置完整恢复
"$PM" sing-box health profile SOCKS-02 on >/dev/null 2>&1
assert_eq "SOCKS-02 重新开启" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_contains "重新开启后配置带 experimental" "$(CFG)" experimental
assert_eq "重新开启后监控服务运行" started "$(hstate)"
OUT=$("$PM" sing-box health mode all 2>&1)
assert_eq "切换为全部监控成功" 0 "$?"
assert_contains "切换提示说明设置已保留" "$OUT" "自定义监控里的设置已保留"
assert_eq "切换为全部监控后自定义设置原样保留" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_contains "全部监控: SOCKS-01 也参与" "$(cat "$(RUND)/profiles")" "SOCKS-01 on "
assert_not_contains "全部监控: 没有关闭项" "$(cat "$(RUND)/profiles")" " off "
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "监控没有订阅时如实显示监控异常 (不沿用旧的正常)" "$OUT" "上游健康：! 监控异常"
OUT=$("$PM" sing-box health mode custom 2>&1)
assert_eq "再次切换为自定义监控" custom "$(kv_get "$(CONF)" mode)"
assert_eq "自定义设置完整恢复: SOCKS-01 关闭" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_contains "恢复后运行目录里 SOCKS-01 关闭" "$(cat "$(RUND)/profiles")" "SOCKS-01 off "
assert_contains "恢复后运行目录里 SOCKS-02 开启" "$(cat "$(RUND)/profiles")" "SOCKS-02 on "
# 整体开关 (v0.8.0 的 enable / disable): 含义不变, 不改写监控范围
"$PM" sing-box health disable >/dev/null 2>&1
assert_eq "整体关闭" false "$(kv_get "$(CONF)" enabled)"
assert_eq "整体关闭不改变模式" custom "$(kv_get "$(CONF)" mode)"
assert_eq "整体关闭不改变自定义设置" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_not_contains "整体关闭后配置没有 experimental" "$(CFG)" experimental
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "整体关闭时状态命令说明" "$OUT" "健康监控：已关闭"
OUT=$("$PM" sing-box health mode all 2>&1)
assert_contains "整体关闭时切换模式会提示" "$OUT" "被整体关闭"
assert_eq "整体关闭时切换模式只改模式" false "$(kv_get "$(CONF)" enabled)"
"$PM" sing-box health mode custom >/dev/null 2>&1
"$PM" sing-box health enable >/dev/null 2>&1
assert_eq "整体重新开启" true "$(kv_get "$(CONF)" enabled)"
assert_eq "整体重新开启后自定义设置仍在" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_contains "整体重新开启后配置带 experimental" "$(CFG)" experimental
# 参数与错误
OUT=$("$PM" sing-box health profile NOPE off 2>&1)
assert_eq "不存在的服务器被拒绝" 1 "$?"
OUT=$("$PM" sing-box health profile SOCKS-01 maybe 2>&1)
assert_eq "无效参数返回 2" 2 "$?"
OUT=$("$PM" sing-box health mode weird 2>&1)
assert_eq "无效模式返回 2" 2 "$?"
OUT=$("$PM" sing-box health mode 2>&1)
assert_eq "缺少模式返回 2" 2 "$?"
OUT=$("$PM" sing-box health all-on 2>&1)
assert_eq "不再有会覆盖独立设置的 all-on" 2 "$?"
OUT=$(APM_EUID=1000 "$PM" sing-box health profile SOCKS-02 off 2>&1)
assert_eq "非 root 被拒绝" 4 "$?"
OUT=$(APM_EUID=1000 "$PM" sing-box health mode all 2>&1)
assert_eq "非 root 切换模式被拒绝" 4 "$?"
assert_eq "非 root 没有改动设置" SOCKS-01 "$(kv_get "$(CONF)" monitor_off)"
assert_eq "非 root 没有改动模式" custom "$(kv_get "$(CONF)" mode)"
# 开机恢复: 服务脚本的 start_pre 按模式写出范围, 全部监控没有关闭项
"$PM" sing-box health profile SOCKS-02 off >/dev/null 2>&1
"$PM" sing-box health profile SOCKS-02 on >/dev/null 2>&1
assert_contains "服务脚本按 mode 恢复范围" "$(cat "$(INITF)")" "^mode="
assert_contains "服务脚本从 monitor_off 写出关闭项" "$(cat "$(INITF)")" "monitor_off="
# 删除服务器时清理它的监控设置与状态
"$PM" sing-box health profile SOCKS-01 off >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
mkst SOCKS-01 healthy "" "$(date +%s)" 0
"$PM" sing-box socks delete SOCKS-01 >/dev/null 2>&1
assert_eq "删除后 monitor_off 被清理" "" "$(kv_get "$(CONF)" monitor_off)"
assert_eq "删除后状态文件被清理" no "$([ -e "$(RUND)/apm-socks-SOCKS-01.state" ] && echo yes || echo no)"
assert_not_contains "删除后 profiles 里没有它" "$(cat "$(RUND)/profiles" 2>/dev/null)" "SOCKS-01 "
# 新建的服务器默认参与监控 (自定义监控里没有关闭记录就是开启)
printf 'FictSocksPassNotReal0009\n' | "$PM" sing-box socks add --name SOCKS-09 --server 192.0.2.19 --port 1089 --username u9 --password-stdin >/dev/null 2>&1
assert_eq "新建服务器默认开启监控" 0 "$(sbh_profile_on SOCKS-09; echo $?)"
# 配置回滚: 范围变化让运行配置变化 (自定义里全部关闭 -> 全部监控 时 Clash API 段重新出现) 而校验失败时, 设置恢复原样
"$PM" sing-box egress Hysteria2-01 direct >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-09 >/dev/null 2>&1
"$PM" sing-box health profile SOCKS-09 off >/dev/null 2>&1
assert_not_contains "回滚测试的前提: 配置没有 experimental" "$(CFG)" experimental
CFG_BEFORE=$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)
cp "$A/usr/local/bin/sing-box" "$T_TMP/sb.good"
printf 'BADBIN\n' >> "$A/usr/local/bin/sing-box"
OUT=$("$PM" sing-box health mode all 2>&1)
assert_eq "校验失败时返回非零" 1 "$?"
cp "$T_TMP/sb.good" "$A/usr/local/bin/sing-box"
assert_eq "校验失败时运行配置不变" "$CFG_BEFORE" "$(sha256sum "$A/etc/sing-box/config.json" | cut -c1-16)"
assert_eq "校验失败时模式恢复原样" custom "$(kv_get "$(CONF)" mode)"
assert_eq "校验失败时自定义设置不变" SOCKS-09 "$(kv_get "$(CONF)" monitor_off)"
assert_eq "校验失败时出口绑定不变" SOCKS-09 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
# v0.8.0 升级兼容: 只有 enabled 端口 密钥的旧文件, 视为全部监控; 显式关闭的状态保留
printf 'schema=1\nenabled=false\napi_port=29555\nsecret=0123456789abcdef0123456789abcdef\n' > "$(CONF)"
assert_eq "旧文件没有 mode 视为全部监控" all "$(sbh_mode)"
assert_eq "旧文件里显式关闭的整体开关仍然关闭" 1 "$(sbh_enabled; echo $?)"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "旧文件整体关闭: 状态命令说明" "$OUT" "健康监控：已关闭"
assert_contains "旧文件: 监控范围是全部监控" "$OUT" "监控范围：全部监控"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-09 >/dev/null 2>&1
assert_eq "升级后的任何操作都不会擅自重新开启" false "$(kv_get "$(CONF)" enabled)"
assert_not_contains "整体关闭时配置没有 experimental" "$(CFG)" experimental
"$PM" sing-box health enable >/dev/null 2>&1

# ---- 卸载清理 ----
OUT=$("$PM" sing-box uninstall 2>&1)
assert_eq "卸载成功" 0 "$?"
assert_eq "卸载后监控服务脚本被移除" no "$([ -e "$(INITF)" ] && echo yes || echo no)"
assert_eq "卸载后运行级别链接被移除" no "$([ -L "$A/etc/runlevels/default/apm-sbhealth" ] && echo yes || echo no)"
assert_eq "卸载后监控服务已停止" stopped "$(hstate)"
assert_eq "不带 purge 的卸载保留 sbhealth.conf" yes "$([ -e "$(CONF)" ] && echo yes || echo no)"
ready l3
printf 'FictSocksPassNotReal0003\n' | "$PM" sing-box socks add --name SOCKS-01 --server 192.0.2.10 --port 1080 --username fictuser --password-stdin >/dev/null 2>&1
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1
SEC=$(kv_get "$(CONF)" secret)
assert_eq "purge 前存在密钥" 32 "${#SEC}"
OUT=$("$PM" sing-box uninstall --purge 2>&1)
assert_eq "purge 成功" 0 "$?"
assert_eq "purge 删除 sbhealth.conf" no "$([ -e "$(CONF)" ] && echo yes || echo no)"
assert_eq "purge 后没有监控痕迹" "" "$(grep -rlF -- "$SEC" "$A" 2>/dev/null)"

# ---- 版本无关: 没有安装 Core 时 health 命令被拒绝而不是创建文件 ----
new_s l2
OUT=$("$PM" sing-box health enable 2>&1)
assert_eq "未安装 sing-box 时 enable 被拒绝" 4 "$?"
assert_eq "被拒绝时没有创建任何文件" no "$([ -e "$(CONF)" ] && echo yes || echo no)"

t_done
