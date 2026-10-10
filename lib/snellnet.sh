# shellcheck shell=sh
# Snell 网络功能: SOCKS5 出口 与 目标访问限制
#
# 两个功能互相独立, 可以分别启用与禁用, 但本版本不能同时启用
#   SOCKS5 出口      Snell 访问目标的 TCP UDP DNS 全部经过指定的 SOCKS5 上游, 上游故障时失败, 不会直连
#   目标访问限制     Snell 只能连接名单里的 地址:端口 组合, 其余全部拒绝, 只转发 TCP, UDP 一律拒绝
#
# 实现 官方 Snell 没有这两项能力, 所以用 graftcp (ptrace) 接管 Snell 进程树的 connect 与 UDP,
#   不修改 Snell 二进制, 不改防火墙, 路由, 全局 DNS, 也不影响其他进程
#   SOCKS5 出口      graftcp 直接拨 SOCKS5 上游, Snell 的 DNS 由同一个 graftcp 之下的 unbound 以 TCP 上游完成
#   目标访问限制     graftcp 把连接交给本地 tinyproxy, 名单由 tinyproxy 的 Filter 按 host:port 精确匹配并默认拒绝
#                    域名条目在启动与刷新时解析并固定, Snell 通过只对它自己可见的私有 /etc/hosts 得到固定解析
#
# 关闭功能时 Snell 使用原来的启动方式, 不运行任何辅助进程
# 辅助组件按需安装, graftcp 固定版本加 SHA256, unbound 与 tinyproxy 来自 Alpine 官方仓库
# 卸载 Snell 不移除这些依赖, 它们可能被其他程序使用
#
# 测试接缝: APM_SNN_URL 覆盖 graftcp 下载地址, APM_SNN_SHA256 覆盖固定的校验和,
#           APM_SNN_HOSTS 指定一个 "名字 地址" 文件代替系统解析器, APM_SNN_NO_PREFLIGHT=1 跳过 ptrace 与命名空间探测

# graftcp 是 hmgle/graftcp v0.8.3 加一个小补丁的构建 (按 协议 地址 端口 精确豁免), GPL-3.0-or-later
# 补丁 许可证 构建脚本与对应源码见仓库 third_party/graftcp, 二进制与对应源码包发布在同名的组件 Release graftcp-v0.8.3-apm1 (不是最新版本, 不影响 Manager 的检查更新)
SNN_GRAFTCP_VER="v0.8.3-apm1"
SNN_GRAFTCP_SHA256_X86_64="a066be3d66abb556414258e26bb4427e93dee2fb48b6b19b1dfe0f77e8df389d"
SNN_GRAFTCP_URL_DEFAULT="https://github.com/csjcsl666/alpine-proxy-manager/releases/download/graftcp-v0.8.3-apm1/graftcp-v0.8.3-apm1-linux-x86_64"
SNN_EXT_DIR="/usr/local/lib/alpine-proxy-manager/ext"
SNN_GRAFTCP="/usr/local/lib/alpine-proxy-manager/ext/graftcp"
SNN_RUN="/run/apm-snell"
SNN_GW_PORT=1082
SNN_DNS_ADDR="127.0.0.53"
SNN_DNS_SERVER_DEFAULT="1.1.1.1"
SNN_MAX_DEST=100
SNN_PKGS_EGRESS="unbound"
SNN_PKGS_ACCESS="tinyproxy"

# ---- 路径 ----

_snn_egress_file() { printf '%s/snell-egress.conf' "$(state_etc)"; }
_snn_access_file() { printf '%s/snell-access.conf' "$(state_etc)"; }
_snn_dir() { printf '%s/snellnet' "$(state_var)"; }
_snn_pins_file() { printf '%s/pins' "$(_snn_dir)"; }
_snn_meta_file() { printf '%s/deps.meta' "$(_snn_dir)"; }
_snn_rundir() { env_path "$SNN_RUN"; }
# 服务脚本里写稳定的 current 路径, 升级后仍然有效
_snn_home() { printf '%s' "${APM_SNN_HOME:-/usr/local/lib/alpine-proxy-manager/current}"; }

# ---- 模式 ----

# 输出 none | egress | access | conflict
snn_mode() {
    local _e _a
    _e=0
    _a=0
    [ -f "$(_snn_egress_file)" ] && [ "$(kv_get "$(_snn_egress_file)" enabled)" = true ] && _e=1
    [ -f "$(_snn_access_file)" ] && [ "$(kv_get "$(_snn_access_file)" enabled)" = true ] && _a=1
    if [ "$_e" = 1 ] && [ "$_a" = 1 ]; then printf 'conflict'
    elif [ "$_e" = 1 ]; then printf 'egress'
    elif [ "$_a" = 1 ]; then printf 'access'
    else printf 'none'
    fi
}

snn_mode_label() {
    case $1 in
        egress) printf 'SOCKS5 出口' ;;
        access) printf '目标访问限制' ;;
        *) printf '关闭' ;;
    esac
}

# ---- 地址规范化 ----

# 小写合法 IPv6 (无方括号) 输出 RFC 5952 压缩形式, graftcp 与 tinyproxy 使用同一种文本, 过滤器才能按文本匹配
_snn_ipv6_canon() {
    awk -v a="$1" 'BEGIN {
        i = index(a, "::")
        if (i) {
            left = substr(a, 1, i - 1); right = substr(a, i + 2)
            nl = (left == "") ? 0 : split(left, L, ":"); nr = (right == "") ? 0 : split(right, R, ":")
            miss = 8 - nl - nr
            for (k = 1; k <= nl; k++) g[k] = L[k]
            for (k = 1; k <= miss; k++) g[nl + k] = "0"
            for (k = 1; k <= nr; k++) g[nl + miss + k] = R[k]
        } else split(a, g, ":")
        for (k = 1; k <= 8; k++) { sub(/^0+/, "", g[k]); if (g[k] == "") g[k] = "0" }
        best = 0; bl = 0; cur = 0; cl = 0
        for (k = 1; k <= 8; k++) {
            if (g[k] == "0") { if (cl == 0) cur = k; cl++; if (cl > bl) { bl = cl; best = cur } }
            else cl = 0
        }
        out = ""
        for (k = 1; k <= 8; k++) {
            if (bl >= 2 && k == best) { out = out "::"; k += bl - 1; continue }
            if (out != "" && substr(out, length(out)) != ":") out = out ":"
            out = out g[k]
        }
        print out }'
}

# 把用户输入的 HOST PORT 规范化为 host:port, 主机可以是 IPv4, IPv6 (带或不带方括号) 或主机名
# 成功输出规范形式并返回 0, 失败输出原因并返回 1
_snn_hostport() {
    local _n _h _p
    _n=$(_sb_socks_host_normalize "$1" "$2") || { printf '%s' "$_n"; return 1; }
    _h=${_n%:*}
    _p=${_n##*:}
    case $_h in
        \[*\]) _h=$(_snn_ipv6_canon "${_h#\[}"); _h=${_h%\]}; printf '[%s]:%s' "$_h" "$_p" ;;
        *) printf '%s:%s' "$_h" "$_p" ;;
    esac
}

# host:port 里的主机部分
_snn_hp_host() { printf '%s' "${1%:*}"; }
_snn_hp_port() { printf '%s' "${1##*:}"; }

