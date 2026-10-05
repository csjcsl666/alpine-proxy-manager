# shellcheck shell=sh
# 通用函数: 输出, 版本, 单位换算
# 依赖: APM_HOME 已由入口脚本设置

APM_NAME="Alpine Proxy Manager"

apm_say() { printf '%s\n' "$*"; }
apm_warn() { printf '警告: %s\n' "$*" >&2; }
apm_err() { printf '错误: %s\n' "$*" >&2; }

# 外部版本的唯一权威来源是 $APM_HOME/VERSION
apm_version() {
    local _v
    _v=
    if [ -r "$APM_HOME/VERSION" ]; then
        IFS= read -r _v < "$APM_HOME/VERSION" || :
    fi
    printf '%s\n' "${_v:-unknown}"
}

# Build 来源优先级: 安装时写入的 BUILD 文件, 其次 git commit short SHA, 最后 unknown
apm_build() {
    local _b
    _b=
    if [ -r "$APM_HOME/BUILD" ]; then
        IFS= read -r _b < "$APM_HOME/BUILD" || :
    fi
    if [ -z "$_b" ] && command -v git >/dev/null 2>&1 && [ -e "$APM_HOME/.git" ]; then
        _b=$(git -c safe.directory='*' -C "$APM_HOME" rev-parse --short HEAD 2>/dev/null) || _b=
    fi
    printf '%s\n' "${_b:-unknown}"
}

apm_print_version() {
    printf '%s %s\n' "$APM_NAME" "$(apm_version)"
    printf 'Build: %s\n' "$(apm_build)"
}

# 字节转 MiB, 向下取整
apm_mib() { printf '%s' $(($1 / 1048576)); }
