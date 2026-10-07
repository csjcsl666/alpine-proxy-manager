# shellcheck shell=sh
# Snell Managed Core: 由 Alpine Proxy Manager 安装并拥有的 Snell 的完整生命周期
#
# 原则
#   - 只管理自己安装的 Snell: 归属只看 cores/snell.meta, external 与归属不明的部署一律拒绝写操作
#   - 元数据最后写入, 之前任何一步失败都回滚到安装前, 绝不出现 managed=true 但 Snell 没装好
#   - PSK 只存在于 /etc/snell/snell-server.conf, 不进元数据, 日志与临时副本
#     自动生成的 PSK 只在生成当次打印一次, 之后读取只显示 "已配置"
#   - 状态判断复用 core_discover, 不看 /proc/*/comm
#   - 不实现 adopt 与 migrate
#
# 测试接缝: 设置 APM_SYSROOT 时, 系统工具 (apk adduser rc-service 等) 只在 sysroot 内查找,
#           找不到就失败, 因此测试永远不会调用真实的系统工具
#           chown 在 sysroot 模式下只记录到 $APM_SYSROOT/.chown.log
#           APM_DOWNLOADER 替换 wget, APM_SNELL_DL_BASE 覆盖下载地址, APM_SNELL_WAIT 覆盖等待秒数
#
# 退出码: 0 成功, 1 失败, 2 用法错误, 3 未实现, 4 被拒绝 (归属, 已存在, 残留)

# 唯一的默认 release 来源, 使用官方下载地址里的标签写法
SNELL_DEFAULT_RELEASE="v6.0.0rc2"
SNELL_DL_BASE_DEFAULT="https://dl.nssurge.com/snell"
SNELL_USER="snell"
SNELL_GROUP="snell"
SNELL_DEPS="gcompat libstdc++ libgcc"
# 已确认的 mode 取值, 其他取值没有证据, 不接受
SNELL_MODES="default"
SNELL_INIT_MARK="# apm-managed: snell"

# 固定布局 (逻辑路径, 访问时经 env_path)
SNELL_BIN=/usr/local/bin/snell-server
SNELL_CONF_DIR=/etc/snell
SNELL_CONF=/etc/snell/snell-server.conf
SNELL_INIT=/etc/init.d/snell
SNELL_LOG_DIR=/var/log/snell

SNELL_STAGING=
SNELL_LOCKED=0
SNELL_CREATED_VAR=0

_snell_say() { printf '%s\n' "$*"; }

# ---- 系统工具接缝 ----

_snell_tool() {
    local _n _d
    _n=$1
    if [ -n "${APM_SYSROOT:-}" ]; then
        for _d in /sbin /usr/sbin /bin /usr/bin; do
            if [ -x "$(env_path "$_d/$_n")" ]; then
                env_path "$_d/$_n"
                return 0
            fi
        done
        return 1
    fi
    command -v "$_n"
}

# _snell_run NAME ARGS..., 找不到工具时返回 127
_snell_run() {
    local _t _n
    _n=$1
    shift
    _t=$(_snell_tool "$_n") || return 127
    "$_t" "$@"
}

# chown 在 sysroot 模式下只记录, 宿主机上不存在 snell 用户
_snell_chown() {
    local _o
    _o=$1
    shift
    if [ -n "${APM_SYSROOT:-}" ]; then
        for _p in "$@"; do
            printf '%s %s\n' "$_o" "$(_core_logical "$_p")" >> "$(env_path /.chown.log)"
        done
        return 0
    fi
    chown "$_o" "$@"
}

_snell_rc() { _snell_run rc-service snell "$1"; }

# ---- 通用检查 ----

_snell_need_root() {
    if ! env_is_root; then
        apm_err "需要 root 权限"
        return 4
    fi
}

_snell_cleanup() {
    [ -z "$SNELL_STAGING" ] || rm -rf -- "$SNELL_STAGING"
    SNELL_STAGING=
    if [ "$SNELL_LOCKED" = 1 ]; then
        rm -rf -- "$(state_var)/snell.lock"
        SNELL_LOCKED=0
        # 数据目录是为锁临时创建的且没有别的内容时, 一并移除, 失败的命令不留痕迹
        [ "$SNELL_CREATED_VAR" = 1 ] && rmdir "$(state_var)" 2>/dev/null
        SNELL_CREATED_VAR=0
    fi
}

# 写操作期间忽略 HUP INT TERM: SSH 断线或 Ctrl+C 打断事务会留下半完成状态 (半装的 Core, 配置与实例不一致)
# 只有没有副作用的下载阶段允许被打断 (见 _snell_fetch), 子进程不会继承这里的忽略
# PIPE 用空操作 trap 而不是忽略: 非 TTY 的 ssh 断开后 stdout 变成断管, 主 shell 不能被 SIGPIPE 杀掉, 子进程仍保持默认处理 (忽略会让 head 之类的管道产生 write error 噪音)
_snell_signals_ignore() { trap '' HUP INT TERM; trap ':' PIPE; }

