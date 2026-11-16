//! A scripted stand-in for the Core host, speaking the v1 wire framing on the platform's
//! real transport (Unix stream socket / Windows named pipe). Shared by the backend fault
//! suite and the launcher end-to-end suite. Not a GUI: native behaviour is qualified by
//! `tests/gui/`.
#![allow(dead_code)]
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

pub const TOKEN: &str = "5e57a1c0ffee5e57a1c0ffee5e57a1c0ffee5e57a1c0ffee5e57a1c0ffee0123";
/// Planted in user-controlled places; must never reach stderr or diagnostics.
pub const SENTINEL: &str = "S3NTINEL-do-not-log-7f3a";
pub const MAX_FRAME: usize = 2_097_152;

pub struct Listener {
    pub endpoint: String,
    #[cfg(unix)]
    inner: std::os::unix::net::UnixListener,
    #[cfg(windows)]
    inner: std::fs::File,
}

pub struct Conn {
    #[cfg(unix)]
    inner: std::os::unix::net::UnixStream,
    #[cfg(windows)]
    inner: std::fs::File,
}

#[cfg(unix)]
impl Listener {
    pub fn bind(dir: &Path) -> Self {
        let path = dir.join("host.sock");
        Self {
            endpoint: path.to_string_lossy().into_owned(),
            inner: std::os::unix::net::UnixListener::bind(&path).unwrap(),
        }
    }
    pub fn accept(self) -> Conn {
        let (inner, _) = self.inner.accept().unwrap();
        // A scripted read that never completes is a test failure, not a hang.
        inner
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        Conn { inner }
    }
}

#[cfg(windows)]
impl Listener {
    pub fn bind(dir: &Path) -> Self {
        use std::os::windows::io::FromRawHandle;
        use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
        use windows_sys::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
        use windows_sys::Win32::System::Pipes::{CreateNamedPipeW, PIPE_TYPE_BYTE, PIPE_WAIT};
        let unique = dir.file_name().unwrap().to_string_lossy().into_owned();
        let endpoint = format!(r"\\.\pipe\nhk-fake-host-{}-{unique}", std::process::id());
        let wide: Vec<u16> = endpoint.encode_utf16().chain(Some(0)).collect();
        // SAFETY: valid NUL-terminated name; default security; the handle is owned below.
        let handle = unsafe {
            CreateNamedPipeW(
                wide.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_BYTE | PIPE_WAIT,
                1,
                1 << 20,
                1 << 20,
                0,
                std::ptr::null(),
            )
        };
        assert_ne!(handle, INVALID_HANDLE_VALUE, "CreateNamedPipeW failed");
        Self {
            endpoint,
            // SAFETY: freshly created, exclusively owned pipe handle.
            inner: unsafe { std::fs::File::from_raw_handle(handle as _) },
        }
    }
    pub fn accept(self) -> Conn {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::System::Pipes::ConnectNamedPipe;
        // Fails with ERROR_PIPE_CONNECTED when the client is already there: both are fine.
        // SAFETY: valid pipe handle, synchronous connect.
        unsafe { ConnectNamedPipe(self.inner.as_raw_handle() as _, std::ptr::null_mut()) };
        Conn { inner: self.inner }
    }
}

impl Conn {
    /// Next frame from the client; `None` once the client has closed the connection.
    pub fn frame(&mut self) -> Option<Value> {
        let mut header = [0_u8; 4];
        self.inner.read_exact(&mut header).ok()?;
        let size = u32::from_be_bytes(header) as usize;
        assert!(size > 0 && size <= MAX_FRAME, "client frame length {size}");
        let mut body = vec![0; size];
        self.inner.read_exact(&mut body).ok()?;
        Some(serde_json::from_slice(&body).expect("client sent invalid JSON"))
    }
    pub fn expect(&mut self, method: &str) -> Value {
        let frame = self
            .frame()
            .unwrap_or_else(|| panic!("client closed before {method}"));
        assert_eq!(frame["method"], method, "unexpected request {frame}");
        assert_eq!(frame["jsonrpc"], "2.0");
        assert!(frame["id"].is_string(), "requests need string ids");
        frame
    }
    pub fn raw(&mut self, bytes: &[u8]) {
        // The client may already have failed and closed; that is what some tests provoke.
        let _ = self
            .inner
            .write_all(bytes)
            .and_then(|()| self.inner.flush());
    }
    pub fn send(&mut self, message: Value) {
        let body = serde_json::to_vec(&message).unwrap();
        let mut frame = (body.len() as u32).to_be_bytes().to_vec();
        frame.extend(body);
        self.raw(&frame);
    }
    pub fn answer(&mut self, request: &Value, result: Value) {
        self.send(json!({"jsonrpc":"2.0","id":request["id"],"result":result}));
    }
    pub fn notify(&mut self, method: &str, params: Value) {
        self.send(json!({"jsonrpc":"2.0","method":method,"params":params}));
    }
    pub fn click(&mut self, element: &str) {
        self.notify(
            "document.event",
            json!({"window_id":"w1","document_id":"d1","event":{"type":"click","element":element,"path":[element]}}),
        );
    }
    pub fn shutdown(&mut self) {
        self.notify("app.shutdown", json!({"deadline_ms":5000}));
    }

