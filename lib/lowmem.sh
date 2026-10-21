# shellcheck shell=sh
# 低内存环境保护 (管理员主动启用, 默认关闭)
#
# 目标系统  Alpine Linux + OpenRC, 内存配额小的 VPS, NAT VPS, LXC/Incus 容器
# 设计原则  自动检测 -> 按需调整 -> 结果可验证 -> 原值可恢复, 不把某一台服务器的参数套用到所有机器
#           容量影响判断, 但不决定是否有资格使用: 任意合理的内存上限都走同一套连续判断, 没有固定档位或查表
#
# 三个独立模块, 各自检测, 各自可能不适用, 状态永远从系统实时读取, 不信任写下来的 "全部成功"
#   tcp        TCP 缓冲上限  只在 单个连接最多能占用的缓冲 (收发上限之和) 超过内存上限的四分之一 时调整
#                           调整目标是内核自带的默认值 (6 MiB 与 4 MiB 上限, 128 KiB 与 16 KiB 初值), 且只降不升
#                           不是按内存线性缩放的公式: 同一台机器配置合理就不动, 内存再大只要有异常的缓冲也会提示
#   ssh        sshd 的 OOM 分数  把 sshd 相关进程的 oom_score_adj 降到 -500 (不用 -1000, 容器里无可杀进程时不会卡死)
#                           内核要求降低分数的进程拥有初始用户命名空间的 CAP_SYS_RESOURCE, 无特权容器通常没有, 此时明确报告不支持
#   forensics  轻量 OOM 取证  常驻一个只用 sh 内建的小进程, oom_kill 计数变化时记录内存组成 (anon file kernel sock slab) 与进程表
#                           需要 cgroup v2 的 memory.events
#
# 修改范围  /proc/sys/net/ipv4/tcp_rmem tcp_wmem (当前网络命名空间)  sshd 进程的 oom_score_adj  一个 OpenRC 服务 apm-lowmem
#           不修改 /etc/sysctl.conf 与 /etc/sysctl.d, 管理员已在那里设置同名参数时跳过该参数
# 持久化   服务 apm-lowmem (default 运行级别, 排在 snell sing-box anytls-socks-gateway sshd 之前) 开机时重新应用 tcp 设置
# 恢复     disable 把仍然等于 APM 设置值的参数写回原值, 已被别人改过的不覆盖; 删除服务与设置文件

LM_SVC=apm-lowmem
LM_INIT=/etc/init.d/apm-lowmem
LM_RUN=/run/apm-lowmem
LM_LOG=/var/log/apm-lowmem.log
LM_KD_RMEM="4096 131072 6291456"
LM_KD_WMEM="4096 16384 4194304"
LM_RISK_DIV=4
LM_SSH_ADJ=-500
LM_SCHEMA=1

_lm_conf() { printf '%s/lowmem.conf' "$(state_etc)"; }
_lm_orig() { printf '%s/lowmem.orig' "$(state_var)"; }
_lm_rc() { _snell_run rc-service "$LM_SVC" "$1"; }

_lm_mib() { printf '%s MiB' "$(($1 / 1048576))"; }

# 规范化空白: "4096\t131072\t6291456" -> "4096 131072 6291456"
_lm_norm() {
    # shellcheck disable=SC2086
    set -- $1
    printf '%s' "$*"
}

_lm_tcp_path() { env_path "/proc/sys/net/ipv4/tcp_$1"; }

# ---- 检测 (全部只读) ----

