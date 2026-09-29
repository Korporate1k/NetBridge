//! File logger: %LOCALAPPDATA%\NetBridge\netbridge.log, rotated to netbridge.log.prev at 8 MB (same bound as the
//! Apple tunnel's debug log). Our own lines log at info; the engine (tun2proxy/ipstack) logs at warn, because at
//! info it writes a line per TCP/UDP session. Set NETBRIDGE_LOG=debug (or trace) to raise everything.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_BYTES: u64 = 8 * 1024 * 1024;
/// Lines sit in memory at most this long before they reach the file (a flusher thread enforces it when idle).
const FLUSH_EVERY: Duration = Duration::from_secs(1);
const BUFFER_BYTES: usize = 64 * 1024;

struct Sink {
    file: BufWriter<File>,
    /// Bytes in the file, buffered ones included.
    len: u64,
    last_flush: Instant,
}

struct FileLogger {
    path: PathBuf,
    max_bytes: u64,
    sink: Mutex<Option<Sink>>,
    ours: log::LevelFilter,
    engine: log::LevelFilter,
}

impl FileLogger {
    fn new(path: PathBuf, max_bytes: u64, ours: log::LevelFilter, engine: log::LevelFilter) -> FileLogger {
        FileLogger { path, max_bytes, sink: Mutex::new(None), ours, engine }
    }

    fn open(&self) -> Option<Sink> {
        let file = OpenOptions::new().create(true).append(true).open(&self.path).ok()?;
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        Some(Sink { file: BufWriter::with_capacity(BUFFER_BYTES, file), len, last_flush: Instant::now() })
    }

    fn write_line(&self, line: &str, urgent: bool) {
        let Ok(mut guard) = self.sink.lock() else { return };
        let too_big = matches!(guard.as_ref(), Some(sink) if sink.len > self.max_bytes);
        if too_big {
            // Flush and close before renaming (Windows can't rename an open file).
            if let Some(mut sink) = guard.take() {
                let _ = sink.file.flush();
            }
            let _ = std::fs::rename(&self.path, self.path.with_extension("log.prev"));
        }
        if guard.is_none() {
            *guard = self.open();
        }
        if let Some(sink) = guard.as_mut() {
            if sink.file.write_all(line.as_bytes()).is_ok() {
                sink.len += line.len() as u64;
            }
            if urgent || sink.last_flush.elapsed() >= FLUSH_EVERY {
                let _ = sink.file.flush();
                sink.last_flush = Instant::now();
            }
        }
    }

    /// Flushes only when something is buffered, so the idle flusher thread costs a lock and nothing else.
    fn flush_buffered(&self) {
        if let Ok(mut guard) = self.sink.lock() {
            if let Some(sink) = guard.as_mut() {
                if !sink.file.buffer().is_empty() {
                    let _ = sink.file.flush();
                }
                sink.last_flush = Instant::now();
            }
        }
    }
}

impl log::Log for FileLogger {
    fn enabled(&self, meta: &log::Metadata) -> bool {
        // Our targets are "NetBridge" / "NetBridge::controller" (the binary's crate name), not the package name.
        let ours = meta.target().split("::").next().is_some_and(|c| c.eq_ignore_ascii_case("netbridge"));
        let limit = if ours { self.ours } else { self.engine };
        meta.level() <= limit
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        let line = format!(
            "{}.{:03} {:<5} {}: {}\n",
            now.as_secs(),
            now.subsec_millis(),
            record.level(),
            record.target(),
            record.args()
        );
        // Errors go out at once: they are what someone reads after a crash.
        self.write_line(&line, record.level() <= log::Level::Error);
    }

    fn flush(&self) {
        self.flush_buffered();
    }
}

pub fn log_path() -> Option<PathBuf> {
    Some(dirs::data_local_dir()?.join("NetBridge").join("netbridge.log"))
}

pub fn init() {
    let Some(path) = log_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let raised = std::env::var("NETBRIDGE_LOG").ok().and_then(|v| v.parse::<log::LevelFilter>().ok());
    let ours = raised.unwrap_or(log::LevelFilter::Info).max(log::LevelFilter::Info);
    let engine = raised.unwrap_or(log::LevelFilter::Warn);
    let logger = FileLogger::new(path, MAX_BYTES, ours, engine);
    if log::set_boxed_logger(Box::new(logger)).is_ok() {
        log::set_max_level(ours.max(engine));
        // Pushes out lines that are still buffered when nothing else gets logged for a while.
        let _ = std::thread::Builder::new().name("netbridge-log-flush".into()).spawn(|| loop {
            std::thread::sleep(FLUSH_EVERY);
            log::logger().flush();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use log::Log;

    fn temp_log(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("netbridge-log-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("netbridge.log")
    }

    fn record(logger: &FileLogger, level: log::Level, msg: &str) {
        logger.log(&log::Record::builder().level(level).target("NetBridge::test").args(format_args!("{msg}")).build());
    }

    fn read(path: &std::path::Path) -> String {
        std::fs::read_to_string(path).unwrap_or_default()
    }

    #[test]
    fn info_is_buffered_until_flush_and_error_goes_out_at_once() {
        let path = temp_log("buffer");
        let logger = FileLogger::new(path.clone(), MAX_BYTES, log::LevelFilter::Info, log::LevelFilter::Warn);
        record(&logger, log::Level::Info, "first");
        assert!(!read(&path).contains("first"), "info line should still be buffered");
        logger.flush();
        assert!(read(&path).contains("first"));
        record(&logger, log::Level::Info, "second");
        record(&logger, log::Level::Error, "boom");
        let text = read(&path);
        assert!(text.contains("second") && text.contains("boom"), "{text}");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn rotates_with_buffered_lines_intact() {
        let path = temp_log("rotate");
        let logger = FileLogger::new(path.clone(), 200, log::LevelFilter::Info, log::LevelFilter::Warn);
        for i in 0..10 {
            record(&logger, log::Level::Info, &format!("line {i:02} {}", "x".repeat(40)));
        }
        logger.flush();
        let prev = read(&path.with_extension("log.prev"));
        let cur = read(&path);
        assert!(!prev.is_empty(), "no rotation happened");
        // Every line landed in exactly one of the two files (the older ones may have rotated away twice).
        let all = format!("{prev}{cur}");
        assert!(all.contains("line 09"), "{all}");
        assert!(cur.len() as u64 <= 200 + 100, "current file not bounded: {}", cur.len());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
