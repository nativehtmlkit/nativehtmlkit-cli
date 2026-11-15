//! Independent Rust client for the Core v1 local JSON-RPC protocol.
//! The CLI does NOT link Core's renderer or private Rust crates.
//!
//! Every operation is bounded: a request must be answered within the per-request deadline,
//! a frame that has started must complete within it, and a write must be accepted within
//! it. Only `next_event` waits for the *user*, and it does so in slices so the caller can
//! probe host liveness in between. Failures never quote frame contents.
use crate::diag::{self, Level};
use crate::error::{code, Failure};
use crate::transport::{Budget, ReadStatus, Stream};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const MAX_FRAME: usize = 2_097_152;
/// Notifications buffered while a request is in flight. The host emits a handful per
/// user action; far more than this without a response means the peer is misbehaving.
const MAX_QUEUED: usize = 1024;
/// ...and their total size: a count alone would allow 1,024 frames of 2 MiB each.
const MAX_QUEUED_BYTES: usize = 8 * 1024 * 1024;
/// Progress is reported to the launcher at most this often.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);
const CONNECT_PATIENCE: Duration = Duration::from_secs(10);

/// Client→host methods this CLI uses (all present in Core's `v1/method-matrix.json`).
/// Keeping them `&'static` lets diagnostics name the operation without a dynamic string.
pub mod method {
    pub const HELLO: &str = "host.hello";
    pub const CAPABILITIES: &str = "host.capabilities";
    pub const DIAGNOSTICS: &str = "host.diagnostics";
    pub const WINDOW_CREATE: &str = "window.create";
    pub const DOCUMENT_LOAD: &str = "document.load";
    pub const DOCUMENT_COMMAND: &str = "document.command";
    pub const READY: &str = "app.ready";
    pub const REQUEST_QUIT: &str = "app.request_quit";
}

pub type Rpc<T> = Result<T, Failure>;

pub fn encode_frame(message: &Value) -> Rpc<Vec<u8>> {
    let body = serde_json::to_vec(message)
        .map_err(|_| Failure::new(code::INTERNAL, "cannot encode an RPC frame"))?;
    if body.is_empty() || body.len() > MAX_FRAME {
        return Err(Failure::new(
            code::INTERNAL,
            format!(
                "outgoing RPC frame of {} bytes exceeds the 2 MiB protocol limit",
                body.len()
            ),
        ));
    }
    let mut frame = Vec::with_capacity(body.len() + 4);
    frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

/// Validate a declared frame length before allocating for it.
pub fn check_length(header: [u8; 4]) -> Rpc<usize> {
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME {
        return Err(Failure::new(
            code::INVALID_FRAME,
            format!("host declared a frame of {length} bytes (allowed: 1 to {MAX_FRAME})"),
        ));
    }
    Ok(length)
}

pub fn decode_body(bytes: &[u8]) -> Rpc<Value> {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(value) if value.is_object() => Ok(value),
        Ok(_) => Err(Failure::new(
            code::INVALID_FRAME,
            "host frame is valid JSON but not an object",
        )),
        Err(_) => Err(Failure::new(
            code::INVALID_FRAME,
            format!(
                "host frame of {} bytes is not valid UTF-8 JSON",
                bytes.len()
            ),
        )),
    }
}

/// What a frame from the host is, by the v1 envelope rules.
enum Incoming {
    HostRequest { id: String, name: String },
    Notification(Value),
    Response(Value),
}

fn classify(message: Value) -> Incoming {
    match message.get("method").and_then(Value::as_str) {
        Some(name) => match message.get("id").and_then(Value::as_str) {
            Some(id) => Incoming::HostRequest {
                id: id.to_owned(),
                name: name.to_owned(),
            },
            None => Incoming::Notification(message),
        },
        None => Incoming::Response(message),
    }
}

