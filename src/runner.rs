//! The launcher side: starts the Core host for one session, waits for it, and makes sure
//! neither a hung host nor a hung backend can keep the pipeline waiting forever.
use crate::diag::{self, Level};
use crate::error::{code, Failure};
use crate::model::{Mode, Outcome, OutputFormat, Session};
use crate::{output, session};
use anyhow::{Context, Result};
use std::env;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

pub const EXIT_CANCELLED: i32 = 2;
pub const EXIT_DEADLINE: i32 = 124;
/// 128 + signal number, as a shell reports a process ended by that signal.
pub const EXIT_INTERRUPTED: i32 = 130;
pub const EXIT_TERMINATED: i32 = 143;
pub const EXIT_HANGUP: i32 = 129;

/// Which interruption arrived, recorded by the signal handler (0: none).
static INTERRUPT: AtomicI32 = AtomicI32::new(0);
const SIGNAL_INT: i32 = 2;
const SIGNAL_HUP: i32 = 1;
const SIGNAL_TERM: i32 = 15;

#[cfg(unix)]
fn install_interrupt_handler() -> Result<()> {
    extern "C" fn record(signal: libc::c_int) {
        // Only an atomic store: async-signal-safe.
        INTERRUPT.store(signal, Ordering::SeqCst);
    }
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: installs a handler that only stores to an atomic.
        let previous = unsafe {
            libc::signal(
                signal,
                record as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )
        };
        if previous == libc::SIG_ERR {
            return Err(io::Error::last_os_error()).context("install CLI interruption handler");
        }
    }
    Ok(())
}

#[cfg(windows)]
fn install_interrupt_handler() -> Result<()> {
    ctrlc::set_handler(|| INTERRUPT.store(SIGNAL_INT, Ordering::SeqCst))
        .context("install CLI interruption handler")
}

/// Run the fallible step that binds the host's lifetime to this process. If it fails the
/// host must not be left running on its own: it is killed and reaped before the error is
/// returned.
fn bind_or_kill<G>(child: &mut Child, bind: impl FnOnce(&Child) -> Result<G>) -> Result<G> {
    match bind(child) {
        Ok(guard) => Ok(guard),
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(error)
        }
    }
}

const POLL: Duration = Duration::from_millis(50);
const HOUSEKEEPING: Duration = Duration::from_millis(200);
const DOCTOR_TIMEOUT: Duration = Duration::from_secs(10);
/// Test-only override (milliseconds) for the watchdog margins below.
const GRACE_ENV: &str = "NATIVEHTMLKIT_WATCHDOG_GRACE_MS";
const DEFAULT_GRACE: Duration = Duration::from_secs(5);

pub fn host_binary(explicit: Option<&Path>) -> Result<PathBuf> {
    let name = if cfg!(windows) {
        "nativehtmlkit-host.exe"
    } else {
        "nativehtmlkit-host"
    };
    if let Some(p) = explicit {
        return verify_executable(p.to_path_buf());
    }
    if let Some(value) = env::var_os("NATIVEHTMLKIT_HOST_BINARY").filter(|v| !v.is_empty()) {
        return verify_executable(PathBuf::from(value));
    }
    let current = env::current_exe().context("locate CLI binary")?;
    if let Some(parent) = current.parent() {
        let candidate = parent.join(name);
        if candidate.is_file() {
            return verify_executable(candidate);
        }
    }
    if let Some(paths) = env::var_os("PATH") {
        for base in env::split_paths(&paths) {
            let candidate = base.join(name);
            if candidate.is_file() {
                return verify_executable(candidate);
            }
        }
    }
    Err(Failure::new(code::HOST_MISSING, "NativeHTMLKit Core host not found. Install a qualified release beside the CLI or set NATIVEHTMLKIT_HOST_BINARY.").into())
}

fn verify_executable(binary: PathBuf) -> Result<PathBuf> {
    if !binary.is_file() {
        return Err(Failure::new(
            code::HOST_MISSING,
            format!("Core host binary does not exist: {}", binary.display()),
        )
        .into());
    }
    Ok(binary)
}