_snell_lock() {
    local _l _pid
    _l=$(state_var)/snell.lock
    [ -d "$(state_var)" ] || SNELL_CREATED_VAR=1
    mkdir -p -- "$(state_var)" || return 1
    chmod 700 -- "$(state_var)" 2>/dev/null
    if ! mkdir -- "$_l" 2>/dev/null; then
        _pid=$(head -n 1 "$_l/pid" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            apm_err "另一个 Manager 写操作正在运行 (pid $_pid), 请等待它结束"
            return 4
        fi
        rm -rf -- "$_l"
        mkdir -- "$_l" 2>/dev/null || return 1
    fi
    SNELL_LOCKED=1
    printf '%s\n' "$$" > "$_l/pid"
    _snell_signals_ignore
    _snell_sweep_staging
}

# 持有独占锁时不可能有别的写操作在使用暂存目录, 剩下的都是被 kill -9 或断电打断的操作留下的
# 里面有实例文件的副本 (含凭据), 不让它们一直留在 /var/tmp
_snell_sweep_staging() {
    local _d
    for _d in "$(env_path /var/tmp)"/apm-snell.*; do
        [ -d "$_d" ] && rm -rf -- "$_d"
    done
    return 0
}

# 允许写操作之前的归属检查, 参数 allow_broken 为 yes 时允许 managed 但 broken 的实例
# 失败返回 4 并说明原因
_snell_require_managed() {
    core_discover snell
    if [ "$CF_INSTALLED" = no ]; then
        apm_err "未检测到 Snell"
        return 4
    fi
    if [ "$CF_INSTALLED" = unverified ]; then
        apm_err "检测到 Snell 命名入口但它不是已确认的 ELF, 拒绝执行写操作"
        return 4
    fi
    if [ "$CF_META_STATE" = invalid ]; then
        apm_err "Manager 元数据异常, 无法证明这是由 Alpine Proxy Manager 管理的 Snell, 拒绝执行写操作"
        return 4
    fi
    if [ "$CF_MANAGED" != yes ]; then
        apm_err "检测到现有 Snell 部署, 但该实例不是由 Alpine Proxy Manager 管理"
        apm_err "拒绝执行写操作, 不会覆盖或接管"
        return 4
    fi
    if [ "$CF_STATE" = broken ] && [ "${1:-no}" != yes ]; then
        apm_err "Snell 处于异常状态 (二进制无法给出版本), 请先执行 snell update --force 或 snell uninstall"
        return 4
    fi
    return 0
}

# ---- 文件与校验 ----

_snell_valid_port() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    [ ${#1} -le 5 ] && [ "$1" -ge 1025 ] && [ "$1" -le 65535 ]
}

# listen 值: 逗号分隔的 ADDR:PORT, ADDR 为 IPv4 或 [IPv6]
_snell_valid_listen() {
    local _item _h _p _seen
    [ -n "$1" ] || return 1
    _seen=" "
    for _item in $(printf '%s' "$1" | tr ',' ' '); do
        case $_item in *:*) ;; *) return 1 ;; esac
        _h=${_item%:*}
        _p=${_item##*:}
        _snell_valid_port "$_p" || return 1
        case $_h in
            \[*\]) printf '%s' "$_h" | grep -Eq '^\[[0-9A-Fa-f:.]+\]$' || return 1 ;;
            *) is_ipv4 "$_h" || return 1 ;;
        esac
        case $_seen in *" $_item "*) return 1 ;; esac
        _seen="$_seen$_item "
    done
}

_snell_valid_psk() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{16,128}$'; }

_snell_valid_mode() {
    local _m
    for _m in $SNELL_MODES; do
        [ "$1" = "$_m" ] && return 0
    done
    return 1
}

# 配置校验器, 供 txn_commit 使用: 单个 [snell-server] 段, 键只允许 listen psk mode dns-ip-preference
# dns-ip-preference 是 Snell-Alpine 模板里使用过的已验证键, 只保留不修改
snell_validate_config() {
    local _f _k _v _n
    _f=$1
    [ -r "$_f" ] || { apm_err "无法读取候选配置"; return 1; }
    [ "$(grep -c '^\[snell-server\][[:space:]]*$' "$_f")" = 1 ] || { apm_err "配置必须恰好有一个 [snell-server] 段"; return 1; }
    if grep -Env '^[[:space:]]*($|#|\[snell-server\][[:space:]]*$|[A-Za-z0-9_-]+[[:space:]]*=)' "$_f" | head -n 1 | grep -q .; then
        apm_err "配置含有无法识别的行"
        return 1
    fi
    # shellcheck disable=SC2013
    for _k in $(sed -n 's/^[[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\)[[:space:]]*=.*/\1/p' "$_f"); do
        case $_k in listen|psk|mode|dns-ip-preference) ;; *) apm_err "配置含有未确认的键: $_k"; return 1 ;; esac
    done
    _n=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\)[[:space:]]*=.*/\1/p' "$_f" | sort | uniq -d | head -n 1)
    [ -z "$_n" ] || { apm_err "配置含有重复的键: $_n"; return 1; }
    _v=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$_f" | head -n 1 | sed 's/[[:space:]]*$//')
    _snell_valid_listen "$_v" || { apm_err "listen 无效: 需要 ADDR:PORT 逗号分隔, 端口 1025 到 65535"; return 1; }
    _v=$(sed -n 's/^[[:space:]]*psk[[:space:]]*=[[:space:]]*//p' "$_f" | head -n 1 | sed 's/[[:space:]]*$//')
    _snell_valid_psk "$_v" || { apm_err "psk 无效: 需要 16 到 128 位字母数字或 _ -"; return 1; }
    _v=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p' "$_f" | head -n 1 | sed 's/[[:space:]]*$//')
    if [ -n "$_v" ]; then
        _snell_valid_mode "$_v" || { apm_err "mode 取值未确认: $_v (已确认: $SNELL_MODES)"; return 1; }
    fi
}

# 端口是否已被监听 (tcp 或 udp), 来自 /proc/net
_snell_port_in_use() {
    [ -n "$(_core_proc_listeners "" " $1 ")" ]
}

_snell_rand_port() {
    local _i _n _p
    _i=0
    while [ "$_i" -lt 30 ]; do
        _n=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')
        [ -n "$_n" ] || return 1
        _p=$((10240 + _n % 21760))
        _snell_port_in_use "$_p" || { printf '%s' "$_p"; return 0; }
        _i=$((_i + 1))
    done
    return 1
}

_snell_gen_psk() {
    local _p
    _p=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    [ "${#_p}" -eq 32 ] || return 1
    printf '%s' "$_p"
}

# 把 listen 里的端口列表输出为空格分隔
_snell_ports_of() { printf '%s' "$1" | tr ',' '\n' | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' | tr '\n' ' ' | sed 's/ $//'; }

# ---- 发布与下载 ----

# 规范化 release 标签: v6.0.0-rc2 与 v6.0.0rc2 视为同一个, 输出官方下载地址使用的写法
snell_norm_release() {
    printf '%s' "$1" | sed 's/^\(v[0-9][0-9.]*\)-/\1/'
}

_snell_valid_release() { printf '%s' "$1" | grep -Eq '^v6\.[0-9]+\.[0-9]+([a-z]+[0-9]*)?$'; }

_snell_asset_arch() {
    case ${APM_ARCH:-$(uname -m)} in
        x86_64) printf 'amd64' ;;
        aarch64) printf 'aarch64' ;;
        x86|i386|i486|i586|i686) printf 'i386' ;;
        *) return 1 ;;
    esac
}

