//! The remote NetBridge (SOCKS5) server this PC connects out to. Mirrors `NetBridge/ClientConfiguration.swift`, so
//! the same QR codes and `socks5://` URIs pair an iPhone, a Mac and a Windows PC.

use percent_encoding::{AsciiSet, CONTROLS, percent_decode_str, utf8_percent_encode};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// Kept out of config.json; on Windows it lives in Credential Manager (see `secret`).
    #[serde(skip)]
    pub password: String,
}

/// Characters escaped in the userinfo part of a URI.
const USERINFO: &AsciiSet = &CONTROLS
    .add(b' ').add(b'"').add(b'#').add(b'%').add(b'/').add(b':').add(b'<').add(b'>')
    .add(b'?').add(b'@').add(b'[').add(b'\\').add(b']').add(b'^').add(b'`').add(b'{').add(b'|').add(b'}');

impl ClientConfig {
    /// Accepts a full `socks5://[user[:pass]@]host:port` URI, or a bare `host:port` (what a device's own QR code
    /// encodes). Same rules as `ClientConfiguration(uriString:)`: scheme must be socks5, host and port required.
    pub fn from_uri(input: &str) -> Option<Self> {
        let trimmed = input.trim();
        let normalized =
            if trimmed.contains("://") { trimmed.to_string() } else { format!("socks5://{trimmed}") };
        let url = url::Url::parse(&normalized).ok()?;
        if !url.scheme().eq_ignore_ascii_case("socks5") {
            return None;
        }
        let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']').to_string();
        if host.is_empty() {
            return None;
        }
        let port = url.port()?;
        let username = percent_decode_str(url.username()).decode_utf8().ok()?.into_owned();
        let password = percent_decode_str(url.password().unwrap_or("")).decode_utf8().ok()?.into_owned();
        Some(ClientConfig { host, port, username, password })
    }

    /// `socks5://user:pass@host:port`; the userinfo is omitted without a username, and a password is only emitted
    /// together with a username (as `URLComponents` does on Apple platforms).
    pub fn uri(&self) -> String {
        let mut s = String::from("socks5://");
        if !self.username.is_empty() {
            s += &utf8_percent_encode(&self.username, USERINFO).to_string();
            if !self.password.is_empty() {
                s.push(':');
                s += &utf8_percent_encode(&self.password, USERINFO).to_string();
            }
            s.push('@');
        }
        s += &host_for_uri(&self.host);
        s += &format!(":{}", self.port);
        s
    }

    pub fn credentials(&self) -> Option<(&str, &str)> {
        if self.username.is_empty() { None } else { Some((&self.username, &self.password)) }
    }

    pub fn is_usable(&self) -> bool {
        !self.host.trim().is_empty() && self.port != 0
    }
}

fn host_for_uri(host: &str) -> String {
    if host.contains(':') { format!("[{host}]") } else { host.to_string() }
}

// ---- persistence -----------------------------------------------------------------------------------------------

fn config_path() -> Option<PathBuf> {
    Some(dirs::config_dir()?.join("NetBridge").join("config.json"))
}

#[derive(Default, Serialize, Deserialize)]
pub struct Stored {
    #[serde(default)]
    pub server: Option<ClientConfig>,
    /// A bypass route this app added and has not removed yet (e.g. it was killed while connected), as "prefix
    /// interface-index". Removed on the next launch; see `routing::cleanup_stale`.
    #[serde(default)]
    pub pending_bypass: Option<String>,
}

pub fn load() -> Stored {
    let Some(path) = config_path() else { return Stored::default() };
    let mut stored: Stored =
        std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    if let Some(server) = stored.server.as_mut() {
        server.password = secret::get(&server.host, server.port, &server.username).unwrap_or_default();
    }
    stored
}

