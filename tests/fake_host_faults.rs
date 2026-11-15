//! Fault injection against the backend: every way the host can go silent or send garbage
//! must end in a classified, bounded, payload-free failure, never a hang or a result.
mod support;
use serde_json::{json, Value};
use std::time::Duration;
use support::*;

const CLI: &str = env!("CARGO_BIN_EXE_nativehtmlkit");
/// Per-request deadline used by these tests (`session()` default) and the slack allowed
/// for process start-up and scheduling on a loaded machine.
const RPC: Duration = Duration::from_millis(400);
const SLACK: Duration = Duration::from_secs(4);
/// A timed wait may return up to one timer tick early when measured with another clock
/// (about 16 ms on Windows), so lower bounds on a reported duration allow for it.
const TICK_MS: u64 = 20;

fn select() -> Value {
    session("select", &["alpha", &format!("beta {SENTINEL}")], json!({}))
}

fn bounded(done: &Finished, at_least: Duration) {
    let floor = at_least - Duration::from_millis(TICK_MS);
    assert!(
        done.elapsed >= floor,
        "failed too early: {:?}",
        done.elapsed
    );
    assert!(
        done.elapsed < at_least + SLACK,
        "not bounded: {:?}",
        done.elapsed
    );
}

fn frame_bytes(body: &[u8]) -> Vec<u8> {
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(body);
    frame
}

#[test]
fn host_never_answers_the_handshake() {
    let mut backend = backend(CLI, &select());
    backend.conn.expect("host.hello");
    let done = backend.finish(); // the fake host stays connected and silent
    let failure = done.failed_with("rpc.timeout");
    assert_eq!(failure["operation"], "host.hello");
    assert_eq!(failure["request_id"], "nhk-1");
    assert_eq!(failure["outcome_unknown"], true);
    assert!(failure["duration_ms"].as_u64().unwrap() >= 400 - TICK_MS);
    bounded(&done, RPC);
    assert_private(&done.side_channels(), "handshake timeout");
}

#[test]
fn host_never_answers_a_request_after_startup() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("document.load");
    let done = backend.finish();
    let failure = done.failed_with("rpc.timeout");
    assert_eq!(failure["operation"], "document.load");
    assert!(
        done.stderr.contains("remote outcome unknown"),
        "{}",
        done.stderr
    );
    bounded(&done, RPC);
    assert!(
        done.file("ready").is_none(),
        "a session that never became ready must not say so"
    );
    let records = done.records();
    let timeout = events(&records, "rpc.timeout");
    assert_eq!(timeout.len(), 1);
    assert_eq!(timeout[0]["operation"], "document.load");
    assert_eq!(timeout[0]["error_code"], "rpc.timeout");
    assert_eq!(timeout[0]["context"]["remote_outcome"], "unknown");
    assert_eq!(
        events(&records, "backend.failed")[0]["error_code"],
        "rpc.timeout"
    );
    assert_private(&done.side_channels(), "request timeout");
}

/// A dropped request: the host stays chatty (notifications keep arriving) but never
/// answers. Notifications must not extend the per-request deadline.
#[test]
fn dropped_rpc_times_out_even_while_notifications_flow() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup();
    backend.conn.click("nhk-submit");
    let mut probes = 0;
    backend.conn.serve_until("document.command", &mut probes);
    for _ in 0..40 {
        backend.conn.notify(
            "window.event",
            json!({"window_id":"w1","event":{"type":"moved"}}),
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let done = backend.finish();
    let failure = done.failed_with("rpc.timeout");
    assert_eq!(failure["operation"], "document.command");
    let waited = failure["duration_ms"].as_u64().unwrap();
    assert!(
        (400 - TICK_MS..2000).contains(&waited),
        "deadline was stretched to {waited} ms"
    );
}

#[test]
fn host_hangs_while_the_user_is_idle() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup();
    // Healthy for a while, then the host stops answering liveness probes.
    assert!(backend.conn.idle(Duration::from_millis(600)) >= 2);
    let done = backend.finish();
    let failure = done.failed_with("host.unresponsive");
    assert_eq!(failure["operation"], "host.capabilities");
    assert!(
        done.stderr.contains("appears to have hung"),
        "{}",
        done.stderr
    );
    bounded(&done, Duration::from_millis(600) + RPC);
}

#[test]
fn host_dies_mid_request() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    drop(std::mem::replace(&mut backend.conn, dead_end()));
    let done = backend.finish();
    let failure = done.failed_with("transport.disconnected");
    assert_eq!(failure["operation"], "window.create");
    assert_eq!(failure["outcome_unknown"], true);
    assert!(
        done.elapsed < SLACK,
        "disconnect must be noticed at once: {:?}",
        done.elapsed
    );
}