_snell_fetch() {
    local _dl _rc
    _dl=${APM_DOWNLOADER:-wget}
    command -v "$_dl" >/dev/null 2>&1 || { apm_err "缺少下载工具 $_dl"; return 1; }
    rm -f -- "$2"
    # 下载阶段没有副作用, 允许 Ctrl+C 与断线中止: exit 会触发调用方的 EXIT trap 清理临时目录与锁
    trap 'exit 130' HUP INT TERM
    "$_dl" -q -T 30 -O "$2" "$1" 2>/dev/null && [ -s "$2" ]
    _rc=$?
    if [ "$SNELL_LOCKED" = 1 ]; then _snell_signals_ignore; else trap - HUP INT TERM; fi
    return "$_rc"
}

_snell_ensure_staging() {
    local _vt
    [ -z "$SNELL_STAGING" ] || return 0
    _vt=$(env_path /var/tmp)
    mkdir -p -- "$_vt" || return 1
    SNELL_STAGING=$(mktemp -d "$_vt/apm-snell.XXXXXX") || { apm_err "无法创建临时目录"; return 1; }
    chmod 700 -- "$SNELL_STAGING"
}

# 依赖: 只在写操作里安装, 只读命令绝不调用
_snell_ensure_deps() {
    local _p _missing
    _missing=
    for _p in $SNELL_DEPS; do
        _snell_run apk info -e "$_p" >/dev/null 2>&1 || _missing="$_missing $_p"
    done
    [ -n "$_missing" ] || return 0
    _snell_say "安装运行依赖:$_missing"
    # shellcheck disable=SC2086
    _snell_run apk add --no-cache $_missing >/dev/null 2>&1 || {
        apm_err "安装运行依赖失败:$_missing"
        return 1
    }
}

# 下载, 校验并试运行, 设置 SNELL_NEW_BIN SNELL_NEW_REPORTED
_snell_stage_release() {
    local _tag _arch _url _zip _dir _out
    _tag=$1
    _arch=$(_snell_asset_arch) || { apm_err "当前 CPU 架构没有 Snell 官方 Server 二进制 (支持 amd64, aarch64, i386)"; return 1; }
    _snell_ensure_staging || return 1
    _url="${APM_SNELL_DL_BASE:-$SNELL_DL_BASE_DEFAULT}/snell-server-$_tag-linux-$_arch.zip"
    _zip=$SNELL_STAGING/snell.zip
    _dir=$SNELL_STAGING/x
    _snell_say "下载 $_url"
    _snell_fetch "$_url" "$_zip" || { apm_err "下载失败: $_url"; return 1; }
    unzip -l "$_zip" >/dev/null 2>&1 || { apm_err "压缩包损坏或格式无效"; return 1; }
    mkdir -p -- "$_dir"
    unzip -o -q "$_zip" snell-server -d "$_dir" >/dev/null 2>&1 || { apm_err "压缩包内没有 snell-server 或解压失败"; return 1; }
    SNELL_NEW_BIN=$_dir/snell-server
    [ "$(core_file_kind "$SNELL_NEW_BIN")" = elf ] || { apm_err "下载的 snell-server 不是 ELF, 拒绝运行"; return 1; }
    chmod 755 -- "$SNELL_NEW_BIN"
    _snell_chown root:root "$SNELL_NEW_BIN" || { apm_err "设置 snell-server 属主失败"; return 1; }
    _out=$(_core_timeout "$SNELL_NEW_BIN" -v 2>&1 | head -n 3)
    SNELL_NEW_REPORTED=$(printf '%s\n' "$_out" | sed -n 's/.*snell-server \(v[0-9][0-9A-Za-z.]*\).*/\1/p' | head -n 1)
    case $SNELL_NEW_REPORTED in
        v6.*) ;;
        *) apm_err "新的 snell-server 无法执行或不是 Snell v6, 可能缺少 gcompat, libstdc++, libgcc, 或临时目录以 noexec 挂载"; return 1 ;;
    esac
}

# ---- 元数据 ----