# 主机部分是不是名字 (不是 IPv4 也不是 [IPv6])
_snn_is_name() {
    case $1 in \[*\]) return 1 ;; esac
    printf '%s' "$1" | grep -Eq '^[0-9.]+$' && return 1
    return 0
}

# ---- 校验 ----

_snn_secret_ok() { _sb_socks_secret_ok "$1"; }

# SOCKS5 出口配置
#   enabled host port [username password] [dns_server]
snn_check_egress() { # FILE
    local _f _rc _k _h _p _n _u _w _d
    _f=$1
    _rc=0
    [ -r "$_f" ] || { apm_err "$_f: 无法读取"; return 1; }
    kv_check_syntax "$_f" || return 1
    for _k in $(kv_keys "$_f"); do
        case $_k in enabled|host|port|username|password|dns_server) ;; *) apm_err "$_f: 未知的键: $_k"; _rc=1 ;; esac
    done
    is_bool "$(kv_get "$_f" enabled)" || { apm_err "$_f: enabled 必须是 true 或 false"; _rc=1; }
    _h=$(kv_get "$_f" host)
    _p=$(kv_get "$_f" port)
    if [ -n "$_h" ] || [ -n "$_p" ]; then
        _n=$(_snn_hostport "$_h" "$_p") || { apm_err "$_f: SOCKS5 服务器地址无效: $_n"; return 1; }
        [ "$(_snn_hp_host "$_n")" = "$_h" ] || { apm_err "$_f: host 不是规范形式 (应为 $(_snn_hp_host "$_n"))"; _rc=1; }
    elif [ "$(kv_get "$_f" enabled)" = true ]; then
        apm_err "$_f: 启用时必须设置 host 与 port"
        _rc=1
    fi
    _u=$(kv_get "$_f" username)
    _w=$(kv_get "$_f" password)
    if { [ -n "$_u" ] && [ -z "$_w" ]; } || { [ -z "$_u" ] && [ -n "$_w" ]; }; then
        apm_err "$_f: username 与 password 必须同时设置或同时留空"
        _rc=1
    elif [ -n "$_u" ]; then
        _snn_secret_ok "$_u" || { apm_err "$_f: username 无效 (可打印 ASCII, 首尾不是空格, 最长 255 字节)"; _rc=1; }
        _snn_secret_ok "$_w" || { apm_err "$_f: password 无效 (可打印 ASCII, 首尾不是空格, 最长 255 字节)"; _rc=1; }
    fi
    _d=$(kv_get "$_f" dns_server)
    if [ -n "$_d" ]; then
        if printf '%s' "$_d" | grep -Eq '^[0-9.]+$'; then
            _sb_valid_ipv4_dest "$_d" || { apm_err "$_f: dns_server 不是有效的 IPv4 地址: $_d"; _rc=1; }
        else
            _sb_valid_ipv6_dest "$_d" || { apm_err "$_f: dns_server 必须是 IPv4 或 IPv6 地址: $_d"; _rc=1; }
        fi
    fi
    return "$_rc"
}

# 一个目标是不是网关或内部组件自己的地址, 这些绝不能出现在名单里, 否则客户端能访问到网关本身
_snn_is_internal() { # 规范 host:port
    case $1 in
        "127.0.0.1:$SNN_GW_PORT"|"[::1]:$SNN_GW_PORT"|"0.0.0.0:$SNN_GW_PORT"|"[::]:$SNN_GW_PORT") return 0 ;;
        "$SNN_DNS_ADDR:53") return 0 ;;
    esac
    return 1
}

# 目标访问限制配置
#   enabled destination.N=host:port
snn_check_access() { # FILE
    local _f _rc _k _v _n _seen _c
    _f=$1
    _rc=0
    [ -r "$_f" ] || { apm_err "$_f: 无法读取"; return 1; }
    kv_check_syntax "$_f" || return 1
    is_bool "$(kv_get "$_f" enabled)" || { apm_err "$_f: enabled 必须是 true 或 false"; _rc=1; }
    _seen=
    _c=0
    for _k in $(kv_keys "$_f"); do
        case $_k in
            enabled) ;;
            destination.*)
                _c=$((_c + 1))
                [ "$_c" -le "$SNN_MAX_DEST" ] || { apm_err "$_f: 目标数量超过上限 $SNN_MAX_DEST"; return 1; }
                case ${_k#destination.} in ''|*[!0-9]*) apm_err "$_f: 键名无效: $_k"; _rc=1; continue ;; esac
                _v=$(kv_get "$_f" "$_k")
                _n=$(_snn_hostport "${_v%:*}" "${_v##*:}") || { apm_err "$_f: $_k 无效: $_n"; _rc=1; continue; }
                [ "$_n" = "$_v" ] || { apm_err "$_f: $_k 不是规范形式 (应为 $_n)"; _rc=1; continue; }
                if _snn_is_internal "$_n"; then apm_err "$_f: $_k 是网关或内部组件自己的地址, 不能加入名单"; _rc=1; continue; fi
                case " $_seen " in *" $_n "*) apm_err "$_f: 重复的目标: $_n"; _rc=1 ;; esac
                _seen="$_seen $_n"
                ;;
            *) apm_err "$_f: 未知的键: $_k"; _rc=1 ;;
        esac
    done
    return "$_rc"
}

# 名单里的全部规范 host:port, 每行一个, 按编号排序
_snn_dests() { # FILE
    local _k
    for _k in $(kv_keys "$1" | grep '^destination\.' | sed 's/^destination\.//' | sort -n); do
        kv_get "$1" "destination.$_k"
        printf '\n'
    done | grep .
}

# ---- 解析与固定 ----

# 解析名字, 每行一个地址, 去重; 测试用 APM_SNN_HOSTS 文件代替系统解析器
_snn_resolve() { # NAME
    if [ -n "${APM_SNN_HOSTS:-}" ]; then
        awk -v n="$1" '$1 == n { for (i = 2; i <= NF; i++) print $i }' "$APM_SNN_HOSTS" | sort -u
        return 0
    fi
    # getent ahosts 的第一列是地址, musl 与 glibc 都有; 过滤成合法的 IPv4 与 IPv6 文本
    getent ahosts "$1" 2>/dev/null | awk '{ print $1 }' | sort -u | grep -E '^[0-9a-fA-F:.]+$'
}

# 一行 "名字 地址" 是当前的固定解析
# 计算固定解析: 名单里每个名字条目, 取最新解析结果; 解析失败沿用上一次成功的固定值 (没有就没有地址, 对应条目不放行)
# 输出 "名字 地址" 行, 地址是规范文本
_snn_compute_pins() { # ACCESS_FILE
    local _hp _h _a _out _old
    _old=$(_snn_pins_file)
    for _hp in $(_snn_dests "$1"); do
        _h=$(_snn_hp_host "$_hp")
        _snn_is_name "$_h" || continue
        _out=$(_snn_resolve "$_h")
        if [ -z "$_out" ] && [ -f "$_old" ]; then
            _out=$(awk -v n="$_h" '$1 == n { print $2 }' "$_old")
            [ -z "$_out" ] || apm_warn "解析 $_h 失败, 沿用上一次的固定地址"
        fi
        [ -n "$_out" ] || { apm_warn "无法解析 $_h, 该条目暂时没有可放行的地址"; continue; }
        for _a in $_out; do
            case $_a in
                *:*) _a=$(_snn_ipv6_canon "$(printf '%s' "$_a" | tr 'A-F' 'a-f')") ;;
            esac
            printf '%s %s\n' "$_h" "$_a"
        done
    done | sort -u
}

