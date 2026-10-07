# shellcheck shell=sh
# 路径抽象与功能状态汇总
#
# 配置目录   /etc/alpine-proxy-manager/{instances,socks}   目录 0700, 文件 0600
# 数据目录   /var/lib/alpine-proxy-manager/{backups,cores}
# Core 归属元数据 cores/<key>.meta 只由 Manager 写入 内容 managed=true core=<key> binary= exact_release=
# 以上路径均可被 APM_ETC / APM_VAR 覆盖, 默认带 APM_SYSROOT 前缀

state_etc() { printf '%s' "${APM_ETC:-$(env_path /etc/alpine-proxy-manager)}"; }
state_var() { printf '%s' "${APM_VAR:-$(env_path /var/lib/alpine-proxy-manager)}"; }
state_instances_dir() { printf '%s/instances' "$(state_etc)"; }
state_socks_dir() { printf '%s/socks' "$(state_etc)"; }
state_backup_dir() { printf '%s/backups' "$(state_var)"; }
state_cores_dir() { printf '%s/cores' "$(state_var)"; }

# 创建目录, 仅供会写入的命令调用, 只读命令不得调用
state_ensure_dirs() {
    local _d
    # 父目录也收紧: 子目录与文件本来就是 0700 与 0600, 这里避免目录项本身被枚举
    mkdir -p -- "$(state_etc)" && chmod 700 -- "$(state_etc)" || return 1
    for _d in "$(state_instances_dir)" "$(state_socks_dir)" "$(state_backup_dir)" "$(state_cores_dir)"; do
        mkdir -p -- "$_d" && chmod 700 -- "$_d" || return 1
    done
}

# 列出目录下的 *.conf, 每行一个路径, 目录不存在时无输出
state_list_confs() {
    local _f
    for _f in "$1"/*.conf; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
    return 0
}

# Server SOCKS Egress 摘要
#   未配置 | 已配置 N 个 Profile (启用 M 个)  末尾可附 (K 个无效)
state_socks_summary() {
    local _total _on _bad _f
    _total=0
    _on=0
    _bad=0
    for _f in $(state_list_confs "$(state_socks_dir)"); do
        _total=$((_total + 1))
        if socks_validate "$_f" >/dev/null 2>&1; then
            [ "$(kv_get "$_f" enabled)" = true ] && _on=$((_on + 1))
        else
            _bad=$((_bad + 1))
        fi
    done
    if [ "$_total" -eq 0 ]; then
        printf '未配置'
        return 0
    fi
    printf '已配置 %s 个 Profile (启用 %s 个)' "$_total" "$_on"
    [ "$_bad" -eq 0 ] || printf ', %s 个无效' "$_bad"
}

# Relay Access Policy 摘要
#   未配置 | N 个实例启用  末尾可附 (K 个无效)
state_relay_summary() {
    local _on _bad _f
    _on=0
    _bad=0
    for _f in $(state_list_confs "$(state_instances_dir)"); do
        if instance_validate "$_f" >/dev/null 2>&1; then
            policy_enabled "$_f" && _on=$((_on + 1))
        else
            _bad=$((_bad + 1))
        fi
    done
    if [ "$_on" -eq 0 ] && [ "$_bad" -eq 0 ]; then
        printf '未配置'
        return 0
    fi
    printf '%s 个实例启用' "$_on"
    [ "$_bad" -eq 0 ] || printf ', %s 个实例配置无效' "$_bad"
}