# _snell_write_meta EXACT REPORTED CREATED_USER CREATED_GROUP, 先写候选再校验再原子替换
_snell_write_meta() {
    local _f _c
    _f=$(core_meta_file snell)
    state_ensure_dirs || return 1
    _c=$(txn_new_candidate "$_f") || return 1
    {
        printf 'schema=1\nmanaged=true\ncore=snell\n'
        printf 'exact_release=%s\nreported_version=%s\n' "$1" "$2"
        printf 'binary_path=%s\nconfig_path=%s\nservice_name=snell\nlog_dir=%s\n' "$SNELL_BIN" "$SNELL_CONF" "$SNELL_LOG_DIR"
        printf 'installed_at=%s\ncreated_user=%s\ncreated_group=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$4"
    } > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# 更新元数据里的一个键值, 用于 update 成功后
_snell_update_meta() { # EXACT REPORTED
    local _f _c
    _f=$(core_meta_file snell)
    _c=$(txn_new_candidate "$_f") || return 1
    awk -v e="$1" -v r="$2" '
        /^exact_release=/ { print "exact_release=" e; next }
        /^reported_version=/ { print "reported_version=" r; next }
        { print }' "$_f" > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# ---- OpenRC 脚本 ----

_snell_write_init() {
    local _t
    _t=$(env_path "$SNELL_INIT")
    mkdir -p -- "$(dirname "$_t")" || return 1
    cat > "$_t" <<'EOF'
#!/sbin/openrc-run
# apm-managed: snell
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager snell 管理, 手工修改可能被覆盖

name="snell"
description="Snell proxy server (managed by Alpine Proxy Manager)"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_user="snell:snell"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=5
respawn_period=60
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/snell/access.log"
error_log="/var/log/snell/error.log"
required_files="/etc/snell/snell-server.conf"
# 官方二进制是 glibc 程序, Alpine 上通过 gcompat 运行
export LD_PRELOAD="/lib/libgcompat.so.0"

depend() {
    need net
    after firewall
}

start_pre() {
    # 降权运行的进程必须能写日志, 否则会静默启动失败
    checkpath -d -m 0750 -o snell:snell /var/log/snell
    checkpath -f -m 0640 -o snell:snell /var/log/snell/access.log
    checkpath -f -m 0640 -o snell:snell /var/log/snell/error.log
}
EOF
    chmod 755 -- "$_t"
}

# ---- 启停与健康检查 ----

_snell_wait_secs() { printf '%s' "${APM_SNELL_WAIT:-15}"; }

# 等待: OpenRC 为 running, 找到服务进程, 配置里的每个端口都处于监听
_snell_wait_healthy() {
    local _t _max _p _ok
    _max=$(_snell_wait_secs)
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover snell
        if [ "$CF_STATE" = running ] && [ -n "$CF_PID" ] && [ -n "$CF_SNELL_LISTEN" ]; then
            _ok=1
            for _p in $(_snell_ports_of "$CF_SNELL_LISTEN"); do
                printf '%s\n' "$CF_LISTEN" | grep -q ":$_p " || _ok=0
            done
            [ "$_ok" = 1 ] && return 0
        fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_snell_wait_stopped() {
    local _t _max
    _max=$(_snell_wait_secs)
    _t=0
    while [ "$_t" -le "$_max" ]; do
        core_discover snell
        # 用服务状态而不是 CF_STATE, 二进制损坏时 CF_STATE 恒为 broken
        if [ "$CF_SERVICE_STATE" = stopped ] && [ -z "$CF_PID" ]; then
            return 0
        fi
        [ "$_t" -lt "$_max" ] && sleep 1
        _t=$((_t + 1))
    done
    return 1
}

_snell_show_failure() {
    apm_err "服务状态: ${CF_SERVICE_STATE:-未知}"
    if [ -n "${CF_LOG_ERR:-}" ] && [ -f "$(env_path "$CF_LOG_ERR")" ]; then
        apm_err "最近日志 ($CF_LOG_ERR, 可能含目标域名):"
        tail -n 10 "$(env_path "$CF_LOG_ERR")" 2>/dev/null | sed 's/^/    /' >&2
    fi
}

# ---- install ----

# 回滚本次安装创建的东西, 按相反顺序, 只处理对应标志位为 1 的步骤
_snell_install_rollback() {
    if [ "${R_STARTED:-0}" = 1 ]; then
        _snell_rc stop >/dev/null 2>&1
    fi
    [ "${R_RCUPDATE:-0}" = 1 ] && _snell_run rc-update del snell default >/dev/null 2>&1
    [ "${R_INIT:-0}" = 1 ] && rm -f -- "$(env_path "$SNELL_INIT")"
    [ "${R_BIN:-0}" = 1 ] && rm -f -- "$(env_path "$SNELL_BIN")" "$(env_path "$SNELL_BIN").new"
    if [ "${R_CONF:-0}" = 1 ]; then
        rm -f -- "$(env_path "$SNELL_CONF")"
        rm -f -- "$(env_path "$SNELL_CONF_DIR")"/.snell-server.conf.cand.* 2>/dev/null
    fi
    [ "${R_LOGDIR:-0}" = 1 ] && rm -rf -- "$(env_path "$SNELL_LOG_DIR")"
    [ "${R_MARK_USER:-0}" = 1 ] && rm -f -- "$(env_path "$SNELL_CONF_DIR")/.apm-created-user"
    [ "${R_MARK_GROUP:-0}" = 1 ] && rm -f -- "$(env_path "$SNELL_CONF_DIR")/.apm-created-group"
    [ "${R_CONFDIR:-0}" = 1 ] && rmdir "$(env_path "$SNELL_CONF_DIR")" 2>/dev/null
    [ "${R_USER:-0}" = 1 ] && _snell_run deluser "$SNELL_USER" >/dev/null 2>&1
    [ "${R_GROUP:-0}" = 1 ] && _snell_run delgroup "$SNELL_GROUP" >/dev/null 2>&1
    rm -f -- "$(core_meta_file snell)"
    return 0
}

_snell_group_exists() { grep -q "^$SNELL_GROUP:" "$(env_path /etc/group)" 2>/dev/null; }
_snell_user_exists() { grep -q "^$SNELL_USER:" "$(env_path /etc/passwd)" 2>/dev/null; }

_snell_install_fail() {
    apm_err "$1"
    _snell_say "正在回滚本次安装"
    _snell_install_rollback
    return 1
}

snell_install() {
    local _release _port _listen _psk _psk_mode _tag _reuse _stdin_psk _a _cmark _gmark
    _release=$SNELL_DEFAULT_RELEASE
    _port=
    _listen=
    _psk=
    _psk_mode=generate
    while [ $# -gt 0 ]; do
        case $1 in
            --release) [ $# -ge 2 ] || { apm_err "--release 需要参数"; return 2; }; _release=$2; shift ;;
            --port) [ $# -ge 2 ] || { apm_err "--port 需要参数"; return 2; }; _port=$2; shift ;;
            --listen) [ $# -ge 2 ] || { apm_err "--listen 需要参数"; return 2; }; _listen=$2; shift ;;
            --psk-stdin) _psk_mode=stdin ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _tag=$(snell_norm_release "$_release")
    _snell_valid_release "$_tag" || { apm_err "release 格式无效: $_release (示例 v6.0.0rc2)"; return 2; }
    [ -z "$_port" ] || _snell_valid_port "$_port" || { apm_err "端口无效: $_port (需要 1025 到 65535)"; return 2; }
    [ -z "$_listen" ] || [ -z "$_port" ] || { apm_err "--port 与 --listen 不能同时使用"; return 2; }
    [ -z "$_listen" ] || _snell_valid_listen "$_listen" || { apm_err "listen 无效"; return 2; }
    _snell_need_root || return 4

    # 已有的部署一律拒绝, 绝不隐式更新或覆盖
    core_discover snell
    if [ "$CF_INSTALLED" != no ] || [ -n "$CF_SERVICE" ]; then
        if [ "$CF_MANAGED" = yes ]; then
            apm_err "Snell 已经由 Alpine Proxy Manager 安装, 如需升级请使用 snell update"
        elif [ "$CF_META_STATE" = invalid ]; then
            apm_err "检测到 Snell 相关文件且 Manager 元数据异常, 归属不明, 拒绝安装"
        else
            apm_err "发现现有 Snell 部署, 当前不会覆盖或接管"
        fi
        return 4
    fi
    for _a in "$SNELL_BIN" "$SNELL_INIT"; do
        if [ -e "$(env_path "$_a")" ] || [ -L "$(env_path "$_a")" ]; then
            apm_err "检测到残留文件 $_a, 为避免覆盖已停止安装"
            return 4
        fi
    done
    if [ -e "$(core_meta_file snell)" ]; then
        apm_err "检测到残留的 Manager 元数据 $(core_meta_file snell), 归属不明, 为避免覆盖已停止安装"
        return 4
    fi
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT

    # 沿用卸载时保留的有效配置, 否则生成新配置
    _reuse=no
    if [ -e "$(env_path "$SNELL_CONF")" ]; then
        snell_validate_config "$(env_path "$SNELL_CONF")" >/dev/null 2>&1 || {
            apm_err "检测到已有配置 $SNELL_CONF 但它无效, 请先处理 (或 snell uninstall --purge 的残留) 后再安装"
            return 4
        }
        _reuse=yes
        _listen=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$(env_path "$SNELL_CONF")" | head -n 1 | sed 's/[[:space:]]*$//')
        _snell_say "沿用已保留的配置 $SNELL_CONF"
    elif [ -z "$_listen" ]; then
        [ -n "$_port" ] || _port=$(_snell_rand_port) || { apm_err "无法选出可用的随机端口"; return 1; }
        _listen="0.0.0.0:$_port"
    fi
    for _a in $(_snell_ports_of "$_listen"); do
        if _snell_port_in_use "$_a"; then
            apm_err "端口 $_a 已被占用"
            return 1
        fi
    done
    if [ "$_reuse" = no ]; then
        if [ "$_psk_mode" = stdin ]; then
            IFS= read -r _psk || :
            _snell_valid_psk "$_psk" || { apm_err "从标准输入读取的 psk 无效 (16 到 128 位字母数字或 _ -)"; return 2; }
        else
            _psk=$(_snell_gen_psk) || { apm_err "生成 PSK 失败 (/dev/urandom 不可用?)"; return 1; }
        fi
    fi

    _snell_say "[1/7] 依赖"
    _snell_ensure_deps || return 1
    _snell_say "[2/7] 下载并校验 Snell $_tag"
    _snell_stage_release "$_tag" || return 1

    R_STARTED=0 R_RCUPDATE=0 R_INIT=0 R_BIN=0 R_CONF=0 R_LOGDIR=0 R_MARK_USER=0 R_MARK_GROUP=0 R_CONFDIR=0 R_USER=0 R_GROUP=0
    _cmark=no
    _gmark=no
    _snell_say "[3/7] 用户与目录"
    if _snell_group_exists; then
        [ ! -f "$(env_path "$SNELL_CONF_DIR")/.apm-created-group" ] || _gmark=yes
    else
        _snell_run addgroup -S "$SNELL_GROUP" >/dev/null 2>&1 || { _snell_install_fail "创建用户组 $SNELL_GROUP 失败"; return 1; }
        R_GROUP=1
        _gmark=yes
    fi
    if _snell_user_exists; then
        [ ! -f "$(env_path "$SNELL_CONF_DIR")/.apm-created-user" ] || _cmark=yes
    else
        _snell_run adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$SNELL_GROUP" "$SNELL_USER" >/dev/null 2>&1 || { _snell_install_fail "创建用户 $SNELL_USER 失败"; return 1; }
        R_USER=1
        _cmark=yes
    fi
    if [ ! -d "$(env_path "$SNELL_CONF_DIR")" ]; then
        mkdir -p -- "$(env_path "$SNELL_CONF_DIR")" || { _snell_install_fail "创建 $SNELL_CONF_DIR 失败"; return 1; }
        R_CONFDIR=1
    fi
    chmod 750 -- "$(env_path "$SNELL_CONF_DIR")"
    _snell_chown "root:$SNELL_GROUP" "$(env_path "$SNELL_CONF_DIR")" || { _snell_install_fail "设置 $SNELL_CONF_DIR 属主失败"; return 1; }
    if [ "$_cmark" = yes ] && [ ! -f "$(env_path "$SNELL_CONF_DIR")/.apm-created-user" ]; then
        : > "$(env_path "$SNELL_CONF_DIR")/.apm-created-user" && R_MARK_USER=1
    fi
    if [ "$_gmark" = yes ] && [ ! -f "$(env_path "$SNELL_CONF_DIR")/.apm-created-group" ]; then
        : > "$(env_path "$SNELL_CONF_DIR")/.apm-created-group" && R_MARK_GROUP=1
    fi
    if [ ! -d "$(env_path "$SNELL_LOG_DIR")" ]; then
        mkdir -p -- "$(env_path "$SNELL_LOG_DIR")" || { _snell_install_fail "创建 $SNELL_LOG_DIR 失败"; return 1; }
        R_LOGDIR=1
    fi
    chmod 750 -- "$(env_path "$SNELL_LOG_DIR")"
    _snell_chown "$SNELL_USER:$SNELL_GROUP" "$(env_path "$SNELL_LOG_DIR")" || { _snell_install_fail "设置 $SNELL_LOG_DIR 属主失败"; return 1; }

    _snell_say "[4/7] 配置"
    if [ "$_reuse" = no ]; then
        _a=$(txn_new_candidate "$(env_path "$SNELL_CONF")") || { _snell_install_fail "无法创建候选配置"; return 1; }
        {
            printf '[snell-server]\nlisten = %s\npsk = %s\nmode = default\n' "$_listen" "$_psk"
        } > "$_a"
        _snell_chown "root:$SNELL_GROUP" "$_a"
        chmod 640 -- "$_a"
        R_CONF=1
        TXN_NEW_MODE=640 txn_commit "$(env_path "$SNELL_CONF")" "$_a" snell_validate_config || { _snell_install_fail "写入配置失败"; return 1; }
    else
        _snell_chown "root:$SNELL_GROUP" "$(env_path "$SNELL_CONF")"
        chmod 640 -- "$(env_path "$SNELL_CONF")"
    fi

    _snell_say "[5/7] 安装二进制与 OpenRC 服务"
    mkdir -p -- "$(dirname "$(env_path "$SNELL_BIN")")"
    R_BIN=1
    { cp -- "$SNELL_NEW_BIN" "$(env_path "$SNELL_BIN").new" && chmod 755 -- "$(env_path "$SNELL_BIN").new" \
        && mv -f -- "$(env_path "$SNELL_BIN").new" "$(env_path "$SNELL_BIN")"; } || { _snell_install_fail "安装 $SNELL_BIN 失败"; return 1; }
    R_INIT=1
    _snell_write_init || { _snell_install_fail "写入 $SNELL_INIT 失败"; return 1; }
    R_RCUPDATE=1
    _snell_run rc-update add snell default >/dev/null 2>&1 || { _snell_install_fail "rc-update add snell default 失败"; return 1; }

    _snell_say "[6/7] 启动并验证"
    R_STARTED=1
    if ! _snell_rc start >/dev/null 2>&1; then
        core_discover snell
        _snell_show_failure
        _snell_install_fail "rc-service snell start 失败"
        return 1
    fi
    if ! _snell_wait_healthy; then
        _snell_show_failure
        _snell_install_fail "Snell 没有在 $(_snell_wait_secs) 秒内进入健康状态 (运行中, 有服务进程, 端口监听)"
        return 1
    fi

    _snell_say "[7/7] 写入 Manager 元数据"
    _snell_write_meta "$_tag" "$SNELL_NEW_REPORTED" "$_cmark" "$_gmark" || { _snell_install_fail "写入元数据失败"; return 1; }

    core_discover snell
    _snell_say ""
    _snell_say "Snell 安装完成并已验证"
    _snell_say "  release：$_tag (二进制自报 $SNELL_NEW_REPORTED)"
    _snell_say "  监听：$_listen (容器或系统内端口, NAT 公网映射需自行配置)"
    _snell_say "  配置：$SNELL_CONF"
    if [ "$_reuse" = no ] && [ "$_psk_mode" = generate ]; then
        _snell_say "  PSK：$_psk"
        _snell_say "  这是自动生成的 PSK, 只在此处显示一次, 之后需要时可用 export 的 secret 操作显式查看, 请自行保存"
    elif [ "$_reuse" = yes ]; then
        _snell_say "  PSK：沿用已保留的配置, 不显示"
    else
        _snell_say "  PSK：已使用你提供的值"
    fi
    _snell_say "  查看状态：proxy-manager snell status"
    trap - EXIT
    _snell_cleanup
}

# ---- start stop restart ----

snell_start() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed no || return 4
    if [ "$CF_STATE" = running ]; then
        _snell_say "Snell 已经在运行"
        return 0
    fi
    if ! _snell_rc start >/dev/null 2>&1; then
        core_discover snell
        _snell_show_failure
        apm_err "rc-service snell start 失败"
        return 1
    fi
    _snell_wait_healthy || { _snell_show_failure; apm_err "Snell 没有进入健康状态"; return 1; }
    _snell_say "Snell 已启动并验证"
}

snell_stop() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed yes || return 4
    if [ "$CF_STATE" = stopped ]; then
        _snell_say "Snell 已经停止"
        return 0
    fi
    _snell_rc stop >/dev/null 2>&1 || { apm_err "rc-service snell stop 失败"; return 1; }
    _snell_wait_stopped || { apm_err "Snell 没有停止"; return 1; }
    _snell_say "Snell 已停止"
}

snell_restart() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed no || return 4
    if ! _snell_rc restart >/dev/null 2>&1; then
        core_discover snell
        _snell_show_failure
        apm_err "rc-service snell restart 失败"
        return 1
    fi
    _snell_wait_healthy || { _snell_show_failure; apm_err "Snell 重启后没有进入健康状态"; return 1; }
    _snell_say "Snell 已重启并验证"
}

