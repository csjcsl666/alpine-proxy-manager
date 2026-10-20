# shellcheck shell=sh
# Client Export: Public Endpoint (客户端连接地址), 凭据显示, 人类可读信息, sing-box 客户端 JSON, 分享 URL, 二维码
#
# 分层
#   Public Endpoint   每个实例 (Snell 为 Core 级) 一份 host 与 port, 只告诉客户端连哪里
#                     监听地址与端口不等于客户端连接地址, Manager 不配置 NAT 不开防火墙 不探测公网 IP
#   Client Export Facts   CX_* 变量, 由 _cx_load_* 从存储读取并校验, 失败即整体失败, 不输出半份结果
#   Renderer          _cx_r_show _cx_r_singbox _cx_r_url 只消费 CX_* 变量, 不自己读实例文件
#
# 安全边界
#   - 只导出该实例客户端认证所需的凭据, 不导出 TLS 私钥, SOCKS 出口凭据, 其他实例的凭据
#   - 目标访问限制与 SOCKS 出口是服务端策略, 不进入客户端导出, 切换它们不改变导出内容
#   - 凭据只来自存储文件, 只写 stdout, 不写临时文件 日志 元数据, 不进入子进程 argv (二维码走 stdin)
#   - 警告信息写 stderr, 这样 > file 只得到导出内容
#   - 所有导出命令只读, 不改凭据, 不重启服务, 不重建证书
#   - 只实现有明确依据的分享 URL: AnyTLS (anytls-go uri_scheme), Hysteria2 (官方 URI Scheme), Shadowsocks (SIP002 SIP022)
#     TUIC 与 Snell 没有稳定的通用 URI, 不发明私有 scheme
#
# 退出码: 0 成功, 1 失败, 2 用法错误, 3 该格式不适用, 4 被拒绝, 5 可选依赖缺失

CX_ID=
CX_TYPE=
CX_ENABLED=
CX_HOST=
CX_PORT=
CX_SNI=
CX_TLSMODE=
CX_CERT=
CX_UUID=
CX_PASS=
CX_METHOD=
CX_CC=
CX_MODE=
CX_LISTEN=
CX_LPORT=
CX_POLICY=
CX_EGRESS=

# ---- Public Endpoint ----

# 客户端连接地址的主机规范化: IPv4, IPv6 (带或不带方括号输入, 存储不带方括号, 小写), 主机名 (小写)
# 成功输出规范形式, 失败在 stdout 输出原因并返回 1
# 拒绝未指定地址 0.0.0.0 与 ::, 它们不可能是客户端的目的地; 回环地址允许 (本机测试用), 展示时提醒
client_host_norm() { # HOST
    local _h _b _last
    _h=$1
    _b=no
    case $_h in
        \[*\]) _h=${_h#\[}; _h=${_h%\]}; _b=yes ;;
    esac
    _h=$(printf '%s' "$_h" | tr '[:upper:]' '[:lower:]')
    case $_h in
        '') printf '地址为空'; return 1 ;;
        *:*)
            _sb_valid_ipv6_dest "$_h" || { printf 'IPv6 地址无效: %s' "$1"; return 1; }
            [ "$_h" != :: ] || { printf '未指定地址 :: 不能作为客户端连接地址'; return 1; }
            printf '%s' "$_h"
            ;;
        *)
            if [ "$_b" = yes ]; then
                printf '方括号只用于 IPv6 地址: %s' "$1"
                return 1
            elif printf '%s' "$_h" | grep -Eq '^[0-9.]+$'; then
                _sb_valid_ipv4_dest "$_h" || { printf 'IPv4 地址无效: %s' "$1"; return 1; }
                [ "$_h" != 0.0.0.0 ] || { printf '未指定地址 0.0.0.0 不能作为客户端连接地址'; return 1; }
                printf '%s' "$_h"
            else
                [ "${#_h}" -le 253 ] || { printf '主机名过长: %s' "$1"; return 1; }
                printf '%s' "$_h" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$' \
                    || { printf '主机名无效: %s' "$1"; return 1; }
                _last=${_h##*.}
                case $_last in
                    *[!0-9]*) ;;
                    *) printf '主机名无效 (末段不能全是数字): %s' "$1"; return 1 ;;
                esac
                printf '%s' "$_h"
            fi
            ;;
    esac
}

# 存储里的 public.host 与 public.port: 两个键同时存在或同时缺省, host 必须已是规范形式
# public.sni 独立于连接地址, 存在时必须是规范形式的域名
client_endpoint_check() { # FILE
    local _h _p _n _s
    _h=$(kv_get "$1" public.host)
    _p=$(kv_get "$1" public.port)
    _s=$(kv_get "$1" public.sni)
    if kv_keys "$1" | grep -qx 'public.sni'; then
        _n=$(client_sni_norm "$_s") || { apm_err "$1: public.sni 无效: $_n"; return 1; }
        [ "$_n" = "$_s" ] || { apm_err "$1: public.sni 不是规范形式"; return 1; }
    fi
    if [ -z "$_h" ] && [ -z "$_p" ]; then
        kv_keys "$1" | grep -Eq '^public\.(host|port)$' && { apm_err "$1: public.host 与 public.port 不能为空"; return 1; }
        return 0
    fi
    if [ -z "$_h" ] || [ -z "$_p" ]; then
        apm_err "$1: public.host 与 public.port 必须同时设置"
        return 1
    fi
    _n=$(client_host_norm "$_h") || { apm_err "$1: public.host 无效: $_n"; return 1; }
    [ "$_n" = "$_h" ] || { apm_err "$1: public.host 不是规范形式"; return 1; }
    is_port "$_p" || { apm_err "$1: public.port 需要 1 到 65535"; return 1; }
}

# 客户端 TLS 服务名 (SNI) 的规范化: 小写域名, 不接受 IP 地址 (RFC 6066 不允许在 SNI 里放 IP 字面量), 不接受通配符
# 成功输出规范形式, 失败在 stdout 输出原因并返回 1
client_sni_norm() { # NAME
    local _n
    _n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $_n in
        '') printf 'TLS 服务名为空'; return 1 ;;
        *:*|*[!a-z0-9.-]*) printf 'TLS 服务名只能是域名 (字母 数字 点 连字符), 不能是 IP 地址或包含其他字符: %s' "$1"; return 1 ;;
    esac
    if printf '%s' "$_n" | grep -Eq '^[0-9.]+$'; then
        printf 'TLS 服务名不能是 IP 地址: %s' "$1"
        return 1
    fi
    [ "${#_n}" -le 253 ] || { printf 'TLS 服务名过长: %s' "$1"; return 1; }
    printf '%s' "$_n" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$' \
        || { printf 'TLS 服务名无效: %s' "$1"; return 1; }
    printf '%s' "$_n"
}

# URI 与 host:port 里的主机, IPv6 加方括号
_cx_host_uri() {
    case $1 in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# 百分号编码, 只保留 RFC 3986 的非保留字符, 值来自 stdin 之外不进入 argv
_cx_pct() { # VALUE
    printf '%s' "$1" | awk '
        BEGIN { for (i = 32; i < 127; i++) t[sprintf("%c", i)] = i }
        {
            s = $0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
                else if (c in t) printf "%%%02X", t[c]
                else exit 1
            }
        }'
}

_cx_b64url() { printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'; }

# ---- TLS 客户端参数: 来自真实证书 ----
# 事实 (从证书文件解析): CX_CERT_PARSED yes|no  CX_CERT_CN  CX_SAN_DNS (小写 空格分隔)  CX_SAN_IP  CX_CERT_SELF yes|no (自签名)
# 结论 (连接地址已知之后由 _cx_tls_resolve 得到): CX_SNI (可以为空: 不发送 SNI)  CX_SNI_SRC  CX_SANOK  CX_TLS_NOTE
# 输入: CX_SNI_OVR 用户明确设置的客户端 TLS 服务名 (public.sni)  CX_SNI_STORED sing-box 实例配置里记录的 server_name (生成证书时使用的名称)
# server (连接目标) 与 server_name (TLS 身份名) 是两件事: 这里只决定后者, 前者来自 Public Endpoint
CX_CERT_PARSED=no
CX_CERT_CN=
CX_SAN_DNS=
CX_SAN_IP=
CX_CERT_SELF=yes
CX_SNI_SRC=
CX_SNI_STORED=
CX_SNI_OVR=
CX_TLS_NOTE=
CX_PIN=no

# IPv4 原样, IPv6 展开为 8 组 4 位小写十六进制, 用来比较证书里的 IP SAN 与连接地址
_cx_ip_canon() { # ADDR
    case $1 in
        *:*)
            printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk '{
                s = $0; dc = index(s, "::")
                if (dc) { l = substr(s, 1, dc - 1); r = substr(s, dc + 2) } else { l = s; r = "" }
                nl = (l == "") ? 0 : split(l, L, ":"); nr = (r == "") ? 0 : split(r, R, ":")
                miss = dc ? 8 - nl - nr : 0
                out = ""
                for (i = 1; i <= nl; i++) { h = L[i]; while (length(h) < 4) h = "0" h; out = out h ":" }
                for (i = 1; i <= miss; i++) out = out "0000:"
                for (i = 1; i <= nr; i++) { h = R[i]; while (length(h) < 4) h = "0" h; out = out h ":" }
                sub(/:$/, "", out); print out }'
            ;;
        *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    esac
}

