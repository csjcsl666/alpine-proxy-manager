# sing-box SOCKS5 上游健康状态机 (事件驱动)
# 输入 sing-box Clash API /logs 的 HTTP 流 (分块 JSON 行), 一行一个事件, 没有事件就阻塞在读上, 不会主动连接任何上游
# 只处理 outbound/socks[apm-socks-名称] 相关的三类真实事件:
#   尝试  INFO  [ID] outbound/socks[TAG]: outbound connection to ...
#   失败  ERROR [ID] connection: open connection to ... using outbound/socks[TAG]: 原因
#   完成  DEBUG [ID] connection: connection upload|download finished|closed   (只有拨号与握手成功的连接才会走到这里)
# 状态文件只保存状态 原因代码 时间戳, 不保存目标地址 域名 用户名 密码 或上游地址
#
# 环境变量 SBH_DIR 状态目录 (必需)  SBH_FAIL_WIN 连续失败的时间窗口秒数 默认 120  SBH_FAIL_N 判定为不可用所需的连续失败数 默认 2
# 自动故障切换 (默认关闭, 逐台授权): profiles 里带 fo 标记的 Profile 在状态机判定 unhealthy 后, 把它的 selector 切到 direct
#   之后只有真实请求 (路由日志里出现该 selector 的路由匹配) 才会触发一次有界的恢复探测, 没有请求就没有任何探测
#   探测 = sing-box 自己对该 SOCKS5 出站发起的完整请求 (握手 认证 CONNECT TLS HTTP), 成功才把 selector 切回 SOCKS5
#   SBH_FAILOVER 切换与探测脚本路径 SBH_HIST 最近一次故障与恢复时间的保存目录 (为空则不保存)
# 状态: unknown 尚无可靠证据  healthy 健康  degraded 单次可归因失败  unhealthy 不可用  recovering 故障后已有新连接在尝试 尚未确认

BEGIN {
    dir = ENVIRON["SBH_DIR"]
    if (dir == "") { print "SBH_DIR 未设置" > "/dev/stderr"; exit 2 }
    win = ENVIRON["SBH_FAIL_WIN"] + 0; if (win <= 0) win = 120
    need = ENVIRON["SBH_FAIL_N"] + 0; if (need <= 0) need = 2
    pcount = 0; seq = 0
    prefix = "apm-socks-"
    tclock = ENVIRON["SBH_TEST_CLOCK"]
    confirm = ENVIRON["SBH_CONFIRM"]   # 恢复确认脚本路径, 为空表示不启用 B
    inflight_ttl = 60
    cooldown = 20   # 一组查询结束后到下一组之间的最短间隔, 持续有新连接时也不会形成连续轮询
    fover = ENVIRON["SBH_FAILOVER"]
    hist = ENVIRON["SBH_HIST"]
    fo_first = 5      # 切到 direct 之后到第一次探测的最短间隔, 之后退避 5 10 20 ... 上限 300 秒
    fo_cap = 300
    pfile = dir "/profiles"
    refresh(1)
    # 目录里残留的状态是上一个监控进程留下的最近一次可靠判断, 保留它 (没有新业务流量时不改变判断); 被关闭监控的 Profile 的残留删除
    cmd = "ls '" dir "' 2>/dev/null"
    while ((cmd | getline lf) > 0) {
        if (lf ~ /^apm-socks-[A-Za-z0-9._-]+\.state$/) {
            tg0 = substr(lf, 1, length(lf) - 6)
            if (tg0 in poff && poff[tg0]) { system("rm -f -- '" dir "/" lf "'"); continue }
            load(tg0)
        }
    }
    close(cmd)
    # 监控 (重新) 启动时, 所有已授权自动切换的 Profile 先恢复为严格的 SOCKS5 (不依赖旧状态继续 DIRECT), 之后由真实故障事件重新触发
    if (fover != "") for (tg0 in pfo) if (pfo[tg0]) system("sh '" fover "' reset '" tg0 "' >/dev/null 2>&1")
}

