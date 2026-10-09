# shellcheck shell=sh
# shellcheck disable=SC2015,SC1003 # A && B || C 用来表达 "成功且健康, 否则失败"
# AnyTLS Gateway Core: 第三个独立 Core (Core key anytlsgw)
#
# 极简网关: 每个 Listener 是 AnyTLS 入站加一个固定的 SOCKS5 上游, 只转发 TCP
# 没有路由, DNS, UDP 处理, 管理接口, 也没有常驻的管理进程; 上游失败就关闭连接, 没有 DIRECT 路径
# 二进制 anytls-socks-gateway 是本项目维护的 Go 程序, 源码 构建脚本 许可证见 third_party/anytls-gateway
# 二进制与对应源码包发布在组件 Release anytls-gateway-v0.1.0, 固定版本加 SHA256
#
# 布局 (与现网部署的布局一致, 配置格式兼容)
#   二进制 /usr/local/bin/anytls-socks-gateway  服务 /etc/init.d/anytls-socks-gateway
#   配置 /etc/anytls-socks-gateway/config.json 证书 cert.pem key.pem  日志 /var/log/anytls-socks-gateway/
#   Manager 的事实来源 /etc/alpine-proxy-manager/anytlsgw.conf (listener 列表, 0600), config.json 由它生成
#   运行用户 anytlsgw (非 root), GOMEMLIMIT=16MiB GOGC=50 写在服务脚本里
#
# 测试接缝: APM_AGW_URL 覆盖下载地址, APM_AGW_SHA256 覆盖固定的校验和, APM_DOWNLOADER, APM_SNELL_WAIT
#
# 退出码: 0 成功, 1 失败, 2 用法错误, 4 被拒绝 (归属, 已存在)

AGW_VER="v0.1.0"
AGW_SHA256_X86_64="c5cf8ee64ea6cad4815ec2d21e2a866daee62f2f1c8c5b8ce366609bf3357bd5"
AGW_URL_DEFAULT="https://github.com/csjcsl666/alpine-proxy-manager/releases/download/anytls-gateway-v0.1.0/anytls-socks-gateway-v0.1.0-linux-x86_64"
AGW_USER="anytlsgw"
AGW_GROUP="anytlsgw"
AGW_BIN=/usr/local/bin/anytls-socks-gateway
AGW_CONF_DIR=/etc/anytls-socks-gateway
AGW_CONF=/etc/anytls-socks-gateway/config.json
AGW_CERT=/etc/anytls-socks-gateway/cert.pem
AGW_KEY=/etc/anytls-socks-gateway/key.pem
AGW_INIT=/etc/init.d/anytls-socks-gateway
AGW_LOG_DIR=/var/log/anytls-socks-gateway
AGW_INIT_MARK="# apm-managed: anytls-gateway"
AGW_MAX_LISTENERS=16

_agw_state() { printf '%s/anytlsgw.conf' "$(state_etc)"; }
_agw_rc() { _snell_run rc-service anytls-socks-gateway "$1"; }
_agw_group_exists() { grep -q "^$AGW_GROUP:" "$(env_path /etc/group)" 2>/dev/null; }
_agw_user_exists() { grep -q "^$AGW_USER:" "$(env_path /etc/passwd)" 2>/dev/null; }

# ---- 校验 ----

_agw_secret_ok() { # 可打印 ASCII, 不含引号与反斜杠 (要写进 JSON)
    _sb_socks_secret_ok "$1" || return 1
    case $1 in *'"'*|*'\'*) return 1 ;; esac
    return 0
}

_agw_pw_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{16,128}$'; }

_agw_gen_pw() {
    local _p
    _p=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24)
    [ "${#_p}" -eq 24 ] || return 1
    printf '%s' "$_p"
}

_agw_ids() { # FILE
    kv_keys "$1" | sed -n 's/^listener\.\([0-9][0-9]*\)\.listen$/\1/p' | sort -n
}

_agw_get() { kv_get "$1" "listener.$2.$3"; }

# 监听地址 addr:port, addr 为 IPv4 或方括号 IPv6, 端口 1025 到 65535
_agw_listen_ok() {
    local _h _p
    _p=${1##*:}
    _h=${1%:*}
    _snell_valid_port "$_p" || return 1
    case $_h in
        \[*\]) _sb_valid_ipv6_dest "${_h#\[}" 2>/dev/null || [ -n "${_h#\[}" ] ;;
        *) _sb_valid_ipv4_dest "$_h" ;;
    esac
}

# 校验事实来源文件, 逐条报告
_agw_check_state() { # FILE
    local _f _rc _id _k _seen _l _s _n
    _f=$1
    _rc=0
    [ -r "$_f" ] || { apm_err "$_f: 无法读取"; return 1; }
    kv_check_syntax "$_f" || return 1
    _seen=
    for _k in $(kv_keys "$_f"); do
        case $_k in
            next_id) ;;
            listener.[0-9]*.listen|listener.[0-9]*.password|listener.[0-9]*.socks_server|listener.[0-9]*.socks_username|listener.[0-9]*.socks_password) ;;
            *) apm_err "$_f: 未知的键: $_k"; _rc=1 ;;
        esac
    done
    _n=0
    for _id in $(_agw_ids "$_f"); do
        _n=$((_n + 1))
        _l=$(_agw_get "$_f" "$_id" listen)
        _agw_listen_ok "$_l" || { apm_err "$_f: listener $_id 的监听地址无效: $_l"; _rc=1; }
        case " $_seen " in *" ${_l##*:} "*) apm_err "$_f: 监听端口重复: ${_l##*:}"; _rc=1 ;; esac
        _seen="$_seen ${_l##*:}"
        _agw_pw_ok "$(_agw_get "$_f" "$_id" password)" || { apm_err "$_f: listener $_id 的 AnyTLS 密码无效"; _rc=1; }
        _s=$(_agw_get "$_f" "$_id" socks_server)
        _sb_socks_host_normalize "${_s%:*}" "${_s##*:}" >/dev/null 2>&1 || { apm_err "$_f: listener $_id 的 SOCKS5 地址无效: $_s"; _rc=1; }
        _agw_secret_ok "$(_agw_get "$_f" "$_id" socks_username)" && [ -n "$(_agw_get "$_f" "$_id" socks_username)" ] || { apm_err "$_f: listener $_id 的 SOCKS5 用户名无效"; _rc=1; }
        _agw_secret_ok "$(_agw_get "$_f" "$_id" socks_password)" && [ -n "$(_agw_get "$_f" "$_id" socks_password)" ] || { apm_err "$_f: listener $_id 的 SOCKS5 密码无效"; _rc=1; }
    done
    [ "$_n" -le "$AGW_MAX_LISTENERS" ] || { apm_err "$_f: listener 数量超过上限 $AGW_MAX_LISTENERS"; _rc=1; }
    return "$_rc"
}

