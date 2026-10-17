# 测试用 SOCKS5 上游: 握手回复前延迟 DELAY 秒, 用来区分 拨号进行中 与 已建立 (无认证)
# 用法: slowsocks.py PORT DELAY
import socket, struct, sys, threading, time
port, delay = int(sys.argv[1]), float(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(16)
def rn(c, n):
    b = b""
    while len(b) < n:
        p = c.recv(n - len(b))
        if not p: raise EOFError
        b += p
    return b
def handle(c):
    try:
        h = c.recv(3)  # 05 01 00
        time.sleep(delay)
        c.sendall(b"\x05\x00")
        req = rn(c, 4)
        if req[3] == 1: a = rn(c, 4); host = socket.inet_ntoa(a)
        else: l = rn(c, 1)[0]; host = rn(c, l).decode()
        p = struct.unpack("!H", rn(c, 2))[0]
        t = socket.create_connection((host, p), timeout=5)
        c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        def pump(a, b):
            try:
                while True:
                    d = a.recv(4096)
                    if not d: break
                    b.sendall(d)
            except Exception: pass
            try: b.shutdown(socket.SHUT_WR)
            except Exception: pass
        threading.Thread(target=pump, args=(c, t), daemon=True).start()
        pump(t, c)
    except Exception: pass
    finally:
        try: c.close()
        except Exception: pass
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
