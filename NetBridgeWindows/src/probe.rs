//! Health probe for the NetBridge server.
//!
//! A TCP connect is NOT enough: a suspended iOS relay keeps accepting TCP but never answers SOCKS5, so a connect-only
//! probe calls a dead server healthy. This probe runs the real SOCKS5 greeting (plus RFC 1929 auth when credentials
//! are set) and then asks for a UDP ASSOCIATE, so "Answering" means both TCP relaying and UDP relaying would be
//! accepted right now. It dials the pinned server address, which the bypass route sends over the physical
//! interface, never through the tunnel.

use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeResult {
    /// SOCKS5 answered (and accepted our credentials). `udp` is whether it granted a UDP ASSOCIATE.
    Answering { udp: bool },
    /// The server answered SOCKS5 but refused our credentials / offered methods.
    AuthRejected(String),
    /// No usable SOCKS5 answer: refused, timed out, closed, or spoke something else.
    NotAnswering(String),
}

pub async fn probe(server: SocketAddr, credentials: Option<(&str, &str)>, timeout: Duration) -> ProbeResult {
    match tokio::time::timeout(timeout, run(server, credentials)).await {
        Ok(result) => result,
        Err(_) => ProbeResult::NotAnswering(format!("no SOCKS5 reply within {} s", timeout.as_secs_f32())),
    }
}

