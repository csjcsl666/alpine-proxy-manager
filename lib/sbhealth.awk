# sing-box SOCKS5 上游健康状态机 (事件驱动)
# 输入 sing-box Clash API /logs 的 HTTP 流 (分块 JSON 行), 一行一个事件, 没有事件就阻塞在读上, 不会主动连接任何上游
# 只处理 outbound/socks[apm-socks-名称] 相关的三类真实事件:
#   尝试  INFO  [ID] outbound/socks[TAG]: outbound connection to ...
#   失败  ERROR [ID] connection: open connection to ... using outbound/socks[TAG]: 原因
#   完成  DEBUG [ID] connection: connection upload|download finished|closed   (只有拨号与握手成功的连接才会走到这里)
# 状态文件只保存状态 原因代码 时间戳, 不保存目标地址 域名 用户名 密码 或上游地址
#
# 环境变量 SBH_DIR 状态目录 (必需)  SBH_FAIL_WIN 连续失败的时间窗口秒数 默认 120  SBH_FAIL_N 判定为不可用所需的连续失败数 默认 2
# 状态: unknown 尚无可靠证据  healthy 健康  degraded 单次可归因失败  unhealthy 不可用  recovering 故障后已有新连接在尝试 尚未确认

BEGIN {
    dir = ENVIRON["SBH_DIR"]
    if (dir == "") { print "SBH_DIR 未设置" > "/dev/stderr"; exit 2 }
    win = ENVIRON["SBH_FAIL_WIN"] + 0; if (win <= 0) win = 120
    need = ENVIRON["SBH_FAIL_N"] + 0; if (need <= 0) need = 2
    pcount = 0; seq = 0
    prefix = "apm-socks-"
    tclock = ENVIRON["SBH_TEST_CLOCK"]
}

function now() { return (tclock != "") ? fake : systime() }

# 状态文件首次出现时载入历史时间戳, 状态本身从 unknown 开始 (sing-box 重启或监控重连后旧状态已无证据)
function load(tag,    f, l, k, v) {
    if (tag in known) return
    known[tag] = 1
    st[tag] = "unknown"; reason[tag] = ""; lastok[tag] = 0; lastfail[tag] = 0; streak[tag] = 0; firstfail[tag] = 0; since[tag] = now()
    f = dir "/" tag ".state"
    while ((getline l < f) > 0) {
        k = substr(l, 1, index(l, "=") - 1); v = substr(l, index(l, "=") + 1)
        if (k == "last_ok") lastok[tag] = v + 0
        else if (k == "last_fail") lastfail[tag] = v + 0
        else if (k == "last_fail_reason") lastreason[tag] = v
    }
    close(f)
}

function save(tag,    f) {
    f = dir "/" tag ".state"
    printf "version=1\nstate=%s\nreason=%s\nsince=%d\nlast_ok=%d\nlast_fail=%d\nlast_fail_reason=%s\nstreak=%d\nupdated=%d\n", \
        st[tag], reason[tag], since[tag], lastok[tag], lastfail[tag], lastreason[tag], streak[tag], now() > f
    close(f)
    dirty[tag] = 0; lastsave[tag] = now()
}

function setst(tag, s, r) {
    if (st[tag] != s) since[tag] = now()
    st[tag] = s; reason[tag] = r
    save(tag)
}

function addpending(id, tag) {
    if (!(id in ptag)) {
        pcount++
        pseq[id] = ++seq
    }
    ptag[id] = tag
    # 长连接可能一直不结束 限制记录数, 超出就丢弃最旧的一半
    if (pcount > 4096) trim()
}

function trim(    id, cut, n) {
    cut = seq - 2048
    for (id in ptag) {
        if (pseq[id] <= cut) { delete ptag[id]; delete pseq[id]; pcount-- }
    }
}

function dropid(id) {
    if (id in ptag) { delete ptag[id]; delete pseq[id]; pcount-- }
}

# 尝试: 只有 unhealthy 才进入 recovering, degraded 是单次失败 不显示为恢复中
function on_attempt(id, tag) {
    load(tag)
    addpending(id, tag)
    if (st[tag] == "unhealthy") setst(tag, "recovering", reason[tag])
}

# 成功证据: 拨号与 SOCKS5 握手完成 (连接已建立) 或上游自己回复了目标侧错误 (上游在线并通过认证)
function on_ok(tag) {
    load(tag)
    lastok[tag] = now(); streak[tag] = 0; firstfail[tag] = 0
    if (st[tag] != "healthy") setst(tag, "healthy", "")
    else if (now() - lastsave[tag] >= 2) save(tag)
    else dirty[tag] = 1
}

