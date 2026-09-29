//! Connection state machine. Runs on its own thread + tokio runtime, independent of the UI, so the tray menu and
//! auto-reconnect keep working while the window is minimised. The UI sends `Command`s and renders `Snapshot`s.

use crate::config::{self, ClientConfig};
use crate::engine::{self, Session};
use crate::probe::{self, ProbeResult};
use crate::reconnect::Reconnector;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

pub const PROBE_EVERY: Duration = Duration::from_secs(20);
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// Minimum spacing between automatic restarts after the physical network changed under the tunnel.
pub const NETWORK_RESTART_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnState {
    Disconnected,
    Connecting,
    Connected,
    /// Waiting to retry after an unexpected drop (attempt number, starting at 1).
    Reconnecting(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Health {
    Unknown,
    Checking,
    Answering { udp: bool },
    AuthRejected(String),
    NotAnswering(String),
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub state: ConnState,
    pub server: String,
    pub connected_since: Option<Instant>,
    pub up_bytes: u64,
    pub down_bytes: u64,
    pub up_rate: f64,
    pub down_rate: f64,
    pub health: Health,
    pub last_probe: Option<Instant>,
    pub ipv6_tunnelled: bool,
    /// Last error worth showing (connect failure, drop reason). Cleared on a successful connect.
    pub message: Option<String>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            state: ConnState::Disconnected,
            server: String::new(),
            connected_since: None,
            up_bytes: 0,
            down_bytes: 0,
            up_rate: 0.0,
            down_rate: 0.0,
            health: Health::Unknown,
            last_probe: None,
            ipv6_tunnelled: false,
            message: None,
        }
    }
}

pub enum Command {
    Connect(ClientConfig),
    Disconnect,
    /// Disconnect (if needed) and end the controller thread.
    Quit,
}

enum Event {
    EngineExited { id: u64, result: Result<(), String> },
    Probed { id: u64, result: ProbeResult },
    /// A connect attempt finished. The attempt's task waits on `reply` before it ends: the worker answers None when it
    /// keeps the session, or hands a stale one back so the task stops it while still holding its place in the
    /// lifecycle chain (see `Worker::lifecycle`). Every Started must be answered.
    Started { id: u64, result: Result<Session, String>, reply: oneshot::Sender<Option<Session>> },
}

#[derive(Clone)]
pub struct Controller {
    tx: mpsc::UnboundedSender<Command>,
    snapshot: Arc<Mutex<Snapshot>>,
}