# ---- 运行时文件生成 ----

# 把 host:port 写成 tinyproxy Filter 的 ERE 行, 锚定整串, 转义 . [ ]
_snn_filter_line() { # 规范 host:port
    printf '^%s$\n' "$(printf '%s' "$1" | sed 's/\./\\./g; s/\[/\\[/g; s/\]/\\]/g')"
}

# 生成目标访问限制的运行时文件到目录 DIR
#   filter 名单的 ERE, 空名单就是空文件 (默认拒绝)
#   tinyproxy.conf
#   hosts 固定解析, Snell 通过私有 /etc/hosts 看到
#   pins 名字到地址的固定值, 供刷新比较
snn_gen_access() { # ACCESS_FILE DIR
    local _hp _h _p _ports _pf _a
    mkdir -p -- "$2" || return 1
    : > "$2/filter"
    : > "$2/hosts"
    _ports=
    _pf="$2/pins"
    _snn_compute_pins "$1" > "$_pf" || return 1
    for _hp in $(_snn_dests "$1"); do
        _h=$(_snn_hp_host "$_hp")
        _p=$(_snn_hp_port "$_hp")
        if _snn_is_name "$_h"; then
            # 域名条目: 对每个固定地址放行 地址:端口
            while IFS= read -r _a; do
                [ -n "$_a" ] || continue
                case $_a in *:*) _a="[$_a]" ;; esac
                if _snn_is_internal "$_a:$_p"; then apm_warn "$_h 解析到网关自己的地址 $_a:$_p, 已忽略"; continue; fi
                _snn_filter_line "$_a:$_p" >> "$2/filter"
            done <<PINS
$(awk -v n="$_h" '$1 == n { print $2 }' "$_pf")
PINS
        else
            _snn_filter_line "$_hp" >> "$2/filter"
        fi
        case " $_ports " in *" $_p "*) ;; *) _ports="$_ports $_p" ;; esac
    done
    sort -u "$2/filter" -o "$2/filter"
    # 私有 hosts: 名字到固定地址; 没有登记的名字走普通 DNS, 受限模式下 UDP 被拒绝, 查不到
    awk '{ print $2, $1 }' "$_pf" > "$2/hosts"
    {
        printf 'Port %s\nListen 127.0.0.1\n' "$SNN_GW_PORT"
        printf 'Timeout 3600\nMaxClients 100\n'
        printf 'Allow 127.0.0.1\nUser nobody\nGroup nobody\n'
        printf 'LogLevel Critical\n'
        printf 'DisableViaHeader Yes\n'
        printf 'FilterDefaultDeny Yes\nFilterType ere\nFilterURLs On\nFilter "%s/filter"\n' "$SNN_RUN"
        for _p in $_ports; do printf 'ConnectPort %s\n' "$_p"; done
    } > "$2/tinyproxy.conf"
    # tinyproxy 降权为 nobody 后仍要读过滤器, Snell 要读私有 hosts: 这两个文件不含机密, 0644
    chmod 644 -- "$2/tinyproxy.conf" "$2/filter" "$2/hosts"
    chmod 600 -- "$2/pins"
}

# graftcp 配置: 密码放在 0600 的配置文件里, 不出现在命令行
snn_gen_graftcp() { # MODE FILE_OF_MODE DIR
    local _h _p _u _w
    case $1 in
        egress)
            _h=$(kv_get "$2" host)
            _p=$(kv_get "$2" port)
            _u=$(kv_get "$2" username)
            _w=$(kv_get "$2" password)
            {
                printf 'select_proxy_mode = only_socks5\n'
                printf 'socks5 = %s:%s\n' "$_h" "$_p"
                [ -z "$_u" ] || printf 'socks5_username = %s\nsocks5_password = %s\n' "$_u" "$_w"
                printf 'udp_proxy = true\ndns_proxy = false\nignore_local = false\n'
            } > "$3/graftcp.conf"
            ;;
        access)
            {
                printf 'select_proxy_mode = only_http_proxy\n'
                printf 'http_proxy = 127.0.0.1:%s\n' "$SNN_GW_PORT"
                # udp_proxy 必须开启: 关闭时 UDP 不被接管会直连, 开启后 HTTP 代理模式拒绝 UDP
                printf 'udp_proxy = true\ndns_proxy = false\nignore_local = false\n'
            } > "$3/graftcp.conf"
            ;;
    esac
    chmod 600 -- "$3/graftcp.conf"
}

# unbound 配置: 只转发到指定的 DNS, 上游查询用 TCP, 这样才会被 graftcp 当作普通连接送进 SOCKS5
snn_gen_unbound() { # EGRESS_FILE DIR
    local _d _v6 _u _z
    _d=$(kv_get "$1" dns_server)
    [ -n "$_d" ] || _d=$SNN_DNS_SERVER_DEFAULT
    _v6=no
    case $_d in *:*) _v6=yes ;; esac
    _u=unbound
    {
        printf 'server:\n    interface: %s\n    port: 53\n    do-ip6: %s\n' "$SNN_DNS_ADDR" "$_v6"
        printf '    access-control: 127.0.0.0/8 allow\n    username: "%s"\n    chroot: ""\n    pidfile: ""\n' "$_u"
        printf '    directory: "%s"\n    num-threads: 1\n' "$SNN_RUN"
        printf '    msg-cache-size: 64k\n    rrset-cache-size: 64k\n    cache-max-ttl: 0\n'
        printf '    tcp-upstream: yes\n    do-not-query-localhost: no\n    module-config: "iterator"\n'
        # unbound 默认把 test example invalid 等保留名字在本地直接答复, 这里只做转发, 一律交给上游解析
        for _z in test example example.com example.net example.org invalid; do
            printf '    local-zone: "%s." nodefault\n' "$_z"
        done
        printf '    use-syslog: no\n    verbosity: 0\n'
        printf 'forward-zone:\n    name: "."\n    forward-addr: %s@53\n' "$_d"
    } > "$2/unbound.conf"
    chmod 600 -- "$2/unbound.conf"
}

# Snell 的运行时配置: 复制管理的配置, SOCKS5 出口模式加上本地 DNS; 属主 root:snell 0640 以便降权后的 Snell 读取
snn_gen_snell_conf() { # MODE DIR
    grep -v -E '^[[:space:]]*dns[[:space:]]*=' "$(env_path "$SNELL_CONF")" > "$2/snell.conf" || return 1
    if [ "$1" = egress ]; then
        printf 'dns = %s\n' "$SNN_DNS_ADDR" >> "$2/snell.conf"
    fi
    chmod 640 -- "$2/snell.conf"
    _snell_chown "root:$SNELL_GROUP" "$2/snell.conf"
}