# ---- 生成 config.json ----

agw_gen_json() { # STATE_FILE -> stdout
    local _f _id _first
    _f=$1
    printf '{\n  "tls": {\n    "cert_file": "%s",\n    "key_file": "%s"\n  },\n  "listeners": [' "$AGW_CERT" "$AGW_KEY"
    _first=1
    for _id in $(_agw_ids "$_f"); do
        [ "$_first" = 1 ] || printf ','
        _first=0
        printf '\n    {\n      "listen": "%s",\n      "password": "%s",\n      "socks5": {\n        "server": "%s",\n        "username": "%s",\n        "password": "%s"\n      }\n    }' \
            "$(_agw_get "$_f" "$_id" listen)" "$(_agw_get "$_f" "$_id" password)" "$(_agw_get "$_f" "$_id" socks_server)" \
            "$(_agw_get "$_f" "$_id" socks_username)" "$(_agw_get "$_f" "$_id" socks_password)"
    done
    printf '\n  ]\n}\n'
}

# 用网关自己的 -check 验证候选 config.json (不启动监听); 只执行已确认的 ELF
_agw_check_json() { # 候选文件
    local _b
    _b=$(env_path "$AGW_BIN")
    [ -x "$_b" ] && [ "$(core_file_kind "$_b")" = elf ] || { apm_err "网关二进制不存在或不是 ELF, 无法校验配置"; return 1; }
    if ! "$_b" -config "$1" -check >/dev/null 2>&1; then
        apm_err "网关拒绝了新配置 (网关 -check 失败), 当前配置未改动"
        return 1
    fi
}

# ---- 公共前置 ----

_agw_begin() { # allow_broken
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _agw_require_managed "${1:-no}" || return 4
}

_agw_require_managed() {
    core_discover anytlsgw
    case $CF_INSTALLED in
        no) apm_err "未检测到 AnyTLS Gateway"; return 4 ;;
        unverified) apm_err "检测到 AnyTLS Gateway 命名入口但它不是已确认的 ELF, 拒绝执行写操作"; return 4 ;;
    esac
    if [ "$CF_META_STATE" = invalid ]; then
        apm_err "Manager 元数据异常, 无法证明这是由 Alpine Proxy Manager 管理的 AnyTLS Gateway, 拒绝执行写操作"
        return 4
    fi
    if [ "$CF_MANAGED" != yes ]; then
        apm_err "检测到现有 AnyTLS Gateway 部署, 但它不是由 Alpine Proxy Manager 管理"
        apm_err "拒绝执行写操作, 不会覆盖或接管"
        return 4
    fi
    if [ "$CF_STATE" = broken ] && [ "${1:-no}" != yes ]; then
        apm_err "AnyTLS Gateway 处于异常状态 (二进制无法给出版本), 请先执行 anytls-gateway update --force 或 uninstall"
        return 4
    fi
    return 0
}