# openssl 接缝: 与 anytlsgw.sh 的 _agw_openssl 相同的 sysroot 规则, 放在这里是为了 client.sh 不依赖别的模块
_cx_openssl() {
    if [ -n "${APM_SYSROOT:-}" ]; then
        [ -x "$(env_path /usr/bin/openssl)" ] || return 127
        "$(env_path /usr/bin/openssl)" "$@"
    else
        openssl "$@"
    fi
}

# 解析证书文件, 失败返回 1 (没有 openssl 或证书无法读取), CX_CERT_PARSED 只有完整解析成功才是 yes
_cx_cert_facts() { # 证书文件的真实路径
    local _sub _iss _san
    CX_CERT_PARSED=no
    CX_CERT_CN=
    CX_SAN_DNS=
    CX_SAN_IP=
    CX_CERT_SELF=yes
    [ -r "$1" ] || return 1
    _sub=$(_cx_openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject= *//')
    [ -n "$_sub" ] || return 1
    _iss=$(_cx_openssl x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
    CX_CERT_CN=$(printf '%s' "$_sub" | sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p' | head -n 1 | sed 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    _san=$(_cx_openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n')
    CX_SAN_DNS=$(printf '%s\n' "$_san" | sed -n 's/^[[:space:]]*DNS:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/ $//')
    CX_SAN_IP=$(printf '%s\n' "$_san" | sed -n 's/^[[:space:]]*IP Address:[[:space:]]*//p' | sed 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/ $//')
    if [ "$_sub" != "$_iss" ]; then CX_CERT_SELF=no; fi
    CX_CERT_PARSED=yes
}

# 名称是否被证书的 DNS SAN 覆盖: 精确相同, 或通配符 *.域 只匹配一级
_cx_san_covers() { # NAME
    local _s
    for _s in $CX_SAN_DNS; do
        [ "$_s" != "$1" ] || return 0
        case $_s in
            \*.*) [ "${1#*.}" != "$1" ] && [ "*.${1#*.}" = "$_s" ] && return 0 ;;
        esac
    done
    return 1
}

# 连接地址 (IP) 是否出现在证书的 IP SAN 里
_cx_ip_in_san() { # ADDR
    local _a _i
    _a=$(_cx_ip_canon "$1")
    for _i in $CX_SAN_IP; do
        [ "$(_cx_ip_canon "$_i")" != "$_a" ] || return 0
    done
    return 1
}

# 客户端 TLS 服务名 (SNI) 的最终策略 (D139)
#   默认 (自签名证书 跳过证书验证 服务端不要求特定 SNI): 不指定. JSON 不写 server_name 分享 URL 不带 sni, 由客户端按连接地址处理
#          不使用任何内部占位名称 (apm.local anytls-gateway) 也不使用任何第三方网站域名
#   用户用 sni set 明确指定的名称: 始终优先使用, 原样导出到 show JSON URL QR; 它只是客户端发送的值, 不代表服务器持有该名称的证书
#   需要按名称校验证书的配置 (嵌入证书固定校验 与 CA 签发的证书): 必须与证书匹配, 所以从真实证书解析, 唯一确定不了就拒绝, 不猜测
#     1 证书只有一个 DNS SAN 用它
#     2 多个 DNS SAN: 连接地址在其中就用连接地址 否则实例记录的 server-name 在其中就用它 否则拒绝并列出名称
#     3 只有 IP SAN: 不发送 SNI (RFC 6066 不允许 IP 字面量) 连接地址在 IP SAN 里才算被证书覆盖
#     4 只有 CN 的历史证书: 取 CN 但客户端会拒绝这种证书的名称校验 不允许嵌入证书固定校验
#     5 没有 openssl 或无法解析证书: 只有 sing-box 实例能退回它记录的 server-name 同样不允许嵌入证书固定校验
# CX_PIN yes 表示这次是嵌入证书固定校验的导出
# 不修改证书, 不修改服务端 TLS 配置, 不重新生成任何东西
_cx_tls_resolve() {
    local _first _n _cnt _chosen _strict
    [ -n "$CX_TLSMODE" ] || return 0
    CX_SNI=
    CX_SNI_SRC=
    CX_SANOK=no
    CX_TLS_NOTE=
    _strict=no
    if [ "${CX_PIN:-no}" = yes ] || [ "${CX_TLSINS:-yes}" = no ]; then _strict=yes; fi
    if [ "$_strict" = no ]; then
        if [ -n "$CX_SNI_OVR" ]; then
            _n=$(client_sni_norm "$CX_SNI_OVR") || { apm_err "$CX_ID: 保存的客户端 TLS 服务名无效: $_n"; return 1; }
            CX_SNI=$_n
            CX_SNI_SRC=override
            CX_TLS_NOTE="这是你指定的客户端 TLS 服务名 跳过证书验证时客户端不会验证它对应网站的身份 服务器也不一定持有该名称的证书 它不等于网站伪装"
        else
            CX_SNI_SRC=default
        fi
        return 0
    fi
    # 需要按名称校验: 先确保有 openssl (缺失时按需安装, 失败就拒绝, 不降级), 再从真实证书取事实
    client_openssl_ensure "不带 --embed-cert 的默认配置不需要 openssl, 但那是跳过证书验证的配置, 不是证书固定校验" || return 5
    if [ -n "${CX_CERT:-}" ] && _cx_cert_facts "$(env_path "$CX_CERT")"; then :; else CX_CERT_PARSED=no; fi
    if [ -n "$CX_SNI_OVR" ]; then
        _n=$(client_sni_norm "$CX_SNI_OVR") || { apm_err "$CX_ID: 保存的客户端 TLS 服务名无效: $_n"; return 1; }
        CX_SNI=$_n
        CX_SNI_SRC=override
        if [ "$CX_CERT_PARSED" = yes ] && _cx_san_covers "$CX_SNI"; then
            CX_SANOK=yes
        else
            CX_TLS_NOTE="自定义的 TLS 服务名 $CX_SNI 没有被服务端证书覆盖: 嵌入证书固定校验与正常证书验证需要匹配的名称 此时不可用"
        fi
        return 0
    fi
    if [ "$CX_CERT_PARSED" != yes ]; then
        apm_err "$CX_ID: 无法解析服务端证书 (文件不存在 不可读 或格式错误), 拒绝导出需要按名称校验的配置; 默认配置 (不嵌入证书) 不受影响"
        return 1
    fi
    # 有意按空格拆分: CX_SAN_DNS 是已校验的小写名称列表
    # shellcheck disable=SC2086
    set -- $CX_SAN_DNS
    _cnt=$#
    if [ "$_cnt" -eq 1 ]; then
        CX_SNI=$1
        CX_SNI_SRC=san
        CX_SANOK=yes
    elif [ "$_cnt" -gt 1 ]; then
        _chosen=
        for _first in "$@"; do
            [ "$_first" != "$CX_HOST" ] || _chosen=$_first
        done
        if [ -z "$_chosen" ] && [ -n "$CX_SNI_STORED" ]; then
            for _first in "$@"; do
                [ "$_first" != "$CX_SNI_STORED" ] || _chosen=$_first
            done
        fi
        if [ -z "$_chosen" ]; then
            apm_err "$CX_ID: 服务端证书覆盖多个 DNS 名称 ($CX_SAN_DNS), 无法唯一确定客户端 TLS 服务名, 拒绝猜测; 请用 endpoint ... sni set 名称 选择其中一个 (不会修改证书与服务端配置)"
            return 4
        fi
        CX_SNI=$_chosen
        CX_SNI_SRC=san
        CX_SANOK=yes
    elif [ -n "$CX_SAN_IP" ]; then
        CX_SNI=
        CX_SNI_SRC=ip-san
        if _cx_ip_in_san "$CX_HOST"; then
            CX_SANOK=yes
        else
            CX_TLS_NOTE="服务端证书只有 IP SAN 且不包含连接地址 $CX_HOST: 不发送 SNI, 嵌入证书固定校验不可用"
        fi
    elif [ -n "$CX_CERT_CN" ]; then
        if client_sni_norm "$CX_CERT_CN" >/dev/null; then
            CX_SNI=$CX_CERT_CN
            CX_SNI_SRC=cn
            CX_TLS_NOTE="服务端证书只有 CN 没有 SAN (历史证书), 客户端会拒绝这种证书的名称校验, 嵌入证书固定校验不可用; 跳过证书验证不受影响"
        else
            CX_SNI=
            CX_SNI_SRC=cn-ip
            CX_TLS_NOTE="服务端证书只有 CN 且不是域名, 不发送 SNI, 嵌入证书固定校验不可用"
        fi
    else
        apm_err "$CX_ID: 服务端证书里没有可用的名称 (SAN 或 CN), 无法确定 TLS 服务名, 拒绝导出"
        return 1
    fi
    if [ "$CX_SNI_SRC" = san ] && [ -n "$CX_SNI_STORED" ] && [ "$CX_SNI_STORED" != "$CX_SNI" ]; then
        CX_TLS_NOTE="实例配置记录的 server_name ($CX_SNI_STORED) 与证书里的名称不一致, 以证书为准"
    fi
    return 0
}

# 人类可读的来源说明
_cx_sni_src_text() {
    case $CX_SNI_SRC in
        default) printf '默认: 不填写 SNI, 由客户端按连接地址处理' ;;
        override) printf '用户指定' ;;
        san) printf '取自服务端证书的 DNS SAN' ;;
        ip-san) printf '证书只有 IP SAN' ;;
        cn) printf '取自服务端证书的 CN (没有 SAN)' ;;
        cn-ip) printf '证书的 CN 不是域名' ;;
        instance) printf '取自实例配置 (未解析证书)' ;;
    esac
}