# 启动脚本: 在 graftcp 的追踪之下运行, 先起 DNS 助手 (SOCKS5 出口), 再把 Snell 降权为 snell 用户
# 目标访问限制且名单有域名时, Snell 在私有挂载命名空间里看到固定解析的 /etc/hosts, 宿主的 /etc/hosts 不变
snn_gen_run() { # MODE DIR
    local _snell
    _snell="LD_PRELOAD=$SNELL_PRELOAD exec $SNELL_BIN -c $SNN_RUN/snell.conf"
    # shellcheck disable=SC2016 # 生成的脚本里的 $n 要原样写出
    {
        printf '#!/bin/sh\n# 由 Alpine Proxy Manager 生成, 在 graftcp 之下运行\n'
        if [ "$1" = egress ]; then
            printf 'env -u LD_PRELOAD unbound -d -c %s/unbound.conf &\n' "$SNN_RUN"
            printf 'n=0\nwhile [ "$n" -lt 100 ]; do\n'
            printf '    grep -q "^ *[0-9]*: 3500007F:0035 " /proc/net/udp && break\n'
            printf '    n=$((n + 1)); sleep 0.1\ndone\n'
            printf '[ "$n" -lt 100 ] || exit 1\n'
            printf 'exec su -s /bin/sh %s -c '"'"'%s'"'"'\n' "$SNELL_USER" "$_snell"
        elif [ -s "$2/hosts" ]; then
            printf 'exec unshare -m /bin/sh -c '"'"'mount --make-rprivate / && mount --bind %s/hosts /etc/hosts && exec su -s /bin/sh %s -c "%s"'"'"'\n' "$SNN_RUN" "$SNELL_USER" "$_snell"
        else
            printf 'exec su -s /bin/sh %s -c '"'"'%s'"'"'\n' "$SNELL_USER" "$_snell"
        fi
    } > "$2/run.sh"
    chmod 755 -- "$2/run.sh"
}

# 生成运行时目录: 启动时由服务脚本在启动包装脚本之前调用, 每次启动都重新生成 (域名在这里重新解析并固定)
snn_prepare() {
    local _mode _d _f
    _mode=$(snn_mode)
    case $_mode in egress|access) ;; *) apm_err "没有启用的 Snell 网络功能 ($_mode)"; return 1 ;; esac
    _d=$(_snn_rundir)
    rm -rf -- "$_d"
    mkdir -p -- "$_d" && chmod 755 -- "$_d" || return 1
    _f=$(_snn_file_of "$_mode")
    "$(_snn_check_of "$_mode")" "$_f" || return 1
    case $_mode in
        access)
            snn_gen_access "$_f" "$_d" || return 1
            # 记住这一次固定下来的解析, 刷新时据此判断有没有变化, 解析失败时也沿用它
            mkdir -p -- "$(_snn_dir)" && cp -- "$_d/pins" "$(_snn_pins_file)" && chmod 600 -- "$(_snn_pins_file)" || return 1
            ;;
        egress) snn_gen_unbound "$_f" "$_d" || return 1 ;;
    esac
    snn_gen_graftcp "$_mode" "$_f" "$_d" || return 1
    snn_gen_snell_conf "$_mode" "$_d" || return 1
    snn_gen_run "$_mode" "$_d" || return 1
    {
        printf 'MODE=%s\nRUN=%s\nGC=%s\nDNS=%s\nSNELL_BIN=%s\nGW_PORT=%s\n' "$_mode" "$SNN_RUN" "$SNN_GRAFTCP" "$SNN_DNS_ADDR" "$SNELL_BIN" "$SNN_GW_PORT"
    } > "$_d/runner.env"
    printf '%s\n' "$_mode" > "$_d/mode"
}

# ---- 依赖 ----

_snn_arch_ok() {
    case ${APM_ARCH:-$(uname -m)} in
        x86_64) return 0 ;;
        *) apm_err "Snell 的 SOCKS5 出口与目标访问限制目前只在 x86_64 上验证, 当前架构 ${APM_ARCH:-$(uname -m)} 不支持"; return 1 ;;
    esac
}

_snn_pkgs_of() {
    case $1 in egress) printf '%s' "$SNN_PKGS_EGRESS" ;; access) printf '%s' "$SNN_PKGS_ACCESS" ;; esac
}

# graftcp 是否已安装且版本是固定的版本
_snn_graftcp_ok() {
    local _b _v
    _b=$(env_path "$SNN_GRAFTCP")
    [ -x "$_b" ] || return 1
    _v=$("$_b" --version 2>&1 | head -n 1)
    case $_v in *"$SNN_GRAFTCP_VER"*) return 0 ;; esac
    return 1
}

# 缺少的组件, 每行一个: graftcp 或 apk:包名
snn_deps_missing() { # MODE
    local _p
    _snn_graftcp_ok || printf 'graftcp\n'
    for _p in $(_snn_pkgs_of "$1"); do
        _snell_run apk info -e "$_p" >/dev/null 2>&1 || printf 'apk:%s\n' "$_p"
    done
}

_snn_install_graftcp() {
    local _url _bin _sum _want _dst _v
    _snell_ensure_staging || return 1
    _snell_ensure_deps || return 1
    _want=${APM_SNN_SHA256:-$SNN_GRAFTCP_SHA256_X86_64}
    _url=${APM_SNN_URL:-$SNN_GRAFTCP_URL_DEFAULT}
    _bin=$SNELL_STAGING/graftcp
    _snell_say "下载 $_url"
    _snell_fetch "$_url" "$_bin" || { apm_err "下载失败: $_url"; return 1; }
    _sum=$(sha256sum "$_bin" | awk '{ print $1 }')
    [ "$_sum" = "$_want" ] || { apm_err "graftcp 校验和不匹配: 期望 $_want, 实际 $_sum"; return 1; }
    [ "$(core_file_kind "$_bin")" = elf ] || { apm_err "graftcp 不是 ELF, 拒绝安装"; return 1; }
    chmod 755 -- "$_bin"
    _v=$("$_bin" --version 2>&1 | head -n 1)
    case $_v in *"$SNN_GRAFTCP_VER"*) ;; *) apm_err "graftcp 无法执行或版本不是 $SNN_GRAFTCP_VER: $_v"; return 1 ;; esac
    _dst=$(env_path "$SNN_GRAFTCP")
    mkdir -p -- "$(dirname "$_dst")" || return 1
    chmod 755 -- "$(dirname "$_dst")" 2>/dev/null
    _snell_chown root:root "$_bin" || return 1
    atomic_install "$_bin" "$_dst" 755 || { apm_err "安装 graftcp 失败"; return 1; }
    SNN_NEW_ARCHIVE_SHA=$_sum
    return 0
}

# 记录依赖来源: graftcp 版本与校验和, 以及由 Manager 安装的软件包 (卸载时据此提示, 不自动删除)
_snn_write_meta() { # APK包列表
    local _f _c _prev
    state_ensure_dirs || return 1
    mkdir -p -- "$(_snn_dir)" && chmod 700 -- "$(_snn_dir)" || return 1
    _f=$(_snn_meta_file)
    _prev=
    [ ! -f "$_f" ] || _prev=$(kv_get "$_f" apk_installed_by_apm)
    _c=$(txn_new_candidate "$_f") || return 1
    {
        printf 'schema=1\ngraftcp_version=%s\n' "$SNN_GRAFTCP_VER"
        printf 'graftcp_sha256=%s\n' "${SNN_NEW_ARCHIVE_SHA:-$(kv_get "$_f" graftcp_sha256 2>/dev/null)}"
        printf 'apk_installed_by_apm=%s\n' "$(printf '%s %s\n' "$_prev" "$1" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')"
        printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$_f" "$_c" kv_check_syntax
}

# 安装缺少的组件; 调用方已经得到用户确认
snn_deps_install() { # MODE
    local _m _apk _item _before
    _apk=
    SNN_NEW_ARCHIVE_SHA=
    for _item in $(snn_deps_missing "$1"); do
        case $_item in
            graftcp) _snn_install_graftcp || return 1 ;;
            apk:*) _apk="$_apk ${_item#apk:}" ;;
        esac
    done
    if [ -n "$_apk" ]; then
        _snell_say "安装软件包:$_apk"
        # shellcheck disable=SC2086
        _snell_run apk add --no-cache $_apk >/dev/null 2>&1 || { apm_err "安装软件包失败:$_apk"; return 1; }
    fi
    _m=$(printf '%s' "$_apk" | sed 's/^ //')
    _snn_write_meta "$_m" || { apm_err "写入依赖记录失败"; return 1; }
}

