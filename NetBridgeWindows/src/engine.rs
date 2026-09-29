//! One tunnel session: resolve the server, create the wintun adapter, install routes, run tun2proxy.
//!
//! The engine arguments mirror `LWIPTunnelEngine/Sources/LWIPTunnelEngine/TunnelEngine.swift` (virtual DNS,
//! 1000 sessions, 120 s UDP timeout, warn verbosity). We call `tun2proxy::run` directly rather than
//! `general_run_for_api`, whose helper thread `exit(-1)`s the whole process 2 s after the engine returns.

use crate::config::ClientConfig;
use std::net::SocketAddr;

pub const MTU: u16 = 1500;
/// MSS advertised to the OS in the engine's SYN-ACKs. Without one, Windows falls back to the RFC default of 536
/// bytes and uploads in small segments. MTU - 60 fits both IPv4 (MTU - 40) and IPv6 with one value.
pub const TCP_MSS: u16 = MTU - 60;

/// Resolve once, with the tunnel down, so the answer is real. With the tunnel up, virtual DNS would hand back a fake
/// 198.18.x.x address. Prefers IPv4, like the Apple clients.
pub async fn resolve(config: &ClientConfig) -> Result<SocketAddr, String> {
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((config.host.as_str(), config.port))
        .await
        .map_err(|e| format!("could not resolve {}: {e}", config.host))?
        .collect();
    addrs
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| addrs.first())
        .copied()
        .ok_or_else(|| format!("{} has no address", config.host))
}

/// tun2proxy arguments for one session (same values as the Apple clients' `TunnelEngine`).
pub fn engine_args(config: &ClientConfig, server: SocketAddr) -> tun2proxy::Args {
    use tun2proxy::{ArgDns, ArgProxy, ArgVerbosity, Args, ProxyType, UserKey};
    let mut args = Args::default();
    // Built directly rather than parsed from a URL: tun2proxy's parser re-resolves the host (we already pinned the
    // address) and rejects bracketed IPv6 literals.
    args.proxy = ArgProxy {
        proxy_type: ProxyType::Socks5,
        addr: server,
        credentials: config.credentials().map(|(user, pass)| UserKey::new(user, pass)),
    };
    args.dns = ArgDns::Virtual;
    args.setup = false; // routing is ours, see routing.rs
    args.max_sessions = 1000;
    args.udp_timeout = 120;
    args.verbosity = ArgVerbosity::Warn;
    args.tun = Some("NetBridge".into());
    args.tcp_mss = Some(TCP_MSS);
    args
}

#[cfg(windows)]
pub use windows_impl::*;

#[cfg(windows)]
mod windows_impl {
    use super::*;
    use crate::packet_filter::{LinkLocalFilter, subnet_broadcast};
    use crate::routing::{self, RouteVia, Routes};
    use crate::wintun_device::{AdapterSpec, WintunDevice};
    use std::net::{IpAddr, Ipv4Addr};
    use tun2proxy::CancellationToken;

    /// Fixed adapter GUID, so reconnects reuse one "NetBridge" adapter instead of creating new ones.
    const ADAPTER_GUID: u128 = 0x6e657462_7269_4467_a000_0000_4e42_0001;
    /// Tunnel-side address. Deliberately not 10.0.0.x (a common home LAN, e.g. many ISP routers); the /24 on the
    /// adapter would shadow it.
    const TUN_ADDR: Ipv4Addr = Ipv4Addr::new(10, 254, 77, 2);
    const TUN_NETMASK: Ipv4Addr = Ipv4Addr::new(255, 255, 255, 0);
    const TUN_PREFIX: u8 = 24;

    pub struct Session {
        token: CancellationToken,
        task: tokio::task::JoinHandle<()>,
        engine: tokio::task::AbortHandle,
        tun_index: u32,
        routes: Routes,
        pub server: SocketAddr,
        pub via: RouteVia,
        /// The physical network's default gateway when we connected; see `routing::path_fingerprint`.
        pub fingerprint: Option<RouteVia>,
        pub ipv6_tunnelled: bool,
    }

