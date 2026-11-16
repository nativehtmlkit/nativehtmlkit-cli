//! End-to-end tests of the real `nativehtmlkit` executable as a pipeline stage: exact
//! stdout bytes, exit status, stderr discipline, bounded failure and process cleanup.
//!
//! This test binary doubles as the host: the CLI is pointed at it with `--host`, launches
//! it as `<exe> run --app <manifest>`, and it then plays a scripted Core host (see
//! `support`), including starting the CLI's own `__backend` exactly as Core does. Hence
//! `harness = false`: `main` decides between "be the fake host" and "run the tests".
mod support;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use support::*;

const CLI: &str = env!("CARGO_BIN_EXE_nativehtmlkit");
const SCENARIO: &str = "NHK_FAKE_SCENARIO";
const RECORD: &str = "NHK_FAKE_RECORD";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Ok(scenario) = std::env::var(SCENARIO) {
        std::process::exit(fake_host(&scenario, &args));
    }
    run_tests(&args);
}

// ---------------------------------------------------------------- the fake host process

fn record(key: &str, value: &str) {
    if let Ok(path) = std::env::var(RECORD) {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        writeln!(file, "{key}={value}").unwrap();
    }
}

fn hang() -> ! {
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

fn fake_host(scenario: &str, args: &[String]) -> i32 {
    if args.first().map(String::as_str) == Some("--version") {
        if scenario == "version_hang" {
            hang();
        }
        println!("nativehtmlkit-host 0.0.0-fake");
        return 0;
    }
    assert_eq!(&args[..2], ["run", "--app"], "host invoked as {args:?}");
    let manifest_path = PathBuf::from(&args[2]);
    record("host_pid", &std::process::id().to_string());
    for key in [
        "NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID",
        "NATIVEHTMLKIT_DIAGNOSTICS",
    ] {
        record(
            key,
            &std::env::var(key).unwrap_or_else(|_| "<unset>".into()),
        );
    }
    // Like the real host, log to stderr; the CLI must pass this through untouched.
    eprintln!("{{\"fake_host\":\"started\"}}");
    if std::env::var_os("NHK_FAKE_CHATTY").is_some() {
        // A host that logs continuously (one complete line per write, as Core does) on the
        // stderr it shares with the launcher.
        std::thread::spawn(|| {
            use std::io::Write;
            let mut n = 0_u64;
            loop {
                n += 1;
                let line = format!(
                    "{{\"fake_host\":\"log\",\"n\":{n},\"pad\":\"{}\"}}\n",
                    "x".repeat(200)
                );
                let _ = std::io::stderr().lock().write_all(line.as_bytes());
                std::thread::sleep(Duration::from_micros(200));
            }
        });
    }
    match scenario {
        "never_start" => hang(),
        "exit_7" => return 7,
        // Like Core on Linux: this process only supervises; the host that owns the
        // endpoint is a separate process that can hang independently of it.
        "supervised_hang" => {
            let status = Command::new(std::env::current_exe().unwrap())
                .args(args)
                .env(SCENARIO, "hang_when_idle")
                .status()
                .unwrap();
            return status.code().unwrap_or(1);
        }
        _ => {}
    }
    let app_dir = manifest_path.parent().unwrap();
    let manifest: toml::Value =
        toml::from_str(&std::fs::read_to_string(&manifest_path).unwrap()).unwrap();
    record(
        "startup_timeout_ms",
        &manifest["host"]["startup_timeout_ms"].to_string(),
    );
    let substitute = |text: &str| text.replace("{app_dir}", &app_dir.to_string_lossy());
    let own = tempfile::tempdir().unwrap();
    let listener = Listener::bind(own.path());
    let mut backend = Command::new(manifest["backend"]["program"].as_str().unwrap())
        .args(
            manifest["backend"]["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|a| substitute(a.as_str().unwrap())),
        )
        .current_dir(substitute(manifest["backend"]["cwd"].as_str().unwrap()))
        .env("UI4ME_ENDPOINT", &listener.endpoint)
        .env("UI4ME_TOKEN", TOKEN)
        .env("UI4ME_APP_ID", manifest["app"]["id"].as_str().unwrap())
        .env("UI4ME_PROTOCOL_VERSION", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    record("backend_pid", &backend.id().to_string());
    let mut conn = listener.accept();
    let mut probes = 0;
    let (name, argument) = scenario.split_once(':').unwrap_or((scenario, ""));
    match name {
        "die_mid_request" => {
            conn.startup_until("document.load");
            // A crash: no clean-up, the backend is simply abandoned.
            std::process::exit(3);
        }
        "hang_at_load" => {
            conn.startup_until("document.load");
            hang();
        }
        _ => {}
    }
    let html = conn.startup();
    record("html_bytes", &html.len().to_string());
    match name {
        "hang_when_idle" => hang(),
        "select" | "idle_then_select" => {
            if name == "idle_then_select" {
                record(
                    "probes",
                    &conn.idle(Duration::from_millis(1500)).to_string(),
                );
            }
            conn.click("nhk-submit");
            let data = conn.serve_until("document.command", &mut probes);
            let entries: Vec<Value> = argument
                .split(',')
                .filter(|i| !i.is_empty())
                .map(|i| json!({"name":"selection","kind":"text","value":i}))
                .collect();
            conn.answer(&data, json!({"entries":entries}));
        }
        "form" => {
            conn.click("nhk-submit");
            let validity = conn.serve_until("document.command", &mut probes);
            conn.answer(&validity, json!({"valid":true}));
            let data = conn.serve_until("document.command", &mut probes);
            conn.answer(
                &data,
                json!({"entries":[{"kind":"text","name":"pw","value":SENTINEL}]}),
            );
        }
        // FR-R-09: a host that is slow but answers every request inside the per-request
        // deadline: three rejected submits and one accepted one are seven consecutive
        // requests, each taking `argument` ms, with no other traffic in between.
        "slow_host" => {
            let delay = Duration::from_millis(argument.parse().unwrap());
            for _ in 0..3 {
                conn.click("nhk-submit");
                let data = conn.serve_until("document.command", &mut probes);
                std::thread::sleep(delay);
                conn.answer(&data, json!({"entries":[]}));
                let shown = conn.serve_until("document.command", &mut probes);
                assert_eq!(shown["params"]["command"]["op"], "set_text");
                std::thread::sleep(delay);
                conn.answer(&shown, json!({}));
            }
            conn.click("nhk-submit");
            let data = conn.serve_until("document.command", &mut probes);
            std::thread::sleep(delay);
            conn.answer(&data, json!({"entries":[{"name":"selection","value":"1"}]}));
        }
        // Submit and closing the window in the same instant: the host is already shutting
        // down, rejects the backend's request with -32008 and announces the shutdown.
        "submit_collides_with_close" => {
            conn.click("nhk-submit");
            let data = conn.serve_until("document.command", &mut probes);
            conn.send(json!({"jsonrpc":"2.0","id":data["id"],"error":{"code":-32008,"message":"Application is shutting down or failed"}}));
            conn.shutdown();
            return i32::from(!backend.wait().unwrap().success());
        }
        "cancel" => conn.click("nhk-cancel"),
        "done" => conn.click("nhk-done"),
        // The user closes the window: the host runs its quit lifecycle by itself.
        "close" => {
            conn.send(json!({"jsonrpc":"2.0","id":"h1","method":"app.before_quit","params":{"reason":"last_window"}}));
            assert_eq!(conn.frame().unwrap()["result"]["allow"], true);
            conn.shutdown();
            return i32::from(!backend.wait().unwrap().success());
        }
        "wait_for_deadline" => {}
        // The whole session succeeds; only the host process then fails to exit.
        "hang_after_shutdown" => {
            conn.click("nhk-submit");
            let data = conn.serve_until("document.command", &mut probes);
            conn.answer(&data, json!({"entries":[{"name":"selection","value":"0"}]}));
            let quit = conn.serve_until("app.request_quit", &mut probes);
            conn.answer(&quit, json!({"requested":true}));
            conn.shutdown();
            let _ = backend.wait();
            hang();
        }
        other => panic!("unknown scenario {other}"),
    }
    let quit = conn.serve_until("app.request_quit", &mut probes);
    conn.answer(&quit, json!({"requested":true}));
    conn.shutdown();
    let output = backend.wait_with_output().unwrap();
    // Core re-logs backend output inside its own records; mimic that channel.
    eprintln!(
        "{{\"fake_host\":\"backend output\",\"text\":{}}}",
        json!(String::from_utf8_lossy(&output.stderr))
    );
    i32::from(!output.status.success())
}

// ---------------------------------------------------------------------- the test driver

struct Run {
    code: Option<i32>,
    stdout: Vec<u8>,
    stderr: String,
    elapsed: Duration,
    recorded: String,
    tmp: tempfile::TempDir,
}

impl Run {
    fn recorded(&self, key: &str) -> Option<&str> {
        self.recorded
            .lines()
            .find_map(|l| l.strip_prefix(key)?.strip_prefix('='))
    }
    fn pid(&self, key: &str) -> u32 {
        self.recorded(key)
            .unwrap_or_else(|| panic!("{key} not recorded"))
            .parse()
            .unwrap()
    }
    fn records(&self) -> Vec<Value> {
        records(&self.stderr)
    }
    /// Nothing the session created survives it: no process, no session directory.
    fn assert_clean(&self) {
        for key in ["host_pid", "backend_pid"] {
            if self.recorded(key).is_some() && !wait_gone(self.pid(key), Duration::from_secs(5)) {
                kill_pid(self.pid(key)); // do not leave it behind for the rest of the run
                panic!("{key} still running after the CLI exited");
            }
        }
        let left: Vec<_> = entries_of(self.tmp.path())
            .into_iter()
            .filter(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("nativehtmlkit-cli-")
            })
            .collect();
        assert!(left.is_empty(), "session directory left behind: {left:?}");
    }
    fn assert_failed(&self, code: &str) {
        assert_eq!(self.code, Some(1), "stderr: {}", self.stderr);
        assert!(self.stdout.is_empty(), "errors must leave stdout empty");
        assert!(
            self.stderr
                .contains(&format!("nativehtmlkit: error[{code}]: ")),
            "stderr: {}",
            self.stderr
        );
    }
}

struct Invocation<'a> {
    scenario: &'a str,
    args: Vec<&'a str>,
    stdin: &'a [u8],
    env: Vec<(&'a str, &'a str)>,
    env_remove: Vec<&'a str>,
}

fn invoke(
    scenario: &'static str,
    args: &[&'static str],
    stdin: &'static [u8],
) -> Invocation<'static> {
    Invocation {
        scenario,
        args: args.to_vec(),
        stdin,
        env: Vec::new(),
        env_remove: Vec::new(),
    }
}

impl Invocation<'_> {
    fn command(&self, tmp: &Path) -> Command {
        let mut command = Command::new(CLI);
        command
            .arg("--host")
            .arg(std::env::current_exe().unwrap())
            .args(&self.args)
            .env(SCENARIO, self.scenario)
            .env(RECORD, tmp.join("fake-host.record"))
            // The session directory is created under the temp dir; give each test its own.
            .env("TMPDIR", tmp)
            .env("TMP", tmp)
            .env("TEMP", tmp)
            .env("NATIVEHTMLKIT_WATCHDOG_GRACE_MS", "300")
            .env_remove("NATIVEHTMLKIT_DIAGNOSTICS")
            .env_remove("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID")
            .env_remove("NATIVEHTMLKIT_HOST_BINARY")
            .stdin(Stdio::piped())
            // Files, not pipes: a host that wrongly outlives the CLI inherits its stderr
            // and would otherwise keep the test waiting for end-of-file instead of failing.
            .stdout(std::fs::File::create(tmp.join("cli-stdout.bin")).unwrap())
            .stderr(std::fs::File::create(tmp.join("cli-stderr.txt")).unwrap());
        for key in &self.env_remove {
            command.env_remove(key);
        }
        for (key, value) in &self.env {
            command.env(key, value);
        }
        command
    }
    fn run(&self) -> Run {
        let tmp = tempfile::tempdir().unwrap();
        let started = Instant::now();
        let mut child = self.command(tmp.path()).spawn().unwrap();
        feed(&mut child, self.stdin);
        collect(child, tmp, started)
    }
}

