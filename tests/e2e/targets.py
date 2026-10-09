# 受控测试目标: 每个 ADDR,PORT 同时监听 TCP 与 UDP, 把每一次命中的目标与对端地址写进日志
# 拒绝场景用日志是否为空证明目标没有收到任何连接, 不依赖客户端的错误信息
# 用法: targets.py LOG ADDR,PORT [ADDR,PORT ...]   (ADDR 可以是 IPv6, 0.0.0.0 与 :: 是通配地址)
import socket, sys, threading

LOG = sys.argv[1]
lock = threading.Lock()


def log(msg):
    with lock:
        with open(LOG, "a") as f:
            f.write(msg + "\n")


def fam(addr):
    return socket.AF_INET6 if ":" in addr else socket.AF_INET


def tcp(addr, port):
    s = socket.socket(fam(addr))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if fam(addr) == socket.AF_INET6:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind((addr, port))
    s.listen(64)
    while True:
        c, a = s.accept()
        log("TCP to=%s:%d peer=%s" % (addr, port, a[0]))

        def h(c=c):
            try:
                c.settimeout(5)
                c.recv(200)
                c.sendall(b"TARGET_OK\n")
            except Exception:
                pass
            c.close()

        threading.Thread(target=h, daemon=True).start()


def udp(addr, port):
    s = socket.socket(fam(addr), socket.SOCK_DGRAM)
    if fam(addr) == socket.AF_INET6:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind((addr, port))
    while True:
        d, a = s.recvfrom(600)
        log("UDP to=%s:%d peer=%s" % (addr, port, a[0]))
        s.sendto(b"UDP_OK " + d, a)


for spec in sys.argv[2:]:
    addr, port = spec.rsplit(",", 1)
    for fn in (tcp, udp):
        threading.Thread(target=fn, args=(addr, int(port)), daemon=True).start()
open(LOG + ".ready", "w").close()
threading.Event().wait()
