#!/usr/bin/env python3
"""SOCKS5 UDP ASSOCIATE QA against a running NetBridge server."""
import socket, struct, sys, threading, time, os, random

PROXY = ("127.0.0.1", int(os.environ.get("PROXY_PORT", "18080")))
results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS" if ok else "FAIL"), "-", name, ("| " + detail) if detail else "", flush=True)


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def associate():
    c = socket.create_connection(PROXY, timeout=5)
    c.sendall(b"\x05\x01\x00")
    assert recvn(c, 2) == b"\x05\x00", "method negotiation"
    c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    ver, rep, _, atyp = struct.unpack("!BBBB", recvn(c, 4))
    assert atyp == 1
    host = socket.inet_ntoa(recvn(c, 4))
    port = struct.unpack("!H", recvn(c, 2))[0]
    assert rep == 0, f"associate rep={rep}"
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(4)
    u.bind(("0.0.0.0", 0))
    # relay may advertise the LAN IP; use loopback to reach it (same host)
    return c, u, ("127.0.0.1", port), host


def wrap(host, port, payload, atyp=None, frag=0):
    try:
        addr = socket.inet_pton(socket.AF_INET, host)
        a = b"\x01" + addr
    except OSError:
        try:
            addr = socket.inet_pton(socket.AF_INET6, host)
            a = b"\x04" + addr
        except OSError:
            a = b"\x03" + bytes([len(host)]) + host.encode()
    return b"\x00\x00" + bytes([frag]) + a + struct.pack("!H", port) + payload


def unwrap(d):
    assert d[:2] == b"\x00\x00"
    atyp = d[3]
    if atyp == 1:
        off = 4 + 4
    elif atyp == 4:
        off = 4 + 16
    else:
        off = 5 + d[4]
    return d[off + 2:], d[:off + 2]


def dns_query(name="example.com"):
    tid = random.randint(0, 65535)
    q = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    for p in name.split("."):
        q += bytes([len(p)]) + p.encode()
    q += b"\x00\x00\x01\x00\x01"
    return tid, q


# ---- local UDP echo servers; record the source address seen for each datagram
seen_src = []


def echo_server(family, bind):
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.bind(bind)
    s.settimeout(0.2)
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            try:
                d, a = s.recvfrom(65535)
            except socket.timeout:
                continue
            seen_src.append(a)
            s.sendto(d, a)

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return s, stop


