# shellcheck shell=sh
# sing-box Managed Core 与 Protocol Instance (AnyTLS, Hysteria2)
#
# 与 Snell Managed Core 使用同一套已验证的模式 (归属元数据, 事务, 回滚, 卸载与 purge),
# 复用 lib/snell.sh 里的通用工具 (_snell_tool _snell_run _snell_chown _snell_lock _snell_fetch ...)
#
# 分层
#   Core            二进制, 版本, OpenRC, 配置根, 生命周期, 更新, 日志, 归属, check
#   Protocol Instance  /etc/alpine-proxy-manager/instances/<id>.conf 是实例的唯一来源,
#                      /etc/sing-box/config.json 由实例生成, 不手工编辑
#
# 安全原则 (与 Snell 一致)
#   - 只管理自己安装的 sing-box, External 与归属不明的部署一律拒绝写操作, 不执行 233boy 管理脚本
#   - 元数据最后写入, 之前失败完整回滚, 元数据与发现输出不含密码
#   - 配置变更: 生成候选, 官方 sing-box check, 备份, 原子替换, 重启并验证, 失败恢复
#   - 更新前必须用新二进制对当前配置执行 check, 不兼容就拒绝升级
#
# 退出码: 0 成功, 1 失败, 2 用法错误, 3 未实现, 4 被拒绝

# 默认 release 的单一来源
# 选择 1.13.14 而不是更新的 1.14.2 的依据: 同一份 AnyTLS 配置空闲 RSS 实测约 43 MB 对 60 MB, 见 research/SINGBOX-MANAGED.md
SINGBOX_DEFAULT_RELEASE="v1.13.14"
SINGBOX_DL_BASE_DEFAULT="https://github.com/SagerNet/sing-box/releases/download"
SINGBOX_API_BASE_DEFAULT="https://api.github.com/repos/SagerNet/sing-box/releases/tags"
SB_USER="sing-box"
SB_GROUP="sing-box"
SB_INIT_MARK="# apm-managed: sing-box"
SB_DEFAULT_SNI="apm.local"
# 磁盘空间下限 (KiB): 压缩包, 解压后的二进制与安装后的二进制最多同时存在
SB_MIN_FREE_KIB=262144

SB_BIN=/usr/local/bin/sing-box
SB_ETC=/etc/sing-box
SB_CONF=/etc/sing-box/config.json
SB_TLS_DIR=/etc/sing-box/tls
SB_INIT=/etc/init.d/sing-box
SB_LOG_DIR=/var/log/sing-box
SB_WORK_DIR=/var/lib/sing-box
SB_MARK_FILE=/etc/sing-box/.apm-managed

SB_HEALTH_DIR=

_sb_say() { printf '%s\n' "$*"; }

_sb_rc() { _snell_run rc-service sing-box "$1"; }
_sb_user_exists() { grep -q "^$SB_USER:" "$(env_path /etc/passwd)" 2>/dev/null; }
_sb_group_exists() { grep -q "^$SB_GROUP:" "$(env_path /etc/group)" 2>/dev/null; }

# ---- 发布, 校验和 ----

_sb_norm_release() {
    case $1 in
        v*) printf '%s' "$1" ;;
        *) printf 'v%s' "$1" ;;
    esac
}

_sb_valid_release() { printf '%s' "$1" | grep -Eq '^v1\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$'; }

_sb_asset_arch() {
    case ${APM_ARCH:-$(uname -m)} in
        x86_64) printf 'amd64' ;;
        aarch64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

# 已核对过的 release 的 sha256, 来自 GitHub 发布页对应资产的 digest
_sb_known_sha256() {
    case "$1/$2" in
        v1.13.14/amd64) printf 'd5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34' ;;
        v1.13.14/arm64) printf 'edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118' ;;
        v1.14.2/amd64) printf '8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297' ;;
        v1.14.2/arm64) printf '675297394f9430cebb72b3c48ba8bce0d6f7c750a9d68a8f7f88c515c8255cd1' ;;
    esac
}