# ---- 提醒 ----

_cx_warn_secret() { printf '警告：以下内容包含客户端凭据\n' >&2; }

# 读取 Public Endpoint, 缺失即失败并说明原因
_cx_need_endpoint() { # FILE LABEL
    local _h _p
    _h=$(kv_get "$1" public.host)
    _p=$(kv_get "$1" public.port)
    if [ -z "$_h" ] && [ -z "$_p" ]; then
        apm_err "$2 尚未配置客户端连接地址, 请先执行 endpoint set 主机 端口 (内部监听地址 ${CX_LISTEN:-?}:${CX_LPORT:-?} 不等于客户端连接地址)"
        return 1
    fi
    client_endpoint_check "$1" || return 1
    CX_HOST=$_h
    CX_PORT=$_p
}

# ---- 事实: sing-box 实例 ----

# 读取并校验实例的凭据与 TLS 事实, 任何一项缺失或无效都失败, 不省略字段不使用默认
_cx_load_sb_creds() { # FILE
    local _f
    _f=$1
    [ -r "$_f" ] || { apm_err "无法读取 $_f (需要 root)"; return 1; }
    sb_instance_validate "$_f" >/dev/null 2>&1 || { sb_instance_validate "$_f" 2>&1 | sed 's/^/  /' >&2; apm_err "实例配置无效, 拒绝导出"; return 1; }
    CX_ID=$(kv_get "$_f" id)
    CX_TYPE=$(kv_get "$_f" type)
    CX_ENABLED=$(kv_get "$_f" enabled)
    CX_LISTEN=$(kv_get "$_f" listen)
    CX_LPORT=$(kv_get "$_f" listen_port)
    CX_PASS=$(kv_get "$_f" credential.password)
    CX_UUID=
    CX_METHOD=
    CX_CC=
    CX_SNI=
    CX_SNI_SRC=
    CX_SNI_STORED=
    CX_SNI_OVR=$(kv_get "$_f" public.sni)
    CX_TLS_NOTE=
    CX_TLSMODE=
    CX_CERT=
    CX_TLSINS=yes
    CX_SANOK=yes
    case $CX_TYPE in
        tuic) CX_UUID=$(kv_get "$_f" credential.uuid); CX_CC=$(kv_get "$_f" transport.congestion_control) ;;
        shadowsocks) CX_METHOD=$(kv_get "$_f" credential.method) ;;
    esac
    if _sb_type_tls "$CX_TYPE"; then
        CX_SNI_STORED=$(kv_get "$_f" tls.server_name)
        CX_TLSMODE=$(kv_get "$_f" tls.mode)
        CX_CERT=$(kv_get "$_f" tls.certificate_path)
        case $CX_TLSMODE in
            self-signed) ;;
            *) apm_err "$CX_ID: 不支持导出的 TLS 模式: '$CX_TLSMODE'"; return 1 ;;
        esac
    fi
    CX_POLICY=off
    _sb_policy_present "$_f" && _sb_policy_check "$_f" >/dev/null 2>&1 && _sb_policy_on "$_f" && CX_POLICY=on
    CX_EGRESS=direct
    kv_keys "$_f" | grep -qx egress_socks && CX_EGRESS=socks
    return 0
}

_cx_load_sb() { # FILE
    _cx_load_sb_creds "$1" || return 1
    _cx_need_endpoint "$1" "$CX_ID" || return 1
    _cx_tls_resolve
}

# ---- 渲染: 人类可读 ----

_cx_label() {
    case $1 in
        anytls) printf 'AnyTLS' ;;
        hysteria2) printf 'Hysteria2' ;;
        tuic) printf 'TUIC' ;;
        shadowsocks) printf 'Shadowsocks' ;;
        snell) printf 'Snell' ;;
    esac
}

# 连接参数摘要, 默认不含凭据
_cx_r_show() {
    printf '客户端连接信息 %s\n' "$CX_ID"
    printf '  协议：%s\n' "$(_cx_label "$CX_TYPE")"
    printf '  服务器：%s\n' "$CX_HOST"
    printf '  端口：%s\n' "$CX_PORT"
    if [ "$CX_TYPE" != snell ]; then
        printf '  传输层：%s\n' "$(_sb_type_transport "$CX_TYPE")"
    else
        printf '  传输层：TCP\n'
    fi
    if [ -n "$CX_TLSMODE" ]; then
        if [ -n "$CX_SNI" ]; then
            printf '  TLS Server Name：%s (%s)\n' "$CX_SNI" "$(_cx_sni_src_text)"
        else
            printf '  TLS Server Name：未指定 (%s)\n' "$(_cx_sni_src_text)"
        fi
        [ -z "$CX_TLS_NOTE" ] || printf '  TLS 提示：%s\n' "$CX_TLS_NOTE"
        if [ "${CX_TLSINS:-yes}" = yes ]; then
            printf '  证书：自签名 (客户端不能按公共 CA 校验, 需要 insecure 或嵌入证书, 这是当前自签名证书模式的限制)\n'
        else
            printf '  证书：由 CA 签发 (客户端按证书链与服务器名称校验, 连接地址需要是证书覆盖的域名)\n'
        fi
    fi
    [ -z "$CX_UUID" ] || printf '  UUID：%s\n' "$CX_UUID"
    [ -z "$CX_METHOD" ] || printf '  method：%s\n' "$CX_METHOD"
    [ "$CX_TYPE" != tuic ] || printf '  拥塞控制：%s\n' "${CX_CC:-未指定 (客户端默认)}"
    [ -z "$CX_MODE" ] || printf '  mode：%s\n' "$CX_MODE"
    printf '  凭据：已配置 (用 export 的 secret 操作显式查看)\n'
    if [ "$CX_ENABLED" = false ]; then
        printf '  实例状态：已禁用, 客户端暂时无法连接\n'
    fi
    case $CX_HOST in
        127.*|::1|localhost) printf '  提醒：回环地址只有本机可用\n' ;;
    esac
    if [ "$CX_POLICY" = on ]; then
        printf '  服务端提醒：该实例启用了目标访问限制, 这是服务端策略, 不属于客户端参数\n'
    fi
    printf '  说明：Public Endpoint 只记录客户端应该连接的地址, 不配置 NAT 与防火墙, 公网可达性没有验证\n'
}

# 凭据, 与连接参数分开显示, 只包含客户端认证需要的值
_cx_r_secret() {
    [ -z "$CX_UUID" ] || printf 'UUID：%s\n' "$CX_UUID"
    [ -z "$CX_METHOD" ] || printf 'method：%s\n' "$CX_METHOD"
    if [ "$CX_TYPE" = snell ]; then
        printf 'psk：%s\n' "$CX_PASS"
    else
        printf '密码：%s\n' "$CX_PASS"
    fi
}

