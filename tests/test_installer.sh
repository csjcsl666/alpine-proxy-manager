# shellcheck shell=sh
# install.sh 集成测试
# 全部在 APM_ROOT 隔离目录中进行, 下载通过 APM_DOWNLOADER 替换为本地 shim
# 归档由 git archive 生成, 与 GitHub codeload 一样带有 pax 全局头 comment=<commit>
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

INSTALLER=$T_ROOT/install.sh
ROOT=$T_TMP/root
SYS=$T_TMP/sys
DL=$T_TMP/dl
SRC=$T_TMP/srcrepo
LIBD=$ROOT/usr/local/lib/alpine-proxy-manager
LINKP=$ROOT/usr/local/bin/proxy-manager

mk_sysroot "$SYS" alpine
cat > "$DL" <<'EOS'
#!/bin/sh
# 与 wget 同形的参数: -q -T N -O DEST URL
while [ $# -gt 1 ]; do
    case $1 in
        -O) dest=$2; shift 2 ;;
        -T) shift 2 ;;
        *) shift ;;
    esac
done
echo "$1" >> "$APM_TEST_DL_LOG"
[ -z "${APM_TEST_DL_FAIL:-}" ] || exit 1
cp "$APM_TEST_ARCHIVE" "$dest"
EOS
chmod +x "$DL"

export APM_ROOT="$ROOT" APM_SYSROOT="$SYS" APM_EUID=0 APM_DOWNLOADER="$DL" APM_DOWNLOAD_TRIES=1
export APM_TEST_ARCHIVE="" APM_TEST_DL_LOG="$T_TMP/dl.log"
: > "$APM_TEST_DL_LOG"

mkdir -p "$SRC"
git -C "$SRC" init -q
cp -R "$T_ROOT/bin" "$T_ROOT/lib" "$SRC/"
N=0

# commit_src VERSION NOTE -> 设置 SHA SHORT ARCH, 每次产生新 commit
commit_src() {
    N=$((N + 1))
    printf '%s\n' "$1" > "$SRC/VERSION"
    printf '# %s\n' "$2" >> "$SRC/lib/common.sh"
    git -C "$SRC" add -A
    git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -q -m "$2"
    SHA=$(git -C "$SRC" rev-parse HEAD)
    SHORT=$(printf '%s' "$SHA" | cut -c1-7)
    ARCH="$T_TMP/archive.$N.tgz"
    git -C "$SRC" archive --format=tar --prefix=alpine-proxy-manager-main/ HEAD | gzip -n > "$ARCH"
    APM_TEST_ARCHIVE=$ARCH
}

# 从 stdin 以 sh -c "$(...)" 的方式执行安装器, 与 README 的一条命令一致
run_install() { OUT=$(sh -c "$(cat "$INSTALLER")" -- "$@" 2>&1); RC=$?; }

