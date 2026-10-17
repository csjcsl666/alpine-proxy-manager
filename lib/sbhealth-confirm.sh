#!/bin/sh
# shellcheck shell=sh
# sing-box SOCKS5 上游恢复确认 (健康监控的方案 B), 由 lib/sbhealth.awk 在事件触发时启动, 不是常驻进程, 也不是定时任务
#
# 触发条件: 某个 Profile 处于 recovering (故障后出现了新的真实拨号, 尚未确认), 且同一个 Profile 没有正在进行的确认
# 做什么: 最多 4 次查询本机 sing-box 的 /connections (间隔 1 2 4 8 秒), 找出满足下面全部条件的连接
#   - 来源 IP 和端口等于触发时记录的待确认连接 (日志里的入站来源, 精确对应, 不是只看 Profile 标签)
#   - 链路里含这个 Profile 的出站标签
#   - download 字节数大于 0: 数据已经从目标经上游回传, 拨号未完成 认证失败 只有入站数据 都不会让它大于 0
#   - 建立时间不早于触发时记录的时间 (排除历史连接)
# 找到就向事件流回报 ok, 否则 4 次结束后回报 end. 永远不连接上游 SOCKS5 服务器, 也不修改 sing-box
# 查询失败 超时 守护进程退出都只是不回报或回报 end, 不影响代理转发; 状态保持 recovering 等待正常的连接结束事件
#
# 环境变量 (由守护进程设置, 不在命令行): SBH_DIR SBH_API_PORT SBH_API_SECRET SBH_FIFO
# 参数 1: Profile 标签 (apm-socks-名称)

tag=$1
dbg() { [ -z "${SBH_DEBUG:-}" ] || printf '%s %s\n' "$(date +%T)" "$*" >> "$SBH_DEBUG"; }
dbg "start $tag"
case $tag in apm-socks-*[!A-Za-z0-9._-]*|'') exit 2 ;; esac
dir=${SBH_DIR:?}
port=${SBH_API_PORT:?}
sec=${SBH_API_SECRET:?}
fifo=${SBH_FIFO:?}
req=$dir/confirm.$tag.req
statef=$dir/$tag.state
[ -f "$req" ] || exit 0

report() { # ok | end
    rm -f -- "$req"
    [ -p "$fifo" ] || return 0
    printf '@C %s %s\n' "$1" "$tag" | timeout 3 tee -- "$fifo" >/dev/null 2>&1
}


check() {
    awk -v tag="$tag" '
    function norm(s,    ip, p) {
        if (substr(s, 1, 1) == "[") { ip = substr(s, 2, index(s, "]") - 2); p = substr(s, index(s, "]:") + 2) }
        else { p = s; sub(/.*:/, "", p); ip = s; sub(/:[^:]*$/, "", ip) }
        return ip " " p
    }
    BEGIN {
        n = split(ENVIRON["REQ"], rl, "\n")
        for (i = 1; i <= n; i++) { split(rl[i], f, " "); want[norm(f[1])] = 1 }
        since = ENVIRON["SINCE"]
        inbody = 0
    }
    {
        sub(/\r$/, "")
        if (!inbody) { if ($0 == "") inbody = 1; next }
        # 分块传输: 单独成行的十六进制数是块大小
        if ($0 ~ /^[0-9a-fA-F]+$/) next
        body = body $0
    }
    END {
        # 分隔符是一个多字符串 split 会当成正则, 先换成单个控制字符
        gsub(/\{"chains":\[/, "\001", body)
        m = split(body, part, "\001")
        for (i = 2; i <= m; i++) {
            c = part[i]
            e = index(c, "]")
            if (e == 0) continue
            if (index(substr(c, 1, e), "\"" tag "\"") == 0) continue
            if (!match(c, /"download":[0-9]+/)) continue
            dl = substr(c, RSTART + 11, RLENGTH - 11) + 0
            if (dl <= 0) continue
            if (!match(c, /"sourceIP":"[^"]*"/)) continue
            ip = substr(c, RSTART + 12, RLENGTH - 13)
            if (!match(c, /"sourcePort":"[0-9]+"/)) continue
            sp = substr(c, RSTART + 14, RLENGTH - 15)
            if (!match(c, /"start":"[^"]*"/)) continue
            st = substr(c, RSTART + 9, 19)
            if (!((ip " " sp) in want)) continue
            if (st < since) continue
            print "hit"; exit
        }
    }'
}

for d in 1 2 4 8; do
    sleep "$d"
    [ -p "$fifo" ] || { rm -f -- "$req"; exit 0; }
    # 状态已经不是 recovering (别的连接已经结束确认了 或者又出现了新的故障) 就不再查询
    [ "$(sed -n 's/^state=//p' "$statef" 2>/dev/null)" = recovering ] || { report end; exit 0; }
    # 每一轮重新读取待确认的连接 (新出现的拨号会被追加进来); 最早的触发时间减 2 秒当作历史连接的分界
    [ -f "$req" ] || exit 0
    REQ=$(cat -- "$req" 2>/dev/null)
    # 状态机正好在重写请求文件时可能读到空文件, 稍等再读一次
    [ -n "$REQ" ] || { sleep 0.3; REQ=$(cat -- "$req" 2>/dev/null); }
    [ -n "$REQ" ] || { report end; exit 0; }
    first=$(printf '%s\n' "$REQ" | awk '{ print $2 }' | sort -n | head -n 1)
    case $first in ''|*[!0-9]*) report end; exit 0 ;; esac
    SINCE=$(date -u -d "@$((first - 2))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)
    [ -n "$SINCE" ] || { report end; exit 0; }
    export REQ SINCE
    dbg "query after ${d}s"
    hit=$(printf 'GET /connections HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n' "$sec" | timeout 5 nc 127.0.0.1 "$port" 2>/dev/null | head -c 1048576 | check)
    dbg "hit=$hit"
    if [ "$hit" = hit ]; then report ok; exit 0; fi
done
report end
exit 0