# ---- config ----

snell_config_show() {
    core_discover snell
    if [ "$CF_INSTALLED" = no ]; then
        apm_err "未检测到 Snell"
        return 1
    fi
    printf 'Snell 配置 (PSK 已脱敏)\n'
    if [ -z "$CF_CONFIG" ]; then
        printf '  配置：未找到\n'
        return 0
    fi
    printf '  路径：%s\n' "$CF_CONFIG"
    [ -z "$CF_CONFIG_PERM" ] || printf '  权限：%s\n' "$CF_CONFIG_PERM"
    if [ "$CF_CONFIG_READABLE" != yes ]; then
        printf '  无法读取配置\n'
        return 0
    fi
    printf '  listen：%s\n' "${CF_SNELL_LISTEN:--}"
    printf '  mode：%s\n' "${CF_SNELL_MODE:--}"
    case $CF_PSK in
        configured) printf '  psk：已配置\n' ;;
        *) printf '  psk：未配置\n' ;;
    esac
    printf '  管理状态：%s\n' "$(core_managed_label)"
}

# 重启并验证, 用作 txn_commit 的 reload
_snell_reload_verify() {
    _snell_rc restart >/dev/null 2>&1 || return 1
    _snell_wait_healthy
}

# snell config set KEY [VALUE|--stdin|--generate]
snell_config_set() {
    local _key _val _cur _cand _was _newports _p _old _rc
    _key=${1:-}
    shift
    [ -n "$_key" ] || { apm_err "用法: snell config set listen|mode|psk 值"; return 2; }
    case $_key in listen|mode|psk) ;; *) apm_err "不支持的键: $_key (只支持 listen mode psk)"; return 2 ;; esac
    _val=
    GENERATED_PSK=
    if [ "$_key" = psk ]; then
        case ${1:-} in
            --stdin) IFS= read -r _val || : ;;
            --generate) _val=$(_snell_gen_psk) || { apm_err "生成 PSK 失败"; return 1; }; GENERATED_PSK=$_val ;;
            *) apm_err "psk 不接受命令行明文参数, 请使用 --stdin 或 --generate"; return 2 ;;
        esac
        _snell_valid_psk "$_val" || { apm_err "psk 无效 (16 到 128 位字母数字或 _ -)"; return 2; }
    else
        _val=${1:-}
        [ -n "$_val" ] || { apm_err "缺少值"; return 2; }
        case $_key in
            listen) _snell_valid_listen "$_val" || { apm_err "listen 无效"; return 2; } ;;
            mode) _snell_valid_mode "$_val" || { apm_err "mode 取值未确认: $_val (已确认: $SNELL_MODES)"; return 2; } ;;
        esac
    fi
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed no || return 4
    [ "$CF_CONFIG_READABLE" = yes ] || { apm_err "无法读取当前配置"; return 1; }
    _cur=$(env_path "$CF_CONFIG")
    _old=$CF_SNELL_LISTEN
    if [ "$_key" = listen ]; then
        for _p in $(_snell_ports_of "$_val"); do
            case " $(_snell_ports_of "$_old") " in *" $_p "*) continue ;; esac
            if _snell_port_in_use "$_p"; then
                apm_err "端口 $_p 已被占用"
                return 1
            fi
        done
    fi
    _cand=$(txn_new_candidate "$_cur") || return 1
    V=$_val awk -v k="$_key" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = " ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print k " = " ENVIRON["V"] }' "$_cur" > "$_cand" || { rm -f -- "$_cand"; return 1; }
    _snell_chown "root:$SNELL_GROUP" "$_cand"
    chmod 640 -- "$_cand"
    _was=$CF_STATE
    APM_BACKUP_KEEP=${APM_BACKUP_KEEP:-2}
    export APM_BACKUP_KEEP
    if [ "$_was" = running ]; then
        txn_commit "$_cur" "$_cand" snell_validate_config _snell_reload_verify
    else
        txn_commit "$_cur" "$_cand" snell_validate_config
    fi
    _rc=$?
    case $_rc in
        0) ;;
        12)
            apm_err "新配置下 Snell 没有进入健康状态, 已恢复旧配置"
            _snell_say "正在用旧配置重新启动"
            if _snell_reload_verify; then
                _snell_say "已恢复旧配置并验证 Snell 正常运行"
            else
                _snell_show_failure
                apm_err "恢复旧配置后 Snell 仍不健康, 请查看日志"
            fi
            return 1
            ;;
        10) apm_err "新配置校验失败, 当前配置未改动"; return 1 ;;
        *) apm_err "配置更新失败 (代码 $_rc)"; return 1 ;;
    esac
    if [ "$_key" = psk ]; then
        _snell_say "psk 已更新"
        if [ -n "$GENERATED_PSK" ]; then
            _snell_say "  新 PSK：$GENERATED_PSK"
            _snell_say "  这是自动生成的 PSK, 只在此处显示一次, 之后需要时可用 export 的 secret 操作显式查看, 请自行保存"
        fi
    else
        _snell_say "$_key 已更新为 $_val"
    fi
    if [ "$_was" = running ]; then
        _snell_say "Snell 已重启并验证"
    else
        _snell_say "Snell 当前未运行, 配置已写入, 下次启动生效"
    fi
}

