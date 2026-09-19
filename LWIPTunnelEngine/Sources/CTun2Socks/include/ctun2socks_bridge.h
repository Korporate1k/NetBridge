#ifndef CTUN2SOCKS_BRIDGE_H
#define CTUN2SOCKS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Minimal bridge between the vendored BadVPN tun2socks C engine and the
 * Swift `LWIPTunnelEngine` target. This is the ONLY header exposed to Swift
 * (via `import CTun2Socks`); the rest of the BadVPN/lwIP tree is private to
 * the C target.
 *
 * tun2socks is IPv4-only in this vendored configuration (the vendored
 * lwip/custom/lwipopts.h sets `LWIP_IPV6 0`, matching upstream Potatso) —
 * see `PacketTunnelProvider` for how IPv6 is left uncaptured as a result.
 */

/*
 * tun2socks entry points (defined in tun2socks/tun2socks.c; the same
 * declarations also live in tun2socks/tun2socks.h).
 *
 * `tun2socks_main` runs the engine's own BReactor event loop and does not
 * return until the tunnel is stopped; it must be called on a dedicated
 * background thread. `fd` is a full-duplex-ish descriptor the engine reads
 * inbound packets from (framed as a 2-byte big-endian length prefix on iOS);
 * outbound packets are delivered via the `ctun2socks_output` callback below
 * rather than written back to `fd`.
 */
extern int tun2socks_main(int argc, char **argv, int fd, int mtu);
extern void stop_tun2socks(void);

/*
 * Convenience entry point that builds the tun2socks argv internally (so the
 * Swift side doesn't have to marshal a `char **`). `socks_server_addr` is
 * "host:port"; `username`/`password` are optional (NULL/empty disables RFC
 * 1929 auth). `fd` is the descriptor the engine reads inbound packets from
 * (framed with a 2-byte big-endian length prefix on iOS); `mtu` is the tun
 * interface MTU. Runs the BReactor event loop and returns only after
 * `stop_tun2socks()` is called.
 */
extern void ctun2socks_start(const char *socks_server_addr, const char *username,
                             const char *password, int fd, int mtu);

/*
 * Set by Swift to receive outbound packets (internet -> device); it should
 * forward them to `NEPacketTunnelFlow.writePackets`. Called from the engine's
 * own thread — hop to the packet flow's queue as needed.
 */
extern void (*ctun2socks_output_handler)(const uint8_t *data, size_t len);

/* Called by BTap on iOS when the engine has an outbound packet to deliver. */
void ctun2socks_output(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* CTUN2SOCKS_BRIDGE_H */
