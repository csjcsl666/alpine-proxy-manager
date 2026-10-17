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
assert_contains "状态命令: 健康" "$OUT" "状态：● 健康"
assert_contains "状态命令: 有最近成功时间" "$OUT" "最近成功：$(date -d "@$NOW" '+%H:%M:%S')"
assert_contains "状态命令: 没有失败" "$OUT" "最近失败：无"
mkst SOCKS-01 unhealthy auth "$((NOW - 100))" "$((NOW - 5))"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "不可用" "$OUT" "状态：● 不可用"
assert_contains "不可用原因" "$OUT" "原因：SOCKS5 认证失败"
mkst SOCKS-01 recovering refused "$((NOW - 100))" "$((NOW - 5))"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "恢复中" "$OUT" "状态：● 恢复中"
mkst SOCKS-01 degraded timeout "$NOW" "$NOW"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "异常" "$OUT" "状态：● 异常"
assert_contains "异常原因" "$OUT" "连接上游超时"
mkst SOCKS-01 healthy "" "$((NOW - 2000))" 0
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "健康但太久没有证据: 显示未知" "$OUT" "状态：○ 未知"
assert_contains "说明原因" "$OUT" "之后没有新连接可以证明"
mkst SOCKS-01 healthy "" "$NOW" 0
rm -f "$D/connected"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "监控未订阅: 不宣称健康" "$OUT" "状态：○ 未知"
assert_contains "监控未订阅: 说明" "$OUT" "监控未运行"
date +%s > "$D/connected"
rm -rf "$A/proc/777"
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "监控进程不在了: 不宣称健康" "$OUT" "监控未运行"
mkdir -p "$A/proc/777"
"$PM" sing-box stop >/dev/null 2>&1
mkdir -p "$D"; printf '777\n' > "$D/daemon.pid"; date +%s > "$D/connected"; mkst SOCKS-01 healthy "" "$NOW" 0
OUT=$("$PM" sing-box health status 2>&1)
assert_contains "sing-box 停止: 不显示上游健康" "$OUT" "sing-box 未运行"
assert_not_contains "sing-box 停止: 不显示健康" "$OUT" "状态：● 健康"
assert_not_contains "状态输出不含用户名" "$OUT" fictuser
assert_not_contains "状态输出不含 SOCKS 密码" "$OUT" FictSocksPass
assert_not_contains "状态输出不含密钥" "$OUT" "$SEC"
"$PM" sing-box start >/dev/null 2>&1

# ---- 现有页面直接显示健康状态 ----
mkst SOCKS-01 unhealthy auth "$((NOW - 100))" "$((NOW - 5))"
date +%s > "$D/connected"; mkdir -p "$A/proc/777"; printf '777\n' > "$D/daemon.pid"
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "实例出口显示上游健康" "$OUT" "上游健康：● 不可用（SOCKS5 认证失败）"
assert_contains "实例出口仍显示 Profile 是否启用" "$OUT" "出口：SOCKS SOCKS-01 (已启用)"
OUT=$("$PM" sing-box socks list 2>&1)
assert_contains "Profile 列表显示上游健康" "$OUT" "上游健康：● 不可用"
OUT=$("$PM" sing-box socks show SOCKS-01 2>&1)
assert_contains "Profile 详情显示健康" "$OUT" "状态：● 不可用"
assert_contains "Profile 详情显示原因" "$OUT" "原因：SOCKS5 认证失败"
assert_contains "Profile 详情显示最近失败" "$OUT" "最近失败："
assert_not_contains "Profile 详情的健康块不含密码" "$OUT" FictSocksPass
mkst SOCKS-01 healthy "" "$NOW" 0
OUT=$("$PM" sing-box egress AnyTLS-01 show 2>&1)
assert_contains "健康时实例出口显示" "$OUT" "上游健康：● 健康"
"$PM" sing-box egress AnyTLS-01 direct >/dev/null 2>&1
OUT=$("$PM" sing-box socks list 2>&1)
assert_not_contains "没有被引用的 Profile 不显示上游健康" "$OUT" "上游健康"
OUT=$("$PM" sing-box socks show SOCKS-01 2>&1)
assert_not_contains "没有被引用的 Profile 详情没有健康块" "$OUT" "状态：●"
"$PM" sing-box egress AnyTLS-01 socks SOCKS-01 >/dev/null 2>&1

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