# 可归因于上游的失败
function on_fail(tag, code,    t) {
    load(tag)
    t = now()
    lastfail[tag] = t; lastreason[tag] = code
    if (firstfail[tag] == 0 || t - firstfail[tag] > win) { firstfail[tag] = t; streak[tag] = 0 }
    streak[tag]++
    if (code == "auth" || st[tag] == "unhealthy" || st[tag] == "recovering" || streak[tag] >= need) setst(tag, "unhealthy", code)
    else setst(tag, "degraded", code)
}

# 把 sing-box 的错误文本归类, 只返回固定的代码, 不保存原文. ok 表示上游已回复 neutral 表示与上游健康无关或无法判断
function classify(txt) {
    if (txt ~ /incorrect user name or password|authentication (failed|error|rejected)|auth(entication)? .*(fail|reject)/) return "auth"
    if (txt ~ /^socks5: request rejected, code=[2-6]$/) return "ok"
    if (txt ~ /^socks5: request rejected/) return "neutral"
    if (txt ~ /context canceled|use of closed network connection/) return "neutral"
    if (txt ~ /connection refused/) return "refused"
    if (txt ~ /network is unreachable|no route to host|host is unreachable/) return "unreachable"
    if (txt ~ /i\/o timeout|timed out|deadline exceeded/) return "timeout"
    if (txt ~ /no such host|server misbehaving|lookup .*: /) return "dns"
    if (txt ~ /^socks5: |^dial tcp |: EOF$|^EOF$|connection reset|broken pipe/) return "protocol"
    return "neutral"
}

function payload_of(line,    p) {
    p = index(line, "\"payload\":\"")
    if (p == 0) return ""
    return substr(line, p + 11)
}

function handle(line,    pl, id, tag, rest, p, q, txt, c, ty) {
    pl = payload_of(line)
    if (pl == "" || substr(pl, 1, 1) != "[") return
    p = index(pl, " ")
    id = substr(pl, 2, p - 2)
    if (id !~ /^[0-9]+$/) return
    q = index(pl, "] ")
    if (q == 0) return
    rest = substr(pl, q + 2)
    if (rest ~ /^outbound\/socks\[/) {
        tag = substr(rest, 16)
        tag = substr(tag, 1, index(tag, "]") - 1)
        if (tag !~ /^apm-socks-[A-Za-z0-9._-]+$/) return
        if (rest ~ /\]: outbound (packet )?connection to /) on_attempt(id, tag)
        return
    }
    if (rest ~ /^connection: open (packet )?connection to /) {
        p = index(rest, " using outbound/socks[")
        if (p == 0) return
        tag = substr(rest, p + 22)
        q = index(tag, "]: ")
        if (q == 0) return
        txt = substr(tag, q + 3)
        tag = substr(tag, 1, q - 1)
        if (tag !~ /^apm-socks-[A-Za-z0-9._-]+$/) return
        # 去掉 JSON 结尾的 "} 与转义
        sub(/"\}$/, "", txt)
        dropid(id)
        c = classify(txt)
        if (c == "ok") on_ok(tag)
        else if (c != "neutral") on_fail(tag, c)
        return
    }
    if (rest ~ /^connection: (connection|packet connection) (upload|download) (finished|closed)/ || rest ~ /^connection: packet connection (finished|closed)/) {
        if (id in ptag) { tag = ptag[id]; dropid(id); on_ok(tag) }
        return
    }
}

# HTTP 响应头: 200 才算订阅成功, 其他状态码 (401 密钥错误等) 直接退出让守护进程报告
NR == 1 {
    if ($0 !~ /^HTTP\/1\.[01] 200/) { print "订阅失败: " $0 > "/dev/stderr"; exit 3 }
    f = dir "/connected"; printf "%d\n", now() > f; close(f)
    next
}

tclock != "" && /^@T / { fake = $2 + 0; next }
tclock != "" && /^@S / { for (tg in known) system("cp '" dir "/" tg ".state' '" dir "/" tg ".snap." $2 "'"); next }

/^\{"type":"/ { handle($0) }

# 到期的合并写入: 下一个事件到来时顺便落盘, 不使用计时器
{ for (t in dirty) if (dirty[t] && now() - lastsave[t] >= 2) save(t) }

END {
    # 订阅结束 (sing-box 停止 重启 或监控退出): 之后没有证据, 所有 Profile 回到 unknown, 保留最后一次的时间戳
    for (t in known) {
        prev[t] = st[t]
        if (st[t] != "unknown") { since[t] = now(); st[t] = "unknown"; reason[t] = "monitor-down" }
        f = dir "/" t ".state"
        printf "version=1\nstate=unknown\nreason=%s\nsince=%d\nlast_ok=%d\nlast_fail=%d\nlast_fail_reason=%s\nstreak=%d\nupdated=%d\nlast_state=%s\n", \
            reason[t], since[t], lastok[t], lastfail[t], lastreason[t], streak[t], now(), prev[t] > f
        close(f)
    }
    system("rm -f -- '" dir "/connected'")
}