/// Host→client names from the v1 matrix; anything else is reported as "other" so a
/// misbehaving peer cannot inject text into diagnostics.
pub fn known_name(name: &str) -> &'static str {
    match name {
        "window.before_close" => "window.before_close",
        "app.before_quit" => "app.before_quit",
        "app.shutdown" => "app.shutdown",
        "app.activated" => "app.activated",
        "window.event" => "window.event",
        "document.event" => "document.event",
        "document.error" => "document.error",
        "request.cancelled" => "request.cancelled",
        "desktop.preferences_changed" => "desktop.preferences_changed",
        _ => "other",
    }
}

pub struct Client {
    stream: Stream,
    next_id: u64,
    queued: VecDeque<(Value, usize)>,
    queued_bytes: usize,
    rpc_timeout: Duration,
    progress: Option<Progress>,
}

/// Where and how often "the host answered" is reported (the launcher's heartbeat file).
struct Progress {
    dir: std::path::PathBuf,
    count: u64,
    last: Instant,
}

impl Client {
    pub fn connect(endpoint: &str, rpc_timeout: Duration) -> Rpc<Self> {
        if endpoint.trim().is_empty() {
            return Err(Failure::new(code::CONNECT, "host endpoint missing"));
        }
        let started = Instant::now();
        // The endpoint path is not repeated in the failure: it is a per-user runtime path.
        let stream = Stream::connect(endpoint, CONNECT_PATIENCE).map_err(|error| {
            Failure::new(
                code::CONNECT,
                format!(
                    "cannot connect to the Core host endpoint ({})",
                    error.kind()
                ),
            )
            .after(started.elapsed())
        })?;
        Ok(Self {
            stream,
            next_id: 0,
            queued: VecDeque::new(),
            queued_bytes: 0,
            rpc_timeout,
            progress: None,
        })
    }

    /// Start reporting every frame received from the host as progress in `dir`.
    pub fn report_progress_to(&mut self, dir: &std::path::Path) {
        crate::session::beat(dir, 0);
        self.progress = Some(Progress {
            dir: dir.to_path_buf(),
            count: 0,
            last: Instant::now(),
        });
    }

    fn progressed(&mut self) {
        if let Some(progress) = &mut self.progress {
            if progress.last.elapsed() >= PROGRESS_INTERVAL {
                progress.count += 1;
                progress.last = Instant::now();
                crate::session::beat(&progress.dir, progress.count);
            }
        }
    }

    pub fn hello(&mut self, token: &str) -> Rpc<Value> {
        let result = self
            .call(
                method::HELLO,
                json!({"token":token,"protocol_version":1,
                "client":{"name":"nativehtmlkit-cli","version":env!("CARGO_PKG_VERSION")}}),
            )
            .map_err(|failure| {
                if failure.code == code::RPC_REJECTED {
                    failure.recode(code::HANDSHAKE, "the Core host rejected the handshake")
                } else {
                    failure
                }
            })?;
        if result.get("protocol_version").and_then(Value::as_u64) != Some(1) {
            return Err(Failure::new(
                code::HANDSHAKE,
                "the Core host does not speak protocol version 1",
            ));
        }
        Ok(result)
    }

