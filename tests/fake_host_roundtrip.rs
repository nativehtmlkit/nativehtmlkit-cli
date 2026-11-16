//! Backend contract against a scripted host: successful sessions, user think time, the
//! explicit deadline and diagnostics. Real native GUI qualification is separate.
mod support;
use serde_json::{json, Value};
use std::time::Duration;
use support::*;

const CLI: &str = env!("CARGO_BIN_EXE_nativehtmlkit");

fn finish_quit(backend: &mut Backend) {
    let mut probes = 0;
    let quit = backend.conn.serve_until("app.request_quit", &mut probes);
    backend.conn.answer(&quit, json!({"requested":true}));
    backend.conn.shutdown();
}

#[test]
fn backend_roundtrips_auth_window_document_selection_and_shutdown() {
    let mut backend = backend(CLI, &session("select", &["<tag>", "beta"], json!({})));
    let html = backend.conn.startup();
    assert!(html.contains("&lt;tag&gt;") && !html.contains("<tag>"));
    backend.conn.click("nhk-submit");
    let mut probes = 0;
    let data = backend.conn.serve_until("document.command", &mut probes);
    assert_eq!(data["params"]["command"]["op"], "get_form_data");
    assert_eq!(data["params"]["command"]["element"], "nhk-selection-form");
    backend.conn.answer(
        &data,
        json!({"entries":[{"name":"selection","kind":"text","value":"1"}]}),
    );
    finish_quit(&mut backend);
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert_eq!(
        done.json("result.json"),
        json!({"kind":"selected","indices":[1]})
    );
    assert!(done.file("error.json").is_none());
    assert!(
        done.file("session.json").is_none(),
        "piped data must not stay on disk"
    );
    assert_eq!(
        done.file("ready").as_deref(),
        Some(std::process::id().to_string().as_str())
    );
    assert_eq!((done.stdout.as_str(), done.stderr.as_str()), ("", ""));
}

#[test]
fn request_ids_are_unique_strings_and_host_requests_are_answered() {
    let mut backend = backend(
        CLI,
        &session("select", &["a"], json!({"liveness_interval_ms":0})),
    );
    let mut ids = std::collections::HashSet::new();
    for method in [
        "host.hello",
        "host.diagnostics",
        "window.create",
        "document.load",
        "app.ready",
    ] {
        let request = backend.conn.expect(method);
        assert!(
            ids.insert(request["id"].as_str().unwrap().to_owned()),
            "id reused"
        );
        let result = match method {
            "host.hello" => json!({"protocol_version":1,"host_version":"x","capabilities":{}}),
            "window.create" => json!({"window_id":"w1"}),
            "document.load" => json!({"document_id":"d1"}),
            _ => json!({}),
        };
        backend.conn.answer(&request, result);
    }
    // Closing the window: the host asks, the client must allow; unknown requests get -32601.
    backend.conn.send(json!({"jsonrpc":"2.0","id":"h1","method":"window.before_close","params":{"window_id":"w1","reason":"user"}}));
    assert_eq!(
        backend.conn.frame().unwrap(),
        json!({"jsonrpc":"2.0","id":"h1","result":{"allow":true}})
    );
    backend.conn.send(json!({"jsonrpc":"2.0","id":"h2","method":"app.before_quit","params":{"reason":"last_window"}}));
    assert_eq!(
        backend.conn.frame().unwrap()["result"],
        json!({"allow":true})
    );
    backend
        .conn
        .send(json!({"jsonrpc":"2.0","id":"h3","method":"future.request","params":{}}));
    let reply = backend.conn.frame().unwrap();
    assert_eq!(
        (reply["id"].as_str(), reply["error"]["code"].as_i64()),
        (Some("h3"), Some(-32601))
    );
    // Unknown notifications are ignored (additive v1 changes).
    backend.conn.notify("future.notification", json!({"x":1}));
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    // Closed without a decision: no result is committed (the launcher maps this to Cancel).
    assert!(done.file("result.json").is_none());
}

/// The user may take as long as they like: several liveness intervals and several
/// per-request deadlines pass, the host keeps answering probes, and the session survives.
#[test]
fn a_slow_user_is_not_a_hung_host() {
    let mut backend = backend(
        CLI,
        &session(
            "select",
            &["a", "b"],
            json!({"rpc_timeout_ms":300,"liveness_interval_ms":100}),
        ),
    );
    backend.conn.startup();
    let probes = backend.conn.idle(Duration::from_millis(1500));
    assert!(
        probes >= 5,
        "expected regular liveness probes, saw {probes}"
    );
    backend.conn.click("nhk-submit");
    let mut more = 0;
    let data = backend.conn.serve_until("document.command", &mut more);
    backend
        .conn
        .answer(&data, json!({"entries":[{"name":"selection","value":"0"}]}));
    finish_quit(&mut backend);
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert_eq!(done.json("result.json")["indices"], json!([0]));
    assert!(done.elapsed >= Duration::from_millis(1500));
    // Progress is reported for the launcher's watchdog (at most every 200 ms).
    let beat: u64 = done.file("heartbeat").unwrap().parse().unwrap();
    assert!(
        beat >= 4,
        "heartbeat {beat} must keep advancing while probes are answered"
    );
}

