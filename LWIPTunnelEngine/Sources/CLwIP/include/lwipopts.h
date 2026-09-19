#ifndef LWIP_LWIPOPTS_H
#define LWIP_LWIPOPTS_H

/*
 * Config for embedding lwIP as a tun2socks-style engine: NO_SYS (no OS/
 * threads — driven by TunnelEngine's own serial queue + a repeating timer
 * calling sys_check_timeouts()), IPv4-only, no link layer (point-to-point
 * tun interface, so no ARP/Ethernet), no DHCP/AutoIP/IGMP/DNS (the tunnel's
 * network settings are fixed by NEPacketTunnelNetworkSettings on the Swift
 * side; on-device DNS queries arrive as ordinary UDP packets to whatever
 * server was configured and get relayed like any other UDP flow), no
 * sockets/netconn API (LocalProxyTunnel drives the raw tcp and udp PCB API
 * directly for tun2socks-style flow interception).
 */

#define NO_SYS                      1
#define LWIP_TIMERS                 1

#define LWIP_IPV6                   0
#define LWIP_ARP                    0
#define LWIP_ETHERNET               0
#define LWIP_DHCP                   0
#define LWIP_AUTOIP                 0
#define LWIP_IGMP                   0
#define LWIP_DNS                    0
#define LWIP_RAW                    0
#define LWIP_NETCONN                0
#define LWIP_SOCKET                 0
#define LWIP_STATS                  0
#define LWIP_NETIF_STATUS_CALLBACK  0
#define LWIP_NETIF_LINK_CALLBACK    0
#define LWIP_HAVE_LOOPIF            0
#define LWIP_NETIF_LOOPBACK         0
#define SYS_LIGHTWEIGHT_PROT        0

#define LWIP_ICMP                   1
#define LWIP_TCP                    1
#define LWIP_UDP                    1
#define LWIP_NETIF_TX_SINGLE_PBUF   1

/* Correctness over hardware-offload speed — nothing here has real NIC
 * checksum offload, and outbound packets we synthesize (SYN-ACKs, etc.)
 * need lwIP to actually fill in valid checksums. */
#define CHECKSUM_GEN_IP             1
#define CHECKSUM_GEN_UDP            1
#define CHECKSUM_GEN_TCP            1
#define CHECKSUM_GEN_ICMP           1
#define CHECKSUM_CHECK_IP           1
#define CHECKSUM_CHECK_UDP          1
#define CHECKSUM_CHECK_TCP          1
#define CHECKSUM_CHECK_ICMP         1

#define MEM_ALIGNMENT               4
#define MEM_SIZE                    (256 * 1024)

#define MEMP_NUM_TCP_PCB            64
#define MEMP_NUM_TCP_PCB_LISTEN     4
#define MEMP_NUM_TCP_SEG            256
#define MEMP_NUM_UDP_PCB            32
#define MEMP_NUM_NETBUF             16
#define MEMP_NUM_NETCONN            0
#define MEMP_NUM_PBUF               64

#define PBUF_POOL_SIZE              256
#define PBUF_POOL_BUFSIZE           1536

#define TCP_MSS                     1400
#define TCP_WND                     (16 * TCP_MSS)
#define TCP_SND_BUF                 (16 * TCP_MSS)
#define TCP_SND_QUEUELEN            (4 * (TCP_SND_BUF) / (TCP_MSS))
#define TCP_QUEUE_OOSEQ             1

#define IP_REASSEMBLY               1
#define IP_FRAG                     1
#define IP_FORWARD                  0

#define LWIP_NETIF_API              0
#define LWIP_COMPAT_MUTEX           0

#define LWIP_DEBUG                  0
#define TCP_DEBUG                   LWIP_DBG_OFF
#define IP_DEBUG                    LWIP_DBG_OFF

#endif /* LWIP_LWIPOPTS_H */