_agw_wait_healthy() {
    local _t _max _id _l
    _max=${APM_SNELL_WAIT:-15}
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover anytlsgw
        if [ "$CF_STATE" = running ] && [ -n "$CF_PID" ]; then
            _ok=1
            for _id in $(_agw_ids "$(_agw_state)"); do
                _l=$(_agw_get "$(_agw_state)" "$_id" listen)
                printf '%s\n' "$CF_LISTEN" | grep -q ":${_l##*:} " || _ok=0
            done
            [ "$_ok" = 1 ] && return 0
        fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_agw_wait_stopped() {
    local _t _max
    _max=${APM_SNELL_WAIT:-15}
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover anytlsgw
        if [ "$CF_SERVICE_STATE" = stopped ] && [ -z "$CF_PID" ]; then return 0; fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_agw_show_failure() {
    apm_err "服务状态: ${CF_SERVICE_STATE:-未知}"
    if [ -n "${CF_LOG_ERR:-}" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then
        apm_err "最近日志 ($CF_LOG_ERR):"
        tail -n 10 "$(env_path "$CF_LOG_ERR")" 2>/dev/null | sed 's/^/    /' >&2
    fi
}

# ---- 写配置: 事实来源与 config.json 一起事务提交, 失败回滚 ----

# 内容来自候选事实来源文件 CAND; 成功后两个文件都已原子替换
_agw_commit() { # CAND_STATE
    local _cj _sf
    _sf=$(_agw_state)
    _agw_check_state "$1" || return 1
    if [ -n "$(_agw_ids "$1")" ]; then
        _cj=$(txn_new_candidate "$(env_path "$AGW_CONF")") || return 1
        agw_gen_json "$1" > "$_cj" || { rm -f -- "$_cj"; return 1; }
        chmod 640 -- "$_cj"
        _agw_check_json "$_cj" || { rm -f -- "$_cj"; return 1; }
        txn_commit "$(env_path "$AGW_CONF")" "$_cj" _agw_nonempty || return 1
        _snell_chown "root:$AGW_GROUP" "$(env_path "$AGW_CONF")"
        chmod 640 -- "$(env_path "$AGW_CONF")"
    else
        rm -f -- "$(env_path "$AGW_CONF")"
    fi
    txn_commit "$_sf" "$1" _agw_check_state || return 1
}

_agw_nonempty() { [ -s "$1" ]; }

_agw_save() { # 保存当前两个文件的副本到 暂存目录, 路径在 AGW_SAVED_STATE AGW_SAVED_CONF
    _snell_ensure_staging || return 1
    AGW_SAVED_STATE=$SNELL_STAGING/state.saved
    AGW_SAVED_CONF=$SNELL_STAGING/conf.saved
    if [ -f "$(_agw_state)" ]; then cp -p -- "$(_agw_state)" "$AGW_SAVED_STATE"; else : > "$AGW_SAVED_STATE"; fi
    if [ -f "$(env_path "$AGW_CONF")" ]; then cp -p -- "$(env_path "$AGW_CONF")" "$AGW_SAVED_CONF"; else : > "$AGW_SAVED_CONF"; fi
}

_agw_restore() {
    if [ -s "$AGW_SAVED_STATE" ]; then cat "$AGW_SAVED_STATE" > "$(_agw_state)"; else rm -f -- "$(_agw_state)"; fi
    if [ -s "$AGW_SAVED_CONF" ]; then cat "$AGW_SAVED_CONF" > "$(env_path "$AGW_CONF")"; else rm -f -- "$(env_path "$AGW_CONF")"; fi
}

# 配置变更后生效: 服务在运行就重启并验证, 失败恢复旧配置
_agw_apply() {
    core_discover anytlsgw
    [ "$CF_STATE" = running ] || return 0
    _snell_say "重启 AnyTLS Gateway 使新配置生效"
    if [ -z "$(_agw_ids "$(_agw_state)")" ]; then
        _agw_rc stop >/dev/null 2>&1
        _snell_say "没有 listener 了, 服务已停止"
        return 0
    fi
    if _agw_rc restart >/dev/null 2>&1 && _agw_wait_healthy; then
        _snell_say "已重启并验证"
        return 0
    fi
    _agw_show_failure
    apm_err "新配置下服务没有进入健康状态, 正在恢复旧配置"
    _agw_restore
    _agw_rc restart >/dev/null 2>&1
    if _agw_wait_healthy; then _snell_say "已恢复旧配置并验证"; else apm_err "恢复旧配置后服务仍不健康, 请查看日志"; fi
    return 1
}

# ---- 元数据 ----

_agw_write_meta() { # 版本
    local _f _c
    _f=$(core_meta_file anytlsgw)
    state_ensure_dirs || return 1
    _c=$(txn_new_candidate "$_f") || return 1
    {
        printf 'schema=1\nmanaged=true\ncore=anytlsgw\n'
        printf 'exact_release=%s\nreported_version=%s\n' "$AGW_VER" "$1"
        printf 'binary_path=%s\nconfig_path=%s\nservice_name=anytls-socks-gateway\nlog_dir=%s\n' "$AGW_BIN" "$AGW_CONF" "$AGW_LOG_DIR"
        printf 'installed_at=%s\ncreated_user=%s\ncreated_group=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3"
    } > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# ---- 服务脚本 ----

_agw_write_init() {
    local _t
    _t=$(env_path "$AGW_INIT")
    mkdir -p -- "$(dirname "$_t")" || return 1
    cat > "$_t" <<'EOF'
#!/sbin/openrc-run
# apm-managed: anytls-gateway
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager anytls-gateway 管理, 手工修改可能被覆盖

name="anytls-socks-gateway"
description="AnyTLS Gateway (managed by Alpine Proxy Manager)"
command="/usr/local/bin/anytls-socks-gateway"
command_args="-config /etc/anytls-socks-gateway/config.json"
command_user="anytlsgw:anytlsgw"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
respawn_period=1800
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/anytls-socks-gateway/output.log"
error_log="/var/log/anytls-socks-gateway/error.log"
required_files="/etc/anytls-socks-gateway/config.json"

# 64 MiB 容器里的运行时参数, 软限制 16 MiB 并让垃圾回收更积极
export GOMEMLIMIT=16MiB
export GOGC=50

depend() {
    need net
}

start_pre() {
    checkpath -d -m 0750 -o anytlsgw:anytlsgw /var/log/anytls-socks-gateway
    checkpath -f -m 0640 -o anytlsgw:anytlsgw /var/log/anytls-socks-gateway/output.log
    checkpath -f -m 0640 -o anytlsgw:anytlsgw /var/log/anytls-socks-gateway/error.log
    # 配置或证书有问题时不启动, 把原因留在日志里
    /usr/local/bin/anytls-socks-gateway -config /etc/anytls-socks-gateway/config.json -check >/dev/null 2>>/var/log/anytls-socks-gateway/error.log
}
EOF
    chmod 755 -- "$_t"
}

# ---- 证书 ----

_agw_need_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    [ -x "$(env_path /usr/bin/openssl)" ] && return 0
    _snell_say "安装依赖: openssl"
    _snell_run apk add --no-cache openssl >/dev/null 2>&1 || { apm_err "安装 openssl 失败"; return 1; }
}

_agw_openssl() {
    if [ -n "${APM_SYSROOT:-}" ]; then
        [ -x "$(env_path /usr/bin/openssl)" ] || return 127
        "$(env_path /usr/bin/openssl)" "$@"
    else
        openssl "$@"
    fi
}

# 生成自签证书 RSA 2048 十年, 写入 AGW_CERT AGW_KEY (权限 644 与 640 root:组)
_agw_gen_cert() {
    local _d
    _d=$(env_path "$AGW_CONF_DIR")
    mkdir -p -- "$_d" || return 1
    _agw_openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=anytls-gateway" \
        -keyout "$_d/.key.new" -out "$_d/.cert.new" >/dev/null 2>&1 || { rm -f -- "$_d/.key.new" "$_d/.cert.new"; apm_err "生成自签证书失败"; return 1; }
    chmod 640 -- "$_d/.key.new"
    chmod 644 -- "$_d/.cert.new"
    mv -f -- "$_d/.key.new" "$(env_path "$AGW_KEY")" && mv -f -- "$_d/.cert.new" "$(env_path "$AGW_CERT")" || return 1
    _snell_chown "root:$AGW_GROUP" "$(env_path "$AGW_KEY")"
}

_agw_cert_fp() { _agw_openssl x509 -in "$(env_path "$AGW_CERT")" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }

# ---- install ----

_agw_asset_ok() {
    case ${APM_ARCH:-$(uname -m)} in
        x86_64) return 0 ;;
        *) apm_err "AnyTLS Gateway 目前只在 x86_64 上验证, 当前架构 ${APM_ARCH:-$(uname -m)} 不支持"; return 1 ;;
    esac
}

# 下载 固定 SHA256 校验 确认 ELF 试运行版本; 设置 AGW_NEW_BIN AGW_NEW_REPORTED
_agw_stage_binary() {
    local _url _want _sum _out
    _snell_ensure_staging || return 1
    _url=${APM_AGW_URL:-$AGW_URL_DEFAULT}
    _want=${APM_AGW_SHA256:-$AGW_SHA256_X86_64}
    AGW_NEW_BIN=$SNELL_STAGING/anytls-socks-gateway
    _snell_say "下载 $_url"
    _snell_fetch "$_url" "$AGW_NEW_BIN" || { apm_err "下载失败: $_url"; return 1; }
    _sum=$(sha256sum "$AGW_NEW_BIN" | awk '{ print $1 }')
    [ "$_sum" = "$_want" ] || { apm_err "校验和不匹配: 期望 $_want, 实际 $_sum"; return 1; }
    [ "$(core_file_kind "$AGW_NEW_BIN")" = elf ] || { apm_err "下载的文件不是 ELF, 拒绝安装"; return 1; }
    chmod 755 -- "$AGW_NEW_BIN"
    _out=$("$AGW_NEW_BIN" -version 2>&1 | head -n 1)
    AGW_NEW_REPORTED=$(printf '%s' "$_out" | sed -n 's/^anytls-socks-gateway \(v[0-9][0-9A-Za-z.-]*\)$/\1/p')
    [ "$AGW_NEW_REPORTED" = "$AGW_VER" ] || { apm_err "二进制无法运行或版本不是 $AGW_VER: $_out"; return 1; }
}

_agw_install_rollback() {
    [ "${R_STARTED:-0}" = 1 ] && _agw_rc stop >/dev/null 2>&1
    [ "${R_RCUPDATE:-0}" = 1 ] && _snell_run rc-update del anytls-socks-gateway default >/dev/null 2>&1
    [ "${R_INIT:-0}" = 1 ] && rm -f -- "$(env_path "$AGW_INIT")"
    [ "${R_BIN:-0}" = 1 ] && rm -f -- "$(env_path "$AGW_BIN")"
    [ "${R_STATE:-0}" = 1 ] && rm -f -- "$(_agw_state)"
    if [ "${R_CONFDIR:-0}" = 1 ]; then
        rm -rf -- "$(env_path "$AGW_CONF_DIR")"
    fi
    [ "${R_LOGDIR:-0}" = 1 ] && rm -rf -- "$(env_path "$AGW_LOG_DIR")"
    [ "${R_USER:-0}" = 1 ] && _snell_run deluser "$AGW_USER" >/dev/null 2>&1
    [ "${R_GROUP:-0}" = 1 ] && _snell_run delgroup "$AGW_GROUP" >/dev/null 2>&1
    rm -f -- "$(core_meta_file anytlsgw)"
    return 0
}

_agw_install_fail() {
    apm_err "$1"
    apm_err "正在回滚本次安装"
    _agw_install_rollback
    return 1
}

# 解析 listener 参数到 AGW_A_PORT AGW_A_BIND AGW_A_SHOST AGW_A_SPORT AGW_A_USER AGW_A_PWSTDIN AGW_A_GEN
_agw_parse_listener_args() {
    AGW_A_PORT=; AGW_A_BIND=0.0.0.0; AGW_A_SHOST=; AGW_A_SPORT=; AGW_A_USER=; AGW_A_PWSTDIN=no
    while [ $# -gt 0 ]; do
        case $1 in
            --port) [ $# -ge 2 ] || { apm_err "--port 需要参数"; return 2; }; AGW_A_PORT=$2; shift ;;
            --bind) [ $# -ge 2 ] || { apm_err "--bind 需要参数"; return 2; }; AGW_A_BIND=$2; shift ;;
            --socks-server) [ $# -ge 2 ] || { apm_err "--socks-server 需要参数"; return 2; }; AGW_A_SHOST=$2; shift ;;
            --socks-port) [ $# -ge 2 ] || { apm_err "--socks-port 需要参数"; return 2; }; AGW_A_SPORT=$2; shift ;;
            --socks-username) [ $# -ge 2 ] || { apm_err "--socks-username 需要参数"; return 2; }; AGW_A_USER=$2; shift ;;
            --socks-password-stdin) AGW_A_PWSTDIN=yes ;;
            *) apm_err "未知参数: $1 (SOCKS5 密码只能通过 --socks-password-stdin 提供)"; return 2 ;;
        esac
        shift
    done
}

