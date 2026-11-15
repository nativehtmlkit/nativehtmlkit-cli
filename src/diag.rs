//! Structured CLI diagnostics (schema version 1), one JSON object per line.
//!
//! Privacy is enforced by the API shape: a record can only carry fixed event names,
//! `&'static str` or identifier-checked strings, numbers and booleans. There is no way to
//! attach a request body, an RPC result, stdin data, a selection, a form value, a path or
//! the launch token.
//!
//! The launcher writes records to stderr. The backend's stderr is captured by the host and
//! re-logged inside host records, so the backend appends to a private file in the session
//! directory instead and the launcher relays those lines to stderr.
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const LEVEL_ENV: &str = "NATIVEHTMLKIT_DIAGNOSTICS";
pub const SESSION_ENV: &str = "NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID";
/// Name of the backend's record file inside the private session directory.
pub const BACKEND_FILE: &str = "diag.ndjson";
/// The backend stops recording after this many bytes and reports how many were dropped.
const FILE_BUDGET: u64 = 1024 * 1024;

#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    /// No CLI records at all (the host logs errors only).
    Off,
    /// Critical failures only.
    #[default]
    Normal,
    /// Adds lifecycle events and per-request timings.
    Debug,
    /// Adds every request start, received event and liveness probe.
    Trace,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Normal => "normal",
            Self::Debug => "debug",
            Self::Trace => "trace",
        }
    }
    /// Same mapping as the Core host: unknown text means `normal`.
    pub fn from_env_text(text: &str) -> Self {
        match text.trim().to_ascii_lowercase().as_str() {
            "off" => Self::Off,
            "debug" => Self::Debug,
            "trace" => Self::Trace,
            _ => Self::Normal,
        }
    }
}

/// The host copies the session id verbatim into every log record and accepts only this
/// shape; anything else would silently break correlation, so the CLI applies the same rule.
pub fn valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// An inherited, well-formed id is preserved so a calling tool can correlate its own
/// records; otherwise a fresh one is generated. Returns (id, inherited_value_was_rejected).
pub fn resolve_session_id(inherited: Option<&str>) -> (String, bool) {
    match inherited.map(str::trim) {
        Some(id) if valid_session_id(id) => (id.to_owned(), false),
        other => {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            (
                format!("nhk-{}-{stamp:x}", std::process::id()),
                other.is_some_and(|id| !id.is_empty()),
            )
        }
    }
}

enum Sink {
    Stderr,
    File {
        file: File,
        written: u64,
        dropped: u64,
    },
}

struct State {
    level: Level,
    session_id: String,
    role: &'static str,
    sink: Mutex<Sink>,
}

static STATE: OnceLock<State> = OnceLock::new();

pub fn init_stderr(level: Level, session_id: &str, role: &'static str) {
    let _ = STATE.set(State {
        level,
        session_id: session_id.to_owned(),
        role,
        sink: Mutex::new(Sink::Stderr),
    });
}

/// Backend sink. If the file cannot be created the backend runs without records; that is
/// reported by the launcher as zero relayed backend records, never as a session failure.
pub fn init_file(level: Level, session_id: &str, role: &'static str, dir: &Path) {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(BACKEND_FILE));
    if let Ok(file) = file {
        let _ = STATE.set(State {
            level,
            session_id: session_id.to_owned(),
            role,
            sink: Mutex::new(Sink::File {
                file,
                written: 0,
                dropped: 0,
            }),
        });
    }
}

/// Identifier-like dynamic text (versions, ids we generated). Anything else is replaced.
fn identifier(text: &str) -> &str {
    if valid_session_id(text) {
        text
    } else {
        "invalid"
    }
}

#[must_use = "call .emit()"]
pub struct Record {
    level: Level,
    event: &'static str,
    request_id: Option<String>,
    operation: Option<&'static str>,
    duration_ms: Option<u64>,
    error_code: Option<String>,
    context: Map<String, Value>,
}