    fn send(&mut self, message: &Value) -> Rpc<()> {
        let frame = encode_frame(message)?;
        self.stream
            .write_all(&frame, self.rpc_timeout)
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::TimedOut => Failure::new(
                    code::RPC_TIMEOUT,
                    "the Core host stopped reading from the connection",
                ),
                kind => Failure::new(
                    code::DISCONNECTED,
                    format!("the Core host connection failed while sending ({kind})"),
                ),
            })
    }

    /// Fill `buffer` for a frame that has already started; the frame must keep arriving.
    fn fill(&mut self, buffer: &mut [u8], budget: &mut Budget, part: &str) -> Rpc<()> {
        let mut filled = 0;
        while filled < buffer.len() {
            let wait = budget.left();
            if wait.is_zero() {
                return Err(Failure::new(
                    code::TRUNCATED,
                    format!("host frame stalled inside its {part}"),
                ));
            }
            let started = Instant::now();
            let status = self
                .stream
                .read(&mut buffer[filled..], wait)
                .map_err(read_error)?;
            budget.charge(wait, started, status == ReadStatus::TimedOut);
            match status {
                ReadStatus::Data(n) => filled += n,
                ReadStatus::TimedOut => {}
                ReadStatus::Closed => {
                    return Err(Failure::new(
                        code::TRUNCATED,
                        format!("host closed the connection inside a frame {part}"),
                    ))
                }
            }
        }
        Ok(())
    }

    /// Read one frame. `Ok(None)` means nothing at all arrived within `first_wait`.
    fn read_frame(&mut self, first_wait: Duration) -> Rpc<Option<(Value, usize)>> {
        let mut header = [0_u8; 4];
        let got = match self
            .stream
            .read(&mut header, first_wait)
            .map_err(read_error)?
        {
            ReadStatus::TimedOut => return Ok(None),
            ReadStatus::Closed => {
                return Err(Failure::new(
                    code::DISCONNECTED,
                    "the Core host closed the connection",
                ))
            }
            ReadStatus::Data(n) => n,
        };
        let mut budget = Budget::new(self.rpc_timeout);
        self.fill(&mut header[got..], &mut budget, "header")?;
        let length = check_length(header)?;
        let mut body = vec![0_u8; length];
        self.fill(&mut body, &mut budget, "body")?;
        let message = decode_body(&body)?;
        self.progressed();
        Ok(Some((message, length)))
    }

    /// Send one request and wait for its response, at most the per-request deadline.
    /// Interleaved notifications are queued; host requests are answered.
    pub fn call(&mut self, name: &'static str, params: Value) -> Rpc<Value> {
        self.call_within(name, params, self.rpc_timeout)
    }

    fn call_within(&mut self, name: &'static str, params: Value, allowed: Duration) -> Rpc<Value> {
        self.next_id += 1;
        let id = format!("nhk-{}", self.next_id);
        let started = Instant::now();
        diag::record(Level::Trace, "rpc.started")
            .request(&id)
            .operation(name)
            .emit();
        let outcome = self.exchange(name, &id, params, allowed);
        match &outcome {
            Ok(_) => diag::record(Level::Debug, "rpc.completed")
                .request(&id)
                .operation(name)
                .duration(started.elapsed())
                .emit(),
            Err(failure) => {
                let event = if failure.code == code::RPC_TIMEOUT {
                    "rpc.timeout"
                } else {
                    "rpc.failed"
                };
                diag::record(Level::Normal, event)
                    .operation(name)
                    .duration(started.elapsed())
                    .failure(failure)
                    .emit();
            }
        }
        outcome
    }

    fn exchange(
        &mut self,
        name: &'static str,
        id: &str,
        params: Value,
        allowed: Duration,
    ) -> Rpc<Value> {
        let started = Instant::now();
        let context = |failure: Failure| failure.during(name, id, started.elapsed());
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":name,"params":params}))
            .map_err(|failure| context(failure).unknown_outcome())?;
        let mut budget = Budget::new(allowed);
        loop {
            let wait = budget.left();
            let waited = Instant::now();
            let frame = if wait.is_zero() {
                None
            } else {
                // Once a request is on the wire its effect is unknown unless a response
                // says otherwise, whatever goes wrong while waiting for it.
                self.read_frame(wait)
                    .map_err(|failure| context(failure).unknown_outcome())?
            };
            let Some((message, size)) = frame else {
                return Err(context(
                    Failure::new(
                        code::RPC_TIMEOUT,
                        "the Core host did not answer the request in time",
                    )
                    .unknown_outcome(),
                ));
            };
            budget.charge(wait, waited, false);
            match classify(message) {
                Incoming::HostRequest { id, name } => self
                    .reply_host_request(&id, &name)
                    .map_err(|failure| context(failure).unknown_outcome())?,
                Incoming::Notification(message) => {
                    if self.queued.len() >= MAX_QUEUED
                        || self.queued_bytes + size > MAX_QUEUED_BYTES
                    {
                        return Err(context(
                            Failure::new(
                                code::VIOLATION,
                                "host sent too many notifications without answering a request",
                            )
                            .unknown_outcome(),
                        ));
                    }
                    self.queued_bytes += size;
                    self.queued.push_back((message, size));
                }
                Incoming::Response(message) => {
                    if message.get("id").and_then(Value::as_str) != Some(id) {
                        return Err(context(
                            Failure::new(
                                code::VIOLATION,
                                "host sent a response that matches no pending request",
                            )
                            .unknown_outcome(),
                        ));
                    }
                    return response_result(&message).map_err(context);
                }
            }
        }
    }

    fn reply_host_request(&mut self, id: &str, name: &str) -> Rpc<()> {
        diag::record(Level::Debug, "host.request")
            .tag("name", known_name(name))
            .emit();
        let message = match name {
            "window.before_close" | "app.before_quit" => {
                json!({"jsonrpc":"2.0","id":id,"result":{"allow":true}})
            }
            _ => {
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}})
            }
        };
        self.send(&message)
    }

    /// Wait at most `slice` for the next host notification. `Ok(None)` means the host sent
    /// nothing in that time, which is normal while the user is thinking; the caller
    /// decides when to probe liveness.
    pub fn next_event(&mut self, slice: Duration) -> Rpc<Option<Value>> {
        if let Some((message, size)) = self.queued.pop_front() {
            self.queued_bytes -= size;
            return Ok(Some(message));
        }
        let mut budget = Budget::new(slice);
        loop {
            let wait = budget.left();
            if wait.is_zero() {
                return Ok(None);
            }
            let waited = Instant::now();
            let Some((message, _)) = self.read_frame(wait)? else {
                return Ok(None);
            };
            budget.charge(wait, waited, false);
            match classify(message) {
                Incoming::HostRequest { id, name } => self.reply_host_request(&id, &name)?,
                Incoming::Notification(message) => return Ok(Some(message)),
                // No request is pending here, so any response is uncorrelated.
                Incoming::Response(_) => {
                    return Err(Failure::new(
                        code::VIOLATION,
                        "host sent a response while no request was pending",
                    ))
                }
            }
        }
    }

    /// Ask the host's event loop to answer a trivial request. Any response, even an error,
    /// proves it is alive; silence for twice the per-request deadline means it has hung.
    pub fn probe(&mut self) -> Rpc<()> {
        let started = Instant::now();
        // A healthy host can be busy for a while (a large relayout, a native modal loop).
        // Ending a session over that would discard the user's input, which is worse than
        // noticing a real hang late, so a probe is allowed twice the per-request deadline.
        match self.call_within(method::CAPABILITIES, json!({}), self.rpc_timeout * 2) {
            Ok(_) => {}
            Err(failure) if failure.code == code::RPC_REJECTED => {}
            Err(failure) if failure.code == code::RPC_TIMEOUT => {
                return Err(failure.recode(
                    code::HOST_UNRESPONSIVE,
                    "the Core host is running but stopped answering; it appears to have hung",
                ))
            }
            Err(failure) => return Err(failure),
        }
        diag::record(Level::Trace, "liveness.ok")
            .duration(started.elapsed())
            .emit();
        Ok(())
    }
}