# ---- 每个 Profile 的监控开关 ----
# 守护进程的运行目录里有一个 profiles 文件, 每行 名称 on|off 版本号 (由 proxy-manager 写入, 没有这一行的 Profile 默认开启)
# 状态机在处理事件时顺便重读它 (同一秒内只读一次, 不使用计时器); 版本号变化 (关闭 重新开启) 就丢弃该 Profile 在内存里的全部状态
function refresh(first,    l, a, n, tg, nr, no, nf, f) {
    if (!first && pread && pstamp == now()) return
    pread = 1; pstamp = now()
    f = pfile
    while ((getline l < f) > 0) {
        n = split(l, a, " ")
        if (n < 3 || a[1] !~ /^[A-Za-z0-9._-]+$/) continue
        tg = prefix a[1]
        no[tg] = (a[2] == "off"); nr[tg] = a[3] + 0; nf[tg] = (n >= 4 && a[4] == "fo")
    }
    close(f)
    if (!first) {
        for (tg in nr) if (!(tg in prev) || prev[tg] != nr[tg]) forget(tg)
        for (tg in prev) if (!(tg in nr)) forget(tg)
    }
    delete prev; delete poff; delete pfo
    for (tg in nr) { prev[tg] = nr[tg]; poff[tg] = no[tg]; pfo[tg] = nf[tg] }
}

# 丢弃一个 Profile 的全部内存状态与状态文件: 关闭时不再展示旧结果, 重新开启时从未知开始, 不复用过期的健康
function forget(tag,    id) {
    # 正在临时 DIRECT 的 Profile 被取消授权或移出监控: 立刻恢复严格的 SOCKS5, 不依赖旧的故障状态
    if (fover != "" && foact[tag]) system("sh '" fover "' reset '" tag "' >/dev/null 2>&1 &")
    delete known[tag]; delete st[tag]; delete reason[tag]; delete lastok[tag]; delete lastfail[tag]
    delete lastreason[tag]; delete streak[tag]; delete firstfail[tag]; delete since[tag]; delete dirty[tag]
    delete inflight[tag]; delete cooled[tag]; delete lastsave[tag]
    delete foact[tag]; delete foinfl[tag]; delete fo_n[tag]; delete fo_next[tag]
    for (id in ptag) if (ptag[id] == tag) { delete ptag[id]; delete pseq[id]; delete ptime[id]; pcount-- }
    system("rm -f -- '" dir "/" tag ".state'")
}

function monitored(tag) {
    refresh(0)
    return !(tag in poff && poff[tag])
}

function now() { return (tclock != "") ? fake : systime() }

# 状态文件首次出现时载入历史时间戳, 状态本身从 unknown 开始 (sing-box 重启或监控重连后旧状态已无证据)
function load(tag,    f, l, k, v) {
    if (tag in known) return
    known[tag] = 1
    st[tag] = "unknown"; reason[tag] = ""; lastok[tag] = 0; lastfail[tag] = 0; streak[tag] = 0; firstfail[tag] = 0; since[tag] = now()
    hfault[tag] = 0; hrec[tag] = 0
    f = dir "/" tag ".state"
    while ((getline l < f) > 0) {
        k = substr(l, 1, index(l, "=") - 1); v = substr(l, index(l, "=") + 1)
        if (k == "last_ok") lastok[tag] = v + 0
        else if (k == "last_fail") lastfail[tag] = v + 0
        else if (k == "last_fail_reason") lastreason[tag] = v
        else if (k == "state") { if (v == "recovering") v = "unhealthy"; if (v ~ /^(unknown|healthy|degraded|unhealthy)$/) st[tag] = v }
        else if (k == "reason") reason[tag] = v
        else if (k == "streak") streak[tag] = v + 0
        else if (k == "since") since[tag] = v + 0
    }
    close(f)
    if (hist != "") {
        f = hist "/" substr(tag, 11) ".hist"
        while ((getline l < f) > 0) {
            k = substr(l, 1, index(l, "=") - 1); v = substr(l, index(l, "=") + 1)
            if (k == "last_fault") hfault[tag] = v + 0
            else if (k == "last_recover") hrec[tag] = v + 0
        }
        close(f)
    }
}