reset_root() { rm -rf "$ROOT"; }
releases() { ls -A "$LIBD/releases" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
libparent_entries() { ls -A "$ROOT/usr/local/lib" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
snapshot() { (cd "$ROOT" && find . | sort); }
ver_out() { "$LINKP" --version 2>&1; }
want_out() { printf 'Alpine Proxy Manager %s\nBuild: %s' "$1" "$2"; }

# ---- 环境拒绝 ----
commit_src 0.1.0-dev.0 first
reset_root
D="$T_TMP/debian"
mk_sysroot "$D" debian
APM_SYSROOT=$D run_install
assert_eq "非 Alpine 拒绝" 1 "$RC"
assert_contains "非 Alpine 提示" "$OUT" "Alpine Proxy Manager 当前仅支持 Alpine Linux。"
assert_fail "非 Alpine 不创建任何目录" test -e "$ROOT/usr"

APM_EUID=1000 run_install
assert_eq "非 root 拒绝" 1 "$RC"
assert_contains "非 root 提示" "$OUT" "请使用 root 运行安装命令。"
assert_fail "非 root 不创建任何目录" test -e "$ROOT/usr"

APM_DOWNLOADER=no-such-downloader run_install
assert_eq "缺少下载工具拒绝" 1 "$RC"
assert_contains "缺少工具提示" "$OUT" "缺少必需工具"

# 用假的 df 固定可用空间, 避免依赖运行环境的挂载信息
mkdir -p "$T_TMP/fakebin"
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/x 100 90 10 90%% /\\n"\n' > "$T_TMP/fakebin/df"
chmod +x "$T_TMP/fakebin/df"
REAL_PATH=$PATH
PATH=$T_TMP/fakebin:$PATH
run_install
PATH=$REAL_PATH
assert_eq "磁盘不足拒绝" 1 "$RC"
assert_contains "磁盘不足提示" "$OUT" "磁盘空间不足: "
assert_eq "磁盘不足后无遗留" "" "$(libparent_entries)"

# 内存提示不阻止安装
echo 33554432 > "$SYS/sys/fs/cgroup/memory.max"
run_install
assert_eq "低内存限制不阻止安装" 0 "$RC"
assert_contains "低内存提示" "$OUT" "提示: 检测到内存上限 32 MiB"
rm -f "$SYS/sys/fs/cgroup/memory.max"
reset_root

run_install --bogus
assert_eq "未知参数返回 2" 2 "$RC"
run_install --help
assert_eq "--help 返回 0" 0 "$RC"
assert_contains "--help 内容" "$OUT" "--uninstall"
APM_REF="a b" run_install
assert_eq "非法 APM_REF 拒绝" 1 "$RC"
APM_REPO="not a repo" run_install
assert_eq "非法 APM_REPO 拒绝" 1 "$RC"

# ---- 首次安装 ----
reset_root
: > "$APM_TEST_DL_LOG"
run_install
assert_eq "首次安装成功" 0 "$RC"
assert_contains "输出安装完成" "$OUT" "Alpine Proxy Manager 安装完成"
assert_contains "输出版本" "$OUT" "版本: 0.1.0-dev.0"
assert_contains "输出 Build" "$OUT" "Build: $SHORT"
assert_eq "默认下载地址" "https://codeload.github.com/csjcsl666/alpine-proxy-manager/tar.gz/main" "$(cat "$APM_TEST_DL_LOG")"
assert_eq "proxy-manager --version 与 Build 正确" "$(want_out 0.1.0-dev.0 "$SHORT")" "$(ver_out)"
assert_eq "命令是相对符号链接" "../lib/alpine-proxy-manager/current/bin/proxy-manager" "$(readlink "$LINKP")"
assert_eq "current 指向 release" "releases/$SHORT" "$(readlink "$LIBD/current")"
assert_eq "BUILD 文件内容" "$SHORT" "$(cat "$LIBD/releases/$SHORT/BUILD")"
assert_eq "VERSION 文件内容" "0.1.0-dev.0" "$(cat "$LIBD/releases/$SHORT/VERSION")"
assert_contains "INSTALL 记录完整 commit" "$(cat "$LIBD/releases/$SHORT/INSTALL")" "commit=$SHA"
assert_contains "INSTALL 记录归档 sha256" "$(cat "$LIBD/releases/$SHORT/INSTALL")" "archive_sha256=$(sha256sum "$ARCH" | awk '{ print $1 }')"
assert_eq "安装内容只有程序本体" "BUILD INSTALL VERSION bin lib" "$(ls -A "$LIBD/releases/$SHORT" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "只有一个 release" "$SHORT" "$(releases)"
assert_eq "无 staging 与锁遗留" "alpine-proxy-manager" "$(libparent_entries)"
assert_eq "bin 权限" 755 "$(stat -c %a "$LIBD/releases/$SHORT/bin/proxy-manager")"
assert_eq "lib 文件权限" 644 "$(stat -c %a "$LIBD/releases/$SHORT/lib/common.sh")"
assert_eq "不假设 PATH 外的 root 也能执行 status" 0 "$("$LINKP" core list >/dev/null 2>&1; echo $?)"

# ---- 重复安装 ----
BEFORE=$(snapshot)
INODE=$(stat -c %i "$LIBD/releases/$SHORT")
: > "$APM_TEST_DL_LOG"
run_install
assert_eq "重复安装成功" 0 "$RC"
assert_contains "同版本同 Build 提示已是最新" "$OUT" "已是最新: 0.1.0-dev.0 (Build: $SHORT)"
assert_eq "重复安装不改变文件树" "$BEFORE" "$(snapshot)"
assert_eq "重复安装不重建 release" "$INODE" "$(stat -c %i "$LIBD/releases/$SHORT")"
assert_eq "重复安装仍只下载一次" 1 "$(wc -l < "$APM_TEST_DL_LOG" | tr -d ' ')"

# --force 重新安装
run_install --force
assert_eq "--force 成功" 0 "$RC"
assert_contains "--force 提示重新安装" "$OUT" "重新安装"
assert_eq "--force 后只有一个 release" "$SHORT.1" "$(releases)"
assert_eq "--force 后 Build 不变" "$(want_out 0.1.0-dev.0 "$SHORT")" "$(ver_out)"
run_install --force
assert_eq "--force 再次执行后 release 唯一" "$SHORT" "$(releases)"
assert_eq "无遗留" "alpine-proxy-manager" "$(libparent_entries)"

# ---- 同 VERSION 不同 Build ----
OLD=$SHORT
commit_src 0.1.0-dev.0 second
run_install
assert_eq "同版本新 Build 升级成功" 0 "$RC"
assert_contains "提示同一开发版本的新 Build" "$OUT" "检测到同一开发版本的新 Build:"
assert_contains "提示 Build 变化" "$OUT" "$OLD → $SHORT"
assert_eq "升级后 Build 为新 Build" "$(want_out 0.1.0-dev.0 "$SHORT")" "$(ver_out)"
assert_eq "旧 release 被清理" "$SHORT" "$(releases)"

# ---- VERSION 变化 ----
OLD=$SHORT
commit_src 0.2.0 third
run_install
assert_eq "版本升级成功" 0 "$RC"
assert_contains "提示版本变化" "$OUT" "更新: 0.1.0-dev.0 ($OLD) → 0.2.0 ($SHORT)"
assert_eq "版本升级后输出" "$(want_out 0.2.0 "$SHORT")" "$(ver_out)"
GOOD_SHORT=$SHORT
GOOD_SNAP=$(snapshot)

# ---- 失败时保持旧版本 ----
check_old_kept() {
    assert_eq "$1: 旧版本仍可用" "$(want_out 0.2.0 "$GOOD_SHORT")" "$(ver_out)"
    assert_eq "$1: 文件树不变" "$GOOD_SNAP" "$(snapshot)"
}

commit_src 0.3.0 candidate
GOOD_ARCH=$ARCH
GOOD_NEW=$SHORT

APM_TEST_DL_FAIL=1 run_install
assert_eq "下载失败返回 1" 1 "$RC"
assert_contains "下载失败提示" "$OUT" "下载失败"
check_old_kept "下载失败"
unset APM_TEST_DL_FAIL

SIZE=$(wc -c < "$GOOD_ARCH")
head -c $((SIZE / 2)) "$GOOD_ARCH" > "$T_TMP/truncated.tgz"
APM_TEST_ARCHIVE=$T_TMP/truncated.tgz run_install
assert_eq "归档损坏返回 1" 1 "$RC"
assert_contains "归档损坏提示" "$OUT" "损坏"
check_old_kept "归档损坏"

printf 'not a tarball at all\n' > "$T_TMP/garbage.tgz"
APM_TEST_ARCHIVE=$T_TMP/garbage.tgz run_install
assert_eq "非 gzip 归档被拒绝" 1 "$RC"
check_old_kept "非 gzip 归档"

# 没有 commit SHA 的普通 tar 归档
mkdir -p "$T_TMP/plain/alpine-proxy-manager-main"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$T_TMP/plain/alpine-proxy-manager-main/"
(cd "$T_TMP/plain" && tar -cf - alpine-proxy-manager-main | gzip -n > "$T_TMP/plain.tgz")
APM_TEST_ARCHIVE=$T_TMP/plain.tgz run_install
assert_eq "无 commit SHA 拒绝" 1 "$RC"
assert_contains "无 commit SHA 提示" "$OUT" "无法从归档确定 commit SHA"
check_old_kept "无 commit SHA"

# sha256 校验
APM_SHA256=0000 run_install
assert_eq "sha256 不匹配拒绝" 1 "$RC"
assert_contains "sha256 不匹配提示" "$OUT" "sha256 不匹配"
check_old_kept "sha256 不匹配"

# staging 校验失败: 缺 lib, 语法错误, VERSION 非法
broken_archive() { # 名称 变更命令(在仓库副本内执行)
    rm -rf "$T_TMP/bk"
    git clone -q "$SRC" "$T_TMP/bk"
    (cd "$T_TMP/bk" && eval "$2" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m "$1")
    git -C "$T_TMP/bk" archive --format=tar --prefix=alpine-proxy-manager-main/ HEAD | gzip -n > "$T_TMP/bk-$1.tgz"
    APM_TEST_ARCHIVE=$T_TMP/bk-$1.tgz
}
broken_archive nolib 'git rm -q lib/txn.sh'
run_install
assert_eq "缺少 lib 模块自检失败" 1 "$RC"
assert_contains "缺少 lib 提示自检失败" "$OUT" "自检失败"
check_old_kept "缺少 lib"

broken_archive syntax 'echo "if then fi (" >> lib/core.sh'
run_install
assert_eq "语法错误被拒绝" 1 "$RC"
assert_contains "语法错误提示" "$OUT" "语法检查失败"
check_old_kept "语法错误"

broken_archive badver 'echo "not a version" > VERSION'
run_install
assert_eq "VERSION 非法被拒绝" 1 "$RC"
assert_contains "VERSION 非法提示" "$OUT" "VERSION 格式无效"
check_old_kept "VERSION 非法"

broken_archive nobin 'git rm -q bin/proxy-manager'
run_install
assert_eq "缺 bin 被拒绝" 1 "$RC"
check_old_kept "缺 bin"

# 安装过程中失败: 切换前与切换后(回滚)
APM_TEST_ARCHIVE=$GOOD_ARCH
APM_FAULT=before_switch run_install
assert_eq "切换前故障返回 1" 1 "$RC"
check_old_kept "切换前故障"
APM_FAULT=post_switch run_install
assert_eq "切换后自检失败返回 1" 1 "$RC"
assert_contains "切换后自检失败提示回滚" "$OUT" "已回滚"
check_old_kept "切换后自检失败"

# 首次安装时的故障不留下半套
reset_root
APM_FAULT=post_switch run_install
assert_eq "首次安装切换后失败" 1 "$RC"
assert_fail "首次安装失败无命令链接" test -e "$LINKP"
assert_fail "首次安装失败无安装目录" test -e "$LIBD"
assert_eq "首次安装失败无遗留" "" "$(libparent_entries)"
APM_FAULT=before_switch run_install
assert_fail "首次安装切换前失败无安装目录" test -e "$LIBD"
assert_eq "首次安装切换前失败无遗留" "" "$(libparent_entries)"

# 回滚后可以正常恢复安装
run_install
assert_eq "失败后重新安装成功" 0 "$RC"
assert_eq "失败后重新安装 Build 正确" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"

# ---- 参数: ref 与 repo ----
: > "$APM_TEST_DL_LOG"
APM_REF=v9.9.9 run_install --force
assert_eq "APM_REF 影响下载地址" "https://codeload.github.com/csjcsl666/alpine-proxy-manager/tar.gz/v9.9.9" "$(cat "$APM_TEST_DL_LOG")"
: > "$APM_TEST_DL_LOG"
APM_REPO=someone/fork run_install --force
assert_eq "APM_REPO 影响下载地址" "https://codeload.github.com/someone/fork/tar.gz/main" "$(cat "$APM_TEST_DL_LOG")"

# ---- 锁 ----
mkdir -p "$ROOT/usr/local/lib/.alpine-proxy-manager.lock"
echo $$ > "$ROOT/usr/local/lib/.alpine-proxy-manager.lock/pid"
run_install
assert_eq "锁被活进程持有时拒绝" 1 "$RC"
assert_contains "锁提示" "$OUT" "另一个安装进程正在运行"
assert_ok "拒绝时不删除他人的锁" test -d "$ROOT/usr/local/lib/.alpine-proxy-manager.lock"
echo 999999 > "$ROOT/usr/local/lib/.alpine-proxy-manager.lock/pid"
run_install
assert_eq "陈旧锁被回收" 0 "$RC"
assert_eq "回收后无锁遗留" "alpine-proxy-manager" "$(libparent_entries)"

# ---- 命令链接冲突 ----
reset_root
mkdir -p "$ROOT/usr/local/bin"
echo foreign > "$LINKP"
run_install
assert_eq "不覆盖已有的非本项目命令" 1 "$RC"
assert_eq "已有命令内容未变" foreign "$(cat "$LINKP")"
assert_fail "冲突时无安装目录" test -e "$LIBD"
run_install --uninstall
assert_ok "卸载不删除非本项目命令" test -f "$LINKP"
reset_root
mkdir -p "$ROOT/usr/local/bin"
ln -s /somewhere/else "$LINKP"
run_install --uninstall
assert_eq "卸载保留他人的符号链接" "/somewhere/else" "$(readlink "$LINKP")"
reset_root

# ---- 旧布局迁移 ----
mkdir -p "$LIBD" "$ROOT/usr/local/bin"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$LIBD/"
echo oldbuild > "$LIBD/BUILD"
ln -s "$LIBD/bin/proxy-manager" "$LINKP"
run_install
assert_eq "旧布局迁移成功" 0 "$RC"
assert_contains "旧布局视为升级" "$OUT" "oldbuild"
assert_fail "旧布局 bin 被清理" test -e "$LIBD/bin"
assert_fail "旧布局 lib 被清理" test -e "$LIBD/lib"
assert_fail "旧布局 VERSION 被清理" test -e "$LIBD/VERSION"
assert_eq "迁移后命令链接" "../lib/alpine-proxy-manager/current/bin/proxy-manager" "$(readlink "$LINKP")"
assert_eq "迁移后 Build 正确" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"
# 旧布局迁移失败时还原
reset_root
mkdir -p "$LIBD" "$ROOT/usr/local/bin"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/VERSION" "$LIBD/"
ln -s "$LIBD/bin/proxy-manager" "$LINKP"
APM_FAULT=post_switch run_install
assert_eq "旧布局迁移失败返回 1" 1 "$RC"
assert_eq "旧布局迁移失败后链接还原" "$LIBD/bin/proxy-manager" "$(readlink "$LINKP")"
assert_ok "旧布局迁移失败后旧文件保留" test -f "$LIBD/bin/proxy-manager"
assert_fail "旧布局迁移失败后无 current" test -e "$LIBD/current"
reset_root

# ---- 路径含空格 ----
ROOT="$T_TMP/root with space"
LIBD=$ROOT/usr/local/lib/alpine-proxy-manager
LINKP=$ROOT/usr/local/bin/proxy-manager
APM_ROOT=$ROOT
run_install
assert_eq "含空格的根路径安装成功" 0 "$RC"
assert_eq "含空格的根路径可运行" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"
run_install --uninstall
assert_eq "含空格的根路径卸载成功" 0 "$RC"
assert_fail "含空格的根路径卸载后链接消失" test -e "$LINKP"
rm -rf "$ROOT"
ROOT=$T_TMP/root
LIBD=$ROOT/usr/local/lib/alpine-proxy-manager
LINKP=$ROOT/usr/local/bin/proxy-manager
APM_ROOT=$ROOT

# ---- 卸载 ----
run_install --uninstall
assert_eq "卸载不存在的安装返回 0" 0 "$RC"
assert_contains "卸载不存在的安装提示" "$OUT" "未安装"
reset_root
run_install
assert_eq "卸载前安装" 0 "$RC"
# 放入不应被卸载触碰的内容
mkdir -p "$ROOT/etc/alpine-proxy-manager/instances" "$ROOT/var/lib/alpine-proxy-manager" "$ROOT/usr/bin"
echo keep > "$ROOT/etc/alpine-proxy-manager/instances/AnyTLS-01.conf"
echo keep > "$ROOT/var/lib/alpine-proxy-manager/state"
echo keep > "$ROOT/usr/bin/sing-box"
echo keep > "$ROOT/usr/bin/snell-server"
echo keep > "$ROOT/usr/local/bin/other-tool"
run_install --uninstall
assert_eq "卸载成功" 0 "$RC"
assert_contains "卸载提示" "$OUT" "已卸载"
assert_fail "卸载后命令消失" test -e "$LINKP"
assert_fail "卸载后命令不是悬空链接" test -L "$LINKP"
assert_fail "卸载后安装目录消失" test -e "$LIBD"
assert_ok "不删除配置" test -f "$ROOT/etc/alpine-proxy-manager/instances/AnyTLS-01.conf"
assert_ok "不删除数据" test -f "$ROOT/var/lib/alpine-proxy-manager/state"
assert_ok "不删除 sing-box" test -f "$ROOT/usr/bin/sing-box"
assert_ok "不删除 Snell" test -f "$ROOT/usr/bin/snell-server"
assert_ok "不删除无关命令" test -f "$ROOT/usr/local/bin/other-tool"
assert_eq "卸载后无遗留" "" "$(libparent_entries)"
# 卸载后可以重新安装
run_install
assert_eq "卸载后重新安装" 0 "$RC"
assert_eq "重新安装后可运行" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"

# ---- 从 stdin 管道执行 ----
reset_root
OUT=$(sh -s -- --uninstall < "$INSTALLER" 2>&1)
assert_contains "管道 stdin 执行并传参" "$OUT" "未安装"
OUT=$(sh < "$INSTALLER" 2>&1)
assert_contains "管道 stdin 无参数执行安装" "$OUT" "安装完成"
assert_eq "管道安装后可运行" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"
reset_root

# ---- 下载被截断的 install.sh 不得执行任何操作 ----
TOTAL=$(wc -c < "$INSTALLER")
BAD=0
n=0
while [ "$n" -lt $((TOTAL - 1)) ]; do
    OUT=$(sh -c "$(head -c "$n" "$INSTALLER")" -- 2>&1)
    case $OUT in *安装完成*|*已卸载*) BAD=$((BAD + 1)) ;; esac
    [ -e "$ROOT/usr" ] && BAD=$((BAD + 1))
    if [ "$n" -lt $((TOTAL - 60)) ]; then n=$((n + 397)); else n=$((n + 1)); fi
done
assert_eq "任意截断位置都不执行安装" 0 "$BAD"
OUT=$(sh -c "$(head -c $((TOTAL - 40)) "$INSTALLER")" -- 2>&1)
assert_fail "截断后根目录未被创建" test -e "$ROOT/usr"

# ---- 开发者安装 --from-dir ----
reset_root
: > "$APM_TEST_DL_LOG"
run_install --from-dir "$SRC"
assert_eq "--from-dir 安装成功" 0 "$RC"
assert_eq "--from-dir Build 取自 git HEAD" "$(want_out 0.3.0 "$GOOD_NEW")" "$(ver_out)"
assert_eq "--from-dir 不下载" "" "$(cat "$APM_TEST_DL_LOG")"
echo "# dirty" >> "$SRC/lib/common.sh"
run_install --from-dir "$SRC"
assert_contains "未提交修改的 Build 带 dirty 标记" "$(ver_out)" "Build: $GOOD_NEW-dirty"
git -C "$SRC" checkout -q -- lib/common.sh
mkdir -p "$T_TMP/notgit"
run_install --from-dir "$T_TMP/notgit"
assert_eq "--from-dir 非 git 目录拒绝" 1 "$RC"
reset_root

t_done
