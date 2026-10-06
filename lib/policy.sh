# shellcheck shell=sh
# Relay Access Policy (界面名称: 目标访问限制)
#
# 按入口实例配置, 内容存放在该实例文件的 relay_access.* 键中, 不存在全局开关
#   relay_access.enabled         true | false, 缺省视为 false
#   relay_access.mode            allowlist, v0.1 只有这一种
#   relay_access.default_action  reject, allowlist 之外的目标一律拒绝
#   relay_access.destination.N   host:port, N 为正整数, 可以没有, 没有时 allowlist 拒绝全部目标
#
# 这里只定义模型与校验, 如何翻译为 Snell 或 sing-box 的具体规则由各 Adapter 决定
# 它描述的是服务器作为 TCP relay 允许连接哪些目标
# 不涉及 SOCKS 凭据, SOCKS handshake 在客户端完成, 服务器看不到

# 校验 host:port, 允许 IPv4, [IPv6] 与主机名, 各 Adapter 可以进一步收紧
policy_valid_destination() {
    local _h _p
    case $1 in *:*) ;; *) return 1 ;; esac
    _h=${1%:*}
    _p=${1##*:}
    is_host "$_h" && is_port "$_p"
}

policy_enabled() {
    [ "$(kv_get "$1" relay_access.enabled)" = true ]
}

# 输出每个目标一行 "host port", 供 Adapter 消费
policy_destinations() {
    local _k _d
    for _k in $(kv_keys "$1" | grep -E '^relay_access\.destination\.' | sort -t. -k3 -n); do
        _d=$(kv_get "$1" "$_k")
        printf '%s %s\n' "${_d%:*}" "${_d##*:}"
    done
}

# 人类可读摘要: 关闭 | allowlist (N 项)
policy_summary() {
    if policy_enabled "$1"; then
        printf 'allowlist (%s 项)' "$(policy_destinations "$1" | wc -l | tr -d ' ')"
    else
        printf '关闭'
    fi
}

policy_validate() {
    local _f _rc _en _mode _act _k _idx _d
    _f=$1
    _rc=0
    _en=$(kv_get "$_f" relay_access.enabled)
    _mode=$(kv_get "$_f" relay_access.mode)
    _act=$(kv_get "$_f" relay_access.default_action)

    if [ -n "$_en" ] && ! is_bool "$_en"; then
        apm_err "$_f: relay_access.enabled 必须是 true 或 false"
        _rc=1
    fi
    if [ -n "$_mode" ] && [ "$_mode" != allowlist ]; then
        apm_err "$_f: relay_access.mode 仅支持 allowlist, 得到 '$_mode'"
        _rc=1
    fi
    if [ -n "$_act" ] && [ "$_act" != reject ]; then
        apm_err "$_f: relay_access.default_action 仅支持 reject, 得到 '$_act'"
        _rc=1
    fi

    for _k in $(kv_keys "$_f" | grep -E '^relay_access\.'); do
        case $_k in
            relay_access.enabled|relay_access.mode|relay_access.default_action) ;;
            relay_access.destination.*)
                _idx=${_k#relay_access.destination.}
                if ! is_uint "$_idx" || [ "$_idx" -lt 1 ]; then
                    apm_err "$_f: $_k 的序号必须是正整数"
                    _rc=1
                fi
                _d=$(kv_get "$_f" "$_k")
                if ! policy_valid_destination "$_d"; then
                    apm_err "$_f: $_k 不是有效的 host:port: '$_d'"
                    _rc=1
                fi
                ;;
            *) apm_err "$_f: 未知的 key: $_k"; _rc=1 ;;
        esac
    done

    # 启用时必须完整声明 mode 与 default_action, 空的 allowlist 合法, 语义是拒绝全部目标, 绝不退回不限制
    if [ "$_en" = true ]; then
        [ "$_mode" = allowlist ] || { apm_err "$_f: 启用 relay_access 时必须设置 mode=allowlist"; _rc=1; }
        [ "$_act" = reject ] || { apm_err "$_f: 启用 relay_access 时必须设置 default_action=reject"; _rc=1; }
    fi
    return "$_rc"
}
