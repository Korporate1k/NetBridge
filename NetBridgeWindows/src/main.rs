//! NetBridge for Windows: a system-wide VPN that sends all TCP and UDP through a NetBridge (SOCKS5) server,
//! the Windows counterpart of the iOS Client tab and the macOS app.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod config;
mod controller;
mod engine;
mod logging;
#[cfg_attr(not(windows), allow(dead_code))] // used by the Windows engine; unit-tested everywhere
mod netspec;
#[cfg_attr(not(windows), allow(dead_code))]
mod packet_filter;
mod probe;
mod qr;
mod reconnect;
#[cfg(windows)]
mod routing;
#[cfg(windows)]
mod wintun_device;

use config::ClientConfig;
use controller::{Command, ConnState, Controller, Health, Snapshot};
use eframe::egui::{self, Color32, RichText};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

const GREEN: Color32 = Color32::from_rgb(52, 199, 89);
const ORANGE: Color32 = Color32::from_rgb(255, 149, 0);
const RED: Color32 = Color32::from_rgb(255, 69, 58);
const GRAY: Color32 = Color32::from_rgb(142, 142, 147);

fn main() -> eframe::Result<()> {
    logging::init();
    log::info!("NetBridge for Windows {} starting", env!("CARGO_PKG_VERSION"));

    let args: Vec<String> = std::env::args().collect();
    let headless_uri = args.iter().position(|a| a == "--connect").map(|i| args.get(i + 1).cloned());

    #[cfg(windows)]
    if !single_instance::acquire() {
        log::warn!("another NetBridge is already running");
        if headless_uri.is_some() {
            // A script must not block on a modal dialog nobody will see.
            log::logger().flush();
            std::process::exit(3);
        }
        rfd::MessageDialog::new()
            .set_title("NetBridge")
            .set_description("NetBridge is already running. Look for its icon in the notification area.")
            .show();
        log::logger().flush();
        return Ok(());
    }

    if let Some(uri) = headless_uri {
        let code = headless(uri.as_deref(), &args);
        log::logger().flush();
        std::process::exit(code);
    }

    let options = |renderer| eframe::NativeOptions {
        renderer,
        viewport: egui::ViewportBuilder::default()
            .with_title("NetBridge")
            .with_inner_size([440.0, 640.0])
            .with_min_inner_size([380.0, 520.0])
            .with_icon(std::sync::Arc::new(icon_data(GRAY))),
        ..Default::default()
    };
    // wgpu first: on Windows it uses Direct3D, which falls back to the WARP software renderer on PCs and VMs without
    // a GPU driver, where OpenGL is only 1.1 and egui_glow refuses to start. OpenGL is the second try.
    let mut result = eframe::run_native(
        "NetBridge",
        options(eframe::Renderer::Wgpu),
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    );
    if let Err(e) = &result {
        log::error!("Direct3D/wgpu renderer failed: {e}; trying OpenGL");
        result = eframe::run_native(
            "NetBridge",
            options(eframe::Renderer::Glow),
            Box::new(|cc| Ok(Box::new(App::new(cc)))),
        );
    }
    if let Err(e) = &result {
        log::error!("could not open the window: {e}");
        let log = logging::log_path().map(|p| p.display().to_string()).unwrap_or_default();
        rfd::MessageDialog::new()
            .set_level(rfd::MessageLevel::Error)
            .set_title("NetBridge")
            .set_description(format!("NetBridge could not open its window:\n\n{e}\n\nDetails are in {log}"))
            .show();
    }
    // The logger is never dropped (it is the global one): push out whatever is still buffered.
    log::logger().flush();
    result
}

