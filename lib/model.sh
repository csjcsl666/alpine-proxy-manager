# shellcheck shell=sh
# 数据模型: Protocol Instance 与 Server SOCKS Profile
#
# 存储格式是逐行 key=value 的纯文本, 不会被 source, 也不引入 YAML/JSON 解析器
# 空行与 # 开头的行是注释, key 只允许 [a-z0-9_.]
# 校验函数成功返回 0, 失败时在 stderr 逐条输出原因并返回 1

# ---- 通用 key=value 辅助 ----

# kv_get FILE KEY, 输出第一个匹配的值
kv_get() {
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

# 校验文件语法: 每个非注释行必须是 key=value, key 不得重复
kv_check_syntax() {
    local _bad _dup
    _bad=$(grep -Env '^[[:space:]]*(#.*)?$|^[a-z0-9_.]+=' "$1" | head -n 1)
    if [ -n "$_bad" ]; then
        apm_err "$1: 语法错误 (行 ${_bad%%:*})"
        return 1
    fi
    _dup=$(grep -E '^[a-z0-9_.]+=' "$1" | cut -d= -f1 | sort | uniq -d | head -n 1)
    if [ -n "$_dup" ]; then
        apm_err "$1: 重复的 key: $_dup"
        return 1
    fi
}

# kv_keys FILE, 输出所有 key
kv_keys() { grep -E '^[a-z0-9_.]+=' "$1" | cut -d= -f1; }

# ---- 值校验 ----

is_uint() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
}

is_port() {
    is_uint "$1" || return 1
    [ ${#1} -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_bool() { case $1 in true|false) return 0 ;; *) return 1 ;; esac; }

# 实例 id 与 SOCKS Profile 名: 字母数字开头, 其后字母数字 _ -
is_ident() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$'
}

is_ipv4() {
    local _ifs _o
    printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    _ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086
    set -- $1
    IFS=$_ifs
    for _o in "$@"; do
        [ "$_o" -le 255 ] || return 1
    done
}

# 主机: IPv4, 方括号 IPv6 或主机名
is_host() {
    case $1 in
        '') return 1 ;;
        \[*\]) printf '%s' "$1" | grep -Eq '^\[[0-9A-Fa-f:.]+\]$' ;;
        *)
            if printf '%s' "$1" | grep -Eq '^[0-9.]+$'; then
                is_ipv4 "$1"
            else
                printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
            fi
            ;;
    esac
}

# 监听地址: ::, 0.0.0.0, IPv4 或不带方括号的 IPv6
is_listen_addr() {
    case $1 in
        '') return 1 ;;
        *:*) printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:.]+$' ;;
        *) is_ipv4 "$1" ;;
    esac
}

# 显示名: 非空, 不含控制字符
is_display_name() {
    [ -n "$1" ] || return 1
    ! printf '%s' "$1" | grep -q '[[:cntrl:]]'
}

# ---- Protocol Instance ----
#
# 文件: <instances>/<id>.conf
#   id, name, type, enabled, listen, listen_port    必填
#   egress_socks   可选, 明确绑定的 SOCKS Profile 名, 为空表示 Direct
#   credential.*   凭据, 由具体协议决定键名
#   tls.*          TLS 参数
#   transport.*    传输层参数
#   relay_access.* 目标访问限制, 见 policy.sh
# 未列出的前缀一律拒绝, 避免拼写错误被静默忽略

INSTANCE_TYPES="snell anytls hysteria2 tuic shadowsocks"

instance_valid_type() {
    local _t
    for _t in $INSTANCE_TYPES; do
        [ "$1" = "$_t" ] && return 0
    done
    return 1
}