# 带 memory.events 的 cgroup 目录: 从本进程所在 cgroup 向上, 第一个有该文件的目录
_lm_cg_dir() {
    local _p _d _root
    _root=$(env_path /sys/fs/cgroup)
    _p=$(sed -n 's/^0:://p' "$(env_path /proc/self/cgroup)" 2>/dev/null | head -n 1)
    [ "$_p" = / ] && _p=
    _d=$_p
    while :; do
        if [ -r "$_root$_d/memory.events" ]; then printf '%s' "$_root$_d"; return 0; fi
        [ -n "$_d" ] || break
        _d=${_d%/*}
    done
    return 1
}

# 管理员在 sysctl 配置里为同名参数设置了值: 输出文件名
_lm_sysctl_conflict() { # tcp_rmem
    local _f
    for _f in "$(env_path /etc/sysctl.conf)" "$(env_path /etc/sysctl.d)"/*.conf "$(env_path /usr/lib/sysctl.d)"/*.conf; do
        [ -f "$_f" ] || continue
        if grep -Eq "^[[:space:]]*net[./]ipv4[./]$1[[:space:]]*=" "$_f" 2>/dev/null; then
            printf '%s' "${_f#"${APM_SYSROOT:-}"}"
            return 0
        fi
    done
    return 1
}

# 当前网络命名空间: core 下的全局参数 (rmem_default 等) 只出现在初始网络命名空间, 容器自己的命名空间里看不到
_lm_netns() {
    if [ ! -d "$(env_path /proc/sys/net/core)" ]; then printf 'unknown'
    elif [ -e "$(env_path /proc/sys/net/core/rmem_default)" ]; then printf 'host'
    else printf 'own'; fi
}

# 是否允许把进程的 oom_score_adj 降到负值: 用一个临时子进程试一次, 不影响任何现有进程
_lm_adj_lower_ok() {
    if [ -n "${APM_SYSROOT:-}" ]; then
        [ ! -e "$(env_path /.deny-oom-lower)" ]
        return $?
    fi
    sh -c 'echo -1 > /proc/self/oom_score_adj' 2>/dev/null
}

# 是否允许写 tcp_rmem/tcp_wmem (root 对只读文件 -w 也为真，所以真实系统上再用 "写回当前值" 试探一次，写入相同的值不改变任何设置)
_lm_tcp_writable() {
    local _k _v
    if [ -n "${APM_SYSROOT:-}" ]; then
        [ ! -e "$(env_path /.deny-sysctl-write)" ] && [ -w "$(_lm_tcp_path rmem)" ] && [ -w "$(_lm_tcp_path wmem)" ]
        return $?
    fi
    for _k in rmem wmem; do
        [ -w "$(_lm_tcp_path "$_k")" ] || return 1
        _v=$(cat "$(_lm_tcp_path "$_k")" 2>/dev/null)
        printf '%s\n' "$_v" > "$(_lm_tcp_path "$_k")" 2>/dev/null || return 1
    done
    return 0
}

# sshd 相关进程: 每行 "pid adj comm"
_lm_ssh_procs() {
    local _p _c _a
    for _p in "$(env_path /proc)"/[0-9]*; do
        [ -r "$_p/comm" ] || continue
        _c=
        IFS= read -r _c < "$_p/comm" 2>/dev/null || continue
        case $_c in sshd|sshd-session|sshd-auth) ;; *) continue ;; esac
        _a=
        IFS= read -r _a < "$_p/oom_score_adj" 2>/dev/null || continue
        printf '%s %s %s\n' "${_p##*/}" "$_a" "$_c"
    done
}

