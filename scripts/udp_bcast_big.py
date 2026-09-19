import socket, struct, time, os, sys
exec(open('udp_qa.py').read().replace("\nmain()\n", "\n"))
c, u, relay, _ = associate()
u.settimeout(3)

# --- broadcast: listener on 0.0.0.0:P answers whoever sent the broadcast
L = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
L.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
L.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
L.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
L.bind(("0.0.0.0", 0)); P = L.getsockname()[1]; L.settimeout(3)
import threading
def answer():
    try:
        d, a = L.recvfrom(4096); L.sendto(b"bcast-ack:" + d, a)
    except socket.timeout: pass
threading.Thread(target=answer, daemon=True).start()
for target in ("255.255.255.255", "10.0.0.255"):
    u.sendto(wrap(target, P, b"hello-bcast"), relay)
    try:
        pl, h = unwrap(u.recvfrom(4096)[0])
        check(f"broadcast to {target} delivered + answered", pl == b"bcast-ack:hello-bcast", f"hdr={h.hex()}")
        break
    except socket.timeout:
        check(f"broadcast to {target} delivered + answered", False, "no reply")
        threading.Thread(target=answer, daemon=True).start()

# --- large payloads through the relay (client->relay->echo->relay->client)
e, _ = echo_server(socket.AF_INET, ("127.0.0.1", 0)); ep = e.getsockname()[1]
u.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
for size in (9000, 9200, 16000, 32768, 60000, 65000, 65497):
    p = os.urandom(size)
    try:
        u.sendto(wrap("127.0.0.1", ep, p), relay)
    except OSError as ex:
        check(f"large payload {size}B", False, f"client-side sendto refused: {ex}")
        continue
    try:
        got, h = unwrap(u.recvfrom(70000)[0])
        check(f"large payload {size}B round trip", got == p)
    except socket.timeout:
        check(f"large payload {size}B round trip", False, "no reply (dropped)")
print("done")
