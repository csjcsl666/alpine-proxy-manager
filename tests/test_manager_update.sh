# shellcheck shell=sh
# Manager 自更新: 检查最新正式 Release, 确认, 复用安装器升级, 失败保护, Core 不重启, TUI 提示
# GitHub 用本地 mock 下载器代替 (API JSON, SHA256SUMS, Release 归档), 自动测试不依赖任何外部服务
# 升级本身走真实的 install.sh (APM_ROOT 隔离), 所以原子切换 自检 回滚都是真实路径
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load common environment state core model policy txn report client snell singbox manager tui

PM_SRC="$T_ROOT/bin/proxy-manager"
if ! mk_elf_stub "$T_TMP/probe" "probe"; then
    t_skip "ELF 桩只支持 x86_64, test_manager_update.sh 全部跳过"
    t_done
    exit $?
fi
# shellcheck source=tests/sb_common.sh
. "$(dirname "$0")/sb_common.sh"

INSTALLER=$T_ROOT/install.sh
ROOT=$T_TMP/mroot
LIBD=$ROOT/usr/local/lib/alpine-proxy-manager
MPM=$ROOT/usr/local/bin/proxy-manager
MOCKD=$T_TMP/mock
mkdir -p "$MOCKD"
MOCK_LOG=$T_TMP/mock.log
SRC=$T_TMP/msrc
OWNER=o/r
export MOCK_DIR="$MOCKD" MOCK_LOG

# ---- mock 下载器: 与 wget 同形的参数 -q -T N -O DEST|- URL, 按 URL 分发 ----
MOCK=$T_TMP/mockdl
cat > "$MOCK" <<'EOS'
#!/bin/sh
dest=
while [ $# -gt 1 ]; do
    case $1 in
        -O) dest=$2; shift 2 ;;
        -T) shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$1" >> "$MOCK_LOG"
