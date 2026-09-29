//! The tunnel adapter, driven through wintun-bindings directly instead of the `tun` crate's AsyncDevice.
//!
//! Why: `tun`'s async read (wintun-bindings `AsyncSession`) tries the ring once and, if it is empty, parks a
//! `WaitForMultipleObjects` on the `blocking` crate's thread pool, then wakes the tokio worker from there: three
//! cross-thread hand-offs every time the ring drains, plus a pool thread spawn after 500 ms idle. With TCP flows
//! capped at 64 KB in flight the ring drains constantly, so that path set the pace. Here one dedicated thread loops
//! on `receive_blocking` (which spins on the ring five times before waiting) and feeds a channel that `poll_read`
//! drains; writes go straight into the send ring, as before.
//!
//! Adapter setup mirrors what `tun::create_as_async` did (open or create by name with a fixed GUID, wait for the IPv4
//! interface, address + mask, MTU, DNS), minus the default route through the adapter it used to add: our /1 routes
//! (routing.rs) are what capture traffic.

use std::io;
use std::net::{IpAddr, Ipv4Addr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;
use windows_sys::Win32::NetworkManagement::IpHelper::{GetIpInterfaceEntry, InitializeIpInterfaceEntry, MIB_IPINTERFACE_ROW};
use windows_sys::Win32::Networking::WinSock::AF_INET;
use wintun_bindings::{Adapter, MAX_RING_CAPACITY, Session};

/// Packets queued between the reader thread and the engine. Bounded so a stalled engine pushes back on the ring
/// (wintun drops at the ring, like a full NIC queue) instead of growing memory without limit.
const QUEUE: usize = 4096;

pub struct AdapterSpec<'a> {
    pub name: &'a str,
    pub guid: u128,
    pub wintun_dll: &'a std::path::Path,
    pub address: Ipv4Addr,
    pub prefix_len: u8,
    pub mtu: u16,
    pub dns: IpAddr,
}

pub struct WintunDevice {
    session: Arc<Session>,
    index: u32,
    rx: mpsc::Receiver<Vec<u8>>,
    reader: Option<std::thread::JoinHandle<()>>,
}

impl WintunDevice {
    /// Blocking (adapter creation and interface setup take a moment); call via `block_in_place`.
    pub fn create(spec: &AdapterSpec) -> io::Result<WintunDevice> {
        let err = |what: &str, e: wintun_bindings::Error| io::Error::other(format!("{what}: {e}"));
        // SAFETY: the path is our own wintun.dll next to the exe (see engine::wintun_path).
        let wintun = unsafe { wintun_bindings::load_from_path(spec.wintun_dll) }.map_err(|e| err("load wintun.dll", e))?;
        let adapter = match Adapter::open(&wintun, spec.name) {
            Ok(a) => a,
            Err(_) => Adapter::create(&wintun, spec.name, spec.name, Some(spec.guid)).map_err(|e| err("create adapter", e))?,
        };
        // SAFETY: NET_LUID_LH is a union over a u64; Value is always valid to read.
        let luid = unsafe { adapter.get_luid().Value };
        wait_for_ipv4_interface(luid, Duration::from_secs(5))?;
        let index = adapter.get_adapter_index().map_err(|e| err("adapter index", e))?;
        crate::routing::add_address(index, IpAddr::V4(spec.address), spec.prefix_len)?;
        adapter.set_mtu(spec.mtu as usize).map_err(|e| err("set MTU", e))?;
        adapter.set_dns_servers(&[spec.dns]).map_err(|e| err("set DNS", e))?;
        let session = adapter.start_session(MAX_RING_CAPACITY).map_err(|e| err("start session", e))?;

        let (tx, rx) = mpsc::channel(QUEUE);
        let reader_session = session.clone();
        let reader = std::thread::Builder::new()
            .name("netbridge-wintun-rx".into())
            .spawn(move || {
                loop {
                    match reader_session.receive_blocking() {
                        Ok(packet) => {
                            if tx.blocking_send(packet.bytes().to_vec()).is_err() {
                                break; // device dropped
                            }
                        }
                        Err(e) => {
                            log::debug!("wintun reader stopping: {e}");
                            break; // session shut down (or gone)
                        }
                    }
                }
            })?;
        Ok(WintunDevice { session, index, rx, reader: Some(reader) })
    }

    pub fn index(&self) -> u32 {
        self.index
    }
}

impl AsyncRead for WintunDevice {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        match self.rx.poll_recv(cx) {
            Poll::Ready(Some(packet)) => {
                let n = packet.len().min(buf.remaining());
                buf.put_slice(&packet[..n]);
                Poll::Ready(Ok(()))
            }
            // The reader thread ended: the session is gone. BrokenPipe makes the engine stop (patch 0004) instead
            // of spinning on zero-length reads.
            Poll::Ready(None) => Poll::Ready(Err(io::ErrorKind::BrokenPipe.into())),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWrite for WintunDevice {
    fn poll_write(self: Pin<&mut Self>, _cx: &mut Context<'_>, data: &[u8]) -> Poll<io::Result<usize>> {
        let len = u16::try_from(data.len()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        match self.session.allocate_send_packet(len) {
            Ok(mut packet) => {
                packet.bytes_mut().copy_from_slice(data);
                self.session.send_packet(packet);
                Poll::Ready(Ok(data.len()))
            }
            // A full send ring: the engine's device-error handling (patch 0004) drops this packet and carries on.
            Err(e) => Poll::Ready(Err(io::Error::other(format!("wintun send: {e}")))),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl Drop for WintunDevice {
    fn drop(&mut self) {
        // Wakes receive_blocking with an error so the reader thread exits; the session and adapter (and with it the
        // adapter's routes) are released when their last Arc goes.
        let _ = self.session.shutdown();
        self.rx.close();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn wait_for_ipv4_interface(luid: u64, timeout: Duration) -> io::Result<()> {
    let started = Instant::now();
    loop {
        let mut row: MIB_IPINTERFACE_ROW = unsafe { std::mem::zeroed() };
        // SAFETY: row is a zeroed MIB_IPINTERFACE_ROW, initialised by the API before use.
        unsafe { InitializeIpInterfaceEntry(&mut row) };
        row.Family = AF_INET;
        row.InterfaceLuid.Value = luid;
        // SAFETY: row is initialised with family and LUID set, as GetIpInterfaceEntry requires.
        if unsafe { GetIpInterfaceEntry(&mut row) } == 0 {
            return Ok(());
        }
        if started.elapsed() >= timeout {
            return Err(io::Error::other("the tunnel adapter's IPv4 interface did not appear"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
