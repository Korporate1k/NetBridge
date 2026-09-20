#!/usr/bin/env python3
"""Cross-association isolation test for the SOCKS5 UDP relay (Mac only, no phone).
Opens N concurrent UDP ASSOCIATEs, learns each one's client-facing port (from the ASSOCIATE reply) and its egress port
(from the whoami server), then sends every association its OWN tagged payload through the relay to the echo server and
checks that each client gets exactly its own reply and nothing else.
  - port collision      : an association's egress port equals another live association's client-facing port
  - dead association    : never got its own reply (its datagrams were hijacked by another relay's egress socket)
  - foreign datagram    : a client received something that is not its own reply (another flow's data / wrapped junk)
Needs: udpload echo 127.0.0.1 21000 1 ; udpload whoami 127.0.0.1 21100 ; proxy on 127.0.0.1:18080.
Usage: N=600 collide.py"""
import os, resource, socket, struct, sys, time

N = int(os.environ.get("N", "600"))
PROXY = ("127.0.0.1", 18080)
resource.setrlimit(resource.RLIMIT_NOFILE, (20000, 20000))


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def associate():
    c = socket.create_connection(PROXY, timeout=10)
    c.sendall(b"\x05\x01\x00")
    assert recvn(c, 2) == b"\x05\x00"
    c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    _, rep, _, atyp = struct.unpack("!BBBB", recvn(c, 4))
    assert rep == 0 and atyp == 1
    host = socket.inet_ntoa(recvn(c, 4))
    port = struct.unpack("!H", recvn(c, 2))[0]
    # Dual-stack IPv6 client socket ON PURPOSE: the relay's NWListener is a dual-stack IPv6 socket, and a plain IPv4
    # client socket can be handed the SAME ephemeral port number as a listener (a test artifact, not a relay bug).
    # With both dual-stack the kernel arbitrates ports between them, so any collision left is the relay's own egress socket.
    u = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    u.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    u.bind(("::", 0))
    u.setblocking(False)
    return {"c": c, "u": u, "relay": ("::ffff:" + host, port), "port": port}


def wrap(port, payload):
    return b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", port) + payload


def drain(a):
    out = []
    while True:
        try:
            out.append(a["u"].recv(65535))
        except BlockingIOError:
            return out


INTERLEAVED = os.environ.get("ORDER", "interleaved") == "interleaved"


def learn_egress(a, wait=1.0):
    """Send 'who' and read back the relay's egress port as the whoami server saw it."""
    a["u"].sendto(wrap(21100, b"who"), a["relay"])
    deadline = time.time() + wait
    a.setdefault("egress", None)
    a.setdefault("p1", [])
    while time.time() < deadline and a["egress"] is None:
        for d in drain(a):
            text = d[10:].decode(errors="replace")
            a["p1"].append(text[:24])
            if text.startswith("127.0.0.1:"):
                a["egress"] = int(text.split(":")[1])
        time.sleep(0.005)


assocs = []
for i in range(N):
    try:
        a = associate()
    except Exception as e:
        print(f"association {i} failed: {e}")
        break
    assocs.append(a)
    if INTERLEAVED:
        # egress socket is created NOW (on the first datagram), before the next association's listener exists
        learn_egress(a)
print(f"opened {len(assocs)} concurrent associations ({'interleaved: egress created right after each listener' if INTERLEAVED else 'listeners first, egress later'})", flush=True)

if not INTERLEAVED:
    # phase 1: egress port of each association (whoami replies "ip:port"; it also sends an unsolicited "punch" 300 ms later)
    for a in assocs:
        a["u"].sendto(wrap(21100, b"who"), a["relay"])
    time.sleep(1.5)
    for a in assocs:
        a["egress"] = None
        for d in drain(a):
            text = d[10:].decode(errors="replace")
            if text.startswith("127.0.0.1:"):
                a["egress"] = int(text.split(":")[1])
else:
    time.sleep(1.0)
    for a in assocs:
        for d in drain(a):   # leftovers from the who phase (normally just the "punch")
            a["p1"].append(d[10:].decode(errors="replace")[:24])
    missing = [(i, a["p1"]) for i, a in enumerate(assocs) if not a["egress"]]
    print(f"who-phase datagrams received by associations WITHOUT a who-reply: {missing[:6]}")
    nopunch = [i for i, a in enumerate(assocs) if a["egress"] and not any(t.startswith("punch:") for t in a["p1"])]
    print(f"associations that got the who-reply but NO punch: {len(nopunch)} {nopunch[:8]}")

listeners = {a["port"]: i for i, a in enumerate(assocs)}
collisions = [(i, a["egress"], listeners[a["egress"]]) for i, a in enumerate(assocs)
              if a["egress"] in listeners and listeners[a["egress"]] != i]
print(f"associations with a learned egress port: {sum(1 for a in assocs if a['egress'])}/{len(assocs)}"
      f"   without: {[i for i, a in enumerate(assocs) if not a['egress']][:10]}")
print(f"PORT COLLISIONS (egress port of A == client-facing port of B, both alive): {len(collisions)}")
for i, port, j in collisions[:6]:
    print(f"   association {i} egress {port} == association {j} client-facing {port}")

# phase 2: each association sends its own tagged payload and must get exactly that back
for i, a in enumerate(assocs):
    a["tag"] = (f"TAG{i:05d}".encode() * 8)[:64]
    a["u"].sendto(wrap(21000, a["tag"]), a["relay"])
time.sleep(2.5)
dead, foreign, dup = [], [], []
for i, a in enumerate(assocs):
    got = drain(a)
    own = [d for d in got if d[10:] == a["tag"] and d[:4] == b"\x00\x00\x00\x01"]
    other = [d for d in got if d not in own and not d[10:].startswith(b"punch:")]
    if not own:
        dead.append(i)
    if len(own) > 1:
        dup.append(i)
    if other:
        foreign.append((i, len(other), other[0][:16].hex()))
print(f"DEAD associations (own reply never arrived): {len(dead)}  {dead[:8]}")
print(f"associations that received FOREIGN datagrams: {len(foreign)}  e.g. {foreign[:3]}")
print(f"associations with duplicated replies: {len(dup)}")
bad = len(collisions) + len(dead) + len(foreign) + len(dup)
print("RESULT:", "PASS (fully isolated)" if bad == 0 else f"FAIL ({len(collisions)} collisions, {len(dead)} dead, {len(foreign)} foreign)")
sys.exit(1 if bad else 0)