/// `NetBridge.exe --connect <socks5 URI> [--for <seconds>]`: the same tunnel without a window, for scripted tests
/// and headless use. Progress goes to the log. Ends after `--for` seconds (default: never), or when the connection
/// has failed for good, and always takes the tunnel down before exiting.
/// Exit codes: 0 ran to completion, 1 connection failed for good, 2 bad arguments, 3 already running.
fn headless(uri: Option<&str>, args: &[String]) -> i32 {
    let Some(config) = uri.and_then(ClientConfig::from_uri) else {
        log::error!("--connect needs a socks5://[user:pass@]host:port or host:port argument");
        return 2;
    };
    let run_for = match args.iter().position(|a| a == "--for").map(|i| args.get(i + 1)) {
        None => None,
        Some(Some(s)) if s.parse::<u64>().is_ok() => s.parse::<u64>().ok().map(Duration::from_secs),
        Some(other) => {
            log::error!("--for needs a number of seconds, got {other:?}");
            return 2;
        }
    };
    log::info!("headless: connecting to {}:{}{}", config.host, config.port, run_for.map(|d| format!(" for {} s", d.as_secs())).unwrap_or_default());
    let (controller, handle) = Controller::spawn(|| {});
    controller.send(Command::Connect(config));
    let started = Instant::now();
    let mut last = String::new();
    let mut left_disconnected = false;
    let mut code = 0;
    while run_for.is_none_or(|d| started.elapsed() < d) {
        std::thread::sleep(Duration::from_secs(1));
        let s = controller.snapshot();
        if s.state != ConnState::Disconnected {
            left_disconnected = true;
        } else if left_disconnected {
            // Back to Disconnected after trying: the controller gave up (bad address, reconnects exhausted).
            log::error!("headless: connection failed: {}", s.message.as_deref().unwrap_or("unknown error"));
            code = 1;
            break;
        }
        let line = format!(
            "state={:?} health={:?} ipv6_tunnelled={} message={:?}",
            s.state, s.health, s.ipv6_tunnelled, s.message
        );
        if line != last {
            log::info!("headless: {line}");
            last = line;
        }
    }
    let s = controller.snapshot();
    log::info!("headless: stopping after {} s; up {} B, down {} B", started.elapsed().as_secs(), s.up_bytes, s.down_bytes);
    Shutdown::new(controller, handle).run();
    log::info!("headless: stopped");
    code
}

// ---- app --------------------------------------------------------------------------------------------------------

struct App {
    controller: Controller,
    host: String,
    port: String,
    username: String,
    password: String,
    link: String,
    notice: Option<(String, bool)>, // (text, is_error)
    history: VecDeque<(f64, f64)>,  // last 60 s of (up, down) B/s
    last_sample: Instant,
    quitting: bool,
    shutdown: Shutdown,
    #[cfg(windows)]
    tray: Option<tray::Tray>,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> App {
        let ctx = cc.egui_ctx.clone();
        let (controller, handle) = Controller::spawn(move || ctx.request_repaint());
        let shutdown = Shutdown::new(controller.clone(), handle);
        let stored = config::load();
        let server = stored.server.unwrap_or_default();
        #[cfg(windows)]
        let tray = tray::Tray::new(controller.clone(), shutdown.clone(), cc.egui_ctx.clone());
        App {
            controller,
            port: if server.port == 0 { String::new() } else { server.port.to_string() },
            host: server.host,
            username: server.username,
            password: server.password,
            link: String::new(),
            notice: None,
            history: VecDeque::with_capacity(60),
            last_sample: Instant::now(),
            quitting: false,
            shutdown,
            #[cfg(windows)]
            tray,
        }
    }

    fn current_config(&self) -> Result<ClientConfig, String> {
        let host = self.host.trim().to_string();
        if host.is_empty() {
            return Err("Enter the server address shown in the NetBridge app on your phone.".into());
        }
        let port: u16 = self.port.trim().parse().map_err(|_| "Port must be a number from 1 to 65535.".to_string())?;
        if port == 0 {
            return Err("Port must be a number from 1 to 65535.".into());
        }
        Ok(ClientConfig { host, port, username: self.username.trim().to_string(), password: self.password.clone() })
    }

    fn apply_config(&mut self, c: ClientConfig) {
        self.host = c.host;
        self.port = c.port.to_string();
        self.username = c.username;
        self.password = c.password;
    }

    fn connect(&mut self) {
        match self.current_config() {
            Ok(config) => {
                let mut stored = config::load();
                stored.server = Some(config.clone());
                config::save(&stored);
                self.notice = None;
                self.controller.send(Command::Connect(config));
            }
            Err(e) => self.notice = Some((e, true)),
        }
    }

    /// Pairing: a QR image picked from disk or dropped on the window. Connects straight away, like the Mac/iOS
    /// scanners do.
    fn import_qr(&mut self, path: &std::path::Path) {
        match qr::decode_file(path) {
            Ok(c) => {
                self.apply_config(c);
                self.connect();
            }
            Err(e) => self.notice = Some((e, true)),
        }
    }