#[test]
fn host_dies_while_the_user_is_idle() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup();
    drop(std::mem::replace(&mut backend.conn, dead_end()));
    let done = backend.finish();
    done.failed_with("transport.disconnected");
    assert!(done.elapsed < SLACK);
}

/// A connection whose peer end is already closed, to take the place of a dropped one.
fn dead_end() -> Conn {
    let dir = tempfile::tempdir().unwrap();
    let listener = Listener::bind(dir.path());
    let endpoint = listener.endpoint.clone();
    let client = std::thread::spawn(move || {
        #[cfg(unix)]
        drop(std::os::unix::net::UnixStream::connect(endpoint));
        #[cfg(windows)]
        drop(
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(endpoint),
        );
    });
    let conn = listener.accept();
    client.join().unwrap();
    conn
}

#[test]
fn truncated_frame_then_close() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    let mut partial = 100_u32.to_be_bytes().to_vec();
    partial.extend_from_slice(format!("{{\"x\":\"{SENTINEL}").as_bytes());
    backend.conn.raw(&partial);
    drop(std::mem::replace(&mut backend.conn, dead_end()));
    let done = backend.finish();
    let failure = done.failed_with("protocol.truncated_frame");
    assert_eq!(failure["operation"], "window.create");
    assert_private(&done.side_channels(), "truncated frame");
}

#[test]
fn truncated_header_then_close() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    backend.conn.raw(&[0, 0]);
    drop(std::mem::replace(&mut backend.conn, dead_end()));
    backend.finish().failed_with("protocol.truncated_frame");
}

/// The host starts a frame and then stalls with the connection open.
#[test]
fn frame_that_stalls_midway_is_bounded() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    let mut partial = 100_u32.to_be_bytes().to_vec();
    partial.extend_from_slice(b"{\"jsonrpc\":");
    backend.conn.raw(&partial);
    let done = backend.finish();
    done.failed_with("protocol.truncated_frame");
    assert!(done.stderr.contains("stalled"), "{}", done.stderr);
    bounded(&done, RPC);
}

#[test]
fn malformed_json_frame() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    backend.conn.raw(&frame_bytes(
        format!("{{\"id\":\"nhk-3\",\"result\":{SENTINEL}").as_bytes(),
    ));
    let done = backend.finish();
    let failure = done.failed_with("protocol.invalid_frame");
    assert_eq!(failure["operation"], "window.create");
    assert_private(&done.side_channels(), "malformed frame");
    assert!(done.elapsed < SLACK);
}

#[test]
fn frames_that_are_not_objects_or_not_utf8() {
    for body in [&b"[1,2,3]"[..], b"\"text\"", b"\xff\xfe\xfd", b"null"] {
        let mut backend = backend(CLI, &select());
        backend.conn.startup_until("window.create");
        backend.conn.raw(&frame_bytes(body));
        backend.finish().failed_with("protocol.invalid_frame");
    }
}

#[test]
fn oversized_and_zero_length_frames() {
    for length in [0_u32, MAX_FRAME as u32 + 1, u32::MAX] {
        let mut backend = backend(CLI, &select());
        backend.conn.startup_until("window.create");
        // Only the header is sent: the client must refuse before reading or allocating.
        backend.conn.raw(&length.to_be_bytes());
        let done = backend.finish();
        done.failed_with("protocol.invalid_frame");
        assert!(
            done.stderr.contains(&format!("{length} bytes")),
            "{}",
            done.stderr
        );
        assert!(done.elapsed < SLACK, "{length}: {:?}", done.elapsed);
    }
}

#[test]
fn largest_legal_frame_is_accepted() {
    let mut backend = backend(
        CLI,
        &session("view", &["a"], json!({"liveness_interval_ms":0})),
    );
    backend.conn.startup();
    // A notification padded to exactly 2 MiB must be read and ignored, not rejected.
    let skeleton = json!({"jsonrpc":"2.0","method":"future.notification","params":{"pad":""}});
    let pad = MAX_FRAME - serde_json::to_vec(&skeleton).unwrap().len();
    backend
        .conn
        .notify("future.notification", json!({"pad":"x".repeat(pad)}));
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
}

#[test]
fn uncorrelated_response_is_a_violation_and_is_not_quoted() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup_until("window.create");
    backend.conn.send(
        json!({"jsonrpc":"2.0","id":"someone-else","result":{"entries":[{"value":SENTINEL}]}}),
    );
    let done = backend.finish();
    let failure = done.failed_with("protocol.violation");
    assert_eq!(failure["operation"], "window.create");
    assert_private(&done.side_channels(), "uncorrelated response");
}

