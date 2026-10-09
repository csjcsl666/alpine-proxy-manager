# shellcheck shell=sh
# Snell 网络功能 (SOCKS5 出口 与 目标访问限制) 的配置层与运行时文件生成
# 全部在模拟系统中进行: 假的 rc-service apk, 真实的最小 ELF 桩代替 graftcp snell-server
# 真实进程的行为 (流量路径, 零命中, 故障, OpenRC 生命周期) 由 tests/e2e 下的端到端测试覆盖
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell snellnet

PM="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_snellnet.sh 全部跳过"
    t_done
    exit $?
fi

MSG_OK='2026-01-01 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.0 (Aug  7 2026)'
ZIPS=$T_TMP/zips
DL=$T_TMP/dl
mk_dl_shim "$DL"
mk_snell_zip "$ZIPS" v6.0.0rc2 "$MSG_OK"
# 假的 graftcp: 真实的 ELF, 运行时输出版本; 下载垫片按文件名取
mk_elf_stub "$ZIPS/graftcp-v0.8.3-apm1-linux-x86_64" "graftcp version v0.8.3-apm1"
mk_elf_stub "$ZIPS/graftcp-wrong-version" "graftcp version v0.8.3"
GC_SHA=$(sha256sum "$ZIPS/graftcp-v0.8.3-apm1-linux-x86_64" | awk '{ print $1 }')
printf 'not an elf\n' > "$ZIPS/graftcp-not-elf"
NOT_ELF_SHA=$(sha256sum "$ZIPS/graftcp-not-elf" | awk '{ print $1 }')
HOSTS=$T_TMP/hosts
printf 't1.example.test 192.0.2.10\nt2.example.test 192.0.2.20 2001:DB8::20\nflip.example.test 192.0.2.30\n' > "$HOSTS"

new_m() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_sim_system "$A"
    K=$A/fake-rc
    mkdir -p "$K"
    echo stopped > "$K/state"
    : > "$K/dl.log"
    APM_SYSROOT=$A
    APM_FAKE_RC_DIR=$K
    APM_EUID=0
    APM_ARCH=x86_64
    APM_DOWNLOADER=$DL
    APM_TEST_ZIPS=$ZIPS
    APM_TEST_DL_LOG=$K/dl.log
    APM_SNELL_WAIT=1
    APM_SNN_URL=http://example.invalid/graftcp-v0.8.3-apm1-linux-x86_64
    APM_SNN_SHA256=$GC_SHA
    APM_SNN_NO_PREFLIGHT=1
    APM_SNN_HOSTS=$HOSTS
    export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER APM_TEST_ZIPS APM_TEST_DL_LOG APM_SNELL_WAIT APM_SNN_URL APM_SNN_SHA256 APM_SNN_NO_PREFLIGHT APM_SNN_HOSTS
    unset APM_VAR APM_ETC APM_BACKUP_DIR APM_BACKUP_KEEP
}
install_snell() {
    "$PM" snell install --port 20000 >/dev/null 2>&1
    "$PM" snell stop >/dev/null 2>&1
}
snap() { (cd "$A" && find . \( -path ./fake-rc -o -path ./.chown.log -o -path ./.apk-installed -o -path './var/tmp/*' \) -prune -o -print | sort; cat etc/passwd etc/group; ls -A var/tmp | wc -l); }
EGRESS=/etc/alpine-proxy-manager/snell-egress.conf
ACCESS=/etc/alpine-proxy-manager/snell-access.conf
INIT=/etc/init.d/snell
PWTXT=FakeUpstreamPassNotSecret0001

