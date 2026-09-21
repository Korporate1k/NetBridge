//! Offline regression test for ipstack patch 0004 (no tunnel involved).
//!
//! Field failure: the packet-tunnel extension died ("Plugin failed") with
//!   `failed to run tun2proxy with error: IpStack(AcceptError)` then `Forcing exit now.`
//! Darwin fails a nonblocking AF_UNIX SOCK_DGRAM write with ENOBUFS (os error 55) once the reader falls ~1 MB behind
//! (measured: ~689 full-size datagrams). ipstack ended its whole loop on that one failed write.
use ipstack::{IpStack, IpStackConfig, IpStackStream};
use std::{
    io,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::time::{sleep, timeout};

#[derive(Clone, Copy)]
enum Fail {
    Enobufs,
    /// What Darwin actually reports on this transport once the peer closes (measured): ECONNRESET on recv,
    /// EDESTADDRREQ on send. The earlier version of this test injected `BrokenPipe`, which the real socketpair
    /// never produces — so it passed while the production classification of these two was wrong.
    ConnReset,
    DestAddrRequired,
}

/// Feeds one UDP packet, fails the first `fail_writes` writes, then accepts and records writes.
struct FlakyDevice {
    first_packet: Option<Vec<u8>>,
    fail_writes: usize,
    fail: Fail,
    written: Arc<Mutex<Vec<Vec<u8>>>>,
}

impl AsyncRead for FlakyDevice {
    fn poll_read(mut self: Pin<&mut Self>, _cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        match self.first_packet.take() {
            Some(p) => {
                buf.put_slice(&p);
                Poll::Ready(Ok(()))
            }
            None => Poll::Pending,
        }
    }
}

impl AsyncWrite for FlakyDevice {
    fn poll_write(mut self: Pin<&mut Self>, _cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        if self.fail_writes > 0 {
            self.fail_writes -= 1;
            return Poll::Ready(Err(match self.fail {
                Fail::Enobufs => io::Error::from_raw_os_error(55),         // Darwin ENOBUFS
                Fail::ConnReset => io::Error::from_raw_os_error(54),       // Darwin ECONNRESET
                Fail::DestAddrRequired => io::Error::from_raw_os_error(39), // Darwin EDESTADDRREQ
            }));
        }
        self.written.lock().unwrap().push(buf.to_vec());
        Poll::Ready(Ok(buf.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

fn udp_packet(payload: &[u8]) -> Vec<u8> {
    let b = etherparse::PacketBuilder::ipv4([10, 0, 0, 2], [8, 8, 8, 8], 64).udp(5000, 53);
    let mut out = Vec::with_capacity(b.size(payload.len()));
    b.write(&mut out, payload).unwrap();
    out
}

async fn start(fail_writes: usize, fail: Fail) -> (IpStack, ipstack::IpStackUdpStream, Arc<Mutex<Vec<Vec<u8>>>>) {
    let written = Arc::new(Mutex::new(Vec::new()));
    let dev = FlakyDevice { first_packet: Some(udp_packet(b"ping")), fail_writes, fail, written: written.clone() };
    let mut stack = IpStack::new(IpStackConfig::default(), dev);
    let stream = timeout(Duration::from_secs(2), stack.accept()).await.expect("accept timed out").expect("accept failed");
    let IpStackStream::Udp(udp) = stream else { panic!("expected a UDP stream") };
    (stack, udp, written)
}

/// A transient write error (ENOBUFS) must drop one packet, not end the stack.
#[tokio::test]
async fn transient_enobufs_write_does_not_kill_the_stack() {
    let (mut stack, mut udp, written) = start(1, Fail::Enobufs).await;

    let _ = udp.write_all(b"first").await; // its packet hits ENOBUFS
    sleep(Duration::from_millis(100)).await;
    let _ = udp.write_all(b"second").await; // must still get through

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while written.lock().unwrap().is_empty() && tokio::time::Instant::now() < deadline {
        sleep(Duration::from_millis(20)).await;
    }
    assert!(!written.lock().unwrap().is_empty(), "nothing was delivered after a transient ENOBUFS write error");

    // accept() must still be pending. `AcceptError` here is the exact field failure.
    let r = timeout(Duration::from_millis(300), stack.accept()).await;
    assert!(r.is_err(), "ip stack died after one transient write error: accept() returned {:?}", r.map(|x| x.map(|_| ())));
}

/// A short ENOBUFS burst must be *retried*, not dropped. Only one packet is ever offered here, so if the retry
/// budget were not there this device would see nothing at all.
#[tokio::test]
async fn a_short_enobufs_burst_is_retried_not_dropped() {
    let (_stack, mut udp, written) = start(3, Fail::Enobufs).await;

    let _ = udp.write_all(b"first").await;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while written.lock().unwrap().is_empty() && tokio::time::Instant::now() < deadline {
        sleep(Duration::from_millis(20)).await;
    }
    let packets = written.lock().unwrap();
    assert!(!packets.is_empty(), "the only packet was dropped instead of retried through a 3-write ENOBUFS burst");
    assert!(
        packets.iter().any(|p| p.ends_with(b"first")),
        "the retried packet did not carry the original payload"
    );
}

/// A device that is really gone must still end the stack (and not spin). ECONNRESET is what a closed peer
/// actually produces on this transport, and treating it as transient is how a dead device becomes a tunnel that
/// reports Connected while carrying nothing.
#[tokio::test]
async fn econnreset_ends_the_stack() {
    let (mut stack, mut udp, _written) = start(usize::MAX, Fail::ConnReset).await;
    let _ = udp.write_all(b"first").await;
    let r = timeout(Duration::from_secs(5), stack.accept()).await.expect("stack did not stop after ECONNRESET");
    assert!(r.is_err(), "accept() should fail once the device is gone");
}

/// The send-side counterpart: Darwin reports EDESTADDRREQ (39) when writing to a socketpair whose peer is gone.
/// Rust has no `ErrorKind` for it, so it decodes as `Uncategorized` and only an explicit errno check catches it.
#[tokio::test]
async fn edestaddrrequired_ends_the_stack() {
    let (mut stack, mut udp, _written) = start(usize::MAX, Fail::DestAddrRequired).await;
    let _ = udp.write_all(b"first").await;
    let r = timeout(Duration::from_secs(5), stack.accept()).await.expect("stack did not stop after EDESTADDRREQ");
    assert!(r.is_err(), "accept() should fail once the device is gone");
}