#[test]
fn response_without_a_pending_request_is_a_violation() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup();
    backend
        .conn
        .send(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":SENTINEL}}));
    let done = backend.finish();
    done.failed_with("protocol.violation");
    assert_private(&done.side_channels(), "stray response");
}

#[test]
fn host_error_keeps_the_numeric_code_and_drops_the_message() {
    let mut backend = backend(CLI, &select());
    let request = {
        backend.conn.startup_until("document.load");
        // startup_until consumed document.load without answering; reject it like Core
        // does for oversized HTML, with a message that quotes user data.
        json!({"id":"nhk-4"})
    };
    backend.conn.send(json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32005,"message":format!("busy: {SENTINEL}"),"data":{"echo":SENTINEL}}}));
    let done = backend.finish();
    let failure = done.failed_with("rpc.rejected");
    assert_eq!(failure["host_code"], -32005);
    assert_eq!(failure["operation"], "document.load");
    assert!(
        failure.get("outcome_unknown").is_none(),
        "a rejection is a known outcome"
    );
    assert!(done.stderr.contains("host code -32005"), "{}", done.stderr);
    assert_private(&done.side_channels(), "host error");
}

#[test]
fn handshake_rejections_fail_closed() {
    for (reply, code) in [
        (
            json!({"error":{"code":-32011,"message":"unauthenticated"}}),
            "protocol.handshake_failed",
        ),
        (
            json!({"error":{"code":-32010,"message":"version"}}),
            "protocol.handshake_failed",
        ),
        (
            json!({"result":{"protocol_version":2,"host_version":"9"}}),
            "protocol.handshake_failed",
        ),
        (json!({"result":{}}), "protocol.handshake_failed"),
        (json!({}), "protocol.violation"),
    ] {
        let mut backend = backend(CLI, &select());
        let hello = backend.conn.expect("host.hello");
        let mut message = reply.clone();
        message["jsonrpc"] = json!("2.0");
        message["id"] = hello["id"].clone();
        backend.conn.send(message);
        let done = backend.finish();
        done.failed_with(code);
        assert!(done.file("ready").is_none());
        assert_private(&done.side_channels(), "handshake");
    }
}

#[test]
fn renderer_error_notification_fails_without_quoting_the_document() {
    let mut backend = backend(CLI, &select());
    backend.conn.startup();
    backend.conn.notify(
        "document.error",
        json!({"window_id":"w1","document_id":"d1","message":format!("near '{SENTINEL}'")}),
    );
    let done = backend.finish();
    done.failed_with("document.error");
    assert_private(&done.side_channels(), "document.error");
}

#[test]
fn selection_the_page_cannot_produce_fails_the_session() {
    for entries in [
        json!([{"name":"selection","value":"7"}]),
        json!([{"name":"selection","value":"0"},{"name":"selection","value":"0"}]),
        json!([{"name":"selection","value":SENTINEL}]),
        json!("not-an-array"),
    ] {
        let mut backend = backend(
            CLI,
            &session("select", &["a", "b"], json!({"liveness_interval_ms":0})),
        );
        backend.conn.startup();
        backend.conn.click("nhk-submit");
        let data = backend.conn.expect("document.command");
        backend.conn.answer(&data, json!({"entries":entries}));
        let done = backend.finish();
        done.failed_with("protocol.violation");
        assert_private(&done.side_channels(), "bad selection");
    }
}

/// The host acknowledges the quit request and then never shuts the session down.
#[test]
fn quit_that_never_completes_is_bounded() {
    let mut backend = backend(
        CLI,
        &session(
            "select",
            &["a"],
            json!({"rpc_timeout_ms":300,"liveness_interval_ms":200}),
        ),
    );
    backend.conn.startup();
    backend.conn.click("nhk-cancel");
    let mut probes = 0;
    let quit = backend.conn.serve_until("app.request_quit", &mut probes);
    backend.conn.answer(&quit, json!({"requested":true}));
    // Still alive (answers probes) for longer than rpc timeout + host shutdown allowance.
    backend.conn.idle(Duration::from_millis(6500));
    let done = backend.finish();
    done.failed_with("host.shutdown_timeout");
    assert!(
        done.elapsed >= Duration::from_millis(5300),
        "{:?}",
        done.elapsed
    );
}

#[test]
fn backend_refuses_to_run_without_host_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let spec = serde_json::to_vec(&select()).unwrap();
    std::fs::write(dir.path().join("session.json"), &spec).unwrap();
    for (endpoint, token) in [
        (None, None),
        (Some("unused"), None),
        (Some("unused"), Some("short")),
        (Some("unused"), Some(&*"g".repeat(64))),
    ] {
        let mut command = std::process::Command::new(CLI);
        command.arg("__backend").arg(dir.path());
        for key in ["UI4ME_ENDPOINT", "UI4ME_TOKEN"] {
            command.env_remove(key);
        }
        if let Some(endpoint) = endpoint {
            command.env("UI4ME_ENDPOINT", endpoint);
        }
        if let Some(token) = token {
            command.env("UI4ME_TOKEN", token);
        }
        let output = command.output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("error[protocol.handshake_failed]"),
            "{stderr}"
        );
        // The piped data was not consumed by an unauthenticated start.
        assert_eq!(
            std::fs::read(dir.path().join("session.json")).unwrap(),
            spec
        );
        let _ = std::fs::remove_file(dir.path().join("error.json"));
    }
}