    fn paste_link(&mut self) {
        match ClientConfig::from_uri(&self.link) {
            Some(c) => {
                self.apply_config(c);
                self.link.clear();
                self.notice = Some(("Server details filled in from the link.".into(), false));
            }
            None => self.notice = Some(("That isn't a NetBridge link (socks5://host:port or host:port).".into(), true)),
        }
    }

    fn sample(&mut self, snap: &Snapshot) {
        if self.last_sample.elapsed() >= Duration::from_secs(1) {
            self.last_sample = Instant::now();
            if self.history.len() == 60 {
                self.history.pop_front();
            }
            let live = snap.state == ConnState::Connected;
            self.history.push_back(if live { (snap.up_rate, snap.down_rate) } else { (0.0, 0.0) });
        }
    }
}

impl eframe::App for App {
    /// Runs every pass, including while the window is hidden or minimised (when `ui` does not).
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let snap = self.controller.snapshot();
        self.sample(&snap);
        #[cfg(windows)]
        if let Some(tray) = self.tray.as_mut() {
            tray.update(&snap);
        }

        // Closing the window while connected keeps the VPN up in the notification area.
        if ctx.input(|i| i.viewport().close_requested()) && !self.quitting {
            if snap.state == ConnState::Disconnected {
                self.quitting = true; // the window closes; Drop for App waits for the disconnect
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
            }
        }
        // Uptime/rates tick every second even without traffic.
        ctx.request_repaint_after(Duration::from_secs(1));
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let snap = self.controller.snapshot();

        let dropped: Vec<std::path::PathBuf> = ctx.input(|i| {
            i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).filter(|p| !p.as_os_str().is_empty()).collect()
        });
        if let Some(path) = dropped.first() {
            self.import_qr(path);
        }

        egui::CentralPanel::default_margins().show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                self.header(ui, &snap);
                ui.add_space(8.0);
                self.health_banner(ui, &snap);
                self.server_section(ui, &snap);
                ui.add_space(10.0);
                self.connect_button(ui, &snap);
                if let Some((text, is_error)) = snap.message.as_ref().map(|m| (m.clone(), true)).or(self.notice.clone()) {
                    ui.add_space(6.0);
                    ui.label(RichText::new(text).color(if is_error { RED } else { GRAY }));
                }
                ui.add_space(12.0);
                ui.separator();
                self.dashboard(ui, &snap);
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.small_button("Open log folder").clicked() {
                        if let Some(dir) = logging::log_path().and_then(|p| p.parent().map(|d| d.to_path_buf())) {
                            let _ = std::process::Command::new("explorer").arg(dir).spawn();
                        }
                    }
                    if ui.small_button("Quit NetBridge").clicked() {
                        self.quitting = true; // Drop for App waits for the disconnect
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                });
            });
        });
    }
}

