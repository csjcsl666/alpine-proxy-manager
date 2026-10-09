# 受控 DNS 服务器: *.apm-lab.example 的 A 记录是 ANSWER, 其他名字 NXDOMAIN, AAAA 返回空答案
# 每个查询的对端地址写进日志, 用来证明解析请求经过了 SOCKS5 上游而不是本机直接发出
# 用法: dnsd.py LOG ADDR ANSWER
import socket, struct, sys, threading

LOG, ADDR, ANSWER = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()


def log(msg):
    with lock:
        with open(LOG, "a") as f:
            f.write(msg + "\n")


def parse_name(p, off):
    labels = []
    while p[off]:
        n = p[off]
        labels.append(p[off + 1:off + 1 + n].decode())
        off += n + 1
    return ".".join(labels), off + 1


def answer(q, proto, peer):
    name, off = parse_name(q, 12)
    qtype = struct.unpack("!H", q[off:off + 2])[0]
    qend = off + 4
    log("DNS %s peer=%s name=%s type=%d" % (proto, peer, name, qtype))
    hdr = q[:2]
    question = q[12:qend]
    if name.endswith(".apm-lab.example") and qtype == 1:
        flags = 0x8180
        rr = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(ANSWER)
        return hdr + struct.pack("!HHHHH", flags, 1, 1, 0, 0) + question + rr
    if name.endswith(".apm-lab.example"):
        return hdr + struct.pack("!HHHHH", 0x8180, 1, 0, 0, 0) + question
    return hdr + struct.pack("!HHHHH", 0x8183, 1, 0, 0, 0) + question


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((ADDR, 53))
    while True:
        d, a = s.recvfrom(600)
        try:
            s.sendto(answer(d, "udp", a[0]), a)
        except Exception:
            pass


def tcp():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ADDR, 53))
    s.listen(16)
    while True:
        c, a = s.accept()

        def h(c=c, a=a):
            try:
                c.settimeout(5)
                while True:
                    ln = c.recv(2)
                    if len(ln) < 2:
                        break
                    n = struct.unpack("!H", ln)[0]
                    q = b""
                    while len(q) < n:
                        part = c.recv(n - len(q))
                        if not part:
                            return
                        q += part
                    r = answer(q, "tcp", a[0])
                    c.sendall(struct.pack("!H", len(r)) + r)
            except Exception:
                pass
            c.close()

        threading.Thread(target=h, daemon=True).start()


threading.Thread(target=udp, daemon=True).start()
threading.Thread(target=tcp, daemon=True).start()
open(LOG + ".ready", "w").close()
threading.Event().wait()
