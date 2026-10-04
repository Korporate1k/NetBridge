//! SOCKS5 health probe: a port of `Socks5Probe` in NetBridgeTunnel/PacketTunnelProvider.swift (and the Windows
//! client's probe.rs). Greeting (no-auth, plus username/password when a user is set), RFC 1929 sign-in if the server
//! picks it, then UDP ASSOCIATE, all under ONE deadline, so a server that accepts TCP and then stays silent (a
//! suspended iOS relay) reads as "not answering" within the timeout. A plain TCP-connect check would call it healthy.
//!
//!   nb-probe HOST PORT [--user U] [--pass P] [--timeout SECONDS]      (user/pass default to $NB_USER / $NB_PASS)
//!
//! HOST must be an IP address (no DNS: a hostname lookup can't be bounded by the deadline). SECONDS: 0.1 to 3600,
//! default 5. Prefer the environment for the password: arguments are visible in the process list.
//!
//! Prints one line, `state=<answering|auth_rejected|not_answering> udp=<yes|no|unknown> detail="..."`, and exits:
//!   0 answering and UDP ASSOCIATE granted    3 answering but UDP refused
//!   2 server refused our credentials         1 not answering (refused, timed out, closed, not SOCKS5)
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::process::exit;
use std::time::{Duration, Instant};

enum Verdict {
    Answering { udp: bool },
    AuthRejected(String),
    NotAnswering(String),
}

struct Io {
    stream: TcpStream,
    deadline: Instant,
    timeout: f64,
}

impl Io {
    fn remaining(&self, what: &str) -> Result<Duration, Verdict> {
        let now = Instant::now();
        if now >= self.deadline {
            return Err(Verdict::NotAnswering(format!("no SOCKS5 reply within {} s ({})", self.timeout, what)));
        }
        Ok(self.deadline - now)
    }
    fn write(&mut self, bytes: &[u8]) -> Result<(), Verdict> {
        let left = self.remaining("send")?;
        self.stream.set_write_timeout(Some(left)).ok();
        self.stream.write_all(bytes).map_err(|e| Verdict::NotAnswering(format!("handshake: send {e}")))
    }
    fn read(&mut self, n: usize) -> Result<Vec<u8>, Verdict> {
        let mut buf = vec![0u8; n];
        let mut got = 0;
        while got < n {
            let left = self.remaining("reply")?;
            self.stream.set_read_timeout(Some(left)).ok();
            match self.stream.read(&mut buf[got..]) {
                Ok(0) => return Err(Verdict::NotAnswering("handshake: server closed the connection".into())),
                Ok(k) => got += k,
                // SO_RCVTIMEO expiry (our deadline) is EAGAIN = WouldBlock; TimedOut is the kernel giving up on the
                // connection itself (retransmissions), which deserves its own message.
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    return Err(Verdict::NotAnswering(format!("no SOCKS5 reply within {} s (reply)", self.timeout)))
                }
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    return Err(Verdict::NotAnswering(format!("handshake: connection timed out ({e})")))
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(Verdict::NotAnswering(format!("handshake: recv {e}"))),
            }
        }
        Ok(buf)
    }
}

fn probe(addr: SocketAddr, user: &str, pass: &str, timeout: f64) -> Verdict {
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);
    let stream = match TcpStream::connect_timeout(&addr, Duration::from_secs_f64(timeout)) {
        Ok(s) => s,
        Err(e) => return Verdict::NotAnswering(format!("connect: {e}")),
    };
    stream.set_nodelay(true).ok();
    let mut io = Io { stream, deadline, timeout };
    match run(&mut io, user, pass) {
        Ok(v) | Err(v) => v,
    }
}