# 填充 LM_* 全局变量
lm_probe() {
    local _ev _k _v
    env_probe_memory
    LM_LIMIT=${ENV_MEM_LIMIT:-0}
    LM_LIMIT_SRC=$ENV_MEM_LIMIT_SRC
    LM_CG_VER=$ENV_CG_VER
    LM_CG_DIR=$(_lm_cg_dir) || LM_CG_DIR=
    LM_OOM_KILL=
    LM_EVENTS=
    if [ -n "$LM_CG_DIR" ]; then
        _ev=$LM_CG_DIR/memory.events
        while read -r _k _v; do
            [ -n "$_k" ] || continue
            LM_EVENTS="$LM_EVENTS $_k=$_v"
            [ "$_k" != oom_kill ] || LM_OOM_KILL=$_v
        done < "$_ev"
        LM_EVENTS=${LM_EVENTS# }
    fi
    LM_RMEM=
    LM_WMEM=
    [ ! -r "$(_lm_tcp_path rmem)" ] || LM_RMEM=$(_lm_norm "$(cat "$(_lm_tcp_path rmem)" 2>/dev/null)")
    [ ! -r "$(_lm_tcp_path wmem)" ] || LM_WMEM=$(_lm_norm "$(cat "$(_lm_tcp_path wmem)" 2>/dev/null)")
    LM_NETNS=$(_lm_netns)
    return 0
}

# ---- TCP 缓冲策略 ----
#
# 风险信号  单个 TCP 连接的缓冲上限之和 S = tcp_rmem 上限 + tcp_wmem 上限
#           S 超过内存上限的四分之一, 说明一条连接 (收发两个队列都堆满, 例如快上游配慢客户端) 就可能占去容器相当一部分内存
#           cgroup v2 对 socket 缓冲的计费发生在软中断里, 超限时只能强制计入而不能拒绝, 回收不回来 (见 HK-Hytron2 根因报告第 2 节)
# 调整      超过阈值时, 把各字段降到内核自带默认值与当前值中较小的一个 (只降不升)
#           内核默认值是长期使用的上游参照, 不是按容量缩放出来的数
# 不判断    内存上限未知时不调整; 阈值以下一律保持原样 (内存再小, 配置合理就不动; 内存再大, 缓冲异常也会提示)
# 内存极小  内核默认值本身也超过阈值时仍只降到默认值, 并提示资源本身不足, 不做没有验证的更激进缩小

# 把三元组按字段取 min(当前, 默认), 并保证 min <= mid <= max
_lm_triplet_min() { # CUR KD
    local _c1 _c2 _c3 _d1 _d2 _d3 _a _b _c
    # shellcheck disable=SC2086
    set -- $1 $2
    _c1=$1; _c2=$2; _c3=$3; _d1=$4; _d2=$5; _d3=$6
    _a=$_c1; [ "$_a" -le "$_d1" ] || _a=$_d1
    _b=$_c2; [ "$_b" -le "$_d2" ] || _b=$_d2
    _c=$_c3; [ "$_c" -le "$_d3" ] || _c=$_d3
    [ "$_b" -le "$_c" ] || _b=$_c
    [ "$_a" -le "$_b" ] || _a=$_b
    printf '%s %s %s' "$_a" "$_b" "$_c"
}

_lm_triplet_ok() { # 三个非负整数
    # shellcheck disable=SC2086
    set -- $1
    [ $# -eq 3 ] || return 1
    case $1$2$3 in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 12 ] && [ "${#2}" -le 12 ] && [ "${#3}" -le 12 ]
}

# 产出  LM_P_TCP  na | unknown | fine | plan
#       LM_P_TCP_NOTE  一句话原因/依据
#       LM_P_RMEM_T LM_P_WMEM_T  目标值 (空表示这个参数不调整)
#       LM_P_RMEM_WHY LM_P_WMEM_WHY  依据
lm_plan_tcp() {
    local _s _thr _k _t _cur _kd _conf
    LM_P_TCP=
    LM_P_TCP_NOTE=
    LM_P_RMEM_T=
    LM_P_WMEM_T=
    LM_P_RMEM_WHY=
    LM_P_WMEM_WHY=
    LM_P_TCP_SKIP=
    if [ -z "$LM_RMEM" ] || [ -z "$LM_WMEM" ]; then
        LM_P_TCP=na; LM_P_TCP_NOTE="内核没有提供 tcp_rmem 或 tcp_wmem"; return 0
    fi
    if ! _lm_triplet_ok "$LM_RMEM" || ! _lm_triplet_ok "$LM_WMEM"; then
        LM_P_TCP=unknown; LM_P_TCP_NOTE="读到的 tcp_rmem/tcp_wmem 格式异常，无法判断，不调整"; return 0
    fi
    if ! _lm_tcp_writable; then
        LM_P_TCP=na; LM_P_TCP_NOTE="当前环境不允许修改 tcp_rmem/tcp_wmem（只读）"; return 0
    fi
    if [ "$LM_LIMIT" -le 0 ] 2>/dev/null; then
        LM_P_TCP=unknown; LM_P_TCP_NOTE="无法可靠识别内存上限，不调整"; return 0
    fi
    # shellcheck disable=SC2086
    set -- $LM_RMEM
    _s=$3
    # shellcheck disable=SC2086
    set -- $LM_WMEM
    _s=$((_s + $3))
    _thr=$((LM_LIMIT / LM_RISK_DIV))
    LM_P_TCP_S=$_s
    LM_P_TCP_THR=$_thr
    if [ "$_s" -le "$_thr" ]; then
        LM_P_TCP=fine
        LM_P_TCP_NOTE="单个连接的缓冲上限之和 $(_lm_mib "$_s")，不超过内存上限 $(_lm_mib "$LM_LIMIT") 的四分之一，无需调整"
        return 0
    fi
    for _k in rmem wmem; do
        if [ "$_k" = rmem ]; then _cur=$LM_RMEM; _kd=$LM_KD_RMEM; else _cur=$LM_WMEM; _kd=$LM_KD_WMEM; fi
        _conf=$(_lm_sysctl_conflict "tcp_$_k") && {
            LM_P_TCP_SKIP="$LM_P_TCP_SKIP tcp_$_k（管理员已在 $_conf 设置，APM 不覆盖）"
            continue
        }
        _t=$(_lm_triplet_min "$_cur" "$_kd")
        [ "$_t" != "$_cur" ] || continue
        if [ "$_k" = rmem ]; then
            LM_P_RMEM_T=$_t
            LM_P_RMEM_WHY="单个连接的缓冲上限之和 $(_lm_mib "$_s") 超过内存上限 $(_lm_mib "$LM_LIMIT") 的四分之一，降到内核默认值与当前值中较小者"
        else
            LM_P_WMEM_T=$_t
            LM_P_WMEM_WHY="单个连接的缓冲上限之和 $(_lm_mib "$_s") 超过内存上限 $(_lm_mib "$LM_LIMIT") 的四分之一，降到内核默认值与当前值中较小者"
        fi
    done
    LM_P_TCP_SKIP=${LM_P_TCP_SKIP# }
    if [ -n "$LM_P_RMEM_T$LM_P_WMEM_T" ]; then
        LM_P_TCP=plan
        LM_P_TCP_NOTE="偏大：单个连接的缓冲上限之和 $(_lm_mib "$_s")，超过内存上限 $(_lm_mib "$LM_LIMIT") 的四分之一"
        [ "$_thr" -ge 10485760 ] || LM_P_TCP_NOTE="$LM_P_TCP_NOTE；内存上限很小，内核默认值本身也可能偏大，APM 不做没有验证的更小设置"
        [ -z "$LM_P_TCP_SKIP" ] || LM_P_TCP_NOTE="$LM_P_TCP_NOTE；跳过 $LM_P_TCP_SKIP"
    elif [ -n "$LM_P_TCP_SKIP" ]; then
        LM_P_TCP=na
        LM_P_TCP_NOTE="偏大，但全部参数都已由管理员在 sysctl 配置中设置，APM 不覆盖：$LM_P_TCP_SKIP"
    else
        LM_P_TCP=fine
        LM_P_TCP_NOTE="已经不高于内核默认值，无需调整（内存上限 $(_lm_mib "$LM_LIMIT") 偏小，资源本身有限）"
    fi
    return 0
}

# ---- SSH 与取证的适用性 ----

# LM_P_SSH  na | fine | plan   LM_P_SSH_NOTE
lm_plan_ssh() {
    local _n _need _pid _adj _c
    LM_P_SSH=
    LM_P_SSH_NOTE=
    if ! _lm_adj_lower_ok; then
        LM_P_SSH=na
        LM_P_SSH_NOTE="当前环境不允许降低 oom_score_adj（内核要求初始用户命名空间的 CAP_SYS_RESOURCE，无特权容器通常没有）"
        return 0
    fi
    _n=0
    _need=0
    while read -r _pid _adj _c; do
        [ -n "$_pid" ] || continue
        _n=$((_n + 1))
        [ "$_adj" -le "$LM_SSH_ADJ" ] 2>/dev/null || _need=$((_need + 1))
    done <<EOF
$(_lm_ssh_procs)
EOF
    if [ "$_n" -eq 0 ]; then
        LM_P_SSH=plan
        LM_P_SSH_NOTE="没有检测到运行中的 sshd，启用后 sshd 出现时会自动设置"
    elif [ "$_need" -eq 0 ]; then
        LM_P_SSH=fine
        LM_P_SSH_NOTE="$_n 个 sshd 进程的 oom_score_adj 已经不高于 $LM_SSH_ADJ，无需修改（启用后仍会维护新出现的进程）"
    else
        LM_P_SSH=plan
        LM_P_SSH_NOTE="$_need/$_n 个 sshd 进程需要把 oom_score_adj 降到 $LM_SSH_ADJ"
    fi
    return 0
}

lm_plan_forensics() {
    LM_P_FOR=
    LM_P_FOR_NOTE=
    if [ "$LM_CG_VER" != v2 ] || [ -z "$LM_CG_DIR" ]; then
        LM_P_FOR=na
        LM_P_FOR_NOTE="需要 cgroup v2 的 memory.events，当前环境不可用或不可读"
        return 0
    fi
    LM_P_FOR=plan
    LM_P_FOR_NOTE="记录 memory.events 变化时的内存组成与进程表"
}

# 立即把 sshd 相关进程的 oom_score_adj 降到目标 (和常驻进程做同样的事，只降不升)，登记 PID 与原值供恢复
_lm_ssh_apply_now() {
    local _pid _adj _c
    mkdir -p -- "$(env_path "$LM_RUN")" 2>/dev/null
    while read -r _pid _adj _c; do
        [ -n "$_pid" ] || continue
        [ "$_adj" -gt "$LM_SSH_ADJ" ] 2>/dev/null || continue
        if printf '%s\n' "$LM_SSH_ADJ" > "$(env_path "/proc/$_pid/oom_score_adj")" 2>/dev/null; then
            printf '%s %s %s\n' "$_pid" "$_adj" "$_c" >> "$(env_path "$LM_RUN/ssh.adj")"
        fi
    done <<EOF
$(_lm_ssh_procs)
EOF
    return 0
}

# ---- 事务入口 ----

_lm_begin() {
    _snell_need_root || return 4
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
}

# 读取设置文件的字段
_lm_cget() { [ -f "$(_lm_conf)" ] && kv_get "$(_lm_conf)" "$1"; }

lm_enabled() { [ "$(_lm_cget enabled)" = true ]; }

# 原子写一个 kv 文件 (候选 -> 语法检查 -> 替换), 内容来自标准输入
_lm_write_kv() { # 目标 权限
    local _c
    mkdir -p -- "$(dirname "$1")" || return 1
    _c=$(txn_new_candidate "$1") || return 1
    cat > "$_c" || { rm -f -- "$_c"; return 1; }
    chmod "$2" "$_c" || { rm -f -- "$_c"; return 1; }
    kv_check_syntax "$_c" >/dev/null 2>&1 || { rm -f -- "$_c"; return 1; }
    mv -f -- "$_c" "$1"
}

_lm_tcp_write() { # rmem|wmem 值
    printf '%s\n' "$2" > "$(_lm_tcp_path "$1")" 2>/dev/null
}

_lm_tcp_read() { _lm_norm "$(cat "$(_lm_tcp_path "$1")" 2>/dev/null)"; }

# ---- OpenRC 服务 ----

_lm_write_init() {
    local _t
    _t=$(env_path "$LM_INIT")
    mkdir -p -- "$(dirname "$_t")" || return 1
    cat > "$_t" <<EOF
#!/sbin/openrc-run
# apm-managed: apm-lowmem
# 由 Alpine Proxy Manager 生成, 请使用 proxy-manager lowmem 管理, 手工修改可能被覆盖
# 低内存环境保护: 开机时重新应用 TCP 缓冲设置, 常驻进程负责 OOM 取证与 sshd 的 OOM 分数

name="apm-lowmem"
description="Low-memory protection: OOM forensics and sshd OOM score (managed by Alpine Proxy Manager)"
command="/bin/sh"
command_args="/usr/local/lib/alpine-proxy-manager/current/lib/lowmem-daemon.sh"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=10
respawn_period=60
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need localmount
    before snell sing-box anytls-socks-gateway sshd apm-sbhealth
}

start_pre() {
    checkpath -d -m 0755 /run/apm-lowmem
    checkpath -f -m 0600 /var/log/apm-lowmem.log
    # 应用 TCP 缓冲设置 (失败只警告, 不阻止服务启动)
    /usr/local/bin/proxy-manager lowmem boot || ewarn "TCP buffer settings were not applied"
    return 0
}
EOF
    chmod 755 -- "$_t"
}

_lm_init_ours() { [ -f "$(env_path "$LM_INIT")" ] && grep -q '^# apm-managed: apm-lowmem' "$(env_path "$LM_INIT")" 2>/dev/null; }

# ---- 启用 ----

lowmem_enable() {
    local _tcp _ssh _for _was _kept
    _lm_begin || return $?
    lm_probe
    lm_plan_tcp
    lm_plan_ssh
    lm_plan_forensics
    _was=false
    lm_enabled && _was=true
    # 已经启用过且 tcp 在用: 沿用保存的目标，不依据已被调整后的值重新计算
    _kept=no
    if [ "$_was" = true ] && [ "$(_lm_cget tcp)" = on ]; then
        _kept=yes
        LM_P_TCP=plan
        LM_P_RMEM_T=$(_lm_cget tcp_rmem)
        LM_P_WMEM_T=$(_lm_cget tcp_wmem)
        LM_P_TCP_NOTE="已启用，沿用保存的设置并重新确认"
    fi
    printf '低内存环境保护：检测结果\n'
    printf '  内存上限：%s（%s）\n' "$(_lm_mib "$LM_LIMIT")" "$(_lm_limit_src_text)"
    printf '  TCP 缓冲：%s\n' "$LM_P_TCP_NOTE"
    printf '  SSH 保护：%s\n' "$LM_P_SSH_NOTE"
    printf '  内存取证：%s\n' "$LM_P_FOR_NOTE"
    _tcp=off; _ssh=off; _for=off
    [ "$LM_P_TCP" != plan ] || _tcp=on
    case $LM_P_SSH in plan|fine) _ssh=on ;; esac
    [ "$LM_P_FOR" != plan ] || _for=on
    if [ "$_tcp$_ssh$_for" = offoffoff ]; then
        printf '\n没有需要启用的项目，没有修改任何设置\n'
        return 0
    fi
    # 原值只在第一次启用时保存，重复启用不覆盖
    if [ "$_kept" = no ] && { [ "$_was" != true ] || [ ! -f "$(_lm_orig)" ]; }; then
        _lm_write_orig || { apm_err "无法保存原始设置，没有做任何修改"; return 1; }
    fi
    if [ "$_tcp" = on ]; then
        _lm_apply_tcp || { apm_err "TCP 缓冲没有完全生效，已恢复到修改前"; _tcp=off; }
    fi
    if [ "$_tcp$_ssh$_for" = offoffoff ]; then
        [ "$_was" = true ] || _lm_drop_state
        printf '\n没有任何项目生效\n'
        return 1
    fi
    if ! _lm_write_conf "$_tcp" "$_ssh" "$_for"; then
        apm_err "无法写入设置文件"
        [ "$_tcp" != on ] || _lm_revert_tcp
        return 1
    fi
    [ "$_ssh" != on ] || _lm_ssh_apply_now
    _lm_install_service || apm_warn "无法安装或启动 OpenRC 服务：SSH 保护与内存取证不可用，TCP 缓冲重启后不会保留"
    printf '\n'
    lowmem_status
    return 0
}