# 校验 listener 参数并写入候选事实来源 CAND, 设置 AGW_NEW_ID AGW_NEW_PW; 读取标准输入的 SOCKS5 密码
_agw_add_to() { # CAND
    local _sp _id _next _srv
    [ -n "$AGW_A_SHOST" ] && [ -n "$AGW_A_SPORT" ] && [ -n "$AGW_A_USER" ] && [ "$AGW_A_PWSTDIN" = yes ] || {
        apm_err "需要 --socks-server 地址 --socks-port 端口 --socks-username 用户名 --socks-password-stdin"
        return 2
    }
    IFS= read -r _sp || :
    [ -n "$_sp" ] || { apm_err "从标准输入没有读到 SOCKS5 密码"; return 2; }
    _srv=$(_sb_socks_host_normalize "$AGW_A_SHOST" "$AGW_A_SPORT") || { apm_err "SOCKS5 服务器地址无效: $_srv"; return 2; }
    _agw_secret_ok "$AGW_A_USER" || { apm_err "SOCKS5 用户名无效 (可打印 ASCII, 不含引号与反斜杠)"; return 2; }
    _agw_secret_ok "$_sp" || { apm_err "SOCKS5 密码无效 (可打印 ASCII, 不含引号与反斜杠)"; return 2; }
    if [ -z "$AGW_A_PORT" ]; then AGW_A_PORT=$(_snell_rand_port) || { apm_err "无法选择空闲端口"; return 1; }; fi
    _snell_valid_port "$AGW_A_PORT" || { apm_err "端口必须是 1025 到 65535: $AGW_A_PORT"; return 2; }
    _agw_listen_ok "$AGW_A_BIND:$AGW_A_PORT" || { apm_err "监听地址无效: $AGW_A_BIND"; return 2; }
    if grep -q "^listener\.[0-9]*\.listen=.*:$AGW_A_PORT\$" "$1" 2>/dev/null; then apm_err "端口 $AGW_A_PORT 已被另一个 listener 使用"; return 2; fi
    if _snell_port_in_use "$AGW_A_PORT"; then apm_err "端口 $AGW_A_PORT 已被其他程序监听"; return 4; fi
    [ "$(_agw_ids "$1" | grep -c .)" -lt "$AGW_MAX_LISTENERS" ] || { apm_err "listener 数量已达上限 $AGW_MAX_LISTENERS"; return 2; }
    AGW_NEW_PW=$(_agw_gen_pw) || { apm_err "生成密码失败"; return 1; }
    _next=$(kv_get "$1" next_id)
    case $_next in ''|*[!0-9]*) _next=1 ;; esac
    _id=$_next
    grep -v "^next_id=" "$1" > "$1.n" 2>/dev/null; mv -f -- "$1.n" "$1"
    {
        printf 'next_id=%s\n' "$((_id + 1))"
        printf 'listener.%s.listen=%s:%s\n' "$_id" "$AGW_A_BIND" "$AGW_A_PORT"
        printf 'listener.%s.password=%s\n' "$_id" "$AGW_NEW_PW"
        printf 'listener.%s.socks_server=%s\n' "$_id" "$_srv"
        printf 'listener.%s.socks_username=%s\n' "$_id" "$AGW_A_USER"
        printf 'listener.%s.socks_password=%s\n' "$_id" "$_sp"
    } >> "$1"
    AGW_NEW_ID=$_id
}

