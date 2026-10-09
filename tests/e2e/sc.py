# SOCKS5 测试客户端: 经本机 sing-box 客户端 (Snell v6 出站) 向目标发 TCP 或 UDP
# 用法: sc.py tcp|udp ADDR PORT   ADDR 可以是 IPv4, IPv6 或域名
# 输出一行 OK:<回应> 或 FAIL:<原因>
import socket, struct, sys

PROXY = ("127.0.0.1", 2080)
proto, addr, port = sys.argv[1], sys.argv[2], int(sys.argv[3])


def target_bytes():
    try:
        return b"\x01" + socket.inet_pton(socket.AF_INET, addr)
    except OSError:
        pass
    try:
        return b"\x04" + socket.inet_pton(socket.AF_INET6, addr)
    except OSError:
        pass
    n = addr.encode()
    return b"\x03" + bytes([len(n)]) + n


def recvn(s, n):
    b = b""
    while len(b) < n:
        p = s.recv(n - len(b))
        if not p:
            raise EOFError("连接被关闭")
        b += p
    return b


try:
    t = socket.create_connection(PROXY, timeout=8)
    t.sendall(b"\x05\x01\x00")
    recvn(t, 2)
    if proto == "tcp":
        t.sendall(b"\x05\x01\x00" + target_bytes() + struct.pack("!H", port))
        rep = recvn(t, 4)
        if rep[1] != 0:
            print("FAIL:socks reply %d" % rep[1])
            sys.exit(0)
        recvn(t, {1: 6, 4: 18}.get(rep[3], 0)) if rep[3] != 3 else recvn(t, recvn(t, 1)[0] + 2)
        t.settimeout(6)
        t.sendall(b"hello\n")
        d = t.recv(100)
        print("OK:" + d.decode().strip() if d else "FAIL:empty reply")
    else:
        t.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        rep = recvn(t, 10)
        if rep[1] != 0:
            print("FAIL:udp associate reply %d" % rep[1])
            sys.exit(0)
        bport = struct.unpack("!H", rep[8:10])[0]
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.settimeout(6)
        u.sendto(b"\x00\x00\x00" + target_bytes() + struct.pack("!H", port) + b"hello", ("127.0.0.1", bport))
        d, _ = u.recvfrom(700)
        # 去掉 SOCKS5 UDP 头
        atyp = d[3]
        off = 4 + (4 if atyp == 1 else 16 if atyp == 4 else 1 + d[4]) + 2
        print("OK:" + d[off:].decode().strip())
except Exception as e:
    print("FAIL:%s" % e)