pub fn record(level: Level, event: &'static str) -> Record {
    Record {
        level,
        event,
        request_id: None,
        operation: None,
        duration_ms: None,
        error_code: None,
        context: Map::new(),
    }
}

impl Record {
    pub fn request(mut self, id: &str) -> Self {
        self.request_id = Some(identifier(id).to_owned());
        self
    }
    pub fn operation(mut self, name: &'static str) -> Self {
        self.operation = Some(name);
        self
    }
    pub fn duration(mut self, elapsed: Duration) -> Self {
        self.duration_ms = Some(elapsed.as_millis() as u64);
        self
    }
    pub fn num(mut self, key: &'static str, value: u64) -> Self {
        self.context.insert(key.to_owned(), Value::from(value));
        self
    }
    pub fn flag(mut self, key: &'static str, value: bool) -> Self {
        self.context.insert(key.to_owned(), Value::Bool(value));
        self
    }
    pub fn tag(mut self, key: &'static str, value: &'static str) -> Self {
        self.context.insert(key.to_owned(), Value::from(value));
        self
    }
    /// For identifier-shaped dynamic values only (e.g. the host version).
    pub fn ident(mut self, key: &'static str, value: &str) -> Self {
        self.context
            .insert(key.to_owned(), Value::from(identifier(value)));
        self
    }
    /// Copy the classification of a failure (code, operation-independent numbers).
    pub fn failure(mut self, failure: &crate::error::Failure) -> Self {
        self.error_code = Some(identifier(&failure.code).to_owned());
        if let Some(id) = &failure.request_id {
            self.request_id = Some(identifier(id).to_owned());
        }
        if let Some(operation) = &failure.operation {
            self.context
                .insert("operation".to_owned(), Value::from(identifier(operation)));
        }
        if self.duration_ms.is_none() {
            self.duration_ms = failure.duration_ms;
        }
        if let Some(code) = failure.host_code {
            self.context
                .insert("host_code".to_owned(), Value::from(code));
        }
        if failure.outcome_unknown {
            self.context
                .insert("remote_outcome".to_owned(), Value::from("unknown"));
        }
        self
    }

    pub fn emit(self) {
        let Some(state) = STATE.get() else { return };
        if self.level == Level::Off || state.level < self.level {
            return;
        }
        let mut object = Map::new();
        object.insert("schema_version".into(), Value::from(1));
        object.insert(
            "timestamp".into(),
            Value::from(timestamp(SystemTime::now())),
        );
        object.insert("session_id".into(), Value::from(state.session_id.as_str()));
        object.insert("component".into(), Value::from("nativehtmlkit-cli"));
        object.insert("role".into(), Value::from(state.role));
        object.insert("pid".into(), Value::from(std::process::id()));
        object.insert("level".into(), Value::from(self.level.as_str()));
        object.insert("event".into(), Value::from(self.event));
        if let Some(id) = self.request_id {
            object.insert("request_id".into(), Value::from(id));
        }
        if let Some(operation) = self.operation {
            object.insert("operation".into(), Value::from(operation));
        }
        if let Some(ms) = self.duration_ms {
            object.insert("duration_ms".into(), Value::from(ms));
        }
        if let Some(code) = self.error_code {
            object.insert("error_code".into(), Value::from(code));
        }
        if !self.context.is_empty() {
            object.insert("context".into(), Value::Object(self.context));
        }
        let mut line = Value::Object(object).to_string();
        line.push('\n');
        write_line(state, line.as_bytes());
    }
}

/// Diagnostics must never fail or block the session: write errors are counted or ignored.
fn write_line(state: &State, line: &[u8]) {
    let mut sink = state.sink.lock().unwrap_or_else(|e| e.into_inner());
    match &mut *sink {
        Sink::Stderr => {
            let _ = std::io::stderr().lock().write_all(line);
        }
        Sink::File {
            file,
            written,
            dropped,
        } => {
            if *written + line.len() as u64 > FILE_BUDGET || file.write_all(line).is_err() {
                *dropped += 1;
            } else {
                *written += line.len() as u64;
            }
        }
    }
}