/// Write the pipeline input and close stdin. A CLI that rejects its arguments exits without
/// reading stdin, so a broken pipe here is expected and not an error of the test.
fn feed(child: &mut std::process::Child, input: &[u8]) {
    let mut stdin = child.stdin.take().unwrap();
    match stdin.write_all(input) {
        Err(error) if error.kind() != std::io::ErrorKind::BrokenPipe => {
            panic!("write stdin: {error}")
        }
        _ => {}
    }
}

/// Wait for the CLI itself (not for whatever it may have left behind) and gather results.
fn collect(mut child: std::process::Child, tmp: tempfile::TempDir, started: Instant) -> Run {
    watchdog(child.id(), Duration::from_secs(60));
    let status = child.wait().unwrap();
    let read = |name: &str| std::fs::read(tmp.path().join(name)).unwrap_or_default();
    Run {
        code: status.code(),
        stdout: read("cli-stdout.bin"),
        stderr: String::from_utf8_lossy(&read("cli-stderr.txt")).into_owned(),
        elapsed: started.elapsed(),
        recorded: String::from_utf8_lossy(&read("fake-host.record")).into_owned(),
        tmp,
    }
}

const ABC: &[u8] = b"alpha\nbeta\ngamma\n";
/// Tight bounds so fault cases finish quickly: rpc 0.4 s, probe every 0.15 s, start 1 s.
const FAST: [&str; 6] = [
    "--rpc-timeout",
    "0.4",
    "--liveness-interval",
    "0.15",
    "--startup-timeout",
    "1",
];

