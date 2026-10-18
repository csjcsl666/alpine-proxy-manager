#!/bin/sh
# shellcheck shell=sh
# sing-box SOCKS5 自动故障切换的执行脚本, 由 lib/sbhealth.awk 在事件触发时启动, 不是常驻进程, 也不是定时任务
# 只访问本机 sing-box 的 Clash API (127.0.0.1, 带密钥), 从不直接连接任何 SOCKS5 上游
#
# 用法: sbhealth-failover.sh 命令 标签
#   switch TAG   把该 Profile 的 selector 切到 direct (已授权自动切换的 Profile 判定为不可用之后)
#   reset TAG    把 selector 切回 SOCKS5 (监控启动 停止时恢复严格的 SOCKS5 策略)
#   probe TAG    让 sing-box 对该 SOCKS5 出站发起一次完整请求 (握手 认证 CONNECT TLS HTTP), 成功就把 selector 切回 SOCKS5
#                并经事件流回报 @F ok, 失败回报 @F fail
# TAG 是 apm-socks-名称. selector 的标签是 apm-sel-名称
#
# 环境变量 (由状态机继承自守护进程, 密钥不在命令行): SBH_API_PORT SBH_API_SECRET SBH_FIFO
#   探测地址必须是 https (sing-box 的 delay 接口只接受 https), 两个独立地址, 见下
#   SBH_PROBE_TIMEOUT 探测超时毫秒, 默认 5000

cmd=${1:-}
tag=${2:-}
case $tag in apm-socks-*) ;; *) exit 2 ;; esac
name=${tag#apm-socks-}
case $name in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
port=${SBH_API_PORT:?}
sec=${SBH_API_SECRET:?}
sel=apm-sel-$name
# 两个相互独立的 https 探测地址 (默认 Cloudflare 与 Google), 任意一个通过就算恢复验证通过, 都失败则继续 DIRECT
# 地址可以在 sbhealth.conf 里设置 (probe_url probe_url2), 由 proxy-manager 写到运行目录里的 probe_url (第 1 行与第 2 行, 空行用默认值)
url1=https://cp.cloudflare.com/generate_204
url2=https://www.gstatic.com/generate_204
if [ -r "${SBH_DIR:-/nonexistent}/probe_url" ]; then
    _u=$(sed -n 1p "$SBH_DIR/probe_url"); [ -z "$_u" ] || url1=$_u
    _u=$(sed -n 2p "$SBH_DIR/probe_url"); [ -z "$_u" ] || url2=$_u
fi
[ -z "${SBH_PROBE_URL:-}" ] || { url1=$SBH_PROBE_URL; url2=; }
[ -z "${SBH_PROBE_URL2:-}" ] || url2=$SBH_PROBE_URL2
tmo=${SBH_PROBE_TIMEOUT:-5000}
case $tmo in ''|*[!0-9]*) tmo=5000 ;; esac

# api 方法 路径 [正文] -> 输出 HTTP 状态码
api() {
    local _b _l
    _b=${3:-}
    _l=${#_b}
    printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$1" "$2" "$sec" "$_l" "$_b" \
        | timeout 12 nc 127.0.0.1 "$port" 2>/dev/null | head -n 1 | tr -d '\r' | awk '{ print $2 }'
}

report() { # ok | fail | swfail
    [ -p "${SBH_FIFO:-}" ] || return 0
    printf '@F %s %s\n' "$1" "$tag" | timeout 3 tee -- "$SBH_FIFO" >/dev/null 2>&1
}

select_to() { # 目标出站标签
    [ "$(api PUT "/proxies/$sel" "{\"name\":\"$1\"}")" = 204 ]
}

# URL 编码 (探测地址只含 URL 里常见的字符)
urlenc() {
    printf '%s' "$1" | sed 's/%/%25/g; s/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s/#/%23/g; s/ /%20/g'
}

case $cmd in
    switch)
        select_to direct || report swfail
        ;;
    reset)
        select_to "$tag" || :
        ;;
    probe)
        # 最多顺序请求两次 (不并发), 请求都通过 /proxies/该 Profile 的出站/delay, 只经过这一个 SOCKS5 出站, 不会走 DIRECT 也不会检测其他 Profile
        # 探测失败只说明"恢复验证未通过", 不是上游故障证据: 只回报 fail, 状态机不会因此记录任何新故障
        code=
        for u in "$url1" "$url2"; do
            case $u in https://*) ;; *) continue ;; esac
            code=$(api GET "/proxies/$tag/delay?url=$(urlenc "$u")&timeout=$tmo")
            [ "$code" = 200 ] && break
        done
        if [ "$code" = 200 ]; then
            if select_to "$tag"; then report ok; else report fail; fi
        else
            report fail
        fi
        ;;
    *) exit 2 ;;
esac
exit 0
