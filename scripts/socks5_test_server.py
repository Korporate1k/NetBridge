#!/usr/bin/env python3
"""Minimal SOCKS5 server (RFC 1928 CONNECT + UDP ASSOCIATE, RFC 1929 auth) for testing NetBridge clients without
the phone. Logs every request so a test can prove traffic crossed the tunnel.

    scripts/socks5_test_server.py [--port 1080] [--user U --password P]
"""
import argparse
import asyncio
import ipaddress
import socket
import struct
import time

STATS = {"tcp": 0, "udp_assoc": 0, "udp_out": 0, "udp_in": 0, "auth_fail": 0}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def parse_addr(data, i):
    atyp = data[i]
    if atyp == 1:
        return str(ipaddress.IPv4Address(data[i + 1:i + 5])), struct.unpack("!H", data[i + 5:i + 7])[0], i + 7
    if atyp == 4:
        return str(ipaddress.IPv6Address(data[i + 1:i + 17])), struct.unpack("!H", data[i + 17:i + 19])[0], i + 19
    if atyp == 3:
        n = data[i + 1]
        return data[i + 2:i + 2 + n].decode(), struct.unpack("!H", data[i + 2 + n:i + 4 + n])[0], i + 4 + n
    raise ValueError(f"bad atyp {atyp}")


def encode_addr(host, port):
    ip = ipaddress.ip_address(host.split("%")[0])
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped  # replies from IPv4 hosts on a dual-stack relay socket
    head = b"\x01" if ip.version == 4 else b"\x04"
    return head + ip.packed + struct.pack("!H", port)


class UdpRelay(asyncio.DatagramProtocol):
    """One association: datagrams from the client are unwrapped and sent out; replies are wrapped and sent back."""

    def __init__(self, client_ip, tag):
        self.client_ip, self.client_addr, self.tag = client_ip, None, tag
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if addr[0] == self.client_ip and (self.client_addr is None or addr == self.client_addr):
            self.client_addr = addr
            if len(data) < 4 or data[2] != 0:
                return  # fragments unsupported
            try:
                host, port, i = parse_addr(data, 3)
                family = self.transport.get_extra_info("socket").family
                if family == socket.AF_INET6:
                    # Dual-stack relay socket: IPv4 destinations are sent as IPv4-mapped IPv6 addresses.
                    dst = socket.getaddrinfo(host, port, socket.AF_INET6, socket.SOCK_DGRAM, 0,
                                             socket.AI_V4MAPPED | socket.AI_ALL)[0][4]
                else:
                    dst = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)[0][4][:2]
            except Exception as e:  # noqa: BLE001
                log(f"{self.tag} UDP bad datagram: {e}")
                return
            STATS["udp_out"] += 1
            log(f"{self.tag} UDP -> {host}:{port} ({len(data) - i} B)")
            self.transport.sendto(data[i:], dst)
        elif self.client_addr:
            STATS["udp_in"] += 1
            self.transport.sendto(b"\x00\x00\x00" + encode_addr(addr[0], addr[1]) + data, self.client_addr)


async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except Exception:  # noqa: BLE001
        pass
    finally:
        w.close()


async def handle(reader, writer, creds):
    peer = writer.get_extra_info("peername")
    tag = f"[{peer[0]}:{peer[1]}]"
    try:
        ver, n = await reader.readexactly(2)
        methods = await reader.readexactly(n)
        if creds:
            if 2 not in methods:
                writer.write(b"\x05\xff")
                return
            writer.write(b"\x05\x02")
            _, ulen = await reader.readexactly(2)
            user = await reader.readexactly(ulen)
            plen = (await reader.readexactly(1))[0]
            pw = await reader.readexactly(plen)
            ok = (user.decode(), pw.decode()) == creds
            writer.write(b"\x01" + (b"\x00" if ok else b"\x01"))
            if not ok:
                STATS["auth_fail"] += 1
                log(f"{tag} auth failed")
                return
        else:
            writer.write(b"\x05\x00")
        head = await reader.readexactly(4)
        rest = await reader.read(262)
        host, port, _ = parse_addr(head + rest, 3)
        cmd = head[1]
        if cmd == 1:
            STATS["tcp"] += 1
            log(f"{tag} CONNECT {host}:{port}")
            try:
                r2, w2 = await asyncio.wait_for(asyncio.open_connection(host, port), 10)
            except Exception as e:  # noqa: BLE001
                log(f"{tag} CONNECT {host}:{port} failed: {e}")
                writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
                return
            bound = w2.get_extra_info("sockname")
            writer.write(b"\x05\x00\x00" + encode_addr(bound[0], bound[1]))
            await asyncio.gather(pipe(reader, w2), pipe(r2, writer))
        elif cmd == 3:
            STATS["udp_assoc"] += 1
            local_ip = writer.get_extra_info("sockname")[0]
            loop = asyncio.get_running_loop()
            # Bound to all interfaces (a socket bound to the client-facing address can't reach the internet when that
            # is loopback), but advertised as the address the client reached us on.
            if ":" in local_ip:
                # IPv6 client: dual-stack relay socket so it can still reach IPv4 destinations.
                sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                sock.bind(("::", 0))
                transport, _ = await loop.create_datagram_endpoint(lambda: UdpRelay(peer[0], tag), sock=sock)
            else:
                transport, _ = await loop.create_datagram_endpoint(lambda: UdpRelay(peer[0], tag), local_addr=("0.0.0.0", 0))
            port = transport.get_extra_info("sockname")[1]
            log(f"{tag} UDP ASSOCIATE -> relay {local_ip}:{port}")
            writer.write(b"\x05\x00\x00" + encode_addr(local_ip, port))
            await writer.drain()
            await reader.read()  # association lives as long as the TCP connection
            transport.close()
        else:
            writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        try:
            await writer.drain()
        except Exception:  # noqa: BLE001
            pass
        writer.close()


async def report():
    while True:
        await asyncio.sleep(30)
        log(f"stats {STATS}")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1080)
    ap.add_argument("--bind", default="0.0.0.0", help="listen address, e.g. :: for IPv6")
    ap.add_argument("--user")
    ap.add_argument("--password", default="")
    a = ap.parse_args()
    creds = (a.user, a.password) if a.user else None
    server = await asyncio.start_server(lambda r, w: handle(r, w, creds), a.bind, a.port)
    log(f"SOCKS5 test server on {a.bind}:{a.port}{' (auth required)' if creds else ''}")
    asyncio.create_task(report())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