_lm_drop_state() { rm -f -- "$(_lm_conf)" "$(_lm_orig)"; }

_lm_limit_src_text() {
    case $LM_LIMIT_SRC in
        cgroup-v2) printf 'cgroup v2' ;;
        cgroup-v1) printf 'cgroup v1' ;;
        *) printf '/proc/meminfo，未发现更小的 cgroup 限制' ;;
    esac
}

# 保存原始设置: 只含需要调整的参数
_lm_write_orig() {
    {
        printf 'schema=%s\n' "$LM_SCHEMA"
        printf 'apm_version=%s\n' "$(apm_version)"
        printf 'saved_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
        printf 'limit=%s\n' "$LM_LIMIT"
        printf 'netns=%s\n' "$LM_NETNS"
        if [ -n "$LM_P_RMEM_T" ]; then
            printf 'tcp_rmem_orig=%s\ntcp_rmem_target=%s\ntcp_rmem_why=%s\n' "$LM_RMEM" "$LM_P_RMEM_T" "$LM_P_RMEM_WHY"
        fi
        if [ -n "$LM_P_WMEM_T" ]; then
            printf 'tcp_wmem_orig=%s\ntcp_wmem_target=%s\ntcp_wmem_why=%s\n' "$LM_WMEM" "$LM_P_WMEM_T" "$LM_P_WMEM_WHY"
        fi
    } | _lm_write_kv "$(_lm_orig)" 600
}