# ---- 预检 ----

# 本地端口是否已被监听 (任意地址), 协议 tcp 或 udp
_snn_port_busy() { # PROTO PORT
    local _hex _f
    _hex=$(printf '%04X' "$2")
    for _f in "$(env_path "/proc/net/$1")" "$(env_path "/proc/net/${1}6")"; do
        [ -r "$_f" ] || continue
        awk -v h=":$_hex" 'NR > 1 && index($2, h) == length($2) - 3 { f = 1 } END { exit !f }' "$_f" && return 0
    done
    return 1
}

# 启用前必须满足的运行条件, 任何一项不满足都拒绝启用, 不改变现有 Snell
snn_preflight() { # MODE
    local _gc _t
    [ -z "${APM_SNN_NO_PREFLIGHT:-}" ] || return 0
    _gc=$(env_path "$SNN_GRAFTCP")
    command -v su >/dev/null 2>&1 || { apm_err "缺少 su, 无法把 Snell 降权运行"; return 1; }
    # ptrace 是否可用: graftcp 追踪一个立即退出的子进程
    if ! "$_gc" --select_proxy_mode only_socks5 --socks5 127.0.0.1:9 /bin/true >/dev/null 2>&1; then
        apm_err "graftcp 无法追踪子进程: 当前环境限制了 ptrace (容器安全策略, seccomp, Yama ptrace_scope=3 或缺少权限), 无法启用"
        return 1
    fi
    case $1 in
        access)
            if _snn_port_busy tcp "$SNN_GW_PORT"; then
                apm_err "本地端口 $SNN_GW_PORT 已被占用, 目标访问限制需要使用它作为内部网关"
                return 1
            fi
            ;;
        egress)
            if _snn_port_busy udp 53; then
                apm_err "本机 UDP 53 端口已被占用, SOCKS5 出口需要在 $SNN_DNS_ADDR:53 提供 Snell 专用的解析器"
                return 1
            fi
            ;;
    esac
    return 0
}

# 名单里有域名条目时, 需要私有挂载命名空间来固定解析, 探测是否可用 (不改动任何真实文件)
snn_ns_ok() {
    local _t _a _b
    [ -z "${APM_SNN_NO_PREFLIGHT:-}" ] || return 0
    _t=$(mktemp -d "$(env_path /var/tmp)/apm-snell-ns.XXXXXX") || return 1
    : > "$_t/a"
    printf 'x\n' > "$_t/b"
    _a=$(unshare -m sh -c "mount --make-rprivate / 2>/dev/null; mount --bind '$_t/b' '$_t/a' && cat '$_t/a'" 2>/dev/null)
    rm -rf -- "$_t"
    [ "$_a" = x ]
}

# ---- 运行状态 ----

_snn_alive() { # PID
    [ -n "$1" ] && [ -d "$(env_path "/proc/$1")" ]
}

_snn_readpid() { # 文件名
    head -n 1 "$(_snn_rundir)/$1" 2>/dev/null | tr -d ' \r\n'
}

# 运行时是否处于预期状态: 包装脚本记录的模式一致且所有记录的进程都在
snn_runtime_ok() { # MODE
    local _mode _p
    _mode=$(head -n 1 "$(_snn_rundir)/mode" 2>/dev/null)
    [ "$_mode" = "$1" ] || return 1
    for _p in graftcp helper; do
        [ -f "$(_snn_rundir)/$_p.pid" ] || { [ "$_p" = helper ] && continue; return 1; }
        _snn_alive "$(_snn_readpid "$_p.pid")" || return 1
    done
    return 0
}

# ---- 服务脚本 ----

# 服务脚本在任一功能启用时改用包装脚本启动; 两者都关闭时保持原来的 Snell 启动方式
_snn_init_ready() {
    grep -q '^# apm-net:' "$(env_path "$SNELL_INIT")" 2>/dev/null
}

# ---- 写配置 ----

# 把标准输入写成配置文件 FILE, 校验后原子替换
_snn_commit() { # FILE VALIDATOR   (内容来自标准输入)
    local _c
    state_ensure_dirs || return 1
    _c=$(txn_new_candidate "$1") || return 1
    cat > "$_c" || { rm -f -- "$_c"; return 1; }
    txn_commit "$1" "$_c" "$2"
}

# 重启并验证, 用于配置变更后生效
_snn_restart_verify() { # MODE(none 表示普通启动)
    _snell_rc restart >/dev/null 2>&1 || return 1
    _snell_wait_healthy || return 1
    [ "$1" = none ] || snn_runtime_ok "$1"
}

# 把配置恢复为 SAVED (内容文件); 保存为空表示原来没有这个文件
_snn_restore() { # FILE SAVED
    if [ -s "$2" ]; then
        cat "$2" > "$1.restore.$$" && chmod 600 -- "$1.restore.$$" && mv -f -- "$1.restore.$$" "$1"
    else
        rm -f -- "$1"
    fi
}

# 读取 Y/n, 回车默认 Yes; 不是交互终端 EOF 读取失败都不算确认
_snn_confirm_tty() { # 提示
    local _a _rc
    [ -t 0 ] || return 1
    while :; do
        printf '%s [Y/n]：' "$1"
        _a=
        _rc=0
        IFS= read -r _a || _rc=$?
        [ "$_rc" -eq 0 ] || [ -n "$_a" ] || return 1
        _a=$(printf '%s' "$_a" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_a in
            ''|y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
        esac
        printf '输入无效，请输入 y 或 n，直接按 Enter 表示 Yes\n'
    done
}

# ---- 通用辅助 ----

_snn_file_of() { case $1 in egress) _snn_egress_file ;; access) _snn_access_file ;; esac; }
_snn_check_of() { case $1 in egress) printf 'snn_check_egress' ;; access) printf 'snn_check_access' ;; esac; }
_snn_cmd_of() { case $1 in egress) printf 'snell egress' ;; access) printf 'snell access' ;; esac; }

