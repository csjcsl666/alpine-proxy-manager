# shellcheck shell=sh
# 统一 TUI: 菜单导航 能力隐藏 秘密输入 确认机制 与 CLI 的一致性
# 输入由 stdin 驱动, tui_run 不检查 TTY (生产入口 tui_cli 才检查), 业务函数全部走真实实现
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox tui

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_tui.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INST() { printf '%s/etc/alpine-proxy-manager/instances/%s.conf' "$A" "$1"; }
PROF() { printf '%s/etc/alpine-proxy-manager/socks/%s.conf' "$A" "$1"; }
CFGSUM() { sha256sum "$A/etc/sing-box/config.json" | cut -c1-16; }
# 在子 shell 里运行 TUI, 避免它的 trap 覆盖测试框架的清理
T() { printf '%b' "$1" | ( tui_run ) 2>&1; }
ready() { new_s "$1"; "$PM" snell install --port 20000 --psk-stdin >/dev/null 2>&1 <<EOF
TuiSnellPskNotSecret0123456789ab
EOF
    "$PM" sing-box install >/dev/null 2>&1; }
leaks() {
    grep -rlF -- "$1" "$A" 2>/dev/null | while IFS= read -r f; do
        ok=0
        for a in $2; do
            # shellcheck disable=SC2254
            case $f in $a) ok=1 ;; esac
        done
        [ "$ok" = 1 ] || printf '%s\n' "$f"
    done
}
export APM_TUI_ANSI=0
LC_ALL=en_US.UTF-8
export LC_ALL

# ---- 主菜单 ----
ready t1
out=$(T '0\n')
assert_contains "主菜单标题" "$out" "Alpine Proxy Manager"
assert_contains "主菜单版本" "$out" "版本：$(cat "$T_ROOT/VERSION")"
assert_contains "主菜单 Build" "$out" "Build："
for item in "1. Core 管理" "2. 协议实例" "3. 目标访问限制" "4. SOCKS 出口" "5. 客户端配置导出" "6. 状态与诊断" "7. 日志" "8. Manager 管理" "0. 退出"; do
    assert_contains "主菜单项 $item" "$out" "$item"
done
assert_contains "主菜单显示 Snell 运行中" "$out" "Snell      ● 运行中"
assert_contains "主菜单显示 sing-box 运行中" "$out" "sing-box   ● 运行中"
assert_contains "已接管" "$out" "已接管"
assert_contains "正常退出" "$out" "已退出"
out=$(T 'abc\n99\n\n-1\n0\n')
assert_eq "非法输入提示三次" 4 "$(printf '%s\n' "$out" | grep -c '输入无效，请重新选择')"
assert_contains "非法输入后仍可正常退出" "$out" "已退出"
out=$(T '')
assert_contains "EOF 干净退出" "$out" "已退出"
out=$(T 'q\n')
assert_contains "q 也可退出" "$out" "已退出"
SN0=$(snap)
T '1\n1\n1\n\n0\n2\n1\n\n0\n0\n6\n1\n\n2\n\n3\n\n4\n\n0\n7\n1\n\n2\n\n0\n8\n1\n\n0\n0\n' >/dev/null
assert_eq "只读浏览没有改变文件系统" "$SN0" "$(snap)"

# ---- Core 菜单 ----
out=$(T '1\n0\n0\n')
assert_contains "Core 菜单标题" "$out" "Core 管理"
assert_contains "Core 菜单 Snell" "$out" "1. 管理 Snell"
assert_contains "Core 菜单 sing-box" "$out" "2. 管理 sing-box"
out=$(T '1\n1\n0\n0\n0\n')
assert_contains "Snell 状态" "$out" "状态：● 运行中"
assert_contains "Snell 管理状态" "$out" "管理：已接管"
assert_contains "Snell 显示 Release" "$out" "Release：v6.0.0rc2"
assert_contains "Snell 显示监听" "$out" "监听："
for item in "查看详细信息" "停止" "重启" "修改配置" "查看日志" "客户端连接地址（Public Endpoint）" "客户端配置导出" "更新" "卸载"; do
    assert_contains "Snell 运行中菜单含 $item" "$out" ". $item"
done
assert_not_contains "Snell 运行中不显示启动" "$out" ". 启动"
out=$(T '1\n2\n0\n0\n0\n')
for item in "查看详细信息" "停止" "重启" "检查配置" "查看日志" "更新" "卸载"; do
    assert_contains "sing-box 菜单含 $item" "$out" ". $item"