impl App {
    fn header(&self, ui: &mut egui::Ui, snap: &Snapshot) {
        let (text, color) = status_text(snap);
        ui.horizontal(|ui| {
            ui.heading(RichText::new("NetBridge").strong());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(RichText::new(text).color(color).strong());
                let (rect, _) = ui.allocate_exact_size(egui::vec2(10.0, 10.0), egui::Sense::hover());
                ui.painter().circle_filled(rect.center(), 5.0, color);
            });
        });
    }

    fn health_banner(&self, ui: &mut egui::Ui, snap: &Snapshot) {
        if snap.state != ConnState::Connected {
            return;
        }
        let ago = snap.last_probe.map(|t| format!(" (checked {} s ago)", t.elapsed().as_secs())).unwrap_or_default();
        let (text, color) = match &snap.health {
            Health::NotAnswering(_) => (
                format!(
                    "Connected, but the NetBridge server at {} isn't answering{ago}. Is the NetBridge app still open on the phone?",
                    snap.server
                ),
                ORANGE,
            ),
            Health::AuthRejected(reason) => (format!("The server refused to sign in: {reason}."), RED),
            _ => return,
        };
        egui::Frame::new()
            .fill(color.gamma_multiply(0.18))
            .stroke(egui::Stroke::new(1.0, color))
            .corner_radius(6.0)
            .inner_margin(8.0)
            .show(ui, |ui| {
                ui.label(RichText::new(text).color(ui.visuals().strong_text_color()));
            });
        ui.add_space(8.0);
    }

    fn server_section(&mut self, ui: &mut egui::Ui, snap: &Snapshot) {
        let editable = matches!(snap.state, ConnState::Disconnected);
        ui.add_enabled_ui(editable, |ui| {
            ui.label(RichText::new("Server").strong());
            egui::Grid::new("server").num_columns(2).spacing([8.0, 6.0]).show(ui, |ui| {
                ui.label("Address");
                ui.add(egui::TextEdit::singleline(&mut self.host).hint_text("192.168.1.20").desired_width(f32::INFINITY));
                ui.end_row();
                ui.label("Port");
                ui.add(egui::TextEdit::singleline(&mut self.port).hint_text("1080").desired_width(80.0));
                ui.end_row();
                ui.label("Username");
                ui.add(egui::TextEdit::singleline(&mut self.username).hint_text("optional").desired_width(f32::INFINITY));
                ui.end_row();
                ui.label("Password");
                ui.add(egui::TextEdit::singleline(&mut self.password).password(true).hint_text("optional").desired_width(f32::INFINITY));
                ui.end_row();
            });
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                let field = ui.add(
                    egui::TextEdit::singleline(&mut self.link).hint_text("Paste a socks5:// link").desired_width(ui.available_width() - 70.0),
                );
                let enter = field.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
                if ui.button("Use").clicked() || enter {
                    self.paste_link();
                }
            });
            ui.horizontal(|ui| {
                if ui.button("Import QR code image…").on_hover_text("Or drop a screenshot of the QR code on this window").clicked() {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("Images", &["png", "jpg", "jpeg", "bmp", "gif", "webp"])
                        .pick_file()
                    {
                        self.import_qr(&path);
                    }
                }
                if let Ok(config) = self.current_config() {
                    if ui.button("Copy link").on_hover_text("Copy this server as a socks5:// link").clicked() {
                        ui.ctx().copy_text(config.uri());
                        self.notice = Some(("Link copied.".into(), false));
                    }
                }
            });
        });
    }

    fn connect_button(&mut self, ui: &mut egui::Ui, snap: &Snapshot) {
        let (label, fill) = match snap.state {
            ConnState::Disconnected => ("Connect", GREEN),
            ConnState::Connecting => ("Connecting…", GRAY),
            ConnState::Connected => ("Disconnect", RED),
            ConnState::Reconnecting(_) => ("Stop reconnecting", ORANGE),
        };
        let button = egui::Button::new(RichText::new(label).size(18.0).color(Color32::WHITE).strong())
            .fill(fill)
            .min_size(egui::vec2(ui.available_width(), 44.0));
        let enabled = snap.state != ConnState::Connecting;
        if ui.add_enabled(enabled, button).clicked() {
            match snap.state {
                ConnState::Disconnected => self.connect(),
                _ => self.controller.send(Command::Disconnect),
            }
        }
    }

    fn dashboard(&self, ui: &mut egui::Ui, snap: &Snapshot) {
        ui.label(RichText::new("Dashboard").strong());
        ui.add_space(4.0);
        let uptime = snap.connected_since.map(|t| format_duration(t.elapsed())).unwrap_or_else(|| "—".into());
        let (proxy, proxy_color) = match &snap.health {
            Health::Answering { .. } => ("Answering".to_string(), GREEN),
            Health::NotAnswering(_) => ("Not answering".to_string(), ORANGE),
            Health::AuthRejected(_) => ("Sign-in refused".to_string(), RED),
            Health::Checking => ("Checking…".to_string(), GRAY),
            Health::Unknown => ("—".to_string(), GRAY),
        };
        let udp = match &snap.health {
            Health::Answering { udp: true } => ("Relayed".to_string(), GREEN),
            Health::Answering { udp: false } => ("Refused by server".to_string(), ORANGE),
            _ => ("—".to_string(), GRAY),
        };
        let connected = snap.state == ConnState::Connected;
        egui::Grid::new("stats").num_columns(2).spacing([16.0, 6.0]).striped(true).show(ui, |ui| {
            let row = |ui: &mut egui::Ui, k: &str, v: String, c: Option<Color32>| {
                ui.label(k);
                match c {
                    Some(c) => ui.label(RichText::new(v).color(c)),
                    None => ui.label(v),
                };
                ui.end_row();
            };
            row(ui, "Server", if snap.server.is_empty() { "—".into() } else { snap.server.clone() }, None);
            row(ui, "Uptime", uptime, None);
            row(ui, "Proxy", proxy, Some(proxy_color));
            row(ui, "UDP", udp.0, Some(udp.1));
            row(ui, "IPv6", if !connected { "—".into() } else if snap.ipv6_tunnelled { "Tunnelled".into() } else { "Not available on this PC".into() }, None);
            row(ui, "Upload", format!("{}  ({}/s)", format_bytes(snap.up_bytes as f64), format_bytes(snap.up_rate)), None);
            row(ui, "Download", format!("{}  ({}/s)", format_bytes(snap.down_bytes as f64), format_bytes(snap.down_rate)), None);
        });
        ui.add_space(8.0);
        self.throughput_chart(ui);
    }

    /// Last 60 s of throughput; down filled, up as a line.
    fn throughput_chart(&self, ui: &mut egui::Ui) {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 90.0), egui::Sense::hover());
        let painter = ui.painter_at(rect);
        painter.rect_filled(rect, 6.0, ui.visuals().extreme_bg_color);
        let max = self.history.iter().map(|(u, d)| u.max(*d)).fold(1024.0_f64, f64::max);
        let n = 60usize;
        let point = |i: usize, v: f64| {
            let x = rect.left() + rect.width() * (i + n - self.history.len()) as f32 / (n - 1) as f32;
            let y = rect.bottom() - 4.0 - (rect.height() - 8.0) * (v / max) as f32;
            egui::pos2(x, y)
        };
        let down: Vec<_> = self.history.iter().enumerate().map(|(i, (_, d))| point(i, *d)).collect();
        let up: Vec<_> = self.history.iter().enumerate().map(|(i, (u, _))| point(i, *u)).collect();
        if down.len() > 1 {
            painter.add(egui::Shape::line(down, egui::Stroke::new(2.0, GREEN)));
            painter.add(egui::Shape::line(up, egui::Stroke::new(1.5, ORANGE)));
        }
        painter.text(
            rect.left_top() + egui::vec2(8.0, 6.0),
            egui::Align2::LEFT_TOP,
            format!("peak {}/s   ■ down  ■ up", format_bytes(max)),
            egui::FontId::proportional(11.0),
            GRAY,
        );
    }
}

