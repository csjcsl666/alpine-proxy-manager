# shellcheck shell=sh
# README 与命令行帮助一致: README 里出现的每条命令都能在 help 里找到, help 里的每个子命令 README 也提到, 不残留过时说明
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

PM="$T_ROOT/bin/proxy-manager"
R=$T_ROOT/README.md
HELP=$("$PM" help </dev/null 2>&1)
assert_contains "help 可用" "$HELP" "用法: proxy-manager"

# README 代码块里 proxy-manager 开头的行: 前两到三个词必须出现在 help 里
n=0
bad=
awk '/^```/ { on = !on; next } on && /^(printf .*\| )?(proxy-manager|apm) / { sub(/^printf [^|]*\| /, ""); print $2 "~" $3 }' "$R" | sort -u > "$T_TMP/readme.cmds"
while read -r w; do
    a=${w%%~*}
    b=${w##*~}
    n=$((n + 1))
    case $a in
        --version|doctor|status|tui|help) cmd=$a ;;
        *) cmd="$a $b" ;;
    esac
    case $HELP in
        *"$cmd"*) ;;
        *) bad="$bad [$cmd]" ;;
    esac
done < "$T_TMP/readme.cmds"
assert_eq "README 代码块里的命令在 help 中都有 (共 $n 种前缀)" "" "$bad"

# help 里列出的每个子命令 README 都提到
for c in "snell install" "snell status" "snell config" "snell update" "snell uninstall" "snell endpoint" "snell export" \
    "sing-box install" "sing-box status" "sing-box update" "sing-box uninstall" "sing-box add" "sing-box list" "sing-box set" \
    "sing-box access" "sing-box socks" "sing-box egress" "sing-box endpoint" "sing-box export" "tui" "doctor" "core list"; do
    case $HELP in *"$c"*) t_pass "help 含 $c" ;; *) t_fail "help 缺少 $c" ;; esac
    if grep -q -- "$c" "$R"; then t_pass "README 提到 $c"; else t_fail "README 没有提到 $c"; fi
done

# 版本与过时措辞
# 默认一键安装必须固定到正式版 tag, 不能退回 main, 版本以 VERSION 为单一来源: tag 不能比 VERSION 新 (发布顺序是先改 VERSION 再打 tag 再更新 README, 所以允许落后)
first=$(awk '/^## 安装/ { on = 1 } on && /^```sh/ { getline; print; exit }' "$R")
rtag=$(printf '%s' "$first" | sed -n 's/.*APM_REF=\(v[0-9][0-9.]*\) .*/\1/p')
utag=$(printf '%s' "$first" | sed -n 's|.*alpine-proxy-manager/\(v[0-9][0-9.]*\)/install.sh.*|\1|p')
assert_eq "README 默认安装的 APM_REF 与下载地址里的 tag 一致" "$rtag" "$utag"
assert_eq "README 默认安装固定到正式版 tag" 1 "$([ -n "$rtag" ] && echo 1 || echo 0)"
assert_eq "README 默认安装命令里没有 main" 0 "$(printf '%s' "$first" | grep -c 'main')"
if [ -n "$rtag" ]; then
    oldest=$(printf '%s\n%s\n' "${rtag#v}" "$(cat "$T_ROOT/VERSION")" | sort -V | head -n 1)
    assert_eq "README 默认安装的 tag 不比 VERSION 新" "${rtag#v}" "$oldest"
fi
assert_eq "README 单独标出开发版 main" 1 "$(grep -c '^### 开发版 main' "$R")"
assert_eq "README 不写死版本号 0.1.0-dev" 0 "$(grep -c '0\.1\.0-dev' "$R")"
assert_eq "README 不含过时的 早期开发版本 措辞" 0 "$(grep -c '早期开发版本\|早期阶段' "$R")"
assert_eq "README 不再说不支持服务器自身的 SOCKS 出口" 0 "$(grep -c '当前不支持服务器自身的 SOCKS 出口' "$R")"
assert_eq "README 没有句号与表情" 0 "$(grep -c '。' "$R")"
assert_eq "README 提到 TLS 策略是有意设计而不是缺陷" 1 "$(grep -c '这是有意的低维护设计' "$R")"
assert_eq "README 说明不提供公网可用性监控" 1 "$(grep -c '不提供公网可用性监控' "$R")"
assert_eq "README 说明 Public Endpoint 不配置 NAT" 1 "$(grep -c '不配置服务商的 NAT' "$R")"
assert_eq "README 不承诺 64 MiB 下 sing-box 稳定" 1 "$(grep -c '不代表 sing-box 在 64 MiB 内能长期稳定运行' "$R")"
for proto in AnyTLS Hysteria2 TUIC Shadowsocks; do
    assert_eq "README 使用原名 $proto" 1 "$([ "$(grep -c "$proto" "$R")" -ge 1 ] && echo 1 || echo 0)"
done
assert_eq "README 没有翻译协议名" 0 "$(grep -c '任意TLS\|歇斯底里\|影梭' "$R")"
t_done