done
assert_contains "sing-box 实例数" "$out" "实例：0，启用 0"
# 停止需要确认, 默认 N
T '1\n1\n2\n\n\n0\n0\n0\n' >/dev/null
core_discover snell
assert_eq "确认默认 N 不停止" running "$CF_STATE"
out=$(T '1\n1\n2\ny\n\n0\n0\n0\n')
core_discover snell
assert_eq "确认 y 停止" stopped "$CF_STATE"
out=$(T '1\n1\n0\n0\n0\n')
assert_contains "停止后显示启动" "$out" ". 启动"
assert_not_contains "停止后不显示停止" "$out" ". 停止"
assert_contains "停止状态符号" "$out" "○ 未运行"
# 启动
out=$(T '1\n1\n2\n\n0\n0\n0\n')
core_discover snell
assert_eq "启动不需要确认" running "$CF_STATE"
# 重启确认
RS=$(grep -c '^snell restart$' "$K/calls" 2>/dev/null || true)
T '1\n1\n3\nn\n\n0\n0\n0\n' >/dev/null
assert_eq "重启默认取消" "$RS" "$(grep -c '^snell restart$' "$K/calls" 2>/dev/null || true)"
T '1\n1\n3\ny\n\n0\n0\n0\n' >/dev/null
assert_eq "重启确认后执行" "$((RS + 1))" "$(grep -c '^snell restart$' "$K/calls" 2>/dev/null || true)"

# ---- External Core ----
ready t2
rm -f "$(META)" "$A/var/lib/alpine-proxy-manager/cores/snell.meta"
out=$(T '1\n1\n0\n0\n0\n')
assert_contains "External 显示未接管" "$out" "现有部署，未接管"
assert_not_contains "External 不显示已接管" "$out" "管理：已接管"
for item in "停止" "重启" "启动" "修改配置" "更新" "卸载" "客户端连接地址"; do
    assert_not_contains "External 隐藏 $item" "$out" ". $item"
done
assert_contains "External 保留只读详情" "$out" ". 查看详细信息"
assert_contains "External 保留日志" "$out" ". 查看日志"
out=$(T '1\n2\n0\n0\n0\n')
assert_contains "External sing-box 显示未接管" "$out" "现有部署，未接管"
for item in "停止" "重启" "检查配置" "更新" "卸载"; do
    assert_not_contains "External sing-box 隐藏 $item" "$out" ". $item"
done
out=$(T '2\n0\n0\n')
assert_contains "External sing-box 下实例页能进入" "$out" "协议实例"
out=$(T '2\n2\n1\n\n0\n0\n0\n')
assert_contains "External 下添加实例被拒绝并说明" "$out" "现有部署，未接管，本项目不会修改它"
assert_eq "External 下没有创建实例" 0 "$(ls "$A/etc/alpine-proxy-manager/instances" 2>/dev/null | wc -l | tr -d ' ')"

# ---- 未安装 ----
new_s t3
out=$(T '1\n1\n0\n0\n0\n')
assert_contains "未安装显示" "$out" "管理：未安装"
assert_contains "未安装显示安装入口" "$out" "安装 Snell"
assert_not_contains "未安装不显示停止" "$out" ". 停止"
out=$(T '2\n2\n\n0\n0\n')
assert_contains "sing-box 未安装时添加实例提示" "$out" "sing-box 尚未安装"
out=$(T '0\n')
assert_contains "未安装的状态符号" "$out" "- 未安装"