# 修改 FILE 里一个键的值 (不存在就追加), 校验后原子替换
_snn_set_kv() { # MODE KEY VALUE
    local _f
    _f=$(_snn_file_of "$1")
    V=$3 awk -v k="$2" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { print k "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print k "=" ENVIRON["V"] }' "$_f" | _snn_commit "$_f" "$(_snn_check_of "$1")"
}

# 配置生效: 功能已启用且 Snell 在运行时, 重启并验证; 失败时恢复旧配置并重启回旧状态
# 参数 SAVED 是旧配置的副本 (空文件表示原来没有)
_snn_apply_live() { # MODE SAVED
    local _f
    _f=$(_snn_file_of "$1")
    core_discover snell
    [ "$(snn_mode)" = "$1" ] || return 0
    [ "$CF_STATE" = running ] || return 0
    _snell_say "重启 Snell 使新配置生效"
    if _snn_restart_verify "$1"; then
        _snell_say "Snell 已重启并验证"
        return 0
    fi
    apm_err "新配置下 Snell 没有进入健康状态, 正在恢复旧配置"
    _snn_restore "$_f" "$2"
    if _snn_restart_verify "$(snn_mode)"; then
        _snell_say "已恢复旧配置并验证"
    else
        _snell_show_failure
        apm_err "恢复旧配置后 Snell 仍不健康, 请查看日志; 可执行 $(_snn_cmd_of "$1") disable 退出该功能"
    fi
    return 1
}

# 公共前置: root, 架构, 锁, 归属; 成功时已持有锁
_snn_begin() { # allow_broken
    _snell_need_root || return 4
    _snn_arch_ok || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_require_managed "${1:-no}" || return 4
}

_snn_save() { # FILE -> 副本路径在 SNN_SAVED
    _snell_ensure_staging || return 1
    SNN_SAVED=$SNELL_STAGING/saved.$$
    if [ -f "$1" ]; then cp -p -- "$1" "$SNN_SAVED"; else : > "$SNN_SAVED"; fi
}

# ---- 启用 ----

snn_enable() { # MODE [--yes]
    local _mode _yes _f _cur _missing _item _was _rc _hp
    _mode=$1
    shift
    _yes=no
    while [ $# -gt 0 ]; do
        case $1 in
            --yes) _yes=yes ;;
            *) apm_err "未知参数: $1"; return 2 ;;
        esac
        shift
    done
    _snn_begin no || return $?
    _f=$(_snn_file_of "$_mode")
    _cur=$(snn_mode)
    if [ "$_cur" = "$_mode" ]; then
        _snell_say "$(snn_mode_label "$_mode")已经启用"
        return 0
    fi
    if [ "$_cur" != none ]; then
        apm_err "已启用 $(snn_mode_label "$_cur"), 与 $(snn_mode_label "$_mode") 互斥, 两者不能同时启用; 请先执行 $(_snn_cmd_of "$_cur") disable"
        return 4
    fi
    if [ ! -f "$_f" ]; then
        case $_mode in
            egress) apm_err "尚未配置 SOCKS5 上游, 请先执行 snell egress set --server 地址 --port 端口 (--no-auth | --username 用户名 --password-stdin)"; return 2 ;;
            access) printf 'enabled=false\n' | _snn_commit "$_f" snn_check_access || return 1 ;;
        esac
    fi
    "$(_snn_check_of "$_mode")" "$_f" || return 1
    if [ "$_mode" = egress ] && [ -z "$(kv_get "$_f" host)" ]; then
        apm_err "尚未配置 SOCKS5 上游, 请先执行 snell egress set"
        return 2
    fi
    if [ "$_mode" = access ]; then
        for _hp in $(_snn_dests "$_f"); do
            if _snn_is_name "$(_snn_hp_host "$_hp")"; then
                snn_ns_ok || { apm_err "名单里有域名条目, 需要给 Snell 一个私有的 /etc/hosts 视图 (挂载命名空间), 当前环境不允许; 请只使用 IP 地址条目"; return 1; }
                break
            fi
        done
    fi
    _missing=$(snn_deps_missing "$_mode")
    if [ -n "$_missing" ]; then
        _snell_say "启用 $(snn_mode_label "$_mode") 需要安装以下组件:"
        for _item in $_missing; do
            case $_item in
                graftcp) _snell_say "  - graftcp $SNN_GRAFTCP_VER (从 GitHub 发行版下载, 固定 SHA256 校验, 安装到 $SNN_GRAFTCP)" ;;
                apk:*) _snell_say "  - ${_item#apk:} (Alpine 官方软件包, apk add)" ;;
            esac
        done
        if [ "$_yes" != yes ] && ! _snn_confirm_tty "安装上述组件并继续？"; then
            _snell_say "已取消, 没有改变任何内容"
            return 1
        fi
        snn_deps_install "$_mode" || { apm_err "安装组件失败, 没有启用, 没有改变 Snell"; return 1; }
    fi
    snn_preflight "$_mode" || return 1
    _snn_save "$_f" || return 1
    core_discover snell
    _was=$CF_STATE
    _snn_set_kv "$_mode" enabled true || return 1
    if ! _snell_write_init; then
        _snn_restore "$_f" "$SNN_SAVED"
        apm_err "更新服务脚本失败, 已恢复"
        return 1
    fi
    if [ "$_was" = running ]; then
        _snell_say "重启 Snell 以启用 $(snn_mode_label "$_mode")"
        if ! _snn_restart_verify "$_mode"; then
            _snell_show_failure
            apm_err "启用后 Snell 没有进入健康状态, 正在恢复"
            _snn_restore "$_f" "$SNN_SAVED"
            _snell_write_init
            if _snn_restart_verify none; then _snell_say "已恢复为普通 Snell 并验证"; else apm_err "恢复后 Snell 仍不健康, 请查看日志"; fi
            return 1
        fi
    fi
    _snell_say "$(snn_mode_label "$_mode")已启用"
    [ "$_was" = running ] || _snell_say "Snell 当前未运行, 下次启动时生效"
    return 0
}

# ---- 禁用 ----

snn_disable() { # MODE
    local _mode _f
    _mode=$1
    _snn_begin yes || return $?
    _f=$(_snn_file_of "$_mode")
    if [ "$(snn_mode)" != "$_mode" ]; then
        _snell_say "$(snn_mode_label "$_mode")没有启用"
        return 0
    fi
    _snn_set_kv "$_mode" enabled false || return 1
    # 服务脚本回到普通启动方式 (不含包装脚本与网络功能标记)
    _snell_write_init || { apm_err "更新服务脚本失败"; return 1; }
    core_discover snell
    if [ "$CF_STATE" = running ] || [ "$CF_SERVICE_STATE" = started ]; then
        _snell_say "重启 Snell 恢复普通运行方式"
        if _snn_restart_verify none; then
            _snell_say "Snell 已重启并验证"
        else
            _snell_show_failure
            apm_err "关闭后 Snell 没有进入健康状态, 请查看日志; 该功能已经关闭"
            return 1
        fi
    fi
    # 服务已按普通方式运行, 清理运行时文件
    rm -rf -- "$(_snn_rundir)"
    _snell_say "$(snn_mode_label "$_mode")已关闭, Snell 使用原来的启动方式, 没有辅助进程"
}

# ---- SOCKS5 出口: 配置 ----

