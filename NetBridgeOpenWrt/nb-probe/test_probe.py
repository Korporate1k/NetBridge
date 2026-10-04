#!/usr/bin/env python3
"""Tests nb-probe's verdicts against the repo's SOCKS5 test server and small fake servers.
   python3 test_probe.py [path/to/nb-probe]      (default: target/release/nb-probe)"""
import os, socket, subprocess, sys, threading, time

PROBE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "target/release/nb-probe")
if not os.access(PROBE, os.X_OK):
    sys.exit(f"nb-probe not found or not executable: {PROBE} (cargo build --release)")
SERVER = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "socks5_test_server.py")
results = []

def check(name, ok, detail=""):
    results.append(ok); print(("PASS" if ok else "FAIL"), "-", name, ("| " + detail) if detail else "", flush=True)

def probe(port, *args, timeout="2"):
    t = time.time()
    p = subprocess.run([PROBE, "127.0.0.1", str(port), "--timeout", timeout, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), time.time() - t

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def fake(handler):
    """Listening socket on a free port whose connections are handed to handler(conn) in a thread."""
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0)); srv.listen(8); port = srv.getsockname()[1]
    def loop():
        while True:
            try: c, _ = srv.accept()
            except OSError: return
            threading.Thread(target=handler, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return srv, port

SERVERS = []

def start_server(*extra):
    port = free_port()
    p = subprocess.Popen([sys.executable, SERVER, "--bind", "127.0.0.1", "--port", str(port), *extra],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    SERVERS.append(p)
    for _ in range(50):
        try: socket.create_connection(("127.0.0.1", port), 0.2).close(); return p, port
        except OSError: time.sleep(0.1)
    p.kill()
    sys.exit(f"test server did not start on port {port}: {p.stderr.read().decode(errors='replace')[-500:]}")

def stop(p):
    p.terminate()
    try: p.wait(5)
    except subprocess.TimeoutExpired: p.kill(); p.wait()

# 1. real server with auth
p, port = start_server("--user", "nb", "--password", "secret")
rc, out, _ = probe(port, "--user", "nb", "--pass", "secret"); check("auth server, right credentials", rc == 0 and "udp=yes" in out, f"rc={rc} {out}")
rc, out, _ = probe(port, "--user", "nb", "--pass", "wrong");  check("auth server, wrong password -> auth_rejected", rc == 2 and "auth_rejected" in out, f"rc={rc} {out}")
rc, out, _ = probe(port);                                     check("auth server, no credentials -> auth_rejected", rc == 2, f"rc={rc} {out}")
os.environ["NB_USER"], os.environ["NB_PASS"] = "nb", "secret"
rc, out, _ = probe(port);                                     check("credentials from NB_USER/NB_PASS env", rc == 0, f"rc={rc} {out}")
del os.environ["NB_USER"], os.environ["NB_PASS"]
stop(p)
# 2. real server without auth
p, port = start_server()
rc, out, _ = probe(port); check("no-auth server", rc == 0 and "udp=yes" in out, f"rc={rc} {out}")
stop(p)
# 3. nothing listening
rc, out, dt = probe(port); check("nothing listening -> not_answering, fast", rc == 1 and "connect:" in out and dt < 1.5, f"rc={rc} {dt:.2f}s {out}")
# 4. silent server: accepts TCP, never answers (a suspended iOS relay)
srv, sport = fake(lambda c: time.sleep(30))
rc, out, dt = probe(sport, timeout="2"); check("silent server (accepts, never answers) -> not_answering within the timeout", rc == 1 and 1.5 < dt < 3.0, f"rc={rc} {dt:.2f}s {out}")
srv.close()
# 5. not SOCKS5 (HTTP-ish banner)
def http_like(c): c.recv(16); c.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n"); c.close()
srv, hport = fake(http_like)
rc, out, _ = probe(hport); check("non-SOCKS5 server -> not_answering", rc == 1 and "not a SOCKS5 server" in out, f"rc={rc} {out}")
srv.close()
# 6. server that refuses UDP ASSOCIATE
def no_udp(c):
    c.recv(8); c.sendall(b"\x05\x00"); c.recv(16); c.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00"); time.sleep(0.5); c.close()
srv, uport = fake(no_udp)
rc, out, _ = probe(uport); check("server refusing UDP ASSOCIATE -> answering, udp=no (exit 3)", rc == 3 and "udp=no" in out, f"rc={rc} {out}")
srv.close()
# 7. server that drops after the greeting
def drop(c): c.recv(8); c.close()
srv, dport = fake(drop)
rc, out, _ = probe(dport); check("server closing mid-handshake -> not_answering", rc == 1 and "closed the connection" in out, f"rc={rc} {out}")
srv.close()
# 8. argument validation: exit 64 (usage), never an abort (134) with nothing printed
for bad in (["--timeout", "inf"], ["--timeout", "nan"], ["--timeout", "0"], ["--timeout", "-1"], ["--timeout", "1e30"], ["--timeout"]):
    q = subprocess.run([PROBE, "127.0.0.1", "1080", *bad], capture_output=True, text=True)
    check(f"bad argument {' '.join(bad)} -> usage error 64", q.returncode == 64, f"rc={q.returncode}")
q = subprocess.run([PROBE, b"\xff\xfe", "1080"], capture_output=True)
check("non-UTF-8 HOST -> clean not_answering, no abort", q.returncode == 1 and b"state=not_answering" in q.stdout, f"rc={q.returncode}")
# 9. HOST must be an IP address (a DNS lookup cannot be bounded by the deadline)
q = subprocess.run([PROBE, "example.com", "1080"], capture_output=True, text=True)
check("hostname HOST -> not_answering with a clear reason", q.returncode == 1 and "must be an IP address" in q.stdout, q.stdout.strip())
# 10. the detail can never break the one-line, double-quoted output the watchdog parses
q = subprocess.run([PROBE, 'a"b\\c\nd', "1080"], capture_output=True, text=True)
line = q.stdout
check("detail is sanitised: one line, exactly two double quotes, no backslash", line.count("\n") == 1 and line.count('"') == 2 and "\\" not in line, repr(line))

for p in SERVERS:
    if p.poll() is None: stop(p)
print(f"== {sum(results)} passed, {len(results) - sum(results)} failed"); sys.exit(0 if all(results) else 1)
