# shellcheck shell=sh
# Manager 自更新: 检查 GitHub 上最新的正式 Release, 确认后复用现有安装器升级 Manager 本身
#
# 原则
#   - 只用用户手动触发时的最新正式 Release, 不追踪 main, 不使用 Draft 与 Pre-release, 不使用任意最新 tag
#   - 不新增第二套下载 解压 安装 替换 回滚: 实际升级完全由 install.sh 完成 (原子 release/current 切换, 自检, 失败回滚, 归档 sha256 校验)
#     这里只做更新协调: 查询 校验 比较版本 取得与归档同源的 install.sh 调用它 校验结果
#   - install.sh 取自已校验的 Release 归档本身, 而不是另外下载的脚本, 所以它和归档处在同一条 SHA256SUMS 校验链上
#   - 不使用 jq Python Node eval: 远端返回的内容只经过 sed 提取并用严格的正则校验后才会使用
#   - 不新增常驻进程 cron 或后台更新, 不修改 Snell 与 sing-box 及其配置, 不重启任何 Core
#   - 版本只允许前进: 当前版本不低于目标时不更新, 不降级, 同版本不同 Build 只说明不切换
#
# 退出码: 0 成功或无需更新的检查, 1 失败, 2 用法错误, 3 没有可更新的正式版本, 4 被拒绝 (需要 root 或写锁被占用), 10 发现新版本 (仅 check-update)

MGR_REPO_DEFAULT="csjcsl666/alpine-proxy-manager"
MGR_TAG=
MGR_VER=
MGR_ERR=

_mgr_repo() { printf '%s' "${APM_REPO:-$MGR_REPO_DEFAULT}"; }
_mgr_api() { printf '%s' "${APM_MGR_API:-https://api.github.com/repos/$(_mgr_repo)}"; }
_mgr_dl() { printf '%s' "${APM_MGR_DL:-https://github.com/$(_mgr_repo)/releases/download}"; }
_mgr_timeout() { printf '%s' "${APM_MGR_TIMEOUT:-8}"; }

# 取 URL 的前 200000 字节到 stdout, 复用 APM_DOWNLOADER (默认 BusyBox wget), 短超时, 失败时没有输出
_mgr_get() {
    local _dl _t
    _dl=${APM_DOWNLOADER:-wget}
    command -v "$_dl" >/dev/null 2>&1 || return 1
    _t=$(_mgr_timeout)
    _client_timeout "$_t" "$_dl" -q -T "$_t" -O - "$1" 2>/dev/null | head -c 200000
}

# 把 JSON 规整成每行一个字段, 再取第一个匹配的字符串值或布尔值, 值之后由调用方用严格正则校验
_mgr_json_lines() { sed 's/[{},]/\n/g'; }
_mgr_json_str() { # 键
    sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)"[[:space:]]*$/\1/p' | head -n 1
}
_mgr_json_bool() { # 键
    sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*\(true\|false\)[[:space:]]*$/\1/p' | head -n 1
}

# 版本比较, 输出 lt eq gt: X.Y.Z 按数字比较, 带预发布后缀的版本 (如 0.5.2-dev.1) 低于同核心的正式版, 构建元数据忽略
_mgr_vcmp() { # A B
    local _ca _cb _sa _sb _r
    _ca=${1%%[-+]*}
    _cb=${2%%[-+]*}
    _r=$(awk -v a="$_ca" -v b="$_cb" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 < y[i] + 0) { print "lt"; exit }
            if (x[i] + 0 > y[i] + 0) { print "gt"; exit }
        }
        print "eq" }')
    if [ "$_r" = eq ]; then
        _sa=no
        _sb=no
        case $1 in *-*) _sa=yes ;; esac
        case $2 in *-*) _sb=yes ;; esac
        if [ "$_sa" = yes ] && [ "$_sb" = no ]; then _r=lt; fi
        if [ "$_sa" = no ] && [ "$_sb" = yes ]; then _r=gt; fi
    fi
    printf '%s' "$_r"
}