    /// (up, down) bytes through the tunnel adapter, from Windows' own interface counters. Read once per UI tick;
    /// tun2proxy's traffic callback is deliberately not used: it takes three global mutexes on every relayed chunk.
    fn interface_octets(if_index: u32) -> Option<(u64, u64)> {
        use windows_sys::Win32::NetworkManagement::IpHelper::{GetIfEntry2, MIB_IF_ROW2};
        let mut row: MIB_IF_ROW2 = unsafe { std::mem::zeroed() };
        row.InterfaceIndex = if_index;
        // SAFETY: row is a properly sized, zeroed MIB_IF_ROW2 with InterfaceIndex set, as GetIfEntry2 requires.
        let rc = unsafe { GetIfEntry2(&mut row) };
        // OutOctets: what Windows sent into the tunnel (upload). InOctets: what the engine delivered (download).
        (rc == 0).then_some((row.OutOctets, row.InOctets))
    }

    fn wintun_path() -> std::path::PathBuf {
        // Load wintun.dll only from next to our own exe, never via the DLL search path.
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("wintun.dll")))
            .unwrap_or_else(|| "wintun.dll".into())
    }

    /// Brings a session up. `on_exit` fires once, from a runtime thread, when the engine stops for any reason:
    /// Ok(()) for a stop we asked for, Err(reason) otherwise.
    pub async fn start(
        config: &ClientConfig,
        on_exit: impl FnOnce(Result<(), String>) + Send + 'static,
    ) -> Result<Session, String> {
        let mut server = resolve(config).await?;
        let via = routing::best_route(server.ip(), None).map_err(|e| format!("no route to {}: {e}", server.ip()))?;
        // A link-local IPv6 server (fe80::/10) is only reachable with its zone: the physical interface.
        if let SocketAddr::V6(v6) = &mut server {
            if (v6.ip().segments()[0] & 0xffc0) == 0xfe80 && v6.scope_id() == 0 {
                v6.set_scope_id(via.if_index);
            }
        }
        let fingerprint = routing::path_fingerprint(via);
        let args = engine_args(config, server);

        let dll = wintun_path();
        let spec = AdapterSpec {
            name: "NetBridge",
            guid: ADAPTER_GUID,
            wintun_dll: &dll,
            address: TUN_ADDR,
            prefix_len: TUN_PREFIX,
            mtu: MTU,
            dns: IpAddr::V4(routing::TUNNEL_DNS),
        };
        let device = tokio::task::block_in_place(|| WintunDevice::create(&spec))
            .map_err(|e| format!("could not create the tunnel adapter (is wintun.dll next to NetBridge.exe?): {e}"))?;
        let tun_index = device.index();

        let routes = tokio::task::block_in_place(|| Routes::install(tun_index, server.ip(), via))
            .map_err(|e| format!("could not set up routes: {e}"))?;
        let ipv6_tunnelled = routes.ipv6_tunnelled;

        let token = CancellationToken::new();
        let stop = token.clone();
        // Windows' own mDNS/LLMNR/NetBIOS/SSDP chatter on this adapter never reaches the proxy; see packet_filter.
        let device = LinkLocalFilter::new(device, subnet_broadcast(TUN_ADDR, TUN_NETMASK));
        let engine = tokio::spawn(tun2proxy::run(device, MTU, args, token.clone()));
        let engine_abort = engine.abort_handle();
        // Supervisor: on_exit must fire even if the engine task panics (tokio would otherwise swallow it, and the
        // health probe, which bypasses the tunnel, would keep reporting the server as fine).
        let task = tokio::spawn(async move {
            let outcome = match engine.await {
                Ok(Ok(_)) if stop.is_cancelled() => Ok(()),
                Ok(Ok(sessions)) => Err(format!("engine stopped unexpectedly ({sessions} sessions open)")),
                Ok(Err(e)) => Err(format!("engine failed: {e}")),
                Err(e) if e.is_cancelled() => Ok(()),
                Err(e) => Err(format!("engine crashed: {e}")),
            };
            on_exit(outcome);
        });
        log::info!(
            "connected: server {server} via interface {} next hop {}, tunnel interface {tun_index}, IPv6 {}",
            via.if_index,
            via.next_hop,
            if ipv6_tunnelled { "tunnelled" } else { "NOT tunnelled" }
        );
        Ok(Session { token, task, engine: engine_abort, tun_index, routes, server, via, fingerprint, ipv6_tunnelled })
    }

    impl Session {
        pub fn bypass_record(&self) -> String {
            self.routes.bypass_record().to_string()
        }

        /// Stops the engine, takes the routes down, and waits (bounded) for the engine to release the adapter, so an
        /// immediate reconnect can recreate it under the same GUID. The engine's `on_exit` still fires.
        pub async fn stop(mut self) {
            self.token.cancel();
            tokio::task::block_in_place(|| self.routes.remove());
            if tokio::time::timeout(std::time::Duration::from_secs(3), &mut self.task).await.is_err() {
                // Still holding the adapter would make the next start fail to recreate it under the same GUID.
                log::warn!("engine did not stop within 3 s; aborting it");
                self.engine.abort();
                let _ = tokio::time::timeout(std::time::Duration::from_secs(2), self.task).await;
            }
        }

        /// (up, down) bytes through this session's adapter so far.
        pub fn traffic(&self) -> (u64, u64) {
            interface_octets(self.tun_index).unwrap_or((0, 0))
        }

        /// Is the bypass route to the server still in place on the physical interface? When it is gone (adapter
        /// reset, Wi-Fi dropped), the engine's own connection to the server would loop into the tunnel.
        pub fn bypass_intact(&self) -> bool {
            routing::best_route(self.server.ip(), None).is_ok_and(|v| v.if_index == self.via.if_index)
        }

        /// The physical side changed under us (adapter gone, or a different network on it)?
        pub fn network_changed(&self) -> bool {
            let now_via = routing::best_route(self.server.ip(), None).ok();
            now_via.map(|v| v.if_index) != Some(self.via.if_index) || routing::path_fingerprint(self.via) != self.fingerprint
        }
    }

    pub fn cleanup_stale(pending_bypass: Option<&str>) {
        routing::cleanup_stale(pending_bypass);
    }
}

