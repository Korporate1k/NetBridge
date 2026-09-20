#!/usr/bin/env python3
"""SOCKS5 UDP ASSOCIATE must advertise the address the client actually reached the server on.

For every local address of this machine (plus loopback, plus ::1 if the server listens on IPv6) connect to the proxy on that
address, do UDP ASSOCIATE, and assert BND.ADDR == the address connected to. Then send a datagram to the ADVERTISED address:port
(not an override) and require the echo back. Usage: PROXY_PORT=18080 udp_advertised.py"""
import os, socket, struct, subprocess, sys, threading

PORT = int(os.environ.get("PROXY_PORT", "18080"))
fails = 0


def check(name, ok, detail=""):
    global fails
    fails += 0 if ok else 1
    print(("PASS" if ok else "FAIL"), "-", name, ("| " + detail) if detail else "", flush=True)


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def local_v4():
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    addrs = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet ") and not line.startswith("inet6"):
            a = line.split()[1]
            # 169.254/16 is link-local; 198.18/15 is the Client VPN's own tunnel (a connect there hits the VPN, not the server).
            if not a.startswith(("169.254.", "198.18.", "198.19.")):
                addrs.append(a)
    return sorted(set(addrs))


def echo_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))

    def loop():
        while True:
            try:
                d, a = s.recvfrom(65535)
                s.sendto(d, a)
            except OSError:
                return
    threading.Thread(target=loop, daemon=True).start()
    return s


def associate(family, addr):
    c = socket.socket(family, socket.SOCK_STREAM)
    c.settimeout(5)
    c.connect((addr, PORT))
    c.sendall(b"\x05\x01\x00")
    assert recvn(c, 2) == b"\x05\x00"
    if family == socket.AF_INET:
        c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    else:
        c.sendall(b"\x05\x03\x00\x04" + b"\x00" * 16 + b"\x00\x00")
    ver, rep, _, atyp = struct.unpack("!BBBB", recvn(c, 4))
    if atyp == 1:
        host = socket.inet_ntoa(recvn(c, 4))
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, recvn(c, 16))
    else:
        raise AssertionError(f"atyp {atyp}")
    port = struct.unpack("!H", recvn(c, 2))[0]
    assert rep == 0, f"rep={rep}"
    return c, host, port


def roundtrip(family, host, port, echo_port):
    u = socket.socket(family, socket.SOCK_DGRAM)
    u.settimeout(4)
    hdr = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo_port)
    payload = os.urandom(64)
    u.sendto(hdr + payload, (host, port))
    try:
        d, _ = u.recvfrom(65535)
    except socket.timeout:
        return False
    return d.endswith(payload)


echo = echo_server()
echo_port = echo.getsockname()[1]

targets = [(socket.AF_INET, a) for a in ["127.0.0.1"] + [x for x in local_v4() if x != "127.0.0.1"]]
try:
    socket.create_connection(("::1", PORT), timeout=2).close()
    targets.append((socket.AF_INET6, "::1"))
except OSError:
    print("note: server not reachable on ::1, skipping IPv6 case")

for fam, addr in targets:
    try:
        c, host, port = associate(fam, addr)
    except Exception as e:
        check(f"associate via {addr}", False, repr(e))
        continue
    check(f"advertised == connected address ({addr})", host == addr, f"advertised {host}:{port}")
    check(f"datagram round-trip to ADVERTISED address ({addr})", roundtrip(fam, host, port, echo_port))
    c.close()

print("FAILURES:", fails)
sys.exit(1 if fails else 0)
