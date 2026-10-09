# shellcheck shell=sh
# Snell 网络功能端到端测试的公共函数, 由各场景脚本 source
# 使用真实的 Snell v6, 官方 sing-box 1.14.x 的 snell 出站作为客户端, 真实的 graftcp tinyproxy unbound
# 所有凭据都是虚构的占位符, 只在隔离环境里使用
#
# 环境变量
#   E2E_DIR       工作目录, 默认 /tmp/apm-e2e
#   E2E_HERE      本目录
#   SB_BIN        官方 sing-box 二进制 (>= 1.14.0)
#   E2E_PSK       Snell 的 PSK (虚构)

# shellcheck disable=SC2015,SC2016 # 测试脚本里 A && B || C 用来记录通过或失败
E2E_DIR=${E2E_DIR:-/tmp/apm-e2e}
E2E_HERE=${E2E_HERE:-$(cd "$(dirname "$0")" && pwd)}
E2E_PSK=${E2E_PSK:-FakePskNotSecret0123456789abcdefgh}
SNELL_PORT=${SNELL_PORT:-8388}
TLOG=$E2E_DIR/targets.log
DLOG=$E2E_DIR/dns.log
UPPASS=UpPassNotSecret0123456789
E2E_PASS=0
E2E_FAIL=0
E2E_PIDS=

mkdir -p "$E2E_DIR"

say() { printf '%s\n' "$*"; }
ok() { E2E_PASS=$((E2E_PASS + 1)); say "  通过: $1"; }
bad() { E2E_FAIL=$((E2E_FAIL + 1)); say "  失败: $1"; }
section() { say ""; say "== $1"; }

track() { E2E_PIDS="$E2E_PIDS $1"; }

# 只杀本脚本启动并记录过的进程
e2e_cleanup() {
    local _p
    for _p in $E2E_PIDS; do
        kill "$_p" 2>/dev/null
    done
    E2E_PIDS=
}

wait_file() { # 文件 最多等待 (0.1 秒的倍数)
    local _n=0
    while [ ! -e "$1" ] && [ "$_n" -lt "${2:-100}" ]; do sleep 0.1; _n=$((_n + 1)); done
    [ -e "$1" ]
}

# 原地改写 /etc/hosts: 容器里它是 bind mount, sed -i 的原子替换会失败
hosts_drop() { # 正则
    grep -v -- "$1" /etc/hosts > "$E2E_DIR/hosts.tmp"
    cat "$E2E_DIR/hosts.tmp" > /etc/hosts
}

tclear() { : > "$TLOG"; : > "$DLOG"; }
thits() { grep -c . "$TLOG" 2>/dev/null || true; }

# ---- 目标 ----

start_targets() { # ADDR,PORT ...
    rm -f "$TLOG.ready"
    : > "$TLOG"
    python3 -I "$E2E_HERE/targets.py" "$TLOG" "$@" &
    TGT_PID=$!
    track "$TGT_PID"
    wait_file "$TLOG.ready" || { say "目标服务没有启动"; return 1; }
}

stop_targets() { [ -z "${TGT_PID:-}" ] || kill "$TGT_PID" 2>/dev/null; TGT_PID=; sleep 0.3; }

start_dnsd() { # ADDR ANSWER
    rm -f "$DLOG.ready"
    : > "$DLOG"
    python3 -I "$E2E_HERE/dnsd.py" "$DLOG" "$1" "$2" &
    DNS_PID=$!
    track "$DNS_PID"
    wait_file "$DLOG.ready" || { say "DNS 服务没有启动"; return 1; }
}

# ---- 上游 SOCKS5 (sing-box) ----
# MODE permissive 出站绑定 127.0.0.77, 回环目标也会被它直连 (用来用对端地址证明流量走了上游)
#      rejectlocal 上游自己拒绝回环目标 (模拟远端上游, 目标零命中)
# 可选第 3 参数用户名: 启用密码认证
start_upstream() { # PORT MODE [USER]
    local _users _rules
    _users=
    [ -z "${3:-}" ] || _users="\"users\":[{\"username\":\"$3\",\"password\":\"$UPPASS\"}],"
    _rules=
    [ "$2" != rejectlocal ] || _rules='"rules":[{"ip_cidr":["127.0.0.0/8","::1/128"],"action":"reject"}],'
    cat > "$E2E_DIR/upstream.json" <<JEOF
{"log":{"level":"debug"},"inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":$1,$_users"sniff":false}],
 "outbounds":[{"type":"direct","tag":"direct","inet4_bind_address":"127.0.0.77"}],
 "route":{$_rules"final":"direct"}}
JEOF
    : > "$E2E_DIR/upstream.log"
    "$SB_BIN" run -c "$E2E_DIR/upstream.json" > "$E2E_DIR/upstream.log" 2>&1 &
    UP_PID=$!
    track "$UP_PID"
    wait_tcp 127.0.0.1 "$1" || { say "上游没有启动"; return 1; }
}