# ---- 协议实例: 添加 查看 修改 ----
ready t4
# AnyTLS: 端口 server-name 密码留空自动生成并确认
out=$(T '2\n2\n20443\n\n\ny\n\n0\n0\n')
assert_contains "添加 AnyTLS 成功" "$out" "已添加实例 AnyTLS-01"
assert_contains "自动生成需要确认" "$out" "将自动生成密码，并在结果中显示一次"
assert_eq "实例文件存在" yes "$([ -f "$(INST AnyTLS-01)" ] && echo yes)"
assert_eq "端口" 20443 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
# 取消自动生成
out=$(T '2\n2\n20444\n\n\nn\n\n0\n0\n')
assert_eq "取消后没有创建第二个实例" no "$([ -f "$(INST AnyTLS-02)" ] && echo yes || echo no)"
# 用户提供密码, 不回显, 不进 argv
PWV=TuiUserPasswordNeverEcho0123456789
out=$(T "2\n3\n20500\n\n$PWV\n\n0\n0\n")
assert_eq "Hysteria2 使用用户提供的密码" "$PWV" "$(kv_get "$(INST Hysteria2-01)" credential.password)"
assert_not_contains "用户密码没有出现在输出中" "$out" "$PWV"
assert_contains "说明使用了用户提供的值" "$out" "已使用你提供的值"
# TUIC
out=$(T '2\n4\n20600\n\n\nbbr\n\ny\n\n0\n0\n')
assert_eq "TUIC 拥塞控制" bbr "$(kv_get "$(INST TUIC-01)" transport.congestion_control)"
# Shadowsocks
out=$(T '2\n5\n20700\n\n\ny\n\n0\n0\n')
assert_eq "Shadowsocks 默认 method" 2022-blake3-aes-128-gcm "$(kv_get "$(INST Shadowsocks-01)" credential.method)"
out=$(T '2\n0\n0\n')
for item in "管理现有实例" "添加 AnyTLS" "添加 Hysteria2" "添加 TUIC" "添加 Shadowsocks"; do
    assert_contains "实例菜单含 $item" "$out" ". $item"
done
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    assert_contains "实例列表含 $id" "$out" "$id ("
done
assert_contains "实例列表显示出口" "$out" "出口：DIRECT"
assert_contains "实例列表显示目标访问限制" "$out" "目标访问限制：未启用"
assert_contains "实例列表显示内部监听" "$out" "内部监听："
# 协议名没有被翻译
assert_not_contains "没有翻译协议名" "$out" "任意TLS"
# 实例详情: 管理现有实例 第 N 个
detail() { T "2\n1\n$1\n0\n0\n0\n"; }
out=$(detail 1)
assert_contains "AnyTLS 详情" "$out" "类型：anytls"
assert_contains "AnyTLS 显示 TLS" "$out" "TLS："
assert_contains "AnyTLS 密码只显示已配置" "$out" "密码：已配置"
assert_contains "AnyTLS 客户端连接地址未配置" "$out" "客户端连接地址：未配置"
for item in "修改实例" "禁用" "目标访问限制" "SOCKS 出口" "客户端连接地址（Public Endpoint）" "客户端配置导出" "查看凭据" "删除实例"; do
    assert_contains "实例详情含 $item" "$out" ". $item"
done
out=$(detail 4)
assert_contains "TUIC 详情含 UUID" "$out" "UUID："
assert_contains "TUIC 详情含拥塞控制" "$out" "拥塞控制：bbr"
out=$(detail 3)
assert_contains "Shadowsocks 详情含 method" "$out" "method："
assert_contains "Shadowsocks 不使用 TLS" "$out" "TLS：不使用"
assert_not_contains "Shadowsocks 不显示 server-name" "$out" "server-name"
# 修改菜单按协议显示
edit() { T "2\n1\n$1\n1\n0\n0\n0\n0\n"; }
out=$(edit 1)
assert_contains "AnyTLS 修改含 server-name" "$out" "修改 TLS server-name"
assert_not_contains "AnyTLS 修改不含 UUID" "$out" "修改 UUID"
assert_not_contains "AnyTLS 修改不含 method" "$out" "修改 method"
out=$(edit 4)
assert_contains "TUIC 修改含 UUID" "$out" "修改 UUID"
assert_contains "TUIC 修改含 congestion-control" "$out" "修改 congestion-control"
out=$(edit 3)
assert_contains "Shadowsocks 修改含 method" "$out" "修改 method 与密钥"
assert_not_contains "Shadowsocks 修改不含 server-name" "$out" "server-name"
assert_contains "Shadowsocks 用密钥措辞" "$out" "修改密钥"
# 修改端口, 业务层校验: 无效值被业务层拒绝
out=$(T '2\n1\n1\n1\n1\nabc\n\n0\n0\n0\n0\n')
assert_contains "无效端口由业务层报错" "$out" "错误:"
assert_eq "无效端口没有改动" 20443 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
assert_contains "失败后提示返回码" "$out" "该操作没有完成"
out=$(T '2\n1\n1\n1\n1\n20445\n\n0\n0\n0\n0\n')
assert_eq "修改端口成功" 20445 "$(kv_get "$(INST AnyTLS-01)" listen_port)"
# 修改密码: 输入不回显路径, 不进 argv
PW2=TuiNewPasswordNeverEcho0123456789ab
out=$(T "2\n1\n1\n1\n4\n$PW2\n\n0\n0\n0\n0\n")
assert_eq "修改密码" "$PW2" "$(kv_get "$(INST AnyTLS-01)" credential.password)"
assert_not_contains "新密码没有出现在输出里" "$out" "$PW2"
# 无末尾换行的秘密 (EOF 前最后一个输入)
# 启用与禁用
T '2\n1\n1\n2\n\n0\n0\n0\n' >/dev/null
assert_eq "禁用" false "$(kv_get "$(INST AnyTLS-01)" enabled)"
out=$(detail 1)
assert_contains "已禁用实例显示启用入口" "$out" ". 启用"
T '2\n1\n1\n2\n\n0\n0\n0\n' >/dev/null
assert_eq "再启用" true "$(kv_get "$(INST AnyTLS-01)" enabled)"
# 一致性: TUI 详情里的事实与 CLI show 一致
cli=$("$PM" sing-box show AnyTLS-01 | sed -n 's/^  监听：//p')
out=$(detail 1)
assert_contains "TUI 与 CLI 的监听一致" "$out" "监听：$cli"