fn read_error(error: std::io::Error) -> Failure {
    Failure::new(
        code::DISCONNECTED,
        format!(
            "the Core host connection failed while reading ({})",
            error.kind()
        ),
    )
}

fn response_result(message: &Value) -> Rpc<Value> {
    if let Some(error) = message.get("error") {
        // Unknown or missing codes are still failures; the message text is host-authored
        // and may quote parameters, so only the numeric code is kept.
        let host_code = error.get("code").and_then(Value::as_i64).unwrap_or(-32603);
        return Err(
            Failure::new(code::RPC_REJECTED, "the Core host rejected the request")
                .host_code(host_code),
        );
    }
    message.get("result").cloned().ok_or_else(|| {
        Failure::new(
            code::VIOLATION,
            "host response has neither result nor error",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_roundtrip() {
        let message = json!({"jsonrpc":"2.0","id":"nhk-1","method":"host.hello","params":{}});
        let frame = encode_frame(&message).unwrap();
        let length = check_length(frame[..4].try_into().unwrap()).unwrap();
        assert_eq!(length, frame.len() - 4);
        assert_eq!(decode_body(&frame[4..]).unwrap(), message);
    }

    #[test]
    fn frame_lengths_outside_the_contract_are_rejected_before_allocation() {
        assert_eq!(
            check_length([0, 0, 0, 0]).unwrap_err().code,
            code::INVALID_FRAME
        );
        assert_eq!(
            check_length([0, 0x20, 0, 1]).unwrap_err().code,
            code::INVALID_FRAME
        );
        assert_eq!(
            check_length([0xff; 4]).unwrap_err().code,
            code::INVALID_FRAME
        );
        assert_eq!(check_length([0, 0x20, 0, 0]).unwrap(), MAX_FRAME);
        assert_eq!(check_length([0, 0, 0, 1]).unwrap(), 1);
    }

    #[test]
    fn oversized_outgoing_frames_are_refused() {
        let big = json!({"x": "a".repeat(MAX_FRAME)});
        assert_eq!(encode_frame(&big).unwrap_err().code, code::INTERNAL);
    }

    #[test]
    fn bodies_must_be_json_objects_and_failures_do_not_quote_them() {
        for body in [
            &b"{\"a\":SENTINEL"[..],
            b"[1,2]",
            b"\"SENTINEL\"",
            b"\xff\xfe",
        ] {
            let failure = decode_body(body).unwrap_err();
            assert_eq!(failure.code, code::INVALID_FRAME);
            assert!(!failure.to_string().contains("SENTINEL"));
        }
    }

    #[test]
    fn host_errors_never_return_success_and_keep_only_the_numeric_code() {
        let failure = response_result(
            &json!({"id":"nhk-1","error":{"code":-32010,"message":"SENTINEL version"}}),
        )
        .unwrap_err();
        assert_eq!(failure.code, code::RPC_REJECTED);
        assert_eq!(failure.host_code, Some(-32010));
        assert!(!failure.to_string().contains("SENTINEL"));
        // An error object without a usable code is still an error.
        assert!(response_result(&json!({"id":"nhk-1","error":{}})).is_err());
        assert_eq!(
            response_result(&json!({"id":"nhk-1"})).unwrap_err().code,
            code::VIOLATION
        );
        assert_eq!(
            response_result(&json!({"id":"nhk-1","result":{"ok":1}})).unwrap(),
            json!({"ok":1})
        );
    }

    #[test]
    fn envelope_classification_follows_the_v1_rules() {
        assert!(matches!(
            classify(json!({"method":"app.before_quit","id":"h1","params":{}})),
            Incoming::HostRequest { .. }
        ));
        assert!(matches!(
            classify(json!({"method":"app.shutdown","params":{}})),
            Incoming::Notification(_)
        ));
        // A non-string id with a method is a notification-shaped frame, not a request.
        assert!(matches!(
            classify(json!({"method":"x","id":7})),
            Incoming::Notification(_)
        ));
        assert!(matches!(
            classify(json!({"id":"nhk-1","result":{}})),
            Incoming::Response(_)
        ));
        assert_eq!(known_name("document.event"), "document.event");
        assert_eq!(known_name("SENTINEL"), "other");
    }
}
