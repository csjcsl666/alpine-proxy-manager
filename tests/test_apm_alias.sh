# shellcheck shell=sh
# 短命令 apm: 与 proxy-manager 同目录的符号链接, 安装 升级 卸载 冲突保护, 以及经符号链接启动时的路径解析与行为等价
# 全部在 APM_ROOT 隔离目录中进行, 下载通过 APM_DOWNLOADER 替换为本地 shim
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

INSTALLER=$T_ROOT/install.sh
ROOT=$T_TMP/root
SYS=$T_TMP/sys
DL=$T_TMP/dl
SRC=$T_TMP/srcrepo
LIBD=$ROOT/usr/local/lib/alpine-proxy-manager
BIN=$ROOT/usr/local/bin
LINKP=$BIN/proxy-manager
APMP=$BIN/apm

mk_sysroot "$SYS" alpine
cat > "$DL" <<'EOS'
#!/bin/sh
while [ $# -gt 1 ]; do
    case $1 in
        -O) dest=$2; shift 2 ;;
        -T) shift 2 ;;
        *) shift ;;
    esac
done
cp "$APM_TEST_ARCHIVE" "$dest"
EOS
chmod +x "$DL"
export APM_ROOT="$ROOT" APM_SYSROOT="$SYS" APM_EUID=0 APM_DOWNLOADER="$DL" APM_DOWNLOAD_TRIES=1 APM_TEST_ARCHIVE=""

mkdir -p "$SRC"
git -C "$SRC" init -q
cp -R "$T_ROOT/bin" "$T_ROOT/lib" "$SRC/"
cp "$T_ROOT/VERSION" "$SRC/VERSION"
N=0
commit_src() {
    N=$((N + 1))
    printf '# %s\n' "$1" >> "$SRC/lib/common.sh"
    git -C "$SRC" add -A
    git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1"
    ARCH="$T_TMP/archive.$N.tgz"
    git -C "$SRC" archive --format=tar --prefix=alpine-proxy-manager-main/ HEAD | gzip -n > "$ARCH"
    APM_TEST_ARCHIVE=$ARCH
}
run_install() { OUT=$(sh -c "$(cat "$INSTALLER")" -- "$@" 2>&1); RC=$?; }
tree() { ( cd "$ROOT" && find . | sort ); }

# ---- 全新安装 ----
rm -rf "$ROOT"
commit_src "build 1"
run_install
assert_eq "全新安装成功" 0 "$RC"
assert_contains "输出提示短命令" "$OUT" "短命令: apm"
assert_ok "proxy-manager 存在" test -L "$LINKP"
assert_ok "apm 存在且是符号链接" test -L "$APMP"
assert_eq "apm 是指向 proxy-manager 的相对链接" proxy-manager "$(readlink "$APMP")"
assert_eq "proxy-manager 仍是原来的相对链接" ../lib/alpine-proxy-manager/current/bin/proxy-manager "$(readlink "$LINKP")"
assert_eq "apm 与 proxy-manager 解析到同一个文件" "$(readlink -f "$LINKP")" "$(readlink -f "$APMP")"
assert_contains "最终解析到 release 里的启动器" "$(readlink -f "$APMP")" "/releases/"
assert_eq "没有复制第二份启动器" 1 "$(find "$ROOT" -name proxy-manager -type f | wc -l | tr -d ' ')"

# ---- 经符号链接启动: 版本 Build help status 与 proxy-manager 完全一致 ----
assert_eq "apm --version 与 proxy-manager --version 完全一致" "$("$LINKP" --version)" "$("$APMP" --version)"
assert_contains "apm --version 带 Build" "$("$APMP" --version)" "Build: "
assert_eq "apm help 与 proxy-manager help 完全一致" "$("$LINKP" help </dev/null)" "$("$APMP" help </dev/null)"
assert_eq "apm status 与 proxy-manager status 完全一致" "$("$LINKP" status </dev/null 2>&1)" "$("$APMP" status </dev/null 2>&1)"
assert_eq "apm doctor 与 proxy-manager doctor 完全一致" "$("$LINKP" doctor </dev/null 2>&1)" "$("$APMP" doctor </dev/null 2>&1)"
assert_eq "apm core list 与 proxy-manager core list 完全一致" "$("$LINKP" core list </dev/null 2>&1)" "$("$APMP" core list </dev/null 2>&1)"
assert_eq "apm 未知命令的返回码与输出一致" "$("$LINKP" bogus </dev/null 2>&1; echo $?)" "$("$APMP" bogus </dev/null 2>&1; echo $?)"
assert_contains "help 同时说明 apm" "$("$APMP" help)" "apm"
assert_contains "help 仍然以 proxy-manager 为完整命令" "$("$APMP" help)" "用法: proxy-manager"
# 非 TTY
assert_eq "非 TTY 无参数与 proxy-manager 一致" "$("$LINKP" </dev/null 2>&1; echo $?)" "$("$APMP" </dev/null 2>&1; echo $?)"
assert_eq "非 TTY 无参数仍是帮助" 0 "$("$APMP" </dev/null >/dev/null 2>&1; echo $?)"
"$APMP" tui </dev/null >/dev/null 2>&1
assert_eq "非 TTY 的 apm tui 返回 2" 2 $?
assert_eq "非 TTY 的 apm tui 与 proxy-manager tui 一致" "$("$LINKP" tui </dev/null 2>&1)" "$("$APMP" tui </dev/null 2>&1)"
# 路径解析: 从别的目录 经 PATH 经二级符号链接启动
assert_eq "从根目录经 PATH 启动" "$("$LINKP" --version)" "$(cd / && PATH="$BIN:$PATH" apm --version)"
mkdir -p "$T_TMP/other"
ln -s "$APMP" "$T_TMP/other/apm2"
assert_eq "经二级符号链接启动 lib 路径解析正确" "$("$LINKP" --version)" "$("$T_TMP/other/apm2" --version)"
ln -s "$LINKP" "$T_TMP/other/pm2"
assert_eq "proxy-manager 的二级符号链接同样正确" "$("$LINKP" --version)" "$("$T_TMP/other/pm2" --version)"
assert_eq "经符号链接运行子命令使用同一套库" "$("$LINKP" sing-box list </dev/null 2>&1)" "$("$T_TMP/other/apm2" sing-box list </dev/null 2>&1)"