# ---- 渲染: sing-box 客户端 JSON ----
# REDACT yes 时凭据写成 REDACTED, 方便展示与调试, EMBED yes 时嵌入服务端证书代替 insecure
_cx_r_singbox() { # REDACT EMBED
    local _pw _crt
    _pw=$CX_PASS
    [ "$1" != yes ] || _pw=REDACTED
    printf '{\n  "log": {\n    "level": "warn"\n  },\n  "inbounds": [\n    {\n      "type": "mixed",\n      "tag": "mixed-in",\n      "listen": "127.0.0.1",\n      "listen_port": 2080\n    }\n  ],\n  "outbounds": [\n    {\n'
    printf '      "type": "%s",\n      "tag": "proxy",\n      "server": "%s",\n      "server_port": %s,\n' "$CX_TYPE" "$CX_HOST" "$CX_PORT"
    case $CX_TYPE in
        anytls|hysteria2)
            printf '      "password": "%s",\n' "$_pw"
            ;;
        tuic)
            printf '      "uuid": "%s",\n      "password": "%s",\n' "$CX_UUID" "$_pw"
            [ -z "$CX_CC" ] || printf '      "congestion_control": "%s",\n' "$CX_CC"
            ;;
        shadowsocks)
            printf '      "method": "%s",\n      "password": "%s"\n' "$CX_METHOD" "$_pw"
            ;;
    esac
    if [ -n "$CX_TLSMODE" ]; then
        printf '      "tls": {\n        "enabled": true'
        [ -z "$CX_SNI" ] || printf ',\n        "server_name": "%s"' "$CX_SNI"
        if [ "$2" = yes ]; then
            if [ "${CX_TLSINS:-yes}" = no ]; then
                apm_err "$CX_ID: 证书由 CA 签发, 客户端按证书链校验, 不需要也不支持嵌入证书固定校验"
                return 1
            fi
            if [ "${CX_SANOK:-yes}" != yes ]; then
                apm_err "$CX_ID: 无法嵌入证书固定校验: ${CX_TLS_NOTE:-服务端证书没有覆盖客户端使用的 TLS 服务名, 客户端会拒绝}; 可以用 endpoint ... sni set 名称 选择证书覆盖的名称, 或明确重新生成带 SAN 的证书 (anytls-gateway cert generate --server-name 名称 或 sing-box set ID server-name 名称 这会更换证书, 需要你明确执行)"
                return 1
            fi
            _crt=$(env_path "$CX_CERT")
            if ! { [ -r "$_crt" ] && grep -q 'BEGIN CERTIFICATE' "$_crt"; }; then
                apm_err "$CX_ID: 无法读取服务端证书, 无法嵌入"
                return 1
            fi
            printf ',\n        "certificate": [\n'
            awk '/BEGIN CERTIFICATE/ { on = 1 } on { a[++n] = $0 } /END CERTIFICATE/ { exit }
                END { for (i = 1; i <= n; i++) printf "          \"%s\"%s\n", a[i], (i < n ? "," : "") }' "$_crt"
            printf '        ]'
        elif [ "${CX_TLSINS:-yes}" = yes ]; then
            printf ',\n        "insecure": true'
        fi
        printf '\n      }\n'
    fi
    printf '    }\n  ]\n}\n'
}

# ---- 渲染: 分享 URL ----
# 只实现有明确依据的格式, 返回 3 表示该协议没有可依据的通用 URI
_cx_r_url() {
    local _auth _host _name _sni _q
    _host=$(_cx_host_uri "$CX_HOST")
    _name=$(_cx_pct "$CX_ID") || return 1
    case $CX_TYPE in
        anytls|hysteria2)
            # 官方格式 scheme://auth@host:port/?sni=..&insecure=1#name, 自签名证书需要 insecure=1
            _auth=$(_cx_pct "$CX_PASS") || return 1
            # sni 与 JSON 的 server_name 来自同一个 CX_SNI, 没有 SNI 时 (证书只有 IP SAN) 不带 sni 参数
            _q=
            if [ -n "$CX_SNI" ]; then _sni=$(_cx_pct "$CX_SNI") || return 1; _q="sni=$_sni"; fi
            if [ "${CX_TLSINS:-yes}" = yes ]; then _q="${_q:+$_q&}insecure=1"; fi
            printf '%s://%s@%s:%s/%s#%s\n' "$CX_TYPE" "$_auth" "$_host" "$CX_PORT" "${_q:+?$_q}" "$_name"
            ;;
        shadowsocks)
            # SIP002: 传统 AEAD 的 userinfo 用 base64url (无填充), SIP022 (2022 方法) 必须不用 base64url, method 与密钥分别百分号编码
            case $CX_METHOD in
                2022-*) _auth=$(_cx_pct "$CX_METHOD"):$(_cx_pct "$CX_PASS") || return 1 ;;
                *) _auth=$(_cx_b64url "$CX_METHOD:$CX_PASS") ;;
            esac
            printf 'ss://%s@%s:%s#%s\n' "$_auth" "$_host" "$CX_PORT" "$_name"
            ;;
        *)
            return 3
            ;;
    esac
}

# ---- 命令: sing-box endpoint ----

_cx_inst_file() { # ID -> stdout path
    is_ident "$1" || { apm_err "实例 ID 无效: $1"; return 1; }
    [ -f "$(state_instances_dir)/$1.conf" ] || { apm_err "实例 $1 不存在"; return 1; }
    printf '%s' "$(state_instances_dir)/$1.conf"
}

singbox_endpoint() { # ID [show | set HOST PORT | clear | sni set NAME | sni clear]
    local _id _act _f _h _p _msg _tmp _sa _sv
    _id=${1:-}
    [ -n "$_id" ] || { apm_err "用法: sing-box endpoint 实例ID [show|set 主机 端口|clear|sni set 名称|sni clear]"; return 2; }
    shift
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _f=$(_cx_inst_file "$_id") || return 1
    case $_act in
        show)
            [ $# -eq 0 ] || { apm_err "show 不需要参数"; return 2; }
            [ -r "$_f" ] || { apm_err "无法读取 $_f (需要 root)"; return 1; }
            printf '实例 %s\n' "$_id"
            printf '  内部监听：%s 端口 %s (不等于客户端连接地址)\n' "$(kv_get "$_f" listen)" "$(kv_get "$_f" listen_port)"
            if ! client_endpoint_check "$_f" >/dev/null 2>&1; then
                printf '  客户端连接地址：配置无效\n'
                return 1
            fi
            if [ -z "$(kv_get "$_f" public.host)" ]; then
                printf '  客户端连接地址：未配置\n'
            else
                _h=$(_cx_host_uri "$(kv_get "$_f" public.host)")
                printf '  客户端连接地址：%s:%s\n' "$_h" "$(kv_get "$_f" public.port)"
            fi
            if [ -n "$(kv_get "$_f" public.sni)" ]; then
                printf '  客户端 TLS 服务名：%s (用户指定)\n' "$(kv_get "$_f" public.sni)"
            else
                printf '  客户端 TLS 服务名：未指定 (默认, 不填写 SNI)\n'
            fi
            printf '  说明：只记录客户端应该连接的地址, 不配置 NAT 与防火墙\n'
            return 0
            ;;
        set)
            [ $# -eq 2 ] || { apm_err "用法: sing-box endpoint $_id set 主机 端口"; return 2; }
            _msg=$(client_host_norm "$1") || { apm_err "$_msg"; return 2; }
            _h=$_msg
            is_port "$2" || { apm_err "端口无效: $2 (需要 1 到 65535)"; return 2; }
            _p=$2
            ;;
        clear)
            [ $# -eq 0 ] || { apm_err "clear 不需要参数"; return 2; }
            ;;
        sni)
            _sa=${1:-}
            [ $# -eq 0 ] || shift
            case $_sa in
                set)
                    [ $# -eq 1 ] || { apm_err "用法: sing-box endpoint $_id sni set 名称"; return 2; }
                    _sv=$(client_sni_norm "$1") || { apm_err "$_sv"; return 2; }
                    ;;
                clear) [ $# -eq 0 ] || { apm_err "sni clear 不需要参数"; return 2; } ;;
                *) apm_err "用法: sing-box endpoint $_id sni set 名称 | sni clear"; return 2 ;;
            esac
            _sb_type_tls "$(kv_get "$_f" type)" || { apm_err "$(kv_get "$_f" type) 不使用 TLS, 没有 TLS 服务名"; return 2; }
            ;;
        *) apm_err "未知的 endpoint 操作: $_act"; return 2 ;;
    esac
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed yes || return 4
    _snell_ensure_staging || return 1
    _tmp=$SNELL_STAGING/endpoint
    mkdir -p -- "$_tmp" && chmod 700 -- "$_tmp" || return 1
    cp -p -- "$_f" "$_tmp/$_id.conf" || return 1
    case $_act in
        set) _sb_inst_set "$_tmp/$_id.conf" public.host "$_h" && _sb_inst_set "$_tmp/$_id.conf" public.port "$_p" || return 1 ;;
        clear) _sb_inst_unset "$_tmp/$_id.conf" public.host && _sb_inst_unset "$_tmp/$_id.conf" public.port || return 1 ;;
        sni)
            if [ "$_sa" = set ]; then
                _sb_inst_set "$_tmp/$_id.conf" public.sni "$_sv" || return 1
            else
                _sb_inst_unset "$_tmp/$_id.conf" public.sni || return 1
            fi
            ;;
    esac
    if ! sb_instance_validate "$_tmp/$_id.conf" >/dev/null 2>&1; then
        sb_instance_validate "$_tmp/$_id.conf" 2>&1 | sed 's/^/  /' >&2
        apm_err "实例未通过校验, 没有改动"
        return 1
    fi
    if cmp -s "$_tmp/$_id.conf" "$_f"; then
        if [ "$_act" = sni ]; then printf '实例 %s 的客户端 TLS 服务名没有变化\n' "$_id"; else printf '实例 %s 的客户端连接地址没有变化\n' "$_id"; fi
        return 0
    fi
    # 只改实例文件里的 public 键, 不生成运行配置, 不重启 sing-box, 不改证书
    atomic_install "$_tmp/$_id.conf" "$_f" 600 || { apm_err "保存失败"; return 1; }
    case $_act in
        set) printf '已设置实例 %s 的客户端连接地址: %s:%s\n' "$_id" "$(_cx_host_uri "$_h")" "$_p" ;;
        clear) printf '已清除实例 %s 的客户端连接地址\n' "$_id" ;;
        sni)
            if [ "$_sa" = set ]; then
                printf '已设置实例 %s 的客户端 TLS 服务名: %s\n' "$_id" "$_sv"
                _cx_sni_cover_hint "$_f" "$_sv"
            else
                printf '已清除实例 %s 的客户端 TLS 服务名, 恢复默认 (不指定 SNI)\n' "$_id"
            fi
            ;;
    esac
    printf '没有修改运行配置与证书, sing-box 没有重启 (客户端连接地址与 TLS 服务名只用于导出)\n'
}