# ---- 目标访问限制 ----
policy() { T "$1"; }
out=$(T '3\n1\n0\n0\n')
assert_contains "目标访问限制页" "$out" "目标访问限制 AnyTLS-01"
for item in "设置为不限制" "设置为 Allowlist" "查看允许目标" "添加允许目标" "删除允许目标" "清空允许目标"; do
    assert_contains "目标访问限制含 $item" "$out" ". $item"
done
out=$(T '3\n1\n2\ny\n\n0\n0\n')
assert_contains "空 Allowlist 需要确认" "$out" "新的 Allowlist 为空"
assert_contains "空 Allowlist 的警告" "$out" "当前 Allowlist 为空，该实例将拒绝所有目标"
out=$(T '3\n1\n2\nn\n\n0\n0\n')
T '3\n1\n4\n192.0.2.10\n1080\n\n0\n0\n' >/dev/null
assert_contains "添加允许目标" "$(cat "$(INST AnyTLS-01)")" "192.0.2.10:1080"
out=$(T '3\n1\n3\n\n0\n0\n')
assert_contains "查看允许目标" "$out" "192.0.2.10:1080"
out=$(T '3\n1\n0\n0\n')
assert_not_contains "有目标后不再警告" "$out" "当前 Allowlist 为空"
T '3\n1\n5\n192.0.2.10\n1080\n\n0\n0\n' >/dev/null
out=$(T '3\n1\n0\n0\n')
assert_contains "删除后再次警告" "$out" "当前 Allowlist 为空，该实例将拒绝所有目标"
T '3\n1\n6\ny\n\n0\n0\n' >/dev/null
T '3\n1\n6\nn\n\n0\n0\n' >/dev/null
T '3\n1\n1\n\n0\n0\n' >/dev/null
assert_not_contains "不限制后没有 relay_access" "$(cat "$(INST AnyTLS-01)")" relay_access
out=$(T '3\n1\n4\n999.1.1.1\n80\n\n0\n0\n')
assert_contains "无效目标由业务层拒绝" "$out" "错误:"

