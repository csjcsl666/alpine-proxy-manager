# TLS 中继: 读取客户端的第一个 TLS ClientHello, 把里面真实发送的 SNI 记录下来, 然后原样转发给服务端
# 用来证明客户端导出的 TLS 服务名真的出现在线路上 (不是只信配置文件), 不解密也不修改任何内容
# 用法: sni_relay.py 监听端口 目标端口 日志文件   每个连接在日志里追加一行 SNI=<名称> 或 SNI=none
import socket, struct, sys, threading

listen_port, target_port, logf = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
lk = threading.Lock()


def sni_of(data):
    # 记录层 5 字节, 握手头 4 字节, 然后是 ClientHello
    try:
        if len(data) < 9 or data[0] != 0x16 or data[5] != 0x01:
            return "notls"
        p = 9 + 2 + 32
        p += 1 + data[p]
        p += 2 + struct.unpack("!H", data[p:p + 2])[0]
        p += 1 + data[p]
        end = p + 2 + struct.unpack("!H", data[p:p + 2])[0]
        p += 2
        while p + 4 <= end:
            t, n = struct.unpack("!HH", data[p:p + 4])
            p += 4
            if t == 0:
                # server_name_list: 长度 2, 类型 1, 名称长度 2, 名称
                ln = struct.unpack("!H", data[p + 3:p + 5])[0]
                return data[p + 5:p + 5 + ln].decode("ascii", "replace")
            p += n
        return "none"
    except Exception:
        return "parse-error"


def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except Exception:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass


def handle(c):
    try:
        first = c.recv(65536)
        if not first:
            c.close()
            return
        with lk:
            with open(logf, "a") as f:
                f.write("SNI=%s\n" % sni_of(first))
        s = socket.create_connection(("127.0.0.1", target_port), timeout=5)
        s.sendall(first)
        threading.Thread(target=pump, args=(s, c), daemon=True).start()
        pump(c, s)
    except Exception:
        try:
            c.close()
        except Exception:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", listen_port))
srv.listen(64)
open(logf + ".ready", "w").close()
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