#[test]
fn unreachable_endpoint_is_a_connect_failure_without_the_path() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("session.json"),
        serde_json::to_vec(&select()).unwrap(),
    )
    .unwrap();
    #[cfg(unix)]
    let endpoint = dir
        .path()
        .join("missing.sock")
        .to_string_lossy()
        .into_owned();
    #[cfg(windows)]
    let endpoint = format!(r"\\.\pipe\nhk-missing-{}", std::process::id());
    let output = std::process::Command::new(CLI)
        .arg("__backend")
        .arg(dir.path())
        .env("UI4ME_ENDPOINT", &endpoint)
        .env("UI4ME_TOKEN", TOKEN)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("error[transport.connect_failed]"),
        "{stderr}"
    );
    assert!(
        !stderr.contains(&endpoint) && !stderr.contains(TOKEN),
        "{stderr}"
    );
}

/// FR-R-01: the real host kills the backend the moment the connection closes. Whatever the
/// backend has to say about a failure must therefore be on disk before it disconnects; the
/// scripted host checks at the instant it sees end-of-file.
#[test]
fn failure_is_recorded_before_the_connection_closes() {
    for _ in 0..10 {
        let mut backend = backend(CLI, &select());
        backend.conn.startup_until("window.create");
        // Reject window.create; the backend fails and will disconnect.
        backend
            .conn
            .send(json!({"jsonrpc":"2.0","id":"nhk-3","error":{"code":-32005,"message":"busy"}}));
        assert!(
            backend.conn.frame().is_none(),
            "the backend should disconnect after the failure"
        );
        let recorded = std::fs::read_to_string(backend.dir.path().join("error.json")).ok();
        let diagnostics =
            std::fs::read_to_string(backend.dir.path().join("diag.ndjson")).unwrap_or_default();
        kill_pid(backend.child.id()); // what Core does on disconnect
        let _ = backend.child.wait();
        let failure: Value = serde_json::from_str(
            &recorded.expect("error.json must exist when the host sees the disconnect"),
        )
        .unwrap();
        assert_eq!(failure["code"], "rpc.rejected");
        assert!(
            diagnostics.contains("\"event\":\"backend.failed\""),
            "backend.failed must be recorded before the disconnect"
        );
    }
}

/// FR-R-16: notifications queued behind a pending request are bounded in bytes, not only in
/// number: five 2 MiB notifications exceed the 8 MiB allowance.
#[test]
fn queued_notifications_are_bounded_in_bytes() {
    let mut backend = backend(
        CLI,
        &session(
            "select",
            &["a"],
            json!({"rpc_timeout_ms":8000,"liveness_interval_ms":0}),
        ),
    );
    backend.conn.startup_until("window.create");
    let skeleton = json!({"jsonrpc":"2.0","method":"future.notification","params":{"pad":""}});
    let pad = "x".repeat(MAX_FRAME - serde_json::to_vec(&skeleton).unwrap().len());
    for _ in 0..5 {
        backend
            .conn
            .notify("future.notification", json!({"pad":pad}));
    }
    let done = backend.finish();
    let failure = done.failed_with("protocol.violation");
    assert_eq!(failure["operation"], "window.create");
    assert!(
        done.elapsed < Duration::from_secs(6),
        "refused on size, not on the deadline: {:?}",
        done.elapsed
    );
}

/// Four such notifications (8 MiB minus a little) are within the allowance.
#[test]
fn notifications_within_the_byte_allowance_are_kept() {
    let mut backend = backend(
        CLI,
        &session(
            "view",
            &["a"],
            json!({"rpc_timeout_ms":8000,"liveness_interval_ms":0}),
        ),
    );
    backend.conn.startup_until("window.create");
    let pad = "x".repeat(MAX_FRAME - 4096);
    for _ in 0..3 {
        backend
            .conn
            .notify("future.notification", json!({"pad":pad}));
    }
    backend
        .conn
        .send(json!({"jsonrpc":"2.0","id":"nhk-3","result":{"window_id":"w1"}}));
    for method in ["document.load", "app.ready"] {
        let request = backend.conn.expect(method);
        backend.conn.answer(&request, json!({"document_id":"d1"}));
    }
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
}