# 应用 tcp: 全部写入并回读确认，任何一项不一致就把已写的恢复原值
_lm_apply_tcp() {
    local _k _t _o _a _done
    _done=
    for _k in rmem wmem; do
        if [ "$_k" = rmem ]; then _t=$LM_P_RMEM_T; _o=$LM_RMEM; else _t=$LM_P_WMEM_T; _o=$LM_WMEM; fi
        [ -n "$_t" ] || continue
        _lm_tcp_write "$_k" "$_t"
        _a=$(_lm_tcp_read "$_k")
        if [ "$_a" != "$_t" ]; then
            apm_err "tcp_$_k 写入后读回 [$_a]，与目标 [$_t] 不一致"
            # 回滚已经写入的和这一个
            _lm_tcp_write "$_k" "$_o"
            for _o in $_done; do _lm_revert_one "$_o"; done
            return 1
        fi
        _done="$_done $_k"
    done
    return 0
}

_lm_revert_one() { # rmem|wmem
    local _o
    _o=$(kv_get "$(_lm_orig)" "tcp_$1_orig")
    [ -z "$_o" ] || _lm_tcp_write "$1" "$_o"
}

_lm_revert_tcp() { _lm_revert_one rmem; _lm_revert_one wmem; }

_lm_write_conf() { # tcp ssh forensics
    local _rt _wt
    _rt=$LM_P_RMEM_T
    _wt=$LM_P_WMEM_T
    {
        printf 'schema=%s\n' "$LM_SCHEMA"
        printf 'enabled=true\n'
        printf 'apm_version=%s\n' "$(apm_version)"
        printf 'enabled_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
        printf 'tcp=%s\n' "$1"
        if [ "$1" = on ]; then
            [ -z "$_rt" ] || printf 'tcp_rmem=%s\n' "$_rt"
            [ -z "$_wt" ] || printf 'tcp_wmem=%s\n' "$_wt"
        fi
        printf 'ssh=%s\nssh_adj=%s\nforensics=%s\ninterval=5\nheartbeat=300\n' "$2" "$LM_SSH_ADJ" "$3"
    } | _lm_write_kv "$(_lm_conf)" 600
}