# 设置自定义 TLS 服务名之后提示它的含义与它和服务端证书的关系 (只读)
_cx_sni_cover_hint() { # 证书所属的实例文件 NAME
    local _crt _t
    printf '提示：这只是客户端发送的 TLS 服务名 跳过证书验证时不会验证该名称对应网站的身份 服务器也不一定持有该名称的证书 它不等于网站伪装\n'
    _t=$(kv_get "$1" type)
    _sb_type_tls "$_t" || return 0
    _crt=$(env_path "$(kv_get "$1" tls.certificate_path)")
    if _cx_cert_facts "$_crt"; then
        if _cx_san_covers "$2"; then
            printf '该名称被服务端证书的 DNS SAN 覆盖, 嵌入证书固定校验可以使用\n'
        else
            printf '该名称没有被服务端证书覆盖: 嵌入证书固定校验与正常证书验证需要匹配的名称 此时不可用 (证书里的名称: %s)\n' "${CX_SAN_DNS:-${CX_CERT_CN:-无}}"
        fi
    fi
}

# ---- 命令: sing-box export ----

singbox_export() { # ID show | secret | sing-box [--redacted] [--embed-cert] | url | qr
    local _id _act _f _red _emb _url _qr _rc
    _id=${1:-}
    [ -n "$_id" ] || { apm_err "用法: sing-box export 实例ID show|secret|sing-box [--redacted] [--embed-cert]|url|qr"; return 2; }
    shift
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _red=no
    _emb=no
    case $_act in
        sing-box)
            while [ $# -gt 0 ]; do
                case $1 in
                    --redacted) _red=yes ;;
                    --embed-cert) _emb=yes ;;
                    *) apm_err "未知参数: $1"; return 2 ;;
                esac
                shift
            done
            ;;
        show|secret|url|qr) [ $# -eq 0 ] || { apm_err "$_act 不需要参数"; return 2; } ;;
        *) apm_err "未知的 export 操作: $_act"; return 2 ;;
    esac
    _f=$(_cx_inst_file "$_id") || return 1
    CX_PIN=no
    [ "$_act" != sing-box ] || CX_PIN=$_emb
    case $_act in
        secret)
            _cx_load_sb_creds "$_f" || return 1
            _cx_warn_secret
            _cx_r_secret
            ;;
        show)
            if ! _cx_load_sb_creds "$_f"; then return 1; fi
            _cx_need_endpoint "$_f" "$_id" || return 1
            _cx_tls_resolve || return $?
            _cx_r_show
            ;;
        sing-box)
            _cx_load_sb "$_f" || return $?
            # 先完整生成再输出, 失败时不留下半份配置
            _url=$(_cx_r_singbox "$_red" "$_emb") || return 1
            [ "$_red" = yes ] || _cx_warn_secret
            printf '%s\n' "$_url"
            ;;
        url|qr)
            _cx_load_sb "$_f" || return $?
            _url=$(_cx_r_url)
            _rc=$?
            if [ "$_rc" -ne 0 ]; then
                apm_err "$(_cx_label "$CX_TYPE") 没有稳定的通用分享 URI, 不提供 URL 与二维码 (sing-box 客户端 JSON 可用: export $_id sing-box)"
                return 3
            fi
            if [ "$_act" = url ]; then
                _cx_warn_secret
                printf '%s\n' "$_url"
                return 0
            fi
            client_qr_ensure "export $_id url" || return 5
            _qr=$CX_QR_BIN
            _cx_warn_secret
            # URL 通过 stdin 传给 qrencode, 不进入进程参数
            printf '%s' "$_url" | "$_qr" -t UTF8 -m 1
            ;;
    esac
}

# ---- 按需依赖: 二维码工具与 openssl 共用同一套安装流程 ----
# 只在用户进入需要它的功能而且命令缺失时才安装, 其他任何入口都不安装, 启动时也不安装
#   qrencode 由 libqrencode-tools 提供, 只在 qr 入口需要
#   openssl 只在嵌入证书固定校验 (以及 Gateway 判断证书类型) 需要, 默认的 sing-box 客户端配置导出不需要
# 只用 apk 和系统已配置的软件源, 不改软件源, 不下载脚本, 不用 curl 管道, apk 输出只用于分类失败原因, 不写日志
# 失败返回 5 并说明原因, 不卡死 (有超时), 也不悄悄降级成别的配置
CX_DEP_BIN=
CX_DEP_WHY=
CX_DEP_PKG=
CX_QR_PKG=libqrencode-tools
CX_QR_BIN=

# 根据 apk 的输出与退出码给出失败原因分类到 CX_DEP_WHY
_cx_apk_classify() { # 退出码 输出
    case $1 in 124|137|143) CX_DEP_WHY=timeout; return 0 ;; esac
    if printf '%s' "$2" | grep -Eqi 'permission denied|operation not permitted|are you root|read-only file system'; then CX_DEP_WHY=perm
    elif printf '%s' "$2" | grep -Eqi 'unable to lock|lock database|resource temporarily unavailable'; then CX_DEP_WHY=lock
    elif printf '%s' "$2" | grep -Eqi 'temporary error|could not resolve|dns|bad address|network|unable to fetch|connection (refused|timed out|reset)|no route|tls|ssl|timed out'; then CX_DEP_WHY=network
    elif printf '%s' "$2" | grep -Eqi 'untrusted|signature'; then CX_DEP_WHY=sig
    elif printf '%s' "$2" | grep -Eqi 'no such package|unable to select packages|not found'; then CX_DEP_WHY=nopkg
    else CX_DEP_WHY=other; fi
}

_cx_dep_why_text() { # 分类
    case $1 in
        timeout) printf '安装超过 %s 秒没有完成, 已中止 (网络很慢或软件源无响应)' "${APM_DEP_INSTALL_TIMEOUT:-${APM_QR_INSTALL_TIMEOUT:-120}}" ;;
        perm) printf '没有写入软件包数据库的权限 (需要 root)' ;;
        lock) printf 'apk 正被其他进程占用, 请稍后重试' ;;
        network) printf '无法访问 Alpine 软件源 (网络或 DNS 不可用)' ;;
        sig) printf '软件源签名校验失败 (本工具不会修改软件源或信任设置)' ;;
        nopkg) printf '当前软件源里没有找到 %s' "$CX_DEP_PKG" ;;
        *) printf 'apk 返回了未分类的错误' ;;
    esac
}