# ---- 未安装 Snell: 全部拒绝, 不创建任何文件 ----
new_m n0
BEFORE=$(snap)
OUT=$("$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth 2>&1)
assert_eq "未安装时 egress set 被拒绝" 4 "$?"
assert_contains "说明原因" "$OUT" "Snell"
OUT=$("$PM" snell access add 192.0.2.1 443 2>&1)
assert_eq "未安装时 access add 被拒绝" 4 "$?"
assert_eq "未安装时没有改动任何文件" "$BEFORE" "$(snap)"

# ---- show: 未配置 ----
new_m s1
install_snell
OUT=$("$PM" snell egress show)
assert_contains "egress show 未配置" "$OUT" "状态：未配置"
OUT=$("$PM" snell access show)
assert_contains "access show 未配置" "$OUT" "状态：未配置"
assert_contains "access show 说明 UDP 拒绝" "$OUT" "UDP 一律拒绝"

# ---- egress set: 参数校验 ----
BEFORE=$(snap)
for args in "--server 127.0.0.1 --port 1080" \
    "--server 127.0.0.1 --port 1080 --username u" \
    "--server 127.0.0.1 --port 1080 --no-auth --username u --password-stdin" \
    "--server 127.0.0.1 --port 1080 --no-auth --password-stdin" \
    "--server 127.0.0.1 --port 1080 --username u --password x" \
    "--server 127.0.0.1 --port 0 --no-auth" \
    "--server 127.0.0.1 --port 70000 --no-auth" \
    "--server bad_host! --port 1080 --no-auth" \
    "--port 1080 --no-auth" \
    "--server 127.0.0.1 --no-auth" \
    "--server 127.0.0.1 --port 1080 --no-auth --bogus"; do
    # shellcheck disable=SC2086
    OUT=$(printf 'x\n' | "$PM" snell egress set $args 2>&1)
    RC=$?
    assert_eq "egress set 拒绝: $args" 2 "$RC"
done
OUT=$("$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth --dns-server not-an-ip 2>&1)
assert_eq "无效的 dns-server 被拒绝" 1 "$?"
assert_eq "参数错误没有改动任何文件" "$BEFORE" "$(snap)"
OUT=$("$PM" snell egress set --server 127.0.0.1 --port 1080 --username u --password x 2>&1)
assert_contains "命令行密码被明确拒绝" "$OUT" "password-stdin"

# ---- egress set: 成功 ----
OUT=$("$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth 2>&1)
assert_eq "egress set 本机上游成功" 0 "$?"
assert_eq "配置文件权限 600" 600 "$(stat -c %a "$A$EGRESS")"
assert_eq "新配置默认未启用" false "$(kv_get "$A$EGRESS" enabled)"
assert_eq "host" 127.0.0.1 "$(kv_get "$A$EGRESS" host)"
assert_eq "port" 1080 "$(kv_get "$A$EGRESS" port)"
OUT=$(printf '%s\n' "$PWTXT" | "$PM" snell egress set --server ::1 --port 1081 --username up --password-stdin 2>&1)
assert_eq "egress set IPv6 带认证成功" 0 "$?"
assert_eq "IPv6 上游规范化保存带方括号" "[::1]" "$(kv_get "$A$EGRESS" host)"
assert_eq "用户名" up "$(kv_get "$A$EGRESS" username)"
assert_not_contains "set 输出不含密码" "$OUT" "$PWTXT"
OUT=$("$PM" snell egress show)
assert_not_contains "show 不含密码" "$OUT" "$PWTXT"
assert_contains "show 说明认证" "$OUT" "密码已配置"
assert_eq "除配置文件外没有任何文件含密码" "$A$EGRESS" "$(grep -rl "$PWTXT" "$A" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
OUT=$("$PM" snell egress set --server up.example.test --port 1082 --no-auth --dns-server 9.9.9.9 2>&1)
assert_eq "egress set 域名上游成功" 0 "$?"
assert_eq "no-auth 清除了用户名" "" "$(kv_get "$A$EGRESS" username)"
assert_eq "dns_server" 9.9.9.9 "$(kv_get "$A$EGRESS" dns_server)"
assert_eq "未启用时服务脚本保持普通模式" 0 "$(grep -c '^# apm-net:' "$A$INIT")"

# ---- 启用: 取消, 校验和不匹配, 非 ELF, 版本不符 ----
OUT=$("$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth 2>&1)
BEFORE=$(snap)
OUT=$("$PM" snell egress enable </dev/null 2>&1)
assert_eq "无终端且没有 --yes 时取消" 1 "$?"
assert_contains "取消的说明" "$OUT" "已取消"
assert_contains "取消前列出要安装的组件" "$OUT" "graftcp"
assert_contains "取消前列出软件包" "$OUT" "unbound"
assert_eq "取消没有改动任何文件" "$BEFORE" "$(snap)"
OUT=$(APM_SNN_SHA256=0000000000000000000000000000000000000000000000000000000000000000 "$PM" snell egress enable --yes 2>&1)
assert_eq "校验和不匹配被拒绝" 1 "$?"
assert_contains "校验和错误说明" "$OUT" "校验和不匹配"
assert_eq "校验和失败没有改动任何文件" "$BEFORE" "$(snap)"
OUT=$(APM_SNN_URL=http://example.invalid/graftcp-not-elf APM_SNN_SHA256=$NOT_ELF_SHA "$PM" snell egress enable --yes 2>&1)
assert_eq "非 ELF 被拒绝" 1 "$?"
assert_contains "非 ELF 说明" "$OUT" "不是 ELF"
OUT=$(APM_SNN_URL=http://example.invalid/graftcp-wrong-version APM_SNN_SHA256=$(sha256sum "$ZIPS/graftcp-wrong-version" | awk '{ print $1 }') "$PM" snell egress enable --yes 2>&1)
assert_eq "版本不符被拒绝" 1 "$?"
assert_contains "版本不符说明" "$OUT" "版本不是"
assert_eq "安装失败没有改动任何文件" "$BEFORE" "$(snap)"
assert_eq "没有残留的 graftcp" 0 "$([ -e "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp" ] && echo 1 || echo 0)"

# ---- 启用成功 (Snell 未运行) ----
OUT=$("$PM" snell egress enable --yes 2>&1)
assert_eq "egress enable 成功" 0 "$?"
assert_contains "输出列出 graftcp" "$OUT" "graftcp v0.8.3-apm1"
assert_eq "graftcp 权限" 755 "$(stat -c %a "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp")"
assert_eq "graftcp 是 ELF" elf "$(core_file_kind "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp")"
assert_contains "安装了 unbound" "$(cat "$A/.apk-installed")" "unbound"
assert_not_contains "出口模式不装 tinyproxy" "$(cat "$A/.apk-installed")" "tinyproxy"
assert_eq "配置已启用" true "$(kv_get "$A$EGRESS" enabled)"
INITTXT=$(cat "$A$INIT")
assert_contains "服务脚本有网络功能标记" "$INITTXT" "# apm-net: egress"
assert_contains "服务脚本仍有 Manager 标记" "$INITTXT" "# apm-managed: snell"
assert_contains "服务脚本运行包装脚本" "$INITTXT" 'command_args="/usr/local/lib/alpine-proxy-manager/current/lib/snellnet-run.sh"'
assert_contains "服务脚本记录真实二进制" "$INITTXT" 'apm_binary="/usr/local/bin/snell-server"'
assert_contains "服务脚本启动前生成运行时文件" "$INITTXT" 'proxy-manager" snell net-prepare'
assert_contains "服务脚本停止后清理" "$INITTXT" "rm -rf /run/apm-snell"
assert_not_contains "网络模式不导出 LD_PRELOAD" "$INITTXT" "export LD_PRELOAD"
assert_not_contains "网络模式没有 command_user" "$INITTXT" "command_user"
META=$A/var/lib/alpine-proxy-manager/snellnet/deps.meta
assert_eq "依赖记录 graftcp 版本" v0.8.3-apm1 "$(kv_get "$META" graftcp_version)"
assert_eq "依赖记录校验和" "$GC_SHA" "$(kv_get "$META" graftcp_sha256)"
assert_contains "依赖记录 apk 包" "$(kv_get "$META" apk_installed_by_apm)" "unbound"
OUT=$("$PM" snell egress enable --yes 2>&1)
assert_contains "重复启用是空操作" "$OUT" "已经启用"
core_discover snell
assert_eq "发现: 二进制来自 apm_binary" /usr/local/bin/snell-server "$CF_BINARY"
assert_eq "发现: 状态 stopped" stopped "$CF_STATE"
OUT=$("$PM" snell status)
assert_contains "status 显示网络功能" "$OUT" "网络功能：SOCKS5 出口"

# ---- 互斥 ----
BEFORE=$(snap)
OUT=$("$PM" snell access enable --yes 2>&1)
assert_eq "出口启用时 access enable 被拒绝" 4 "$?"
assert_contains "互斥说明" "$OUT" "互斥"
assert_contains "给出操作指引" "$OUT" "snell egress disable"
assert_eq "互斥拒绝没有改动任何文件" "$BEFORE" "$(snap)"
# 名单可以在出口启用时编辑, 但不能启用
OUT=$("$PM" snell access add 192.0.2.1 443 2>&1)
assert_eq "出口启用时仍可编辑名单" 0 "$?"
assert_eq "名单保持未启用" false "$(kv_get "$A$ACCESS" enabled)"

# ---- 禁用 ----
OUT=$("$PM" snell egress disable 2>&1)
assert_eq "egress disable 成功" 0 "$?"
assert_eq "配置已禁用" false "$(kv_get "$A$EGRESS" enabled)"
assert_eq "服务脚本回到普通模式" 0 "$(grep -c '^# apm-net:' "$A$INIT")"
assert_contains "普通模式脚本有 command_user" "$(cat "$A$INIT")" 'command_user="snell:snell"'
assert_contains "普通模式脚本导出 LD_PRELOAD" "$(cat "$A$INIT")" 'export LD_PRELOAD="/lib/libgcompat.so.0"'
assert_eq "普通模式脚本没有 net-prepare" 0 "$(grep -c 'net-prepare' "$A$INIT")"
OUT=$("$PM" snell egress disable 2>&1)
assert_contains "重复禁用是空操作" "$OUT" "没有启用"
assert_eq "禁用后 graftcp 仍保留 (再次启用不用重新下载)" 1 "$([ -x "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp" ] && echo 1 || echo 0)"

# ---- 名单 ----
new_m a1
install_snell
for hp in "192.0.2.1 443" "192.0.2.1 8443" "198.51.100.5 443" "127.0.0.1 9000" "::1 9001" "2001:DB8:0:0:0:0:0:1 443" "example.org 443" "Example.ORG 8443"; do
    # shellcheck disable=SC2086
    "$PM" snell access add $hp >/dev/null 2>&1
done
OUT=$("$PM" snell access show)
assert_contains "名单含 IPv4" "$OUT" "192.0.2.1:443"
assert_contains "同 IP 不同端口分别列出" "$OUT" "192.0.2.1:8443"
assert_contains "回环可以列入" "$OUT" "127.0.0.1:9000"
assert_contains "IPv6 回环规范化" "$OUT" "[::1]:9001"
assert_contains "IPv6 压缩为规范形式" "$OUT" "[2001:db8::1]:443"
assert_contains "域名小写" "$OUT" "example.org:443"
assert_contains "域名小写同一个名字的第二个端口" "$OUT" "example.org:8443"
assert_eq "名单条数" 8 "$(printf '%s\n' "$OUT" | grep -c '^    ')"
assert_eq "名单文件权限" 600 "$(stat -c %a "$A$ACCESS")"
OUT=$("$PM" snell access add 192.0.2.1 443 2>&1)
assert_eq "重复条目被拒绝" 2 "$?"
OUT=$("$PM" snell access add 2001:db8::1 443 2>&1)
assert_eq "写法不同的同一 IPv6 被识别为重复" 2 "$?"
for hp in "127.0.0.1 1082" "::1 1082" "127.0.0.53 53" "192.0.2.1 0" "192.0.2.1 99999" "192.0.2.1 abc" "bad_host! 443" "" "192.0.2.1"; do
    # shellcheck disable=SC2086
    OUT=$("$PM" snell access add $hp 2>&1)
    assert_eq "access add 拒绝: [$hp]" 2 "$?"
done
OUT=$("$PM" snell access add 127.0.0.1 1082 2>&1)
assert_contains "网关地址的拒绝说明" "$OUT" "网关或内部组件"
OUT=$("$PM" snell access add 127.0.0.53 53 2>&1)
assert_contains "DNS 助手地址的拒绝说明" "$OUT" "网关或内部组件"
assert_eq "拒绝不改变名单" 8 "$("$PM" snell access show | grep -c '^    ')"
"$PM" snell access delete 192.0.2.1 8443 >/dev/null 2>&1
assert_eq "delete 后条数" 7 "$("$PM" snell access show | grep -c '^    ')"
assert_not_contains "delete 删除了正确的条目" "$("$PM" snell access show)" "192.0.2.1:8443"
assert_contains "delete 保留同 IP 另一个端口" "$("$PM" snell access show)" "192.0.2.1:443"
OUT=$("$PM" snell access delete 192.0.2.1 8443 2>&1)
assert_eq "删除不存在的条目失败" 2 "$?"
"$PM" snell access clear >/dev/null 2>&1
OUT=$("$PM" snell access show)
assert_contains "clear 后名单为空" "$OUT" "(空) 启用时拒绝所有目标"
# 上限
new_m a2
install_snell
n=1
while [ "$n" -le 100 ]; do
    "$PM" snell access add 192.0.2.1 $((1000 + n)) >/dev/null 2>&1
    n=$((n + 1))
done
assert_eq "名单上限内全部写入" 100 "$("$PM" snell access show | grep -c '^    ')"
OUT=$("$PM" snell access add 192.0.2.1 5000 2>&1)
assert_eq "超过上限被拒绝" 1 "$?"
assert_eq "超过上限不改变名单" 100 "$("$PM" snell access show | grep -c '^    ')"

# ---- 目标访问限制: 运行时文件 ----
new_m a3
install_snell
for hp in "192.0.2.1 443" "192.0.2.1 8443" "198.51.100.5 443" "::1 9001" "2001:db8::1 443" "127.0.0.1 9000" "t1.example.test 443" "t2.example.test 8443"; do
    # shellcheck disable=SC2086
    "$PM" snell access add $hp >/dev/null 2>&1
done
OUT=$("$PM" snell access enable --yes 2>&1)
assert_eq "access enable 成功" 0 "$?"
assert_contains "access 安装 tinyproxy" "$(cat "$A/.apk-installed")" "tinyproxy"
assert_not_contains "access 不装 unbound" "$(cat "$A/.apk-installed")" "unbound"
assert_contains "服务脚本模式 access" "$(cat "$A$INIT")" "# apm-net: access"
"$PM" snell net-prepare >/dev/null 2>&1
assert_eq "net-prepare 成功" 0 "$?"
R=$A/run/apm-snell
FILTER=$(cat "$R/filter")
assert_contains "过滤器含 IPv4 精确对" "$FILTER" '^192\.0\.2\.1:443$'
assert_contains "过滤器同 IP 另一端口" "$FILTER" '^192\.0\.2\.1:8443$'
assert_contains "过滤器含 IPv6" "$FILTER" '^\[::1\]:9001$'
assert_contains "过滤器含压缩 IPv6" "$FILTER" '^\[2001:db8::1\]:443$'
assert_contains "过滤器含回环" "$FILTER" '^127\.0\.0\.1:9000$'
assert_contains "域名 t1 展开为固定地址" "$FILTER" '^192\.0\.2\.10:443$'
assert_contains "域名 t2 的 IPv4" "$FILTER" '^192\.0\.2\.20:8443$'
assert_contains "域名 t2 的 IPv6 规范化" "$FILTER" '^\[2001:db8::20\]:8443$'
assert_not_contains "过滤器不含域名文本" "$FILTER" 'example\.test'
assert_not_contains "不含未列入的交叉组合" "$FILTER" '^198\.51\.100\.5:8443$'
assert_eq "过滤器每行都被锚定" 0 "$(printf '%s\n' "$FILTER" | grep -vc '^\^.*\$$')"
TP=$(cat "$R/tinyproxy.conf")
assert_contains "tinyproxy 默认拒绝" "$TP" "FilterDefaultDeny Yes"
assert_contains "tinyproxy 正则过滤" "$TP" "FilterType ere"
assert_contains "tinyproxy 过滤 URL (CONNECT 目标)" "$TP" "FilterURLs On"
assert_contains "tinyproxy 只监听回环" "$TP" "Listen 127.0.0.1"
assert_contains "tinyproxy 端口" "$TP" "Port 1082"
assert_contains "tinyproxy 只允许本机" "$TP" "Allow 127.0.0.1"
assert_contains "ConnectPort 并集 443" "$TP" "ConnectPort 443"
assert_contains "ConnectPort 并集 8443" "$TP" "ConnectPort 8443"
assert_contains "ConnectPort 并集 9000" "$TP" "ConnectPort 9000"
assert_contains "ConnectPort 并集 9001" "$TP" "ConnectPort 9001"
assert_eq "ConnectPort 没有重复" "$(grep -c '^ConnectPort' "$R/tinyproxy.conf")" "$(grep '^ConnectPort' "$R/tinyproxy.conf" | sort -u | wc -l | tr -d ' ')"
GCC=$(cat "$R/graftcp.conf")
assert_contains "graftcp 走 HTTP 代理模式" "$GCC" "select_proxy_mode = only_http_proxy"
assert_contains "graftcp 指向内部网关" "$GCC" "http_proxy = 127.0.0.1:1082"
assert_contains "graftcp 接管 UDP 以便拒绝" "$GCC" "udp_proxy = true"
assert_contains "graftcp 不豁免回环" "$GCC" "ignore_local = false"
assert_contains "graftcp 不使用 DNS 代理" "$GCC" "dns_proxy = false"
assert_not_contains "graftcp 没有黑名单文件" "$GCC" "blackip"
assert_not_contains "graftcp 没有白名单文件" "$GCC" "whiteip"
assert_eq "graftcp 配置权限" 600 "$(stat -c %a "$R/graftcp.conf")"
HOSTSF=$(cat "$R/hosts")
assert_contains "私有 hosts 含固定解析" "$HOSTSF" "192.0.2.10 t1.example.test"
assert_contains "私有 hosts 含 IPv6" "$HOSTSF" "2001:db8::20 t2.example.test"
RUNSH=$(cat "$R/run.sh")
assert_contains "有域名条目时用私有挂载命名空间" "$RUNSH" "unshare -m"
assert_contains "命名空间传播设为私有" "$RUNSH" "mount --make-rprivate /"
assert_contains "只绑定私有 hosts 到 /etc/hosts" "$RUNSH" "mount --bind /run/apm-snell/hosts /etc/hosts"
assert_not_contains "access 模式没有 DNS 助手" "$RUNSH" "unbound"
assert_contains "Snell 降权为 snell 用户" "$RUNSH" "su -s /bin/sh snell"
assert_contains "只给 Snell 设置 LD_PRELOAD" "$RUNSH" "LD_PRELOAD=/lib/libgcompat.so.0 exec /usr/local/bin/snell-server"
SC=$(cat "$R/snell.conf")
assert_contains "运行时配置沿用 listen" "$SC" "listen = 0.0.0.0:20000"
assert_not_contains "access 模式不改 dns" "$SC" "dns ="
assert_eq "snell.conf 权限" 640 "$(stat -c %a "$R/snell.conf")"
assert_eq "runner.env 模式" access "$(sed -n 's/^MODE=//p' "$R/runner.env")"
assert_eq "mode 文件" access "$(cat "$R/mode")"
assert_eq "固定解析被持久化" "$(cat "$R/pins")" "$(cat "$A/var/lib/alpine-proxy-manager/snellnet/pins")"
assert_eq "固定解析权限" 600 "$(stat -c %a "$A/var/lib/alpine-proxy-manager/snellnet/pins")"
assert_not_contains "密钥类内容不进入 tinyproxy 配置" "$TP" "psk"
# 域名变化但没有 refresh: 重新生成时才会采用新解析 (启动 = 重新解析), 单独的系统解析变化不会自动放行
printf 't1.example.test 192.0.2.99\nt2.example.test 192.0.2.20 2001:DB8::20\n' > "$HOSTS"
OUT=$("$PM" snell access refresh 2>&1)
assert_eq "refresh 成功" 0 "$?"
assert_contains "refresh 报告变化" "$OUT" "有变化"
assert_contains "refresh 显示新的固定地址" "$OUT" "192.0.2.99"
assert_contains "pins 更新前未被偷偷改动" "$(cat "$A/var/lib/alpine-proxy-manager/snellnet/pins")" "192.0.2.10"
"$PM" snell net-prepare >/dev/null 2>&1
assert_contains "重新生成后采用新地址" "$(cat "$R/filter")" '^192\.0\.2\.99:443$'
assert_not_contains "旧地址不再放行" "$(cat "$R/filter")" '^192\.0\.2\.10:443$'
OUT=$("$PM" snell access refresh 2>&1)
assert_contains "再次 refresh 无变化" "$OUT" "没有变化"
# 解析失败: 沿用上一次的固定地址 (fail-closed 不放行任何新地址)
printf 't2.example.test 192.0.2.20 2001:DB8::20\n' > "$HOSTS"
"$PM" snell net-prepare >"$T_TMP/prep.out" 2>&1
assert_contains "解析失败时沿用旧固定地址" "$(cat "$R/filter")" '^192\.0\.2\.99:443$'
assert_contains "解析失败有警告" "$(cat "$T_TMP/prep.out")" "沿用上一次"
# 完全没有固定值: 该条目没有可放行的地址
new_m a4
install_snell
"$PM" snell access add nowhere.example.test 443 >/dev/null 2>&1
"$PM" snell access enable --yes >/dev/null 2>&1
"$PM" snell net-prepare >"$T_TMP/prep.out" 2>&1
assert_eq "无法解析的域名生成空过滤器" 0 "$(grep -c . "$A/run/apm-snell/filter")"
assert_contains "无法解析有警告" "$(cat "$T_TMP/prep.out")" "无法解析"

# ---- 空名单与无域名的运行时文件 ----
new_m a5
install_snell
"$PM" snell access enable --yes >/dev/null 2>&1
assert_eq "空名单可以启用" true "$(kv_get "$A$ACCESS" enabled)"
"$PM" snell net-prepare >/dev/null 2>&1
R=$A/run/apm-snell
assert_eq "空名单的过滤器是空文件" 0 "$(wc -c < "$R/filter" | tr -d ' ')"
assert_contains "空名单默认拒绝" "$(cat "$R/tinyproxy.conf")" "FilterDefaultDeny Yes"
assert_eq "空名单没有 ConnectPort" 0 "$(grep -c '^ConnectPort' "$R/tinyproxy.conf")"
assert_not_contains "没有域名时不创建挂载命名空间" "$(cat "$R/run.sh")" "unshare"
"$PM" snell access add 192.0.2.1 443 >/dev/null 2>&1
"$PM" snell net-prepare >/dev/null 2>&1
assert_not_contains "只有 IP 条目时不创建挂载命名空间" "$(cat "$R/run.sh")" "unshare"

# ---- SOCKS5 出口: 运行时文件 ----
new_m e1
install_snell
printf '%s\n' "$PWTXT" | "$PM" snell egress set --server up.example.test --port 1080 --username up --password-stdin --dns-server 9.9.9.9 >/dev/null 2>&1
"$PM" snell egress enable --yes >/dev/null 2>&1
"$PM" snell net-prepare >/dev/null 2>&1
R=$A/run/apm-snell
GCC=$(cat "$R/graftcp.conf")
assert_contains "出口走 SOCKS5 模式" "$GCC" "select_proxy_mode = only_socks5"
assert_contains "出口上游" "$GCC" "socks5 = up.example.test:1080"
assert_contains "出口用户名" "$GCC" "socks5_username = up"
assert_contains "出口密码只在 0600 的配置里" "$GCC" "socks5_password = $PWTXT"
assert_contains "出口接管 UDP" "$GCC" "udp_proxy = true"
assert_contains "出口接管回环 (不豁免)" "$GCC" "ignore_local = false"
assert_eq "出口 graftcp 配置权限" 600 "$(stat -c %a "$R/graftcp.conf")"
UB=$(cat "$R/unbound.conf")
assert_contains "unbound 只监听 DNS 助手地址" "$UB" "interface: 127.0.0.53"
assert_contains "unbound 转发到指定 DNS" "$UB" "forward-addr: 9.9.9.9@53"
assert_contains "unbound 上游用 TCP" "$UB" "tcp-upstream: yes"
assert_contains "unbound 只服务本机" "$UB" "access-control: 127.0.0.0/8 allow"
assert_eq "unbound 配置权限" 600 "$(stat -c %a "$R/unbound.conf")"
RUNSH=$(cat "$R/run.sh")
assert_contains "出口模式先起 unbound" "$RUNSH" "unbound -d -c /run/apm-snell/unbound.conf"
assert_contains "unbound 不带 gcompat 预加载" "$RUNSH" "env -u LD_PRELOAD unbound"
assert_contains "出口模式 Snell 降权" "$RUNSH" "su -s /bin/sh snell"
SC=$(cat "$R/snell.conf")
assert_contains "出口模式 Snell 使用 DNS 助手" "$SC" "dns = 127.0.0.53"
assert_not_contains "运行时配置不含出口密码" "$SC" "$PWTXT"
assert_eq "管理的 Snell 配置未被改动" 0 "$(grep -c '127.0.0.53' "$A/etc/snell/snell-server.conf")"
assert_eq "出口模式没有 tinyproxy 配置" 0 "$([ -e "$R/tinyproxy.conf" ] && echo 1 || echo 0)"
# 用户原有的 dns 项在运行时配置里被替换, 管理配置本身保持不变
printf 'dns = 8.8.8.8\n' >> "$A/etc/snell/snell-server.conf"
"$PM" snell net-prepare >/dev/null 2>&1
assert_eq "运行时配置只有一个 dns 项" 1 "$(grep -c '^dns' "$A/run/apm-snell/snell.conf")"
assert_contains "且是 DNS 助手" "$(cat "$A/run/apm-snell/snell.conf")" "dns = 127.0.0.53"
assert_contains "管理配置保留用户的 dns" "$(cat "$A/etc/snell/snell-server.conf")" "dns = 8.8.8.8"
# 两个功能同时标记启用 (手工改文件) 时拒绝生成
new_m c1
install_snell
"$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth >/dev/null 2>&1
"$PM" snell access add 192.0.2.1 443 >/dev/null 2>&1
sed -i 's/^enabled=.*/enabled=true/' "$A$EGRESS" "$A$ACCESS"
OUT=$("$PM" snell net-prepare 2>&1)
assert_eq "冲突配置拒绝生成运行时文件" 1 "$?"
assert_eq "冲突时没有运行时目录内容" 0 "$([ -e "$A/run/apm-snell/run.sh" ] && echo 1 || echo 0)"
assert_contains "status 报告冲突" "$("$PM" snell status)" "配置冲突"

# ---- 无效配置文件 ----
new_m v1
install_snell
printf 'enabled=true\nhost=127.0.0.1\nport=99999\n' > "$A$EGRESS"
chmod 600 "$A$EGRESS"
assert_contains "show 报告无效配置" "$("$PM" snell egress show)" "配置无效"
printf 'enabled=true\ndestination.1=192.0.2.1:443\ndestination.2=192.0.2.1:443\n' > "$A$ACCESS"
chmod 600 "$A$ACCESS"
assert_contains "重复条目的配置无效" "$("$PM" snell access show)" "配置无效"
printf 'enabled=true\ndestination.1=127.0.0.1:1082\n' > "$A$ACCESS"
assert_contains "含网关地址的配置无效" "$("$PM" snell access show)" "配置无效"

# ---- 运行中启用: 重启后验证不通过时回滚 (模拟系统里没有真实的辅助进程) ----
new_m r1
"$PM" snell install --port 20000 >/dev/null 2>&1
core_discover snell
assert_eq "前提: Snell 在运行" running "$CF_STATE"
"$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth >/dev/null 2>&1
BEFOREI=$(cat "$A$INIT")
OUT=$("$PM" snell egress enable --yes 2>&1)
assert_eq "验证失败时 enable 返回 1" 1 "$?"
assert_contains "说明正在恢复" "$OUT" "正在恢复"
assert_eq "配置恢复为未启用" false "$(kv_get "$A$EGRESS" enabled)"
assert_eq "服务脚本恢复为普通模式" "$BEFOREI" "$(cat "$A$INIT")"
core_discover snell
assert_eq "恢复后 Snell 仍在运行" running "$CF_STATE"
# 已启用且运行时修改名单: 验证失败时恢复旧名单
new_m r2
"$PM" snell install --port 20000 >/dev/null 2>&1
"$PM" snell access add 192.0.2.1 443 >/dev/null 2>&1
sed -i 's/^enabled=.*/enabled=true/' "$A$ACCESS"
BEFOREA=$(cat "$A$ACCESS")
OUT=$("$PM" snell access add 192.0.2.2 443 2>&1)
assert_eq "验证失败时 add 返回 1" 1 "$?"
assert_eq "名单恢复为修改前" "$BEFOREA" "$(cat "$A$ACCESS")"

# ---- 卸载 ----
new_m u1
install_snell
"$PM" snell egress set --server 127.0.0.1 --port 1080 --no-auth >/dev/null 2>&1
"$PM" snell egress enable --yes >/dev/null 2>&1
mkdir -p "$A/run/apm-snell"
: > "$A/run/apm-snell/leftover"
OUT=$("$PM" snell uninstall 2>&1)
assert_eq "启用状态下卸载成功" 0 "$?"
assert_eq "卸载清理运行时目录" 0 "$([ -e "$A/run/apm-snell" ] && echo 1 || echo 0)"
assert_eq "保留配置时功能被关闭" false "$(kv_get "$A$EGRESS" enabled)"
assert_eq "保留上游设置" 127.0.0.1 "$(kv_get "$A$EGRESS" host)"
assert_eq "保留 graftcp" 1 "$([ -x "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp" ] && echo 1 || echo 0)"
OUT=$("$PM" snell install --port 20000 2>&1)
RC=$?
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
assert_eq "卸载后可以重新安装" 0 "$RC"
assert_eq "重新安装得到普通 Snell" 0 "$(grep -c '^# apm-net:' "$A$INIT")"
"$PM" snell stop >/dev/null 2>&1
OUT=$("$PM" snell uninstall --purge 2>&1)
assert_eq "purge 成功" 0 "$?"
assert_eq "purge 删除出口配置" 0 "$([ -e "$A$EGRESS" ] && echo 1 || echo 0)"
assert_eq "purge 删除 graftcp" 0 "$([ -e "$A/usr/local/lib/alpine-proxy-manager/ext/graftcp" ] && echo 1 || echo 0)"
assert_eq "purge 删除依赖记录" 0 "$([ -e "$A/var/lib/alpine-proxy-manager/snellnet" ] && echo 1 || echo 0)"
assert_contains "purge 不卸载 apk 包" "$(cat "$A/.apk-installed")" "unbound"
# 卸载 Snell 不触碰 sing-box 的任何数据
new_m u2
install_snell
mkdir -p "$A/etc/alpine-proxy-manager/instances" "$A/var/lib/alpine-proxy-manager/cores"
printf 'enabled=true\n' > "$A/etc/alpine-proxy-manager/instances/keepme.conf"
"$PM" snell access add 192.0.2.1 443 >/dev/null 2>&1
"$PM" snell uninstall --purge >/dev/null 2>&1
assert_ok "sing-box 实例配置原样保留" test -f "$A/etc/alpine-proxy-manager/instances/keepme.conf"

t_done
