#ifndef CLWIP_SHIM_H
#define CLWIP_SHIM_H

/* Explicit list of the lwIP headers TunnelEngine.swift actually needs,
 * included in one normal translation unit (each header's own #include
 * guards + internal #includes do the rest) — deliberately NOT an
 * umbrella-*directory* module (SwiftPM's default when no module.modulemap
 * is present), which tries to compile every header under include/
 * (including unrelated netif/ppp/*.h, lowpan*.h, etc.) as independent
 * top-level units and breaks on lwIP's legacy, non-modules-clean headers. */

#include "lwip/init.h"
#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/mem.h"
#include "lwip/memp.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "lwip/sys.h"
#include "lwip/ip.h"
#include "lwip/ip4.h"
#include "lwip/ip4_addr.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/timeouts.h"

/* Deliberately NOT including lwip/inet.h: its BSD-compat `struct in6_addr`
 * is defined unconditionally (not guarded by LWIP_IPV6) and collides with
 * Darwin's real <netinet6/in6.h> definition when both land in the same
 * Clang module. We don't need it — lwIP's own natively-named
 * ip4addr_aton()/ip4addr_ntoa() (from ip4_addr.h, already included) cover
 * everything this engine uses. */

/* Thin real functions wrapping macros/inline patterns the Swift side can't
 * call directly (Swift's Clang importer only imports simple object-like
 * macros, not multi-statement function-like ones like `ip_addr_copy_from_ip4`
 * or `tcp_sndbuf`). */

static inline void lwip_shim_ip_addr_from_ip4(ip_addr_t *dest, const ip4_addr_t *src) {
    ip_addr_copy_from_ip4(*dest, *src);
}

static inline const ip4_addr_t *lwip_shim_ip4_current_dest_addr(void) {
    return ip4_current_dest_addr();
}

static inline void lwip_shim_ip_addr_set_any(ip_addr_t *dest) {
    ip_addr_set_any(0, dest);
}

static inline u16_t lwip_shim_tcp_sndbuf(const struct tcp_pcb *pcb) {
    return tcp_sndbuf(pcb);
}

#endif /* CLWIP_SHIM_H */