# 期望的 sha256: 环境变量 APM_SB_SHA256, 其次内置表, 最后查询 GitHub 发布页的资产 digest
# 都拿不到时返回失败, 不在没有校验的情况下安装
_sb_expected_sha256() { # TAG ARCH ASSET
    local _h _json
    if [ -n "${APM_SB_SHA256:-}" ]; then
        printf '%s' "$APM_SB_SHA256"
        return 0
    fi
    _h=$(_sb_known_sha256 "$1" "$2")
    if [ -n "$_h" ]; then
        printf '%s' "$_h"
        return 0
    fi
    _snell_ensure_staging || return 1
    _json=$SNELL_STAGING/release.json
    _snell_fetch "${APM_SB_API_BASE:-$SINGBOX_API_BASE_DEFAULT}/$1" "$_json" || return 1
    _h=$(awk -v a="$3" '
        /"name":/ { n = $0; sub(/.*"name": *"/, "", n); sub(/".*/, "", n) }
        /"digest":/ && n == a { d = $0; sub(/.*"digest": *"sha256:/, "", d); sub(/".*/, "", d); print d; exit }' "$_json")
    printf '%s' "$_h" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s' "$_h"
}

# 磁盘空间: 数据放在磁盘上的 staging, 检查 /var/tmp 与二进制所在目录, df 解析不了时放行
_sb_check_disk() {
    local _d _avail
    for _d in "$(env_path /var/tmp)" "$(dirname "$(env_path "$SB_BIN")")"; do
        while [ ! -d "$_d" ] && [ "$_d" != / ]; do _d=${_d%/*}; [ -n "$_d" ] || _d=/; done
        _avail=$(df -Pk "$_d" 2>/dev/null | awk 'NR == 2 { print $4 }')
        case $_avail in ''|*[!0-9]*) continue ;; esac
        if [ "$_avail" -lt "${APM_SB_MIN_FREE_KIB:-$SB_MIN_FREE_KIB}" ]; then
            apm_err "磁盘空间不足: $_d 可用 ${_avail} KiB, sing-box 安装至少需要 ${APM_SB_MIN_FREE_KIB:-$SB_MIN_FREE_KIB} KiB"
            return 1
        fi
    done
    return 0
}

# 下载, 校验 sha256, 只解压 sing-box 一个文件并立即删除压缩包, 设置 SB_NEW_BIN SB_NEW_REPORTED
_sb_stage_release() {
    local _tag _arch _asset _dir _url _exp _got _member _out
    _tag=$1
    _arch=$(_sb_asset_arch) || { apm_err "当前 CPU 架构没有 sing-box 官方 musl 构建 (支持 amd64, arm64)"; return 1; }
    _snell_ensure_staging || return 1
    _sb_check_disk || return 1
    _asset="sing-box-${_tag#v}-linux-$_arch-musl.tar.gz"
    _dir="sing-box-${_tag#v}-linux-$_arch-musl"
    _url="${APM_SB_DL_BASE:-$SINGBOX_DL_BASE_DEFAULT}/$_tag/$_asset"
    _exp=$(_sb_expected_sha256 "$_tag" "$_arch" "$_asset") || { apm_err "无法确定 $_asset 的 sha256, 拒绝安装 (可设置 APM_SB_SHA256)"; return 1; }
    _snell_say "下载 $_url"
    _snell_fetch "$_url" "$SNELL_STAGING/sb.tar.gz" || { apm_err "下载失败: $_url"; return 1; }
    _got=$(sha256sum "$SNELL_STAGING/sb.tar.gz" | awk '{ print $1 }')
    if [ "$_got" != "$_exp" ]; then
        rm -f -- "$SNELL_STAGING/sb.tar.gz"
        apm_err "sha256 不匹配: 期望 $_exp, 实际 $_got"
        return 1
    fi
    mkdir -p -- "$SNELL_STAGING/x"
    _member="$_dir/sing-box"
    tar -xzf "$SNELL_STAGING/sb.tar.gz" -C "$SNELL_STAGING/x" "$_member" >/dev/null 2>&1
    # 无论成败都立即删除压缩包, 不让它和解压后的二进制同时占用磁盘
    rm -f -- "$SNELL_STAGING/sb.tar.gz"
    SB_NEW_BIN=$SNELL_STAGING/x/$_member
    [ -f "$SB_NEW_BIN" ] || { apm_err "压缩包内没有 $_member 或解压失败"; return 1; }
    [ "$(core_file_kind "$SB_NEW_BIN")" = elf ] || { apm_err "解压出的 sing-box 不是 ELF, 拒绝运行"; return 1; }
    chmod 755 -- "$SB_NEW_BIN"
    _out=$(_core_timeout "$SB_NEW_BIN" version 2>&1 | head -n 3)
    SB_NEW_REPORTED=$(printf '%s\n' "$_out" | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n 1)
    [ -n "$SB_NEW_REPORTED" ] || { apm_err "新的 sing-box 无法执行或没有给出版本"; return 1; }
    if [ "$SB_NEW_REPORTED" != "${_tag#v}" ]; then
        apm_err "二进制自报版本 $SB_NEW_REPORTED 与请求的 release $_tag 不一致"
        return 1
    fi
}

# ---- 实例 (Protocol Instance) ----

_sb_json_safe() { printf '%s' "$1" | grep -Eq '^[][A-Za-z0-9_./:@-]*$'; }

_sb_valid_sni() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'; }

# 支持的协议类型, 内部统一使用规范化的小写名, 不接受别名
# 每个协议在这里登记 传输层 是否需要 TLS 与凭据规格, 再提供校验与 inbound 生成
SB_TYPES="anytls hysteria2 tuic shadowsocks"

# Shadowsocks 只支持官方当前版本 (1.13.14 与 1.14.2) 都确认可用且值得支持的现代 AEAD 方法
# 2022 系列要求 base64 编码的固定长度密钥, 传统 AEAD 方法使用普通密码
# 不支持 none rc4-md5 等已不安全或官方不支持的方法, 也不支持 aes-192 与 xchacha 等小众方法
SB_SS_METHODS="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-128-gcm aes-256-gcm chacha20-ietf-poly1305"
SB_SS_DEFAULT_METHOD="2022-blake3-aes-128-gcm"
# TUIC 的拥塞控制, 官方确认的取值, 其他值 sing-box 会拒绝
SB_TUIC_CC="cubic new_reno bbr"

_sb_type_valid() {
    local _t
    for _t in $SB_TYPES; do
        [ "$1" = "$_t" ] && return 0
    done
    return 1
}

# 实例 ID 前缀与用户界面显示名
_sb_type_prefix() {
    case $1 in
        anytls) printf 'AnyTLS' ;;
        hysteria2) printf 'Hysteria2' ;;
        tuic) printf 'TUIC' ;;
        shadowsocks) printf 'Shadowsocks' ;;
    esac
}

# 协议实际监听的传输层列表, Shadowsocks 的 inbound 同时监听 TCP 与 UDP
# 端口冲突与健康检查对列表里的每个协议分别判断, 纯 TCP 与纯 UDP 的同号端口互不冲突
_sb_type_protos() {
    case $1 in
        anytls) printf 'tcp' ;;
        hysteria2|tuic) printf 'udp' ;;
        shadowsocks) printf 'tcp udp' ;;
    esac
}

# 写进实例文件与界面的传输层名称
_sb_type_transport() {
    case $1 in
        anytls) printf 'tcp' ;;
        hysteria2|tuic) printf 'udp' ;;
        shadowsocks) printf 'tcp+udp' ;;
    esac
}

_sb_type_has_proto() { # TYPE PROTO
    local _p
    for _p in $(_sb_type_protos "$1"); do
        [ "$_p" = "$2" ] && return 0
    done
    return 1
}

# 协议是否需要 TLS, Shadowsocks 不需要, 也就不生成证书
_sb_type_tls() {
    case $1 in
        anytls|hysteria2|tuic) return 0 ;;
        *) return 1 ;;
    esac
}

_sb_proto_label() { case $1 in tcp) printf 'TCP' ;; udp) printf 'UDP' ;; esac; }

_sb_valid_uuid() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }

# 生成标准的 UUID v4: 16 个随机字节, 版本位固定为 4, 变体位取 8 9 a b, 不依赖 uuidgen
_sb_gen_uuid() {
    local _h _v
    _h=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ "${#_h}" -eq 32 ] || return 1
    case $(printf '%s' "$_h" | cut -c17) in
        0|4|8|c) _v=8 ;;
        1|5|9|d) _v=9 ;;
        2|6|a|e) _v=a ;;
        *) _v=b ;;
    esac
    printf '%s-%s-4%s-%s%s-%s' "$(printf '%s' "$_h" | cut -c1-8)" "$(printf '%s' "$_h" | cut -c9-12)" \
        "$(printf '%s' "$_h" | cut -c14-16)" "$_v" "$(printf '%s' "$_h" | cut -c18-20)" "$(printf '%s' "$_h" | cut -c21-32)"
}

_sb_ss_method_valid() {
    local _m
    for _m in $SB_SS_METHODS; do
        [ "$1" = "$_m" ] && return 0
    done
    return 1
}

_sb_tuic_cc_valid() {
    local _c
    for _c in $SB_TUIC_CC; do
        [ "$1" = "$_c" ] && return 0
    done
    return 1
}

# 凭据规格: psk 为 16 到 128 位字母数字或 _ -, b64:N 为 base64 编码的 N 字节密钥
# 只有 Shadowsocks 的 2022 方法使用 b64, 规格取决于协议与 method, 不同 method 的密钥格式不通用
_sb_secret_kind() { # TYPE METHOD
    case $1 in
        shadowsocks)
            case $2 in
                2022-blake3-aes-128-gcm) printf 'b64:16' ;;
                2022-*) printf 'b64:32' ;;
                *) printf 'psk' ;;
            esac
            ;;
        *) printf 'psk' ;;
    esac
}

# base64 密钥必须是带填充的标准编码, 长度精确, 解码后字节数精确
_sb_valid_b64key() { # VALUE BYTES
    local _len
    _len=$(( (($2 + 2) / 3) * 4 ))
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || return 1
    [ "${#1}" -eq "$_len" ] || return 1
    [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "$2" ]
}

_sb_valid_secret() { # KIND VALUE
    case $1 in
        psk) _snell_valid_psk "$2" ;;
        b64:*) _sb_valid_b64key "$2" "${1#b64:}" ;;
        *) return 1 ;;
    esac
}

_sb_gen_secret() { # KIND
    local _k
    case $1 in
        psk) _snell_gen_psk ;;
        b64:*)
            _k=$(head -c "${1#b64:}" /dev/urandom 2>/dev/null | base64 | tr -d '\n')
            _sb_valid_b64key "$_k" "${1#b64:}" || return 1
            printf '%s' "$_k"
            ;;
        *) return 1 ;;
    esac
}

_sb_secret_hint() { # KIND
    case $1 in
        psk) printf '16 到 128 位字母数字或 _ -' ;;
        b64:16) printf 'base64 编码的 16 字节密钥, 24 个字符' ;;
        b64:32) printf 'base64 编码的 32 字节密钥, 44 个字符' ;;
    esac
}

# 实例校验: 通用模型校验加协议专有字段, 各协议的凭据字段由自己定义
# anytls 与 hysteria2 是 password, tuic 是 uuid 加 password, shadowsocks 是 method 加按 method 决定格式的密钥
sb_instance_validate() {
    local _f _rc _v _t _m
    _f=$1
    _rc=0
    instance_validate "$_f" || _rc=1
    _t=$(kv_get "$_f" type)
    if ! _sb_type_valid "$_t"; then
        apm_err "$_f: sing-box 目前只支持 $SB_TYPES 实例"
        return 1
    fi
    _v=$(kv_get "$_f" listen_port)
    _snell_valid_port "$_v" || { apm_err "$_f: listen_port 需要 1025 到 65535"; _rc=1; }
    if _sb_type_tls "$_t"; then
        _v=$(kv_get "$_f" tls.server_name)
        _sb_valid_sni "$_v" || { apm_err "$_f: tls.server_name 无效"; _rc=1; }
        for _v in tls.certificate_path tls.key_path; do
            case $(kv_get "$_f" "$_v") in
                /*) _sb_json_safe "$(kv_get "$_f" "$_v")" || { apm_err "$_f: $_v 含有不允许的字符"; _rc=1; } ;;
                *) apm_err "$_f: $_v 必须是绝对路径"; _rc=1 ;;
            esac
        done
    fi
    case $_t in
        anytls|hysteria2)
            _snell_valid_psk "$(kv_get "$_f" credential.password)" || { apm_err "$_f: credential.password 无效 ($(_sb_secret_hint psk))"; _rc=1; }
            ;;
        tuic)
            _sb_valid_uuid "$(kv_get "$_f" credential.uuid)" || { apm_err "$_f: credential.uuid 不是有效的 UUID"; _rc=1; }
            _snell_valid_psk "$(kv_get "$_f" credential.password)" || { apm_err "$_f: credential.password 无效 ($(_sb_secret_hint psk))"; _rc=1; }
            _v=$(kv_get "$_f" transport.congestion_control)
            if [ -n "$_v" ]; then
                _sb_tuic_cc_valid "$_v" || { apm_err "$_f: transport.congestion_control 不在允许的取值内 ($SB_TUIC_CC)"; _rc=1; }
            fi
            ;;
        shadowsocks)
            _m=$(kv_get "$_f" credential.method)
            if _sb_ss_method_valid "$_m"; then
                _sb_valid_secret "$(_sb_secret_kind shadowsocks "$_m")" "$(kv_get "$_f" credential.password)" \
                    || { apm_err "$_f: credential.password 不符合 method $_m 的要求 ($(_sb_secret_hint "$(_sb_secret_kind shadowsocks "$_m")"))"; _rc=1; }
            else
                apm_err "$_f: credential.method 不在允许的取值内 ($SB_SS_METHODS)"
                _rc=1
            fi
            ;;
    esac
    _sb_policy_check "$_f" || _rc=1
    return "$_rc"
}

# 一个 inbound 的 JSON, 各协议自己的结构, 已有协议的输出保持逐字节不变
# anytls 与 hysteria2: users 里一个 password, tls 里证书与私钥路径, Hysteria2 的带宽与 masquerade 可选 v1 不配置
# tuic: users 里 uuid 加 password, 可选 congestion_control, tls
# shadowsocks: method 与 password 直接在 inbound 上, 同时监听 TCP 与 UDP, 没有 tls
_sb_inbound() { # FILE
    local _t
    _t=$(kv_get "$1" type)
    case $_t in
        anytls|hysteria2)
            printf '\n    {\n      "type": "%s",\n      "tag": "%s",\n      "listen": "%s",\n      "listen_port": %s,\n      "users": [\n        {\n          "password": "%s"\n        }\n      ],\n      "tls": {\n        "enabled": true,\n        "certificate_path": "%s",\n        "key_path": "%s"\n      }\n    }' \
                "$_t" "$(kv_get "$1" id)" "$(kv_get "$1" listen)" "$(kv_get "$1" listen_port)" "$(kv_get "$1" credential.password)" \
                "$(kv_get "$1" tls.certificate_path)" "$(kv_get "$1" tls.key_path)"
            ;;
        tuic)
            printf '\n    {\n      "type": "tuic",\n      "tag": "%s",\n      "listen": "%s",\n      "listen_port": %s,\n      "users": [\n        {\n          "uuid": "%s",\n          "password": "%s"\n        }\n      ],\n' \
                "$(kv_get "$1" id)" "$(kv_get "$1" listen)" "$(kv_get "$1" listen_port)" "$(kv_get "$1" credential.uuid)" "$(kv_get "$1" credential.password)"
            if [ -n "$(kv_get "$1" transport.congestion_control)" ]; then
                printf '      "congestion_control": "%s",\n' "$(kv_get "$1" transport.congestion_control)"
            fi
            printf '      "tls": {\n        "enabled": true,\n        "certificate_path": "%s",\n        "key_path": "%s"\n      }\n    }' \
                "$(kv_get "$1" tls.certificate_path)" "$(kv_get "$1" tls.key_path)"
            ;;
        shadowsocks)
            printf '\n    {\n      "type": "shadowsocks",\n      "tag": "%s",\n      "listen": "%s",\n      "listen_port": %s,\n      "method": "%s",\n      "password": "%s"\n    }' \
                "$(kv_get "$1" id)" "$(kv_get "$1" listen)" "$(kv_get "$1" listen_port)" "$(kv_get "$1" credential.method)" "$(kv_get "$1" credential.password)"
            ;;
    esac
}

# ---- 目标访问限制 (Relay Access Policy) ----
# 内部模型沿用 policy.sh 的 relay_access.* 键, 没有任何键就是不限制, 旧实例无需迁移
# 第一版只支持 IPv4 与 [IPv6] 加端口, 不支持域名, 不支持 CIDR 与端口范围

_sb_valid_ipv4_dest() {
    is_ipv4 "$1" || return 1
    ! printf '%s' "$1" | grep -Eq '(^|\.)0[0-9]'
}

# 不带方括号的 IPv6, 小写十六进制, 至多一个 ::, 不接受内嵌 IPv4 与区域标识
_sb_valid_ipv6_dest() {
    awk -v a="$1" 'BEGIN {
        if (a !~ /^[0-9a-f:]+$/ || a ~ /:::/) exit 1
        b = a; c = gsub(/::/, "X", b)
        if (c > 1) exit 1
        if (a ~ /^:/ && a !~ /^::/) exit 1
        if (a ~ /:$/ && a !~ /::$/) exit 1
        k = split(a, g, ":"); ne = 0
        for (i = 1; i <= k; i++) { if (g[i] != "") { ne++; if (length(g[i]) > 4) exit 1 } }
        if (c == 0 && ne != 8) exit 1
        if (c == 1 && ne > 7) exit 1
        exit 0 }'
}

# 把用户输入的 HOST PORT 规范化为 host:port 形式, IPv6 带方括号并转小写, 失败时返回 1 并设置 SB_DEST_ERR
_sb_dest_normalize() { # HOST PORT
    local _h _b
    SB_DEST_ERR=
    _h=$1
    is_port "$2" || { SB_DEST_ERR="端口无效: $2 (需要 1 到 65535)"; return 1; }
    _b=no
    case $_h in
        \[*\]) _h=${_h#\[}; _h=${_h%\]}; _b=yes ;;
    esac
    case $_h in
        *:*)
            _h=$(printf '%s' "$_h" | tr 'A-F' 'a-f')
            _sb_valid_ipv6_dest "$_h" || { SB_DEST_ERR="IPv6 地址无效: $1"; return 1; }
            printf '[%s]:%s' "$_h" "$2"
            ;;
        '') SB_DEST_ERR="地址为空"; return 1 ;;
        *)
            if [ "$_b" = yes ]; then
                SB_DEST_ERR="方括号只用于 IPv6 地址: $1"
                return 1
            elif printf '%s' "$_h" | grep -Eq '^[0-9.]+$'; then
                _sb_valid_ipv4_dest "$_h" || { SB_DEST_ERR="IPv4 地址无效: $1"; return 1; }
                printf '%s:%s' "$_h" "$2"
            else
                SB_DEST_ERR="目标访问限制第一版只支持 IP 地址, 不支持域名: $1"
                return 1
            fi
            ;;
    esac
}

# 已存储的 host:port 是否是规范化的 IP 目标
_sb_dest_stored_ok() { # host:port
    local _n
    _n=$(_sb_dest_normalize "${1%:*}" "${1##*:}") || return 1
    [ "$_n" = "$1" ]
}

# 实例的目标列表, 每行 host:port, 按地址再按端口排序且去重前保持原样 以便校验发现重复
_sb_policy_dests() { # FILE
    policy_destinations "$1" | LC_ALL=C sort -k1,1 -k2,2n | while read -r _h _p; do printf '%s:%s\n' "$_h" "$_p"; done
}

# 实例是否带有任何 relay_access 键, 带有键就必须显式声明 enabled, 否则不能静默当作不限制
_sb_policy_present() { kv_keys "$1" | grep -q '^relay_access\.'; }

# 目标访问限制是否生效 (fail-closed 校验见 _sb_policy_check)
_sb_policy_on() { policy_enabled "$1"; }

# 校验实例的目标访问限制, 任何问题都返回 1, 调用方必须拒绝而不是当作不限制
_sb_policy_check() { # FILE
    local _f _rc _en _d _seen
    _f=$1
    _rc=0
    _sb_policy_present "$_f" || return 0
    policy_validate "$_f" >/dev/null 2>&1 || { policy_validate "$_f" 2>&1 | sed 's/^/  /' >&2; _rc=1; }
    _en=$(kv_get "$_f" relay_access.enabled)
    if [ "$_en" != true ] && [ "$_en" != false ]; then
        apm_err "$_f: 存在 relay_access 配置但 relay_access.enabled 没有显式设为 true 或 false"
        _rc=1
    fi
    _seen=
    for _d in $(_sb_policy_dests "$_f"); do
        if ! _sb_dest_stored_ok "$_d"; then
            apm_err "$_f: relay_access 的目标不是有效的规范化 IP 目标: $_d"
            _rc=1
            continue
        fi
        case " $_seen " in *" $_d "*) apm_err "$_f: relay_access 目标重复: $_d"; _rc=1 ;; esac
        _seen="$_seen $_d"
    done
    return "$_rc"
}

# 一个目标的 route 规则: 命中该实例入站且目标是这个 IP 与端口就走 direct
_sb_route_allow_rule() { # TAG host:port
    local _h _p _cidr
    _h=${2%:*}
    _p=${2##*:}
    case $_h in
        \[*\]) _h=${_h#\[}; _h=${_h%\]}; _cidr=$_h/128 ;;
        *) _cidr=$_h/32 ;;
    esac
    printf '\n      {\n        "inbound": ["%s"],\n        "ip_cidr": ["%s"],\n        "port": [%s],\n        "action": "route",\n        "outbound": "direct"\n      }' "$1" "$_cidr" "$_p"
}

# 全部启用且开启目标访问限制的实例的 route.rules 内容, 没有则输出为空
# 每个实例先列出它的允许规则 (地址与端口排序) 再列一条只对该入站生效的 reject 兜底
# 规则只按入站 tag 匹配, 不限制的实例与其他实例完全不受影响
_sb_route_rules() { # INSTANCES_DIR
    local _f _tag _d _first
    _first=1
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" enabled)" = true ] || continue
        _sb_type_valid "$(kv_get "$_f" type)" || continue
        _sb_policy_present "$_f" || continue
        _sb_policy_check "$_f" || return 1
        _sb_policy_on "$_f" || continue
        _tag=$(kv_get "$_f" id)
        for _d in $(_sb_policy_dests "$_f"); do
            [ "$_first" = 1 ] || printf ','
            _first=0
            _sb_route_allow_rule "$_tag" "$_d"
        done
        [ "$_first" = 1 ] || printf ','
        _first=0
        printf '\n      {\n        "inbound": ["%s"],\n        "action": "reject"\n      }' "$_tag"
    done
}

# 由实例目录生成完整的 sing-box 配置到标准输出, 只包含启用的实例, 按实例 ID 排序, 输出稳定
# 没有任何实例开启目标访问限制时不输出 route, 配置与没有这个功能时逐字节相同
# 任何实例的限制配置无效都整体失败, 绝不退回不限制
sb_generate_config() { # INSTANCES_DIR
    local _f _first _rules
    _rules=$(_sb_route_rules "$1") || return 1
    printf '{\n  "log": {\n    "level": "warn",\n    "timestamp": true\n  },\n  "inbounds": ['
    _first=1
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" enabled)" = true ] || continue
        _sb_type_valid "$(kv_get "$_f" type)" || continue
        [ "$_first" = 1 ] || printf ','
        _first=0
        _sb_inbound "$_f"
    done
    [ "$_first" = 1 ] || printf '\n  '
    printf '],\n  "outbounds": [\n    {\n      "type": "direct",\n      "tag": "direct"\n    }\n  ]'
    if [ -n "$_rules" ]; then
        printf ',\n  "route": {\n    "rules": [%s\n    ]\n  }' "$_rules"
    fi
    printf '\n}\n'
}

# 启用实例的监听, 形如 tcp:20443 udp:20443, 空格分隔, 实例要求几种传输层就有几项
_sb_expected_ports() {
    local _f _r _pr
    _r=
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" enabled)" = true ] || continue
        for _pr in $(_sb_type_protos "$(kv_get "$_f" type)"); do
            _r="$_r $_pr:$(kv_get "$_f" listen_port)"
        done
    done
    printf '%s' "${_r# }"
}

# 两个监听地址是否重叠: 相同, 或任一方是通配地址
_sb_addr_overlap() {
    [ "$1" = "$2" ] && return 0
    case $1 in ::|0.0.0.0) return 0 ;; esac
    case $2 in ::|0.0.0.0) return 0 ;; esac
    return 1
}

# 实例间冲突: 全部实例 (启用或禁用) 里是否已有 同协议同端口且地址重叠 的实例
_sb_port_taken_by_instance() { # DIR PROTO PORT LISTEN [EXCEPT_ID]
    local _f
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" id)" != "${5:-}" ] || continue
        _sb_type_has_proto "$(kv_get "$_f" type)" "$2" || continue
        [ "$(kv_get "$_f" listen_port)" = "$3" ] || continue
        _sb_addr_overlap "$(kv_get "$_f" listen)" "$4" && return 0
    done
    return 1
}

# 系统冲突: /proc/net 里是否已有 同协议同端口且地址重叠 的监听, tcp 与 udp 分开判断
_sb_port_busy() { # PROTO PORT LISTEN
    local _pr _ad _ino _a
    _core_proc_listeners "" " $2 " | while read -r _pr _ad _ino; do
        [ "$_pr" = "$1" ] || continue
        _a=${_ad%:*}
        _a=${_a#[}
        _a=${_a%]}
        _sb_addr_overlap "$_a" "$3" && echo busy
    done | grep -q busy
}

# 一个实例类型的所有传输层上, 端口是否都可用: 先查实例间冲突, 再查系统监听, 任何一个协议冲突整体拒绝
# 第 6 个参数 no 时不查系统监听, 用于只更换监听地址而端口不变的场景
_sb_check_ports() { # DIR TYPE PORT LISTEN [EXCEPT_ID] [CHECK_SYSTEM]
    local _pr
    for _pr in $(_sb_type_protos "$2"); do
        if _sb_port_taken_by_instance "$1" "$_pr" "$3" "$4" "${5:-}"; then
            apm_err "$_pr 端口 $3 已被其他实例使用"
            return 1
        fi
        if [ "${6:-yes}" = yes ] && _sb_port_busy "$_pr" "$3" "$4"; then
            apm_err "$_pr 端口 $3 已被占用"
            return 1
        fi
    done
    return 0
}

# 实例当前是否在它要求的每个传输层上都有自己的监听
_sb_inst_listening() { # FILE
    local _pr
    for _pr in $(_sb_type_protos "$(kv_get "$1" type)"); do
        _sb_listening "$_pr" "$(kv_get "$1" listen_port)" || return 1
    done
}

# 当前发现到的监听里是否有 PROTO 与 PORT, 依据 CF_LISTEN 即服务进程自己的 socket
_sb_listening() { # PROTO PORT
    printf '%s\n' "$CF_LISTEN" | awk -v p="$1" -v t=":$2" '
        $1 == p { n = length($2); if (substr($2, n - length(t) + 1) == t) f = 1 }
        END { exit !f }'
}

_sb_next_id() { # DIR TYPE_PREFIX
    local _n _id
    _n=1
    while [ "$_n" -le 99 ]; do
        _id=$(printf '%s-%02d' "$2" "$_n")
        [ -e "$1/$_id.conf" ] || { printf '%s' "$_id"; return 0; }
        _n=$((_n + 1))
    done
    return 1
}

# 修改实例文件里的一个键, 不存在则追加
_sb_inst_set() { # FILE KEY VALUE  -> 结果写回 FILE
    local _tmp
    _tmp=$1.new
    V=$3 awk -v k="$2" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { print k "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print k "=" ENVIRON["V"] }' "$1" > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp"
    mv -f -- "$_tmp" "$1"
}

# 删除精确键或某个前缀下的全部键 (前缀以点结尾)
_sb_inst_unset() { # FILE KEY | FILE PREFIX.
    local _tmp
    _tmp=$1.new
    awk -v k="$2" '
        k ~ /\.$/ { if (index($0, k) == 1) next; print; next }
        index($0, k "=") == 1 { next }
        { print }' "$1" > "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod 600 -- "$_tmp"
    mv -f -- "$_tmp" "$1"
}

# ---- 健康检查 ----

_sb_wait_secs() { printf '%s' "${APM_SB_WAIT:-${APM_SNELL_WAIT:-20}}"; }

# running, 有服务进程, 启用实例的每个端口都在监听, 没有实例时只要求运行与进程
_sb_wait_healthy() {
    local _t _max _p _ok _dir
    _max=$(_sb_wait_secs)
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover singbox
        _dir=${SB_HEALTH_DIR:-$(state_instances_dir)}
        if [ "$CF_STATE" = running ] && [ -n "$CF_PID" ]; then
            _ok=1
            for _p in $(_sb_expected_ports "$_dir"); do
                _sb_listening "${_p%%:*}" "${_p#*:}" || _ok=0
            done
            [ "$_ok" = 1 ] && return 0
        fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_sb_wait_stopped() {
    local _t _max
    _max=$(_sb_wait_secs)
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover singbox
        if [ "$CF_SERVICE_STATE" = stopped ] && [ -z "$CF_PID" ]; then
            return 0
        fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_sb_show_failure() {
    apm_err "服务状态: ${CF_SERVICE_STATE:-未知}"
    if [ -n "${CF_LOG_ERR:-}" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then
        apm_err "最近日志 ($CF_LOG_ERR, 可能含目标域名):"
        tail -n 10 "$(env_path "$CF_LOG_ERR")" 2>/dev/null | sed 's/^/    /' >&2
    fi
}

_sb_reload_verify() {
    _sb_rc restart >/dev/null 2>&1 || return 1
    _sb_wait_healthy
}

# ---- 归属检查 ----

_sb_require_managed() { # allow_broken
    core_discover singbox
    if [ "$CF_INSTALLED" = no ]; then
        apm_err "未检测到 sing-box"
        return 4
    fi
    if [ "$CF_INSTALLED" = unverified ]; then
        apm_err "检测到 sing-box 命名入口但它不是已确认的 ELF, 拒绝执行写操作"
        return 4
    fi
    if [ "$CF_META_STATE" = invalid ]; then
        apm_err "Manager 元数据异常, 无法证明这是由 Alpine Proxy Manager 管理的 sing-box, 拒绝执行写操作"
        return 4
    fi
    if [ "$CF_MANAGED" != yes ]; then
        apm_err "检测到现有 sing-box 部署, 但该实例不是由 Alpine Proxy Manager 管理"
        apm_err "拒绝执行写操作, 不会覆盖或接管"
        return 4
    fi
    if [ "$CF_STATE" = broken ] && [ "${1:-no}" != yes ]; then
        apm_err "sing-box 处于异常状态 (二进制无法给出版本), 请先执行 sing-box update --force 或 sing-box uninstall"
        return 4
    fi
    return 0
}

# ---- 元数据 ----

_sb_write_meta() { # EXACT REPORTED CREATED_USER CREATED_GROUP
    local _f _c
    _f=$(core_meta_file singbox)
    state_ensure_dirs || return 1
    _c=$(txn_new_candidate "$_f") || return 1
    {
        printf 'schema=1\nmanaged=true\ncore=singbox\n'
        printf 'exact_release=%s\nreported_version=%s\n' "$1" "$2"
        printf 'binary_path=%s\nconfig_path=%s\nconfig_root=%s\nservice_name=sing-box\nlog_dir=%s\n' "$SB_BIN" "$SB_CONF" "$SB_ETC" "$SB_LOG_DIR"
        printf 'installed_at=%s\ncreated_user=%s\ncreated_group=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$4"
    } > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

_sb_update_meta() { # EXACT REPORTED
    local _f _c
    _f=$(core_meta_file singbox)
    _c=$(txn_new_candidate "$_f") || return 1
    awk -v e="$1" -v r="$2" '
        /^exact_release=/ { print "exact_release=" e; next }
        /^reported_version=/ { print "reported_version=" r; next }
        { print }' "$_f" > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# ---- OpenRC 脚本 ----

_sb_write_init() {
    local _t
    _t=$(env_path "$SB_INIT")
    mkdir -p -- "$(dirname "$_t")" || return 1
    cat > "$_t" <<'EOF'
#!/sbin/openrc-run
# apm-managed: sing-box
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager sing-box 管理, 手工修改可能被覆盖

name="sing-box"
description="sing-box service (managed by Alpine Proxy Manager)"
command="/usr/local/bin/sing-box"
command_args="run --disable-color -D /var/lib/sing-box -c /etc/sing-box/config.json"
command_user="sing-box:sing-box"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=5
respawn_period=60
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/access.log"
error_log="/var/log/sing-box/error.log"
required_files="/etc/sing-box/config.json"

depend() {
    need net
    after firewall
}

start_pre() {
    # 降权运行的进程必须能写日志与工作目录
    checkpath -d -m 0750 -o sing-box:sing-box /var/log/sing-box
    checkpath -f -m 0640 -o sing-box:sing-box /var/log/sing-box/access.log
    checkpath -f -m 0640 -o sing-box:sing-box /var/log/sing-box/error.log
    checkpath -d -m 0750 -o sing-box:sing-box /var/lib/sing-box
    # 启动前先用官方 check 验证配置, 配置有问题时不要启动一个注定失败的服务
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json
}
EOF
    chmod 755 -- "$_t"
}

# ---- install ----

_sb_install_rollback() {
    [ "${R_STARTED:-0}" = 1 ] && _sb_rc stop >/dev/null 2>&1
    [ "${R_RCUPDATE:-0}" = 1 ] && _snell_run rc-update del sing-box default >/dev/null 2>&1
    [ "${R_INIT:-0}" = 1 ] && rm -f -- "$(env_path "$SB_INIT")"
    [ "${R_BIN:-0}" = 1 ] && rm -f -- "$(env_path "$SB_BIN")" "$(env_path "$SB_BIN").new"
    if [ "${R_CONF:-0}" = 1 ]; then
        rm -f -- "$(env_path "$SB_CONF")"
        rm -f -- "$(env_path "$SB_ETC")"/.config.json.cand.* 2>/dev/null
    fi
    [ "${R_LOGDIR:-0}" = 1 ] && rm -rf -- "$(env_path "$SB_LOG_DIR")"
    [ "${R_WORKDIR:-0}" = 1 ] && rm -rf -- "$(env_path "$SB_WORK_DIR")"
    [ "${R_TLSDIR:-0}" = 1 ] && rmdir "$(env_path "$SB_TLS_DIR")" 2>/dev/null
    [ "${R_MARK_USER:-0}" = 1 ] && rm -f -- "$(env_path "$SB_ETC")/.apm-created-user"
    [ "${R_MARK_GROUP:-0}" = 1 ] && rm -f -- "$(env_path "$SB_ETC")/.apm-created-group"
    [ "${R_MARK:-0}" = 1 ] && rm -f -- "$(env_path "$SB_MARK_FILE")"
    [ "${R_ETC:-0}" = 1 ] && rmdir "$(env_path "$SB_ETC")" 2>/dev/null
    [ "${R_USER:-0}" = 1 ] && _snell_run deluser "$SB_USER" >/dev/null 2>&1
    if [ "${R_GROUP:-0}" = 1 ] && _sb_group_exists; then
        _snell_run delgroup "$SB_GROUP" >/dev/null 2>&1
    fi
    rm -f -- "$(core_meta_file singbox)"
    return 0
}

_sb_install_fail() {
    apm_err "$1"
    _sb_say "正在回滚本次安装"
    _sb_install_rollback
    return 1
}

singbox_install() {
    local _release _tag _a _cmark _gmark _ports _p
    _release=$SINGBOX_DEFAULT_RELEASE
    while [ $# -gt 0 ]; do
        case $1 in
            --release) [ $# -ge 2 ] || { apm_err "--release 需要参数"; return 2; }; _release=$2; shift ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _tag=$(_sb_norm_release "$_release")
    _sb_valid_release "$_tag" || { apm_err "release 格式无效: $_release (示例 v1.13.14)"; return 2; }
    _snell_need_root || return 4

    core_discover singbox
    if [ "$CF_INSTALLED" != no ] || [ -n "$CF_SERVICE" ]; then
        if [ "$CF_MANAGED" = yes ]; then
            apm_err "sing-box 已经由 Alpine Proxy Manager 安装, 如需升级请使用 sing-box update"
        elif [ "$CF_META_STATE" = invalid ]; then
            apm_err "检测到 sing-box 相关文件且 Manager 元数据异常, 归属不明, 拒绝安装"
        else
            apm_err "发现现有 sing-box 部署, 当前不会覆盖或接管"
        fi
        return 4
    fi
    for _a in "$SB_BIN" "$SB_INIT"; do
        if [ -e "$(env_path "$_a")" ] || [ -L "$(env_path "$_a")" ]; then
            apm_err "检测到残留文件 $_a, 为避免覆盖已停止安装"
            return 4
        fi
    done
    if [ -e "$(core_meta_file singbox)" ]; then
        apm_err "检测到残留的 Manager 元数据 $(core_meta_file singbox), 归属不明, 为避免覆盖已停止安装"
        return 4
    fi
    # /etc/sing-box 已存在但没有 Manager 标记: 是别的部署 (例如 233boy 或 apk), 不碰
    if [ -d "$(env_path "$SB_ETC")" ] && [ ! -f "$(env_path "$SB_MARK_FILE")" ]; then
        apm_err "发现 $SB_ETC 已存在且不是由 Manager 创建的, 拒绝安装, 不会覆盖或接管"
        return 4
    fi
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT

    # 沿用卸载时保留的实例: 先校验, 并确认端口空闲
    if [ -d "$(state_instances_dir)" ]; then
        for _a in $(state_list_confs "$(state_instances_dir)"); do
            sb_instance_validate "$_a" >/dev/null 2>&1 || { apm_err "已保留的实例 $_a 无效, 请先处理后再安装"; return 4; }
        done
        _ports=$(_sb_expected_ports "$(state_instances_dir)")
        for _p in $_ports; do
            if _sb_port_busy "${_p%%:*}" "${_p#*:}" "::"; then
                apm_err "已保留的实例使用的 ${_p%%:*} 端口 ${_p#*:} 已被占用"
                return 1
            fi
        done
    fi

    _sb_say "[1/7] 下载并校验 sing-box $_tag"
    _sb_stage_release "$_tag" || return 1

    R_STARTED=0 R_RCUPDATE=0 R_INIT=0 R_BIN=0 R_CONF=0 R_LOGDIR=0 R_WORKDIR=0 R_TLSDIR=0 R_MARK=0 R_MARK_USER=0 R_MARK_GROUP=0 R_ETC=0 R_USER=0 R_GROUP=0
    _cmark=no
    _gmark=no
    _sb_say "[2/7] 用户与目录"
    if _sb_group_exists; then
        [ ! -f "$(env_path "$SB_ETC")/.apm-created-group" ] || _gmark=yes
    else
        _snell_run addgroup -S "$SB_GROUP" >/dev/null 2>&1 || { _sb_install_fail "创建用户组 $SB_GROUP 失败"; return 1; }
        R_GROUP=1
        _gmark=yes
    fi
    if _sb_user_exists; then
        [ ! -f "$(env_path "$SB_ETC")/.apm-created-user" ] || _cmark=yes
    else
        _snell_run adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$SB_GROUP" "$SB_USER" >/dev/null 2>&1 || { _sb_install_fail "创建用户 $SB_USER 失败"; return 1; }
        R_USER=1
        _cmark=yes
    fi
    if [ ! -d "$(env_path "$SB_ETC")" ]; then
        mkdir -p -- "$(env_path "$SB_ETC")" || { _sb_install_fail "创建 $SB_ETC 失败"; return 1; }
        R_ETC=1
    fi
    chmod 750 -- "$(env_path "$SB_ETC")"
    _snell_chown "root:$SB_GROUP" "$(env_path "$SB_ETC")" || { _sb_install_fail "设置 $SB_ETC 属主失败"; return 1; }
    if [ ! -f "$(env_path "$SB_MARK_FILE")" ]; then
        : > "$(env_path "$SB_MARK_FILE")" && R_MARK=1
    fi
    if [ "$_cmark" = yes ] && [ ! -f "$(env_path "$SB_ETC")/.apm-created-user" ]; then
        : > "$(env_path "$SB_ETC")/.apm-created-user" && R_MARK_USER=1
    fi
    if [ "$_gmark" = yes ] && [ ! -f "$(env_path "$SB_ETC")/.apm-created-group" ]; then
        : > "$(env_path "$SB_ETC")/.apm-created-group" && R_MARK_GROUP=1
    fi
    if [ ! -d "$(env_path "$SB_TLS_DIR")" ]; then
        mkdir -p -- "$(env_path "$SB_TLS_DIR")" && R_TLSDIR=1
        chmod 750 -- "$(env_path "$SB_TLS_DIR")"
        _snell_chown "root:$SB_GROUP" "$(env_path "$SB_TLS_DIR")"
    fi
    if [ ! -d "$(env_path "$SB_LOG_DIR")" ]; then
        mkdir -p -- "$(env_path "$SB_LOG_DIR")" || { _sb_install_fail "创建 $SB_LOG_DIR 失败"; return 1; }
        R_LOGDIR=1
    fi
    chmod 750 -- "$(env_path "$SB_LOG_DIR")"
    _snell_chown "$SB_USER:$SB_GROUP" "$(env_path "$SB_LOG_DIR")" || { _sb_install_fail "设置 $SB_LOG_DIR 属主失败"; return 1; }
    if [ ! -d "$(env_path "$SB_WORK_DIR")" ]; then
        mkdir -p -- "$(env_path "$SB_WORK_DIR")" || { _sb_install_fail "创建 $SB_WORK_DIR 失败"; return 1; }
        R_WORKDIR=1
    fi
    chmod 750 -- "$(env_path "$SB_WORK_DIR")"
    _snell_chown "$SB_USER:$SB_GROUP" "$(env_path "$SB_WORK_DIR")" || { _sb_install_fail "设置 $SB_WORK_DIR 属主失败"; return 1; }

    _sb_say "[3/7] 安装二进制"
    mkdir -p -- "$(dirname "$(env_path "$SB_BIN")")"
    R_BIN=1
    # 同一文件系统上 mv 是 rename, 不会再复制一份大二进制
    { chmod 755 -- "$SB_NEW_BIN" && mv -f -- "$SB_NEW_BIN" "$(env_path "$SB_BIN").new" \
        && mv -f -- "$(env_path "$SB_BIN").new" "$(env_path "$SB_BIN")"; } || { _sb_install_fail "安装 $SB_BIN 失败"; return 1; }

    _sb_say "[4/7] 生成配置并用官方 check 校验"
    _a=$(txn_new_candidate "$(env_path "$SB_CONF")") || { _sb_install_fail "无法创建候选配置"; return 1; }
    sb_generate_config "$(state_instances_dir)" > "$_a" || { rm -f -- "$_a"; _sb_install_fail "生成配置失败"; return 1; }
    _snell_chown "root:$SB_GROUP" "$_a"
    chmod 640 -- "$_a"
    R_CONF=1
    TXN_NEW_MODE=640 txn_commit "$(env_path "$SB_CONF")" "$_a" core_singbox_check_config || { _sb_install_fail "配置未通过 sing-box check"; return 1; }

    _sb_say "[5/7] OpenRC 服务"
    R_INIT=1
    _sb_write_init || { _sb_install_fail "写入 $SB_INIT 失败"; return 1; }
    R_RCUPDATE=1
    _snell_run rc-update add sing-box default >/dev/null 2>&1 || { _sb_install_fail "rc-update add sing-box default 失败"; return 1; }

    _sb_say "[6/7] 启动并验证"
    R_STARTED=1
    if ! _sb_rc start >/dev/null 2>&1; then
        core_discover singbox
        _sb_show_failure
        _sb_install_fail "rc-service sing-box start 失败"
        return 1
    fi
    if ! _sb_wait_healthy; then
        _sb_show_failure
        _sb_install_fail "sing-box 没有在 $(_sb_wait_secs) 秒内进入健康状态 (运行中, 有服务进程, 实例端口监听)"
        return 1
    fi

    _sb_say "[7/7] 写入 Manager 元数据"
    _sb_write_meta "$_tag" "$SB_NEW_REPORTED" "$_cmark" "$_gmark" || { _sb_install_fail "写入元数据失败"; return 1; }

    _sb_say ""
    _sb_say "sing-box 安装完成并已验证"
    _sb_say "  release：$_tag (二进制自报 $SB_NEW_REPORTED)"
    _sb_say "  配置：$SB_CONF (由实例生成, 请用 proxy-manager sing-box add 管理, 不要手工编辑)"
    _sb_say "  日志：$SB_LOG_DIR"
    _sb_say "  添加实例：proxy-manager sing-box add anytls hysteria2 tuic 或 shadowsocks"
    trap - EXIT
    _snell_cleanup
}

# ---- 启停 ----

singbox_start() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    if [ "$CF_STATE" = running ]; then
        _sb_say "sing-box 已经在运行"
        return 0
    fi
    if ! _sb_rc start >/dev/null 2>&1; then
        core_discover singbox
        _sb_show_failure
        apm_err "rc-service sing-box start 失败"
        return 1
    fi
    _sb_wait_healthy || { _sb_show_failure; apm_err "sing-box 没有进入健康状态"; return 1; }
    _sb_say "sing-box 已启动并验证"
}

singbox_stop() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed yes || return 4
    if [ "$CF_STATE" = stopped ]; then
        _sb_say "sing-box 已经停止"
        return 0
    fi
    _sb_rc stop >/dev/null 2>&1 || { apm_err "rc-service sing-box stop 失败"; return 1; }
    _sb_wait_stopped || { apm_err "sing-box 没有停止"; return 1; }
    _sb_say "sing-box 已停止"
}

singbox_restart() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    if ! _sb_rc restart >/dev/null 2>&1; then
        core_discover singbox
        _sb_show_failure
        apm_err "rc-service sing-box restart 失败"
        return 1
    fi
    _sb_wait_healthy || { _sb_show_failure; apm_err "sing-box 重启后没有进入健康状态"; return 1; }
    _sb_say "sing-box 已重启并验证"
}

# check: 用官方 sing-box check 校验当前配置, 只读
singbox_check() {
    _sb_require_managed yes || return 4
    if core_singbox_check_config "$(env_path "$SB_CONF")"; then
        _sb_say "配置通过 sing-box check"
    else
        apm_err "配置未通过 sing-box check"
        return 1
    fi
}

# ---- 配置事务 ----

# 以实例目录 NEWDIR 生成新配置, 官方 check, 备份, 原子替换, 运行中则重启并验证, 失败恢复旧配置与服务
# 返回 0 成功, 1 失败 (已说明原因并恢复)
_sb_commit_instances() { # NEWDIR WAS_RUNNING
    local _cand _rc _cfg
    _cfg=$(env_path "$SB_CONF")
    _cand=$(txn_new_candidate "$_cfg") || { apm_err "无法创建候选配置"; return 1; }
    sb_generate_config "$1" > "$_cand" || { rm -f -- "$_cand"; apm_err "生成配置失败"; return 1; }
    _snell_chown "root:$SB_GROUP" "$_cand"
    chmod 640 -- "$_cand"
    APM_BACKUP_KEEP=${APM_BACKUP_KEEP:-2}
    export APM_BACKUP_KEEP
    SB_HEALTH_DIR=$1
    if [ "$2" = running ]; then
        txn_commit "$_cfg" "$_cand" core_singbox_check_config _sb_reload_verify
    else
        txn_commit "$_cfg" "$_cand" core_singbox_check_config
    fi
    _rc=$?
    SB_HEALTH_DIR=
    case $_rc in
        0) return 0 ;;
        12)
            apm_err "新配置下 sing-box 没有进入健康状态, 已恢复旧配置"
            _sb_say "正在用旧配置重新启动"
            if _sb_reload_verify; then
                _sb_say "已恢复旧配置并验证 sing-box 正常运行"
            else
                _sb_show_failure
                apm_err "恢复旧配置后 sing-box 仍不健康, 请查看日志"
            fi
            return 1
            ;;
        10) apm_err "新配置未通过 sing-box check, 当前配置未改动"; return 1 ;;
        *) apm_err "配置更新失败 (代码 $_rc)"; return 1 ;;
    esac
}

# 复制当前实例到 staging 作为可修改的提案目录
_sb_propose_dir() {
    local _d _f
    _snell_ensure_staging || return 1
    _d=$SNELL_STAGING/instances
    rm -rf -- "$_d"
    mkdir -p -- "$_d" || return 1
    chmod 700 -- "$_d"
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        cp -p -- "$_f" "$_d/" || return 1
    done
    # 原样保留一份, 保存实例失败时用它恢复旧配置
    rm -rf -- "$SNELL_STAGING/instances.orig"
    mkdir -p -- "$SNELL_STAGING/instances.orig" || return 1
    chmod 700 -- "$SNELL_STAGING/instances.orig"
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        cp -p -- "$_f" "$SNELL_STAGING/instances.orig/" || return 1
    done
    printf '%s' "$_d"
}

# 成功后把提案目录同步为正式实例目录: 安装新增与修改的, 删除已不存在的
_sb_sync_instances() { # NEWDIR
    local _f _id
    state_ensure_dirs || return 1
    for _f in $(state_list_confs "$1"); do
        atomic_install "$_f" "$(state_instances_dir)/${_f##*/}" 600 || return 1
    done
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _id=${_f##*/}
        [ -e "$1/$_id" ] || rm -f -- "$_f"
    done
}

# 配置已经提交后保存实例文件, 保存失败则把配置与服务恢复为旧实例, 不留下配置与实例不一致的状态
_sb_finish() { # NEWDIR WAS_STATE
    if _sb_sync_instances "$1"; then
        return 0
    fi
    apm_err "保存实例失败, 正在恢复旧配置"
    _sb_sync_instances "$SNELL_STAGING/instances.orig" >/dev/null 2>&1
    _sb_commit_instances "$SNELL_STAGING/instances.orig" "$2" >/dev/null 2>&1
    return 1
}

# 生成自签名证书对, 输出写到 CRT 与 KEY, 通过已确认为 ELF 的 sing-box generate tls-keypair
_sb_gen_tls() { # SNI CRT KEY
    local _bin _tmp
    _bin=$(core_trusted_binary singbox) || { apm_err "没有已确认的 sing-box 可用于生成证书"; return 1; }
    _snell_ensure_staging || return 1
    _tmp=$SNELL_STAGING/kp.pem
    ( umask 077; "$_bin" generate tls-keypair "$1" -m 120 > "$_tmp" 2>/dev/null ) || { rm -f -- "$_tmp"; apm_err "生成证书失败"; return 1; }
    ( umask 077
      awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$_tmp" > "$3"
      awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$_tmp" > "$2" ) || { rm -f -- "$_tmp"; return 1; }
    rm -f -- "$_tmp"
    if ! { grep -q 'BEGIN PRIVATE KEY' "$3" && grep -q 'BEGIN CERTIFICATE' "$2"; }; then
        apm_err "生成的证书无效"
        return 1
    fi
    chmod 640 -- "$2" "$3"
    _snell_chown "root:$SB_GROUP" "$2" "$3"
}

# ---- 实例命令 ----

# add TYPE [--name ID] [--port N | --listen ADDR] [--password-stdin]
#   TLS 协议 (anytls hysteria2 tuic) 另有 [--server-name NAME]
#   tuic 另有 [--uuid UUID] [--congestion-control cubic|new_reno|bbr]
#   shadowsocks 另有 [--method METHOD]
singbox_add() {
    local _type _name _port _listen _sni _pwmode _pw _dir _id _crt _key _f _was _a _p _prefix _transport
    local _uuid _cc _method _kind _tls _pr _bad
    _type=${1:-}
    [ -n "$_type" ] || { apm_err "用法: sing-box add $SB_TYPES [选项]"; return 2; }
    shift
    _sb_type_valid "$_type" || { apm_err "不支持的协议: $_type (支持 $SB_TYPES)"; return 2; }
    _prefix=$(_sb_type_prefix "$_type")
    _transport=$(_sb_type_transport "$_type")
    _tls=no
    _sb_type_tls "$_type" && _tls=yes
    _name=
    _port=
    _listen=::
    _sni=$SB_DEFAULT_SNI
    _pwmode=generate
    _uuid=
    _cc=
    _method=
    [ "$_type" != shadowsocks ] || _method=$SB_SS_DEFAULT_METHOD
    _bad=
    while [ $# -gt 0 ]; do
        case $1 in
            --name) [ $# -ge 2 ] || { apm_err "--name 需要参数"; return 2; }; _name=$2; shift ;;
            --port) [ $# -ge 2 ] || { apm_err "--port 需要参数"; return 2; }; _port=$2; shift ;;
            --listen) [ $# -ge 2 ] || { apm_err "--listen 需要参数"; return 2; }; _listen=$2; shift ;;
            --server-name)
                [ $# -ge 2 ] || { apm_err "--server-name 需要参数"; return 2; }
                [ "$_tls" = yes ] || { apm_err "$_type 不使用 TLS, 没有 --server-name"; return 2; }
                _sni=$2; shift ;;
            --password-stdin) _pwmode=stdin ;;
            --uuid)
                [ $# -ge 2 ] || { apm_err "--uuid 需要参数"; return 2; }
                [ "$_type" = tuic ] || { apm_err "只有 tuic 有 --uuid"; return 2; }
                _uuid=$2; shift ;;
            --congestion-control)
                [ $# -ge 2 ] || { apm_err "--congestion-control 需要参数"; return 2; }
                [ "$_type" = tuic ] || { apm_err "只有 tuic 有 --congestion-control"; return 2; }
                _cc=$2; shift ;;
            --method)
                [ $# -ge 2 ] || { apm_err "--method 需要参数"; return 2; }
                [ "$_type" = shadowsocks ] || { apm_err "只有 shadowsocks 有 --method"; return 2; }
                _method=$2; shift ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    [ -z "$_name" ] || is_ident "$_name" || { apm_err "名称无效: $_name"; return 2; }
    [ -z "$_port" ] || _snell_valid_port "$_port" || { apm_err "端口无效: $_port (需要 1025 到 65535)"; return 2; }
    is_listen_addr "$_listen" || { apm_err "listen 无效: $_listen"; return 2; }
    [ "$_tls" = no ] || _sb_valid_sni "$_sni" || { apm_err "server-name 无效: $_sni"; return 2; }
    [ -z "$_uuid" ] || _sb_valid_uuid "$_uuid" || { apm_err "uuid 无效 (需要小写的标准 UUID 格式)"; return 2; }
    [ -z "$_cc" ] || _sb_tuic_cc_valid "$_cc" || { apm_err "congestion-control 无效 (允许 $SB_TUIC_CC)"; return 2; }
    [ "$_type" != shadowsocks ] || _sb_ss_method_valid "$_method" || { apm_err "method 不在允许的取值内 ($SB_SS_METHODS)"; return 2; }
    _kind=$(_sb_secret_kind "$_type" "$_method")
    _pw=
    if [ "$_pwmode" = stdin ]; then
        IFS= read -r _pw || _pw=
        _sb_valid_secret "$_kind" "$_pw" || { apm_err "从标准输入读取的密码无效 ($(_sb_secret_hint "$_kind"))"; return 2; }
    fi
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    _was=$CF_STATE
    state_ensure_dirs || return 1
    # 必须在当前 shell 里创建 staging, 命令替换里创建的目录不会被 EXIT 清理
    _snell_ensure_staging || return 1
    _dir=$(_sb_propose_dir) || return 1
    if [ -n "$_name" ]; then
        _id=$_name
        if [ -e "$_dir/$_id.conf" ]; then
            apm_err "实例 $_id 已存在"
            return 1
        fi
    else
        _id=$(_sb_next_id "$_dir" "$_prefix") || { apm_err "没有可用的实例编号"; return 1; }
    fi
    if [ -z "$_port" ]; then
        _a=0
        while [ "$_a" -lt 30 ]; do
            _p=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')
            _p=$((10240 + _p % 21760))
            if _sb_check_ports "$_dir" "$_type" "$_p" "$_listen" "" yes >/dev/null 2>&1; then
                _port=$_p
                break
            fi
            _a=$((_a + 1))
        done
        [ -n "$_port" ] || { apm_err "无法选出可用的随机端口"; return 1; }
    else
        # 要求多个传输层的协议 (shadowsocks) 任何一个传输层冲突都整体拒绝
        _sb_check_ports "$_dir" "$_type" "$_port" "$_listen" "" yes || return 1
    fi
    [ "$_pwmode" = stdin ] || _pw=$(_sb_gen_secret "$_kind") || { apm_err "生成密码失败 (/dev/urandom 不可用?)"; return 1; }
    if [ "$_type" = tuic ] && [ -z "$_uuid" ]; then
        _uuid=$(_sb_gen_uuid) || { apm_err "生成 UUID 失败"; return 1; }
    fi

    _crt=
    _key=
    if [ "$_tls" = yes ]; then
        _crt=$SB_TLS_DIR/$_id.crt
        _key=$SB_TLS_DIR/$_id.key
        _sb_gen_tls "$_sni" "$(env_path "$_crt")" "$(env_path "$_key")" || { rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"; return 1; }
    fi
    _f=$_dir/$_id.conf
    (
        umask 077
        printf 'id=%s\nname=%s\ntype=%s\nenabled=true\nlisten=%s\nlisten_port=%s\n' "$_id" "$_id" "$_type" "$_listen" "$_port"
        case $_type in
            tuic) printf 'credential.uuid=%s\n' "$_uuid" ;;
            shadowsocks) printf 'credential.method=%s\n' "$_method" ;;
        esac
        printf 'credential.password=%s\n' "$_pw"
        if [ "$_tls" = yes ]; then
            printf 'tls.mode=self-signed\ntls.server_name=%s\ntls.certificate_path=%s\ntls.key_path=%s\n' "$_sni" "$_crt" "$_key"
        fi
        printf 'transport.type=%s\n' "$_transport"
        [ -z "$_cc" ] || printf 'transport.congestion_control=%s\n' "$_cc"
    ) > "$_f" || { [ -z "$_crt" ] || rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"; return 1; }
    if ! sb_instance_validate "$_f" >/dev/null 2>&1; then
        [ -z "$_crt" ] || rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"
        sb_instance_validate "$_f" 2>&1 | sed 's/^/  /' >&2
        apm_err "实例未通过校验"
        return 1
    fi
    if ! _sb_commit_instances "$_dir" "$_was"; then
        [ -z "$_crt" ] || rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"
        return 1
    fi
    if ! _sb_finish "$_dir" "$_was"; then
        [ -z "$_crt" ] || rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"
        return 1
    fi
    _sb_say "已添加实例 $_id"
    if [ "$_tls" = yes ]; then
        _sb_say "  协议：$_type ($_transport), 监听：$_listen 端口 $_port, 证书：自签名 (server-name $_sni)"
    else
        _sb_say "  协议：$_type ($_transport), 监听：$_listen 端口 $_port, 不使用 TLS"
    fi
    [ "$_type" != tuic ] || _sb_say "  UUID：$_uuid"
    [ -z "$_cc" ] || _sb_say "  拥塞控制：$_cc"
    [ "$_type" != shadowsocks ] || _sb_say "  method：$_method"
    if [ "$_pwmode" = generate ]; then
        _sb_say "  密码：$_pw"
        _sb_say "  这是自动生成的密码, 只在此处显示一次, 之后 proxy-manager 不会再显示它, 请自行保存"
    else
        _sb_say "  密码：已使用你提供的值"
    fi
    if [ "$_was" = running ]; then
        _sb_say "sing-box 已重启并验证"
    else
        _sb_say "sing-box 当前未运行, 配置已写入, 下次启动生效"
    fi
}

singbox_list() {
    local _f _any _st
    core_discover singbox
    _any=0
    printf 'sing-box 实例\n'
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _any=1
        if [ "$(kv_get "$_f" enabled)" = true ]; then
            _st=启用
            _sb_inst_listening "$_f" && _st="启用, 监听中"
        else
            _st=禁用
        fi
        printf '  %s  %s  %s  %s 端口 %s  %s\n' "$(kv_get "$_f" id)" "$(kv_get "$_f" type)" "$_st" "$(kv_get "$_f" listen)" "$(kv_get "$_f" listen_port)" \
            "$(if _sb_type_tls "$(kv_get "$_f" type)"; then printf 'SNI %s' "$(kv_get "$_f" tls.server_name)"; else printf 'method %s' "$(kv_get "$_f" credential.method)"; fi)"
    done
    [ "$_any" = 1 ] || printf '  (没有实例)\n'
}

singbox_show() {
    local _f _p _t
    [ -n "${1:-}" ] || { apm_err "用法: sing-box show 实例ID"; return 2; }
    _f=$(state_instances_dir)/$1.conf
    [ -f "$_f" ] || { apm_err "实例 $1 不存在"; return 1; }
    core_discover singbox
    _t=$(kv_get "$_f" type)
    printf '实例 %s\n' "$1"
    printf '  类型：%s\n' "$_t"
    printf '  传输层：%s\n' "$(_sb_type_transport "$_t")"
    printf '  启用：%s\n' "$(kv_get "$_f" enabled)"
    printf '  监听：%s\n' "$(kv_get "$_f" listen)"
    printf '  端口：%s\n' "$(kv_get "$_f" listen_port)"
    if _sb_type_tls "$_t"; then
        printf '  server-name：%s\n' "$(kv_get "$_f" tls.server_name)"
        printf '  TLS：%s (证书 %s)\n' "$(kv_get "$_f" tls.mode)" "$(kv_get "$_f" tls.certificate_path)"
    else
        printf '  TLS：不使用\n'
    fi
    # UUID 是用户标识不是密钥, 可以显示, 密码与密钥一律只显示已配置
    [ "$_t" != tuic ] || printf '  UUID：%s\n' "$(kv_get "$_f" credential.uuid)"
    if [ "$_t" = tuic ]; then
        _p=$(kv_get "$_f" transport.congestion_control)
        printf '  拥塞控制：%s\n' "${_p:-默认 (cubic)}"
    fi
    [ "$_t" != shadowsocks ] || printf '  method：%s\n' "$(kv_get "$_f" credential.method)"
    if [ -n "$(kv_get "$_f" credential.password)" ]; then
        printf '  密码：已配置\n'
    else
        printf '  密码：未配置\n'
    fi
    for _p in $(_sb_type_protos "$_t"); do
        if _sb_listening "$_p" "$(kv_get "$_f" listen_port)"; then
            printf '  内部 %s Listener：正常\n' "$(_sb_proto_label "$_p")"
        else
            printf '  内部 %s Listener：未监听\n' "$(_sb_proto_label "$_p")"
        fi
    done
    _sb_policy_show "$_f"
    printf '  说明：这是容器或系统内部的监听状态, 公网可达性 (NAT 与防火墙) 没有验证\n'
}

# 通用: 以提案目录修改后提交
# singbox_change ID ACTION ...  ACTION: enable disable delete set
# set 的键: port listen server-name(TLS 协议) password uuid(tuic) congestion-control(tuic) method(shadowsocks)
#   password 与 method 的密钥参数 --stdin 或 --generate, 密钥格式取决于协议与 method
singbox_change() {
    local _id _action _dir _f _was _key _val _crt _key_path _old_crt _old_key _bk _p _t
    local _secmode _method _kind _newm _cur _curkind _ok
    _id=${1:-}
    _action=${2:-}
    if [ -z "$_id" ] || [ -z "$_action" ]; then
        apm_err "用法: sing-box enable|disable|delete|set 实例ID ..."
        return 2
    fi
    shift 2
    GENERATED_PW=
    GENERATED_UUID=
    _val=
    _key=
    _secmode=
    if [ "$_action" = set ]; then
        _key=${1:-}
        shift
        case $_key in
            port) _val=${1:-}; _snell_valid_port "$_val" || { apm_err "端口无效 (需要 1025 到 65535)"; return 2; } ;;
            listen) _val=${1:-}; is_listen_addr "$_val" || { apm_err "listen 无效"; return 2; } ;;
            server-name) _val=${1:-}; _sb_valid_sni "$_val" || { apm_err "server-name 无效"; return 2; } ;;
            congestion-control) _val=${1:-}; _sb_tuic_cc_valid "$_val" || { apm_err "congestion-control 无效 (允许 $SB_TUIC_CC)"; return 2; } ;;
            uuid)
                _val=${1:-}
                if [ "$_val" = --generate ]; then
                    _val=$(_sb_gen_uuid) || { apm_err "生成 UUID 失败"; return 1; }
                    GENERATED_UUID=$_val
                fi
                _sb_valid_uuid "$_val" || { apm_err "uuid 无效 (需要小写的标准 UUID 格式, 或 --generate)"; return 2; }
                ;;
            password)
                case ${1:-} in
                    --stdin) _secmode=stdin; IFS= read -r _val || _val= ;;
                    --generate) _secmode=generate ;;
                    *) apm_err "密码不接受命令行明文参数, 请使用 --stdin 或 --generate"; return 2 ;;
                esac
                ;;
            method)
                _val=${1:-}
                _sb_ss_method_valid "$_val" || { apm_err "method 不在允许的取值内 ($SB_SS_METHODS)"; return 2; }
                case ${2:-} in
                    --stdin) _secmode=stdin; IFS= read -r _newm || _newm=; ;;
                    --generate) _secmode=generate ;;
                    '') ;;
                    *) apm_err "method 之后只接受 --stdin 或 --generate 来同时更换密钥"; return 2 ;;
                esac
                ;;
            *) apm_err "不支持的键: $_key (支持 port listen server-name password uuid congestion-control method)"; return 2 ;;
        esac
    fi
    case $_action in enable|disable|delete|set) ;; *) apm_err "未知操作: $_action"; return 2 ;; esac
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    _was=$CF_STATE
    _snell_ensure_staging || return 1
    _dir=$(_sb_propose_dir) || return 1
    _f=$_dir/$_id.conf
    [ -f "$_f" ] || { apm_err "实例 $_id 不存在"; return 1; }
    _t=$(kv_get "$_f" type)
    _crt=$(kv_get "$_f" tls.certificate_path)
    _key_path=$(kv_get "$_f" tls.key_path)
    _old_crt=
    _old_key=
    # 键与协议的匹配
    if [ "$_action" = set ]; then
        case $_key in
            server-name) _sb_type_tls "$_t" || { apm_err "$_t 不使用 TLS, 没有 server-name"; return 2; } ;;
            uuid|congestion-control) [ "$_t" = tuic ] || { apm_err "只有 tuic 有 $_key"; return 2; } ;;
            method) [ "$_t" = shadowsocks ] || { apm_err "只有 shadowsocks 有 method"; return 2; } ;;
        esac
    fi
    case $_action in
        enable) _sb_inst_set "$_f" enabled true ;;
        disable) _sb_inst_set "$_f" enabled false ;;
        delete) rm -f -- "$_f" ;;
        set)
            case $_key in
                port)
                    _sb_check_ports "$_dir" "$_t" "$_val" "$(kv_get "$_f" listen)" "$_id" "$([ "$_val" != "$(kv_get "$_f" listen_port)" ] && echo yes || echo no)" || return 1
                    _sb_inst_set "$_f" listen_port "$_val"
                    ;;
                listen)
                    _sb_check_ports "$_dir" "$_t" "$(kv_get "$_f" listen_port)" "$_val" "$_id" no || return 1
                    _sb_inst_set "$_f" listen "$_val"
                    ;;
                congestion-control) _sb_inst_set "$_f" transport.congestion_control "$_val" ;;
                uuid) _sb_inst_set "$_f" credential.uuid "$_val" ;;
                password)
                    _kind=$(_sb_secret_kind "$_t" "$(kv_get "$_f" credential.method)")
                    if [ "$_secmode" = generate ]; then
                        _val=$(_sb_gen_secret "$_kind") || { apm_err "生成密码失败"; return 1; }
                        GENERATED_PW=$_val
                    fi
                    _sb_valid_secret "$_kind" "$_val" || { apm_err "密码无效 ($(_sb_secret_hint "$_kind"))"; return 2; }
                    _sb_inst_set "$_f" credential.password "$_val"
                    ;;
                method)
                    # 不同 method 的密钥格式不通用, 绝不做不可见的转换:
                    # 新 method 与当前密钥兼容才保留, 否则必须同时用 --generate 或 --stdin 更换密钥
                    _kind=$(_sb_secret_kind shadowsocks "$_val")
                    _cur=$(kv_get "$_f" credential.password)
                    case $_secmode in
                        generate) _cur=$(_sb_gen_secret "$_kind") || { apm_err "生成密钥失败"; return 1; }; GENERATED_PW=$_cur ;;
                        stdin)
                            _sb_valid_secret "$_kind" "$_newm" || { apm_err "从标准输入读取的密钥不符合 $_val 的要求 ($(_sb_secret_hint "$_kind"))"; return 2; }
                            _cur=$_newm
                            ;;
                        *)
                            if ! _sb_valid_secret "$_kind" "$_cur"; then
                                apm_err "当前密钥不符合 $_val 的要求 ($(_sb_secret_hint "$_kind")), 请在 method 之后加 --generate 或 --stdin 同时更换密钥"
                                return 2
                            fi
                            ;;
                    esac
                    _sb_inst_set "$_f" credential.method "$_val"
                    [ "$_secmode" = "" ] || _sb_inst_set "$_f" credential.password "$_cur"
                    ;;
                server-name)
                    # 更换证书: 先把旧证书放到 staging, 失败时放回
                    _bk=$SNELL_STAGING/oldtls
                    mkdir -p -- "$_bk"
                    if ! { cp -p -- "$(env_path "$_crt")" "$_bk/crt" && cp -p -- "$(env_path "$_key_path")" "$_bk/key"; }; then
                        apm_err "备份旧证书失败"
                        return 1
                    fi
                    _sb_gen_tls "$_val" "$(env_path "$_crt")" "$(env_path "$_key_path")" || {
                        cp -p -- "$_bk/crt" "$(env_path "$_crt")"; cp -p -- "$_bk/key" "$(env_path "$_key_path")"; return 1; }
                    _sb_inst_set "$_f" tls.server_name "$_val"
                    _old_crt=$_bk/crt
                    _old_key=$_bk/key
                    ;;
            esac
            ;;
    esac
    if [ "$_action" != delete ] && ! sb_instance_validate "$_f" >/dev/null 2>&1; then
        sb_instance_validate "$_f" 2>&1 | sed 's/^/  /' >&2
        apm_err "修改后的实例未通过校验"
        [ -z "$_old_crt" ] || { cp -p -- "$_old_crt" "$(env_path "$_crt")"; cp -p -- "$_old_key" "$(env_path "$_key_path")"; }
        return 1
    fi
    if ! _sb_commit_instances "$_dir" "$_was"; then
        [ -z "$_old_crt" ] || { cp -p -- "$_old_crt" "$(env_path "$_crt")"; cp -p -- "$_old_key" "$(env_path "$_key_path")"; }
        return 1
    fi
    if ! _sb_finish "$_dir" "$_was"; then
        [ -z "$_old_crt" ] || { cp -p -- "$_old_crt" "$(env_path "$_crt")"; cp -p -- "$_old_key" "$(env_path "$_key_path")"; }
        return 1
    fi
    if [ "$_action" = delete ] && [ -n "$_crt" ]; then
        rm -f -- "$(env_path "$_crt")" "$(env_path "$_key_path")"
    fi
    case $_action in
        enable) _sb_say "实例 $_id 已启用" ;;
        disable) _sb_say "实例 $_id 已禁用" ;;
        delete) _sb_say "实例 $_id 已删除" ;;
        set)
            case $_key in
                password)
                    _sb_say "实例 $_id 的密码已更新"
                    if [ -n "$GENERATED_PW" ]; then
                        _sb_say "  新密码：$GENERATED_PW"
                        _sb_say "  这是自动生成的密码, 只在此处显示一次, 请自行保存"
                    fi
                    ;;
                method)
                    _sb_say "实例 $_id 的 method 已更新为 $_val"
                    if [ -n "$GENERATED_PW" ]; then
                        _sb_say "  新密码：$GENERATED_PW"
                        _sb_say "  这是自动生成的密码, 只在此处显示一次, 请自行保存"
                    elif [ "$_secmode" = stdin ]; then
                        _sb_say "  密码已更换为你提供的值"
                    else
                        _sb_say "  原密钥与新 method 兼容, 已保留"
                    fi
                    ;;
                uuid)
                    _sb_say "实例 $_id 的 uuid 已更新为 $_val"
                    ;;
                *) _sb_say "实例 $_id 的 $_key 已更新为 $_val" ;;
            esac
            ;;
    esac
    if [ "$_was" = running ]; then
        _sb_say "sing-box 已重启并验证"
    else
        _sb_say "sing-box 当前未运行, 配置已写入, 下次启动生效"
    fi
}