# 每个 Profile 最近一次故障与恢复的时间, 只在状态真正变化时更新, 原子替换 (临时文件加 mv)
function hist_save(tag,    f, tmp) {
    if (hist == "") return
    f = hist "/" substr(tag, 11) ".hist"
    tmp = f ".new"
    # 经 shell 写入: 目录缺失或不可写只会让这次历史丢失, 不会让状态机因重定向失败而退出
    system("{ printf 'version=1\\nlast_fault=%d\\nlast_recover=%d\\n' " (hfault[tag] + 0) " " (hrec[tag] + 0) " > '" tmp "' && mv -f -- '" tmp "' '" f "'; } 2>/dev/null")
}

function save(tag,    f) {
    f = dir "/" tag ".state"
    printf "version=1\nstate=%s\nreason=%s\nsince=%d\nlast_ok=%d\nlast_fail=%d\nlast_fail_reason=%s\nstreak=%d\nupdated=%d\nfailover=%s\nexit=%s\n", \
        st[tag], reason[tag], since[tag], lastok[tag], lastfail[tag], lastreason[tag], streak[tag], now(), ((tag in pfo) && pfo[tag]) ? "on" : "off", foact[tag] ? "direct" : "socks" > f
    close(f)
    dirty[tag] = 0; lastsave[tag] = now()
}

function setst(tag, s, r) {
    # 新的故障周期从头开始: 冷却只用于同一个恢复周期内, 进入 unhealthy 或回到 healthy 都清除
    if (s == "unhealthy" || s == "healthy") delete cooled[tag]
    if (st[tag] != s) since[tag] = now()
    st[tag] = s; reason[tag] = r
    save(tag)
}

# 入站日志里的来源地址, 用来把日志里的连接编号和 Clash API 的 /connections 条目精确对应 (入站日志先于出站日志)
function note_src(id, s,    p) {
    if (!(id in srcof)) { scount++; if (scount > 8192) { delete srcof; scount = 0 } }
    srcof[id] = s
}

function addpending(id, tag) {
    if (!(id in ptag)) {
        pcount++
        pseq[id] = ++seq
        ptime[id] = now()
    }
    ptag[id] = tag
    # 长连接可能一直不结束 限制记录数, 超出就丢弃最旧的一半
    if (pcount > 4096) trim()
}

function trim(    id, cut, n) {
    cut = seq - 2048
    for (id in ptag) {
        if (pseq[id] <= cut) { delete ptag[id]; delete pseq[id]; delete ptime[id]; pcount-- }
    }
}

function dropid(id) {
    if (id in ptag) { delete ptag[id]; delete pseq[id]; delete ptime[id]; pcount-- }
}

# 尝试: 只有 unhealthy 才进入 recovering, degraded 是单次失败 不显示为恢复中
function on_attempt(id, tag) {
    load(tag)
    addpending(id, tag)
    if (st[tag] == "unhealthy") setst(tag, "recovering", reason[tag])
    if (st[tag] == "recovering") maybe_confirm(tag)
}

# 恢复确认 (方案 B): 只有 Profile 处于 recovering 且出现了新的真实拨号, 才启动一组有界的本机 /connections 查询
# 同一个 Profile 同一时间最多一组 (inflight), 待确认的是该 Profile 最近的未结束连接的来源地址 最多 16 个
function maybe_confirm(tag,    id, n, f, i, k, cnt, order, ids, rank) {
    if (confirm == "") return
    if ((tag in cooled) && now() - cooled[tag] < cooldown) return
    f = dir "/confirm." tag ".req"
    cnt = 0
    for (id in ptag) if (ptag[id] == tag && (id in srcof)) { cnt++; order[cnt] = pseq[id]; ids[cnt] = id }
    if (cnt == 0) return
    # 取最新的 16 个
    n = 0
    for (k = 1; k <= cnt; k++) { n = 0; for (i = 1; i <= cnt; i++) if (order[i] > order[k]) n++; rank[k] = n }
    printf "" > f
    for (k = 1; k <= cnt; k++) if (rank[k] < 16) print srcof[ids[k]] " " ptime[ids[k]] >> f
    close(f)
    # 请求文件每次都更新 (正在进行的那一组会在下一轮读到新的待确认连接), 但同一个 Profile 同一时间只启动一组
    if ((tag in inflight) && now() - inflight[tag] < inflight_ttl) return
    inflight[tag] = now()
    system("sh '" confirm "' '" tag "' >/dev/null 2>&1 &")
}