# 成功时 CX_DEP_BIN 是可执行的命令路径; 失败输出原因并返回 5
client_dep_ensure() { # 命令 包名 检测名称 成功名称 验证参数 失败后的替代说明
    local _cmd _pkg _det _okn _vfy _alt _apk _out _rc _tmo _last
    _cmd=$1; _pkg=$2; _det=$3; _okn=$4; _vfy=$5; _alt=$6
    CX_DEP_PKG=$_pkg
    _tmo=${APM_DEP_INSTALL_TIMEOUT:-${APM_QR_INSTALL_TIMEOUT:-120}}
    CX_DEP_BIN=$(_snell_tool "$_cmd" 2>/dev/null) || CX_DEP_BIN=
    if [ -n "$CX_DEP_BIN" ]; then return 0; fi
    printf '检测%s...\n未安装 %s，正在安装所需依赖 (%s)...\n' "$_det" "$_cmd" "$_pkg" >&2
    if ! env_is_root; then
        apm_err "自动安装需要 root 权限, 当前不是 root; 请以 root 运行, 或自行执行 apk add $_pkg; $_alt"
        return 5
    fi
    _apk=$(_snell_tool apk 2>/dev/null) || _apk=
    if [ -z "$_apk" ]; then
        apm_err "没有找到 apk, 无法自动安装 $_pkg (本功能只支持 Alpine); $_alt"
        return 5
    fi
    _out=$(_client_timeout "$_tmo" "$_apk" add --no-cache "$_pkg" 2>&1 </dev/null)
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _cx_apk_classify "$_rc" "$_out"
        if [ "$CX_DEP_WHY" = nopkg ]; then
            # 包名随 Alpine 版本可能变化: 按命令提供者再试一次, 仍然是系统已配置的软件源
            _out=$(_client_timeout "$_tmo" "$_apk" add --no-cache "cmd:$_cmd" 2>&1 </dev/null)
            _rc=$?
            [ "$_rc" -eq 0 ] || _cx_apk_classify "$_rc" "$_out"
        fi
    fi
    if [ "$_rc" -ne 0 ]; then
        _last=$(printf '%s\n' "$_out" | sed '/^[[:space:]]*$/d' | tail -n 1 | cut -c1-160)
        apm_err "${_okn}安装失败: $(_cx_dep_why_text "$CX_DEP_WHY")${_last:+ (apk: $_last)}; $_alt"
        return 5
    fi
    CX_DEP_BIN=$(_snell_tool "$_cmd" 2>/dev/null) || CX_DEP_BIN=
    # shellcheck disable=SC2086 # 验证参数是固定的短选项
    if [ -z "$CX_DEP_BIN" ] || ! "$CX_DEP_BIN" $_vfy >/dev/null 2>&1; then
        apm_err "$_pkg 已安装但找不到可以运行的 $_cmd; $_alt"
        return 5
    fi
    printf '✓ %s安装成功\n' "$_okn" >&2
    return 0
}

# 二维码: 成功时 CX_QR_BIN 是可执行的 qrencode 路径, 失败时分享 URL 导出仍然可用
client_qr_ensure() { # URL 导出命令的提示 (只是命令名, 不含任何凭据)
    client_dep_ensure qrencode "$CX_QR_PKG" 二维码生成工具 二维码工具 -V "分享链接仍可用: $1" || return $?
    CX_QR_BIN=$CX_DEP_BIN
}

# openssl: 嵌入证书固定校验要读证书里的名称 失败时不会降级成跳过证书验证的配置
client_openssl_ensure() { # 失败后的替代说明
    client_dep_ensure openssl openssl 证书解析工具 openssl version "$1"
}

# ---- 服务器公网 IP 展示 ----
# 只用于展示 Snell 的连接信息, 与 Public Endpoint 配置模型无关: 不写入任何配置, 不判断 NAT 映射, 不验证公网可达性
# 数据来源是第三方 HTTPS 服务返回的出口 IPv4, 仅在用户选择查看连接信息时按需查询, 失败时降级为 获取失败
CLIENT_IP_URLS="https://api.ipify.org https://ipv4.icanhazip.com"

# 严格的公网 IPv4: 四段十进制, 无前导零, 并排除 0/8 10/8 100.64/10 127/8 169.254/16 172.16/12 192.168/16 以及 224 以上的组播与保留段
client_valid_public_ipv4() {
    local _a _b
    printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    _sb_valid_ipv4_dest "$1" || return 1
    _a=${1%%.*}
    _b=${1#*.}
    _b=${_b%%.*}
    case $_a in 0|10|127) return 1 ;; esac
    [ "$_a" -lt 224 ] || return 1
    case $_a.$_b in 169.254|192.168) return 1 ;; esac
    if [ "$_a" = 172 ] && [ "$_b" -ge 16 ] && [ "$_b" -le 31 ]; then return 1; fi
    if [ "$_a" = 100 ] && [ "$_b" -ge 64 ] && [ "$_b" -le 127 ]; then return 1; fi
    return 0
}

_client_timeout() { # 秒数 命令...
    local _s
    _s=$1
    shift
    if command -v timeout >/dev/null 2>&1; then timeout "$_s" "$@"; else "$@"; fi
}

CLIENT_IP6_URLS="https://api6.ipify.org https://ipv6.icanhazip.com"

# 严格的公网 IPv6: 合法的 IPv6 文本, 且属于全局单播 2000::/3, 排除文档用途的 2001:db8::/32
# 回环 ::1, 未指定 ::, 链路本地 fe80::/10, 唯一本地 fc00::/7, 组播 ff00::/8, IPv4 映射等都不在 2000::/3 内, 一律拒绝
client_valid_public_ipv6() {
    local _h _g
    _h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $_h in *:*) ;; *) return 1 ;; esac
    _sb_valid_ipv6_dest "$_h" || return 1
    _g=${_h%%:*}
    case $_g in
        2???|3???) ;;
        *) return 1 ;;
    esac
    case $_h in 2001:db8:*|2001:0db8:*) return 1 ;; esac
    return 0
}

# 依次尝试每个服务, 每个有短超时, 响应只取前 64 字节的第一行, 经校验函数严格验证才接受
# 下载器沿用 APM_DOWNLOADER (默认 BusyBox wget), 测试用它替换成 mock, 不依赖第三方服务
_client_fetch_ip() { # 校验函数 URL列表
    local _dl _u _t _r
    _dl=${APM_DOWNLOADER:-wget}
    command -v "$_dl" >/dev/null 2>&1 || return 1
    _t=${APM_IP_TIMEOUT:-4}
    for _u in $2; do
        _r=$(_client_timeout "$_t" "$_dl" -q -T "$_t" -O - "$_u" 2>/dev/null | head -c 64 | head -n 1 | tr -d '\r \t')
        if "$1" "$_r"; then
            printf '%s' "$_r"
            return 0
        fi
    done
    return 1
}

# 输出公网 IPv4 并返回 0, 失败返回 1
client_public_ip() {
    _client_fetch_ip client_valid_public_ipv4 "$CLIENT_IP_URLS"
}

# 自动选择: 先 IPv4 (保持原有行为), 取不到再试 IPv6, 两者都失败返回 1
# 只读查询: 不写任何配置, 不修改网卡 路由 防火墙. 结果只是服务器出口地址, 不保证等于客户端可达的地址 (NAT 与端口映射)
client_public_ip_auto() {
    client_public_ip && return 0
    _client_fetch_ip client_valid_public_ipv6 "$CLIENT_IP6_URLS"
}

# ---- Snell: Core 级 Public Endpoint 与导出 ----

_cx_snell_ep_file() { printf '%s/snell-endpoint.conf' "$(state_etc)"; }

# 读取 Snell 的客户端事实, 配置来自 Core 配置文件, 端点来自独立的元数据文件
_cx_load_snell_creds() {
    local _c _l
    _c=$(env_path "$SNELL_CONF")
    [ -f "$_c" ] || { apm_err "没有找到 Snell 配置 $SNELL_CONF"; return 1; }
    [ -r "$_c" ] || { apm_err "无法读取 $SNELL_CONF (需要 root)"; return 1; }
    snell_validate_config "$_c" || { apm_err "Snell 配置无效, 拒绝导出"; return 1; }
    CX_ID=snell
    CX_TYPE=snell
    CX_PASS=$(sed -n 's/^[[:space:]]*psk[[:space:]]*=[[:space:]]*//p' "$_c" | head -n 1 | sed 's/[[:space:]]*$//')
    CX_MODE=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p' "$_c" | head -n 1 | sed 's/[[:space:]]*$//')
    _l=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$_c" | head -n 1 | sed 's/[[:space:]]*$//')
    CX_LISTEN=$_l
    CX_LPORT=
    CX_SNI=
    CX_UUID=
    CX_METHOD=
    CX_CC=
    CX_POLICY=off
    core_discover snell
    [ "$CF_STATE" = running ] || CX_ENABLED=false
    return 0
}