# 目标访问限制的展示, 实例文件没有任何 relay_access 键就是不限制
_sb_policy_show() { # FILE
    local _d
    if ! _sb_policy_present "$1"; then
        printf '  目标访问限制：未启用\n'
        return 0
    fi
    if ! _sb_policy_check "$1" >/dev/null 2>&1; then
        printf '  目标访问限制：配置无效, 生成配置会被拒绝 (不会退回不限制)\n'
        return 0
    fi
    if ! _sb_policy_on "$1"; then
        printf '  目标访问限制：未启用\n'
        return 0
    fi
    printf '  目标访问限制：Allowlist\n'
    if [ -z "$(_sb_policy_dests "$1")" ]; then
        printf '  允许目标：(空) 当前 allowlist 为空, 所有目标将被拒绝\n'
    else
        printf '  允许目标：\n'
        for _d in $(_sb_policy_dests "$1"); do
            printf '    %s\n' "$_d"
        done
    fi
    printf '  默认动作：拒绝\n'
}

# access ID [show] | unrestricted | allowlist | add HOST PORT | delete HOST PORT | clear
# 跨协议通用, 只改实例文件里的 relay_access 键, 沿用实例事务, 失败回滚到旧实例与旧配置
singbox_access() {
    local _id _act _f _dir _was _norm _d _n _max _k _v _msg _tmpf
    _id=${1:-}
    [ -n "$_id" ] || { apm_err "用法: sing-box access 实例ID [show|unrestricted|allowlist|add 地址 端口|delete 地址 端口|clear]"; return 2; }
    shift
    _act=${1:-show}
    [ $# -eq 0 ] || shift
    _f=$(state_instances_dir)/$_id.conf
    [ -f "$_f" ] || { apm_err "实例 $_id 不存在"; return 1; }
    case $_act in
        show)
            [ $# -eq 0 ] || { apm_err "show 不需要参数"; return 2; }
            printf '实例 %s\n' "$_id"
            _sb_policy_show "$_f"
            return 0
            ;;
        unrestricted|allowlist|clear)
            [ $# -eq 0 ] || { apm_err "$_act 不需要参数"; return 2; }
            ;;
        add|delete)
            [ $# -eq 2 ] || { apm_err "用法: sing-box access $_id $_act 地址 端口"; return 2; }
            _norm=$(_sb_dest_normalize "$1" "$2") || { apm_err "$SB_DEST_ERR"; return 2; }
            ;;
        *) apm_err "未知的 access 操作: $_act"; return 2 ;;
    esac
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed no || return 4
    _was=$CF_STATE
    _snell_ensure_staging || return 1
    _dir=$(_sb_propose_dir) || return 1
    _f=$_dir/$_id.conf
    _msg=
    case $_act in
        unrestricted)
            if ! _sb_policy_present "$_f"; then
                _sb_say "实例 $_id 已经不限制目标, 没有改动"
                return 0
            fi
            _sb_inst_unset "$_f" relay_access. || return 1
            ;;
        allowlist)
            if _sb_policy_check "$_f" >/dev/null 2>&1 && _sb_policy_on "$_f"; then
                _sb_say "实例 $_id 已经是 allowlist, 没有改动"
                return 0
            fi
            # 从无到有或修复无效配置: 只保留合法的目标, 重新写入完整的声明
            _sb_inst_unset "$_f" relay_access.enabled || return 1
            _sb_inst_set "$_f" relay_access.enabled true || return 1
            _sb_inst_set "$_f" relay_access.mode allowlist || return 1
            _sb_inst_set "$_f" relay_access.default_action reject || return 1
            ;;
        clear)
            _sb_policy_on "$_f" || { apm_err "实例 $_id 当前不是 allowlist, 没有目标可清空"; return 2; }
            _sb_inst_unset "$_f" relay_access.destination. || return 1
            ;;
        add|delete)
            _sb_policy_on "$_f" || { apm_err "实例 $_id 当前不限制目标, 请先执行 sing-box access $_id allowlist"; return 2; }
            _n=
            _max=0
            for _k in $(kv_keys "$_f" | grep '^relay_access\.destination\.'); do
                _v=$(kv_get "$_f" "$_k")
                [ "$_v" != "$_norm" ] || _n=$_k
                _d=${_k#relay_access.destination.}
                is_uint "$_d" && [ "$_d" -gt "$_max" ] && _max=$_d
            done
            if [ "$_act" = add ]; then
                [ -z "$_n" ] || { apm_err "目标 $_norm 已经在 allowlist 里"; return 1; }
                _sb_inst_set "$_f" "relay_access.destination.$((_max + 1))" "$_norm" || return 1
            else
                [ -n "$_n" ] || { apm_err "目标 $_norm 不在 allowlist 里"; return 1; }
                _sb_inst_unset "$_f" "$_n" || return 1
            fi
            ;;
    esac
    if ! sb_instance_validate "$_f" >/dev/null 2>&1; then
        sb_instance_validate "$_f" 2>&1 | sed 's/^/  /' >&2
        apm_err "修改后的实例未通过校验"
        return 1
    fi
    _sb_commit_instances "$_dir" "$_was" || return 1
    _sb_finish "$_dir" "$_was" || return 1
    case $_act in
        unrestricted) _sb_say "实例 $_id 已改为不限制目标" ;;
        allowlist) _sb_say "实例 $_id 已启用目标访问限制 (allowlist), 白名单之外的目标一律拒绝" ;;
        clear) _sb_say "实例 $_id 的 allowlist 已清空" ;;
        add) _sb_say "实例 $_id 已允许目标 $_norm" ;;
        delete) _sb_say "实例 $_id 已移除目标 $_norm" ;;
    esac
    if [ "$_act" != unrestricted ] && [ -z "$(_sb_policy_dests "$_f")" ]; then
        _sb_say "  注意: 当前 allowlist 为空, 所有目标将被拒绝"
    fi
    if [ "$_was" = running ]; then
        _sb_say "sing-box 已重启并验证"
    else
        _sb_say "sing-box 当前未运行, 配置已写入, 下次启动生效"
    fi
}