/// With probing disabled the backend sends nothing while idle and still waits.
#[test]
fn liveness_probing_can_be_disabled() {
    let mut backend = backend(
        CLI,
        &session(
            "view",
            &["a"],
            json!({"rpc_timeout_ms":200,"liveness_interval_ms":0}),
        ),
    );
    backend.conn.startup();
    assert_eq!(backend.conn.idle(Duration::from_millis(900)), 0);
    backend.conn.click("nhk-done");
    let quit = backend.conn.expect("app.request_quit");
    backend.conn.answer(&quit, json!({}));
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert_eq!(done.json("result.json"), json!({"kind":"viewed"}));
}

#[test]
fn explicit_deadline_closes_the_session_as_timed_out() {
    let mut backend = backend(CLI, &session("select", &["a"], json!({"deadline_ms":400})));
    backend.conn.startup();
    let mut probes = 0;
    let quit = backend.conn.serve_until("app.request_quit", &mut probes);
    backend.conn.answer(&quit, json!({"requested":true}));
    // A click that arrives after the deadline must not turn into a result.
    backend.conn.click("nhk-submit");
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert_eq!(done.json("result.json"), json!({"kind":"timed_out"}));
    assert!(done.elapsed >= Duration::from_millis(400) && done.elapsed < Duration::from_secs(5));
}

#[test]
fn empty_submit_is_shown_in_the_window_and_the_session_continues() {
    let mut backend = backend(
        CLI,
        &session("select", &["a", "b"], json!({"liveness_interval_ms":0})),
    );
    backend.conn.startup();
    backend.conn.click("nhk-submit");
    let data = backend.conn.expect("document.command");
    backend.conn.answer(&data, json!({"entries":[]}));
    let shown = backend.conn.expect("document.command");
    assert_eq!(shown["params"]["command"]["op"], "set_text");
    assert_eq!(shown["params"]["command"]["element"], "nhk-error");
    backend.conn.answer(&shown, json!({}));
    // Clicks on rows and on foreign documents are not decisions.
    backend.conn.click("nhk-row-1");
    backend.conn.notify("document.event", json!({"window_id":"w9","document_id":"d9","event":{"type":"click","element":"nhk-submit"}}));
    // A control nested in author markup resolves through the bubbling path.
    backend.conn.notify("document.event", json!({"window_id":"w1","document_id":"d1","event":{"type":"click","element":"icon","path":["icon","nhk-cancel"]}}));
    let quit = backend.conn.expect("app.request_quit");
    backend.conn.answer(&quit, json!({}));
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert!(
        done.file("result.json").is_none(),
        "Cancel commits no result"
    );
    let records = done.records();
    assert_eq!(
        events(&records, "submit.rejected")[0]["context"]["reason"],
        "empty_selection"
    );
    assert_eq!(events(&records, "user.cancelled").len(), 1);
}