/// Wait for a child for at most `limit`; kill it and return `None` when it does not exit.
fn wait_bounded(child: &mut Child, limit: Duration) -> io::Result<Option<ExitStatus>> {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(status));
        }
        if started.elapsed() >= limit {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub fn doctor(binary: Option<&Path>) -> Result<()> {
    let host = host_binary(binary)?;
    // `--version` prints one short line, far below a pipe buffer, so the pipes can be
    // read after the bounded wait without a reader thread.
    let mut child = Command::new(&host)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            Failure::new(
                code::HOST_MISSING,
                format!("cannot start the Core host ({})", error.kind()),
            )
        })?;
    let Some(status) = wait_bounded(&mut child, DOCTOR_TIMEOUT).context("wait for Core host")?
    else {
        return Err(Failure::new(
            code::HOST_FAILED,
            "the Core host did not answer --version in time",
        )
        .after(DOCTOR_TIMEOUT)
        .into());
    };
    let mut version = String::new();
    if let Some(mut pipe) = child.stdout.take() {
        let _ = pipe.by_ref().take(4096).read_to_string(&mut version);
    }
    if !status.success() || version.trim().is_empty() {
        return Err(Failure::new(
            code::HOST_FAILED,
            format!("Core host version check failed with {status}"),
        )
        .into());
    }
    println!("NativeHTMLKit CLI {}", env!("CARGO_PKG_VERSION"));
    println!("Core host: {}", host.display());
    println!("{}", version.trim_end());
    Ok(())
}

pub struct Options {
    pub host: Option<PathBuf>,
    pub startup_timeout: Duration,
    /// Level given with `--diagnostics`; exported to the host. `None` leaves the host's
    /// environment (including an inherited `NATIVEHTMLKIT_DIAGNOSTICS`) untouched.
    pub diagnostics_flag: Option<Level>,
}

/// Copies the backend's diagnostic records (complete lines only) to stderr.
struct Relay {
    path: PathBuf,
    offset: u64,
    partial: Vec<u8>,
}

impl Relay {
    const MAX_LINE: usize = 16 * 1024;

    fn new(dir: &Path) -> Self {
        Self {
            path: dir.join(diag::BACKEND_FILE),
            offset: 0,
            partial: Vec::new(),
        }
    }

    fn pump(&mut self) {
        let Ok(mut file) = std::fs::File::open(&self.path) else {
            return;
        };
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return;
        }
        let mut fresh = Vec::new();
        if file.take(4 * 1024 * 1024).read_to_end(&mut fresh).is_err() {
            return;
        }
        self.offset += fresh.len() as u64;
        self.partial.extend_from_slice(&fresh);
        let Some(end) = self.partial.iter().rposition(|&b| b == b'\n') else {
            if self.partial.len() > Self::MAX_LINE {
                self.partial.clear();
            }
            return;
        };
        let complete: Vec<u8> = self.partial.drain(..=end).collect();
        let mut stderr = io::stderr().lock();
        for line in complete.split(|&b| b == b'\n') {
            // Only this CLI's own record shape is forwarded.
            if line.starts_with(b"{\"schema_version\":1,") && line.len() <= Self::MAX_LINE {
                let _ = stderr.write_all(line);
                let _ = stderr.write_all(b"\n");
            }
        }
    }
}

/// Decides when waiting on the host process is no longer justified. It never limits how
/// long the *user* may take: once the backend is ready, the only requirement is that the
/// backend keeps proving the host answers (see `backend::interact`).
struct Watchdog {
    dir: PathBuf,
    startup_limit: Duration,
    /// `None` when liveness probing is disabled: there is then no heartbeat to expect.
    stale_limit: Option<Duration>,
    failure_grace: Duration,
    /// Time observed by this process in small steps, so a suspended machine does not
    /// count as host silence.
    clock: Duration,
    last_tick: Instant,
    ready: Option<Option<u32>>,
    beat: Option<Vec<u8>>,
    beat_at: Duration,
    failure_at: Option<Duration>,
    done_at: Option<Duration>,
    exit_allowance: Duration,
}