# ---- update ----

snell_update() {
    local _release _tag _force _cur_exact _was _bin _old _rc _new_reported _st
    _release=$SNELL_DEFAULT_RELEASE
    _force=0
    while [ $# -gt 0 ]; do
        case $1 in
            --force) _force=1 ;;
            v*) _release=$1 ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _tag=$(snell_norm_release "$_release")
    _snell_valid_release "$_tag" || { apm_err "release 格式无效: $_release (示例 v6.0.0rc2)"; return 2; }
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed yes || return 4
    _cur_exact=$CF_VERSION_EXACT
    _snell_say "当前 release：$_cur_exact (二进制自报 ${CF_VERSION_REPORTED:-未知})"
    _snell_say "目标 release：$_tag"
    if [ "$_cur_exact" = "$_tag" ] && [ "$_force" = 0 ] && [ "$CF_STATE" != broken ]; then
        _snell_say "已经是目标版本, 无需更新 (--force 可强制重装二进制)"
        return 0
    fi
    _was=$CF_STATE
    _snell_ensure_deps || return 1
    _snell_stage_release "$_tag" || { apm_err "更新已中止, 现有版本未改动"; return 1; }
    _new_reported=$SNELL_NEW_REPORTED
    _bin=$(env_path "$SNELL_BIN")
    _old=$_bin.old

    cp -p -- "$_bin" "$_old" || { apm_err "备份旧二进制失败, 更新已中止"; return 1; }
    if [ "$_was" = running ]; then
        if ! _snell_rc stop >/dev/null 2>&1 || ! _snell_wait_stopped; then
            rm -f -- "$_old"
            apm_err "停止 Snell 失败, 更新已中止, 现有版本未改动"
            _snell_rc start >/dev/null 2>&1
            return 1
        fi
    fi
    if ! { cp -- "$SNELL_NEW_BIN" "$_bin.new" && chmod 755 -- "$_bin.new" && mv -f -- "$_bin.new" "$_bin"; }; then
        apm_err "替换二进制失败, 恢复旧版本"
        rm -f -- "$_bin.new"
        mv -f -- "$_old" "$_bin"
        [ "$_was" != running ] || { _snell_rc start >/dev/null 2>&1; _snell_wait_healthy; }
        return 1
    fi
    _rc=0
    if [ "$_was" = running ]; then
        _snell_rc start >/dev/null 2>&1 || _rc=1
        [ "$_rc" = 0 ] && { _snell_wait_healthy || _rc=1; }
    else
        # 之前没在运行就不启动, 只确认新二进制能给出版本
        _st=$(_core_timeout "$_bin" -v 2>&1 | sed -n 's/.*snell-server \(v[0-9][0-9A-Za-z.]*\).*/\1/p' | head -n 1)
        [ -n "$_st" ] || _rc=1
    fi
    if [ "$_rc" = 0 ] && _snell_update_meta "$_tag" "$_new_reported"; then
        rm -f -- "$_old"
        _snell_say "更新完成并已验证: $_cur_exact -> $_tag (二进制自报 $_new_reported)"
        return 0
    fi
    apm_err "新版本验证失败, 回滚到旧版本"
    core_discover snell
    _snell_show_failure
    _snell_rc stop >/dev/null 2>&1
    if mv -f -- "$_old" "$_bin"; then
        if [ "$_was" = running ]; then
            if _snell_rc start >/dev/null 2>&1 && _snell_wait_healthy; then
                _snell_say "已回滚并恢复运行: $_cur_exact"
            else
                apm_err "回滚后仍无法启动, 请查看日志"
            fi
        else
            _snell_say "已回滚到旧二进制 (更新前未在运行)"
        fi
    else
        apm_err "恢复旧二进制失败, 备份保留在 $_old"
    fi
    return 1
}

