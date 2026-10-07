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
client_endpoint_check() { # FILE
    local _h _p _n
    _h=$(kv_get "$1" public.host)
    _p=$(kv_get "$1" public.port)
    if [ -z "$_h" ] && [ -z "$_p" ]; then
        kv_keys "$1" | grep -q '^public\.' && { apm_err "$1: public.host 与 public.port 不能为空"; return 1; }
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
    CX_TLSMODE=
    CX_CERT=
    case $CX_TYPE in
        tuic) CX_UUID=$(kv_get "$_f" credential.uuid); CX_CC=$(kv_get "$_f" transport.congestion_control) ;;
        shadowsocks) CX_METHOD=$(kv_get "$_f" credential.method) ;;
    esac
    if _sb_type_tls "$CX_TYPE"; then
        CX_SNI=$(kv_get "$_f" tls.server_name)
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
    _cx_need_endpoint "$1" "$CX_ID"
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
    if [ -n "$CX_SNI" ]; then
        printf '  TLS Server Name：%s\n' "$CX_SNI"
        printf '  证书：自签名 (客户端不能按公共 CA 校验, 需要 insecure 或嵌入证书, 这是当前自签名证书模式的限制)\n'
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
    if [ -n "$CX_SNI" ]; then
        printf '      "tls": {\n        "enabled": true,\n        "server_name": "%s",\n' "$CX_SNI"
        if [ "$2" = yes ]; then
            _crt=$(env_path "$CX_CERT")
            if ! { [ -r "$_crt" ] && grep -q 'BEGIN CERTIFICATE' "$_crt"; }; then
                apm_err "$CX_ID: 无法读取服务端证书, 无法嵌入"
                return 1
            fi
            printf '        "certificate": [\n'
            awk '/BEGIN CERTIFICATE/ { on = 1 } on { a[++n] = $0 } /END CERTIFICATE/ { exit }
                END { for (i = 1; i <= n; i++) printf "          \"%s\"%s\n", a[i], (i < n ? "," : "") }' "$_crt"
            printf '        ]\n      }\n'
        else
            printf '        "insecure": true\n      }\n'
        fi
    fi
    printf '    }\n  ]\n}\n'
}

# ---- 渲染: 分享 URL ----
# 只实现有明确依据的格式, 返回 3 表示该协议没有可依据的通用 URI
_cx_r_url() {
    local _auth _host _name _sni
    _host=$(_cx_host_uri "$CX_HOST")
    _name=$(_cx_pct "$CX_ID") || return 1
    case $CX_TYPE in
        anytls|hysteria2)
            # 官方格式 scheme://auth@host:port/?sni=..&insecure=1#name, 自签名证书需要 insecure=1
            _auth=$(_cx_pct "$CX_PASS") || return 1
            _sni=$(_cx_pct "$CX_SNI") || return 1
            printf '%s://%s@%s:%s/?sni=%s&insecure=1#%s\n' "$CX_TYPE" "$_auth" "$_host" "$CX_PORT" "$_sni" "$_name"
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

singbox_endpoint() { # ID [show | set HOST PORT | clear]
    local _id _act _f _h _p _msg _tmp
    _id=${1:-}
    [ -n "$_id" ] || { apm_err "用法: sing-box endpoint 实例ID [show|set 主机 端口|clear]"; return 2; }
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
    if [ "$_act" = set ]; then
        _sb_inst_set "$_tmp/$_id.conf" public.host "$_h" && _sb_inst_set "$_tmp/$_id.conf" public.port "$_p" || return 1
    else
        _sb_inst_unset "$_tmp/$_id.conf" public. || return 1
    fi
    if ! sb_instance_validate "$_tmp/$_id.conf" >/dev/null 2>&1; then
        sb_instance_validate "$_tmp/$_id.conf" 2>&1 | sed 's/^/  /' >&2
        apm_err "实例未通过校验, 没有改动"
        return 1
    fi
    if cmp -s "$_tmp/$_id.conf" "$_f"; then
        printf '实例 %s 的客户端连接地址没有变化\n' "$_id"
        return 0
    fi
    # 只改实例文件里的 public 键, 不生成运行配置, 不重启 sing-box
    atomic_install "$_tmp/$_id.conf" "$_f" 600 || { apm_err "保存失败"; return 1; }
    if [ "$_act" = set ]; then
        printf '已设置实例 %s 的客户端连接地址: %s:%s\n' "$_id" "$(_cx_host_uri "$_h")" "$_p"
    else
        printf '已清除实例 %s 的客户端连接地址\n' "$_id"
    fi
    printf '没有修改运行配置, sing-box 没有重启 (客户端连接地址只用于导出)\n'
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
    case $_act in
        secret)
            _cx_load_sb_creds "$_f" || return 1
            _cx_warn_secret
            _cx_r_secret
            ;;
        show)
            if ! _cx_load_sb_creds "$_f"; then return 1; fi
            _cx_need_endpoint "$_f" "$_id" || return 1
            _cx_r_show
            ;;
        sing-box)
            _cx_load_sb "$_f" || return 1
            # 先完整生成再输出, 失败时不留下半份配置
            _url=$(_cx_r_singbox "$_red" "$_emb") || return 1
            [ "$_red" = yes ] || _cx_warn_secret
            printf '%s\n' "$_url"
            ;;
        url|qr)
            _cx_load_sb "$_f" || return 1
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
            _qr=$(_snell_tool qrencode) || {
                apm_err "二维码是可选功能, 需要 qrencode (apk add libqrencode-tools), Manager 不会自动安装; 分享链接仍可用: export $_id url"
                return 5
            }
            _cx_warn_secret
            # URL 通过 stdin 传给 qrencode, 不进入进程参数
            printf '%s' "$_url" | "$_qr" -t UTF8 -m 1
            ;;
    esac
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

snell_export() { # show | secret
    local _act
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
        sing-box|url|qr)
            apm_err "Snell 没有 sing-box 出站, 也没有稳定的通用分享 URI, 只提供 export show 与 export secret"
            return 3
            ;;
        *) apm_err "未知的 export 操作: $_act"; return 2 ;;
    esac
}