fn fast(rest: &[&'static str]) -> Vec<&'static str> {
    FAST.iter().copied().chain(rest.iter().copied()).collect()
}

fn select_writes_exactly_the_chosen_rows() {
    let run = invoke("select:2,0", &["select", "--multi"], ABC).run();
    assert_eq!(run.code, Some(0), "stderr: {}", run.stderr);
    assert_eq!(run.stdout, b"alpha\ngamma\n", "document order, exact bytes");
    // Default diagnostics: a successful run adds nothing of its own to stderr.
    assert!(run.records().is_empty(), "stderr: {}", run.stderr);
    assert!(
        run.stderr.contains("\"fake_host\":\"started\""),
        "host stderr is passed through"
    );
    assert_eq!(run.recorded("startup_timeout_ms"), Some("15000"));
    run.assert_clean();
}

fn json_selection_preserves_records() {
    let input = br#"[{"z":1,"a":12345678901234567890123},{"z":2.50,"a":null}]"#;
    let run = invoke("select:1", &["select", "--input-format", "json"], input).run();
    assert_eq!(run.code, Some(0), "stderr: {}", run.stderr);
    assert_eq!(run.stdout, b"[{\"z\":2.50,\"a\":null}]\n");
}

fn cancel_and_window_close_exit_2_with_empty_stdout() {
    for scenario in ["cancel", "close"] {
        let run = invoke(scenario, &["select"], ABC).run();
        assert_eq!(run.code, Some(2), "{scenario}: {}", run.stderr);
        assert!(run.stdout.is_empty());
        assert!(
            !run.stderr.contains("error["),
            "cancel is not an error: {}",
            run.stderr
        );
        run.assert_clean();
    }
}

/// A Submit that collides with the window being closed is a Cancel (exit 2), never an error.
fn submit_colliding_with_window_close_is_cancel() {
    let run = invoke("submit_collides_with_close", &["select"], ABC).run();
    assert_eq!(run.code, Some(2), "{}", run.stderr);
    assert!(run.stdout.is_empty());
    assert!(!run.stderr.contains("error["), "{}", run.stderr);
    run.assert_clean();
}

fn view_exits_0_with_empty_stdout() {
    for scenario in ["done", "close"] {
        let run = invoke(scenario, &["view"], ABC).run();
        assert_eq!(
            (run.code, run.stdout.len()),
            (Some(0), 0),
            "{scenario}: {}",
            run.stderr
        );
        run.assert_clean();
    }
}

fn empty_selection_needs_allow_empty() {
    let run = invoke(
        "select:",
        &["select", "--allow-empty", "--output-format", "json"],
        ABC,
    )
    .run();
    assert_eq!(run.code, Some(0), "stderr: {}", run.stderr);
    assert_eq!(run.stdout, b"[]\n");
}

fn input_and_usage_errors_exit_1_before_any_host_starts() {
    for (args, stdin, code) in [
        (
            vec!["select", "--input-format", "json"],
            &b"[1,"[..],
            Some("input.invalid"),
        ),
        (
            vec!["select", "--input-format", "csv"],
            b"a,b\n1,2,3\n",
            Some("input.invalid"),
        ),
        (vec!["select"], b"", Some("input.invalid")),
        (vec!["select"], b"\xff\xfe\n", Some("input.invalid")),
        (vec!["select", "--title", ""], ABC, Some("usage.invalid")),
        (
            vec!["select", "--css", "/nonexistent/x.css"],
            ABC,
            Some("input.invalid"),
        ),
        (vec!["select", "--bogus"], ABC, None),
        (vec!["select", "--rpc-timeout", "0"], ABC, None),
        (vec!["select", "--timeout", "soon"], ABC, None),
        (vec!["select", "--diagnostics", "loud"], ABC, None),
    ] {
        let mut invocation = invoke("select:0", &[], stdin);
        invocation.args = args.clone();
        let run = invocation.run();
        assert_eq!(run.code, Some(1), "{args:?}: {}", run.stderr);
        assert!(run.stdout.is_empty(), "{args:?}");
        if let Some(code) = code {
            assert!(
                run.stderr
                    .contains(&format!("nativehtmlkit: error[{code}]: ")),
                "{args:?}: {}",
                run.stderr
            );
            assert!(
                run.records().is_empty(),
                "user mistakes are not diagnostic records by default"
            );
        }
        assert!(
            run.recorded("host_pid").is_none(),
            "{args:?}: host must not start"
        );
    }
}

fn help_and_version_succeed_on_stdout() {
    for (args, needle) in [
        (
            vec!["--version"],
            concat!("nativehtmlkit ", env!("CARGO_PKG_VERSION")),
        ),
        (vec!["--help"], "--rpc-timeout"),
        (vec!["select", "--help"], "--timeout"),
    ] {
        let output = Command::new(CLI).args(&args).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(
            String::from_utf8_lossy(&output.stdout).contains(needle),
            "{args:?}"
        );
        assert!(output.stderr.is_empty());
    }
}

fn missing_host_is_classified() {
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("no-such-host");
    let mut child = Command::new(CLI)
        .args(["--host", missing.to_str().unwrap(), "select"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    feed(&mut child, ABC);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[host.not_found]"));
}

fn a_slow_user_with_a_healthy_host_still_gets_the_result() {
    let run = invoke("idle_then_select:1", &fast(&["select"]), ABC).run();
    assert_eq!(run.code, Some(0), "stderr: {}", run.stderr);
    assert_eq!(run.stdout, b"beta\n");
    assert!(
        run.pid("probes") >= 4,
        "probes: {:?}",
        run.recorded("probes")
    );
    assert!(
        run.elapsed >= Duration::from_millis(1500),
        "waited through several deadlines"
    );
    assert_eq!(run.recorded("startup_timeout_ms"), Some("1000"));
    run.assert_clean();
}

fn hung_host_is_detected_reported_and_killed() {
    let run = invoke("hang_when_idle", &fast(&["select"]), ABC).run();
    run.assert_failed("host.unresponsive");
    assert!(
        run.elapsed < Duration::from_secs(8),
        "not bounded: {:?}",
        run.elapsed
    );
    let records = run.records();
    let failed = events(&records, "session.failed");
    assert_eq!(failed.len(), 1, "stderr: {}", run.stderr);
    assert_eq!(failed[0]["error_code"], "host.unresponsive");
    assert_eq!(failed[0]["role"], "launcher");
    assert_eq!(failed[0]["context"]["operation"], "host.diagnostics");
    // The backend's own records are relayed even at the default level for failures.
    assert_eq!(events(&records, "backend.failed")[0]["role"], "backend");
    assert_eq!(events(&records, "host.watchdog").len(), 1);
    run.assert_clean();
}

fn hung_request_is_detected_before_the_window_is_ready() {
    let run = invoke("hang_at_load", &fast(&["select"]), ABC).run();
    run.assert_failed("rpc.timeout");
    assert!(
        run.stderr.contains("operation document.load"),
        "{}",
        run.stderr
    );
    assert!(run.elapsed < Duration::from_secs(8), "{:?}", run.elapsed);
    run.assert_clean();
}

fn host_that_never_starts_the_backend_is_bounded() {
    let run = invoke("never_start", &fast(&["select"]), ABC).run();
    run.assert_failed("host.startup_timeout");
    // startup 1 s + watchdog grace 0.3 s
    assert!(
        run.elapsed >= Duration::from_millis(1300) && run.elapsed < Duration::from_secs(8),
        "{:?}",
        run.elapsed
    );
    run.assert_clean();
}

fn host_crash_mid_request_is_an_error_not_a_cancel() {
    let run = invoke("die_mid_request", &fast(&["select"]), ABC).run();
    run.assert_failed("transport.disconnected");
    assert!(run.elapsed < Duration::from_secs(8), "{:?}", run.elapsed);
    run.assert_clean();
}

/// The backend is done and the result is committed, but the host never exits. Bounded even
/// with liveness probing disabled, and fail-closed: no result is written.
fn host_that_never_exits_after_the_session_is_bounded() {
    let run = invoke(
        "hang_after_shutdown",
        &["--liveness-interval", "0", "select"],
        ABC,
    )
    .run();
    run.assert_failed("host.shutdown_timeout");
    // host shutdown allowance 5 s + watchdog grace 0.3 s
    assert!(
        run.elapsed >= Duration::from_millis(5300) && run.elapsed < Duration::from_secs(15),
        "{:?}",
        run.elapsed
    );
    run.assert_clean();
}

fn form_fragment_without_the_form_is_refused_before_a_window_opens() {
    let tmp = tempfile::tempdir().unwrap();
    for (name, html, ok) in [
        ("missing.html", "<p>no form here</p>", false),
        (
            "other.html",
            "<form id=\"other\"><input name=a></form>",
            false,
        ),
        (
            "double.html",
            "<form id = \"nhk-form\"><input name=a></form>",
            true,
        ),
        ("single.html", "<form class=x id='nhk-form'></form>", true),
    ] {
        let path = tmp.path().join(name);
        std::fs::write(&path, html).unwrap();
        let path: &'static str = Box::leak(path.to_str().unwrap().to_owned().into_boxed_str());
        let run = invoke("cancel", &["form", "--html", path], b"").run();
        if ok {
            assert_eq!(run.code, Some(2), "{name}: {}", run.stderr);
        } else {
            run.assert_failed("input.invalid");
            assert!(run.stderr.contains("nhk-form"), "{}", run.stderr);
            assert!(
                run.recorded("host_pid").is_none(),
                "{name}: host must not start"
            );
        }
    }
}

/// FR-R-09: seven consecutive requests that each take 87 % of the per-request deadline
/// break no deadline, but keep the backend busy for 18 s without an idle moment to probe
/// in. The launcher's watchdog (limit here: 1 + 3 x 3 + 0.5 s) must not mistake that for a
/// dead backend and discard the user's selection: every answer counts as progress.
fn slow_but_answering_host_is_not_killed() {
    let mut invocation = invoke(
        "slow_host:2600",
        &[
            "--rpc-timeout",
            "3",
            "--liveness-interval",
            "1",
            "select",
            "--multi",
        ],
        ABC,
    );
    invocation.env = vec![("NATIVEHTMLKIT_WATCHDOG_GRACE_MS", "500")];
    let run = invocation.run();
    assert_eq!(run.code, Some(0), "stderr: {}", run.stderr);
    assert_eq!(run.stdout, b"beta\n");
    assert!(run.elapsed >= Duration::from_secs(18), "{:?}", run.elapsed);
    run.assert_clean();
}

/// FR-R-02 / FR-R-03: input inside the row/column/byte limits that the host would still
/// refuse (document node limit, 1 MiB page) is refused by the launcher with an actionable
/// `input.invalid`, before any host process or window exists.
fn documents_the_host_would_refuse_are_refused_before_it_starts() {
    let wide = |rows: usize, cols: usize| -> &'static [u8] {
        let records: Vec<Value> = (0..rows)
            .map(|i| {
                Value::Object(
                    (0..cols)
                        .map(|j| (format!("c{j}"), json!(format!("v{i}_{j}"))))
                        .collect(),
                )
            })
            .collect();
        Box::leak(serde_json::to_vec(&records).unwrap().into_boxed_slice())
    };
    // 1871 rows x 16 columns: 65,567 nodes by the documented formula, 31 over the limit.
    let run = invoke(
        "select:0",
        &["select", "--input-format", "json"],
        wide(1871, 16),
    )
    .run();
    run.assert_failed("input.invalid");
    assert!(
        run.stderr.contains("1871 rows x 16 columns") && run.stderr.contains("65536"),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr.contains("at most 1870 rows"),
        "the message must say what would fit: {}",
        run.stderr
    );
    assert!(run.recorded("host_pid").is_none(), "host must not start");
    // One row fewer is accepted and reaches the host.
    let run = invoke(
        "select:0",
        &[
            "select",
            "--input-format",
            "json",
            "--output-format",
            "lines",
        ],
        wide(1870, 16),
    )
    .run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    assert!(run.recorded("host_pid").is_some());
    // 2000 lines of 600 bytes: 1.2 MB of page for a 1 MiB limit, inside the 8 MiB input limit.
    let long: &'static [u8] = Box::leak(
        format!("{}\n", "x".repeat(600))
            .repeat(2000)
            .into_bytes()
            .into_boxed_slice(),
    );
    for mode in ["select", "view"] {
        let run = invoke("select:0", &[mode], long).run();
        run.assert_failed("input.invalid");
        assert!(run.stderr.contains("1 MiB"), "{}", run.stderr);
        assert!(
            run.recorded("host_pid").is_none(),
            "{mode}: host must not start"
        );
    }
}

fn host_exiting_unsuccessfully_is_an_error() {
    let run = invoke("exit_7", &["select"], ABC).run();
    run.assert_failed("host.failed");
    run.assert_clean();
}

/// Linux topology: the process the CLI started is only a supervisor; the host that hung
/// is another process, found through the pid it reported over the protocol.
fn supervised_hung_host_is_killed_by_pid() {
    let run = invoke("supervised_hang", &fast(&["select"]), ABC).run();
    run.assert_failed("host.unresponsive");
    let pids: Vec<u32> = run
        .recorded
        .lines()
        .filter_map(|l| l.strip_prefix("host_pid="))
        .map(|p| p.parse().unwrap())
        .collect();
    assert_eq!(pids.len(), 2, "supervisor and supervised host");
    for pid in pids {
        assert!(
            wait_gone(pid, Duration::from_secs(5)),
            "host process {pid} survived"
        );
    }
    assert_eq!(
        events(&run.records(), "host.killed").len(),
        1,
        "{}",
        run.stderr
    );
    run.assert_clean();
}

fn explicit_timeout_exits_124_with_empty_stdout() {
    let run = invoke(
        "wait_for_deadline",
        &fast(&["--timeout", "0.6", "select"]),
        ABC,
    )
    .run();
    assert_eq!(run.code, Some(124), "stderr: {}", run.stderr);
    assert!(run.stdout.is_empty());
    assert!(run.stderr.contains("--timeout deadline"), "{}", run.stderr);
    assert!(
        !run.stderr.contains("error["),
        "a deadline is not a host failure: {}",
        run.stderr
    );
    assert!(run.elapsed >= Duration::from_millis(600) && run.elapsed < Duration::from_secs(8));
    run.assert_clean();
}

fn diagnostics_flag_reaches_host_backend_and_stderr() {
    let run = invoke("select:1", &["--diagnostics", "trace", "select"], ABC).run();
    assert_eq!(
        (run.code, run.stdout.as_slice()),
        (Some(0), &b"beta\n"[..]),
        "{}",
        run.stderr
    );
    assert_eq!(run.recorded("NATIVEHTMLKIT_DIAGNOSTICS"), Some("trace"));
    let session = run
        .recorded("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID")
        .unwrap()
        .to_owned();
    assert!(session.starts_with("nhk-"), "generated id: {session}");
    let records = run.records();
    assert!(
        records.iter().all(|r| r["session_id"] == session.as_str()),
        "one id across processes"
    );
    let roles: std::collections::BTreeSet<&str> = records
        .iter()
        .map(|r| r["role"].as_str().unwrap())
        .collect();
    assert_eq!(
        roles.into_iter().collect::<Vec<_>>(),
        ["backend", "launcher"]
    );
    let pids: std::collections::BTreeSet<u64> =
        records.iter().map(|r| r["pid"].as_u64().unwrap()).collect();
    assert_eq!(
        pids.len(),
        2,
        "launcher and backend are different processes"
    );
    assert_eq!(
        events(&records, "backend.started")[0]["context"]["session_id_inherited_through_host"],
        true
    );
    let started = events(&records, "session.started")[0];
    assert_eq!(
        started["context"],
        json!({"mode":"select","rows":3,"columns":1})
    );
    let completed = events(&records, "session.completed")[0];
    assert_eq!(completed["context"]["outcome"], "submitted");
    assert!(completed["duration_ms"].is_u64());
    assert!(events(&records, "rpc.completed")
        .iter()
        .any(|r| r["operation"] == "document.load" && r["request_id"] == "nhk-4"));
    assert!(!events(&records, "rpc.started").is_empty());
}

/// Regression test for interleaved stderr lines: the host logs continuously on the stream
/// it shares with the launcher while the launcher relays a trace-level session. Every line
/// that reaches stderr must be one whole JSON object from one writer.
fn stderr_lines_stay_whole_next_to_a_chatty_host() {
    let mut invocation = invoke(
        "idle_then_select:1",
        &[
            "--diagnostics",
            "trace",
            "--rpc-timeout",
            "2",
            "--liveness-interval",
            "0.02",
            "select",
        ],
        ABC,
    );
    invocation.env = vec![("NHK_FAKE_CHATTY", "1")];
    let run = invocation.run();
    assert_eq!((run.code, run.stdout.as_slice()), (Some(0), &b"beta\n"[..]));
    let (mut ours, mut hosts) = (0, 0);
    for line in run.stderr.lines().filter(|l| !l.is_empty()) {
        let value: Value = serde_json::from_str(line).unwrap_or_else(|error| {
            panic!("a stderr line is not one whole record ({error}): {line}")
        });
        if value.get("schema_version").is_some() {
            ours += 1;
        } else {
            assert!(value.get("fake_host").is_some(), "{line}");
            hosts += 1;
        }
    }
    assert!(
        ours > 100 && hosts > 1000,
        "not enough concurrent traffic: {ours} CLI records, {hosts} host lines"
    );
}

fn inherited_diagnostics_environment_is_preserved() {
    let mut invocation = invoke("select:0", &["select"], ABC);
    invocation.env = vec![
        ("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID", "ci-run.42:job_7"),
        ("NATIVEHTMLKIT_DIAGNOSTICS", "debug"),
    ];
    let run = invocation.run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    assert_eq!(
        run.recorded("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID"),
        Some("ci-run.42:job_7")
    );
    assert_eq!(
        run.recorded("NATIVEHTMLKIT_DIAGNOSTICS"),
        Some("debug"),
        "inherited level left untouched"
    );
    let records = run.records();
    assert!(!records.is_empty() && records.iter().all(|r| r["session_id"] == "ci-run.42:job_7"));
    assert!(
        events(&records, "rpc.started").is_empty(),
        "debug is not trace"
    );
    assert_eq!(events(&records, "rpc.completed").len(), 7);
    // The flag wins over the environment.
    let mut invocation = invoke("select:0", &["--diagnostics", "off", "select"], ABC);
    invocation.env = vec![("NATIVEHTMLKIT_DIAGNOSTICS", "trace")];
    let run = invocation.run();
    assert_eq!(run.recorded("NATIVEHTMLKIT_DIAGNOSTICS"), Some("off"));
    assert!(run.records().is_empty());
}

fn malformed_inherited_session_id_is_replaced_and_disclosed() {
    let mut invocation = invoke("select:0", &["select"], ABC);
    invocation.env = vec![("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID", "bad id \"x\"")];
    let run = invocation.run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    let used = run.recorded("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID").unwrap();
    assert!(used.starts_with("nhk-"), "{used}");
    assert_eq!(events(&run.records(), "session_id.replaced").len(), 1);
}

/// Sentinel test: user data in every input position, the launch token on the wire, full
/// trace diagnostics. Only stdout may carry the data.
fn trace_output_never_contains_user_data_or_the_token() {
    let stdin: &'static [u8] = Box::leak(
        format!("first {SENTINEL}\nsecond {SENTINEL}\n")
            .into_bytes()
            .into_boxed_slice(),
    );
    let title: &'static str = Box::leak(format!("title {SENTINEL}").into_boxed_str());
    let run = invoke(
        "select:1",
        &["--diagnostics", "trace", "select", "--title", title],
        stdin,
    )
    .run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    assert_eq!(run.stdout, format!("second {SENTINEL}\n").as_bytes());
    assert_private(&run.stderr, "launcher stderr (select)");
    assert!(
        events(&run.records(), "rpc.completed").len() >= 7,
        "trace really was on"
    );

    // Form values, with the failure path as well (hung host after the form is shown).
    let tmp = tempfile::tempdir().unwrap();
    let form = tmp.path().join("form.html");
    std::fs::write(
        &form,
        format!("<form id='nhk-form'><input name='pw' value='{SENTINEL}'></form>"),
    )
    .unwrap();
    let form: &'static str = Box::leak(form.to_str().unwrap().to_owned().into_boxed_str());
    let run = invoke(
        "form",
        &["--diagnostics", "trace", "form", "--html", form],
        b"",
    )
    .run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    assert_eq!(
        run.stdout,
        format!(
            "{{\"entries\":[{{\"kind\":\"text\",\"name\":\"pw\",\"value\":\"{SENTINEL}\"}}]}}\n"
        )
        .as_bytes()
    );
    assert_private(&run.stderr, "launcher stderr (form)");
    let run = invoke(
        "hang_when_idle",
        &fast(&["--diagnostics", "trace", "form", "--html", form]),
        b"",
    )
    .run();
    run.assert_failed("host.unresponsive");
    assert_private(&run.stderr, "launcher stderr (form, hung host)");
}

fn stdout_write_failure_is_an_error() {
    let invocation = invoke("select:0", &["select"], ABC);
    let tmp = tempfile::tempdir().unwrap();
    let mut command = invocation.command(tmp.path());
    command.stdout(
        std::fs::OpenOptions::new()
            .write(true)
            .open("/dev/full")
            .unwrap(),
    );
    let mut child = command.spawn().unwrap();
    feed(&mut child, ABC);
    let run = collect(child, tmp, Instant::now());
    run.assert_failed("output.failed");
    run.assert_clean();
}

fn endless_asset_file_is_refused_without_reading_it_all() {
    let run = invoke("select:0", &["select", "--css", "/dev/zero"], ABC).run();
    run.assert_failed("input.invalid");
    assert!(run.stderr.contains("256 KiB"), "{}", run.stderr);
    assert!(run.elapsed < Duration::from_secs(5));
}

fn doctor_reports_the_host_and_is_bounded() {
    let run = invoke("select:0", &["doctor"], b"").run();
    assert_eq!(run.code, Some(0), "{}", run.stderr);
    let stdout = String::from_utf8_lossy(&run.stdout);
    assert!(
        stdout.contains(concat!("NativeHTMLKit CLI ", env!("CARGO_PKG_VERSION")))
            && stdout.contains("nativehtmlkit-host 0.0.0-fake"),
        "{stdout}"
    );
    let run = invoke("version_hang", &["doctor"], b"").run();
    run.assert_failed("host.failed");
    assert!(
        run.elapsed >= Duration::from_secs(10) && run.elapsed < Duration::from_secs(20),
        "{:?}",
        run.elapsed
    );
}

/// SIGINT / SIGTERM / SIGHUP to the CLI: exit 130 / 143 / 129, nothing on stdout, host and backend gone and the
/// session directory removed.
fn termination_signals_clean_up() {
    for (signal, exit) in [("-INT", 130), ("-TERM", 143), ("-HUP", 129)] {
        let invocation = invoke(
            "hang_when_idle",
            &["--liveness-interval", "0", "select"],
            ABC,
        );
        let tmp = tempfile::tempdir().unwrap();
        let mut child = invocation.command(tmp.path()).spawn().unwrap();
        feed(&mut child, ABC);
        let record = tmp.path().join("fake-host.record");
        let ready = Instant::now();
        while !std::fs::read_to_string(&record)
            .unwrap_or_default()
            .contains("html_bytes=")
        {
            assert!(
                ready.elapsed() < Duration::from_secs(20),
                "session never became ready"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        Command::new("kill")
            .args([signal, &child.id().to_string()])
            .status()
            .unwrap();
        let signalled = Instant::now();
        let run = collect(child, tmp, ready);
        assert_eq!(run.code, Some(exit), "{signal}: {}", run.stderr);
        if signal != "-INT" {
            // FR-R-08: only Ctrl+C reaches the host by itself; TERM and HUP stop it at once.
            assert!(
                signalled.elapsed() < Duration::from_millis(2500),
                "{signal} took {:?}",
                signalled.elapsed()
            );
        }
        assert!(run.stdout.is_empty());
        run.assert_clean();
    }
}

/// SIGKILL of the CLI cannot be handled; the host must still not outlive it.
fn killed_launcher_takes_the_host_down() {
    let invocation = invoke(
        "hang_when_idle",
        &["--liveness-interval", "0", "select"],
        ABC,
    );
    let tmp = tempfile::tempdir().unwrap();
    let mut child = invocation.command(tmp.path()).spawn().unwrap();
    feed(&mut child, ABC);
    let record = tmp.path().join("fake-host.record");
    let ready = Instant::now();
    while !std::fs::read_to_string(&record)
        .unwrap_or_default()
        .contains("html_bytes=")
    {
        assert!(ready.elapsed() < Duration::from_secs(20));
        std::thread::sleep(Duration::from_millis(20));
    }
    child.kill().unwrap();
    child.wait().unwrap();
    let recorded = std::fs::read_to_string(&record).unwrap();
    let host: u32 = recorded
        .lines()
        .find_map(|l| l.strip_prefix("host_pid="))
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        wait_gone(host, Duration::from_secs(5)),
        "host outlived a killed launcher"
    );
}

fn concurrent_sessions_do_not_mix_results() {
    std::thread::scope(|scope| {
        let a =
            scope.spawn(|| invoke("idle_then_select:0", &fast(&["select"]), b"one\ntwo\n").run());
        let b = scope.spawn(|| invoke("select:1", &["select"], b"x-ray\nyankee\n").run());
        let (a, b) = (a.join().unwrap(), b.join().unwrap());
        assert_eq!(
            (a.code, a.stdout.as_slice()),
            (Some(0), &b"one\n"[..]),
            "{}",
            a.stderr
        );
        assert_eq!(
            (b.code, b.stdout.as_slice()),
            (Some(0), &b"yankee\n"[..]),
            "{}",
            b.stderr
        );
    });
}

/// Where a test can run. Tests that do not apply are reported as ignored, never as ok.
const ANY: bool = true;
const UNIX: bool = cfg!(unix); // needs /dev/full, /dev/zero or POSIX signals
const LINUX: bool = cfg!(target_os = "linux"); // needs PR_SET_PDEATHSIG / procfs

fn run_tests(args: &[String]) {
    let tests: &[(&str, bool, fn())] = &[
        (
            "select_writes_exactly_the_chosen_rows",
            ANY,
            select_writes_exactly_the_chosen_rows,
        ),
        (
            "json_selection_preserves_records",
            ANY,
            json_selection_preserves_records,
        ),
        (
            "cancel_and_window_close_exit_2_with_empty_stdout",
            ANY,
            cancel_and_window_close_exit_2_with_empty_stdout,
        ),
        (
            "view_exits_0_with_empty_stdout",
            ANY,
            view_exits_0_with_empty_stdout,
        ),
        (
            "empty_selection_needs_allow_empty",
            ANY,
            empty_selection_needs_allow_empty,
        ),
        (
            "input_and_usage_errors_exit_1_before_any_host_starts",
            ANY,
            input_and_usage_errors_exit_1_before_any_host_starts,
        ),
        (
            "help_and_version_succeed_on_stdout",
            ANY,
            help_and_version_succeed_on_stdout,
        ),
        (
            "missing_host_is_classified",
            ANY,
            missing_host_is_classified,
        ),
        (
            "a_slow_user_with_a_healthy_host_still_gets_the_result",
            ANY,
            a_slow_user_with_a_healthy_host_still_gets_the_result,
        ),
        (
            "hung_host_is_detected_reported_and_killed",
            ANY,
            hung_host_is_detected_reported_and_killed,
        ),
        (
            "hung_request_is_detected_before_the_window_is_ready",
            ANY,
            hung_request_is_detected_before_the_window_is_ready,
        ),
        (
            "host_that_never_starts_the_backend_is_bounded",
            ANY,
            host_that_never_starts_the_backend_is_bounded,
        ),
        (
            "host_crash_mid_request_is_an_error_not_a_cancel",
            ANY,
            host_crash_mid_request_is_an_error_not_a_cancel,
        ),
        (
            "host_that_never_exits_after_the_session_is_bounded",
            ANY,
            host_that_never_exits_after_the_session_is_bounded,
        ),
        (
            "form_fragment_without_the_form_is_refused_before_a_window_opens",
            ANY,
            form_fragment_without_the_form_is_refused_before_a_window_opens,
        ),
        (
            "slow_but_answering_host_is_not_killed",
            ANY,
            slow_but_answering_host_is_not_killed,
        ),
        (
            "documents_the_host_would_refuse_are_refused_before_it_starts",
            ANY,
            documents_the_host_would_refuse_are_refused_before_it_starts,
        ),
        (
            "submit_colliding_with_window_close_is_cancel",
            ANY,
            submit_colliding_with_window_close_is_cancel,
        ),
        (
            "stderr_lines_stay_whole_next_to_a_chatty_host",
            ANY,
            stderr_lines_stay_whole_next_to_a_chatty_host,
        ),
        (
            "host_exiting_unsuccessfully_is_an_error",
            ANY,
            host_exiting_unsuccessfully_is_an_error,
        ),
        (
            "supervised_hung_host_is_killed_by_pid",
            LINUX,
            supervised_hung_host_is_killed_by_pid,
        ),
        (
            "explicit_timeout_exits_124_with_empty_stdout",
            ANY,
            explicit_timeout_exits_124_with_empty_stdout,
        ),
        (
            "diagnostics_flag_reaches_host_backend_and_stderr",
            ANY,
            diagnostics_flag_reaches_host_backend_and_stderr,
        ),
        (
            "inherited_diagnostics_environment_is_preserved",
            ANY,
            inherited_diagnostics_environment_is_preserved,
        ),
        (
            "malformed_inherited_session_id_is_replaced_and_disclosed",
            ANY,
            malformed_inherited_session_id_is_replaced_and_disclosed,
        ),
        (
            "trace_output_never_contains_user_data_or_the_token",
            ANY,
            trace_output_never_contains_user_data_or_the_token,
        ),
        (
            "stdout_write_failure_is_an_error",
            UNIX,
            stdout_write_failure_is_an_error,
        ),
        (
            "endless_asset_file_is_refused_without_reading_it_all",
            UNIX,
            endless_asset_file_is_refused_without_reading_it_all,
        ),
        (
            "doctor_reports_the_host_and_is_bounded",
            ANY,
            doctor_reports_the_host_and_is_bounded,
        ),
        (
            "termination_signals_clean_up",
            UNIX,
            termination_signals_clean_up,
        ),
        (
            "killed_launcher_takes_the_host_down",
            LINUX,
            killed_launcher_takes_the_host_down,
        ),
        (
            "concurrent_sessions_do_not_mix_results",
            ANY,
            concurrent_sessions_do_not_mix_results,
        ),
    ];
    let filters: Vec<&String> = args.iter().filter(|a| !a.starts_with('-')).collect();
    let selected: Vec<_> = tests
        .iter()
        .filter(|(name, _, _)| {
            filters.is_empty() || filters.iter().any(|f| name.contains(f.as_str()))
        })
        .collect();
    println!("\nrunning {} tests", selected.len());
    // Every test owns its temp dir and endpoint, so they run concurrently.
    let results: Vec<(&str, Option<bool>)> = std::thread::scope(|scope| {
        let handles: Vec<_> = selected
            .iter()
            .map(|(name, applies, test)| {
                (
                    *name,
                    applies.then(|| scope.spawn(move || std::panic::catch_unwind(test).is_ok())),
                )
            })
            .collect();
        handles
            .into_iter()
            .map(|(name, handle)| (name, handle.map(|h| h.join().unwrap_or(false))))
            .collect()
    });
    let (mut passed, mut failed, mut ignored) = (0, 0, 0);
    for (name, outcome) in &results {
        let text = match outcome {
            Some(true) => {
                passed += 1;
                "ok"
            }
            Some(false) => {
                failed += 1;
                "FAILED"
            }
            None => {
                ignored += 1;
                "ignored (not applicable on this platform)"
            }
        };
        println!("test {name} ... {text}");
    }
    println!(
        "\ntest result: {}. {passed} passed; {failed} failed; {ignored} ignored; 0 measured; {} filtered out\n",
        if failed == 0 { "ok" } else { "FAILED" },
        tests.len() - selected.len()
    );
    std::process::exit(i32::from(failed != 0));
}
