#!/usr/bin/env python3
"""Cold-hostname burst test: datagrams sent to a hostname (ATYP 3) the relay has never resolved.
Each trial uses a fresh random *.localtest.me name (public wildcard DNS -> 127.0.0.1) so the relay's first
getaddrinfo is genuinely cold. Reports how many datagrams come back. Usage: coldresolve.py"""
import os, random, socket, struct, sys, time
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "udp_qa.py")).read().replace("\nmain()\n", "\n"))

if os.environ.get("EXT_ECHO_PORT"):
    # Use an external (C) echo so the Python interpreter lock / busy-wait sender can't starve the echo.
    EP = int(os.environ["EXT_ECHO_PORT"])
    stop = type("NoStop", (), {"set": lambda self: None})()
else:
    e, stop = echo_server(socket.AF_INET, ("127.0.0.1", 0))
    EP = e.getsockname()[1]


def trial(n, pps=None, size=200):
    c, u, relay, _ = associate()
    host = f"t{random.randrange(10**9)}.localtest.me"
    u.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    u.settimeout(0.001)
    got = set()
    t0 = time.time()
    for i in range(n):
        u.sendto(wrap(host, EP, struct.pack("!I", i) + b"x" * (size - 4)), relay)
        if pps:
            while time.time() - t0 < (i + 1) / pps:
                pass
    end = time.time() + 3.0
    u.settimeout(0.2)
    while time.time() < end and len(got) < n:
        try:
            pl, _h = unwrap(u.recvfrom(65535)[0])
            got.add(struct.unpack("!I", pl[:4])[0])
        except socket.timeout:
            pass
    c.close(); u.close()
    first_missing = next((i for i in range(n) if i not in got), None)
    return len(got), first_missing


for label, n, pps in (("instant burst of 200", 200, None), ("instant burst of 1000", 1000, None),
                      ("2000 pps for 1 s", 2000, 2000), ("10000 pps for 1 s", 10000, 10000)):
    res = [trial(n, pps) for _ in range(3)]
    print(f"{label:22s} delivered {[r[0] for r in res]} of {n}   first-missing-seq {[r[1] for r in res]}", flush=True)
stop.set()
