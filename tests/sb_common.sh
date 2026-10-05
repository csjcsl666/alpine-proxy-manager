# shellcheck shell=sh
# sing-box 测试共用的夹具与辅助函数, 由 test_singbox*.sh source, 需先 source tests/lib.sh
# 不以 test_ 开头, run.sh 不会单独运行它

ZIPS=$T_TMP/zips
DL=$T_TMP/dl
mk_dl_shim "$DL"
mk_snell_zip "$ZIPS" v6.0.0rc2 '2026-01-01 00:00:00.000000 [server_main] <NOTIFY> snell-server v6.0.0 (Aug  7 2026)'
mk_sb_release "$ZIPS" 1.13.14; SHA_D=$SB_LAST_SHA
mk_sb_release "$ZIPS" 1.14.2; SHA_N=$SB_LAST_SHA
mk_sb_release "$ZIPS" 1.13.99 BADBIN-1.13.99; SHA_BAD=$SB_LAST_SHA
mk_sb_release "$ZIPS" 1.13.51 mismatch 1.13.50; SHA_MIS=$SB_LAST_SHA
printf 'not a tarball\n' > "$ZIPS/sing-box-1.13.60-linux-amd64-musl.tar.gz"
SHA_GARBAGE=$(sha256sum "$ZIPS/sing-box-1.13.60-linux-amd64-musl.tar.gz" | awk '{ print $1 }')
# 压缩包里没有 sing-box
W=$T_TMP/emptytar
mkdir -p "$W/sing-box-1.13.61-linux-amd64-musl"
echo x > "$W/sing-box-1.13.61-linux-amd64-musl/LICENSE"
( cd "$W" && tar -czf "$ZIPS/sing-box-1.13.61-linux-amd64-musl.tar.gz" sing-box-1.13.61-linux-amd64-musl )
SHA_NOMEMBER=$(sha256sum "$ZIPS/sing-box-1.13.61-linux-amd64-musl.tar.gz" | awk '{ print $1 }')
# sing-box 是脚本的压缩包, 不得被执行
SM=$T_TMP/scriptmarker
mkdir -p "$SM" "$T_TMP/scrtar/sing-box-1.13.62-linux-amd64-musl"
printf '#!/bin/sh\ntouch "%s/SHOULD_NOT_EXIST"\necho "sing-box version 1.13.62"\n' "$SM" > "$T_TMP/scrtar/sing-box-1.13.62-linux-amd64-musl/sing-box"
chmod +x "$T_TMP/scrtar/sing-box-1.13.62-linux-amd64-musl/sing-box"
( cd "$T_TMP/scrtar" && tar -czf "$ZIPS/sing-box-1.13.62-linux-amd64-musl.tar.gz" sing-box-1.13.62-linux-amd64-musl )
SHA_SCRIPT=$(sha256sum "$ZIPS/sing-box-1.13.62-linux-amd64-musl.tar.gz" | awk '{ print $1 }')

new_s() {
    A=$T_TMP/$1
    rm -rf "$A"
    mk_sysroot "$A" alpine
    mk_sim_system "$A"
    K=$A/fake-rc
    mkdir -p "$K"
    echo stopped > "$K/state"
    echo stopped > "$K/state-sing-box"
    : > "$K/dl.log"
    APM_SYSROOT=$A
    APM_FAKE_RC_DIR=$K
    APM_EUID=0
    APM_ARCH=x86_64
    APM_DOWNLOADER=$DL
    APM_TEST_ZIPS=$ZIPS
    APM_TEST_DL_LOG=$K/dl.log
    APM_SB_DL_BASE=https://example.invalid/releases
    APM_SB_WAIT=1
    APM_SNELL_WAIT=1
    APM_SB_SHA256=$SHA_D
    export APM_SYSROOT APM_FAKE_RC_DIR APM_EUID APM_ARCH APM_DOWNLOADER APM_TEST_ZIPS APM_TEST_DL_LOG APM_SB_DL_BASE APM_SB_WAIT APM_SNELL_WAIT APM_SB_SHA256
    unset APM_VAR APM_ETC APM_BACKUP_DIR APM_BACKUP_KEEP
}
snap() { (cd "$A" && find . \( -path ./fake-rc -o -path ./.chown.log -o -path ./.apk-installed -o -path './var/tmp/*' \) -prune -o -print | sort; cat etc/passwd etc/group; ls -A var/tmp | wc -l); }
calls() { cat "$K/calls" 2>/dev/null; }
count_calls() { grep -c "^sing-box $1\$" "$K/calls" 2>/dev/null || true; }
running() { core_discover singbox; [ "$CF_STATE" = running ]; }
META() { printf '%s/var/lib/alpine-proxy-manager/cores/singbox.meta' "$A"; }
use_sha() { APM_SB_SHA256=$1; export APM_SB_SHA256; }
fail_case() {
    assert_eq "$1: 返回非零" 1 "$([ "$2" -ne 0 ] && echo 1 || echo 0)"
    assert_eq "$1: 回滚后文件树与账户和安装前一致" "$BEFORE" "$(snap)"
    assert_fail "$1: 没有元数据" test -e "$(META)"
    assert_fail "$1: 没有运行级别链接" test -e "$A/etc/runlevels/default/sing-box"
    assert_eq "$1: 服务不在运行" stopped "$(cat "$K/state-sing-box")"
}

