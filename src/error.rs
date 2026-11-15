//! Stable, payload-free failure classification shared by the launcher and the backend.
//!
//! A `Failure` never carries user data: messages are built from fixed text, protocol method
//! names, numeric codes and durations only. Text supplied by the host (error messages,
//! renderer errors, raw frames) is deliberately not copied, because it can quote form values.
use serde::{Deserialize, Serialize};
use std::fmt;
use std::time::Duration;

/// Stable identifiers. They are part of the CLI's stderr contract (`error[<code>]`).
pub mod code {
    /// Command-line arguments that clap accepted but the CLI rejects.
    pub const USAGE: &str = "usage.invalid";
    /// stdin or a `--html`/`--css` file could not be used.
    pub const INPUT: &str = "input.invalid";
    /// The result could not be encoded or written to stdout.
    pub const OUTPUT: &str = "output.failed";
    /// No Core host executable, or it cannot be started.
    pub const HOST_MISSING: &str = "host.not_found";
    /// The host did not get the backend ready in time.
    pub const HOST_STARTUP: &str = "host.startup_timeout";
    /// The host stopped answering liveness probes while the window was open.
    pub const HOST_UNRESPONSIVE: &str = "host.unresponsive";
    /// The host accepted a quit request but never shut the session down.
    pub const HOST_SHUTDOWN: &str = "host.shutdown_timeout";
    /// The host process ended unsuccessfully without a more specific cause.
    pub const HOST_FAILED: &str = "host.failed";
    /// The CLI's own backend process stopped reporting progress.
    pub const BACKEND_UNRESPONSIVE: &str = "backend.unresponsive";
    /// A request was sent and no response arrived before the per-request deadline.
    pub const RPC_TIMEOUT: &str = "rpc.timeout";
    /// The host answered a request with a JSON-RPC error.
    pub const RPC_REJECTED: &str = "rpc.rejected";
    /// The connection ended at a frame boundary (host exited or closed the endpoint).
    pub const DISCONNECTED: &str = "transport.disconnected";
    /// The connection could not be established.
    pub const CONNECT: &str = "transport.connect_failed";
    /// A frame ended, or stalled, part-way through.
    pub const TRUNCATED: &str = "protocol.truncated_frame";
    /// Frame length 0 / above 2 MiB, invalid UTF-8/JSON, or not a JSON object.
    pub const INVALID_FRAME: &str = "protocol.invalid_frame";
    /// A well-formed frame that breaks the v1 contract (uncorrelated response, bad result).
    pub const VIOLATION: &str = "protocol.violation";
    /// Launch credentials or protocol version were not accepted.
    pub const HANDSHAKE: &str = "protocol.handshake_failed";
    /// The host reported a renderer/document error.
    pub const DOCUMENT: &str = "document.error";
    /// Private session files are missing, corrupted or inconsistent.
    pub const SESSION: &str = "session.invalid";
    /// Anything unclassified. Treated as a defect in the CLI.
    pub const INTERNAL: &str = "internal";
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Failure {
    pub code: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// Numeric JSON-RPC error code reported by the host (`rpc.rejected`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_code: Option<i64>,
    /// True when a request was sent but its effect on the host is not known.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub outcome_unknown: bool,
}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_owned(),
            message: message.into(),
            operation: None,
            request_id: None,
            duration_ms: None,
            host_code: None,
            outcome_unknown: false,
        }
    }
    /// Attach the request during which the failure happened (kept if already set).
    pub fn during(mut self, operation: &str, request_id: &str, elapsed: Duration) -> Self {
        self.operation.get_or_insert_with(|| operation.to_owned());
        self.request_id.get_or_insert_with(|| request_id.to_owned());
        self.duration_ms.get_or_insert(elapsed.as_millis() as u64);
        self
    }
    pub fn after(mut self, elapsed: Duration) -> Self {
        self.duration_ms = Some(elapsed.as_millis() as u64);
        self
    }
    pub fn unknown_outcome(mut self) -> Self {
        self.outcome_unknown = true;
        self
    }
    pub fn host_code(mut self, code: i64) -> Self {
        self.host_code = Some(code);
        self
    }
    pub fn recode(mut self, code: &'static str, message: &str) -> Self {
        self.code = code.to_owned();
        self.message = message.to_owned();
        self
    }
    /// Failures that mean the host, the transport or the CLI itself misbehaved. They are
    /// always reported as a structured record; user mistakes (input, usage) are not.
    pub fn is_critical(&self) -> bool {
        !matches!(self.code.as_str(), code::USAGE | code::INPUT)
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "error[{}]: {}", self.code, self.message)?;
        let mut details = Vec::new();
        if let Some(operation) = &self.operation {
            details.push(format!("operation {operation}"));
        }
        if let Some(id) = &self.request_id {
            details.push(format!("request {id}"));
        }
        if let Some(code) = self.host_code {
            details.push(format!("host code {code}"));
        }
        if let Some(ms) = self.duration_ms {
            details.push(format!("after {ms} ms"));
        }
        if self.outcome_unknown {
            details.push("remote outcome unknown".to_owned());
        }
        if !details.is_empty() {
            write!(f, " ({})", details.join(", "))?;
        }
        Ok(())
    }
}

impl std::error::Error for Failure {}

/// Classify any error for reporting. A `Failure` anywhere in the chain wins; other errors
/// keep their full context text under `fallback` (they originate from the CLI's own
/// messages, the OS, or parsers that report positions rather than content).
pub fn classify(error: &anyhow::Error, fallback: &'static str) -> Failure {
    for cause in error.chain() {
        if let Some(failure) = cause.downcast_ref::<Failure>() {
            return failure.clone();
        }
    }
    Failure::new(fallback, format!("{error:#}"))
}

/// Tag an error with a class unless it already carries one.
pub fn tag(error: anyhow::Error, class: &'static str) -> anyhow::Error {
    anyhow::Error::new(classify(&error, class))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_is_stable_and_machine_matchable() {
        let failure = Failure::new(code::RPC_TIMEOUT, "no response from the Core host")
            .during("document.load", "nhk-3", Duration::from_millis(1500))
            .unknown_outcome();
        assert_eq!(
            failure.to_string(),
            "error[rpc.timeout]: no response from the Core host (operation document.load, request nhk-3, after 1500 ms, remote outcome unknown)"
        );
    }

    #[test]
    fn classification_prefers_a_failure_in_the_chain() {
        let inner = anyhow::Error::new(Failure::new(code::DISCONNECTED, "closed"));
        let wrapped = inner.context("outer context");
        assert_eq!(classify(&wrapped, code::INTERNAL).code, code::DISCONNECTED);
        let plain = anyhow::anyhow!("bad row");
        let failure = classify(&plain, code::INPUT);
        assert_eq!(
            (failure.code.as_str(), failure.message.as_str()),
            (code::INPUT, "bad row")
        );
        assert!(!failure.is_critical());
        assert_eq!(
            classify(&tag(plain, code::OUTPUT), code::INTERNAL).code,
            code::OUTPUT
        );
    }

    #[test]
    fn serialized_form_omits_absent_members() {
        let text = serde_json::to_string(&Failure::new(code::HOST_FAILED, "x")).unwrap();
        assert_eq!(text, r#"{"code":"host.failed","message":"x"}"#);
        let back: Failure = serde_json::from_str(&text).unwrap();
        assert_eq!(back.code, code::HOST_FAILED);
    }
}