    /// hello → diagnostics → window.create → document.load → app.ready, answered like Core.
    /// Returns the HTML the client loaded.
    pub fn startup(&mut self) -> String {
        self.startup_until("app.ready").unwrap()
    }

    /// Answer the startup sequence but stop (without answering) at `stop_at`.
    pub fn startup_until(&mut self, stop_at: &str) -> Option<String> {
        let mut html = None;
        for method in [
            "host.hello",
            "host.diagnostics",
            "window.create",
            "document.load",
            "app.ready",
        ] {
            let request = self.expect(method);
            if method == stop_at && method != "app.ready" {
                return None;
            }
            let result = match method {
                "host.hello" => {
                    assert_eq!(request["params"]["token"], TOKEN);
                    assert_eq!(request["params"]["protocol_version"], 1);
                    json!({"protocol_version":1,"host_version":"0.0.0-fake","app_id":"org.nativehtmlkit.Test","capabilities":{}})
                }
                "host.diagnostics" => json!({"phase":"initializing","pid":std::process::id()}),
                "window.create" => json!({"window_id":"w1"}),
                "document.load" => {
                    assert_eq!(request["params"]["window_id"], "w1");
                    html = Some(request["params"]["html"].as_str().unwrap().to_owned());
                    json!({"document_id":"d1","loaded":true})
                }
                _ => json!({"ready":true}),
            };
            self.answer(&request, result);
        }
        html
    }

    /// Serve requests until `until` arrives (returned unanswered). Liveness probes are
    /// answered and counted; any other method is a test failure.
    pub fn serve_until(&mut self, until: &str, probes: &mut u32) -> Value {
        loop {
            let request = self
                .frame()
                .unwrap_or_else(|| panic!("client closed before {until}"));
            if request["method"] == until {
                return request;
            }
            assert_eq!(
                request["method"], "host.diagnostics",
                "unexpected {request}"
            );
            *probes += 1;
            self.answer(&request, json!({"phase":"ready","dropped_notifications":0}));
        }
    }

    /// Answer liveness probes for `duration`, like a healthy host with an idle user.
    pub fn idle(&mut self, duration: Duration) -> u32 {
        let mut probes = 0;
        let until = Instant::now() + duration;
        self.set_read_timeout(Some(Duration::from_millis(20)));
        while Instant::now() < until {
            if let Some(request) = self.poll_frame() {
                assert_eq!(
                    request["method"], "host.diagnostics",
                    "unexpected {request}"
                );
                probes += 1;
                self.answer(&request, json!({"phase":"ready","dropped_notifications":0}));
            }
        }
        self.set_read_timeout(Some(Duration::from_secs(20)));
        probes
    }

    #[cfg(unix)]
    fn set_read_timeout(&mut self, timeout: Option<Duration>) {
        self.inner.set_read_timeout(timeout).unwrap();
    }
    #[cfg(unix)]
    fn poll_frame(&mut self) -> Option<Value> {
        let mut first = [0_u8; 1];
        match self.inner.read(&mut first) {
            Ok(1) => {}
            _ => return None,
        }
        self.inner
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut rest = [0_u8; 3];
        self.inner.read_exact(&mut rest).unwrap();
        let size = u32::from_be_bytes([first[0], rest[0], rest[1], rest[2]]) as usize;
        let mut body = vec![0; size];
        self.inner.read_exact(&mut body).unwrap();
        self.inner
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        Some(serde_json::from_slice(&body).unwrap())
    }