# ---- update ----

singbox_update() {
    local _release _tag _force _cur_exact _was _bin _old _rc _new_reported _v
    _release=$SINGBOX_DEFAULT_RELEASE
    _force=0
    while [ $# -gt 0 ]; do
        case $1 in
            --force) _force=1 ;;
            v[0-9]*|[0-9]*) _release=$1 ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _tag=$(_sb_norm_release "$_release")
    _sb_valid_release "$_tag" || { apm_err "release 格式无效: $_release (示例 v1.13.14)"; return 2; }
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _sb_require_managed yes || return 4
    _cur_exact=$CF_VERSION_EXACT
    _sb_say "当前 release：$_cur_exact (二进制自报 ${CF_VERSION_REPORTED:-未知})"
    _sb_say "目标 release：$_tag"
    if [ "$_cur_exact" = "$_tag" ] && [ "$_force" = 0 ] && [ "$CF_STATE" != broken ]; then
        _sb_say "已经是目标版本, 无需更新 (--force 可强制重装二进制)"
        return 0
    fi
    _was=$CF_SERVICE_STATE
    _sb_stage_release "$_tag" || { apm_err "更新已中止, 现有版本未改动"; return 1; }
    _new_reported=$SB_NEW_REPORTED
    # 用新二进制对当前配置执行 check, 不兼容就拒绝升级, 绝不先替换再发现不兼容
    _sb_say "用新二进制检查当前配置"
    if ! "$SB_NEW_BIN" check -c "$(env_path "$SB_CONF")" >/dev/null 2>&1; then
        "$SB_NEW_BIN" check -c "$(env_path "$SB_CONF")" 2>&1 | sed 's/^/    /' >&2
        apm_err "新版本 $_tag 无法通过当前配置的 sing-box check, 拒绝升级, 现有版本未改动"
        return 1
    fi
    _bin=$(env_path "$SB_BIN")
    _old=$_bin.old
    if [ "$_was" = started ]; then
        if ! _sb_rc stop >/dev/null 2>&1 || ! _sb_wait_stopped; then
            apm_err "停止 sing-box 失败, 更新已中止, 现有版本未改动"
            _sb_rc start >/dev/null 2>&1
            return 1
        fi
    fi
    # rename 而不是复制, 不额外占用一份二进制大小的磁盘
    if ! { mv -f -- "$_bin" "$_old" && chmod 755 -- "$SB_NEW_BIN" && mv -f -- "$SB_NEW_BIN" "$_bin"; }; then
        apm_err "替换二进制失败, 恢复旧版本"
        [ -f "$_old" ] && mv -f -- "$_old" "$_bin"
        [ "$_was" != started ] || { _sb_rc start >/dev/null 2>&1; _sb_wait_healthy; }
        return 1
    fi
    _rc=0
    if [ "$_was" = started ]; then
        _sb_rc start >/dev/null 2>&1 || _rc=1
        [ "$_rc" = 0 ] && { _sb_wait_healthy || _rc=1; }
    else
        _v=$(_core_timeout "$_bin" version 2>&1 | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n 1)
        [ -n "$_v" ] || _rc=1
    fi
    if [ "$_rc" = 0 ] && _sb_update_meta "$_tag" "$_new_reported"; then
        rm -f -- "$_old"
        _sb_say "更新完成并已验证: $_cur_exact -> $_tag (二进制自报 $_new_reported)"
        return 0
    fi
    apm_err "新版本验证失败, 回滚到旧版本"
    core_discover singbox
    _sb_show_failure
    _sb_rc stop >/dev/null 2>&1
    if mv -f -- "$_old" "$_bin"; then
        if [ "$_was" = started ]; then
            if _sb_rc start >/dev/null 2>&1 && _sb_wait_healthy; then
                _sb_say "已回滚并恢复运行: $_cur_exact"
            else
                apm_err "回滚后仍无法启动, 请查看日志"
            fi
        else
            _sb_say "已回滚到旧二进制 (更新前未在运行)"
        fi
    else
        apm_err "恢复旧二进制失败, 备份保留在 $_old"
    fi
    return 1
}