# ---- TTY: 用 script 分配伪终端, 没有 script 时跳过 (Alpine 上由 util-linux-misc 提供) ----
if command -v script >/dev/null 2>&1; then
    tty_run() { printf '0\n' | SHELL=/bin/sh APM_TUI_ANSI=0 LC_ALL=en_US.UTF-8 script -qec "$*" /dev/null 2>&1 | tr -d '\r'; }
    a=$(tty_run "$APMP")
    b=$(tty_run "$LINKP")
    c=$(tty_run "$APMP tui")
    d=$(tty_run "$LINKP tui")
    assert_contains "TTY 下 apm 进入 TUI 主菜单" "$a" "1. Core 管理"
    assert_contains "TTY 下 apm 菜单有退出项" "$a" "0. 退出"
    assert_contains "TTY 下 apm 正常退出" "$a" "已退出"
    assert_eq "TTY 下 apm 与 proxy-manager 进入完全相同的 TUI" "$b" "$a"
    assert_contains "TTY 下 apm tui 进入 TUI" "$c" "1. Core 管理"
    assert_eq "TTY 下 apm tui 与 proxy-manager tui 完全一致" "$d" "$c"
    assert_eq "TTY 下无参数与 tui 子命令进入同一个 TUI" "$a" "$c"
else
    t_skip "没有 script, 伪终端相关的 apm 测试跳过 (Alpine: apk add util-linux-misc)"
fi