    #[cfg(windows)]
    fn set_read_timeout(&mut self, _timeout: Option<Duration>) {}
    #[cfg(windows)]
    fn poll_frame(&mut self) -> Option<Value> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::System::Pipes::PeekNamedPipe;
        let mut available = 0_u32;
        // SAFETY: valid pipe handle; only the byte count is requested.
        let ok = unsafe {
            PeekNamedPipe(
                self.inner.as_raw_handle() as _,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 || available < 4 {
            std::thread::sleep(Duration::from_millis(10));
            return None;
        }
        self.frame()
    }
}

/// A `session.json` like the launcher writes, with tight test bounds.
pub fn session(mode: &str, rows: &[&str], runtime: Value) -> Value {
    let rows: Vec<Value> = rows
        .iter()
        .map(|r| json!({"cells":[r],"value":r}))
        .collect();
    let mut base = json!({"rpc_timeout_ms":400,"liveness_interval_ms":150,"deadline_ms":null,
        "diagnostics":"trace","session_id":"test-session.1"});
    for (key, value) in runtime.as_object().cloned().unwrap_or_default() {
        base[key] = value;
    }
    json!({"schema":1,"mode":mode,"title":"Test","multi":true,"allow_empty":false,"css":null,
        "html": if mode == "form" { json!("<form id='nhk-form'><input name='secret'></form>") } else { Value::Null },
        "data":{"format":"lines","columns":["Value"],"rows":rows},"runtime":base})
}

pub struct Backend {
    pub child: Child,
    pub dir: tempfile::TempDir,
    pub conn: Conn,
    started: Instant,
}

/// Start `nativehtmlkit __backend` against a fresh fake-host endpoint.
pub fn backend(cli: &str, session: &Value) -> Backend {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("session.json"),
        serde_json::to_vec(session).unwrap(),
    )
    .unwrap();
    let listener = Listener::bind(dir.path());
    let child = Command::new(cli)
        .arg("__backend")
        .arg(dir.path())
        .env("UI4ME_ENDPOINT", &listener.endpoint)
        .env("UI4ME_TOKEN", TOKEN)
        .env("UI4ME_APP_ID", "org.nativehtmlkit.Test")
        .env("UI4ME_PROTOCOL_VERSION", "1")
        .env("NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID", "test-session.1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    watchdog(child.id(), Duration::from_secs(40));
    let conn = listener.accept();
    Backend {
        child,
        dir,
        conn,
        started: Instant::now(),
    }
}

pub struct Finished {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
    pub elapsed: Duration,
    pub dir: tempfile::TempDir,
}

impl Backend {
    /// Wait for the backend to exit and collect everything it produced.
    pub fn finish(self) -> Finished {
        let Backend {
            child,
            dir,
            conn,
            started,
        } = self;
        let output = child.wait_with_output().unwrap();
        drop(conn);
        Finished {
            status: output.status,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            elapsed: started.elapsed(),
            dir,
        }
    }
}

impl Finished {
    pub fn file(&self, name: &str) -> Option<String> {
        std::fs::read_to_string(self.dir.path().join(name)).ok()
    }
    pub fn json(&self, name: &str) -> Value {
        serde_json::from_str(&self.file(name).unwrap_or_else(|| panic!("{name} missing"))).unwrap()
    }
    pub fn records(&self) -> Vec<Value> {
        records(&self.file("diag.ndjson").unwrap_or_default())
    }
    /// Asserts the classified failure contract: exit 1, no stdout, `error.json` and the
    /// stderr line agree on the code. Returns the failure for further checks.
    pub fn failed_with(&self, code: &str) -> Value {
        assert_eq!(self.status.code(), Some(1), "stderr: {}", self.stderr);
        assert_eq!(self.stdout, "");
        let failure = self.json("error.json");
        assert_eq!(failure["code"], code, "stderr: {}", self.stderr);
        assert!(
            self.stderr
                .contains(&format!("nativehtmlkit: error[{code}]: ")),
            "stderr: {}",
            self.stderr
        );
        assert!(
            self.file("result.json").is_none(),
            "a failed session must not commit a result"
        );
        failure
    }
    /// Everything the backend emitted outside the result channel.
    pub fn side_channels(&self) -> String {
        format!(
            "{}\n{}\n{}",
            self.stderr,
            self.file("diag.ndjson").unwrap_or_default(),
            self.file("error.json").unwrap_or_default()
        )
    }
}

/// Parse NDJSON diagnostic records, failing on any line that is not a schema-1 record.
pub fn records(text: &str) -> Vec<Value> {
    text.lines()
        .filter(|line| line.starts_with("{\"schema_version\""))
        .map(|line| {
            let record: Value = serde_json::from_str(line).expect("record is not JSON");
            for key in [
                "timestamp",
                "session_id",
                "component",
                "role",
                "level",
                "event",
            ] {
                assert!(record[key].is_string(), "record lacks {key}: {line}");
            }
            assert_eq!(record["schema_version"], 1);
            assert!(record["pid"].is_u64());
            record
        })
        .collect()
}

pub fn events<'a>(records: &'a [Value], event: &str) -> Vec<&'a Value> {
    records.iter().filter(|r| r["event"] == event).collect()
}

pub fn assert_private(text: &str, what: &str) {
    for secret in [SENTINEL, TOKEN] {
        assert!(!text.contains(secret), "{what} leaked {secret}:\n{text}");
    }
}

pub fn kill_pid(pid: u32) {
    #[cfg(unix)]
    let _ = Command::new("kill")
        .args(["-KILL", &pid.to_string()])
        .status();
    #[cfg(windows)]
    let _ = Command::new("taskkill")
        .args(["/F", "/PID", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

pub fn alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // A zombie still has a /proc entry; only a running process counts.
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .map(|stat| {
                !stat
                    .rsplit(')')
                    .next()
                    .unwrap_or("")
                    .trim_start()
                    .starts_with('Z')
            })
            .unwrap_or(false)
    }
    #[cfg(windows)]
    {
        let out = Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).contains(&pid.to_string())
    }
}

/// Last resort so a defect cannot hang the whole test run: kill `pid` after `limit`.
pub fn watchdog(pid: u32, limit: Duration) {
    std::thread::spawn(move || {
        std::thread::sleep(limit);
        if alive(pid) {
            eprintln!("test watchdog: killing pid {pid} after {limit:?}");
            kill_pid(pid);
        }
    });
}

pub fn wait_gone(pid: u32, limit: Duration) -> bool {
    let started = Instant::now();
    while alive(pid) {
        if started.elapsed() > limit {
            return false;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    true
}

pub fn entries_of(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect()
}