/// Ends the controller and WAITS for it, so the tunnel's routes and DNS rule are removed before the process exits.
/// Every exit path goes through here: closing the window, the Quit button, the tray's Quit.
#[derive(Clone)]
struct Shutdown {
    controller: Controller,
    handle: std::sync::Arc<std::sync::Mutex<Option<std::thread::JoinHandle<()>>>>,
}

impl Shutdown {
    fn new(controller: Controller, handle: std::thread::JoinHandle<()>) -> Shutdown {
        Shutdown { controller, handle: std::sync::Arc::new(std::sync::Mutex::new(Some(handle))) }
    }

    fn run(&self) {
        self.controller.send(Command::Quit);
        if let Some(handle) = self.handle.lock().ok().and_then(|mut h| h.take()) {
            let _ = handle.join();
        }
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.shutdown.run();
    }
}

fn status_text(snap: &Snapshot) -> (String, Color32) {
    match snap.state {
        ConnState::Disconnected => ("Disconnected".into(), GRAY),
        ConnState::Connecting => ("Connecting…".into(), GRAY),
        ConnState::Reconnecting(n) => (format!("Reconnecting (try {n} of {})", reconnect::DELAYS.len()), ORANGE),
        ConnState::Connected => match snap.health {
            Health::NotAnswering(_) | Health::AuthRejected(_) => ("Connected, server not answering".into(), ORANGE),
            _ => ("Connected".into(), GREEN),
        },
    }
}

fn format_bytes(b: f64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = b;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 { format!("{v:.0} {}", UNITS[i]) } else { format!("{v:.1} {}", UNITS[i]) }
}

fn format_duration(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}

/// A 32×32 ring, used for the window and tray icons.
fn icon_rgba(color: Color32) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(32 * 32 * 4);
    for y in 0..32 {
        for x in 0..32 {
            let (dx, dy) = (x as f32 - 15.5, y as f32 - 15.5);
            let d = (dx * dx + dy * dy).sqrt();
            let outer = (14.0 - d).clamp(0.0, 1.0);
            let inner = (d - 6.0).clamp(0.0, 1.0);
            let a = outer.min(inner);
            rgba.extend_from_slice(&[color.r(), color.g(), color.b(), (a * 255.0) as u8]);
        }
    }
    rgba
}