agw_install() {
    local _rc _mark_user _mark_group _cand _had_conf _had_state _have_ids _newlistener
    _agw_parse_listener_args "$@" || return $?
    _snell_need_root || return 4
    _agw_asset_ok || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    core_discover anytlsgw
    if [ "$CF_INSTALLED" != no ] || [ -n "$CF_SERVICE" ]; then
        if [ "$CF_MANAGED" = yes ]; then
            apm_err "AnyTLS Gateway 已由 Manager 安装, 不隐式更新; 请使用 anytls-gateway update"
        else
            apm_err "检测到现有 AnyTLS Gateway 部署, 拒绝安装; 不会覆盖或接管现有部署"
        fi
        return 4
    fi
    _had_conf=no
    _had_state=no
    [ ! -e "$(env_path "$AGW_CONF_DIR")" ] || _had_conf=yes
    [ ! -e "$(_agw_state)" ] || _had_state=yes
    R_STARTED=0; R_RCUPDATE=0; R_INIT=0; R_BIN=0; R_STATE=0; R_CONFDIR=0; R_LOGDIR=0; R_USER=0; R_GROUP=0
    _agw_need_openssl || return 1
    _snell_ensure_staging || return 1
    _cand=$SNELL_STAGING/state.cand
    if [ "$_had_state" = yes ]; then
        _agw_check_state "$(_agw_state)" || { apm_err "保留的 listener 记录无效, 请先修复或清理 $(_agw_state)"; return 1; }
        cp -- "$(_agw_state)" "$_cand"
        _snell_say "沿用已保留的 listener 记录"
    else
        : > "$_cand"
    fi
    _newlistener=no
    if [ -n "$AGW_A_SHOST" ]; then
        _agw_add_to "$_cand"
        _rc=$?
        [ "$_rc" -eq 0 ] || return "$_rc"
        _newlistener=yes
    fi
    _snell_say "[1/6] 下载并校验 AnyTLS Gateway $AGW_VER"
    _agw_stage_binary || return 1
    _snell_say "[2/6] 用户与目录"
    _mark_group=no
    _mark_user=no
    if ! _agw_group_exists; then _snell_run addgroup -S "$AGW_GROUP" >/dev/null 2>&1 || { apm_err "创建用户组失败"; return 1; }; R_GROUP=1; _mark_group=yes; fi
    if ! _agw_user_exists; then _snell_run adduser -S -G "$AGW_GROUP" -H -h /var/empty -s /sbin/nologin "$AGW_USER" >/dev/null 2>&1 || { _agw_install_fail "创建用户失败"; return 1; }; R_USER=1; _mark_user=yes; fi
    [ "$_had_conf" = yes ] || R_CONFDIR=1
    [ -e "$(env_path "$AGW_LOG_DIR")" ] || R_LOGDIR=1
    mkdir -p -- "$(env_path "$AGW_CONF_DIR")" "$(env_path "$AGW_LOG_DIR")" || { _agw_install_fail "创建目录失败"; return 1; }
    chmod 750 -- "$(env_path "$AGW_CONF_DIR")" "$(env_path "$AGW_LOG_DIR")"
    _snell_chown "root:$AGW_GROUP" "$(env_path "$AGW_CONF_DIR")"
    _snell_chown "$AGW_USER:$AGW_GROUP" "$(env_path "$AGW_LOG_DIR")"
    _snell_say "[3/6] 证书"
    if [ -f "$(env_path "$AGW_CERT")" ] && [ -f "$(env_path "$AGW_KEY")" ]; then
        _snell_say "沿用已保留的证书"
    else
        _agw_gen_cert || { _agw_install_fail "证书生成失败"; return 1; }
    fi
    _snell_say "[4/6] 配置"
    state_ensure_dirs || { _agw_install_fail "无法创建状态目录"; return 1; }
    atomic_install "$AGW_NEW_BIN" "$(env_path "$AGW_BIN")" 755 || { _agw_install_fail "安装二进制失败"; return 1; }
    R_BIN=1
    _snell_chown root:root "$(env_path "$AGW_BIN")"
    _have_ids=$(_agw_ids "$_cand")
    if [ -n "$_have_ids" ]; then
        [ "$_had_state" = yes ] || R_STATE=1
        _agw_commit "$_cand" || { _agw_install_fail "写入配置失败"; return 1; }
    elif [ "$_had_state" != yes ]; then
        R_STATE=1
        : > "$(_agw_state)"; chmod 600 -- "$(_agw_state)"
    fi
    _snell_say "[5/6] 安装 OpenRC 服务"
    _agw_write_init || { _agw_install_fail "写入 $AGW_INIT 失败"; return 1; }
    R_INIT=1
    _snell_run rc-update add anytls-socks-gateway default >/dev/null 2>&1 || { _agw_install_fail "加入默认运行级别失败"; return 1; }
    R_RCUPDATE=1
    _agw_write_meta "$AGW_NEW_REPORTED" "$_mark_user" "$_mark_group" || { _agw_install_fail "写入元数据失败"; return 1; }
    if [ -z "$_have_ids" ]; then
        _snell_say "[6/6] 完成 (没有 listener, 服务未启动)"
        _snell_say "AnyTLS Gateway $AGW_VER 已安装; 添加第一个 listener: proxy-manager anytls-gateway listener add ..."
        return 0
    fi
    _snell_say "[6/6] 启动并验证"
    if ! _agw_rc start >/dev/null 2>&1 || ! _agw_wait_healthy; then
        core_discover anytlsgw
        _agw_show_failure
        R_STARTED=1
        # 保留的数据不在失败时删除
        [ "$_had_state" = yes ] && R_STATE=0
        _agw_install_fail "服务没有进入健康状态"
        return 1
    fi
    _snell_say "AnyTLS Gateway 安装完成并已验证"
    _snell_say "  版本：$AGW_NEW_REPORTED"
    if [ "$_newlistener" = yes ]; then
        _snell_say "  监听：$AGW_A_BIND:$AGW_A_PORT (容器或系统内端口, NAT 公网映射需自行配置)"
        _snell_say "  AnyTLS 密码：$AGW_NEW_PW (只显示这一次, 之后用 anytls-gateway export secret $AGW_NEW_ID 查看)"
    fi
    _snell_say "  证书：$(_agw_cert_fp) (自签证书需要客户端跳过校验或固定该指纹)"
}

# ---- start stop restart ----