# 查询最新正式 Release, 成功设置 MGR_TAG 与 MGR_VER, 失败设置 MGR_ERR 并返回 1
# releases/latest 本身不返回 Draft 与 Pre-release, 这里仍然检查字段, 不依赖这个假设
_mgr_resolve_latest() {
    local _repo _json _lines _tag _draft _pre
    MGR_TAG=
    MGR_VER=
    MGR_ERR=
    _repo=$(_mgr_repo)
    if ! printf '%s' "$_repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        MGR_ERR="仓库名无效"
        return 1
    fi
    _json=$(_mgr_get "$(_mgr_api)/releases/latest")
    if [ -z "$_json" ]; then
        MGR_ERR="无法连接 GitHub 或请求超时或返回了错误状态"
        return 1
    fi
    _lines=$(printf '%s' "$_json" | _mgr_json_lines)
    _tag=$(printf '%s\n' "$_lines" | _mgr_json_str tag_name)
    _draft=$(printf '%s\n' "$_lines" | _mgr_json_bool draft)
    _pre=$(printf '%s\n' "$_lines" | _mgr_json_bool prerelease)
    if [ -z "$_tag" ]; then
        MGR_ERR="返回内容里没有 Release 信息 (可能还没有正式 Release 或被限流)"
        return 1
    fi
    if ! printf '%s' "$_tag" | grep -Eq '^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'; then
        MGR_ERR="返回的版本号格式无效"
        return 1
    fi
    if [ "$_draft" != false ] || [ "$_pre" != false ]; then
        MGR_ERR="最新的 Release 不是正式版 (Draft 或 Pre-release 不会被使用)"
        return 1
    fi
    MGR_TAG=$_tag
    MGR_VER=${_tag#v}
    return 0
}

# 正式 Release 对应 commit 的 7 位 Build, 取不到时输出空
_mgr_tag_build() { # tag
    local _sha
    _sha=$(_mgr_get "$(_mgr_api)/commits/$1" | _mgr_json_lines | _mgr_json_str sha)
    if printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{40}$'; then
        printf '%s' "$_sha" | cut -c1-7
    fi
}

_mgr_fail_check() {
    printf '检查更新失败：无法获取 GitHub Release 信息。\n'
    [ -z "$MGR_ERR" ] || printf '原因：%s\n' "$MGR_ERR"
    printf '\n当前 Manager 未发生任何变化。\n'
}

# 检查更新, 只读, 任何用户可用
#   0 已是最新或不需要更新  10 发现新版本  1 失败
manager_check_update() {
    local _cur _build _cmp _rb
    [ $# -eq 0 ] || { apm_err "check-update 不需要参数"; return 2; }
    if ! _mgr_resolve_latest; then
        _mgr_fail_check
        return 1
    fi
    _cur=$(apm_version)
    _build=$(apm_build)
    _cmp=$(_mgr_vcmp "$_cur" "$MGR_VER")
    printf '当前版本：%s\n最新正式版：%s\n' "$_cur" "$MGR_VER"
    case $_cmp in
        lt)
            printf '\n发现新版本。\n'
            return 10
            ;;
        gt)
            printf '\n当前版本高于最新正式版，可能是开发版，不会降级。\n'
            return 0
            ;;
    esac
    _rb=$(_mgr_tag_build "$MGR_TAG")
    if [ -n "$_rb" ] && [ "$_build" != "$_rb" ]; then
        printf '当前 Build：%s\n正式版 Build：%s\n' "$_build" "$_rb"
        printf '\n版本号相同但 Build 不同，当前可能是来自 main 的开发版，这不是新的正式版本，不会自动切换。\n'
        return 0
    fi
    if [ -z "$_rb" ]; then
        printf '\n已是最新正式版 (无法确认 Build)。\n'
    else
        printf '\n已是最新正式版。\n'
    fi
    return 0
}

_mgr_core_before() { # key -> 输出 PID 或 -
    core_discover "$1"
    if [ "$CF_INSTALLED" != yes ]; then printf '%s' "-"; return 0; fi
    printf '%s' "${CF_PID:--}"
}

# 更新前后的 Core 状态, 如实报告, 不推断
_mgr_core_report() { # 名称 key 更新前 PID
    local _now
    _now=$(_mgr_core_before "$2")
    if [ "$3" = - ] && [ "$_now" = - ]; then
        core_discover "$2"
        if [ "$CF_INSTALLED" = yes ]; then printf '%s：未运行\n' "$1"; else printf '%s：未安装\n' "$1"; fi
    elif [ "$3" = "$_now" ]; then
        printf '%s：未重启 (PID %s)\n' "$1" "$_now"
    else
        printf '%s：PID 已变化 (%s → %s)\n' "$1" "$3" "$_now"
    fi
}

_mgr_update_fail() { # 原因
    printf 'Manager 更新失败。\n\n原因：%s\n' "$1"
    printf '\n当前 Manager 保持原版本 %s 可用，没有安装任何新文件。\n' "$(apm_version)"
}

