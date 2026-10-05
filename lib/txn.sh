# shellcheck shell=sh
# 配置事务: 候选文件 -> 校验 -> 备份 -> 原子替换 -> 可选 reload
#
# 用法:
#   cand=$(txn_new_candidate /etc/foo/config.json)
#   generate > "$cand"
#   txn_commit /etc/foo/config.json "$cand" validator_cmd [reload_cmd]
#
# validator_cmd 与 reload_cmd 都是单个命令名或函数名, 校验时以候选文件路径为唯一参数调用
# 例如 sing-box 使用 core_singbox_check_config
#
# txn_commit 返回码:
#   0   成功
#   2   候选文件不存在
#   10  校验失败, 当前配置未被改动, 候选文件已删除
#   11  备份失败, 当前配置未被改动
#   12  替换后 reload 失败, 已回滚到旧配置, 需要人工确认服务状态
#   13  替换失败, 当前配置未被改动
#
# 同目录 mv 是原子的, 候选文件必须与目标在同一文件系统, txn_new_candidate 保证这一点
# 尚未实现并发锁, 两个管理进程同时写同一目标的行为未定义

# 保留的备份份数, 可被 APM_BACKUP_KEEP 覆盖
txn_backup_keep() { printf '%s' "${APM_BACKUP_KEEP:-10}"; }

# txn_new_candidate TARGET, 在目标同目录创建 0600 的隐藏候选文件并输出路径
txn_new_candidate() {
    local _dir _base
    _dir=${1%/*}
    _base=${1##*/}
    [ "$_dir" = "$1" ] && _dir=.
    mktemp "$_dir/.$_base.cand.XXXXXX"
}

# atomic_install SRC DST MODE, 复制到 DST 同目录的临时文件后 mv 覆盖
atomic_install() {
    local _tmp _dir _base
    _dir=${2%/*}
    _base=${2##*/}
    [ "$_dir" = "$2" ] && _dir=.
    _tmp="$_dir/.$_base.tmp.$$"
    cp -- "$1" "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    chmod "$3" "$_tmp" || { rm -f -- "$_tmp"; return 1; }
    mv -f -- "$_tmp" "$2" || { rm -f -- "$_tmp"; return 1; }
}

# txn_backup TARGET, 备份到备份目录并输出备份路径
# 文件名 <base>.bak.<时间戳>.<序号>, 字典序即时间序
txn_backup() {
    local _dir _base _ts _n _c _dst _keep _count _f _del
    _dir=${APM_BACKUP_DIR:-$(state_backup_dir)}
    _base=${1##*/}
    mkdir -p -- "$_dir" && chmod 700 -- "$_dir" || return 1
    _ts=$(date +%Y%m%d%H%M%S)
    # 同一秒内序号取已有最大值加一, 不能取第一个空位, 否则裁剪后序号回退会打乱时间序
    _n=0
    for _f in "$_dir/$_base.bak.$_ts".[0-9]*; do
        [ -e "$_f" ] || continue
        _c=$(printf '%s' "${_f##*.}" | sed 's/^0*//')
        [ "${_c:-0}" -ge "$_n" ] && _n=$(( ${_c:-0} + 1 ))
    done
    _dst=$(printf '%s/%s.bak.%s.%03d' "$_dir" "$_base" "$_ts" "$_n")
    cp -p -- "$1" "$_dst" || return 1

    _keep=$(txn_backup_keep)
    _count=0
    for _f in "$_dir/$_base".bak.[0-9]*; do
        [ -e "$_f" ] && _count=$((_count + 1))
    done
    _del=$((_count - _keep))
    for _f in "$_dir/$_base".bak.[0-9]*; do
        [ "$_del" -gt 0 ] || break
        [ -e "$_f" ] || continue
        rm -f -- "$_f"
        _del=$((_del - 1))
    done
    printf '%s\n' "$_dst"
}

txn_commit() {
    local _target _cand _validator _reload _backup _mode
    _target=$1
    _cand=$2
    _validator=$3
    _reload=${4:-}
    _backup=

    [ -f "$_cand" ] || { apm_err "候选文件不存在: $_cand"; return 2; }

    if ! "$_validator" "$_cand"; then
        rm -f -- "$_cand"
        apm_err "候选配置校验失败, 当前配置未改动"
        return 10
    fi

    _mode=600
    if [ -e "$_target" ]; then
        _mode=$(stat -c %a -- "$_target") || _mode=600
        if ! _backup=$(txn_backup "$_target"); then
            rm -f -- "$_cand"
            apm_err "备份旧配置失败, 当前配置未改动"
            return 11
        fi
    fi

    chmod "$_mode" -- "$_cand"
    if ! mv -f -- "$_cand" "$_target"; then
        rm -f -- "$_cand"
        apm_err "替换配置失败, 当前配置未改动"
        return 13
    fi

    if [ -n "$_reload" ] && ! "$_reload"; then
        if [ -n "$_backup" ]; then
            atomic_install "$_backup" "$_target" "$_mode"
        else
            rm -f -- "$_target"
        fi
        apm_err "reload 失败, 已回滚到旧配置, 请检查服务状态"
        return 12
    fi
    return 0
}