_cx_snell_need_endpoint() {
    local _e
    _e=$(_cx_snell_ep_file)
    if [ ! -f "$_e" ]; then
        apm_err "Snell 尚未配置客户端连接地址, 请先执行 snell endpoint set 主机 端口 (内部监听 ${CX_LISTEN:-?} 不等于客户端连接地址)"
        return 1
    fi
    client_endpoint_check "$_e" || return 1
    CX_HOST=$(kv_get "$_e" public.host)
    CX_PORT=$(kv_get "$_e" public.port)
    [ -n "$CX_HOST" ] || { apm_err "客户端连接地址文件无效"; return 1; }
}

snell_endpoint() { # [show | set HOST PORT | clear]
    local _act _e _h _p _msg _c
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _e=$(_cx_snell_ep_file)
    case $_act in
        show)
            [ $# -eq 0 ] || { apm_err "show 不需要参数"; return 2; }
            printf 'Snell\n'
            _c=$(env_path "$SNELL_CONF")
            if [ -r "$_c" ]; then
                printf '  内部监听：%s (不等于客户端连接地址)\n' "$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$_c" | head -n 1 | sed 's/[[:space:]]*$//')"
            fi
            if [ ! -f "$_e" ]; then
                printf '  客户端连接地址：未配置\n'
            elif ! client_endpoint_check "$_e" >/dev/null 2>&1; then
                printf '  客户端连接地址：配置无效\n'
                return 1
            else
                printf '  客户端连接地址：%s:%s\n' "$(_cx_host_uri "$(kv_get "$_e" public.host)")" "$(kv_get "$_e" public.port)"
            fi
            printf '  说明：只记录客户端应该连接的地址, 不配置 NAT 与防火墙\n'
            return 0
            ;;
        set)
            [ $# -eq 2 ] || { apm_err "用法: snell endpoint set 主机 端口"; return 2; }
            _msg=$(client_host_norm "$1") || { apm_err "$_msg"; return 2; }
            _h=$_msg
            is_port "$2" || { apm_err "端口无效: $2 (需要 1 到 65535)"; return 2; }
            _p=$2
            ;;
        clear) [ $# -eq 0 ] || { apm_err "clear 不需要参数"; return 2; } ;;
        *) apm_err "未知的 endpoint 操作: $_act"; return 2 ;;
    esac
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed || return 4
    state_ensure_dirs || return 1
    if [ "$_act" = clear ]; then
        if [ ! -f "$_e" ]; then
            printf 'Snell 没有客户端连接地址, 没有改动\n'
            return 0
        fi
        rm -f -- "$_e"
        printf '已清除 Snell 的客户端连接地址\n'
    else
        _snell_ensure_staging || return 1
        printf 'public.host=%s\npublic.port=%s\n' "$_h" "$_p" > "$SNELL_STAGING/ep" || return 1
        atomic_install "$SNELL_STAGING/ep" "$_e" 600 || { apm_err "保存失败"; return 1; }
        printf '已设置 Snell 的客户端连接地址: %s:%s\n' "$(_cx_host_uri "$_h")" "$_p"
    fi
    printf '没有修改 Snell 配置, Snell 没有重启 (客户端连接地址只用于导出)\n'
}

snell_export() { # show | secret | info
    local _act _ip
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    [ $# -eq 0 ] || { apm_err "$_act 不需要参数"; return 2; }
    case $_act in
        secret)
            _cx_load_snell_creds || return 1
            _cx_warn_secret
            _cx_r_secret
            ;;
        show)
            _cx_load_snell_creds || return 1
            _cx_snell_need_endpoint || return 1
            _cx_r_show
            printf '  Snell 客户端协议版本：由客户端按服务端版本选择 (没有确认的对应关系, 不在这里猜测)\n'
            ;;
        info)
            # 不依赖 Public Endpoint: 公网 IP 按需查询, 端口与版本来自 Snell 现有配置与发现事实, 只读, 不写任何文件, 不重启
            _cx_load_snell_creds || return 1
            _ip=$(client_public_ip_auto) || _ip=
            printf 'Snell 连接信息\n'
            printf '公网 IP：%s\n' "${_ip:-获取失败}"
            printf '监听端口：%s\n' "$(_snell_ports_of "$CX_LISTEN" | sed 's/ /, /g')"
            printf 'Snell 版本：%s\n' "${CF_VERSION_REPORTED:-未知}"
            printf 'PSK：已配置\n'
            ;;
        sing-box|url|qr)
            apm_err "Snell 没有 sing-box 出站, 也没有稳定的通用分享 URI, 只提供 export info show secret"
            return 3
            ;;
        *) apm_err "未知的 export 操作: $_act"; return 2 ;;
    esac
}

# ---- AnyTLS Gateway: 每条转发线路是一个客户端入口 ----
# 事实来源: 转发线路记录 (监听端口 AnyTLS 密码) 与网关当前使用的证书 (名称 自签名与否 SAN)
# 绝不使用该线路的 SOCKS5 上游地址 与 sing-box 实例的任何数据
# 客户端连接地址 (public.host public.port) 按线路单独保存在 anytlsgw-endpoint-线路ID.conf, 不进入网关配置与 config.json

_cx_agw_ep_file() { printf '%s/anytlsgw-endpoint-%s.conf' "$(state_etc)" "$1"; }

