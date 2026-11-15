use crate::model::{Mode, Outcome, OutputFormat, Session};
use crate::{output, session};
use anyhow::{anyhow, bail, Context, Result};
use std::env;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

pub fn host_binary(explicit: Option<&Path>) -> Result<PathBuf> {
    let name = if cfg!(windows) {
        "nativehtmlkit-host.exe"
    } else {
        "nativehtmlkit-host"
    };
    if let Some(p) = explicit {
        return verify_executable(p.to_path_buf());
    }
    if let Ok(value) = env::var("NATIVEHTMLKIT_HOST_BINARY") {
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
    bail!("NativeHTMLKit Core host not found. Install a qualified release beside the CLI or set NATIVEHTMLKIT_HOST_BINARY.")
}

fn verify_executable(binary: PathBuf) -> Result<PathBuf> {
    if !binary.is_file() {
        bail!("Core host binary does not exist: {}", binary.display());
    }
    Ok(binary)
}

pub fn doctor(binary: Option<&Path>) -> Result<()> {
    let host = host_binary(binary)?;
    let result = Command::new(&host)
        .arg("--version")
        .output()
        .context("invoke Core host")?;
    if !result.status.success() {
        bail!(
            "Core host version check failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    println!("NativeHTMLKit CLI {}", env!("CARGO_PKG_VERSION"));
    println!("Core host: {}", host.display());
    print!("{}", String::from_utf8_lossy(&result.stdout));
    Ok(())
}

pub fn run(host: Option<&Path>, session: Session, output_format: OutputFormat) -> Result<i32> {
    let binary = host_binary(host)?;
    let current = env::current_exe().context("locate CLI process for internal backend")?;
    let tmp = session::SessionDir::create(&session, &current)?;
    let interrupted = Arc::new(AtomicBool::new(false));
    let interrupted_signal = interrupted.clone();
    ctrlc::set_handler(move || {
        interrupted_signal.store(true, Ordering::SeqCst);
    })
    .context("install CLI interruption handler")?;
    let mut command = Command::new(binary);
    command
        .arg("run")
        .arg("--app")
        .arg(tmp.manifest())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    bind_lifetime_before_spawn(&mut command);
    let mut child = command.spawn().context("start native host")?;
    // Keep the binding alive until the host has been reaped.
    let _lifetime = bind_lifetime_after_spawn(&child)?;
    let status = loop {
        if interrupted.load(Ordering::SeqCst) {
            // A terminal Ctrl+C is delivered to the whole foreground process group, so the
            // host launcher normally exits by itself; Core's launcher watch then stops the
            // supervised host and its backend. Allow a short grace period, then force it.
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline {
                if child.try_wait().ok().flatten().is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
            return Ok(130); // Interrupted: no result is ever written to stdout.
        }
        if let Some(status) = child.try_wait().context("wait for Core host")? {
            break status;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    if !status.success() {
        return Err(anyhow!("native host failed with status {status}"));
    }
    let outcome = match session::read_outcome(tmp.path())? {
        Some(outcome) => outcome,
        None => return Ok(if session.mode == Mode::View { 0 } else { 2 }),
    };
    if matches!(
        (&session.mode, &outcome),
        (Mode::Select, Outcome::Selected { .. })
            | (Mode::Form, Outcome::Form { .. })
            | (Mode::View, Outcome::Viewed)
    ) {
        let encoded = output::encode(&session.data, &outcome, output_format)?;
        io::stdout()
            .lock()
            .write_all(&encoded)
            .context("write pipeline output")?;
        Ok(0)
    } else {
        bail!("session mode/result mismatch (possibly corrupted completion file)")
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