# ---- SOCKS 出口 ----
out=$(T '4\n0\n0\n')
assert_contains "SOCKS 页" "$out" "没有 Profile"
for item in "管理 Profile" "添加 SOCKS Profile" "批量启用" "批量禁用"; do assert_contains "SOCKS 页含 $item" "$out" ". $item"; done
out=$(T '4\n2\n192.0.2.50\n1080\n\n\n\n0\n0\n')
assert_contains "添加无认证 Profile" "$out" "已添加 SOCKS Profile SOCKS-01"
SPW=TuiSocksPasswordNeverEcho01234567
out=$(T "4\n2\n192.0.2.51\n1081\nsocks2\nsocksuser\n$SPW\n\n0\n0\n")
assert_eq "SOCKS 密码已保存" "$SPW" "$(kv_get "$(PROF socks2)" password)"
assert_not_contains "SOCKS 密码没有回显到输出" "$out" "$SPW"
assert_eq "SOCKS 用户名" socksuser "$(kv_get "$(PROF socks2)" username)"
out=$(T '4\n0\n0\n')
assert_contains "列表含认证" "$out" "用户名认证"
assert_contains "列表含无认证" "$out" "无认证"
# 绑定出口
out=$(T '2\n1\n1\n4\n0\n0\n0\n0\n')
assert_contains "出口页含 DIRECT" "$out" ". DIRECT"
assert_contains "出口页含 Profile" "$out" ". SOCKS Profile SOCKS-01"
out=$(T '2\n1\n1\n4\n2\n\n0\n0\n0\n0\n')
assert_contains "绑定时明确提示" "$out" "该实例流量将通过 SOCKS-01 出口，不会自动测试，也不会自动回落 DIRECT"
assert_eq "绑定成功" SOCKS-01 "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
out=$(T '2\n0\n0\n')
assert_contains "实例列表显示 SOCKS 出口" "$out" "出口：SOCKS SOCKS-01"
# 删除被引用的 Profile: 业务层拒绝
out=$(T '4\n1\n1\n6\ny\n\n0\n0\n0\n')
assert_eq "被引用的 Profile 没有被删除" yes "$([ -f "$(PROF SOCKS-01)" ] && echo yes)"
assert_contains "业务层拒绝说明" "$out" "AnyTLS-01"
# 批量禁用需要确认
T '4\n4\n\n\n0\n0\n' >/dev/null
assert_eq "批量禁用默认取消" true "$(kv_get "$(PROF SOCKS-01)" enabled)"
T '4\n4\ny\n\n0\n0\n' >/dev/null
assert_eq "批量禁用确认后执行" false "$(kv_get "$(PROF SOCKS-01)" enabled)"
out=$(T '4\n1\n1\n0\n0\n0\n')
assert_contains "禁用后菜单显示启用" "$out" ". 启用"
T '4\n3\n\n0\n0\n' >/dev/null
assert_eq "批量启用" true "$(kv_get "$(PROF SOCKS-01)" enabled)"
# 恢复 DIRECT
T '2\n1\n1\n4\n1\n\n0\n0\n0\n0\n' >/dev/null
assert_eq "回到 DIRECT" "" "$(kv_get "$(INST AnyTLS-01)" egress_socks)"
# 现在可以删除未被引用的 Profile, 默认 N
T '4\n1\n1\n6\n\n\n0\n0\n0\n' >/dev/null
assert_eq "默认 N 不删除" yes "$([ -f "$(PROF SOCKS-01)" ] && echo yes)"
T '4\n1\n1\n6\ny\n\n0\n0\n0\n' >/dev/null
assert_eq "确认后删除" no "$([ -f "$(PROF SOCKS-01)" ] && echo yes || echo no)"

# ---- 客户端连接地址 ----
CS0=$(CFGSUM)
RS0=$(count_calls restart)
out=$(T '2\n1\n1\n5\n0\n0\n0\n0\n')
assert_contains "endpoint 页说明" "$out" "不配置 NAT 与防火墙"
T '2\n1\n1\n5\n1\nexample.com\n32001\n\n0\n0\n0\n0\n' >/dev/null
assert_eq "TUI 设置 endpoint" example.com "$(kv_get "$(INST AnyTLS-01)" public.host)"
assert_eq "endpoint 没有改运行配置" "$CS0" "$(CFGSUM)"
assert_eq "endpoint 没有重启" "$RS0" "$(count_calls restart)"
cli=$("$PM" sing-box endpoint AnyTLS-01 show | sed -n 's/^  客户端连接地址：//p')
out=$(detail 1)
assert_contains "详情与 CLI 的 endpoint 一致" "$out" "客户端连接地址：$cli"
T '2\n1\n1\n5\n2\n\n0\n0\n0\n0\n' >/dev/null
assert_eq "TUI 清除 endpoint" "" "$(kv_get "$(INST AnyTLS-01)" public.host)"
out=$(T '2\n1\n1\n5\n1\n0.0.0.0\n443\n\n0\n0\n0\n0\n')
assert_contains "无效 endpoint 由业务层拒绝" "$out" "错误:"

# ---- 客户端配置导出 ----
for id in AnyTLS-01 Hysteria2-01 TUIC-01 Shadowsocks-01; do
    "$PM" sing-box endpoint $id set example.com "3200$(printf '%s' "$id" | wc -c | tr -d ' ')" >/dev/null 2>&1
done
expo() { T "2\n1\n$1\n6\n$2\n0\n0\n0\n0\n"; }
out=$(expo 1 0)
assert_contains "导出页含证书校验说明" "$out" "证书校验：跳过（自签名，免维护）"
for item in "查看连接信息" "查看凭据" "导出 sing-box JSON" "导出 sing-box JSON（隐藏凭据）" "可选：嵌入证书固定校验" "导出分享 URL" "显示 QR（需要 qrencode）" "设置客户端连接地址"; do
    assert_contains "AnyTLS 导出页含 $item" "$out" "$item"