/// Trace diagnostics describe the whole session (who, what operation, which request, how
/// long) without any of the data that flowed through it.
#[test]
fn trace_records_correlate_the_session_without_exposing_data() {
    let secret_row = format!("row {SENTINEL}");
    let mut spec = session("form", &[&secret_row], json!({}));
    spec["title"] = json!(format!("title {SENTINEL}"));
    spec["html"] = json!(format!(
        "<form id='nhk-form'><input name='pw' value='{SENTINEL}'></form>"
    ));
    let mut backend = backend(CLI, &spec);
    assert!(
        backend.conn.startup().contains(SENTINEL),
        "the document itself carries the data"
    );
    backend.conn.click("nhk-submit");
    let mut probes = 0;
    let validity = backend.conn.serve_until("document.command", &mut probes);
    assert_eq!(validity["params"]["command"]["op"], "check_validity");
    backend.conn.answer(&validity, json!({"valid":true}));
    let data = backend.conn.serve_until("document.command", &mut probes);
    let entries = json!([{"kind":"text","name":"pw","value":SENTINEL}]);
    backend.conn.answer(&data, json!({"entries":entries}));
    finish_quit(&mut backend);
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    // The result channel carries the value; nothing else does.
    assert_eq!(
        done.json("result.json"),
        json!({"kind":"form","entries":entries})
    );
    assert_private(&done.side_channels(), "backend side channels");

    let records = done.records();
    assert!(records.iter().all(|r| r["session_id"] == "test-session.1"
        && r["role"] == "backend"
        && r["component"] == "nativehtmlkit-cli"));
    assert_eq!(
        events(&records, "backend.started")[0]["context"]["session_id_inherited_through_host"],
        true
    );
    // The v1 launch variables (endpoint, token, ...) are gone from the backend's environment.
    assert_eq!(
        events(&records, "backend.started")[0]["context"]["launch_environment_cleared"],
        true
    );
    let completed: Vec<(&str, &str)> = events(&records, "rpc.completed")
        .iter()
        .map(|r| {
            assert!(r["duration_ms"].is_u64(), "{r}");
            (
                r["operation"].as_str().unwrap(),
                r["request_id"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        completed,
        [
            ("host.hello", "nhk-1"),
            ("host.diagnostics", "nhk-2"),
            ("window.create", "nhk-3"),
            ("document.load", "nhk-4"),
            ("app.ready", "nhk-5"),
            ("document.command", "nhk-6"),
            ("document.command", "nhk-7"),
            ("app.request_quit", "nhk-8"),
        ]
    );
    assert_eq!(events(&records, "rpc.started").len(), completed.len());
    assert_eq!(
        events(&records, "handshake.completed")[0]["context"]["host_version"],
        "0.0.0-fake"
    );
    for event in ["window.ready", "submit.accepted", "session.shutdown"] {
        assert_eq!(events(&records, event).len(), 1, "{event}");
    }
    let received: Vec<&Value> = events(&records, "event.received")
        .iter()
        .map(|r| &r["context"]["name"])
        .collect();
    assert_eq!(received, [&json!("document.event"), &json!("app.shutdown")]);
    // Timestamps are ISO-8601 UTC with milliseconds.
    let stamp = records[0]["timestamp"].as_str().unwrap();
    assert!(
        stamp.len() == 24 && stamp.ends_with('Z') && &stamp[10..11] == "T",
        "{stamp}"
    );
}

#[test]
fn levels_filter_records_and_off_writes_nothing() {
    for (level, expect_debug, expect_trace) in [
        ("off", false, false),
        ("normal", false, false),
        ("debug", true, false),
    ] {
        let mut backend = backend(
            CLI,
            &session(
                "view",
                &["a"],
                json!({"diagnostics":level,"liveness_interval_ms":0}),
            ),
        );
        backend.conn.startup();
        backend.conn.shutdown();
        let done = backend.finish();
        assert!(done.status.success());
        let records = done.records();
        assert_eq!(
            !events(&records, "rpc.completed").is_empty(),
            expect_debug,
            "{level}"
        );
        assert_eq!(
            !events(&records, "rpc.started").is_empty(),
            expect_trace,
            "{level}"
        );
        if !expect_debug {
            assert!(records.is_empty(), "{level}: {records:?}");
        }
    }
}

/// The pending request's answer is found by its id among interleaved traffic: notifications
/// and a host request arrive first, and the events are still delivered afterwards.
#[test]
fn the_answer_is_found_by_id_among_interleaved_frames() {
    let mut backend = backend(
        CLI,
        &session("select", &["a", "b"], json!({"liveness_interval_ms":0})),
    );
    backend.conn.startup();
    backend.conn.click("nhk-submit");
    let data = backend.conn.expect("document.command");
    // While that request is pending: a click on Cancel, a notification, a host request.
    backend.conn.click("nhk-row-0");
    backend.conn.notify(
        "window.event",
        json!({"window_id":"w1","event":{"type":"moved"}}),
    );
    backend.conn.send(json!({"jsonrpc":"2.0","id":"h9","method":"window.before_close","params":{"window_id":"w1","reason":"user"}}));
    assert_eq!(backend.conn.frame().unwrap()["id"], "h9");
    backend
        .conn
        .answer(&data, json!({"entries":[{"name":"selection","value":"0"}]}));
    finish_quit(&mut backend);
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    assert_eq!(done.json("result.json")["indices"], json!([0]));
}

/// Core 1.0.3 drops window/document events for a backend that is not reading and reports
/// the count in `host.diagnostics`. The backend discloses an increase once, at the default
/// level, because a lost click is exactly a "Submit did nothing" report.
#[test]
fn notifications_dropped_by_the_host_are_disclosed() {
    let mut backend = backend(
        CLI,
        &session(
            "view",
            &["a"],
            json!({"diagnostics":"normal","rpc_timeout_ms":400,"liveness_interval_ms":100}),
        ),
    );
    backend.conn.startup();
    for dropped in [0, 3, 3, 5] {
        let probe = backend.conn.expect("host.diagnostics");
        backend.conn.answer(
            &probe,
            json!({"phase":"ready","dropped_notifications":dropped}),
        );
    }
    backend.conn.shutdown();
    let done = backend.finish();
    assert!(done.status.success(), "stderr: {}", done.stderr);
    let records = done.records();
    let totals: Vec<&Value> = events(&records, "host.notifications_dropped")
        .iter()
        .map(|r| &r["context"]["total"])
        .collect();
    assert_eq!(totals, [&json!(3), &json!(5)]);
}