# 读取并校验一条转发线路的客户端事实, 缺失或无效就失败, 不猜测不使用默认
_cx_load_agw_creds() { # ID或端口
    local _f _id _l
    _f=$(_agw_state)
    [ -r "$_f" ] || { apm_err "无法读取转发线路记录 (需要 root)"; return 1; }
    kv_check_syntax "$_f" || { apm_err "转发线路记录无效, 拒绝导出"; return 1; }
    _id=$(_agw_find_id "$1") || { apm_err "没有这条转发线路: $1"; return 2; }
    _l=$(_agw_get "$_f" "$_id" listen)
    _agw_listen_ok "$_l" || { apm_err "转发线路 $_id 的监听地址无效, 拒绝导出"; return 1; }
    CX_REF=$_id
    CX_ID="AnyTLS-Gateway-$_id"
    CX_TYPE=anytls
    CX_ENABLED=true
    CX_LISTEN=${_l%:*}
    CX_LPORT=${_l##*:}
    CX_PASS=$(_agw_get "$_f" "$_id" password)
    _agw_pw_ok "$CX_PASS" || { apm_err "转发线路 $_id 的 AnyTLS 密码无效, 拒绝导出"; return 1; }
    CX_UUID=; CX_METHOD=; CX_CC=; CX_MODE=
    CX_POLICY=off
    CX_EGRESS=socks
    CX_TLSMODE=self-signed
    CX_CERT=$AGW_CERT
    CX_TLSINS=yes
    CX_SANOK=yes
    [ -r "$(env_path "$AGW_CERT")" ] || { apm_err "无法读取网关证书 $AGW_CERT (需要 root), 拒绝导出"; return 1; }
    client_openssl_ensure "需要 openssl 读取网关证书并判断它是自签名还是 CA 签发, 没有可替代的导出方式" || return 5
    _cx_cert_facts "$(env_path "$AGW_CERT")" || { apm_err "无法解析网关证书, 拒绝导出"; return 1; }
    CX_SNI=
    CX_SNI_SRC=
    CX_SNI_STORED=
    CX_SNI_OVR=
    CX_TLS_NOTE=
    if [ "$CX_CERT_SELF" = no ]; then
        CX_TLSINS=no
        CX_TLSMODE=ca
    fi
    return 0
}

_cx_agw_need_endpoint() { # ID
    local _e
    _e=$(_cx_agw_ep_file "$1")
    if [ ! -f "$_e" ]; then
        apm_err "转发线路 $1 尚未配置客户端连接地址, 请先执行 anytls-gateway endpoint $1 set 主机 端口 (内部监听 ${CX_LISTEN:-?}:${CX_LPORT:-?} 不等于客户端连接地址, SOCKS5 上游也不是)"
        return 1
    fi
    client_endpoint_check "$_e" || return 1
    CX_HOST=$(kv_get "$_e" public.host)
    CX_PORT=$(kv_get "$_e" public.port)
    if [ -z "$CX_HOST" ]; then
        apm_err "转发线路 $1 尚未配置客户端连接地址, 请先执行 anytls-gateway endpoint $1 set 主机 端口"
        return 1
    fi
    CX_SNI_OVR=$(kv_get "$_e" public.sni)
    _cx_tls_resolve
}

agw_endpoint() { # ID或端口 [show | set HOST PORT | clear | sni set NAME | sni clear]
    local _ref _id _act _e _h _p _msg _f _sa _sv _h0 _p0 _s0
    _ref=${1:-}
    [ -n "$_ref" ] || { apm_err "用法: anytls-gateway endpoint ID或端口 [show|set 主机 端口|clear|sni set 名称|sni clear]"; return 2; }
    shift
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _f=$(_agw_state)
    [ -r "$_f" ] || { apm_err "无法读取转发线路记录 (需要 root)"; return 1; }
    _id=$(_agw_find_id "$_ref") || { apm_err "没有这条转发线路: $_ref"; return 2; }
    _e=$(_cx_agw_ep_file "$_id")
    case $_act in
        show)
            [ $# -eq 0 ] || { apm_err "show 不需要参数"; return 2; }
            printf '转发线路 %s\n' "$_id"
            printf '  内部监听：%s (不等于客户端连接地址)\n' "$(_agw_get "$_f" "$_id" listen)"
            if [ ! -f "$_e" ]; then
                printf '  客户端连接地址：未配置\n'
            elif ! client_endpoint_check "$_e" >/dev/null 2>&1; then
                printf '  客户端连接地址：配置无效\n'
                return 1
            elif [ -z "$(kv_get "$_e" public.host)" ]; then
                printf '  客户端连接地址：未配置\n'
            else
                printf '  客户端连接地址：%s:%s\n' "$(_cx_host_uri "$(kv_get "$_e" public.host)")" "$(kv_get "$_e" public.port)"
            fi
            if [ -f "$_e" ] && [ -n "$(kv_get "$_e" public.sni)" ]; then
                printf '  客户端 TLS 服务名：%s (用户指定)\n' "$(kv_get "$_e" public.sni)"
            else
                printf '  客户端 TLS 服务名：未指定 (默认, 不填写 SNI)\n'
            fi
            printf '  说明：只记录客户端应该连接的地址, 不配置 NAT 与防火墙\n'
            return 0
            ;;
        set)
            [ $# -eq 2 ] || { apm_err "用法: anytls-gateway endpoint $_ref set 主机 端口"; return 2; }
            _msg=$(client_host_norm "$1") || { apm_err "$_msg"; return 2; }
            _h=$_msg
            is_port "$2" || { apm_err "端口无效: $2 (需要 1 到 65535)"; return 2; }
            _p=$2
            ;;
        clear) [ $# -eq 0 ] || { apm_err "clear 不需要参数"; return 2; } ;;
        sni)
            _sa=${1:-}
            [ $# -eq 0 ] || shift
            case $_sa in
                set)
                    [ $# -eq 1 ] || { apm_err "用法: anytls-gateway endpoint $_ref sni set 名称"; return 2; }
                    _sv=$(client_sni_norm "$1") || { apm_err "$_sv"; return 2; }
                    ;;
                clear) [ $# -eq 0 ] || { apm_err "sni clear 不需要参数"; return 2; } ;;
                *) apm_err "用法: anytls-gateway endpoint $_ref sni set 名称 | sni clear"; return 2 ;;
            esac
            ;;
        *) apm_err "未知的 endpoint 操作: $_act"; return 2 ;;
    esac
    _agw_begin no || return $?
    state_ensure_dirs || return 1
    _snell_ensure_staging || return 1
    # 文件里只有 public.host public.port public.sni 三个键: 先取出现有值, 改其中一部分, 全空就删除文件
    _h0=; _p0=; _s0=
    if [ -f "$_e" ]; then
        client_endpoint_check "$_e" || return 1
        _h0=$(kv_get "$_e" public.host); _p0=$(kv_get "$_e" public.port); _s0=$(kv_get "$_e" public.sni)
    fi
    case $_act in
        set) _h0=$_h; _p0=$_p ;;
        clear) _h0=; _p0= ;;
        sni) if [ "$_sa" = set ]; then _s0=$_sv; else _s0=; fi ;;
    esac
    if [ -z "$_h0" ] && [ -z "$_s0" ]; then
        if [ ! -f "$_e" ]; then
            printf '转发线路 %s 没有客户端连接设置, 没有改动\n' "$_id"
            return 0
        fi
        rm -f -- "$_e"
    else
        { [ -z "$_h0" ] || printf 'public.host=%s\npublic.port=%s\n' "$_h0" "$_p0"; [ -z "$_s0" ] || printf 'public.sni=%s\n' "$_s0"; } > "$SNELL_STAGING/ep" || return 1
        if [ -f "$_e" ] && cmp -s "$SNELL_STAGING/ep" "$_e"; then
            printf '转发线路 %s 的客户端连接设置没有变化\n' "$_id"
            return 0
        fi
        atomic_install "$SNELL_STAGING/ep" "$_e" 600 || { apm_err "保存失败"; return 1; }
    fi
    case $_act in
        set) printf '已设置转发线路 %s 的客户端连接地址: %s:%s\n' "$_id" "$(_cx_host_uri "$_h")" "$_p" ;;
        clear) printf '已清除转发线路 %s 的客户端连接地址\n' "$_id" ;;
        sni)
            if [ "$_sa" = set ]; then
                printf '已设置转发线路 %s 的客户端 TLS 服务名: %s\n' "$_id" "$_sv"
                printf '提示：这只是客户端发送的 TLS 服务名 跳过证书验证时不会验证该名称对应网站的身份 服务器也不一定持有该名称的证书 它不等于网站伪装\n'
                if _cx_cert_facts "$(env_path "$AGW_CERT")"; then
                    if _cx_san_covers "$_sv"; then
                        printf '该名称被网关证书的 DNS SAN 覆盖, 嵌入证书固定校验可以使用\n'
                    else
                        printf '该名称没有被网关证书覆盖: 嵌入证书固定校验与正常证书验证需要匹配的名称 此时不可用 (证书里的名称: %s)\n' "${CX_SAN_DNS:-${CX_CERT_CN:-无}}"
                    fi
                fi
            else
                printf '已清除转发线路 %s 的客户端 TLS 服务名, 恢复默认 (不指定 SNI)\n' "$_id"
            fi
            ;;
    esac
    printf '没有修改网关配置与证书, AnyTLS Gateway 没有重启 (客户端连接地址与 TLS 服务名只用于导出)\n'
}

# anytls-gateway client ID或端口 show | secret | sing-box [--redacted] [--embed-cert] | url | qr
agw_client() {
    local _ref _act _red _emb _url _qr _rc
    _ref=${1:-}
    [ -n "$_ref" ] || { apm_err "用法: anytls-gateway client ID或端口 show|secret|sing-box [--redacted] [--embed-cert]|url|qr"; return 2; }
    shift
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _red=no
    _emb=no
    case $_act in
        sing-box)
            while [ $# -gt 0 ]; do
                case $1 in
                    --redacted) _red=yes ;;
                    --embed-cert) _emb=yes ;;
                    *) apm_err "未知参数: $1"; return 2 ;;
                esac
                shift
            done
            ;;
        show|secret|url|qr) [ $# -eq 0 ] || { apm_err "$_act 不需要参数"; return 2; } ;;
        *) apm_err "未知的 client 操作: $_act"; return 2 ;;
    esac
    CX_PIN=no
    [ "$_act" != sing-box ] || CX_PIN=$_emb
    _cx_load_agw_creds "$_ref" || return $?
    case $_act in
        secret)
            _cx_warn_secret
            _cx_r_secret
            ;;
        show)
            _cx_agw_need_endpoint "$CX_REF" || return $?
            _cx_r_show
            ;;
        sing-box)
            _cx_agw_need_endpoint "$CX_REF" || return $?
            _url=$(_cx_r_singbox "$_red" "$_emb") || return 1
            [ "$_red" = yes ] || _cx_warn_secret
            printf '%s\n' "$_url"
            ;;
        url|qr)
            _cx_agw_need_endpoint "$CX_REF" || return $?
            _url=$(_cx_r_url) || { apm_err "生成分享 URL 失败"; return 1; }
            if [ "$_act" = url ]; then
                _cx_warn_secret
                printf '%s\n' "$_url"
                return 0
            fi
            client_qr_ensure "client $_ref url" || return 5
            _qr=$CX_QR_BIN
            _cx_warn_secret
            printf '%s' "$_url" | "$_qr" -t UTF8 -m 1
            _rc=$?
            return "$_rc"
            ;;
    esac
}