done
assert_not_contains "不把嵌入证书说成推荐" "$out" "推荐"
out=$(expo 4 0)
assert_contains "TUIC 说明没有 URL" "$out" "TUIC 没有稳定的通用分享 URL"
assert_not_contains "TUIC 不提供 URL 入口" "$out" ". 导出分享 URL"
assert_not_contains "TUIC 不提供 QR 入口" "$out" ". 显示 QR"
out=$(expo 3 0)
assert_not_contains "Shadowsocks 不显示证书校验" "$out" "证书校验"
assert_not_contains "Shadowsocks 没有嵌入证书选项" "$out" "嵌入证书"
assert_contains "Shadowsocks 有 URL" "$out" ". 导出分享 URL"
# 查看连接信息不含凭据
APW=$(kv_get "$(INST AnyTLS-01)" credential.password)
out=$(expo 1 1)
assert_contains "连接信息" "$out" "协议：AnyTLS"
assert_not_contains "连接信息不含凭据" "$out" "$APW"
# 查看凭据需要确认
out=$(T '2\n1\n1\n6\n2\nn\n\n0\n0\n0\n0\n')
assert_not_contains "拒绝确认不显示凭据" "$out" "$APW"
assert_contains "确认提示" "$out" "即将显示客户端凭据。终端记录或截图可能包含 Secret。"
out=$(T '2\n1\n1\n6\n2\n\n\n0\n0\n0\n0\n')
assert_not_contains "默认 N 不显示凭据" "$out" "$APW"
out=$(T '2\n1\n1\n6\n2\ny\n\n0\n0\n0\n0\n')
assert_contains "确认后显示凭据" "$out" "密码：$APW"
# JSON 需要确认, 隐藏凭据版本不需要
out=$(T '2\n1\n1\n6\n3\nn\n\n0\n0\n0\n0\n')
assert_not_contains "JSON 拒绝确认不输出" "$out" '"type": "anytls"'
out=$(T '2\n1\n1\n6\n3\ny\n\n0\n0\n0\n0\n')
assert_contains "JSON 确认后输出" "$out" '"type": "anytls"'
assert_contains "JSON 含密码" "$out" "\"password\": \"$APW\""
assert_contains "JSON 提示重定向" "$out" "export AnyTLS-01 sing-box > client.json"
out=$(T '2\n1\n1\n6\n4\n\n0\n0\n0\n0\n')
assert_contains "隐藏凭据版本" "$out" '"password": "REDACTED"'
assert_not_contains "隐藏凭据版本不含密码" "$out" "$APW"
out=$(T '2\n1\n1\n6\n5\ny\n\n0\n0\n0\n0\n')
assert_contains "证书固定可选" "$out" '"certificate": ['
assert_not_contains "证书固定版本没有 insecure" "$out" insecure
out=$(T '2\n1\n1\n6\n6\ny\n\n0\n0\n0\n0\n')
assert_contains "URL" "$out" "anytls://"
# QR 缺依赖
out=$(T '2\n1\n1\n6\n7\ny\n\n0\n0\n0\n0\n')
assert_contains "缺 qrencode 的提示" "$out" "当前未安装可选工具 qrencode"
assert_contains "不自动安装" "$out" "TUI 不会自动安装"
assert_eq "没有安装 qrencode" 0 "$(grep -c qrencode "$A/.apk-installed" 2>/dev/null || true)"
# 有 qrencode 时
mkdir -p "$A/usr/bin"
printf '#!/bin/sh\ncat > "%s/qr.in"\nprintf QRDONE\\n\n' "$T_TMP" > "$A/usr/bin/qrencode"
chmod +x "$A/usr/bin/qrencode"
out=$(T '2\n1\n1\n6\n7\ny\n\n0\n0\n0\n0\n')
assert_contains "有 qrencode 时显示" "$out" "QRDONE"
assert_contains "stdin 收到 URL" "$(cat "$T_TMP/qr.in")" "anytls://"
rm -f "$A/usr/bin/qrencode"
# 主菜单第 5 项可以选 Snell
out=$(T '5\n5\n0\n0\n')
assert_contains "Snell 导出页" "$out" "客户端配置导出 snell"
assert_contains "Snell 没有 URL" "$out" "Snell 没有通用分享 URL"
assert_not_contains "Snell 没有 JSON 入口" "$out" "导出 sing-box JSON"
"$PM" snell endpoint set 203.0.113.9 32100 >/dev/null 2>&1
out=$(T '5\n5\n1\n\n0\n0\n')
assert_contains "Snell 连接信息" "$out" "协议：Snell"
out=$(T '5\n5\n2\ny\n\n0\n0\n')
assert_contains "Snell 凭据" "$out" "psk：TuiSnellPskNotSecret0123456789ab"