_lm_install_service() {
    if [ -f "$(env_path "$LM_INIT")" ] && ! _lm_init_ours; then
        apm_err "$LM_INIT 已存在且不是 APM 生成的，拒绝覆盖"
        return 1
    fi
    _lm_write_init || return 1
    _snell_run rc-update add "$LM_SVC" default >/dev/null 2>&1 || :
    _lm_rc status >/dev/null 2>&1 || _lm_rc start >/dev/null 2>&1 || return 1
    return 0
}

# 开机应用 (由服务的 start_pre 调用): 把设置文件里的 tcp 目标写入当前网络命名空间，不碰原值备份
lowmem_boot() {
    local _k _t _a
    [ "$(_lm_cget tcp)" = on ] || return 0
    for _k in rmem wmem; do
        _t=$(_lm_cget "tcp_$_k")
        [ -n "$_t" ] || continue
        _lm_triplet_ok "$_t" || { apm_warn "设置文件里的 tcp_$_k 无效，已忽略"; continue; }
        _a=$(_lm_tcp_read "$_k")
        [ "$_a" = "$_t" ] && continue
        _lm_tcp_write "$_k" "$_t" || { apm_warn "无法写入 tcp_$_k"; continue; }
        apm_say "tcp_$_k: $_a -> $_t"
    done
    return 0
}

# ---- 恢复 ----

lowmem_disable() {
    local _k _o _t _c _pid _adj _comm _f _orig
    _lm_begin || return $?
    if ! lm_enabled && [ ! -f "$(_lm_orig)" ] && ! _lm_init_ours; then
        printf '低内存环境保护没有启用，没有需要恢复的内容\n'
        return 0
    fi
    # 先停服务: 常驻进程不再维护 sshd 的分数
    if _lm_init_ours; then
        _lm_rc stop >/dev/null 2>&1 || :
        _snell_run rc-update del "$LM_SVC" default >/dev/null 2>&1 || :
    fi
    printf '恢复结果：\n'
    # sshd: 只恢复仍然等于 APM 设置值的进程
    if [ -f "$(env_path "$LM_RUN/ssh.adj")" ]; then
        _f=$(env_path "$LM_RUN/ssh.adj")
        _c=0
        while read -r _pid _adj _comm; do
            [ -n "$_pid" ] || continue
            [ -r "$(env_path "/proc/$_pid/comm")" ] || continue
            _o=
            IFS= read -r _o < "$(env_path "/proc/$_pid/comm")" 2>/dev/null
            [ "$_o" = "$_comm" ] || continue
            IFS= read -r _t < "$(env_path "/proc/$_pid/oom_score_adj")" 2>/dev/null
            [ "$_t" = "$(_lm_cget ssh_adj)" ] || continue
            printf '%s\n' "$_adj" > "$(env_path "/proc/$_pid/oom_score_adj")" 2>/dev/null && _c=$((_c + 1))
        done < "$_f"
        printf '  SSH 保护：已把 %s 个进程的 oom_score_adj 恢复为原值\n' "$_c"
    else
        printf '  SSH 保护：没有需要恢复的进程\n'
    fi
    # tcp: 只在当前值仍等于 APM 设置值时写回
    for _k in rmem wmem; do
        _t=$(kv_get "$(_lm_orig)" "tcp_${_k}_target" 2>/dev/null)
        _o=$(kv_get "$(_lm_orig)" "tcp_${_k}_orig" 2>/dev/null)
        [ -n "$_o" ] || continue
        _c=$(_lm_tcp_read "$_k")
        if [ "$_c" = "$_o" ]; then
            printf '  tcp_%s：当前值已是原值 %s\n' "$_k" "$_o"
        elif [ "$_c" = "$_t" ]; then
            if _lm_tcp_write "$_k" "$_o" && [ "$(_lm_tcp_read "$_k")" = "$_o" ]; then
                printf '  tcp_%s：%s -> %s（恢复为原值）\n' "$_k" "$_c" "$_o"
            else
                printf '  tcp_%s：写回原值失败，当前仍是 %s\n' "$_k" "$_c"
            fi
        else
            printf '  tcp_%s：当前值 %s 既不是 APM 的设置也不是原值，已被外部修改，没有覆盖\n' "$_k" "$_c"
        fi
    done
    if _lm_init_ours; then rm -f -- "$(env_path "$LM_INIT")"; fi
    rm -rf -- "$(env_path "$LM_RUN")"
    rm -f -- "$(_lm_conf)" "$(_lm_orig)"
    printf '  OpenRC 服务与设置文件已删除，取证日志 %s 保留\n' "$LM_LOG"
    return 0
}