fn run(io: &mut Io, user: &str, pass: &str) -> Result<Verdict, Verdict> {
    let with_auth = !user.is_empty();
    io.write(if with_auth { &[5, 2, 0x00, 0x02] } else { &[5, 1, 0x00] })?;
    let choice = io.read(2)?;
    if choice[0] != 5 {
        return Err(Verdict::NotAnswering(format!("not a SOCKS5 server (version byte {})", choice[0])));
    }
    match choice[1] {
        0x00 => {}
        0x02 => {
            if !with_auth {
                return Err(Verdict::AuthRejected("server requires a username and password".into()));
            }
            if user.len() > 255 || pass.len() > 255 {
                return Err(Verdict::AuthRejected("username or password longer than 255 bytes".into()));
            }
            let mut msg = vec![1, user.len() as u8];
            msg.extend_from_slice(user.as_bytes());
            msg.push(pass.len() as u8);
            msg.extend_from_slice(pass.as_bytes());
            io.write(&msg)?;
            let status = io.read(2)?;
            if status[1] != 0 {
                return Err(Verdict::AuthRejected("wrong username or password".into()));
            }
        }
        0xFF => return Err(Verdict::AuthRejected("server accepts none of the offered sign-in methods".into())),
        m => return Err(Verdict::NotAnswering(format!("server chose unsupported method {m}"))),
    }
    // UDP ASSOCIATE with an unspecified client address (RFC 1928 section 7); it ends when we close.
    io.write(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0])?;
    let head = io.read(4)?;
    let udp = head[0] == 5 && head[1] == 0;
    if udp {
        // Drain the bound address so the server sees a clean close rather than a reset with unread data.
        match head[3] {
            1 => drop(io.read(4 + 2)),
            4 => drop(io.read(16 + 2)),
            3 => {
                if let Ok(l) = io.read(1) {
                    drop(io.read(l[0] as usize + 2))
                }
            }
            _ => {}
        }
    }
    let _ = io.stream.shutdown(std::net::Shutdown::Both);
    Ok(Verdict::Answering { udp })
}

fn usage() -> ! {
    eprintln!("usage: nb-probe HOST(IP address) PORT [--user U] [--pass P] [--timeout SECONDS(0.1-3600)]");
    exit(64);
}

/// The detail is printed inside double quotes and parsed by the watchdog with sed: keep it on one line, without quotes
/// or backslashes.
fn clean(detail: &str) -> String {
    detail
        .chars()
        .map(|c| match c {
            '"' => '\'',
            '\\' => '/',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect()
}

fn report(state: &str, udp: &str, detail: &str, code: i32) -> ! {
    println!("state={state} udp={udp} detail=\"{}\"", clean(detail));
    exit(code)
}

fn main() {
    // lossy: a non-UTF-8 argument or variable must not abort the probe
    let mut args = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned());
    let host = args.next().unwrap_or_else(|| usage());
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or_else(|| usage());
    let env = |k: &str| std::env::var_os(k).map(|v| v.to_string_lossy().into_owned()).unwrap_or_default();
    let mut user = env("NB_USER");
    let mut pass = env("NB_PASS");
    let mut timeout = 5.0f64;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--user" => user = args.next().unwrap_or_else(|| usage()),
            "--pass" => pass = args.next().unwrap_or_else(|| usage()),
            "--timeout" => timeout = args.next().and_then(|t| t.parse().ok()).unwrap_or_else(|| usage()),
            _ => usage(),
        }
    }
    // finite and in range, or Duration::from_secs_f64 / Instant + Duration would panic (abort) on inf or huge values
    if !timeout.is_finite() || !(0.1..=3600.0).contains(&timeout) {
        usage();
    }
    let ip: IpAddr = match host.parse() {
        Ok(ip) => ip,
        Err(_) => report("not_answering", "unknown", &format!("HOST must be an IP address, got {host}"), 1),
    };
    match probe(SocketAddr::new(ip, port), &user, &pass, timeout) {
        Verdict::Answering { udp: true } => report("answering", "yes", "UDP ASSOCIATE granted", 0),
        Verdict::Answering { udp: false } => report("answering", "no", "UDP ASSOCIATE refused", 3),
        Verdict::AuthRejected(d) => report("auth_rejected", "unknown", &d, 2),
        Verdict::NotAnswering(d) => report("not_answering", "unknown", &d, 1),
    }
}