stop_upstream() { [ -z "${UP_PID:-}" ] || kill "$UP_PID" 2>/dev/null; UP_PID=; sleep 0.5; }

wait_tcp() { # 地址 端口
    local _n=0
    while [ "$_n" -lt 100 ]; do
        python3 -I -c "import socket,sys;socket.create_connection((sys.argv[1],int(sys.argv[2])),1).close()" "$1" "$2" 2>/dev/null && return 0
        _n=$((_n + 1)); sleep 0.1
    done
    return 1
}

# ---- 客户端 (官方 sing-box 的 Snell v6 出站) ----

# 进程数: comm 等于 NAME, 或 argv 里有一个元素的末段等于 NAME (gcompat 加载器会改写 Snell 的命令行)
pcount() { # NAME
    local _n _d _c
    _n=0
    for _d in /proc/[0-9]*; do
        [ "${_d#/proc/}" = "$$" ] && continue
        _c=$(cat "$_d/comm" 2>/dev/null)
        if [ "$_c" = "$1" ] || tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | sed 's|.*/||' | grep -Fxq -- "$1"; then
            _n=$((_n + 1))
        fi
    done
    echo "$_n"
}

start_client() {
    [ -z "${CL_PID:-}" ] || { kill "$CL_PID" 2>/dev/null; wait "$CL_PID" 2>/dev/null; CL_PID=; }
    cat > "$E2E_DIR/client.json" <<JEOF
{"log":{"level":"warn"},"inbounds":[{"type":"socks","tag":"in","listen":"127.0.0.1","listen_port":2080}],
 "outbounds":[{"type":"snell","tag":"sn","server":"127.0.0.1","server_port":$SNELL_PORT,"version":6,"psk":"$E2E_PSK","mode":"default"}],
 "route":{"final":"sn"}}
JEOF
    # 客户端看不到 /etc/hosts 里的测试映射: 域名要原样交给 Snell 解析, 不能在客户端先被解析掉
    : > "$E2E_DIR/empty-hosts"
    unshare -m /bin/sh -c 'mount --make-rprivate / && mount --bind "$1" /etc/hosts && exec "$2" run -c "$3"' _ "$E2E_DIR/empty-hosts" "$SB_BIN" "$E2E_DIR/client.json" > "$E2E_DIR/client.log" 2>&1 &
    CL_PID=$!
    track "$CL_PID"
    wait_tcp 127.0.0.1 2080 || { say "客户端没有启动"; cat "$E2E_DIR/client.log"; return 1; }
}

# Snell 重启后客户端的旧连接失效, 测试里重新建立客户端 (真实客户端会自动重连)
restart_client() { start_client; }

sc() { python3 -I "$E2E_HERE/sc.py" "$@"; }

# ---- 断言 ----

# 拒绝: 客户端失败, 并且目标零命中 (不能只看客户端的错误)
expect_denied() { # 说明 proto addr port
    local _o _h
    tclear
    _o=$(sc "$2" "$3" "$4")
    sleep 0.3
    _h=$(thits)
    case $_o in OK:*) bad "$1: 客户端得到了回应 ($_o)"; return 1 ;; esac
    if [ "${_h:-0}" -ne 0 ]; then bad "$1: 目标收到了 $_h 次命中: $(tr '\n' ';' < "$TLOG")"; return 1; fi
    ok "$1 (拒绝, 目标零命中)"
}

# 不得直连: 目标日志里不能有来自上游绑定地址 (127.0.0.77) 以外的对端, 客户端成功与否不论
expect_not_direct() { # 说明 proto addr port
    local _o
    tclear
    _o=$(sc "$2" "$3" "$4")
    sleep 0.3
    if grep -v 'peer=127\.0\.0\.77$' "$TLOG" | grep -q .; then bad "$1: 目标收到了非上游的连接: $(cat "$TLOG")"; return 1; fi
    ok "$1 (没有直连; 客户端结果 ${_o%%:*})"
}

# 放行: 客户端得到回应, 目标恰好命中一次, 对端地址符合预期 (正则)
expect_peer() { # 说明 proto addr port 对端正则
    local _o _h
    tclear
    _o=$(sc "$2" "$3" "$4")
    sleep 0.3
    _h=$(thits)
    case $_o in OK:*) ;; *) bad "$1: 客户端没有回应 ($_o)"; return 1 ;; esac
    if [ "${_h:-0}" -ne 1 ]; then bad "$1: 目标命中次数 $_h, 期望 1: $(tr '\n' ';' < "$TLOG")"; return 1; fi
    if ! grep -Eq "peer=($5)\$" "$TLOG"; then bad "$1: 对端地址不符: $(cat "$TLOG")"; return 1; fi
    ok "$1 (对端 $(sed 's/.*peer=//' "$TLOG"))"
}

e2e_finish() {
    e2e_cleanup
    say ""
    say "通过 $E2E_PASS 项, 失败 $E2E_FAIL 项"
    [ "$E2E_FAIL" -eq 0 ]
}