impl Watchdog {
    fn new(dir: &Path, startup: Duration, runtime: &crate::model::Runtime) -> Self {
        let grace = env::var(GRACE_ENV)
            .ok()
            .and_then(|v| v.parse().ok())
            .map(Duration::from_millis)
            .unwrap_or(DEFAULT_GRACE);
        // The backend reports progress after every frame from the host. The longest
        // legitimate silence is an idle interval followed by a liveness probe that is
        // allowed twice the per-request deadline; one more deadline is kept as margin.
        let stale_limit = (runtime.liveness_interval_ms != 0).then(|| {
            Duration::from_millis(runtime.liveness_interval_ms + 3 * runtime.rpc_timeout_ms) + grace
        });
        Self {
            dir: dir.to_path_buf(),
            startup_limit: startup + grace,
            stale_limit,
            failure_grace: grace.min(Duration::from_secs(2)),
            clock: Duration::ZERO,
            last_tick: Instant::now(),
            ready: None,
            beat: None,
            beat_at: Duration::ZERO,
            failure_at: None,
            done_at: None,
            // What the host itself allows for shutting a session down, plus the margin.
            exit_allowance: Duration::from_millis(session::HOST_SHUTDOWN_TIMEOUT_MS) + grace,
        }
    }

    fn host_pid(&self) -> Option<u32> {
        self.ready.flatten()
    }

    /// Returns the failure to report when the host must be stopped now.
    fn tick(&mut self) -> Option<Failure> {
        self.clock += self.last_tick.elapsed().min(Duration::from_secs(1));
        self.last_tick = Instant::now();
        if self.ready.is_none() {
            self.ready = session::read_ready(&self.dir);
            if self.ready.is_some() {
                self.beat_at = self.clock;
            }
        }
        // The backend already knows what went wrong. A healthy host ends the session by
        // itself; a hung one, or one showing its failure page, is stopped after a grace.
        if let Some(failure) = session::read_failure(&self.dir) {
            let since = *self.failure_at.get_or_insert(self.clock);
            return (self.clock - since >= self.failure_grace).then_some(failure);
        }
        if self.ready.is_none() {
            return (self.clock >= self.startup_limit).then(|| {
                Failure::new(
                    code::HOST_STARTUP,
                    "the Core host did not open the window in time",
                )
                .after(self.clock)
            });
        }
        // The backend is finished, so no more heartbeats will come; the host only has to
        // exit. This holds whether or not liveness probing is enabled.
        if self.done_at.is_some() || session::is_done(&self.dir) {
            let since = *self.done_at.get_or_insert(self.clock);
            return (self.clock - since >= self.exit_allowance).then(|| {
                Failure::new(
                    code::HOST_SHUTDOWN,
                    "the session ended but the Core host process did not exit",
                )
                .after(self.clock - since)
            });
        }
        let limit = self.stale_limit?;
        let beat = session::read_beat(&self.dir);
        if beat.is_some() && beat != self.beat {
            self.beat = beat;
            self.beat_at = self.clock;
        }
        (self.clock - self.beat_at >= limit).then(|| {
            Failure::new(
                code::BACKEND_UNRESPONSIVE,
                "the CLI backend stopped reporting host liveness",
            )
            .after(self.clock - self.beat_at)
        })
    }
}