instance_validate() {
    local _f _rc _stem _id _v _k
    _f=$1
    _rc=0
    [ -r "$_f" ] || { apm_err "$_f: 无法读取"; return 1; }
    kv_check_syntax "$_f" || return 1

    _stem=${_f##*/}
    _stem=${_stem%.conf}
    _id=$(kv_get "$_f" id)
    is_ident "$_id" || { apm_err "$_f: id 无效: '$_id'"; _rc=1; }
    [ "$_id" = "$_stem" ] || { apm_err "$_f: id 必须与文件名一致 ($_stem)"; _rc=1; }

    _v=$(kv_get "$_f" name)
    is_display_name "$_v" || { apm_err "$_f: name 不能为空或含控制字符"; _rc=1; }

    _v=$(kv_get "$_f" type)
    instance_valid_type "$_v" || { apm_err "$_f: 不支持的 type: '$_v'"; _rc=1; }

    _v=$(kv_get "$_f" enabled)
    is_bool "$_v" || { apm_err "$_f: enabled 必须是 true 或 false"; _rc=1; }

    _v=$(kv_get "$_f" listen)
    is_listen_addr "$_v" || { apm_err "$_f: listen 无效: '$_v'"; _rc=1; }

    _v=$(kv_get "$_f" listen_port)
    is_port "$_v" || { apm_err "$_f: listen_port 无效: '$_v'"; _rc=1; }

    _v=$(kv_get "$_f" egress_socks)
    if [ -n "$_v" ]; then
        is_ident "$_v" || { apm_err "$_f: egress_socks 不是有效的 Profile 名: '$_v'"; _rc=1; }
    fi

    for _k in $(kv_keys "$_f"); do
        case $_k in
            id|name|type|enabled|listen|listen_port|egress_socks) ;;
            credential.?*|tls.?*|transport.?*|relay_access.?*) ;;
            *) apm_err "$_f: 未知的 key: $_k"; _rc=1 ;;
        esac
    done

    policy_validate "$_f" || _rc=1
    return "$_rc"
}

# ---- Server SOCKS Profile ----
#
# 文件: <socks>/<name>.conf
#   name, host, port, enabled   必填
#   username, password          可选, 必须同时出现或同时缺省
#   fallback                    保留字段, v0.1 必须为空
#                               自动 failover 属于未来的独立功能, 不得悄悄启用
# Profile 只有被某个实例通过 egress_socks 明确绑定才会生效
# enabled 只表示该 Profile 可被绑定, 不会让它自动参与路由

socks_validate() {
    local _f _rc _stem _n _v _u _p _k
    _f=$1
    _rc=0
    [ -r "$_f" ] || { apm_err "$_f: 无法读取"; return 1; }
    kv_check_syntax "$_f" || return 1

    _stem=${_f##*/}
    _stem=${_stem%.conf}
    _n=$(kv_get "$_f" name)
    is_ident "$_n" || { apm_err "$_f: name 无效: '$_n'"; _rc=1; }
    [ "$_n" = "$_stem" ] || { apm_err "$_f: name 必须与文件名一致 ($_stem)"; _rc=1; }

    _v=$(kv_get "$_f" host)
    is_host "$_v" || { apm_err "$_f: host 无效: '$_v'"; _rc=1; }

    _v=$(kv_get "$_f" port)
    is_port "$_v" || { apm_err "$_f: port 无效: '$_v'"; _rc=1; }

    _v=$(kv_get "$_f" enabled)
    is_bool "$_v" || { apm_err "$_f: enabled 必须是 true 或 false"; _rc=1; }

    _u=$(kv_get "$_f" username)
    _p=$(kv_get "$_f" password)
    if { [ -n "$_u" ] && [ -z "$_p" ]; } || { [ -z "$_u" ] && [ -n "$_p" ]; }; then
        apm_err "$_f: username 与 password 必须同时设置或同时留空"
        _rc=1
    fi

    _v=$(kv_get "$_f" fallback)
    if [ -n "$_v" ]; then
        apm_err "$_f: fallback 在 v0.1 未实现, 必须留空"
        _rc=1
    fi

    for _k in $(kv_keys "$_f"); do
        case $_k in
            name|host|port|enabled|username|password|fallback) ;;
            *) apm_err "$_f: 未知的 key: $_k"; _rc=1 ;;
        esac
    done
    return "$_rc"
}