snn_egress_set() { # --server H --port P (--no-auth | --username U --password-stdin) [--dns-server IP]
    local _server _port _user _pwstdin _auth _noauth _dns _pw _f _n _old _en
    _server=
    _port=
    _user=
    _pwstdin=no
    _auth=
    _noauth=no
    _dns=
    while [ $# -gt 0 ]; do
        case $1 in
            --server) [ $# -ge 2 ] || { apm_err "--server 需要参数"; return 2; }; _server=$2; shift ;;
            --port) [ $# -ge 2 ] || { apm_err "--port 需要参数"; return 2; }; _port=$2; shift ;;
            --no-auth) _noauth=yes ;;
            --username) [ $# -ge 2 ] || { apm_err "--username 需要参数"; return 2; }; _user=$2; shift ;;
            --password-stdin) _pwstdin=yes ;;
            --dns-server) [ $# -ge 2 ] || { apm_err "--dns-server 需要参数"; return 2; }; _dns=$2; shift ;;
            *) apm_err "未知参数: $1 (密码只能通过 --password-stdin 提供, 不接受命令行明文)"; return 2 ;;
        esac
        shift
    done
    { [ -n "$_server" ] && [ -n "$_port" ]; } || { apm_err "需要 --server 与 --port"; return 2; }
    if [ "$_noauth" = yes ]; then
        { [ -z "$_user" ] && [ "$_pwstdin" = no ]; } || { apm_err "--no-auth 不能与 --username 或 --password-stdin 同时使用"; return 2; }
    else
        [ -n "$_user" ] || { apm_err "需要明确选择认证方式: --no-auth, 或 --username 加 --password-stdin"; return 2; }
        [ "$_pwstdin" = yes ] || { apm_err "--username 必须同时提供 --password-stdin (没有密码的用户名是不完整的认证)"; return 2; }
        IFS= read -r _pw || :
        [ -n "$_pw" ] || { apm_err "从标准输入没有读到密码"; return 2; }
    fi
    _n=$(_snn_hostport "$_server" "$_port") || { apm_err "$_n"; return 2; }
    _snn_begin yes || return $?
    _f=$(_snn_egress_file)
    _en=false
    [ ! -f "$_f" ] || _en=$(kv_get "$_f" enabled)
    _snn_save "$_f" || return 1
    {
        printf 'enabled=%s\nhost=%s\nport=%s\n' "$_en" "$(_snn_hp_host "$_n")" "$(_snn_hp_port "$_n")"
        [ -z "$_user" ] || printf 'username=%s\npassword=%s\n' "$_user" "$_pw"
        [ -n "$_dns" ] && printf 'dns_server=%s\n' "$_dns"
        [ -n "$_dns" ] || { [ ! -f "$SNN_SAVED" ] || [ -z "$(kv_get "$SNN_SAVED" dns_server)" ] || printf 'dns_server=%s\n' "$(kv_get "$SNN_SAVED" dns_server)"; }
    } | _snn_commit "$_f" snn_check_egress || return 1
    _snell_say "SOCKS5 上游已设置: $(_snn_hp_host "$_n"):$(_snn_hp_port "$_n") ($([ -n "$_user" ] && echo "用户名密码认证, 密码已保存且不显示" || echo 无认证))"
    _snn_apply_live egress "$SNN_SAVED"
}

# ---- 目标访问限制: 名单 ----

# 写回名单: 标准输入是全部 host:port, 每行一个; 保持 enabled 不变
_snn_write_dests() { # ENABLED  (名单来自标准输入)
    local _f _n
    _f=$(_snn_access_file)
    {
        printf 'enabled=%s\n' "$1"
        _n=0
        while IFS= read -r _hp; do
            [ -n "$_hp" ] || continue
            _n=$((_n + 1))
            printf 'destination.%s=%s\n' "$_n" "$_hp"
        done
    } | _snn_commit "$_f" snn_check_access
}