pub fn save(stored: &Stored) {
    let Some(path) = config_path() else { return };
    if let Some(server) = &stored.server {
        secret::set(&server.host, server.port, &server.username, &server.password);
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    match serde_json::to_vec_pretty(stored) {
        Ok(bytes) => write_atomically(&path, &bytes),
        Err(e) => log::warn!("could not encode config: {e}"),
    }
}

/// Write to a temp file and rename it over the target, so a crash mid-write can't leave a truncated config.json.
fn write_atomically(path: &std::path::Path, bytes: &[u8]) {
    let tmp = path.with_extension("json.tmp");
    let result = std::fs::write(&tmp, bytes).and_then(|_| std::fs::rename(&tmp, path));
    if let Err(e) = result {
        log::warn!("could not save {}: {e}", path.display());
    }
}

/// The bypass route recorded by a running session (see `Stored::pending_bypass`). Read and written on its own,
/// without going through Credential Manager: the controller used to load() + save() the whole config for this,
/// and a transient Credential Manager read failure then saved an empty password, which deleted the stored one.
pub fn load_pending_bypass() -> Option<String> {
    let path = config_path()?;
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice::<Stored>(&bytes).ok()?.pending_bypass
}

pub fn set_pending_bypass(record: Option<String>) {
    let Some(path) = config_path() else { return };
    let mut json: serde_json::Value = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .filter(serde_json::Value::is_object)
        .unwrap_or_else(|| serde_json::json!({}));
    json["pending_bypass"] = record.map_or(serde_json::Value::Null, serde_json::Value::String);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    match serde_json::to_vec_pretty(&json) {
        Ok(bytes) => write_atomically(&path, &bytes),
        Err(e) => log::warn!("could not encode config: {e}"),
    }
}

#[cfg(windows)]
mod secret {
    const SERVICE: &str = "NetBridge";
    fn account(host: &str, port: u16, user: &str) -> String {
        format!("{user}@{host}:{port}")
    }
    pub fn get(host: &str, port: u16, user: &str) -> Option<String> {
        if user.is_empty() {
            return None;
        }
        keyring::Entry::new(SERVICE, &account(host, port, user)).ok()?.get_password().ok()
    }
    pub fn set(host: &str, port: u16, user: &str, password: &str) {
        if user.is_empty() {
            return;
        }
        let Ok(entry) = keyring::Entry::new(SERVICE, &account(host, port, user)) else { return };
        let result = if password.is_empty() { entry.delete_credential() } else { entry.set_password(password) };
        if let Err(e) = result {
            if !matches!(e, keyring::Error::NoEntry) {
                log::warn!("Credential Manager: {e}");
            }
        }
    }
}

/// Non-Windows builds exist only for `cargo test`; they never persist a password.
#[cfg(not(windows))]
mod secret {
    pub fn get(_: &str, _: u16, _: &str) -> Option<String> {
        None
    }
    pub fn set(_: &str, _: u16, _: &str, _: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_uri() {
        let c = ClientConfig::from_uri("socks5://alice:s3cret@192.168.1.20:1080").unwrap();
        assert_eq!(c, ClientConfig { host: "192.168.1.20".into(), port: 1080, username: "alice".into(), password: "s3cret".into() });
        assert_eq!(c.uri(), "socks5://alice:s3cret@192.168.1.20:1080");
    }

    #[test]
    fn bare_host_port_and_whitespace() {
        let c = ClientConfig::from_uri("  172.20.10.1:8080\n").unwrap();
        assert_eq!((c.host.as_str(), c.port, c.username.as_str()), ("172.20.10.1", 8080, ""));
        assert_eq!(c.uri(), "socks5://172.20.10.1:8080");
    }

    #[test]
    fn scheme_is_case_insensitive_and_hostnames_work() {
        let c = ClientConfig::from_uri("SOCKS5://phone.local:1080").unwrap();
        assert_eq!(c.host, "phone.local");
    }

    #[test]
    fn rejects_other_schemes_missing_port_and_garbage() {
        assert!(ClientConfig::from_uri("http://1.2.3.4:8080").is_none());
        assert!(ClientConfig::from_uri("socks5://1.2.3.4").is_none());
        assert!(ClientConfig::from_uri("1.2.3.4").is_none());
        assert!(ClientConfig::from_uri("").is_none());
        assert!(ClientConfig::from_uri("socks5://1.2.3.4:99999").is_none());
    }

    #[test]
    fn ipv6_host() {
        let c = ClientConfig::from_uri("socks5://[fe80::1]:1080").unwrap();
        assert_eq!(c.host, "fe80::1");
        assert_eq!(c.uri(), "socks5://[fe80::1]:1080");
    }

    #[test]
    fn credentials_with_reserved_characters_round_trip() {
        let c = ClientConfig { host: "10.0.0.5".into(), port: 1080, username: "a@b".into(), password: "p:w/d%?#".into() };
        let back = ClientConfig::from_uri(&c.uri()).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn password_without_username_is_not_emitted() {
        let c = ClientConfig { host: "h".into(), port: 1, username: "".into(), password: "x".into() };
        assert_eq!(c.uri(), "socks5://h:1");
        assert!(c.credentials().is_none());
    }

    #[test]
    fn stored_json_never_contains_the_password() {
        let stored = Stored { server: Some(ClientConfig::from_uri("socks5://u:topsecret@h:1").unwrap()), pending_bypass: None };
        let json = serde_json::to_string(&stored).unwrap();
        assert!(!json.contains("topsecret"), "{json}");
        let back: Stored = serde_json::from_str(&json).unwrap();
        assert_eq!(back.server.unwrap().username, "u");
    }
}