# ---- uninstall ----

singbox_uninstall() {
    local _purge _cu _cg _f
    _purge=0
    while [ $# -gt 0 ]; do
        case $1 in
            --purge) _purge=1 ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    core_discover singbox
    if [ "$CF_INSTALLED" = no ] && [ "$CF_META_STATE" = none ] && [ -z "$CF_SERVICE" ]; then
        _sb_say "sing-box 未安装, 无需卸载"
        return 0
    fi
    if [ "$CF_INSTALLED" = no ] && [ "$CF_META_STATE" = valid ] && [ "$(kv_get "$(core_meta_file singbox)" managed)" = true ]; then
        _sb_say "二进制已不存在, 清理 Manager 记录的残留"
    else
        _sb_require_managed yes || return 4
    fi
    _cu=$(kv_get "$(core_meta_file singbox)" created_user)
    _cg=$(kv_get "$(core_meta_file singbox)" created_group)
    if [ "$CF_STATE" = running ] || [ "$CF_STATE" = crashed ] || [ "$CF_SERVICE_STATE" = started ] || [ -n "$CF_PID" ]; then
        _sb_rc stop >/dev/null 2>&1 || { apm_err "停止 sing-box 失败, 卸载已中止, 没有删除任何文件"; return 1; }
        _sb_wait_stopped || { apm_err "sing-box 没有停止, 卸载已中止, 没有删除任何文件"; return 1; }
    fi
    _snell_run rc-update del sing-box default >/dev/null 2>&1
    if [ -f "$(env_path "$SB_INIT")" ]; then
        if grep -q "^$SB_INIT_MARK" "$(env_path "$SB_INIT")"; then
            rm -f -- "$(env_path "$SB_INIT")"
        else
            apm_warn "$SB_INIT 没有 Manager 标记, 已保留"
        fi
    fi
    rm -f -- "$(env_path "$SB_BIN")" "$(env_path "$SB_BIN").old" "$(env_path "$SB_BIN").new"
    if [ "$_purge" = 1 ]; then
        # 只删除有 Manager 标记的配置根, 没有标记说明不是 Manager 创建的, 保留
        if [ -f "$(env_path "$SB_MARK_FILE")" ]; then
            rm -rf -- "$(env_path "$SB_ETC")"
        else
            apm_warn "$SB_ETC 没有 Manager 标记, 已保留"
        fi
        rm -rf -- "$(env_path "$SB_LOG_DIR")" "$(env_path "$SB_WORK_DIR")"
        for _f in $(state_list_confs "$(state_instances_dir)"); do
            _sb_type_valid "$(kv_get "$_f" type)" && rm -f -- "$_f"
        done
        for _f in "$(state_backup_dir)"/config.json.bak.*; do
            [ -e "$_f" ] && rm -f -- "$_f"
        done
        if [ "$_cu" = yes ] && _sb_user_exists; then
            _snell_run deluser "$SB_USER" >/dev/null 2>&1 || apm_warn "删除用户 $SB_USER 失败, 已保留"
        fi
        if [ "$_cg" = yes ] && _sb_group_exists; then
            _snell_run delgroup "$SB_GROUP" >/dev/null 2>&1 || apm_warn "删除用户组 $SB_GROUP 失败, 已保留"
        fi
    fi
    for _f in "$(state_backup_dir)"/singbox.meta.bak.*; do
        [ -e "$_f" ] && rm -f -- "$_f"
    done
    rm -f -- "$(core_meta_file singbox)"
    _sb_say "sing-box 已卸载"
    if [ "$_purge" = 1 ]; then
        _sb_say "已删除: 服务, 二进制, 配置, 日志, 证书, 实例, 配置备份, 元数据 (以及由 Manager 创建的用户与用户组)"
    else
        _sb_say "已保留: 配置 $SB_ETC (含证书), 日志 $SB_LOG_DIR, 实例定义, 用户 $SB_USER (重新安装会沿用, sing-box uninstall --purge 才会删除)"
    fi
}

# ---- CLI ----

singbox_cli() {
    local _sub _id
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        status) report_singbox_status ;;
        info) report_singbox_info ;;
        log) report_singbox_log "${1:-20}" ;;
        install) singbox_install "$@" ;;
        start) singbox_start ;;
        stop) singbox_stop ;;
        restart) singbox_restart ;;
        check) singbox_check ;;
        update) singbox_update "$@" ;;
        uninstall) singbox_uninstall "$@" ;;
        add) singbox_add "$@" ;;
        list) singbox_list ;;
        show) singbox_show "$@" ;;
        access) singbox_access "$@" ;;
        enable|disable|delete)
            [ -n "${1:-}" ] || { apm_err "用法: sing-box $_sub 实例ID"; return 2; }
            singbox_change "$1" "$_sub"
            ;;
        set)
            [ -n "${1:-}" ] || { apm_err "用法: sing-box set 实例ID 键 值"; return 2; }
            _id=$1
            shift
            singbox_change "$_id" set "$@"
            ;;
        reload|adopt|migrate)
            apm_err "sing-box $_sub 尚未实现"
            return 3
            ;;
        *) apm_err "未知的 sing-box 子命令: $_sub"; return 2 ;;
    esac
}