snn_access_add() { # HOST PORT
    local _hp _f _en _all
    [ $# -eq 2 ] || { apm_err "用法: snell access add 主机 端口"; return 2; }
    _hp=$(_snn_hostport "$1" "$2") || { apm_err "$_hp"; return 2; }
    if _snn_is_internal "$_hp"; then
        apm_err "$_hp 是网关或内部组件自己的地址, 不能加入名单"
        return 2
    fi
    _snn_begin yes || return $?
    _f=$(_snn_access_file)
    _en=false
    [ ! -f "$_f" ] || _en=$(kv_get "$_f" enabled)
    _all=
    [ ! -f "$_f" ] || _all=$(_snn_dests "$_f")
    case "
$_all
" in *"
$_hp
"*) apm_err "名单里已经有 $_hp"; return 2 ;; esac
    if [ "$_en" = true ] && _snn_is_name "$(_snn_hp_host "$_hp")"; then
        snn_ns_ok || { apm_err "域名条目需要私有挂载命名空间, 当前环境不允许, 请使用 IP 地址"; return 1; }
    fi
    _snn_save "$_f" || return 1
    { [ -z "$_all" ] || printf '%s\n' "$_all"; printf '%s\n' "$_hp"; } | _snn_write_dests "$_en" || return 1
    _snell_say "已加入名单: $_hp"
    _snn_apply_live access "$SNN_SAVED"
}

snn_access_delete() { # HOST PORT
    local _hp _f _en _all _new
    [ $# -eq 2 ] || { apm_err "用法: snell access delete 主机 端口"; return 2; }
    _hp=$(_snn_hostport "$1" "$2") || { apm_err "$_hp"; return 2; }
    _snn_begin yes || return $?
    _f=$(_snn_access_file)
    [ -f "$_f" ] || { apm_err "名单是空的"; return 2; }
    _en=$(kv_get "$_f" enabled)
    _all=$(_snn_dests "$_f")
    _new=$(printf '%s\n' "$_all" | grep -v -x -F -- "$_hp")
    [ "$_new" != "$_all" ] || { apm_err "名单里没有 $_hp"; return 2; }
    _snn_save "$_f" || return 1
    printf '%s\n' "$_new" | _snn_write_dests "$_en" || return 1
    _snell_say "已从名单删除: $_hp"
    _snn_apply_live access "$SNN_SAVED"
}

snn_access_clear() {
    local _f _en
    _snn_begin yes || return $?
    _f=$(_snn_access_file)
    [ -f "$_f" ] || { _snell_say "名单本来就是空的"; return 0; }
    _en=$(kv_get "$_f" enabled)
    _snn_save "$_f" || return 1
    : | _snn_write_dests "$_en" || return 1
    _snell_say "名单已清空: 启用时将拒绝所有目标"
    _snn_apply_live access "$SNN_SAVED"
}

# 刷新: 重新解析名单里的域名; 固定的地址有变化才重启, 没有变化不重启, 也不会放行任何新的目标
snn_access_refresh() {
    local _f _tmp _changed
    _snn_begin yes || return $?
    _f=$(_snn_access_file)
    [ -f "$_f" ] || { _snell_say "名单是空的, 没有需要刷新的域名"; return 0; }
    _snell_ensure_staging || return 1
    _tmp=$SNELL_STAGING/pins.new
    _snn_compute_pins "$_f" > "$_tmp" || return 1
    if [ -f "$(_snn_pins_file)" ] && cmp -s "$_tmp" "$(_snn_pins_file)"; then
        _snell_say "域名的固定地址没有变化"
        return 0
    fi
    _changed=yes
    _snell_say "域名的固定地址有变化:"
    sed 's/^/  /' "$_tmp"
    if [ "$(snn_mode)" != access ]; then
        mkdir -p -- "$(_snn_dir)" && cp -- "$_tmp" "$(_snn_pins_file)" && chmod 600 -- "$(_snn_pins_file)"
        _snell_say "目标访问限制未启用, 下次启用时使用新的地址"
        return 0
    fi
    core_discover snell
    if [ "$CF_STATE" != running ]; then
        _snell_say "Snell 未运行, 下次启动时使用新的地址"
        return 0
    fi
    _snell_say "重启 Snell 使新地址生效"
    if _snn_restart_verify access; then
        _snell_say "Snell 已重启并验证"
    else
        _snell_show_failure
        apm_err "刷新后 Snell 没有进入健康状态, 请查看日志"
        return 1
    fi
}

# ---- 显示 ----

snn_show_egress() {
    local _f _en _u
    _f=$(_snn_egress_file)
    printf 'SOCKS5 出口\n'
    if [ ! -f "$_f" ]; then
        printf '  状态：未配置\n  说明：Snell 访问目标的 TCP UDP DNS 将全部经过指定的 SOCKS5 上游, 上游故障时失败, 不会直连\n'
        return 0
    fi
    snn_check_egress "$_f" >/dev/null 2>&1 || { printf '  状态：配置无效, 请重新执行 snell egress set\n'; return 0; }
    _en=$(kv_get "$_f" enabled)
    printf '  状态：%s\n' "$([ "$_en" = true ] && echo 已启用 || echo 未启用)"
    printf '  上游：%s:%s\n' "$(kv_get "$_f" host)" "$(kv_get "$_f" port)"
    _u=$(kv_get "$_f" username)
    if [ -n "$_u" ]; then printf '  认证：用户名 %s, 密码已配置\n' "$_u"; else printf '  认证：无认证\n'; fi
    printf '  DNS 服务器：%s (经由上游查询)\n' "$(kv_get "$_f" dns_server | grep . || echo "$SNN_DNS_SERVER_DEFAULT")"
    [ "$_en" != true ] || snn_show_runtime egress
}

snn_show_access() {
    local _f _en _hp _n _a
    _f=$(_snn_access_file)
    printf '目标访问限制\n'
    if [ ! -f "$_f" ]; then
        printf '  状态：未配置\n  说明：Snell 只能连接名单里的 地址:端口, 其余全部拒绝, 只转发 TCP, UDP 一律拒绝\n'
        return 0
    fi
    snn_check_access "$_f" >/dev/null 2>&1 || { printf '  状态：配置无效\n'; return 0; }
    _en=$(kv_get "$_f" enabled)
    printf '  状态：%s\n' "$([ "$_en" = true ] && echo 已启用 || echo 未启用)"
    _n=$(_snn_dests "$_f" | grep -c . || true)
    printf '  允许的目标 (%s)：\n' "${_n:-0}"
    if [ "${_n:-0}" -eq 0 ]; then
        printf '    (空) 启用时拒绝所有目标\n'
    else
        for _hp in $(_snn_dests "$_f"); do
            printf '    %s' "$_hp"
            if _snn_is_name "$(_snn_hp_host "$_hp")" && [ -f "$(_snn_pins_file)" ]; then
                _a=$(awk -v n="$(_snn_hp_host "$_hp")" '$1 == n { printf "%s ", $2 }' "$(_snn_pins_file)")
                [ -z "$_a" ] || printf '  固定解析: %s' "$_a"
            fi
            printf '\n'
        done
    fi
    printf '  说明：只转发 TCP, UDP 业务一律拒绝; 域名条目在启动与刷新时解析并固定\n'
    [ "$_en" != true ] || snn_show_runtime access
}

snn_show_runtime() { # MODE
    core_discover snell
    if [ "$CF_STATE" != running ]; then
        printf '  运行：Snell 未运行\n'
    elif snn_runtime_ok "$1"; then
        printf '  运行：正常 (辅助进程均在运行)\n'
    else
        printf '  运行：异常 (辅助进程缺失), Snell 的业务连接会失败而不是直连, 请查看日志并重启\n'
    fi
}

# ---- CLI ----

snell_egress_cli() {
    local _sub
    _sub=${1:-show}
    [ $# -eq 0 ] || shift
    case $_sub in
        show|status) snn_show_egress ;;
        set) snn_egress_set "$@" ;;
        enable) snn_enable egress "$@" ;;
        disable) snn_disable egress ;;
        *) apm_err "用法: snell egress [show | set --server 地址 --port 端口 (--no-auth | --username 名 --password-stdin) [--dns-server IP] | enable [--yes] | disable]"; return 2 ;;
    esac
}

snell_access_cli() {
    local _sub
    _sub=${1:-show}
    [ $# -eq 0 ] || shift
    case $_sub in
        show|status) snn_show_access ;;
        add) snn_access_add "$@" ;;
        delete) snn_access_delete "$@" ;;
        clear) snn_access_clear ;;
        refresh) snn_access_refresh ;;
        enable) snn_enable access "$@" ;;
        disable) snn_disable access ;;
        *) apm_err "用法: snell access [show | add 主机 端口 | delete 主机 端口 | clear | refresh | enable [--yes] | disable]"; return 2 ;;
    esac
}

# ---- 服务脚本 (启用网络功能时) ----

# 输出 SOCKS5 出口 / 目标访问限制 模式的服务脚本; 普通模式的脚本仍由 snell.sh 的静态模板生成, 不含任何额外内容
snn_init_text() { # MODE
    local _h
    _h=$(_snn_home)
    cat <<EOF
#!/sbin/openrc-run
# apm-managed: snell
# apm-net: $1
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager snell 管理, 手工修改可能被覆盖

name="snell"
description="Snell proxy server (managed by Alpine Proxy Manager, network feature: $1)"
# 实际运行的是包装脚本, 由它在 graftcp 之下启动 Snell, 这里的 apm_binary 供状态发现使用
apm_binary="$SNELL_BIN"
command="/bin/sh"
command_args="$_h/lib/snellnet-run.sh"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=5
respawn_period=60
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/snell/access.log"
error_log="/var/log/snell/error.log"
required_files="$SNELL_CONF"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 -o snell:snell /var/log/snell
    checkpath -f -m 0640 -o snell:snell /var/log/snell/access.log
    checkpath -f -m 0640 -o snell:snell /var/log/snell/error.log
    # 每次启动重新生成运行时文件, 域名在这里重新解析并固定, 失败则不启动
    "$_h/bin/proxy-manager" snell net-prepare || return 1
}

stop_post() {
    rm -rf /run/apm-snell
}
EOF
}

# 卸载 Snell 时的收尾: 运行时目录一定清理; 两个功能一律关闭, 重新安装得到普通 Snell
# 清除 (--purge) 时删除两个配置, 固定解析, 依赖记录与 Manager 自己安装的 graftcp, 不卸载 apk 软件包, 也不动其他 Core
snn_on_uninstall() { # PURGE(0|1)
    local _f
    rm -rf -- "$(_snn_rundir)"
    for _f in "$(_snn_egress_file)" "$(_snn_access_file)"; do
        [ -f "$_f" ] || continue
        if [ "$1" = 1 ]; then
            rm -f -- "$_f"
        else
            sed 's/^enabled=.*/enabled=false/' "$_f" > "$_f.tmp.$$" && chmod 600 -- "$_f.tmp.$$" && mv -f -- "$_f.tmp.$$" "$_f"
        fi
    done
    if [ "$1" = 1 ]; then
        rm -rf -- "$(_snn_dir)"
        rm -f -- "$(env_path "$SNN_GRAFTCP")"
        rmdir -- "$(env_path "$SNN_EXT_DIR")" 2>/dev/null
    fi
    return 0
}