def main():
    e4, stop4 = echo_server(socket.AF_INET, ("127.0.0.1", 0))
    e4port = e4.getsockname()[1]
    have6 = True
    try:
        e6, stop6 = echo_server(socket.AF_INET6, ("::1", 0))
        e6port = e6.getsockname()[1]
    except OSError:
        have6 = False

    # 1. Real DNS via two public resolvers
    c, u, relay, _ = associate()
    cport = u.getsockname()[1]
    for resolver in ("1.1.1.1", "8.8.8.8"):
        tid, q = dns_query()
        u.sendto(wrap(resolver, 53, q), relay)
        try:
            d, _ = u.recvfrom(4096)
            payload, hdr = unwrap(d)
            ok = len(payload) > 12 and struct.unpack("!H", payload[:2])[0] == tid and (payload[3] & 0x0F) == 0 and struct.unpack("!H", payload[6:8])[0] >= 1
            check(f"DNS A example.com via {resolver} through relay", ok, f"{len(payload)}B reply")
            exp = b"\x00\x00\x00\x01" + socket.inet_aton(resolver) + struct.pack("!H", 53)
            check(f"reply header names real source {resolver}:53", hdr == exp, f"hdr={hdr.hex()}")
        except socket.timeout:
            check(f"DNS A example.com via {resolver} through relay", False, "timeout")

    # 2. Echo integrity across sizes; source must not be the client's own socket
    del seen_src[:]
    for size in (1, 64, 512, 1200, 1400, 4000, 9000):
        p = os.urandom(size)
        u.sendto(wrap("127.0.0.1", e4port, p), relay)
        try:
            d, _ = u.recvfrom(65535)
            got, _h = unwrap(d)
            check(f"echo integrity {size}B", got == p and _h == b"\x00\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", e4port), "" if got == p else f"got {len(got)}B")
        except socket.timeout:
            check(f"echo integrity {size}B", False, "timeout")
    srcports = {a[1] for a in seen_src}
    check("destination saw relay's socket, NOT the client's", cport not in srcports and len(srcports) >= 1,
          f"client port {cport}, destination saw ports {sorted(srcports)}")

    # 3. Burst of 200 datagrams, count replies + order
    u.settimeout(0.6)
    n = 200
    for i in range(n):
        u.sendto(wrap("127.0.0.1", e4port, struct.pack("!I", i) + b"x" * 100), relay)
    got = []
    try:
        while len(got) < n:
            d, _ = u.recvfrom(65535)
            got.append(struct.unpack("!I", unwrap(d)[0][:4])[0])
    except socket.timeout:
        pass
    check("burst 200 datagrams (loopback, no pacing)", len(got) >= 190, f"{len(got)}/200 replies, in-order={got == sorted(got)}")
    u.settimeout(4)

    # 4. Domain-name ATYP (3)
    p = b"hostname-atyp"
    u.sendto(wrap("dns.google", 53, dns_query()[1]), relay)
    try:
        d, _ = u.recvfrom(4096)
        pl, h3 = unwrap(d)
        check("domain-name destination (ATYP=3), header names resolved IP:53", len(pl) > 12 and h3[3] in (1, 4) and h3[-2:] == struct.pack("!H", 53), f"hdr={h3.hex()}")
    except socket.timeout:
        check("domain-name destination (ATYP=3)", False, "timeout")

    # 5. IPv6 destination (ATYP 4)
    if have6:
        p = b"ipv6-atyp"
        u.sendto(wrap("::1", e6port, p), relay)
        try:
            d, _ = u.recvfrom(4096)
            pl, h6 = unwrap(d)
            check("IPv6 destination (ATYP=4), header names ::1", pl == p and h6 == b"\x00\x00\x00\x04" + socket.inet_pton(socket.AF_INET6, "::1") + struct.pack("!H", e6port), f"hdr={h6.hex()}")
        except socket.timeout:
            check("IPv6 destination (ATYP=4)", False, "timeout")

    # 6. Multiple destinations concurrently in one association (DNS + echo)
    tid, q = dns_query("apple.com")
    u.sendto(wrap("1.1.1.1", 53, q), relay)
    u.sendto(wrap("127.0.0.1", e4port, b"multi"), relay)
    replies = []
    try:
        while len(replies) < 2:
            replies.append(unwrap(u.recvfrom(4096)[0])[0])
    except socket.timeout:
        pass
    check("two destinations interleaved in one association", len(replies) == 2, f"{len(replies)}/2")

    # 6b. Stable external port: two different destinations must see the SAME relay source port
    e4b, stop4b = echo_server(socket.AF_INET, ("127.0.0.1", 0))
    e4bport = e4b.getsockname()[1]
    del seen_src[:]
    u.sendto(wrap("127.0.0.1", e4port, b"one"), relay)
    u.sendto(wrap("127.0.0.1", e4bport, b"two"), relay)
    try:
        u.recvfrom(4096); u.recvfrom(4096)
    except socket.timeout:
        pass
    ports = {a[1] for a in seen_src}
    check("one external port shared by all destinations (endpoint-independent mapping)", len(ports) == 1, f"destinations saw source ports {sorted(ports)}")
    relay_egress = seen_src[0] if seen_src else None
    stop4b.set()

    # 6c. Reply from a DIFFERENT socket than the one the client sent to (e.g. DNS answering from another IP/port)
    other = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); other.bind(("127.0.0.1", 0))
    oport = other.getsockname()[1]
    ask = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); ask.bind(("127.0.0.1", 0)); ask.settimeout(4)
    askport = ask.getsockname()[1]
    def answer_elsewhere():
        try:
            d, a = ask.recvfrom(4096)
            other.sendto(b"reply-from-other-port:" + d, a)
        except socket.timeout:
            pass
    threading.Thread(target=answer_elsewhere, daemon=True).start()
    u.sendto(wrap("127.0.0.1", askport, b"q"), relay)
    try:
        d, _ = u.recvfrom(4096)
        pl, h = unwrap(d)
        check("reply from a different source port is delivered, header names it",
              pl == b"reply-from-other-port:q" and h == b"\x00\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", oport), f"hdr={h.hex()} expected port {oport}")
    except socket.timeout:
        check("reply from a different source port is delivered, header names it", False, "timeout (dropped)")

    # 6d. Unsolicited inbound from a party the client never sent to (hole-punch / full cone)
    if relay_egress:
        peer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); peer.bind(("127.0.0.1", 0))
        pport = peer.getsockname()[1]
        peer.sendto(b"unsolicited-hello", relay_egress)
        try:
            d, _ = u.recvfrom(4096)
            pl, h = unwrap(d)
            check("unsolicited datagram from a never-contacted peer is delivered (full cone)",
                  pl == b"unsolicited-hello" and h[-2:] == struct.pack("!H", pport), f"hdr={h.hex()} expected port {pport}")
        except socket.timeout:
            check("unsolicited datagram from a never-contacted peer is delivered (full cone)", False, "timeout (dropped)")

    # 7. Malformed + fragmented datagrams must be dropped, not crash/echo
    u.settimeout(1.5)
    u.sendto(b"\x00\x00", relay)  # too short
    u.sendto(wrap("127.0.0.1", e4port, b"frag", frag=1), relay)  # FRAG != 0
    try:
        u.recvfrom(4096)
        check("malformed / FRAG!=0 datagrams dropped", False, "unexpected reply")
    except socket.timeout:
        check("malformed / FRAG!=0 datagrams dropped", True)
    # relay still healthy afterwards
    u.settimeout(4)
    u.sendto(wrap("127.0.0.1", e4port, b"alive"), relay)
    try:
        check("relay survives malformed input", unwrap(u.recvfrom(4096)[0])[0] == b"alive")
    except socket.timeout:
        check("relay survives malformed input", False, "timeout")

    # 8. Rogue second sender must not hijack the association
    rogue = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rogue.settimeout(1.5)
    rogue.sendto(wrap("127.0.0.1", e4port, b"rogue"), relay)
    try:
        rogue.recvfrom(4096)
        check("second sender rejected", False, "rogue got a reply")
    except socket.timeout:
        check("second sender rejected", True)
    rogue.close()

    # 9. Closing the TCP control connection tears down the UDP association
    c.close()
    time.sleep(1.5)
    u.settimeout(1.5)
    u.sendto(wrap("127.0.0.1", e4port, b"after-close"), relay)
    try:
        u.recvfrom(4096)
        check("association torn down when control TCP closes", False, "still relaying")
    except (socket.timeout, ConnectionRefusedError):
        check("association torn down when control TCP closes", True)
    u.close()

    stop4.set()
    fails = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(fails)}/{len(results)} passed")
    sys.exit(1 if fails else 0)


main()