# 成功证据: 拨号与 SOCKS5 握手完成 (连接已建立) 或上游自己回复了目标侧错误 (上游在线并通过认证)
function on_ok(tag,    was) {
    load(tag)
    was = st[tag]
    lastok[tag] = now(); streak[tag] = 0; firstfail[tag] = 0
    if (was == "unhealthy" || was == "recovering") { hrec[tag] = now(); hist_save(tag) }
    if (st[tag] != "healthy") setst(tag, "healthy", "")
    else if (now() - lastsave[tag] >= 2) save(tag)
    else dirty[tag] = 1
}

# 可归因于上游的失败
function on_fail(tag, code,    t, was) {
    load(tag)
    was = st[tag]
    t = now()
    lastfail[tag] = t; lastreason[tag] = code
    if (firstfail[tag] == 0 || t - firstfail[tag] > win) { firstfail[tag] = t; streak[tag] = 0 }
    streak[tag]++
    if (code == "auth" || st[tag] == "unhealthy" || st[tag] == "recovering" || streak[tag] >= need) {
        if (was != "unhealthy" && was != "recovering") { hfault[tag] = t; hist_save(tag) }
        setst(tag, "unhealthy", code)
        maybe_failover(tag)
    } else setst(tag, "degraded", code)
}

# ---- 自动故障切换 ----
# 已授权的 Profile 判定为不可用后把 selector 切到 direct (新连接立刻改道, 已建立的连接不迁移); 只有真实请求才触发有界的恢复探测
function maybe_failover(tag) {
    if (fover == "" || !(tag in pfo) || !pfo[tag] || foact[tag]) return
    if (st[tag] != "unhealthy") return
    foact[tag] = 1; fo_n[tag] = 0; fo_next[tag] = now() + fo_first; foinfl[tag] = 0
    system("sh '" fover "' switch '" tag "' >/dev/null 2>&1 &")
    save(tag)
}