async fn run(server: SocketAddr, credentials: Option<(&str, &str)>) -> ProbeResult {
    let mut s = match TcpStream::connect(server).await {
        Ok(s) => s,
        Err(e) => return ProbeResult::NotAnswering(format!("connect: {e}")),
    };
    let _ = s.set_nodelay(true);
    let io = |e: std::io::Error| ProbeResult::NotAnswering(format!("handshake: {e}"));

    // Greeting: offer no-auth, plus username/password when we have credentials.
    let greeting: &[u8] = if credentials.is_some() { &[5, 2, 0x00, 0x02] } else { &[5, 1, 0x00] };
    if let Err(e) = s.write_all(greeting).await {
        return io(e);
    }
    let mut choice = [0u8; 2];
    if let Err(e) = s.read_exact(&mut choice).await {
        return io(e);
    }
    if choice[0] != 5 {
        return ProbeResult::NotAnswering(format!("not a SOCKS5 server (version byte {})", choice[0]));
    }
    match choice[1] {
        0x00 => {}
        0x02 => {
            let Some((user, pass)) = credentials else {
                return ProbeResult::AuthRejected("server requires a username and password".into());
            };
            if user.len() > 255 || pass.len() > 255 {
                return ProbeResult::AuthRejected("username or password longer than 255 bytes".into());
            }
            let mut req = vec![1, user.len() as u8];
            req.extend_from_slice(user.as_bytes());
            req.push(pass.len() as u8);
            req.extend_from_slice(pass.as_bytes());
            if let Err(e) = s.write_all(&req).await {
                return io(e);
            }
            let mut status = [0u8; 2];
            if let Err(e) = s.read_exact(&mut status).await {
                return io(e);
            }
            if status[1] != 0 {
                return ProbeResult::AuthRejected("wrong username or password".into());
            }
        }
        0xFF => return ProbeResult::AuthRejected("server accepts none of the offered sign-in methods".into()),
        m => return ProbeResult::NotAnswering(format!("server chose unsupported method {m}")),
    }

    // UDP ASSOCIATE with an unspecified client address (RFC 1928 §7). The association ends when we close.
    if let Err(e) = s.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).await {
        return io(e);
    }
    let mut head = [0u8; 4];
    if let Err(e) = s.read_exact(&mut head).await {
        return io(e);
    }
    let udp = head[0] == 5 && head[1] == 0;
    // Drain the bound address so the server sees a clean close rather than a reset with unread data.
    let rest = match head[3] {
        1 => 4 + 2,
        4 => 16 + 2,
        3 => {
            let mut len = [0u8; 1];
            if s.read_exact(&mut len).await.is_err() {
                return ProbeResult::Answering { udp };
            }
            len[0] as usize + 2
        }
        _ => 0,
    };
    if udp && rest > 0 {
        let mut buf = vec![0u8; rest];
        let _ = s.read_exact(&mut buf).await;
    }
    let _ = s.shutdown().await;
    ProbeResult::Answering { udp }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[derive(Clone, Copy)]
    enum Mode {
        Healthy { require_auth: bool, udp: bool },
        /// Accepts TCP and reads, never writes: what a suspended iOS relay looks like.
        Silent,
        RejectAll,
    }

    async fn fake_server(mode: Mode) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut hdr = [0u8; 2];
                    if s.read_exact(&mut hdr).await.is_err() {
                        return;
                    }
                    let mut methods = vec![0u8; hdr[1] as usize];
                    let _ = s.read_exact(&mut methods).await;
                    match mode {
                        Mode::Silent => {
                            let mut sink = [0u8; 64];
                            while let Ok(n) = s.read(&mut sink).await {
                                if n == 0 {
                                    break;
                                }
                            }
                        }
                        Mode::RejectAll => {
                            let _ = s.write_all(&[5, 0xFF]).await;
                        }
                        Mode::Healthy { require_auth, udp } => {
                            if require_auth {
                                if !methods.contains(&2) {
                                    let _ = s.write_all(&[5, 0xFF]).await;
                                    return;
                                }
                                let _ = s.write_all(&[5, 2]).await;
                                let mut v = [0u8; 2];
                                let _ = s.read_exact(&mut v).await;
                                let mut user = vec![0u8; v[1] as usize];
                                let _ = s.read_exact(&mut user).await;
                                let mut pl = [0u8; 1];
                                let _ = s.read_exact(&mut pl).await;
                                let mut pass = vec![0u8; pl[0] as usize];
                                let _ = s.read_exact(&mut pass).await;
                                let ok = user == b"alice" && pass == b"pw";
                                let _ = s.write_all(&[1, if ok { 0 } else { 1 }]).await;
                                if !ok {
                                    return;
                                }
                            } else {
                                let _ = s.write_all(&[5, 0]).await;
                            }
                            let mut req = [0u8; 10];
                            let _ = s.read_exact(&mut req).await;
                            assert_eq!(req[1], 3, "probe must ask for UDP ASSOCIATE");
                            let rep = if udp { 0 } else { 7 };
                            let _ = s.write_all(&[5, rep, 0, 1, 127, 0, 0, 1, 0x1F, 0x90]).await;
                            let mut sink = [0u8; 8];
                            let _ = s.read(&mut sink).await;
                        }
                    }
                });
            }
        });
        addr
    }

    const T: Duration = Duration::from_millis(800);

    #[tokio::test]
    async fn healthy_no_auth_with_udp() {
        let a = fake_server(Mode::Healthy { require_auth: false, udp: true }).await;
        assert_eq!(probe(a, None, T).await, ProbeResult::Answering { udp: true });
    }

    #[tokio::test]
    async fn healthy_but_udp_refused() {
        let a = fake_server(Mode::Healthy { require_auth: false, udp: false }).await;
        assert_eq!(probe(a, None, T).await, ProbeResult::Answering { udp: false });
    }

    #[tokio::test]
    async fn auth_accepted() {
        let a = fake_server(Mode::Healthy { require_auth: true, udp: true }).await;
        assert_eq!(probe(a, Some(("alice", "pw")), T).await, ProbeResult::Answering { udp: true });
    }

    #[tokio::test]
    async fn wrong_password_is_auth_rejected() {
        let a = fake_server(Mode::Healthy { require_auth: true, udp: true }).await;
        assert!(matches!(probe(a, Some(("alice", "nope")), T).await, ProbeResult::AuthRejected(_)));
    }

    #[tokio::test]
    async fn missing_credentials_is_auth_rejected() {
        let a = fake_server(Mode::Healthy { require_auth: true, udp: true }).await;
        assert!(matches!(probe(a, None, T).await, ProbeResult::AuthRejected(_)));
    }

    #[tokio::test]
    async fn accepts_tcp_but_silent_is_not_answering() {
        let a = fake_server(Mode::Silent).await;
        let started = std::time::Instant::now();
        assert!(matches!(probe(a, None, T).await, ProbeResult::NotAnswering(_)));
        assert!(started.elapsed() < T + Duration::from_millis(500), "probe must honour its timeout");
    }

    #[tokio::test]
    async fn reject_all_methods() {
        let a = fake_server(Mode::RejectAll).await;
        assert!(matches!(probe(a, None, T).await, ProbeResult::AuthRejected(_)));
    }

    #[tokio::test]
    async fn nothing_listening_is_not_answering() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let a = l.local_addr().unwrap();
        drop(l);
        assert!(matches!(probe(a, None, T).await, ProbeResult::NotAnswering(_)));
    }
}
