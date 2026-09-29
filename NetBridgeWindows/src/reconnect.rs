//! Auto-reconnect policy, the same rules as `MacClientModel` on macOS:
//! - only a session that was up and ended with an error the user did not cause is retried;
//! - retries wait 2 s, 5 s, 15 s, then give up;
//! - earlier attempts are forgiven only after a session that has been up 60 s *and* whose latest health probe got a
//!   real SOCKS5 answer from the proxy. A tunnel can sit "connected" while the proxy is unreachable, so time alone
//!   would let a fault spaced > 60 s apart retry forever. Downlink bytes are no proof either: with virtual DNS the
//!   engine answers every DNS query itself, so bytes flow into the adapter even when the proxy is dead. A byte
//!   condition on top of the probe adds nothing (DNS alone satisfies it), so it is not used.

use std::time::Duration;

pub const DELAYS: [Duration; 3] = [Duration::from_secs(2), Duration::from_secs(5), Duration::from_secs(15)];
pub const HEALTHY_AFTER: Duration = Duration::from_secs(60);

#[derive(Debug, Default)]
pub struct Reconnector {
    attempts: usize,
}

impl Reconnector {
    /// The user pressed Connect: start with a fresh budget.
    pub fn reset(&mut self) {
        self.attempts = 0;
    }

    pub fn attempts(&self) -> usize {
        self.attempts
    }

    /// Called while connected, with the session's uptime and whether the latest health probe of THIS session got a
    /// SOCKS5 answer from the proxy (`ProbeResult::Answering`). Not bytes: see the module comment.
    pub fn note_progress(&mut self, uptime: Duration, proxy_answering: bool) {
        if self.attempts > 0 && proxy_answering && uptime >= HEALTHY_AFTER {
            log::info!("session healthy ({} s up, proxy answering); clearing reconnect attempts", uptime.as_secs());
            self.attempts = 0;
        }
    }

    /// A session ended. Returns how long to wait before reconnecting, or None to stay disconnected.
    pub fn on_session_end(&mut self, user_requested: bool, failed: bool) -> Option<Duration> {
        if user_requested || !failed {
            return None;
        }
        let delay = *DELAYS.get(self.attempts)?;
        self.attempts += 1;
        Some(delay)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backs_off_then_gives_up() {
        let mut r = Reconnector::default();
        assert_eq!(r.on_session_end(false, true), Some(Duration::from_secs(2)));
        assert_eq!(r.on_session_end(false, true), Some(Duration::from_secs(5)));
        assert_eq!(r.on_session_end(false, true), Some(Duration::from_secs(15)));
        assert_eq!(r.on_session_end(false, true), None);
        assert_eq!(r.attempts(), 3);
    }

    #[test]
    fn user_stop_and_clean_exit_never_reconnect() {
        let mut r = Reconnector::default();
        assert_eq!(r.on_session_end(true, true), None);
        assert_eq!(r.on_session_end(false, false), None);
        assert_eq!(r.attempts(), 0);
    }

    #[test]
    fn forgiven_only_after_a_long_session_with_the_proxy_answering() {
        let mut r = Reconnector::default();
        r.on_session_end(false, true);
        r.on_session_end(false, true);
        // Long, but the proxy never answered (dead relay; virtual DNS still moves bytes): not forgiven.
        r.note_progress(Duration::from_secs(600), false);
        assert_eq!(r.attempts(), 2);
        // Proxy answering, but not up long enough yet: not forgiven.
        r.note_progress(Duration::from_secs(59), true);
        assert_eq!(r.attempts(), 2);
        r.note_progress(Duration::from_secs(60), true);
        assert_eq!(r.attempts(), 0);
        assert_eq!(r.on_session_end(false, true), Some(Duration::from_secs(2)));
    }

    #[test]
    fn dead_proxy_spaced_drops_still_give_up() {
        // Each session lasts well over 60 s but the proxy never answers: the budget must still run out.
        let mut r = Reconnector::default();
        let mut delays = Vec::new();
        for _ in 0..5 {
            r.note_progress(Duration::from_secs(300), false);
            delays.push(r.on_session_end(false, true));
        }
        let secs: Vec<_> = delays.iter().map(|d| d.map(|d| d.as_secs())).collect();
        assert_eq!(secs, [Some(2), Some(5), Some(15), None, None]);
    }

    #[test]
    fn nothing_to_forgive_is_a_no_op() {
        let mut r = Reconnector::default();
        r.note_progress(Duration::from_secs(600), true);
        assert_eq!(r.attempts(), 0);
    }

    #[test]
    fn reset_restores_the_budget() {
        let mut r = Reconnector::default();
        for _ in 0..4 {
            r.on_session_end(false, true);
        }
        r.reset();
        assert_eq!(r.on_session_end(false, true), Some(Duration::from_secs(2)));
    }
}