[ "${MOCK_NET:-up}" = up ] || exit 1
[ -z "${MOCK_SLOW:-}" ] || exec sleep 30
case $1 in
    */releases/latest) f=$MOCK_DIR/latest.json ;;
    */commits/*) f=$MOCK_DIR/commit.json ;;
    */SHA256SUMS) f=$MOCK_DIR/SHA256SUMS ;;
    */alpine-proxy-manager-*.tar.gz) f=$MOCK_DIR/archive.tgz ;;
    */tar.gz/*) f=$MOCK_DIR/bootstrap.tgz ;;
    *) exit 1 ;;
esac
[ -f "$f" ] || exit 1
if [ "$dest" = - ]; then cat "$f"; else cp "$f" "$dest"; fi
EOS
chmod +x "$MOCK"

# ---- 发布构造 ----
mkdir -p "$SRC"
git -C "$SRC" init -q
cp -R "$T_ROOT/bin" "$T_ROOT/lib" "$T_ROOT/install.sh" "$SRC/"
N=0
# mkrel 版本 -> 设置 REL_ARCH REL_SHA REL_BUILD, 归档带 install.sh 与 pax 头里的 commit
mkrel() {
    N=$((N + 1))
    printf '%s\n' "$1" > "$SRC/VERSION"
    printf '# release %s\n' "$1" >> "$SRC/lib/common.sh"
    git -C "$SRC" add -A
    git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -q -m "release $1"
    REL_SHA=$(git -C "$SRC" rev-parse HEAD)
    REL_BUILD=$(printf '%s' "$REL_SHA" | cut -c1-7)
    REL_ARCH=$T_TMP/rel.$N.tgz
    git -C "$SRC" archive --format=tar --prefix="alpine-proxy-manager-$1/" HEAD | gzip -n > "$REL_ARCH"
    REL_SUM=$(sha256sum "$REL_ARCH" | awk '{ print $1 }')
}
# 发布到 mock: 归档 SHA256SUMS commit
publish() { # 版本 [归档文件]
    local _a
    _a=${2:-$REL_ARCH}
    cp "$_a" "$MOCKD/archive.tgz"
    printf '%s  alpine-proxy-manager-%s.tar.gz\n' "$(sha256sum "$_a" | awk '{ print $1 }')" "$1" > "$MOCKD/SHA256SUMS"
    printf '{\n  "sha": "%s",\n  "commit": {\n    "tree": {\n      "sha": "0000000000000000000000000000000000000000"\n    }\n  }\n}\n' "$REL_SHA" > "$MOCKD/commit.json"
}
# 与 GitHub 同样的 pretty JSON, 含嵌套对象和资产
setlatest() { # tag draft prerelease
    cat > "$MOCKD/latest.json" <<EOF
{
  "url": "https://api.example.invalid/repos/$OWNER/releases/1",
  "author": {
    "login": "someone",
    "id": 1
  },
  "tag_name": "$1",
  "target_commitish": "main",
  "name": "Alpine Proxy Manager",
  "draft": $2,
  "prerelease": $3,
  "assets": [
    {
      "name": "SHA256SUMS",
      "draft": true
    }
  ],
  "body": "说明 \\"tag_name\\": \\"v9.9.9\\" 不能被当成字段"
}
EOF
}

# ---- 环境: sim 系统里有运行中的 Snell 与 sing-box, Manager 装在隔离根目录 ----
new_s m1
printf 'MgrSnellPsk0123456789abcdefAB\n' | "$T_ROOT/bin/proxy-manager" snell install --port 20000 --psk-stdin >/dev/null 2>&1
"$T_ROOT/bin/proxy-manager" sing-box install >/dev/null 2>&1
"$T_ROOT/bin/proxy-manager" sing-box add anytls --port 20443 >/dev/null 2>&1
export APM_ROOT="$ROOT" APM_DOWNLOADER="$MOCK" APM_DOWNLOAD_TRIES=1 APM_MGR_API="https://api.example.invalid/repos/$OWNER" APM_MGR_DL="https://dl.example.invalid/releases/download" APM_MGR_TIMEOUT=5
mkrel 0.5.1
OLD_BUILD=$REL_BUILD
OLD_SHA=$REL_SHA
cp "$REL_ARCH" "$MOCKD/bootstrap.tgz"
OUT=$(sh -c "$(cat "$INSTALLER")" -- 2>&1)
assert_eq "初始安装的 Manager 是 0.5.1" "Alpine Proxy Manager 0.5.1" "$("$MPM" --version | sed -n 1p)"
assert_eq "初始 Build" "Build: $OLD_BUILD" "$("$MPM" --version | sed -n 2p)"

mgr() { "$MPM" "$@"; }
mgr_out() { OUT=$("$MPM" "$@" </dev/null 2>&1); RC=$?; }
tree() { ( cd "$ROOT" && find . | sort ); }
data_sum() { ( cd "$A" && cat etc/alpine-proxy-manager/instances/*.conf etc/sing-box/config.json etc/snell/snell-server.conf var/lib/alpine-proxy-manager/cores/*.meta 2>/dev/null | cksum ); }
spid() { core_discover snell; printf '%s' "$CF_PID"; }
bpid() { core_discover singbox; printf '%s' "$CF_PID"; }
leftover() { { ls "$A/var/tmp" 2>/dev/null | grep apm-snell; [ -d "$A/var/lib/alpine-proxy-manager/snell.lock" ] && echo lock; true; } | tr '\n' ' ' | sed 's/ $//'; }
unset_net() { unset MOCK_NET MOCK_SLOW; }

# ---- 检查更新 ----
mkrel 0.5.2
NEW_BUILD=$REL_BUILD
NEW_SHA=$REL_SHA
NEW_ARCH=$REL_ARCH
publish 0.5.2 "$NEW_ARCH"
setlatest v0.5.2 false false
T0=$(tree)
: > "$MOCK_LOG"
mgr_out manager check-update
assert_eq "有新正式版: 返回 10" 10 "$RC"
assert_contains "显示当前版本" "$OUT" "当前版本：0.5.1"
assert_contains "显示最新正式版" "$OUT" "最新正式版：0.5.2"
assert_contains "提示发现新版本" "$OUT" "发现新版本。"
assert_eq "只查询了 API 的最新 Release" 1 "$(grep -c 'releases/latest' "$MOCK_LOG")"
assert_not_contains "检查更新不下载归档" "$(cat "$MOCK_LOG")" "tar.gz"
assert_not_contains "检查更新不下载 SHA256SUMS" "$(cat "$MOCK_LOG")" "SHA256SUMS"
assert_eq "检查更新没有改变安装" "$T0" "$(tree)"
assert_eq "检查更新没有留下锁和暂存" "" "$(leftover)"
# 非 root 也能检查
OUT=$(APM_EUID=1000 "$MPM" manager check-update </dev/null 2>&1); RC=$?
assert_eq "非 root 可以检查更新" 10 "$RC"
assert_contains "非 root 检查更新有结果" "$OUT" "最新正式版：0.5.2"
# JSON 里被转义的伪字段不能影响解析
assert_not_contains "转义的伪字段没有被当成版本" "$OUT" "9.9.9"
# 当前已是最新: Build 相同
publish 0.5.1 "$T_TMP/rel.1.tgz"
printf '{\n  "sha": "%s"\n}\n' "$OLD_SHA" > "$MOCKD/commit.json"
setlatest v0.5.1 false false
mgr_out manager check-update
assert_eq "已是最新: 返回 0" 0 "$RC"
assert_contains "已是最新正式版" "$OUT" "已是最新正式版。"
assert_not_contains "已是最新时不提示新版本" "$OUT" "发现新版本"
# 版本相同但 Build 不同: 明确说明, 不称为新正式版本
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$MOCKD/commit.json"
mgr_out manager check-update
assert_eq "版本相同 Build 不同: 返回 0" 0 "$RC"
assert_contains "说明 Build 不同" "$OUT" "版本号相同但 Build 不同"
assert_contains "显示当前 Build" "$OUT" "当前 Build：$OLD_BUILD"
assert_contains "显示正式版 Build" "$OUT" "正式版 Build：$(printf '%s' "$NEW_SHA" | cut -c1-7)"
assert_not_contains "不把开发候选称为新正式版本" "$OUT" "发现新版本"
# 取不到 Build 时如实说明
rm -f "$MOCKD/commit.json"
mgr_out manager check-update
assert_contains "取不到 Build 时如实说明" "$OUT" "无法确认 Build"
# 最新正式版低于当前: 不降级
setlatest v0.5.0 false false
mgr_out manager check-update
assert_eq "当前高于最新正式版: 返回 0" 0 "$RC"
assert_contains "不降级的说明" "$OUT" "不会降级"
# Pre-release 与 Draft 不被选用
setlatest v0.5.2 false true
mgr_out manager check-update
assert_eq "Pre-release: 返回 1" 1 "$RC"
assert_contains "Pre-release 不被当成正式版" "$OUT" "不是正式版"
assert_not_contains "Pre-release 不显示最新版本" "$OUT" "最新正式版：0.5.2"
setlatest v0.5.2 true false
mgr_out manager check-update
assert_eq "Draft: 返回 1" 1 "$RC"
assert_contains "Draft 不被当成正式版" "$OUT" "不是正式版"
# 非法响应
for bad in 'v0.5' 'v0.5.2-rc1' 'main' 'latest' '0.5.2' 'v0.5.2.1' 'vX.Y.Z' 'v99999.1.1' 'v0.5.2 ' ''; do
    setlatest "$bad" false false
    mgr_out manager check-update
    assert_eq "非法版本 [$bad]: 返回 1" 1 "$RC"
    assert_contains "非法版本 [$bad]: 给出失败说明" "$OUT" "检查更新失败"
done
rm -f "$T_TMP/PWNED"
setlatest 'v0.5.2\";touch '"$T_TMP"'/PWNED;#' false false
mgr_out manager check-update
assert_eq "注入式 tag 被拒绝" 1 "$RC"
assert_fail "注入式 tag 没有执行任何东西" test -e "$T_TMP/PWNED"
printf '{"message":"Not Found","documentation_url":"https://docs.github.com"}\n' > "$MOCKD/latest.json"
mgr_out manager check-update
assert_eq "HTTP 错误体: 返回 1" 1 "$RC"
assert_contains "HTTP 错误体: 说明没有 Release 信息" "$OUT" "没有 Release 信息"
printf '<html>rate limited</html>\n' > "$MOCKD/latest.json"
mgr_out manager check-update
assert_eq "非 JSON: 返回 1" 1 "$RC"
printf '{"tag_name":"v0.5.2","draft":false,"prerelease":false}' > "$MOCKD/latest.json"
mgr_out manager check-update
assert_eq "单行 JSON 也能解析" 10 "$RC"
# 网络失败与超时
setlatest v0.5.2 false false
OUT=$(MOCK_NET=down "$MPM" manager check-update </dev/null 2>&1); RC=$?
assert_eq "网络失败: 返回 1" 1 "$RC"
assert_contains "网络失败的固定说明" "$OUT" "检查更新失败：无法获取 GitHub Release 信息。"
assert_contains "网络失败时 Manager 未变化" "$OUT" "当前 Manager 未发生任何变化。"
T1=$(date +%s)
OUT=$(MOCK_SLOW=1 APM_MGR_TIMEOUT=1 "$MPM" manager check-update </dev/null 2>&1); RC=$?
T2=$(date +%s)
assert_eq "超时: 返回 1" 1 "$RC"
assert_eq "超时在几秒内返回" yes "$([ $((T2 - T1)) -le 8 ] && echo yes)"
assert_contains "超时说明" "$OUT" "检查更新失败"
assert_eq "失败的检查没有改变安装" "$T0" "$(tree)"
assert_fail "没有 main 的请求" grep -q '/main\|heads/main\|tar.gz/main' "$MOCK_LOG"

# ---- 更新 Manager: 拒绝与不更新的情形 ----
publish 0.5.2 "$NEW_ARCH"
setlatest v0.5.2 false false
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$MOCKD/commit.json"
: > "$MOCK_LOG"
OUT=$(APM_EUID=1000 "$MPM" manager update </dev/null 2>&1); RC=$?
assert_eq "非 root 更新被拒绝" 4 "$RC"
assert_contains "非 root 的提示" "$OUT" "需要 root"
assert_eq "非 root 没有联网" 0 "$(wc -l < "$MOCK_LOG" | tr -d ' ')"
assert_eq "非 root 没有改变安装" "$T0" "$(tree)"
setlatest v0.5.0 false false
: > "$MOCK_LOG"
mgr_out manager update
assert_eq "不降级: 返回 3" 3 "$RC"
assert_contains "不降级的说明" "$OUT" "不会降级"
assert_not_contains "不降级时没有下载归档" "$(cat "$MOCK_LOG")" "tar.gz"
setlatest v0.5.1 false false
mgr_out manager update
assert_eq "版本相同: 返回 3" 3 "$RC"
assert_contains "版本相同时不切换到其他 Build" "$OUT" "不会切换到 main 或其他 Build"
assert_eq "无需更新时没有改变安装" "$T0" "$(tree)"
setlatest v0.5.2 false true
mgr_out manager update
assert_eq "更新时 Pre-release 不被使用: 返回 1" 1 "$RC"
assert_eq "Pre-release 没有改变安装" "$T0" "$(tree)"
OUT=$(MOCK_NET=down "$MPM" manager update </dev/null 2>&1); RC=$?
assert_eq "更新时网络失败: 返回 1" 1 "$RC"
assert_contains "更新时网络失败的说明" "$OUT" "当前 Manager 未发生任何变化"
assert_eq "网络失败没有改变安装" "$T0" "$(tree)"
setlatest v0.5.2 false false

# ---- 更新失败不破坏旧版本 ----
fail_case() { # 名称
    assert_eq "$1: 返回 1" 1 "$RC"
    assert_contains "$1: 报告失败" "$OUT" "Manager 更新失败"
    assert_not_contains "$1: 不显示成功" "$OUT" "Manager 更新成功"
    assert_eq "$1: 旧版本仍然可用" "Alpine Proxy Manager 0.5.1" "$("$MPM" --version | sed -n 1p)"
    assert_eq "$1: 旧 Build 不变" "Build: $OLD_BUILD" "$("$MPM" --version | sed -n 2p)"
    assert_eq "$1: 安装目录不变" "$T0" "$(tree)"
    assert_eq "$1: 没有留下锁和暂存" "" "$(leftover)"
    assert_eq "$1: apm 仍可用" "Alpine Proxy Manager 0.5.1" "$("$ROOT/usr/local/bin/apm" --version | sed -n 1p)"
}
rm -f "$MOCKD/archive.tgz"
mgr_out manager update
fail_case "下载归档失败"
publish 0.5.2 "$NEW_ARCH"
printf '%s  alpine-proxy-manager-0.5.2.tar.gz\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$MOCKD/SHA256SUMS"
mgr_out manager update
fail_case "校验和不匹配"
assert_contains "校验和不匹配的原因" "$OUT" "校验和不匹配"
printf '%s  other-file.tar.gz\n' "$NEW_SUM" > "$MOCKD/SHA256SUMS"
mgr_out manager update
fail_case "SHA256SUMS 里没有对应条目"
printf 'not a checksum  alpine-proxy-manager-0.5.2.tar.gz\n' > "$MOCKD/SHA256SUMS"
mgr_out manager update
fail_case "SHA256SUMS 格式异常"
rm -f "$MOCKD/SHA256SUMS"
mgr_out manager update
fail_case "没有 SHA256SUMS"
# 归档里的 VERSION 与 tag 不一致, 以及 tag 比内容新的降级式欺骗
mkrel 0.5.0
publish 0.5.2 "$REL_ARCH"
mgr_out manager update
fail_case "归档 VERSION 低于 tag (降级式内容)"
assert_contains "说明版本不一致" "$OUT" "不一致"
mkrel 0.5.9
publish 0.5.2 "$REL_ARCH"
mgr_out manager update
fail_case "归档 VERSION 与 tag 不一致"
# 校验和匹配但内容不是有效归档
printf 'this is not a tar archive\n' | gzip -n > "$T_TMP/garbage.tgz"
publish 0.5.2 "$T_TMP/garbage.tgz"
mgr_out manager update
fail_case "归档内容无效"
# 安装器中途失败: 真实回滚
mkrel 0.5.2
NEW_BUILD=$REL_BUILD
NEW_SHA=$REL_SHA
NEW_ARCH=$REL_ARCH
publish 0.5.2 "$NEW_ARCH"
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$MOCKD/commit.json"
OUT=$(APM_FAULT=post_switch "$MPM" manager update </dev/null 2>&1); RC=$?
fail_case "安装器切换后自检失败 (回滚)"
assert_contains "回滚时展示安装器输出" "$OUT" "回滚"
OUT=$(APM_FAULT=before_switch "$MPM" manager update </dev/null 2>&1); RC=$?
fail_case "安装器切换前失败"

# ---- 更新成功 ----
D0=$(data_sum)
SP0=$(spid)
BP0=$(bpid)
RS0=$(count_calls restart)
: > "$MOCK_LOG"
mgr_out manager update
assert_eq "更新成功: 返回 0" 0 "$RC"
assert_contains "报告成功" "$OUT" "Manager 更新成功。"
assert_contains "原版本" "$OUT" "原版本：0.5.1"
assert_contains "新版本" "$OUT" "新版本：0.5.2"
assert_contains "新 Build" "$OUT" "Build：$NEW_BUILD"
assert_contains "Snell 未重启" "$OUT" "Snell：未重启 (PID $SP0)"
assert_contains "sing-box 未重启" "$OUT" "sing-box：未重启 (PID $BP0)"
assert_contains "提示重新运行 apm" "$OUT" "请重新运行 apm 使用新版管理界面。"
assert_eq "安装后版本" "Alpine Proxy Manager 0.5.2" "$("$MPM" --version | sed -n 1p)"
assert_eq "安装后 Build" "Build: $NEW_BUILD" "$("$MPM" --version | sed -n 2p)"
assert_eq "apm 指向新版本" "Alpine Proxy Manager 0.5.2" "$("$ROOT/usr/local/bin/apm" --version | sed -n 1p)"
assert_eq "只剩一个 release" 1 "$(ls "$LIBD/releases" | wc -l | tr -d ' ')"
assert_eq "Snell PID 不变" "$SP0" "$(spid)"
assert_eq "sing-box PID 不变" "$BP0" "$(bpid)"
assert_eq "没有重启任何 Core" "$RS0" "$(count_calls restart)"
assert_eq "Manager 数据不变" "$D0" "$(data_sum)"
assert_eq "更新没有留下锁和暂存" "" "$(leftover)"
assert_contains "按 tag 下载 SHA256SUMS" "$(cat "$MOCK_LOG")" "/v0.5.2/SHA256SUMS"
assert_contains "按 tag 下载归档" "$(cat "$MOCK_LOG")" "/v0.5.2/alpine-proxy-manager-0.5.2.tar.gz"
assert_not_contains "没有请求 main" "$(cat "$MOCK_LOG")" "/main"
assert_not_contains "没有请求 codeload" "$(cat "$MOCK_LOG")" "tar.gz/main"
# 更新之后再检查: 已是最新; 再次更新: 无需
mgr_out manager check-update
assert_eq "更新后检查: 返回 0" 0 "$RC"
assert_contains "更新后是最新正式版" "$OUT" "已是最新正式版。"
mgr_out manager update
assert_eq "更新后再更新: 返回 3" 3 "$RC"

# ---- 参数与用法 ----
"$MPM" manager </dev/null >/dev/null 2>&1
assert_eq "manager 无子命令返回 2" 2 $?
"$MPM" manager bogus </dev/null >/dev/null 2>&1
assert_eq "未知 manager 子命令返回 2" 2 $?
"$MPM" manager update extra </dev/null >/dev/null 2>&1
assert_eq "update 不接受多余参数" 2 $?
"$MPM" manager check-update extra </dev/null >/dev/null 2>&1
assert_eq "check-update 不接受多余参数" 2 $?
assert_contains "help 列出 manager" "$("$MPM" help)" "manager update"

# ---- TUI ----
# 重新构造: 旧版本装进 ROOT, 新正式版在 mock 里
rm -rf "$ROOT"
cp "$T_TMP/rel.1.tgz" "$MOCKD/bootstrap.tgz"
OUT=$(sh -c "$(cat "$INSTALLER")" -- 2>&1)
publish 0.5.2 "$NEW_ARCH"
setlatest v0.5.2 false false
printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$MOCKD/commit.json"
if command -v script >/dev/null 2>&1; then
    tui() { printf '%b' "$1" | SHELL=/bin/sh APM_TUI_ANSI=0 LC_ALL=en_US.UTF-8 script -qec "$MPM" /dev/null 2>&1 | tr -d '\r'; }
    : > "$MOCK_LOG"
    out=$(tui '6\n0\n0\n')
    assert_contains "Manager 菜单标题" "$out" "Manager 管理"
    assert_contains "Manager 菜单版本" "$out" "当前版本：0.5.1"
    for item in "1. 查看版本" "2. 检查更新" "3. 更新 Manager" "4. 检查环境" "5. 查看帮助" "0. 返回"; do
        assert_contains "Manager 菜单项 $item" "$out" "$item"
    done
    assert_eq "进入 TUI 与 Manager 菜单不联网" 0 "$(wc -l < "$MOCK_LOG" | tr -d ' ')"
    # 检查更新: 有新版本, 可选择更新; 这里选择返回, 不更新
    out=$(tui '6\n2\n0\n0\n0\n')
    assert_contains "检查更新页标题" "$out" "Manager · 检查更新"
    assert_contains "检查更新: 最新正式版" "$out" "最新正式版：0.5.2"
    assert_contains "检查更新: 发现新版本" "$out" "发现新版本。"
    assert_contains "检查更新: 更新选项" "$out" "1. 更新到 0.5.2"
    assert_eq "只检查不更新" "Alpine Proxy Manager 0.5.1" "$("$MPM" --version | sed -n 1p)"
    assert_not_contains "检查更新不下载归档" "$(cat "$MOCK_LOG")" "tar.gz"
    # 拒绝更新: 输入 n
    out=$(tui '6\n3\nn\n\n0\n0\n')
    assert_contains "更新确认: 目标版本" "$out" "目标版本：0.5.2"
    assert_contains "更新确认: 只更新 Manager" "$out" "此次操作只更新 Alpine Proxy Manager。"
    for item in "Snell 服务及配置" "sing-box 服务及配置" "协议实例" "SOCKS Profile" "目标访问限制" "PSK / 密钥" "客户端连接地址"; do
        assert_contains "更新确认列出不会修改: $item" "$out" "- $item"
    done
    assert_contains "更新确认默认 Yes" "$out" "[Y/n]"
    assert_eq "拒绝更新后版本不变" "Alpine Proxy Manager 0.5.1" "$("$MPM" --version | sed -n 1p)"
    out=$(tui '6\n3\nx\nN\n\n0\n0\n')
    assert_contains "无效输入后重新询问" "$out" "输入无效，请输入 y 或 n"
    assert_eq "无效输入后输入 N 版本不变" "Alpine Proxy Manager 0.5.1" "$("$MPM" --version | sed -n 1p)"
    assert_not_contains "拒绝更新不显示成功" "$out" "Manager 更新成功"
    # 网络失败不卡死, 正常返回
    out=$(MOCK_NET=down tui '6\n2\n\n0\n0\n')
    assert_contains "TUI 网络失败的提示" "$out" "检查更新失败：无法获取 GitHub Release 信息。"
    assert_contains "TUI 网络失败后仍可退出" "$out" "已退出"
    # 已是最新: 没有更新选项
    printf '{\n  "sha": "%s"\n}\n' "$OLD_SHA" > "$MOCKD/commit.json"
    setlatest v0.5.1 false false
    out=$(tui '6\n3\n\n0\n0\n')
    assert_contains "TUI 已是最新" "$out" "已是最新正式版。"
    assert_not_contains "已是最新时不出现更新确认" "$out" "此次操作只更新 Alpine Proxy Manager。"
    # 确认更新: 成功提示, 并退出旧的 TUI 进程, 不回到菜单
    publish 0.5.2 "$NEW_ARCH"
    setlatest v0.5.2 false false
    printf '{\n  "sha": "%s"\n}\n' "$NEW_SHA" > "$MOCKD/commit.json"
    out=$(tui '6\n3\n\n\n')
    assert_contains "TUI 更新成功" "$out" "Manager 更新成功。"
    assert_contains "TUI 成功后提示重新运行 apm" "$out" "请重新运行 apm 使用新版管理界面。"
    after=$(printf '%s\n' "$out" | sed -n '/请重新运行 apm/,$p')
    assert_contains "更新成功后旧 TUI 退出" "$after" "已退出"
    assert_not_contains "更新成功后不回到 Manager 菜单" "$after" "Manager 管理"
    assert_not_contains "更新成功后不回到主菜单" "$after" "1. Snell"
    assert_eq "TUI 更新后版本" "Alpine Proxy Manager 0.5.2" "$("$MPM" --version | sed -n 1p)"
    assert_eq "TUI 更新后没有留下锁和暂存" "" "$(leftover)"
    # 从检查更新页直接更新
    rm -rf "$ROOT"
    cp "$T_TMP/rel.1.tgz" "$MOCKD/bootstrap.tgz"
    OUT=$(sh -c "$(cat "$INSTALLER")" -- 2>&1)
    out=$(tui '6\n2\n1\ny\n\n')
    assert_contains "检查更新页直接更新" "$out" "Manager 更新成功。"
    assert_eq "检查更新页更新后版本" "Alpine Proxy Manager 0.5.2" "$("$MPM" --version | sed -n 1p)"
else
    t_skip "没有 script, TUI 伪终端测试跳过 (Alpine: apk add util-linux-misc)"
fi

# ---- 依赖与实现约束 ----
M=$T_ROOT/lib/manager.sh
assert_eq "没有引入 jq Python Node curl 作为运行依赖" 0 "$(grep -v '^[[:space:]]*#' "$M" | grep -c -E '\b(jq|python3?|node|nodejs|curl|perl)\b')"
assert_eq "不使用 eval" 0 "$(grep -v '^[[:space:]]*#' "$M" | grep -c -E '\beval\b')"
assert_eq "不新增定时任务或后台进程" 0 "$(grep -v '^[[:space:]]*#' "$M" | grep -c -E 'crontab|cron|nohup|setsid|disown|&[[:space:]]*$')"
assert_eq "不请求 main 或分支归档" 0 "$(grep -v '^[[:space:]]*#' "$M" | grep -c -E 'refs/heads|/main\b|tar\.gz/')"
# shellcheck disable=SC2016
assert_contains "复用现有安装器而不是自己安装" "$(cat "$M")" 'sh "$_tmp/install.sh"'
assert_contains "复用现有下载函数" "$(cat "$M")" "_snell_fetch"
assert_eq "没有自己的 release 目录或 current 链接操作" 0 "$(grep -v '^[[:space:]]*#' "$M" | grep -c -E 'ln -s|mv -T|/current|lib/alpine-proxy-manager/releases')"
t_done