/// Non-Windows builds exist only so the platform-independent parts can be unit-tested on a Mac.
#[cfg(not(windows))]
pub use stub::*;

#[cfg(not(windows))]
mod stub {
    use super::*;

    pub struct Session {
        pub server: SocketAddr,
        pub ipv6_tunnelled: bool,
    }

    pub async fn start(
        _config: &ClientConfig,
        _on_exit: impl FnOnce(Result<(), String>) + Send + 'static,
    ) -> Result<Session, String> {
        Err("the tunnel only runs on Windows".into())
    }

    impl Session {
        pub fn bypass_record(&self) -> String {
            String::new()
        }
        pub async fn stop(self) {}
        pub fn network_changed(&self) -> bool {
            false
        }
        pub fn traffic(&self) -> (u64, u64) {
            (0, 0)
        }
        pub fn bypass_intact(&self) -> bool {
            true
        }
    }

    pub fn cleanup_stale(_pending_bypass: Option<&str>) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use tun2proxy::{ArgDns, ProxyType};

    #[test]
    fn args_match_the_apple_engine_and_keep_credentials_intact() {
        let config = ClientConfig { host: "phone.local".into(), port: 1080, username: "a@b".into(), password: "p:w/d%?#".into() };
        let args = engine_args(&config, "192.168.1.9:1080".parse().unwrap());
        assert_eq!(args.proxy.proxy_type, ProxyType::Socks5);
        assert_eq!(args.proxy.addr, "192.168.1.9:1080".parse::<SocketAddr>().unwrap());
        let creds = args.proxy.credentials.expect("credentials");
        assert_eq!((creds.username.as_str(), creds.password.as_str()), ("a@b", "p:w/d%?#"));
        assert!(matches!(args.dns, ArgDns::Virtual));
        assert_eq!(args.tcp_mss, Some(TCP_MSS));
        assert!(!args.setup);
        assert_eq!((args.max_sessions, args.udp_timeout), (1000, 120));
    }

    #[test]
    fn no_credentials_when_no_username() {
        let config = ClientConfig { host: "h".into(), port: 1, username: String::new(), password: String::new() };
        let args = engine_args(&config, "[fe80::1]:1080".parse().unwrap());
        assert!(args.proxy.credentials.is_none());
        assert!(args.proxy.addr.is_ipv6());
    }
}