/// Stop the host for certain. `child` is the process this launcher started; on Linux that
/// is Core's supervising launcher and the real host runs in a systemd user unit whose
/// event loop may be the very thing that hung, so it is killed by process id as well.
fn stop_host(child: &mut Child, host_pid: Option<u32>, binary: &Path, patience: Duration) {
    let _ = child.kill();
    let _ = wait_bounded(child, Duration::from_secs(2));
    #[cfg(target_os = "linux")]
    if let Some(pid) = host_pid.filter(|&pid| pid != child.id() && pid > 1) {
        // Only ever signal a process that is still this session's host binary.
        let is_host = || {
            std::fs::read_link(format!("/proc/{pid}/exe"))
                .ok()
                .zip(binary.canonicalize().ok())
                .is_some_and(|(exe, host)| exe == host)
        };
        // A responsive host notices that its launcher is gone and shuts down by itself.
        let waited = Instant::now();
        while is_host() && waited.elapsed() < patience {
            std::thread::sleep(Duration::from_millis(50));
        }
        if is_host() {
            // SAFETY: plain syscall on a pid; no memory is involved.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            diag::record(Level::Normal, "host.killed")
                .tag("target", "supervised_host")
                .emit();
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = (host_pid, binary, patience);
}

pub fn run(options: &Options, session: Session, output_format: OutputFormat) -> Result<i32> {
    let binary = host_binary(options.host.as_deref())?;
    let current = env::current_exe().context("locate CLI process for internal backend")?;
    let startup_ms = options.startup_timeout.as_millis() as u64;
    let tmp = session::SessionDir::create(&session, &current, startup_ms)
        .map_err(|error| crate::error::tag(error, code::SESSION))?;
    install_interrupt_handler()?;
    let mut command = Command::new(&binary);
    command
        .arg("run")
        .arg("--app")
        .arg(tmp.manifest())
        .env(diag::SESSION_ENV, &session.runtime.session_id)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    if let Some(level) = options.diagnostics_flag {
        command.env(diag::LEVEL_ENV, level.as_str());
    }
    if env::var_os("NATIVEHTMLKIT_CLI_TEST_HEADLESS").is_some() {
        // Protocol tests against a real host without opening a window (tests/README.md).
        command.arg("--headless");
    }
    bind_lifetime_before_spawn(&mut command);
    let started = Instant::now();
    diag::record(Level::Debug, "session.started")
        .tag(
            "mode",
            match session.mode {
                Mode::Select => "select",
                Mode::View => "view",
                Mode::Form => "form",
            },
        )
        .num("rows", session.data.rows.len() as u64)
        .num("columns", session.data.columns.len() as u64)
        .emit();
    let mut child = command.spawn().map_err(|error| {
        Failure::new(
            code::HOST_MISSING,
            format!("cannot start the Core host ({})", error.kind()),
        )
    })?;
    // Keep the binding alive until the host has been reaped.
    let _lifetime = bind_or_kill(&mut child, bind_lifetime_after_spawn)?;
    diag::record(Level::Debug, "host.spawned")
        .num("host_launcher_pid", u64::from(child.id()))
        .emit();
    let mut relay = Relay::new(tmp.path());
    let mut watchdog = Watchdog::new(tmp.path(), options.startup_timeout, &session.runtime);
    let mut housekeeping = Instant::now();
    let status = loop {
        let signal = INTERRUPT.load(Ordering::SeqCst);
        if signal != 0 {
            let (outcome, exit) = match signal {
                SIGNAL_TERM => ("terminated", EXIT_TERMINATED),
                SIGNAL_HUP => ("hangup", EXIT_HANGUP),
                _ => ("interrupted", EXIT_INTERRUPTED),
            };
            if signal == SIGNAL_INT {
                // A terminal Ctrl+C is delivered to the whole foreground process group, so
                // the host launcher normally exits by itself; give it a moment to do so.
                let _ = wait_bounded(&mut child, Duration::from_secs(3));
            }
            // SIGTERM and SIGHUP reach only this process: the host is stopped at once. A
            // responsive supervised host then shuts down by itself within the patience.
            watchdog.tick();
            stop_host(
                &mut child,
                watchdog.host_pid(),
                &binary,
                Duration::from_secs(3),
            );
            relay.pump();
            diag::record(Level::Debug, "session.completed")
                .tag("outcome", outcome)
                .num("exit_code", exit as u64)
                .duration(started.elapsed())
                .emit();
            return Ok(exit); // No result is ever written to stdout after an interruption.
        }
        if let Some(status) = child.try_wait().context("wait for Core host")? {
            break status;
        }
        if housekeeping.elapsed() >= HOUSEKEEPING {
            housekeeping = Instant::now();
            relay.pump();
            if let Some(failure) = watchdog.tick() {
                diag::record(Level::Normal, "host.watchdog")
                    .failure(&failure)
                    .emit();
                stop_host(&mut child, watchdog.host_pid(), &binary, Duration::ZERO);
                relay.pump();
                return Err(failure.into());
            }
        }
        std::thread::sleep(POLL);
    };
    relay.pump();
    diag::record(Level::Debug, "host.exited")
        .num(
            "status",
            u64::from(status.code().unwrap_or(-1).unsigned_abs()),
        )
        .flag("success", status.success())
        .duration(started.elapsed())
        .emit();
    // Fail closed: a recorded backend failure or an unsuccessful host never yields a result,
    // even if one had been committed before the failure.
    let mut failure = session::read_failure(tmp.path());
    if failure.is_none() && !status.success() {
        // A host that crashed takes the connection with it; give the backend a moment to
        // record what it saw, which is more specific than the bare exit status.
        let waited = Instant::now();
        while failure.is_none() && waited.elapsed() < Duration::from_millis(500) {
            std::thread::sleep(POLL);
            failure = session::read_failure(tmp.path());
        }
        relay.pump();
    }
    if let Some(failure) = failure {
        return Err(failure.into());
    }
    if !status.success() {
        return Err(Failure::new(
            code::HOST_FAILED,
            format!("the Core host ended with {status}"),
        )
        .after(started.elapsed())
        .into());
    }
    let completed = |outcome: &'static str, exit: i32| {
        diag::record(Level::Debug, "session.completed")
            .tag("outcome", outcome)
            .num("exit_code", exit as u64)
            .duration(started.elapsed())
            .emit();
        Ok(exit)
    };
    let outcome = match session::read_outcome(tmp.path())
        .map_err(|error| crate::error::tag(error, code::SESSION))?
    {
        Some(outcome) => outcome,
        // Window closed without a decision: a viewer was simply read, anything else
        // counts as Cancel.
        None if session.mode == Mode::View => return completed("viewed", 0),
        None => return completed("cancelled", EXIT_CANCELLED),
    };
    match (&session.mode, &outcome) {
        (_, Outcome::TimedOut) => {
            eprintln!(
                "nativehtmlkit: no decision before the --timeout deadline; the window was closed"
            );
            completed("deadline", EXIT_DEADLINE)
        }
        (Mode::Select, Outcome::Selected { .. })
        | (Mode::Form, Outcome::Form { .. })
        | (Mode::View, Outcome::Viewed) => {
            let encoded = output::encode(&session.data, &outcome, output_format)
                .map_err(|error| crate::error::tag(error, code::OUTPUT))?;
            let mut stdout = io::stdout().lock();
            // Flush explicitly: a failed flush at process exit would be silent and the
            // pipeline would see success with missing output.
            stdout
                .write_all(&encoded)
                .and_then(|()| stdout.flush())
                .map_err(|error| {
                    Failure::new(
                        code::OUTPUT,
                        format!("cannot write the result to stdout ({})", error.kind()),
                    )
                })?;
            completed("submitted", 0)
        }
        _ => Err(Failure::new(
            code::SESSION,
            "session mode/result mismatch (possibly corrupted completion file)",
        )
        .into()),
    }
}

/// The host (and through Core's own supervision, its window and backend) must not outlive
/// this launcher, even if the launcher is SIGKILLed or its console is closed. Otherwise an
/// orphaned window would keep the user's piped data alive with no consumer for the result.
#[cfg(target_os = "linux")]
fn bind_lifetime_before_spawn(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    // SAFETY: getpid/prctl/getppid are async-signal-safe and allocate nothing.
    let parent = unsafe { libc::getpid() };
    unsafe {
        command.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == -1 {
                return Err(io::Error::last_os_error());
            }
            // The launcher may have died between fork and prctl.
            if libc::getppid() != parent {
                return Err(io::Error::from_raw_os_error(libc::ESRCH));
            }
            Ok(())
        });
    }
}