# ---- 状态 (只读, 从系统实时读取) ----

# 常驻进程是否在运行
_lm_daemon_running() {
    _lm_init_ours || return 1
    _lm_rc status >/dev/null 2>&1
}

_lm_log_size() {
    local _f
    _f=$(env_path "$LM_LOG")
    [ -f "$_f" ] || { printf '0'; return 0; }
    wc -c < "$_f" 2>/dev/null | tr -d ' '
}

# 输出一个模块的一行: 名称：状态
lowmem_status() {
    local _en _tcp _ssh _for _ok _total _line _k _t _c _n _bad _pid _adj _cm _okn
    lm_probe
    lm_plan_tcp
    lm_plan_ssh
    lm_plan_forensics
    _en=no
    lm_enabled && _en=yes
    _tcp=$(_lm_cget tcp); _ssh=$(_lm_cget ssh); _for=$(_lm_cget forensics)
    _total=0
    _ok=0
    printf '低内存环境保护\n'
    printf '  内存上限：%s（%s）\n' "$(_lm_mib "$LM_LIMIT")" "$(_lm_limit_src_text)"
    if [ -n "$LM_OOM_KILL" ]; then
        printf '  历史 OOM Kill：%s 次（所在 cgroup %s 自创建以来的累计，不是最近一次）\n' "$LM_OOM_KILL" "${LM_CG_DIR#"${APM_SYSROOT:-}"}"
    else
        printf '  历史 OOM Kill：不可用（没有可读的 cgroup v2 memory.events）\n'
    fi
    # TCP
    if [ "$_en" = yes ] && [ "$_tcp" = on ]; then
        _total=$((_total + 1))
        _bad=
        for _k in rmem wmem; do
            _t=$(_lm_cget "tcp_$_k")
            [ -n "$_t" ] || continue
            _c=$(_lm_tcp_read "$_k")
            [ "$_c" = "$_t" ] || _bad="$_bad tcp_$_k 当前 [$_c] 与设置 [$_t] 不一致（可能被外部修改）"
        done
        if [ -z "$_bad" ]; then
            _ok=$((_ok + 1))
            printf '  TCP 缓冲：已生效（接收 %s，发送 %s）\n' "$LM_RMEM" "$LM_WMEM"
        else
            printf '  TCP 缓冲：未生效：%s\n' "${_bad# }"
        fi
    else
        case $LM_P_TCP in
            plan) printf '  TCP 缓冲：%s；启用后调整\n' "$LM_P_TCP_NOTE" ;;
            *) printf '  TCP 缓冲：%s\n' "$LM_P_TCP_NOTE" ;;
        esac
    fi
    # SSH
    if [ "$_en" = yes ] && [ "$_ssh" = on ]; then
        _total=$((_total + 1))
        _n=0
        _okn=0
        while read -r _pid _adj _cm; do
            [ -n "$_pid" ] || continue
            _n=$((_n + 1))
            [ "$_adj" -le "$LM_SSH_ADJ" ] 2>/dev/null && _okn=$((_okn + 1))
        done <<EOF