# 真实请求 (路由日志里出现了该 Profile 的 selector) 触发一次探测: 同一个 Profile 同一时间最多一个, 退避 5 10 20 ... 300 秒, 没有请求就不探测
function maybe_probe(tag,    b, i) {
    if (fover == "" || !foact[tag] || foinfl[tag]) return
    if (now() < fo_next[tag]) return
    b = fo_first
    for (i = 0; i < fo_n[tag]; i++) { b = b * 2; if (b >= fo_cap) { b = fo_cap; break } }
    fo_n[tag]++
    fo_next[tag] = now() + b
    foinfl[tag] = 1
    system("sh '" fover "' probe '" tag "' >/dev/null 2>&1 &")
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

function handle(line,    pl, id, tag, rest, p, q, txt, c, ty, kind) {
    pl = payload_of(line)
    if (pl == "" || substr(pl, 1, 1) != "[") return
    p = index(pl, " ")
    id = substr(pl, 2, p - 2)
    if (id !~ /^[0-9]+$/) return
    q = index(pl, "] ")
    if (q == 0) return
    rest = substr(pl, q + 2)
    if (rest ~ /^inbound\/[a-z0-9-]+\[[^]]*\]: inbound connection from /) {
        p = index(rest, " connection from ")
        note_src(id, substr(rest, p + 17))
        sub(/"\}$/, "", srcof[id])
        return
    }
    if (rest ~ /^outbound\/socks\[/) {
        tag = substr(rest, 16)
        tag = substr(tag, 1, index(tag, "]") - 1)
        if (tag !~ /^apm-socks-[A-Za-z0-9._-]+$/) return
        if (!monitored(tag)) return
        if (rest ~ /\]: outbound (packet )?connection to /) on_attempt(id, tag)
        return
    }
    if (rest ~ /^router: match\[[0-9]+\] / && match(rest, /route\(apm-sel-[A-Za-z0-9._-]+\)/)) {
        tag = "apm-socks-" substr(rest, RSTART + 14, RLENGTH - 15)
        if (monitored(tag)) maybe_probe(tag)
        return
    }
    if (rest ~ /^connection: open (packet )?connection to /) {
        p = index(rest, " using outbound/")
        if (p == 0) return
        tag = substr(rest, p + 16)
        # 1.13 的错误行标注实际使用的出站 (socks 或 direct), 1.14 标注 selector, 所以两种都要认
        kind = ""
        if (tag ~ /^socks\[/) { kind = "socks"; tag = substr(tag, 7) }
        else if (tag ~ /^selector\[/) { kind = "selector"; tag = substr(tag, 10) }
        else return
        q = index(tag, "]: ")
        if (q == 0) return
        txt = substr(tag, q + 3)
        tag = substr(tag, 1, q - 1)
        if (kind == "selector") {
            if (tag !~ /^apm-sel-[A-Za-z0-9._-]+$/) return
            tag = "apm-socks-" substr(tag, 9)
            # 已经切到 direct: selector 下的失败是直连目标的失败, 与 SOCKS5 上游无关
            if (foact[tag]) return
        } else if (tag !~ /^apm-socks-[A-Za-z0-9._-]+$/) return
        if (!monitored(tag)) return
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

# 恢复确认脚本的回报 (经同一个 FIFO 写入): ok 找到了该 Profile 上已回传数据的连接, end 这一组查询结束
/^@C (ok|end) / {
    tg = $3
    if (tg ~ /^apm-socks-[A-Za-z0-9._-]+$/ && (tg in known) && monitored(tg)) {
        delete inflight[tg]; cooled[tg] = now()
        if ($2 == "ok" && st[tg] == "recovering") on_ok(tg)
    }
    next
}

# 切换与探测脚本的回报: ok 探测成功且 selector 已切回 SOCKS5, fail 探测失败 (继续 DIRECT), swfail 切到 direct 没有成功 (仍是 SOCKS5, 下次故障再试)
/^@F (ok|fail|swfail) / {
    tg = $3
    if (tg ~ /^apm-socks-[A-Za-z0-9._-]+$/ && (tg in known) && monitored(tg)) {
        foinfl[tg] = 0
        if ($2 == "ok") { foact[tg] = 0; fo_n[tg] = 0; on_ok(tg) }
        else if ($2 == "swfail") { foact[tg] = 0; save(tg) }
    }
    next
}

# 测试用: 在流里改写 profiles 文件 (模拟 proxy-manager 在运行中切换开关)
tclock != "" && /^@PC$/ { printf "" > pfile; close(pfile); next }
tclock != "" && /^@P / { printf "%s\n", substr($0, 4) >> pfile; close(pfile); next }
tclock != "" && /^@S / { for (tg in known) system("cp '" dir "/" tg ".state' '" dir "/" tg ".snap." $2 "'"); next }

/^\{"type":"/ { handle($0) }

# 到期的合并写入: 下一个事件到来时顺便落盘, 不使用计时器
{ for (t in dirty) if (dirty[t] && now() - lastsave[t] >= 2) save(t) }

END {
    # 订阅结束 (sing-box 停止 重启 或监控退出): 没有新证据, 最近一次可靠判断原样保留 (显示层会因为监控没有运行而提示监控异常)
    # last_state 字段只给测试和诊断用
    for (t in known) {
        f = dir "/" t ".state"
        printf "version=1\nstate=%s\nreason=%s\nsince=%d\nlast_ok=%d\nlast_fail=%d\nlast_fail_reason=%s\nstreak=%d\nupdated=%d\nfailover=%s\nexit=socks\nlast_state=%s\n", \
            st[t], reason[t], since[t], lastok[t], lastfail[t], lastreason[t], streak[t], now(), ((t in pfo) && pfo[t]) ? "on" : "off", st[t] > f
        close(f)
        # 仍然切在 direct 的 selector: 没有监控就没有恢复手段, 恢复为严格的 SOCKS5 (监控只是被停止, sing-box 还在运行时有效)
        if (fover != "" && foact[t]) system("sh '" fover "' reset '" t "' >/dev/null 2>&1")
    }
    system("rm -f -- '" dir "/connected'")
}