# 更新 Manager 本身
manager_update() {
    local _cur _cmp _base _asset _sum _got _tmp _vmember _out _rc _link _nv _nb _sp0 _bp0
    [ $# -eq 0 ] || { apm_err "update 不需要参数"; return 2; }
    _snell_need_root || return 4
    if ! _mgr_resolve_latest; then
        printf 'Manager 更新失败：无法获取 GitHub Release 信息。\n'
        [ -z "$MGR_ERR" ] || printf '原因：%s\n' "$MGR_ERR"
        printf '\n当前 Manager 未发生任何变化。\n'
        return 1
    fi
    _cur=$(apm_version)
    _cmp=$(_mgr_vcmp "$_cur" "$MGR_VER")
    if [ "$_cmp" != lt ]; then
        printf '当前版本：%s\n最新正式版：%s\n\n' "$_cur" "$MGR_VER"
        if [ "$_cmp" = gt ]; then
            printf '当前版本高于最新正式版，可能是开发版，不会降级。\n'
        else
            printf '没有可更新的正式版本，不会切换到 main 或其他 Build。\n'
        fi
        return 3
    fi
    _snell_lock || return 4
    trap '_snell_cleanup' EXIT
    _snell_ensure_staging || return 1
    _tmp=$SNELL_STAGING
    _base=$(_mgr_dl)/$MGR_TAG
    _asset=alpine-proxy-manager-$MGR_VER.tar.gz
    # 校验链: SHA256SUMS 里的哈希 对应下载到的归档, 缺失或格式异常都拒绝, 不退回到未校验的安装
    _snell_fetch "$_base/SHA256SUMS" "$_tmp/SHA256SUMS" || { _mgr_update_fail "下载 SHA256SUMS 失败"; return 1; }
    _sum=$(awk -v f="$_asset" '$2 == f && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; exit }' "$_tmp/SHA256SUMS")
    [ -n "$_sum" ] || { _mgr_update_fail "SHA256SUMS 里没有 $_asset 的有效校验和"; return 1; }
    _snell_fetch "$_base/$_asset" "$_tmp/$_asset" || { _mgr_update_fail "下载 $_asset 失败"; return 1; }
    _got=$(sha256sum "$_tmp/$_asset" | awk '{ print $1 }')
    [ "$_got" = "$_sum" ] || { _mgr_update_fail "归档校验和不匹配"; return 1; }
    tar -tzf "$_tmp/$_asset" > "$_tmp/list" 2>/dev/null || { _mgr_update_fail "归档无法读取"; return 1; }
    if grep -Eq '(^|/)\.\.(/|$)|^/' "$_tmp/list"; then
        _mgr_update_fail "归档包含不安全的路径"
        return 1
    fi
    # 归档里的 VERSION 必须和 Release 版本一致, 防止 tag 与内容不符造成意外降级
    _vmember=alpine-proxy-manager-$MGR_VER
    _nv=$(tar -xzf "$_tmp/$_asset" -O "$_vmember/VERSION" 2>/dev/null | head -n 1 | tr -d '\r \t')
    [ "$_nv" = "$MGR_VER" ] || { _mgr_update_fail "归档内的版本 ($_nv) 与 Release ($MGR_VER) 不一致"; return 1; }
    [ "$(_mgr_vcmp "$_cur" "$_nv")" = lt ] || { _mgr_update_fail "目标版本不高于当前版本，拒绝降级"; return 1; }
    # install.sh 取自已校验的归档本身
    tar -xzf "$_tmp/$_asset" -O "$_vmember/install.sh" > "$_tmp/install.sh" 2>/dev/null || { _mgr_update_fail "归档里没有 install.sh"; return 1; }
    sh -n "$_tmp/install.sh" 2>/dev/null || { _mgr_update_fail "归档里的 install.sh 语法检查失败"; return 1; }
    _sp0=$(_mgr_core_before snell)
    _bp0=$(_mgr_core_before singbox)
    # 复用现有安装器: 与 README 的固定版本命令等价, 由它负责原子切换 自检 与失败回滚
    _out=$( ( APM_REF=$MGR_TAG APM_ARCHIVE_URL=$_base/$_asset APM_SHA256=$_sum
              export APM_REF APM_ARCHIVE_URL APM_SHA256
              sh "$_tmp/install.sh" ) 2>&1 )
    _rc=$?
    _link=${APM_ROOT:-}
    _link=${_link%/}/usr/local/bin/proxy-manager
    _nv=$("$_link" --version 2>/dev/null | sed -n 's/^Alpine Proxy Manager //p' | head -n 1)
    _nb=$("$_link" --version 2>/dev/null | sed -n 's/^Build: //p' | head -n 1)
    if [ "$_rc" -ne 0 ] || [ "$_nv" != "$MGR_VER" ] || ! printf '%s' "$_nb" | grep -Eq '^[0-9a-f]{7}'; then
        printf 'Manager 更新失败。\n\n'
        printf '安装器输出：\n%s\n' "$(printf '%s\n' "$_out" | tail -n 8 | sed 's/^/  /')"
        printf '\n当前 Manager 版本：%s (安装器会在失败时回滚到原版本)\n' "${_nv:-未知}"
        return 1
    fi
    printf 'Manager 更新成功。\n\n原版本：%s\n新版本：%s\nBuild：%s\n\n' "$_cur" "$_nv" "$_nb"
    _mgr_core_report Snell snell "$_sp0"
    _mgr_core_report sing-box singbox "$_bp0"
    printf '\n请重新运行 apm 使用新版管理界面。\n'
    return 0
}

manager_cli() {
    local _sub
    _sub=${1:-}
    [ $# -eq 0 ] || shift
    case $_sub in
        check-update) manager_check_update "$@" ;;
        update) manager_update "$@" ;;
        ''|help) apm_err "用法: manager check-update | update"; return 2 ;;
        *) apm_err "未知的 manager 子命令: $_sub"; return 2 ;;
    esac
}