# ---- uninstall ----

snell_uninstall() {
    local _purge _cu _cg _bk _f
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
    core_discover snell
    if [ "$CF_INSTALLED" = no ] && [ "$CF_META_STATE" = none ] && [ -z "$CF_SERVICE" ]; then
        _snell_say "Snell 未安装, 无需卸载"
        return 0
    fi
    if [ "$CF_INSTALLED" = no ] && [ "$CF_META_STATE" = valid ] && [ "$(kv_get "$(core_meta_file snell)" managed)" = true ]; then
        _snell_say "二进制已不存在, 清理 Manager 记录的残留"
    else
        _snell_require_managed yes || return 4
    fi
    _cu=$(kv_get "$(core_meta_file snell)" created_user)
    _cg=$(kv_get "$(core_meta_file snell)" created_group)

    if [ "$CF_STATE" = running ] || [ "$CF_STATE" = crashed ] || [ "$CF_SERVICE_STATE" = started ] || [ -n "$CF_PID" ]; then
        _snell_rc stop >/dev/null 2>&1 || { apm_err "停止 Snell 失败, 卸载已中止, 没有删除任何文件"; return 1; }
        _snell_wait_stopped || { apm_err "Snell 没有停止, 卸载已中止, 没有删除任何文件"; return 1; }
    fi
    _snell_run rc-update del snell default >/dev/null 2>&1
    # 只删除带有 apm-managed 标记的服务脚本
    if [ -f "$(env_path "$SNELL_INIT")" ]; then
        if grep -q "^$SNELL_INIT_MARK" "$(env_path "$SNELL_INIT")"; then
            rm -f -- "$(env_path "$SNELL_INIT")"
        else
            apm_warn "$SNELL_INIT 没有 Manager 标记, 已保留"
        fi
    fi
    rm -f -- "$(env_path "$SNELL_BIN")" "$(env_path "$SNELL_BIN").old" "$(env_path "$SNELL_BIN").new"

    if [ "$_purge" = 1 ]; then
        rm -rf -- "$(env_path "$SNELL_CONF_DIR")" "$(env_path "$SNELL_LOG_DIR")"
        rm -f -- "$(state_etc)/snell-endpoint.conf"
        _bk=$(state_backup_dir)
        for _f in "$_bk"/snell-server.conf.bak.*; do
            [ -e "$_f" ] && rm -f -- "$_f"
        done
        if [ "$_cu" = yes ] && _snell_user_exists; then
            _snell_run deluser "$SNELL_USER" >/dev/null 2>&1 || apm_warn "删除用户 $SNELL_USER 失败, 已保留"
        fi
        # Alpine 的 deluser 会顺带删除同名的空用户组, 所以先确认用户组还在
        if [ "$_cg" = yes ] && _snell_group_exists; then
            _snell_run delgroup "$SNELL_GROUP" >/dev/null 2>&1 || apm_warn "删除用户组 $SNELL_GROUP 失败, 已保留"
        fi
    fi
    # 元数据的备份在元数据删除后没有意义, 两种卸载都清理
    for _f in "$(state_backup_dir)"/snell.meta.bak.*; do
        [ -e "$_f" ] && rm -f -- "$_f"
    done
    # 元数据最后删除, 前面失败时仍可证明归属
    rm -f -- "$(core_meta_file snell)"
    _snell_say "Snell 已卸载"
    if [ "$_purge" = 1 ]; then
        _snell_say "已删除: 服务, 二进制, 配置, 日志, 配置备份, 元数据 (以及由 Manager 创建的用户与用户组)"
    else
        _snell_say "已保留: 配置 $SNELL_CONF, 日志 $SNELL_LOG_DIR, 用户 $SNELL_USER (重新安装会沿用配置, snell uninstall --purge 才会删除)"
    fi
    _snell_say "未移除依赖包 ($SNELL_DEPS), 它们可能被其他程序使用"
}

# ---- CLI ----

snell_cli() {
    local _sub
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        status) report_snell_status ;;
        info) report_snell_info ;;
        log) report_snell_log "${1:-20}" ;;
        install) snell_install "$@" ;;
        start) snell_start ;;
        stop) snell_stop ;;
        restart) snell_restart ;;
        update) snell_update "$@" ;;
        endpoint) snell_endpoint "$@" ;;
        export) snell_export "$@" ;;
        uninstall) snell_uninstall "$@" ;;
        config)
            case ${1:-show} in
                show) snell_config_show ;;
                set) shift; snell_config_set "$@" ;;
                *) apm_err "用法: snell config [show|set 键 值]"; return 2 ;;
            esac
            ;;
        reload|adopt|migrate)
            apm_err "Snell $_sub 尚未实现"
            return 3
            ;;
        *) apm_err "未知的 snell 子命令: $_sub"; return 2 ;;
    esac
}