# ---- 升级: 从没有 apm 的旧安装升级会自动获得 apm, 且不触碰任何数据 ----
mkdir -p "$ROOT/etc/alpine-proxy-manager/instances" "$ROOT/var/lib/alpine-proxy-manager/cores" "$ROOT/etc/sing-box"
printf 'id=AnyTLS-01\n' > "$ROOT/etc/alpine-proxy-manager/instances/AnyTLS-01.conf"
printf 'managed=true\ncore=singbox\n' > "$ROOT/var/lib/alpine-proxy-manager/cores/singbox.meta"
printf '{"log":{}}\n' > "$ROOT/etc/sing-box/config.json"
data_sum() { ( cd "$ROOT" && cat etc/alpine-proxy-manager/instances/*.conf var/lib/alpine-proxy-manager/cores/* etc/sing-box/config.json | cksum ); }
D0=$(data_sum)
rm -f "$APMP"
assert_fail "模拟 0.5.0: 没有 apm" test -e "$APMP"
commit_src "build 2"
run_install
assert_eq "升级成功" 0 "$RC"
assert_contains "升级提示新 Build" "$OUT" "→"
assert_eq "升级自动获得 apm" proxy-manager "$(readlink "$APMP")"
assert_contains "升级输出提示短命令" "$OUT" "短命令: apm"
assert_eq "升级没有改动任何数据" "$D0" "$(data_sum)"
assert_eq "升级之后只有一个 release" 1 "$(ls "$LIBD/releases" | wc -l | tr -d ' ')"
assert_eq "升级之后 apm 仍然可用" "$("$LINKP" --version)" "$("$APMP" --version)"
assert_eq "安装器不涉及服务操作" 0 "$(grep -c -E 'rc-service|rc-update|openrc-run|restart' "$INSTALLER" | tr -d ' ')"
# 同一 Build 且 apm 缺失: 已是最新, 同时补上
rm -f "$APMP"
run_install
assert_contains "同一 Build 提示已是最新" "$OUT" "已是最新"
assert_contains "同一 Build 补上缺失的 apm" "$OUT" "已补充短命令 apm"
assert_eq "apm 被补上" proxy-manager "$(readlink "$APMP")"
# 同一 Build 且 apm 正确: 什么都不做
S1=$(tree)
run_install
assert_contains "再次执行提示已是最新" "$OUT" "已是最新"
assert_not_contains "apm 正确时不再提示补充" "$OUT" "已补充"
assert_eq "apm 正确时文件树不变" "$S1" "$(tree)"
INO1=$(ls -li "$APMP" | awk '{print $1}')
run_install --force
assert_eq "--force 之后 apm 仍正确" proxy-manager "$(readlink "$APMP")"
assert_eq "--force 之后 apm 没有被重建" "$INO1" "$(ls -li "$APMP" | awk '{print $1}')"
# 用户自己建的绝对路径链接也算本项目别名, 修正为相对链接
rm -f "$APMP"; ln -s "$LINKP" "$APMP"
run_install --force
assert_eq "指向 proxy-manager 的绝对链接被修正为相对链接" proxy-manager "$(readlink "$APMP")"

# ---- 冲突: 不覆盖别人的 apm ----
# 描述 apm 的形态与内容, 不含会随父目录变化的链接计数
desc() {
    if [ -L "$APMP" ]; then printf 'link %s' "$(readlink "$APMP")"
    elif [ -d "$APMP" ]; then printf 'dir %s' "$(ls -A "$APMP" | tr '\n' ' ')"
    elif [ -e "$APMP" ]; then printf 'file %s %s' "$(stat -c %a "$APMP")" "$(cat "$APMP")"
    else printf 'none'; fi
}
foreign_case() { # 名称 创建命令
    rm -rf "$ROOT"
    mkdir -p "$BIN"
    eval "$2"
    BEFORE=$(desc)
    commit_src "build conflict $1"
    run_install
    assert_eq "$1: Manager 本身安装成功" 0 "$RC"
    assert_ok "$1: proxy-manager 可用" "$LINKP" --version
    assert_contains "$1: 警告已存在且不覆盖" "$OUT" "已存在且不是本项目创建的"
    assert_contains "$1: 警告指引使用 proxy-manager" "$OUT" "请使用 proxy-manager"
    assert_not_contains "$1: 不提示短命令可用" "$OUT" "短命令: apm"
    assert_eq "$1: 别人的 apm 完全没有变化" "$BEFORE" "$(desc)"
    run_install
    assert_eq "$1: 再次执行仍然不覆盖" "$BEFORE" "$(desc)"
    run_install --force
    assert_eq "$1: --force 也不覆盖" "$BEFORE" "$(desc)"
    OUT=$(sh -c "$(cat "$INSTALLER")" -- --uninstall 2>&1)
    assert_contains "$1: 卸载提示保留" "$OUT" "不是本项目创建的, 已保留"
    assert_eq "$1: 卸载不删除别人的 apm" "$BEFORE" "$(desc)"
    assert_fail "$1: 卸载删除了 proxy-manager" test -e "$LINKP"
}
foreign_case "普通文件" "printf 'foreign tool\n' > '$APMP'; chmod +x '$APMP'"
foreign_case "指向别处的链接" "ln -s /bin/true '$APMP'"
foreign_case "悬空的别处链接" "ln -s /nonexistent/other-tool '$APMP'"
foreign_case "目录" "mkdir '$APMP'; printf x > '$APMP/f'"
foreign_case "指向别的 proxy-manager" "ln -s other/proxy-manager '$APMP'"

# ---- 卸载: 只删除本项目创建的 apm ----
rm -rf "$ROOT"
commit_src "build uninstall"
run_install
assert_ok "卸载前 apm 存在" test -L "$APMP"
OUT=$(sh -c "$(cat "$INSTALLER")" -- --uninstall 2>&1)
assert_fail "卸载后 apm 消失" test -e "$APMP"
assert_fail "卸载后 apm 不是悬空链接" test -L "$APMP"
assert_fail "卸载后 proxy-manager 消失" test -L "$LINKP"
assert_fail "卸载后安装目录消失" test -d "$LIBD"
assert_not_contains "卸载本项目的 apm 不报错" "$OUT" "已保留"
run_install
assert_eq "卸载后重新安装 apm 回来" proxy-manager "$(readlink "$APMP")"
assert_eq "重新安装后版本一致" "$("$LINKP" --version)" "$("$APMP" --version)"
# 同目录里无关的命令不受影响
printf 'other\n' > "$BIN/unrelated"
OUT=$(sh -c "$(cat "$INSTALLER")" -- --uninstall 2>&1)
assert_eq "卸载不动无关命令" other "$(cat "$BIN/unrelated")"
assert_fail "没有 aliasless 悬空链接遗留" test -L "$APMP"

# ---- 失败回滚不受 apm 影响 ----
rm -rf "$ROOT"
commit_src "build rollback"
APM_FAULT=post_switch run_install
assert_eq "切换后故障返回 1" 1 "$RC"
assert_fail "回滚后没有 apm" test -e "$APMP"
assert_fail "回滚后没有 proxy-manager" test -e "$LINKP"
run_install
assert_eq "回滚后重新安装成功并带 apm" proxy-manager "$(readlink "$APMP")"
t_done