/// Disclose lost evidence: called once when the backend ends.
pub fn finish() {
    let Some(state) = STATE.get() else { return };
    let mut sink = state.sink.lock().unwrap_or_else(|e| e.into_inner());
    if let Sink::File { file, dropped, .. } = &mut *sink {
        if *dropped != 0 {
            let line = format!(
                "{{\"schema_version\":1,\"timestamp\":\"{}\",\"session_id\":\"{}\",\"component\":\"nativehtmlkit-cli\",\"role\":\"{}\",\"pid\":{},\"level\":\"normal\",\"event\":\"diagnostics.dropped\",\"context\":{{\"dropped_records\":{}}}}}\n",
                timestamp(SystemTime::now()),
                state.session_id,
                state.role,
                std::process::id(),
                dropped
            );
            let _ = file.write_all(line.as_bytes());
            *dropped = 0;
        }
        let _ = file.flush();
    }
}

/// ISO-8601 UTC with milliseconds, without a date-time dependency.
pub fn timestamp(now: SystemTime) -> String {
    let since = now.duration_since(UNIX_EPOCH).unwrap_or_default();
    let (secs, millis) = (since.as_secs(), since.subsec_millis());
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil-from-days (proleptic Gregorian), Howard Hinnant's algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_iso_8601_utc() {
        let at = |secs: u64, ms: u32| UNIX_EPOCH + Duration::new(secs, ms * 1_000_000);
        assert_eq!(timestamp(at(0, 0)), "1970-01-01T00:00:00.000Z");
        assert_eq!(timestamp(at(951_782_400, 7)), "2000-02-29T00:00:00.007Z");
        assert_eq!(
            timestamp(at(1_794_787_199, 999)),
            "2026-11-15T23:59:59.999Z"
        );
        assert_eq!(timestamp(at(4_102_444_800, 0)), "2100-01-01T00:00:00.000Z");
    }

    #[test]
    fn levels_order_and_parse_like_the_host() {
        assert!(Level::Trace > Level::Debug && Level::Debug > Level::Normal);
        assert!(Level::Normal > Level::Off);
        assert_eq!(Level::from_env_text(" TRACE "), Level::Trace);
        assert_eq!(Level::from_env_text("debug"), Level::Debug);
        assert_eq!(Level::from_env_text("off"), Level::Off);
        assert_eq!(Level::from_env_text("nonsense=trace"), Level::Normal);
        for level in [Level::Off, Level::Normal, Level::Debug, Level::Trace] {
            assert_eq!(Level::from_env_text(level.as_str()), level);
        }
    }

    #[test]
    fn inherited_session_ids_are_preserved_only_when_well_formed() {
        assert_eq!(
            resolve_session_id(Some("ci-42:job.7_a")),
            ("ci-42:job.7_a".to_owned(), false)
        );
        assert_eq!(resolve_session_id(Some(" padded ")).0, "padded");
        for bad in ["a b", "a\"b", "new\nline", &"x".repeat(129)] {
            let (id, rejected) = resolve_session_id(Some(bad));
            assert!(
                rejected && valid_session_id(&id) && id.starts_with("nhk-"),
                "{bad:?}"
            );
        }
        let (generated, rejected) = resolve_session_id(None);
        assert!(!rejected && valid_session_id(&generated));
        assert!(!resolve_session_id(Some("")).1);
    }

    #[test]
    fn dynamic_text_must_be_identifier_shaped() {
        assert_eq!(identifier("1.0.2"), "1.0.2");
        assert_eq!(identifier("secret value"), "invalid");
        assert_eq!(identifier("{\"a\":1}"), "invalid");
    }
}