agw_start() {
    _agw_begin no || return $?
    core_discover anytlsgw
    [ -n "$(_agw_ids "$(_agw_state)")" ] || { apm_err "没有 listener, 请先添加: anytls-gateway listener add"; return 4; }
    if [ "$CF_STATE" = running ]; then _snell_say "AnyTLS Gateway 已在运行"; return 0; fi
    _agw_rc start >/dev/null 2>&1 && _agw_wait_healthy || { core_discover anytlsgw; _agw_show_failure; apm_err "启动失败"; return 1; }
    _snell_say "AnyTLS Gateway 已启动并验证"
}

agw_stop() {
    _agw_begin yes || return $?
    core_discover anytlsgw
    if [ "$CF_SERVICE_STATE" = stopped ] && [ -z "$CF_PID" ]; then _snell_say "AnyTLS Gateway 已经停止"; return 0; fi
    _agw_rc stop >/dev/null 2>&1 || { apm_err "停止失败"; return 1; }
    _agw_wait_stopped || { apm_err "服务没有停止"; return 1; }
    _snell_say "AnyTLS Gateway 已停止"
}

agw_restart() {
    _agw_begin no || return $?
    [ -n "$(_agw_ids "$(_agw_state)")" ] || { apm_err "没有 listener, 请先添加: anytls-gateway listener add"; return 4; }
    _agw_rc restart >/dev/null 2>&1 && _agw_wait_healthy || { core_discover anytlsgw; _agw_show_failure; apm_err "重启失败"; return 1; }
    _snell_say "AnyTLS Gateway 已重启并验证"
}

# ---- listener ----

agw_listener_add() {
    local _cand _rc
    _agw_parse_listener_args "$@" || return $?
    _agw_begin no || return $?
    _snell_ensure_staging || return 1
    _cand=$SNELL_STAGING/state.cand
    if [ -f "$(_agw_state)" ]; then cp -- "$(_agw_state)" "$_cand"; else : > "$_cand"; fi
    _agw_add_to "$_cand"
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
    _agw_save || return 1
    _agw_commit "$_cand" || return 1
    _snell_say "已添加 listener $AGW_NEW_ID: $AGW_A_BIND:$AGW_A_PORT"
    _snell_say "  AnyTLS 密码：$AGW_NEW_PW (只显示这一次, 之后用 anytls-gateway export secret $AGW_NEW_ID 查看)"
    core_discover anytlsgw
    if [ "$CF_STATE" = running ]; then _agw_apply; return $?; fi
    _snell_say "服务未运行, 使用 anytls-gateway start 启动"
}

_agw_find_id() { # ID 或 端口 -> 输出 id
    local _x _id
    _x=$1
    for _id in $(_agw_ids "$(_agw_state)"); do
        [ "$_id" = "$_x" ] && { printf '%s' "$_id"; return 0; }
        [ "$(_agw_get "$(_agw_state)" "$_id" listen | sed 's/.*://')" = "$_x" ] && { printf '%s' "$_id"; return 0; }
    done
    return 1
}

agw_listener_delete() {
    local _id _cand
    [ $# -eq 1 ] || { apm_err "用法: anytls-gateway listener delete ID或端口"; return 2; }
    _agw_begin no || return $?
    _id=$(_agw_find_id "$1") || { apm_err "没有这个 listener: $1"; return 2; }
    _snell_ensure_staging || return 1
    _cand=$SNELL_STAGING/state.cand
    grep -v "^listener\.$_id\." "$(_agw_state)" > "$_cand"
    _agw_save || return 1
    _agw_commit "$_cand" || return 1
    _snell_say "已删除 listener $_id"
    _agw_apply
}

# set: --socks-server --socks-port --socks-username --socks-password-stdin 任意子集 (改上游), 或 --new-password (重新生成 AnyTLS 密码)
agw_listener_set() {
    local _id _cand _srv _host _port _user _pwin _newpw _sp _cur
    [ $# -ge 2 ] || { apm_err "用法: anytls-gateway listener set ID或端口 (--socks-server H --socks-port P --socks-username U --socks-password-stdin | --new-password)"; return 2; }
    _id=$1
    shift
    _host=; _port=; _user=; _pwin=no; _newpw=no
    while [ $# -gt 0 ]; do
        case $1 in
            --socks-server) [ $# -ge 2 ] || return 2; _host=$2; shift ;;
            --socks-port) [ $# -ge 2 ] || return 2; _port=$2; shift ;;
            --socks-username) [ $# -ge 2 ] || return 2; _user=$2; shift ;;
            --socks-password-stdin) _pwin=yes ;;
            --new-password) _newpw=yes ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _sp=
    if [ "$_pwin" = yes ]; then IFS= read -r _sp || :; [ -n "$_sp" ] || { apm_err "从标准输入没有读到 SOCKS5 密码"; return 2; }; _agw_secret_ok "$_sp" || { apm_err "SOCKS5 密码无效"; return 2; }; fi
    [ -z "$_user" ] || _agw_secret_ok "$_user" || { apm_err "SOCKS5 用户名无效"; return 2; }
    _agw_begin no || return $?
    _id=$(_agw_find_id "$_id") || { apm_err "没有这个 listener: $_id"; return 2; }
    _snell_ensure_staging || return 1
    _cand=$SNELL_STAGING/state.cand
    cp -- "$(_agw_state)" "$_cand"
    if [ -n "$_host$_port" ]; then
        _cur=$(_agw_get "$_cand" "$_id" socks_server)
        [ -n "$_host" ] || _host=${_cur%:*}
        [ -n "$_port" ] || _port=${_cur##*:}
        _srv=$(_sb_socks_host_normalize "$_host" "$_port") || { apm_err "SOCKS5 服务器地址无效: $_srv"; return 2; }
        _agw_set_key "$_cand" "listener.$_id.socks_server" "$_srv"
    fi
    [ -z "$_user" ] || _agw_set_key "$_cand" "listener.$_id.socks_username" "$_user"
    [ -z "$_sp" ] || _agw_set_key "$_cand" "listener.$_id.socks_password" "$_sp"
    if [ "$_newpw" = yes ]; then
        AGW_NEW_PW=$(_agw_gen_pw) || return 1
        _agw_set_key "$_cand" "listener.$_id.password" "$AGW_NEW_PW"
    fi
    _agw_save || return 1
    _agw_commit "$_cand" || return 1
    _snell_say "已更新 listener $_id"
    [ "$_newpw" != yes ] || _snell_say "  新的 AnyTLS 密码：$AGW_NEW_PW (只显示这一次)"
    _agw_apply
}

_agw_set_key() { # FILE KEY VALUE
    V=$3 awk -v k="$2" 'index($0, k "=") == 1 { print k "=" ENVIRON["V"]; next } { print }' "$1" > "$1.n" && mv -f -- "$1.n" "$1"
}

agw_listener_list() {
    local _id _f
    _f=$(_agw_state)
    if [ ! -f "$_f" ] || [ -z "$(_agw_ids "$_f")" ]; then printf 'Listener：没有\n'; return 0; fi
    printf 'Listener：\n'
    for _id in $(_agw_ids "$_f"); do
        printf '  %s  监听 %s  上游 %s  SOCKS5 用户名 %s (密码已配置)  AnyTLS 密码已配置\n' "$_id" "$(_agw_get "$_f" "$_id" listen)" "$(_agw_get "$_f" "$_id" socks_server)" "$(_agw_get "$_f" "$_id" socks_username)"
    done
}

# ---- cert ----

agw_cert() {
    local _sub _c _k
    _sub=${1:-show}
    [ $# -eq 0 ] || shift
    case $_sub in
        show)
            [ -f "$(env_path "$AGW_CERT")" ] || { apm_err "没有证书"; return 1; }
            printf '证书：%s\n' "$AGW_CERT"
            _agw_openssl x509 -in "$(env_path "$AGW_CERT")" -noout -subject -dates 2>/dev/null | sed 's/^/  /'
            printf '  SHA256 指纹：%s\n' "$(_agw_cert_fp)"
            ;;
        generate)
            _agw_begin no || return $?
            _agw_need_openssl || return 1
            _agw_gen_cert || return 1
            _snell_say "已重新生成自签证书, 新指纹 $(_agw_cert_fp)"
            _snell_ensure_staging || return 1
            core_discover anytlsgw
            [ "$CF_STATE" != running ] || { _agw_rc restart >/dev/null 2>&1 && _agw_wait_healthy || { apm_err "重启失败"; return 1; }; _snell_say "已重启并验证"; }
            ;;
        import)
            _c=; _k=
            while [ $# -gt 0 ]; do
                case $1 in
                    --cert-file) [ $# -ge 2 ] || return 2; _c=$2; shift ;;
                    --key-file) [ $# -ge 2 ] || return 2; _k=$2; shift ;;
                    *) apm_err "未知参数: $1"; return 2 ;;
                esac
                shift
            done
            [ -f "$_c" ] && [ -f "$_k" ] || { apm_err "用法: anytls-gateway cert import --cert-file 文件 --key-file 文件"; return 2; }
            _agw_begin no || return $?
            _agw_need_openssl || return 1
            _agw_import_cert "$_c" "$_k" || return 1
            core_discover anytlsgw
            [ "$CF_STATE" != running ] || { _agw_rc restart >/dev/null 2>&1 && _agw_wait_healthy || { apm_err "重启失败, 请检查证书"; return 1; }; _snell_say "已重启并验证"; }
            ;;
        *) apm_err "用法: anytls-gateway cert [show | generate | import --cert-file 文件 --key-file 文件]"; return 2 ;;
    esac
}