impl Controller {
    /// `repaint` is called whenever the snapshot changes.
    pub fn spawn(repaint: impl Fn() + Send + Sync + 'static) -> (Controller, std::thread::JoinHandle<()>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let shared = snapshot.clone();
        let handle = std::thread::Builder::new()
            .name("netbridge-controller".into())
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
                // Run the worker as a task so it sits on a runtime worker thread (block_in_place needs one).
                let worker = Worker::new(shared, Box::new(repaint));
                let _ = rt.block_on(async move { tokio::spawn(worker.run(rx)).await });
                // Give the engine task a moment to observe cancellation before the runtime is dropped.
                rt.shutdown_timeout(Duration::from_secs(3));
            })
            .expect("controller thread");
        (Controller { tx, snapshot }, handle)
    }

    pub fn send(&self, cmd: Command) {
        let _ = self.tx.send(cmd);
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

struct Worker {
    shared: Arc<Mutex<Snapshot>>,
    repaint: Box<dyn Fn() + Send + Sync>,
    snap: Snapshot,
    session: Option<Session>,
    session_id: u64,
    /// Mirror of `session_id` for connect tasks, so a queued attempt that is already stale skips `engine::start`.
    live_id: Arc<AtomicU64>,
    /// The connect attempt in flight, if any: (id, is_retry).
    connecting: Option<(u64, bool)>,
    /// The last spawned connect/teardown task. Each new one awaits the previous one first, so adapter and route
    /// changes never overlap (a start must not recreate the fixed-GUID adapter while an old session still holds it),
    /// while the select! loop stays free to serve Disconnect/Quit and events.
    lifecycle: Option<JoinHandle<()>>,
    config: Option<ClientConfig>,
    reconnect: Reconnector,
    reconnect_at: Option<Instant>,
    baseline: (u64, u64),
    last_totals: (u64, u64, Instant),
    next_probe: Instant,
    probe_in_flight: bool,
    reachable_this_session: bool,
    consecutive_probe_failures: u32,
    /// When the last automatic network-change restart happened; cleared once the server answers again.
    last_network_restart: Option<Instant>,
    events_tx: mpsc::UnboundedSender<Event>,
}

impl Worker {
    fn new(shared: Arc<Mutex<Snapshot>>, repaint: Box<dyn Fn() + Send + Sync>) -> Worker {
        let (events_tx, _) = mpsc::unbounded_channel();
        Worker {
            shared,
            repaint,
            snap: Snapshot::default(),
            session: None,
            session_id: 0,
            live_id: Arc::new(AtomicU64::new(0)),
            connecting: None,
            lifecycle: None,
            config: None,
            reconnect: Reconnector::default(),
            reconnect_at: None,
            baseline: (0, 0),
            last_totals: (0, 0, Instant::now()),
            next_probe: Instant::now(),
            probe_in_flight: false,
            reachable_this_session: false,
            consecutive_probe_failures: 0,
            last_network_restart: None,
            events_tx,
        }
    }

    fn publish(&self) {
        if let Ok(mut s) = self.shared.lock() {
            *s = self.snap.clone();
        }
        (self.repaint)();
    }

    /// Starts a new session id; events and connect results carrying an older id are stale from here on.
    fn next_id(&mut self) -> u64 {
        self.session_id += 1;
        self.live_id.store(self.session_id, Ordering::SeqCst);
        self.session_id
    }

    /// Queues `work` behind whatever connect/teardown is still running.
    fn chain(&mut self, work: impl std::future::Future<Output = ()> + Send + 'static) {
        let prev = self.lifecycle.take();
        self.lifecycle = Some(tokio::spawn(async move {
            if let Some(prev) = prev {
                let _ = prev.await;
            }
            work.await;
        }));
    }

    async fn run(mut self, mut commands: mpsc::UnboundedReceiver<Command>) {
        let (events_tx, mut events) = mpsc::unbounded_channel();
        self.events_tx = events_tx;

        // Undo anything a previous run left behind before touching routes again.
        let pending = config::load_pending_bypass();
        tokio::task::block_in_place(|| engine::cleanup_stale(pending.as_deref()));
        if pending.is_some() {
            config::set_pending_bypass(None);
        }

        let mut tick = tokio::time::interval(Duration::from_secs(1));
        // After a long connect/disconnect, don't fire a burst of catch-up ticks (each with a tiny dt, which showed as
        // absurd rate spikes); just resume the 1 s cadence.
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let reconnect_sleep = async {
                match self.reconnect_at {
                    Some(at) => tokio::time::sleep_until(at.into()).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                cmd = commands.recv() => match cmd {
                    Some(Command::Connect(config)) => {
                        self.reconnect.reset();
                        self.reconnect_at = None;
                        self.disconnect(true);
                        self.config = Some(config);
                        self.connect(false);
                    }
                    Some(Command::Disconnect) => {
                        self.reconnect_at = None;
                        self.disconnect(true);
                        self.snap.state = ConnState::Disconnected;
                        self.publish();
                    }
                    Some(Command::Quit) | None => {
                        self.reconnect_at = None;
                        self.disconnect(true);
                        self.finish_lifecycle(&mut events).await;
                        return;
                    }
                },
                Some(event) = events.recv() => self.handle_event(event),
                _ = reconnect_sleep => {
                    self.reconnect_at = None;
                    self.connect(true);
                }
                _ = tick.tick() => {
                    if self.on_tick() {
                        self.restart_for_network("the bypass route to the server is gone");
                    }
                }
            }
        }
    }

    /// Quit: wait for queued connects/teardowns so no routes or adapter outlive the process. A connect that lands
    /// meanwhile is stale (Quit bumped the id) and is handed back to its task to be stopped.
    async fn finish_lifecycle(&mut self, events: &mut mpsc::UnboundedReceiver<Event>) {
        let Some(mut lifecycle) = self.lifecycle.take() else { return };
        loop {
            tokio::select! {
                _ = &mut lifecycle => return,
                Some(event) = events.recv() => self.handle_event(event),
            }
        }
    }

    /// Starts a connect attempt in the background; the result comes back as `Event::Started`.
    /// `auto`: started by the controller itself (reconnect, network change), not by the user's Connect.
    fn connect(&mut self, auto: bool) {
        let Some(config) = self.config.clone() else { return };
        let is_retry = auto || self.reconnect.attempts() > 0;
        self.snap.state = ConnState::Connecting;
        self.snap.server = format!("{}:{}", config.host, config.port);
        self.snap.message = None;
        self.snap.health = Health::Unknown;
        self.snap.last_probe = None;
        self.publish();

        let id = self.next_id();
        self.connecting = Some((id, is_retry));
        let events = self.events_tx.clone();
        let live_id = self.live_id.clone();
        self.chain(async move {
            if live_id.load(Ordering::SeqCst) != id {
                log::info!("connect attempt {id} cancelled before it started");
                return;
            }
            let exit_events = events.clone();
            let result = engine::start(&config, move |result| {
                let _ = exit_events.send(Event::EngineExited { id, result });
            })
            .await;
            let (reply, returned) = oneshot::channel();
            let late = match events.send(Event::Started { id, result, reply }) {
                Ok(()) => returned.await.ok().flatten(),
                // The worker is gone: nobody will own this session.
                Err(mpsc::error::SendError(Event::Started { result, .. })) => result.ok(),
                Err(_) => None,
            };
            if let Some(session) = late {
                log::info!("connect attempt {id} finished after it was cancelled; taking it down");
                session.stop().await;
            }
        });
    }

    /// The outcome of the attempt `connect` started.
    fn on_started(&mut self, id: u64, result: Result<Session, String>) -> Option<Session> {
        let is_retry = match self.connecting {
            Some((current, is_retry)) if current == id && id == self.session_id => is_retry,
            // Cancelled by Disconnect/Quit/a newer Connect: hand a late session back to be stopped.
            _ => return result.ok(),
        };
        self.connecting = None;
        match result {
            Ok(session) => {
                config::set_pending_bypass(Some(session.bypass_record()).filter(|r| !r.is_empty()));

                self.snap.ipv6_tunnelled = session.ipv6_tunnelled;
                self.baseline = session.traffic();
                self.session = Some(session);
                self.snap.state = ConnState::Connected;
                self.snap.connected_since = Some(Instant::now());
                self.last_totals = (self.baseline.0, self.baseline.1, Instant::now());
                self.snap.up_bytes = 0;
                self.snap.down_bytes = 0;
                self.reachable_this_session = false;
                self.consecutive_probe_failures = 0;
                self.next_probe = Instant::now();
                self.publish();
            }
            Err(e) => {
                log::error!("connect failed: {e}");
                self.snap.message = Some(e);
                if is_retry {
                    // A failed retry counts against the reconnect budget like a drop does.
                    self.schedule_reconnect_or_stop(false);
                } else {
                    // The user's own Connect failed (bad address, no wintun.dll, ...): show it, don't retry.
                    self.snap.state = ConnState::Disconnected;
                    self.publish();
                }
            }
        }
        None
    }

    /// Tears the current session down (in the background, queued on the lifecycle chain) and cancels any connect
    /// attempt in flight. `user` = the user asked for it (no reconnect).
    fn disconnect(&mut self, user: bool) {
        self.next_id(); // ignore late events (and connect results) from the old session
        if let Some((id, _)) = self.connecting.take() {
            log::info!("cancelling connect attempt {id} ({})", if user { "user" } else { "internal" });
        }
        if let Some(session) = self.session.take() {
            log::info!("disconnecting ({})", if user { "user" } else { "internal" });
            self.chain(async move {
                session.stop().await;
                config::set_pending_bypass(None);
            });
        }
        self.snap.connected_since = None;
        self.snap.health = Health::Unknown;
        self.snap.up_rate = 0.0;
        self.snap.down_rate = 0.0;
        self.probe_in_flight = false;
    }

    fn schedule_reconnect_or_stop(&mut self, user: bool) {
        match self.reconnect.on_session_end(user, true) {
            Some(delay) => {
                log::warn!("reconnecting in {} s (attempt {})", delay.as_secs(), self.reconnect.attempts());
                self.reconnect_at = Some(Instant::now() + delay);
                self.snap.state = ConnState::Reconnecting(self.reconnect.attempts());
            }
            None => {
                self.snap.state = ConnState::Disconnected;
            }
        }
        self.publish();
    }

    fn handle_event(&mut self, event: Event) {
        match event {
            Event::Started { id, result, reply } => {
                let late = self.on_started(id, result);
                // The attempt's task is always waiting on this reply (it holds the lifecycle chain until answered).
                let _ = reply.send(late);
            }
            Event::EngineExited { id, result } => {
                if id != self.session_id {
                    return;
                }
                let reason = match result {
                    Ok(()) => "engine stopped".to_string(),
                    Err(e) => e,
                };
                log::error!("session dropped: {reason}");
                self.snap.message = Some(format!("Connection dropped: {reason}"));
                self.disconnect(false);
                self.schedule_reconnect_or_stop(false);
            }
            Event::Probed { id, result } => {
                if id != self.session_id {
                    return;
                }
                self.probe_in_flight = false;
                self.snap.last_probe = Some(Instant::now());
                self.snap.health = match result {
                    ProbeResult::Answering { udp } => {
                        self.reachable_this_session = true;
                        self.consecutive_probe_failures = 0;
                        self.last_network_restart = None;
                        Health::Answering { udp }
                    }
                    ProbeResult::AuthRejected(r) => {
                        self.consecutive_probe_failures = 0;
                        Health::AuthRejected(r)
                    }
                    ProbeResult::NotAnswering(r) => {
                        self.consecutive_probe_failures += 1;
                        log::warn!("server not answering ({}x): {r}", self.consecutive_probe_failures);
                        Health::NotAnswering(r)
                    }
                };
                self.publish();
                self.maybe_restart_for_network_change();
            }
        }
    }

    /// The bypass route is pinned to the network we connected on. If that network is gone, the engine can no longer
    /// reach the server and the session is dead. Restart it, with the same guards as the Mac client: the server
    /// answered earlier this session, has now failed twice running, and the physical path really changed. A relay that
    /// is merely switched off does NOT trigger this: that churns without fixing anything.
    fn maybe_restart_for_network_change(&mut self) {
        if !self.reachable_this_session || self.consecutive_probe_failures < 2 {
            return;
        }
        let changed = self.session.as_ref().is_some_and(|s| tokio::task::block_in_place(|| s.network_changed()));
        if changed {
            self.restart_for_network("the physical network changed under the tunnel");
        }
    }

    /// Rebuilds the session on the current network. Spaced by NETWORK_RESTART_BACKOFF (not once per session: a
    /// second Wi-Fi change later in the day must recover too); a failed attempt goes through the reconnect backoff.
    fn restart_for_network(&mut self, why: &str) {
        if self.last_network_restart.is_some_and(|t| t.elapsed() < NETWORK_RESTART_BACKOFF) {
            return;
        }
        log::warn!("{why}; reconnecting");
        self.last_network_restart = Some(Instant::now());
        self.disconnect(false);
        self.connect(true);
    }

    /// Returns true when the session needs a network restart (bypass route lost).
    fn on_tick(&mut self) -> bool {
        let Some(session) = &self.session else { return false };
        // Checked every second (one GetBestRoute2 call): with the bypass route gone, every new flow hangs in a loop
        // through the tunnel, so waiting for two failed 20 s probes left the PC stalled for up to a minute.
        let bypass_lost = !session.bypass_intact();
        let (up, down) = session.traffic();
        let now = Instant::now();
        let dt = now.duration_since(self.last_totals.2).as_secs_f64().max(0.001);
        self.snap.up_rate = up.saturating_sub(self.last_totals.0) as f64 / dt;
        self.snap.down_rate = down.saturating_sub(self.last_totals.1) as f64 / dt;
        self.last_totals = (up, down, now);
        self.snap.up_bytes = up.saturating_sub(self.baseline.0);
        self.snap.down_bytes = down.saturating_sub(self.baseline.1);
        if let Some(since) = self.snap.connected_since {
            // Bytes are no health signal (virtual DNS answers locally); only a SOCKS answer from this session's
            // latest probe counts. `health` is reset to Unknown on every connect, so it can't carry over.
            let answering = matches!(self.snap.health, Health::Answering { .. });
            self.reconnect.note_progress(now.duration_since(since), answering);
        }

        if !self.probe_in_flight && now >= self.next_probe {
            if let (Some(session), Some(config)) = (&self.session, &self.config) {
                self.probe_in_flight = true;
                self.next_probe = now + PROBE_EVERY;
                if self.snap.last_probe.is_none() {
                    self.snap.health = Health::Checking;
                }
                let server = session.server;
                let creds = config.credentials().map(|(u, p)| (u.to_string(), p.to_string()));
                let id = self.session_id;
                let events = self.events_tx.clone();
                tokio::spawn(async move {
                    let creds_ref = creds.as_ref().map(|(u, p)| (u.as_str(), p.as_str()));
                    let result = probe::probe(server, creds_ref, PROBE_TIMEOUT).await;
                    let _ = events.send(Event::Probed { id, result });
                });
            }
        }
        self.publish();
        bypass_lost
    }
}

// On non-Windows the engine stub fails every start, which exercises the background connect -> Started path.
#[cfg(all(test, not(windows)))]
mod tests {
    use super::*;

    fn wait_for(controller: &Controller, what: impl Fn(&Snapshot) -> bool) -> Snapshot {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snap = controller.snapshot();
            if what(&snap) || Instant::now() > deadline {
                return snap;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn config() -> ClientConfig {
        ClientConfig { host: "127.0.0.1".into(), port: 1080, username: String::new(), password: String::new() }
    }

    #[test]
    fn user_connect_failure_is_reported_without_retry() {
        let (controller, handle) = Controller::spawn(|| {});
        controller.send(Command::Connect(config()));
        let snap = wait_for(&controller, |s| s.state == ConnState::Disconnected && s.message.is_some());
        assert_eq!(snap.state, ConnState::Disconnected);
        assert!(snap.message.as_deref().is_some_and(|m| m.contains("only runs on Windows")), "{:?}", snap.message);
        controller.send(Command::Quit);
        handle.join().unwrap();
    }

    #[test]
    fn disconnect_and_quit_during_connect_finish_promptly() {
        let (controller, handle) = Controller::spawn(|| {});
        for _ in 0..5 {
            controller.send(Command::Connect(config()));
        }
        controller.send(Command::Disconnect);
        let snap = wait_for(&controller, |s| s.state == ConnState::Disconnected);
        assert_eq!(snap.state, ConnState::Disconnected);
        controller.send(Command::Connect(config()));
        controller.send(Command::Quit);
        let started = Instant::now();
        handle.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
