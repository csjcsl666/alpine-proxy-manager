#!/bin/sh
# shellcheck disable=SC2015,SC2016,SC2034 # 测试脚本里 A && B || C 用来记录通过或失败
# 二维码依赖自动安装的真实验证 (v0.8.4): 需要网络, 在干净的 Alpine 容器里以 root 运行, 不属于 tests/run.sh
# 真实的 apk 真实的 Alpine 软件源 真实的 libqrencode-tools 与 zbar imagemagick (只用来把二维码解码回来对比)
# 验证: 缺少 qrencode 时 client_qr_ensure 真的装上并能运行 再次进入不重复安装 二维码解码后与分享 URL 完全一致 密码特殊字符
# 注意: 会安装与卸载 libqrencode-tools zbar imagemagick, 结束时恢复到开始前的状态
set -u
E2E_HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$E2E_HERE/net_lib.sh"
for _m in common environment state core model policy txn report client snell snellnet anytlsgw singbox sbhealth; do
    # shellcheck source=/dev/null
    . "$E2E_HERE/../../lib/$_m.sh"
done
[ "$(id -u)" = 0 ] || { say "需要 root"; exit 1; }
command -v apk >/dev/null 2>&1 || { say "需要 Alpine 的 apk"; exit 1; }

had_qr=no
command -v qrencode >/dev/null 2>&1 && had_qr=yes
had_zbar=no
command -v zbarimg >/dev/null 2>&1 && had_zbar=yes
had_ossl=no
command -v openssl >/dev/null 2>&1 && had_ossl=yes
had_im=no
apk info -e imagemagick >/dev/null 2>&1 && had_im=yes
restore() {
    [ "$had_qr" = yes ] || apk del libqrencode-tools >/dev/null 2>&1
    [ "$had_zbar" = yes ] || apk del zbar >/dev/null 2>&1
    [ "$had_im" = yes ] || apk del imagemagick >/dev/null 2>&1
    [ "$had_ossl" = no ] || command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null 2>&1
    [ "$had_ossl" = yes ] || apk del openssl >/dev/null 2>&1
}
trap 'restore; e2e_cleanup' EXIT

section "准备: 确保开始时没有 qrencode"
[ "$had_qr" = no ] || apk del libqrencode-tools >/dev/null 2>&1
command -v qrencode >/dev/null 2>&1 && { say "无法卸载已有的 qrencode, 跳过"; exit 0; }
ok "开始时没有 qrencode"

section "场景 1 缺少 qrencode: 进入二维码功能时自动安装 (真实 apk)"
# 不能放进命令替换 (子 shell 里设置的 CX_QR_BIN 不会回到这里)
client_qr_ensure "export X url" > "$E2E_DIR/ensure.out" 2>&1; rc=$?
OUT=$(cat "$E2E_DIR/ensure.out")
[ $rc = 0 ] && ok "client_qr_ensure 成功" || bad "client_qr_ensure 失败: $OUT"
case $OUT in *"未安装 qrencode，正在安装所需依赖 (libqrencode-tools)"*) ok "有安装提示" ;; *) bad "没有安装提示: $OUT" ;; esac
case $OUT in *"二维码工具安装成功"*) ok "有成功提示" ;; *) bad "没有成功提示" ;; esac
[ -n "$CX_QR_BIN" ] && "$CX_QR_BIN" -V >/dev/null 2>&1 && ok "qrencode 实际可以运行: $("$CX_QR_BIN" -V 2>&1 | head -n 1)" || bad "qrencode 不可运行"
apk info -e libqrencode-tools >/dev/null 2>&1 && ok "libqrencode-tools 已安装" || bad "libqrencode-tools 没有安装"

section "场景 2 再次进入不重复安装"
client_qr_ensure "export X url" > "$E2E_DIR/ensure2.out" 2>&1; rc=$?
OUT=$(cat "$E2E_DIR/ensure2.out")
[ $rc = 0 ] && [ -z "$OUT" ] && ok "已安装时静默通过, 没有任何安装输出" || bad "再次进入有输出: $OUT"