$(_lm_ssh_procs)
EOF
        if [ "$_n" -eq 0 ]; then
            if _lm_daemon_running; then _ok=$((_ok + 1)); printf '  SSH 保护：已启用，当前没有 sshd 进程，出现后由常驻进程设置\n'
            else printf '  SSH 保护：未生效（常驻进程没有运行）\n'; fi
        elif [ "$_okn" -eq "$_n" ]; then
            _ok=$((_ok + 1))
            printf '  SSH 保护：已生效（%s 个 sshd 进程的 oom_score_adj 不高于 %s）\n' "$_n" "$LM_SSH_ADJ"
        else
            printf '  SSH 保护：部分生效（%s/%s 个 sshd 进程已设置，新进程由常驻进程在数秒内设置）\n' "$_okn" "$_n"
        fi
    else
        printf '  SSH 保护：%s\n' "$LM_P_SSH_NOTE"
    fi
    # 取证
    if [ "$_en" = yes ] && [ "$_for" = on ]; then
        _total=$((_total + 1))
        if _lm_daemon_running; then
            _ok=$((_ok + 1))
            printf '  内存取证：运行中（日志 %s，%s 字节，只在 oom_kill 变化时详细记录）\n' "$LM_LOG" "$(_lm_log_size)"
        else
            printf '  内存取证：未生效（常驻进程没有运行）\n'
        fi
    else
        printf '  内存取证：%s\n' "$LM_P_FOR_NOTE"
    fi
    # 持久化
    if [ "$_en" = yes ]; then
        if _lm_init_ours && [ -e "$(env_path /etc/runlevels/default/$LM_SVC)" ]; then
            printf '  开机持久化：已启用（OpenRC 服务 %s，default 运行级别）\n' "$LM_SVC"
        else
            printf '  开机持久化：未生效（OpenRC 服务缺失或没有加入开机启动）\n'
        fi
    fi
    if [ "$_en" != yes ]; then
        printf '  保护状态：未启用\n'
    elif [ "$_total" -eq 0 ]; then
        printf '  保护状态：已启用，但没有生效的项目\n'
    elif [ "$_ok" -eq "$_total" ]; then
        printf '  保护状态：已启用（%s/%s 项生效）\n' "$_ok" "$_total"
    else
        printf '  保护状态：部分启用（%s/%s 项生效）\n' "$_ok" "$_total"
    fi
    return 0
}

# 详情: 每个调整的原值 目标值 实际值 依据
lowmem_detail() {
    local _k _o _t _w _c
    lowmem_status
    printf '\n详情\n'
    printf '  网络命名空间：'
    case $LM_NETNS in
        own) printf '容器自己的网络命名空间（core 全局参数不可见），tcp_rmem/tcp_wmem 的修改只影响本容器\n' ;;
        host) printf '初始网络命名空间（整机），tcp_rmem/tcp_wmem 的修改对本机所有连接生效\n' ;;
        *) printf '未确认\n' ;;
    esac
    printf '  当前 tcp_rmem：%s\n  当前 tcp_wmem：%s\n' "${LM_RMEM:-不可用}" "${LM_WMEM:-不可用}"
    printf '  内核默认值（参照）：tcp_rmem %s，tcp_wmem %s\n' "$LM_KD_RMEM" "$LM_KD_WMEM"
    if [ -f "$(_lm_orig)" ]; then
        for _k in rmem wmem; do
            _o=$(kv_get "$(_lm_orig)" "tcp_${_k}_orig")
            [ -n "$_o" ] || continue
            _t=$(kv_get "$(_lm_orig)" "tcp_${_k}_target")
            _w=$(kv_get "$(_lm_orig)" "tcp_${_k}_why")
            _c=$(_lm_tcp_read "$_k")
            printf '  tcp_%s：原值 [%s]，目标 [%s]，当前 [%s]\n    依据：%s\n' "$_k" "$_o" "$_t" "$_c" "$_w"
        done
        printf '  原始设置保存在 %s\n' "$(_lm_orig)"
    fi
    printf '  SSH 保护范围：只降低 sshd 相关进程的 oom_score_adj，不修改其他进程；容器权限不允许时不会尝试\n'
    printf '  说明：memory.events 是累计计数；内存占用偏高不等于发生过 OOM；周期采样抓不到毫秒级峰值\n'
    printf '  说明：不承诺启用后 SSH 一定不被 OOM 杀死，也不承诺高流量下 Snell 一定稳定；资源本身不足时这些保护无法替代更多内存\n'
    return 0
}

lowmem_log() {
    local _n _f
    _n=${1:-20}
    case $_n in ''|*[!0-9]*) apm_err "行数必须是正整数"; return 2 ;; esac
    [ "$_n" -ge 1 ] && [ "$_n" -le 200 ] || { apm_err "行数范围 1 到 200"; return 2; }
    _f=$(env_path "$LM_LOG")
    if [ ! -s "$_f" ]; then printf '还没有取证记录（%s）\n' "$LM_LOG"; return 0; fi
    tail -n "$_n" "$_f"
}

lowmem_cli() {
    local _sub
    _sub=${1:-status}
    [ $# -eq 0 ] || shift
    case $_sub in
        status) lowmem_status ;;
        detail) lowmem_detail ;;
        enable) lowmem_enable ;;
        disable) lowmem_disable ;;
        boot) lowmem_boot ;;
        log) lowmem_log "$@" ;;
        *) apm_err "用法: lowmem [status | detail | enable | disable | log [N]]"; return 2 ;;
    esac
}

# 一行摘要 (状态总览用, 只读文件不探测)
lowmem_summary() {
    if lm_enabled; then printf '已启用'; else printf '未启用'; fi
}
