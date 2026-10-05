# shellcheck shell=sh
# sing-box Managed Core 与 AnyTLS Protocol Instance
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

# AnyTLS 实例校验: 通用模型校验加 AnyTLS 专有字段
sb_instance_validate() {
    local _f _rc _v
    _f=$1
    _rc=0
    instance_validate "$_f" || _rc=1
    case $(kv_get "$_f" type) in
        anytls)
            _v=$(kv_get "$_f" credential.password)
            _snell_valid_psk "$_v" || { apm_err "$_f: credential.password 无效 (16 到 128 位字母数字或 _ -)"; _rc=1; }
            _v=$(kv_get "$_f" tls.server_name)
            _sb_valid_sni "$_v" || { apm_err "$_f: tls.server_name 无效"; _rc=1; }
            for _v in tls.certificate_path tls.key_path; do
                case $(kv_get "$_f" "$_v") in
                    /*) _sb_json_safe "$(kv_get "$_f" "$_v")" || { apm_err "$_f: $_v 含有不允许的字符"; _rc=1; } ;;
                    *) apm_err "$_f: $_v 必须是绝对路径"; _rc=1 ;;
                esac
            done
            _v=$(kv_get "$_f" listen_port)
            _snell_valid_port "$_v" || { apm_err "$_f: listen_port 需要 1025 到 65535"; _rc=1; }
            ;;
        *) apm_err "$_f: sing-box 目前只支持 anytls 实例"; _rc=1 ;;
    esac
    return "$_rc"
}

# 一个 AnyTLS inbound 的 JSON
_sb_inbound_anytls() {
    printf '\n    {\n      "type": "anytls",\n      "tag": "%s",\n      "listen": "%s",\n      "listen_port": %s,\n      "users": [\n        {\n          "password": "%s"\n        }\n      ],\n      "tls": {\n        "enabled": true,\n        "certificate_path": "%s",\n        "key_path": "%s"\n      }\n    }' \
        "$(kv_get "$1" id)" "$(kv_get "$1" listen)" "$(kv_get "$1" listen_port)" "$(kv_get "$1" credential.password)" \
        "$(kv_get "$1" tls.certificate_path)" "$(kv_get "$1" tls.key_path)"
}

# 由实例目录生成完整的 sing-box 配置到标准输出, 只包含启用的实例
sb_generate_config() { # INSTANCES_DIR
    local _f _first
    printf '{\n  "log": {\n    "level": "warn",\n    "timestamp": true\n  },\n  "inbounds": ['
    _first=1
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" enabled)" = true ] || continue
        case $(kv_get "$_f" type) in
            anytls)
                [ "$_first" = 1 ] || printf ','
                _first=0
                _sb_inbound_anytls "$_f"
                ;;
        esac
    done
    [ "$_first" = 1 ] || printf '\n  '
    printf '],\n  "outbounds": [\n    {\n      "type": "direct",\n      "tag": "direct"\n    }\n  ]\n}\n'
}

# 启用实例的端口, 空格分隔
_sb_expected_ports() {
    local _f _r
    _r=
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" enabled)" = true ] || continue
        _r="$_r $(kv_get "$_f" listen_port)"
    done
    printf '%s' "${_r# }"
}

# 全部实例 (启用或禁用) 里是否已有该端口
_sb_port_taken_by_instance() { # DIR PORT [EXCEPT_ID]
    local _f
    for _f in $(state_list_confs "$1"); do
        [ "$(kv_get "$_f" id)" != "${3:-}" ] || continue
        [ "$(kv_get "$_f" listen_port)" = "$2" ] && return 0
    done
    return 1
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
                printf '%s\n' "$CF_LISTEN" | grep -q ":$_p " || _ok=0
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
            if _snell_port_in_use "$_p"; then
                apm_err "已保留的实例使用的端口 $_p 已被占用"
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
    _sb_say "  添加实例：proxy-manager sing-box add anytls"
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
    _cand=$(txn_new_candidate "$_cfg") || return 1
    sb_generate_config "$1" > "$_cand" || { rm -f -- "$_cand"; return 1; }
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

# add anytls [--name ID] [--port N | --listen ADDR] [--server-name NAME] [--password-stdin]
singbox_add() {
    local _type _name _port _listen _sni _pwmode _pw _dir _id _crt _key _f _was _a _p
    _type=${1:-}
    [ -n "$_type" ] || { apm_err "用法: sing-box add anytls [选项]"; return 2; }
    shift
    case $_type in anytls) ;; *) apm_err "不支持的协议: $_type (目前只支持 anytls)"; return 2 ;; esac
    _name=
    _port=
    _listen=::
    _sni=$SB_DEFAULT_SNI
    _pwmode=generate
    while [ $# -gt 0 ]; do
        case $1 in
            --name) [ $# -ge 2 ] || { apm_err "--name 需要参数"; return 2; }; _name=$2; shift ;;
            --port) [ $# -ge 2 ] || { apm_err "--port 需要参数"; return 2; }; _port=$2; shift ;;
            --listen) [ $# -ge 2 ] || { apm_err "--listen 需要参数"; return 2; }; _listen=$2; shift ;;
            --server-name) [ $# -ge 2 ] || { apm_err "--server-name 需要参数"; return 2; }; _sni=$2; shift ;;
            --password-stdin) _pwmode=stdin ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    [ -z "$_name" ] || is_ident "$_name" || { apm_err "名称无效: $_name"; return 2; }
    [ -z "$_port" ] || _snell_valid_port "$_port" || { apm_err "端口无效: $_port (需要 1025 到 65535)"; return 2; }
    is_listen_addr "$_listen" || { apm_err "listen 无效: $_listen"; return 2; }
    _sb_valid_sni "$_sni" || { apm_err "server-name 无效: $_sni"; return 2; }
    _pw=
    if [ "$_pwmode" = stdin ]; then
        IFS= read -r _pw || _pw=
        _snell_valid_psk "$_pw" || { apm_err "从标准输入读取的密码无效 (16 到 128 位字母数字或 _ -)"; return 2; }
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
        _id=$(_sb_next_id "$_dir" AnyTLS) || { apm_err "没有可用的实例编号"; return 1; }
    fi
    if [ -z "$_port" ]; then
        _a=0
        while [ "$_a" -lt 30 ]; do
            _p=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')
            _p=$((10240 + _p % 21760))
            if ! _snell_port_in_use "$_p" && ! _sb_port_taken_by_instance "$_dir" "$_p"; then
                _port=$_p
                break
            fi
            _a=$((_a + 1))
        done
        [ -n "$_port" ] || { apm_err "无法选出可用的随机端口"; return 1; }
    else
        if _sb_port_taken_by_instance "$_dir" "$_port"; then
            apm_err "端口 $_port 已被其他实例使用"
            return 1
        fi
        if _snell_port_in_use "$_port"; then
            apm_err "端口 $_port 已被占用"
            return 1
        fi
    fi
    [ "$_pwmode" = stdin ] || _pw=$(_snell_gen_psk) || { apm_err "生成密码失败 (/dev/urandom 不可用?)"; return 1; }

    _crt=$SB_TLS_DIR/$_id.crt
    _key=$SB_TLS_DIR/$_id.key
    _sb_gen_tls "$_sni" "$(env_path "$_crt")" "$(env_path "$_key")" || { rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"; return 1; }
    _f=$_dir/$_id.conf
    (
        umask 077
        printf 'id=%s\nname=%s\ntype=anytls\nenabled=true\nlisten=%s\nlisten_port=%s\n' "$_id" "$_id" "$_listen" "$_port"
        printf 'credential.password=%s\n' "$_pw"
        printf 'tls.mode=self-signed\ntls.server_name=%s\ntls.certificate_path=%s\ntls.key_path=%s\n' "$_sni" "$_crt" "$_key"
        printf 'transport.type=tcp\n'
    ) > "$_f" || { rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"; return 1; }
    if ! sb_instance_validate "$_f" >/dev/null 2>&1; then
        rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"
        sb_instance_validate "$_f" 2>&1 | sed 's/^/  /' >&2
        apm_err "实例未通过校验"
        return 1
    fi
    if ! _sb_commit_instances "$_dir" "$_was"; then
        rm -f -- "$(env_path "$_crt")" "$(env_path "$_key")"
        return 1
    fi
    _sb_sync_instances "$_dir" || { apm_err "保存实例失败"; return 1; }
    _sb_say "已添加实例 $_id"
    _sb_say "  协议：anytls, 监听：$_listen 端口 $_port, 证书：自签名 (server-name $_sni)"
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
    local _f _any _st _port
    core_discover singbox
    _any=0
    printf 'sing-box 实例\n'
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        _any=1
        _port=$(kv_get "$_f" listen_port)
        if [ "$(kv_get "$_f" enabled)" = true ]; then
            _st=启用
            printf '%s\n' "$CF_LISTEN" | grep -q ":$_port " && _st="启用, 监听中"
        else
            _st=禁用
        fi
        printf '  %s  %s  %s  %s 端口 %s  %s\n' "$(kv_get "$_f" id)" "$(kv_get "$_f" type)" "$_st" "$(kv_get "$_f" listen)" "$_port" "SNI $(kv_get "$_f" tls.server_name)"
    done
    [ "$_any" = 1 ] || printf '  (没有实例)\n'
}

singbox_show() {
    local _f
    [ -n "${1:-}" ] || { apm_err "用法: sing-box show 实例ID"; return 2; }
    _f=$(state_instances_dir)/$1.conf
    [ -f "$_f" ] || { apm_err "实例 $1 不存在"; return 1; }
    core_discover singbox
    printf '实例 %s\n' "$1"
    printf '  类型：%s\n' "$(kv_get "$_f" type)"
    printf '  启用：%s\n' "$(kv_get "$_f" enabled)"
    printf '  监听：%s\n' "$(kv_get "$_f" listen)"
    printf '  端口：%s\n' "$(kv_get "$_f" listen_port)"
    printf '  server-name：%s\n' "$(kv_get "$_f" tls.server_name)"
    printf '  TLS：%s (证书 %s)\n' "$(kv_get "$_f" tls.mode)" "$(kv_get "$_f" tls.certificate_path)"
    if [ -n "$(kv_get "$_f" credential.password)" ]; then
        printf '  密码：已配置\n'
    else
        printf '  密码：未配置\n'
    fi
    printf '%s\n' "$CF_LISTEN" | grep -q ":$(kv_get "$_f" listen_port) " && printf '  当前监听：是\n' || printf '  当前监听：否\n'
}

# 通用: 以提案目录修改后提交
# _sb_change ID ACTION ...  ACTION: enable disable delete set KEY VALUE [--stdin|--generate]
singbox_change() {
    local _id _action _dir _f _was _key _val _port _crt _key_path _sni _cleanup_tls _old_crt _old_key _bk
    _id=${1:-}
    _action=${2:-}
    if [ -z "$_id" ] || [ -z "$_action" ]; then
        apm_err "用法: sing-box enable|disable|delete|set 实例ID ..."
        return 2
    fi
    shift 2
    GENERATED_PW=
    _val=
    _key=
    if [ "$_action" = set ]; then
        _key=${1:-}
        shift
        case $_key in
            port) _val=${1:-}; _snell_valid_port "$_val" || { apm_err "端口无效 (需要 1025 到 65535)"; return 2; } ;;
            listen) _val=${1:-}; is_listen_addr "$_val" || { apm_err "listen 无效"; return 2; } ;;
            server-name) _val=${1:-}; _sb_valid_sni "$_val" || { apm_err "server-name 无效"; return 2; } ;;
            password)
                case ${1:-} in
                    --stdin) IFS= read -r _val || _val= ;;
                    --generate) _val=$(_snell_gen_psk) || { apm_err "生成密码失败"; return 1; }; GENERATED_PW=$_val ;;
                    *) apm_err "密码不接受命令行明文参数, 请使用 --stdin 或 --generate"; return 2 ;;
                esac
                _snell_valid_psk "$_val" || { apm_err "密码无效 (16 到 128 位字母数字或 _ -)"; return 2; }
                ;;
            *) apm_err "不支持的键: $_key (支持 port listen server-name password)"; return 2 ;;
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
    _crt=$(kv_get "$_f" tls.certificate_path)
    _key_path=$(kv_get "$_f" tls.key_path)
    _cleanup_tls=
    case $_action in
        enable) _sb_inst_set "$_f" enabled true ;;
        disable) _sb_inst_set "$_f" enabled false ;;
        delete) rm -f -- "$_f" ;;
        set)
            case $_key in
                port)
                    if _sb_port_taken_by_instance "$_dir" "$_val" "$_id"; then apm_err "端口 $_val 已被其他实例使用"; return 1; fi
                    if [ "$_val" != "$(kv_get "$_f" listen_port)" ] && _snell_port_in_use "$_val"; then apm_err "端口 $_val 已被占用"; return 1; fi
                    _sb_inst_set "$_f" listen_port "$_val"
                    ;;
                listen) _sb_inst_set "$_f" listen "$_val" ;;
                password) _sb_inst_set "$_f" credential.password "$_val" ;;
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
        [ -z "${_old_crt:-}" ] || { cp -p -- "$_old_crt" "$(env_path "$_crt")"; cp -p -- "$_old_key" "$(env_path "$_key_path")"; }
        return 1
    fi
    if ! _sb_commit_instances "$_dir" "$_was"; then
        [ -z "${_old_crt:-}" ] || { cp -p -- "$_old_crt" "$(env_path "$_crt")"; cp -p -- "$_old_key" "$(env_path "$_key_path")"; }
        return 1
    fi
    _sb_sync_instances "$_dir" || { apm_err "保存实例失败"; return 1; }
    if [ "$_action" = delete ]; then
        rm -f -- "$(env_path "$_crt")" "$(env_path "$_key_path")"
    fi
    case $_action in
        enable) _sb_say "实例 $_id 已启用" ;;
        disable) _sb_say "实例 $_id 已禁用" ;;
        delete) _sb_say "实例 $_id 已删除" ;;
        set)
            if [ "$_key" = password ]; then
                _sb_say "实例 $_id 的密码已更新"
                if [ -n "$GENERATED_PW" ]; then
                    _sb_say "  新密码：$GENERATED_PW"
                    _sb_say "  这是自动生成的密码, 只在此处显示一次, 请自行保存"
                fi
            else
                _sb_say "实例 $_id 的 $_key 已更新为 $_val"
            fi
            ;;
    esac
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
            case $(kv_get "$_f" type) in anytls) rm -f -- "$_f" ;; esac
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