# ---- 删除实例, 默认 N ----
T '2\n1\n2\n8\n\n\n0\n0\n0\n' >/dev/null
assert_eq "删除默认 N" yes "$([ -f "$(INST Hysteria2-01)" ] && echo yes)"
T '2\n1\n2\n8\ny\n\n0\n0\n0\n' >/dev/null
assert_eq "确认后删除" no "$([ -f "$(INST Hysteria2-01)" ] && echo yes || echo no)"

# ---- 日志 状态 Manager ----
out=$(T '7\n0\n0\n')
assert_contains "日志页" "$out" "1. Snell 日志"
assert_contains "日志提示" "$out" "日志可能包含访问目标"
out=$(T '6\n0\n0\n')
for item in "系统状态" "Core 状态" "doctor 环境检查" "资源使用"; do assert_contains "状态页含 $item" "$out" ". $item"; done
out=$(T '6\n1\n\n0\n0\n')
assert_contains "系统状态来自 report_status" "$out" "Server SOCKS Egress"
out=$(T '6\n3\n\n0\n0\n')
assert_contains "doctor 来自 report_doctor" "$out" "Alpine Linux："
out=$(T '6\n4\n\n0\n0\n')
assert_contains "资源页" "$out" "系统内存："
assert_contains "资源页说明不持续刷新" "$out" "不做持续刷新"
out=$(T '8\n0\n0\n')
assert_contains "Manager 页版本" "$out" "当前版本：$(cat "$T_ROOT/VERSION")"
for item in "查看版本" "检查环境" "查看帮助"; do assert_contains "Manager 页含 $item" "$out" ". $item"; done
out=$(T '8\n1\n\n0\n0\n')
assert_contains "查看版本" "$out" "Alpine Proxy Manager $(cat "$T_ROOT/VERSION")"

# ---- 秘密输入 helper ----
# 无末尾换行
printf 'abc' | { tui_read_secret "p: " >/dev/null; assert_eq "无末尾换行的秘密被完整读取" abc "$TUI_SECRET"; }
printf '' | { tui_read_secret "p: " >/dev/null; assert_eq "空输入得到空值" "" "$TUI_SECRET"; }
printf 'x y\n' | { tui_read_secret "p: " >/dev/null; assert_eq "含空格的秘密原样保留" "x y" "$TUI_SECRET"; }
# stty 路径: 用假 stty 记录调用
mkdir -p "$A/bin"
cat > "$A/bin/stty" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T_TMP/stty.log"
case \$1 in -g) printf 'SAVEDSTATE\n' ;; esac
EOF
chmod +x "$A/bin/stty"
: > "$T_TMP/stty.log"
out=$( (APM_TUI_TEST_TTY=1; export APM_TUI_TEST_TTY; printf 'topsecret\n' | { tui_read_secret "p: "; printf '[%s]' "$TUI_SECRET"; }) 2>&1)
assert_contains "秘密被读取" "$out" "[topsecret]"
assert_eq "stty 调用顺序: 保存, 关回显, 恢复" "-g
-echo
SAVEDSTATE" "$(cat "$T_TMP/stty.log")"
: > "$T_TMP/stty.log"
( APM_TUI_TEST_TTY=1; export APM_TUI_TEST_TTY; printf '' | tui_read_secret "p: " >/dev/null 2>&1 )
assert_eq "EOF 路径同样恢复" "-g
-echo
SAVEDSTATE" "$(cat "$T_TMP/stty.log")"
: > "$T_TMP/stty.log"
( TUI_STTY_SAVED=XSTATE; _tui_on_int >/dev/null 2>&1 )
assert_eq "Ctrl+C 处理返回 130" 130 $?
assert_eq "Ctrl+C 恢复终端" "XSTATE" "$(cat "$T_TMP/stty.log")"
out=$( (TUI_STTY_SAVED=YSTATE; _tui_on_int) 2>&1 )
assert_contains "Ctrl+C 简洁退出信息" "$out" "已退出"
: > "$T_TMP/stty.log"
( TUI_STTY_SAVED=ZSTATE; _tui_restore )
assert_eq "restore 只恢复一次并清空" "ZSTATE" "$(cat "$T_TMP/stty.log")"
# 没有 stty 时拒绝输入秘密
mv "$A/bin/stty" "$A/bin/stty.off"
out=$( (APM_TUI_TEST_TTY=1; export APM_TUI_TEST_TTY; printf 'secret\n' | { tui_read_secret "p: "; printf 'rc=%s secret=[%s]' "$?" "$TUI_SECRET"; }) 2>&1)
assert_contains "无法关闭回显时拒绝" "$out" "无法关闭终端回显"
assert_contains "拒绝时没有读取秘密" "$out" "secret=[]"
mv "$A/bin/stty.off" "$A/bin/stty"