_agw_import_cert() { # CERT KEY
    local _d _pc _pk
    _pc=$(_agw_openssl x509 -in "$1" -noout -pubkey 2>/dev/null | sed 's/ //g')
    _pk=$(_agw_openssl pkey -in "$2" -pubout 2>/dev/null | sed 's/ //g')
    [ -n "$_pc" ] && [ "$_pc" = "$_pk" ] || { apm_err "证书与私钥无效或不匹配, 没有改动现有证书"; return 1; }
    _d=$(env_path "$AGW_CONF_DIR")
    cp -- "$1" "$_d/.cert.new" && cp -- "$2" "$_d/.key.new" || return 1
    chmod 644 -- "$_d/.cert.new"
    chmod 640 -- "$_d/.key.new"
    mv -f -- "$_d/.key.new" "$(env_path "$AGW_KEY")" && mv -f -- "$_d/.cert.new" "$(env_path "$AGW_CERT")" || return 1
    _snell_chown "root:$AGW_GROUP" "$(env_path "$AGW_KEY")"
    _snell_say "已导入证书, 指纹 $(_agw_cert_fp)"
}

# ---- export ----

agw_export() {
    local _sub _id _f _l
    _sub=${1:-info}
    [ $# -eq 0 ] || shift
    _f=$(_agw_state)
    case $_sub in
        info)
            agw_listener_list
            printf '证书指纹：%s\n' "$(_agw_cert_fp)"
            printf '客户端：AnyTLS, 服务器地址使用容器的公网地址与 NAT 映射端口; 自签证书需要跳过证书校验或固定上面的指纹\n'
            printf '密码：snell 一样不在这里显示, 使用 anytls-gateway export secret ID\n'
            ;;
        secret)
            [ $# -eq 1 ] || { apm_err "用法: anytls-gateway export secret ID或端口"; return 2; }
            _id=$(_agw_find_id "$1") || { apm_err "没有这个 listener: $1"; return 2; }
            _l=$(_agw_get "$_f" "$_id" listen)
            printf 'listener %s 监听端口 %s\n' "$_id" "${_l##*:}"
            printf 'AnyTLS 密码：%s\n' "$(_agw_get "$_f" "$_id" password)"
            printf '客户端出站 (sing-box):\n  {"type":"anytls","server":"<服务器地址>","server_port":<映射端口>,"password":"%s","tls":{"enabled":true,"insecure":true}}\n' "$(_agw_get "$_f" "$_id" password)"
            ;;
        *) apm_err "用法: anytls-gateway export [info | secret ID或端口]"; return 2 ;;
    esac
}

# ---- update ----

