use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "kebab-case")]
pub enum InputFormat {
    Lines,
    Csv,
    Tsv,
    Json,
    Ndjson,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "kebab-case")]
pub enum OutputFormat {
    Same,
    Lines,
    Csv,
    Tsv,
    Json,
    Ndjson,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Select,
    View,
    Form,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Row {
    pub cells: Vec<String>,
    pub value: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Data {
    pub format: InputFormat,
    pub columns: Vec<String>,
    pub rows: Vec<Row>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub schema: u32,
    pub mode: Mode,
    pub title: String,
    pub data: Data,
    pub multi: bool,
    pub allow_empty: bool,
    pub css: Option<String>,
    pub html: Option<String>,
    /// Bounds and diagnostics chosen on the launcher's command line. Carried in the
    /// private session file because the backend is started by the host, not by the launcher.
    #[serde(default)]
    pub runtime: Runtime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Runtime {
    /// Longest wait for the host to answer one request, complete a started frame or accept
    /// a write.
    pub rpc_timeout_ms: u64,
    /// Idle time after which host liveness is probed; 0 disables probing.
    pub liveness_interval_ms: u64,
    /// Explicit bound on waiting for the user (`--timeout`); `None` waits indefinitely.
    pub deadline_ms: Option<u64>,
    pub diagnostics: crate::diag::Level,
    pub session_id: String,
}

pub const DEFAULT_RPC_TIMEOUT_MS: u64 = 30_000;
pub const DEFAULT_LIVENESS_INTERVAL_MS: u64 = 5_000;

impl Default for Runtime {
    fn default() -> Self {
        Self {
            rpc_timeout_ms: DEFAULT_RPC_TIMEOUT_MS,
            liveness_interval_ms: DEFAULT_LIVENESS_INTERVAL_MS,
            deadline_ms: None,
            diagnostics: crate::diag::Level::Normal,
            session_id: String::new(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outcome {
    Selected {
        indices: Vec<usize>,
    },
    Form {
        entries: Vec<Value>,
    },
    Viewed,
    /// The explicit `--timeout` passed before the user submitted or cancelled.
    TimedOut,
}