fn icon_data(color: Color32) -> egui::IconData {
    egui::IconData { rgba: icon_rgba(color), width: 32, height: 32 }
}

// ---- Windows-only: tray icon and single instance ----------------------------------------------------------------

#[cfg(windows)]
mod tray {
    use super::*;
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

    pub struct Tray {
        icon: TrayIcon,
        toggle: MenuItem,
        shown: Option<(ConnState, bool)>,
    }

    impl Tray {
        pub fn new(controller: Controller, shutdown: Shutdown, ctx: egui::Context) -> Option<Tray> {
            let toggle = MenuItem::new("Connect", true, None);
            let show = MenuItem::new("Show NetBridge", true, None);
            let quit = MenuItem::new("Quit", true, None);
            let menu = Menu::new();
            menu.append_items(&[&toggle, &show, &PredefinedMenuItem::separator(), &quit]).ok()?;
            let icon = TrayIconBuilder::new()
                .with_menu(Box::new(menu))
                .with_tooltip("NetBridge: disconnected")
                .with_icon(Icon::from_rgba(icon_rgba(GRAY), 32, 32).ok()?)
                .build()
                .map_err(|e| log::warn!("tray icon unavailable: {e}"))
                .ok()?;

            // Handled here rather than in `update()`: egui does not run frames while the window is minimised, and
            // the tray has to keep working then. Quit waits for the controller so routes are removed before exit.
            let (toggle_id, show_id, quit_id) = (toggle.id().clone(), show.id().clone(), quit.id().clone());
            MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
                if event.id == toggle_id {
                    let snap = controller.snapshot();
                    if snap.state == ConnState::Disconnected {
                        match config::load().server {
                            Some(server) if server.is_usable() => controller.send(Command::Connect(server)),
                            _ => show_window(&ctx),
                        }
                    } else {
                        controller.send(Command::Disconnect);
                    }
                } else if event.id == show_id {
                    show_window(&ctx);
                } else if event.id == quit_id {
                    // This handler runs on the UI thread; taking the tunnel down can take seconds, so hide the
                    // window and do it off-thread instead of freezing ("Not responding").
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
                    let shutdown = shutdown.clone();
                    std::thread::spawn(move || {
                        shutdown.run();
                        log::logger().flush();
                        std::process::exit(0);
                    });
                }
                ctx.request_repaint();
            }));
            Some(Tray { icon, toggle, shown: None })
        }

        pub fn update(&mut self, snap: &Snapshot) {
            let healthy = !matches!(snap.health, Health::NotAnswering(_) | Health::AuthRejected(_));
            let key = (snap.state, healthy);
            if self.shown == Some(key) {
                return;
            }
            self.shown = Some(key);
            let (text, color) = status_text(snap);
            let _ = self.icon.set_tooltip(Some(format!("NetBridge: {}", text.to_lowercase())));
            if let Ok(icon) = Icon::from_rgba(icon_rgba(color), 32, 32) {
                let _ = self.icon.set_icon(Some(icon));
            }
            self.toggle.set_text(if snap.state == ConnState::Disconnected { "Connect" } else { "Disconnect" });
        }
    }

    fn show_window(ctx: &egui::Context) {
        ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }
}

#[cfg(windows)]
mod single_instance {
    use windows_sys::Win32::Foundation::{ERROR_ALREADY_EXISTS, GetLastError};
    use windows_sys::Win32::System::Threading::CreateMutexW;

    /// Two instances would fight over the one adapter and the routes. The mutex is held for the process lifetime.
    pub fn acquire() -> bool {
        let name: Vec<u16> = "Global\\NetBridgeWindowsClient\0".encode_utf16().collect();
        // SAFETY: valid null-terminated wide string; the handle is intentionally leaked (released at exit).
        unsafe {
            let handle = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
            !handle.is_null() && GetLastError() != ERROR_ALREADY_EXISTS
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_and_durations() {
        assert_eq!(format_bytes(512.0), "512 B");
        assert_eq!(format_bytes(1_500_000.0), "1.5 MB");
        assert_eq!(format_duration(Duration::from_secs(65)), "1:05");
        assert_eq!(format_duration(Duration::from_secs(3725)), "1:02:05");
    }

    #[test]
    fn icon_is_32x32_rgba() {
        assert_eq!(icon_rgba(GREEN).len(), 32 * 32 * 4);
    }
}