agw_update() {
    local _force _cur _was
    _force=no
    while [ $# -gt 0 ]; do case $1 in --force) _force=yes ;; *) apm_err "未知参数: $1"; return 2 ;; esac; shift; done
    _agw_asset_ok || return 4
    _agw_begin yes || return $?
    _cur=$CF_VERSION_REPORTED
    if [ "$_cur" = "$AGW_VER" ] && [ "$_force" != yes ] && [ "$CF_STATE" != broken ]; then
        _snell_say "已经是内置的固定版本 $AGW_VER, 无需更新 (--force 可重新安装二进制)"
        return 0
    fi
    _agw_stage_binary || return 1
    cp -p -- "$(env_path "$AGW_BIN")" "$(env_path "$AGW_BIN").old" 2>/dev/null
    core_discover anytlsgw
    _was=$CF_STATE
    [ "$_was" != running ] || _agw_rc stop >/dev/null 2>&1
    atomic_install "$AGW_NEW_BIN" "$(env_path "$AGW_BIN")" 755 || { apm_err "替换二进制失败"; mv -f -- "$(env_path "$AGW_BIN").old" "$(env_path "$AGW_BIN")" 2>/dev/null; [ "$_was" != running ] || _agw_rc start >/dev/null 2>&1; return 1; }
    _snell_chown root:root "$(env_path "$AGW_BIN")"
    if [ "$_was" = running ]; then
        if ! _agw_rc start >/dev/null 2>&1 || ! _agw_wait_healthy; then
            apm_err "新二进制没有进入健康状态, 正在回滚"
            _agw_rc stop >/dev/null 2>&1
            mv -f -- "$(env_path "$AGW_BIN").old" "$(env_path "$AGW_BIN")" 2>/dev/null
            _agw_rc start >/dev/null 2>&1 && _agw_wait_healthy && _snell_say "已回滚到旧版本"
            return 1
        fi
    fi
    rm -f -- "$(env_path "$AGW_BIN").old"
    _agw_write_meta "$AGW_NEW_REPORTED" "$(kv_get "$(core_meta_file anytlsgw)" created_user)" "$(kv_get "$(core_meta_file anytlsgw)" created_group)" >/dev/null 2>&1
    _snell_say "AnyTLS Gateway 已更新到 $AGW_NEW_REPORTED"
}

# ---- uninstall ----

agw_uninstall() {
    local _purge _cu _cg
    _purge=0
    while [ $# -gt 0 ]; do case $1 in --purge) _purge=1 ;; *) apm_err "未知参数: $1"; return 2 ;; esac; shift; done
    _agw_begin yes || return $?
    _cu=$(kv_get "$(core_meta_file anytlsgw)" created_user)
    _cg=$(kv_get "$(core_meta_file anytlsgw)" created_group)
    if [ "$CF_STATE" = running ] || [ "$CF_SERVICE_STATE" = started ] || [ -n "$CF_PID" ]; then
        _agw_rc stop >/dev/null 2>&1 || { apm_err "停止失败, 卸载已中止, 没有删除任何文件"; return 1; }
        _agw_wait_stopped || { apm_err "服务没有停止, 卸载已中止, 没有删除任何文件"; return 1; }
    fi
    _snell_run rc-update del anytls-socks-gateway default >/dev/null 2>&1
    if [ -f "$(env_path "$AGW_INIT")" ] && grep -q "^$AGW_INIT_MARK" "$(env_path "$AGW_INIT")"; then rm -f -- "$(env_path "$AGW_INIT")"; fi
    rm -f -- "$(env_path "$AGW_BIN")" "$(env_path "$AGW_BIN").old"
    if [ "$_purge" = 1 ]; then
        rm -rf -- "$(env_path "$AGW_CONF_DIR")" "$(env_path "$AGW_LOG_DIR")" "$(_agw_state)"
        [ "$_cu" != yes ] || ! _agw_user_exists || _snell_run deluser "$AGW_USER" >/dev/null 2>&1 || apm_warn "删除用户 $AGW_USER 失败, 已保留"
        [ "$_cg" != yes ] || ! _agw_group_exists || _snell_run delgroup "$AGW_GROUP" >/dev/null 2>&1 || apm_warn "删除用户组 $AGW_GROUP 失败, 已保留"
    fi
    rm -f -- "$(core_meta_file anytlsgw)"
    _snell_say "AnyTLS Gateway 已卸载"
    if [ "$_purge" = 1 ]; then _snell_say "已删除: 服务, 二进制, 配置, 证书, 日志, listener 记录, 元数据 (以及由 Manager 创建的用户与用户组)"
    else _snell_say "已保留: 配置 $AGW_CONF_DIR, 日志 $AGW_LOG_DIR, listener 记录 (重新安装前需先 --purge 或手工清理)"; fi
}

# ---- 只读报告 ----

report_anytlsgw_status() {
    core_discover anytlsgw
    printf 'AnyTLS Gateway\n'
    printf '  状态：%s\n' "$(core_state_label "$CF_STATE")"
    [ "$CF_INSTALLED" = yes ] || { _rpt_notes; return 0; }
    printf '  版本：%s (二进制自报)\n' "${CF_VERSION_REPORTED:-未知}"
    printf '  来源：%s, %s\n' "$(core_deployment_label "$CF_DEPLOYMENT")" "$(core_managed_label)"
    [ -z "$CF_PID" ] || printf '  进程：%s\n' "$CF_PID"
    _rpt_listeners
    _rpt_notes
}

report_anytlsgw_info() {
    core_discover anytlsgw
    printf 'AnyTLS Gateway\n'
    printf '  已安装：%s\n' "$(_rpt_yn "$CF_INSTALLED")"
    printf '  状态：%s\n' "$(core_state_label "$CF_STATE")"
    printf '  部署类型：%s\n  管理状态：%s\n' "$CF_DEPLOYMENT" "$(core_managed_label)"
    [ -z "$CF_BINARY" ] || printf '  二进制：%s\n' "$CF_BINARY"
    if [ "$CF_INSTALLED" = yes ]; then
        printf '  自报版本：%s\n  精确发布：%s\n' "${CF_VERSION_REPORTED:-未知}" "$CF_VERSION_EXACT"
        [ -z "$CF_PID" ] || printf '  服务进程 PID：%s\n' "$CF_PID"
        printf '  服务用户：%s\n' "${CF_SERVICE_USER:-未声明}"
        [ -z "$CF_CONFIG" ] || printf '  配置：%s (存在 %s)\n' "$CF_CONFIG" "$(_rpt_yn "$CF_CONFIG_EXISTS")"
        [ "$CF_DEPLOYMENT" != managed ] || agw_listener_list
    fi
    _rpt_listeners
    _rpt_notes
}

report_anytlsgw_log() { _report_core_log anytlsgw "$@"; }

# ---- CLI ----

agw_cli() {
    local _sub
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        status) report_anytlsgw_status ;;
        info) report_anytlsgw_info ;;
        log) report_anytlsgw_log "${1:-20}" ;;
        install) agw_install "$@" ;;
        start) agw_start ;;
        stop) agw_stop ;;
        restart) agw_restart ;;
        update) agw_update "$@" ;;
        uninstall) agw_uninstall "$@" ;;
        cert) agw_cert "$@" ;;
        export) agw_export "$@" ;;
        config) agw_listener_list ;;
        listener)
            case ${1:-list} in
                list) agw_listener_list ;;
                add) shift; agw_listener_add "$@" ;;
                delete) shift; agw_listener_delete "$@" ;;
                set) shift; agw_listener_set "$@" ;;
                *) apm_err "用法: anytls-gateway listener [list | add ... | delete ID | set ID ...]"; return 2 ;;
            esac
            ;;
        *) apm_err "未知的 anytls-gateway 子命令: $_sub"; return 2 ;;
    esac
}