#[cfg(target_os = "linux")]
fn bind_lifetime_after_spawn(_child: &std::process::Child) -> Result<NoGuard> {
    Ok(NoGuard)
}

#[cfg(windows)]
fn bind_lifetime_before_spawn(_command: &mut Command) {}

#[cfg(windows)]
fn bind_lifetime_after_spawn(child: &std::process::Child) -> Result<job::KillOnClose> {
    job::KillOnClose::assign(child)
}

#[cfg(windows)]
mod job {
    use anyhow::{bail, Result};
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    /// A job whose only handle is owned by this process: when the CLI exits for any reason
    /// the kernel closes the handle and terminates the host. Core's host places its backend
    /// in its own kill-on-close job, so the whole tree is released (nested jobs, Windows 8+).
    pub struct KillOnClose(HANDLE);

    impl KillOnClose {
        pub fn assign(child: &std::process::Child) -> Result<Self> {
            // SAFETY: plain Win32 calls with owned handles and a zeroed POD struct.
            unsafe {
                let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if job.is_null() {
                    bail!(
                        "create host job object: {}",
                        std::io::Error::last_os_error()
                    );
                }
                let guard = Self(job);
                let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    (&raw const limits).cast(),
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) == 0
                {
                    bail!(
                        "configure host job object: {}",
                        std::io::Error::last_os_error()
                    );
                }
                if AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE) == 0 {
                    bail!(
                        "assign host to job object: {}",
                        std::io::Error::last_os_error()
                    );
                }
                Ok(guard)
            }
        }
    }

    impl Drop for KillOnClose {
        fn drop(&mut self) {
            // SAFETY: the handle was created by CreateJobObjectW and is closed exactly once.
            unsafe { CloseHandle(self.0) };
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
fn bind_lifetime_before_spawn(_command: &mut Command) {}

#[cfg(not(any(target_os = "linux", windows)))]
fn bind_lifetime_after_spawn(_child: &std::process::Child) -> Result<NoGuard> {
    Ok(NoGuard)
}

/// Placeholder guard where the host lifetime is bound at spawn time (Linux PDEATHSIG).
#[cfg(not(windows))]
struct NoGuard;

#[cfg(test)]
mod tests {
    use super::*;

    fn sleeper() -> Child {
        let mut command = if cfg!(windows) {
            let mut c = Command::new("ping");
            c.args(["-n", "60", "127.0.0.1"]);
            c
        } else {
            let mut c = Command::new("sleep");
            c.arg("60");
            c
        };
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap()
    }

    /// FR-R-11: when binding the host to the launcher's lifetime fails, the host is not
    /// left running on its own.
    #[test]
    fn failed_lifetime_binding_kills_the_host() {
        let mut child = sleeper();
        let error = bind_or_kill(&mut child, |_| -> Result<()> {
            anyhow::bail!("assign host to job object: denied")
        })
        .unwrap_err();
        assert!(error.to_string().contains("job object"));
        // Already reaped by bind_or_kill: try_wait reports the exit without blocking.
        let status = child
            .try_wait()
            .unwrap()
            .expect("host must have been killed and reaped");
        assert!(!status.success());
    }

    #[test]
    fn successful_lifetime_binding_leaves_the_host_running() {
        let mut child = sleeper();
        assert_eq!(bind_or_kill(&mut child, |_| Ok(7)).unwrap(), 7);
        assert!(child.try_wait().unwrap().is_none());
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[test]
    fn exit_codes_follow_the_128_plus_signal_convention() {
        assert_eq!(EXIT_INTERRUPTED, 128 + SIGNAL_INT);
        assert_eq!(EXIT_TERMINATED, 128 + SIGNAL_TERM);
        assert_eq!(EXIT_HANGUP, 128 + SIGNAL_HUP);
    }
}