section "场景 3 二维码解码后与分享 URL 完全一致 (含需要百分号编码的密码与 IPv6 地址)"
# zbarimg 需要 ImageMagick 才能读 PNG
apk add --no-cache zbar imagemagick >/dev/null 2>&1
command -v zbarimg >/dev/null 2>&1 || { say "没有 zbarimg, 跳过解码对比"; exit 0; }
for pw in 'PlainPassword0123456789' 'ab+/c=d&e f:g@h#i?j%k' 'Zm9vYmFy-_~.0123'; do
    CX_ID=AnyTLS-01; CX_TYPE=anytls; CX_PASS=$pw; CX_HOST=2001:db8::5; CX_PORT=32001
    CX_SNI=apm.local; CX_TLSINS=yes; CX_TLSMODE=self-signed
    URL=$(_cx_r_url) || { bad "生成 URL 失败: $pw"; continue; }
    printf '%s' "$URL" | "$CX_QR_BIN" -t PNG -s 6 -m 2 -o "$E2E_DIR/qr.png"
    DEC=$(zbarimg --quiet --raw "$E2E_DIR/qr.png" 2>/dev/null)
    [ "$DEC" = "$URL" ] && ok "解码结果与 URL 完全一致: $(printf '%s' "$URL" | sed 's#//[^@]*@#//***@#')" || bad "解码不一致: $(printf '%s' "$DEC" | sed 's#//[^@]*@#//***@#')"
done

section "场景 4 终端输出的二维码 (UTF8) 能生成且不含明文 URL"
CX_PASS=PlainPassword0123456789
URL=$(_cx_r_url)
TXT=$(printf '%s' "$URL" | "$CX_QR_BIN" -t UTF8 -m 1)
[ -n "$TXT" ] && ok "UTF8 二维码已生成" || bad "UTF8 二维码为空"
case $TXT in *PlainPassword*|*anytls://*) bad "终端输出里出现了明文凭据" ;; *) ok "终端输出里没有明文凭据" ;; esac

section "场景 5 openssl 缺失时按需自动安装 (与 qrencode 共用同一套流程, 真实 apk)"
apk del openssl >/dev/null 2>&1
if command -v openssl >/dev/null 2>&1; then
    say "无法卸载 openssl, 跳过"
else
    ok "开始时没有 openssl"
    client_openssl_ensure "默认配置不需要 openssl" > "$E2E_DIR/ossl.out" 2>&1; rc=$?
    OUT=$(cat "$E2E_DIR/ossl.out")
    [ $rc = 0 ] && ok "client_openssl_ensure 成功" || bad "client_openssl_ensure 失败: $OUT"
    case $OUT in *"未安装 openssl，正在安装所需依赖 (openssl)"*) ok "有安装提示" ;; *) bad "没有安装提示: $OUT" ;; esac
    case $OUT in *"openssl安装成功"*) ok "有成功提示" ;; *) bad "没有成功提示" ;; esac
    [ -n "$CX_DEP_BIN" ] && "$CX_DEP_BIN" version >/dev/null 2>&1 && ok "openssl 实际可以运行: $("$CX_DEP_BIN" version 2>&1 | head -n 1)" || bad "openssl 不可运行"
    client_openssl_ensure "x" > "$E2E_DIR/ossl2.out" 2>&1
    [ ! -s "$E2E_DIR/ossl2.out" ] && ok "已安装时静默通过 不重复安装" || bad "再次进入有输出: $(cat "$E2E_DIR/ossl2.out")"
    # 装好之后真实解析一张真实证书的名称
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=real.example.net" -addext "subjectAltName=DNS:real.example.net,IP:203.0.113.8" -keyout "$E2E_DIR/k.pem" -out "$E2E_DIR/c.pem" >/dev/null 2>&1
    _cx_cert_facts "$E2E_DIR/c.pem" && [ "$CX_SAN_DNS" = real.example.net ] && [ "$CX_SAN_IP" = 203.0.113.8 ] && ok "真实证书的 DNS SAN 与 IP SAN 解析正确" || bad "证书解析: DNS=$CX_SAN_DNS IP=$CX_SAN_IP"
fi

say ""
say "通过 $E2E_PASS 失败 $E2E_FAIL"
[ "$E2E_FAIL" -eq 0 ]
