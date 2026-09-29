//! Keeps link-local-only traffic out of the proxy. Windows sends mDNS (224.0.0.251 / ff02::fb), LLMNR
//! (224.0.0.252 / ff02::1:3), SSDP, NetBIOS name broadcasts (the adapter's subnet broadcast, :137) and the like out
//! of EVERY interface, the tunnel adapter included. None of it means anything on the far side of a SOCKS server, and
//! tun2proxy would otherwise relay each datagram as a UDP ASSOCIATE session.
//!
//! Per-interface switches don't cover it: LLMNR and mDNS can only be turned off machine-wide (EnableMulticast /
//! EnableMDNS), and NetBIOS-over-TCP/IP only stops the :137 broadcasts. Routes can't either: Windows puts its own
//! on-link 224.0.0.0/4, ff00::/8 and broadcast routes on each interface, and senders pick the interface explicitly.
//! So we drop these packets where they leave Windows: between the tunnel device and the engine.

use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// The directed broadcast address of `addr`/`netmask` (10.254.77.2/24 -> 10.254.77.255).
pub fn subnet_broadcast(addr: Ipv4Addr, netmask: Ipv4Addr) -> Ipv4Addr {
    Ipv4Addr::from(u32::from(addr) | !u32::from(netmask))
}

/// True for a packet whose destination only exists on the local link: multicast, broadcast (limited or the tunnel
/// subnet's `v4_broadcast`), or link-local unicast. Anything that isn't a well-formed IPv4/IPv6 header is kept; the
/// engine decides what to do with it, as before.
pub fn is_link_local_only(packet: &[u8], v4_broadcast: Ipv4Addr) -> bool {
    match packet.first().map(|b| b >> 4) {
        Some(4) if packet.len() >= 20 => {
            let dst = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);
            dst.is_multicast() || dst.is_broadcast() || dst == v4_broadcast || dst.is_link_local()
        }
        Some(6) if packet.len() >= 40 => {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(&packet[24..40]);
            let dst = Ipv6Addr::from(octets);
            dst.is_multicast() || dst.is_unicast_link_local()
        }
        _ => false,
    }
}

/// The tunnel device as the engine sees it, minus link-local-only packets (see `is_link_local_only`). Relies on the
/// device returning exactly one packet per read, which the wintun device does and the engine requires anyway.
pub struct LinkLocalFilter<D> {
    inner: D,
    v4_broadcast: Ipv4Addr,
    dropped: u64,
}

impl<D> LinkLocalFilter<D> {
    pub fn new(inner: D, v4_broadcast: Ipv4Addr) -> Self {
        LinkLocalFilter { inner, v4_broadcast, dropped: 0 }
    }
}

impl<D: AsyncRead + Unpin> AsyncRead for LinkLocalFilter<D> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = &mut *self;
        let start = buf.filled().len();
        loop {
            match Pin::new(&mut this.inner).poll_read(cx, buf) {
                Poll::Ready(Ok(())) if is_link_local_only(&buf.filled()[start..], this.v4_broadcast) => {
                    this.dropped += 1;
                    if this.dropped.is_power_of_two() {
                        log::debug!("dropped {} link-local-only packets (multicast/broadcast) so far", this.dropped);
                    }
                    buf.set_filled(start); // discard it and read the next packet
                }
                other => return other,
            }
        }
    }
}

impl<D: AsyncWrite + Unpin> AsyncWrite for LinkLocalFilter<D> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use tokio::io::AsyncReadExt;

    const BCAST: Ipv4Addr = Ipv4Addr::new(10, 254, 77, 255);

    fn v4(dst: [u8; 4]) -> Vec<u8> {
        let mut p = vec![0u8; 28];
        p[0] = 0x45;
        p[9] = 17; // UDP
        p[12..16].copy_from_slice(&[10, 254, 77, 2]);
        p[16..20].copy_from_slice(&dst);
        p
    }

    fn v6(dst: &str) -> Vec<u8> {
        let mut p = vec![0u8; 48];
        p[0] = 0x60;
        p[6] = 17;
        p[8..24].copy_from_slice(&"fd00:7470::2".parse::<Ipv6Addr>().unwrap().octets());
        p[24..40].copy_from_slice(&dst.parse::<Ipv6Addr>().unwrap().octets());
        p
    }

    #[test]
    fn broadcast_of_the_tunnel_subnet() {
        assert_eq!(subnet_broadcast(Ipv4Addr::new(10, 254, 77, 2), Ipv4Addr::new(255, 255, 255, 0)), BCAST);
        assert_eq!(subnet_broadcast(Ipv4Addr::new(10, 1, 2, 3), Ipv4Addr::new(255, 255, 255, 255)), Ipv4Addr::new(10, 1, 2, 3));
    }

    #[test]
    fn windows_link_local_chatter_is_dropped() {
        assert!(is_link_local_only(&v4([224, 0, 0, 251]), BCAST)); // mDNS
        assert!(is_link_local_only(&v4([224, 0, 0, 252]), BCAST)); // LLMNR
        assert!(is_link_local_only(&v4([239, 255, 255, 250]), BCAST)); // SSDP
        assert!(is_link_local_only(&v4([10, 254, 77, 255]), BCAST)); // NetBIOS name service broadcast
        assert!(is_link_local_only(&v4([255, 255, 255, 255]), BCAST));
        assert!(is_link_local_only(&v4([169, 254, 1, 1]), BCAST));
        assert!(is_link_local_only(&v6("ff02::fb"), BCAST));
        assert!(is_link_local_only(&v6("ff02::1:3"), BCAST));
        assert!(is_link_local_only(&v6("fe80::1"), BCAST));
    }

    #[test]
    fn everything_else_is_kept() {
        assert!(!is_link_local_only(&v4([8, 8, 8, 8]), BCAST)); // DNS to the virtual resolver
        assert!(!is_link_local_only(&v4([10, 254, 77, 1]), BCAST));
        assert!(!is_link_local_only(&v4([192, 168, 1, 255]), BCAST)); // someone else's broadcast is just an address
        assert!(!is_link_local_only(&v6("2606:4700::1111"), BCAST));
        assert!(!is_link_local_only(&v6("fd00:7470::1"), BCAST));
        // Truncated or unknown headers go to the engine unchanged.
        assert!(!is_link_local_only(&v4([224, 0, 0, 251])[..19], BCAST));
        assert!(!is_link_local_only(&v6("ff02::fb")[..39], BCAST));
        assert!(!is_link_local_only(&[], BCAST));
        assert!(!is_link_local_only(&[0x00; 40], BCAST));
    }

    /// A device that hands out one queued packet per read, like wintun.
    struct Packets(VecDeque<Vec<u8>>);

    impl AsyncRead for Packets {
        fn poll_read(mut self: Pin<&mut Self>, _cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
            if let Some(p) = self.0.pop_front() {
                buf.put_slice(&p);
            }
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn filter_skips_dropped_packets_and_returns_the_next_real_one() {
        let real = v4([1, 1, 1, 1]);
        let dev = Packets(VecDeque::from([v4([224, 0, 0, 251]), v6("ff02::fb"), v4([10, 254, 77, 255]), real.clone()]));
        let mut filter = LinkLocalFilter::new(dev, BCAST);
        let mut buf = vec![0u8; 1500];
        let n = filter.read(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], &real[..]);
        assert_eq!(filter.dropped, 3);
        assert_eq!(filter.read(&mut buf).await.unwrap(), 0); // end of stream still reaches the engine
    }
}