# ---- 秘密不进 argv, 不泄漏 ----
assert_eq "TUI 源码没有把秘密放进命令行参数" 0 "$(grep -c -E -- '--(password|psk) "\$' "$T_ROOT/lib/tui.sh")"
for s in "$PWV" "$PW2" "$SPW" TuiSnellPskNotSecret0123456789ab; do
    assert_eq "秘密只在允许的位置 [$(printf '%s' "$s" | cut -c1-8)]" "" "$(leaks "$s" "*/etc/alpine-proxy-manager/instances/* */etc/alpine-proxy-manager/socks/* */etc/sing-box/config.json */etc/snell/* */var/lib/alpine-proxy-manager/backups/* */qr.in")"
done

# ---- 颜色 与 终端 ----
ready t5
out=$(APM_TUI_ANSI=1 NO_COLOR=1 T '0\n')
assert_eq "NO_COLOR 没有颜色转义" 0 "$(printf '%s' "$out" | grep -c "$(printf '\033')\[3")"
out=$(APM_TUI_ANSI=1 TERM=xterm T '0\n')
assert_contains "ANSI 模式清屏" "$out" "$(printf '\033')[H"
assert_contains "ANSI 模式有颜色" "$out" "$(printf '\033')[32m"
out=$(APM_TUI_ANSI=1 TERM=dumb T '0\n')
assert_contains "TERM=dumb 使用纯文本符号" "$out" "[RUNNING]"
assert_not_contains "TERM=dumb 不含 ANSI" "$out" "$(printf '\033')["
out=$(LC_ALL=C T '0\n')
assert_contains "非 UTF-8 使用 ASCII 状态" "$out" "[RUNNING]"
assert_not_contains "非 UTF-8 不使用圆点" "$out" "●"
out=$(LC_ALL=zh_CN.UTF-8 T '0\n')
assert_contains "UTF-8 使用圆点" "$out" "● 运行中"
out=$(LC_ALL=C TERM=xterm APM_TUI_ANSI=1 T '0\n')
assert_contains "非 UTF-8 终端提示中文可能无法显示" "$out" "可能无法正确显示中文"
assert_contains "但功能仍可用" "$out" "已退出"

# ---- 非 root ----
ready t6
SN1=$(snap)
out=$(APM_EUID=1000 T '1\n1\n2\n\n0\n0\n0\n')
assert_contains "非 root 的提示" "$(APM_EUID=1000 T '0\n')" "当前不是 root"
assert_contains "写操作提示需要 root" "$out" "此操作需要 root"
core_discover snell
assert_eq "非 root 没有停止服务" running "$CF_STATE"
assert_not_contains "不自动 sudo" "$out" "sudo -n"
out=$(APM_EUID=1000 T '2\n2\n20999\n0\n0\n')
assert_eq "非 root 没有创建实例" 0 "$(ls "$A/etc/alpine-proxy-manager/instances" 2>/dev/null | wc -l | tr -d ' ')"

# ---- 入口 ----
ready t7
"$PM" tui </dev/null >/dev/null 2>&1
assert_eq "非 TTY 的 tui 子命令被拒绝" 2 $?
assert_contains "非 TTY 的提示" "$("$PM" tui </dev/null 2>&1)" "TUI 需要交互式终端"
out=$("$PM" </dev/null 2>&1)
assert_contains "无参数且非 TTY 保持帮助输出" "$out" "用法: proxy-manager"
assert_contains "帮助列出 tui" "$out" "tui "
"$PM" help </dev/null >/dev/null 2>&1
assert_eq "help 不变" 0 $?
out=$("$PM" status </dev/null 2>&1)
assert_contains "status 不受影响" "$out" "Server SOCKS Egress"
assert_fail "没有常驻进程" sh -c 'ps 2>/dev/null | grep -q "[p]roxy-manager tui"'
t_done
