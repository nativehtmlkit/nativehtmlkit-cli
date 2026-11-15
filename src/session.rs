use crate::error::Failure;
use crate::model::{Outcome, Session};
use anyhow::{anyhow, bail, Context, Result};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use tempfile::{Builder, TempDir};

pub struct SessionDir {
    dir: TempDir,
}
/// The backend can outlive the host by a moment (it notices the lost connection and
/// records why), so a file may appear while the directory is being deleted. Retry briefly
/// instead of leaving the directory behind.
impl Drop for SessionDir {
    fn drop(&mut self) {
        for _ in 0..20 {
            match fs::remove_dir_all(self.dir.path()) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    std::thread::sleep(std::time::Duration::from_millis(25));
                }
                _ => return,
            }
        }
    }
}

impl SessionDir {
    pub fn create(data: &Session, executable: &Path, startup_timeout_ms: u64) -> Result<Self> {
        let mut builder = Builder::new();
        builder.prefix("nativehtmlkit-cli-");
        // The session holds the user's piped data. tempfile follows the umask (often 0775),
        // so request owner-only access explicitly; the mode is applied at creation (no race).
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            builder.permissions(std::fs::Permissions::from_mode(0o700));
        }
        let dir = builder.tempdir().context("create private GUI session")?;
        let session = Self { dir };
        session.save(data, executable, startup_timeout_ms)?;
        Ok(session)
    }
    pub fn path(&self) -> &Path {
        self.dir.path()
    }
    pub fn manifest(&self) -> PathBuf {
        self.path().join("app.toml")
    }
    fn save(&self, session: &Session, exe: &Path, startup_timeout_ms: u64) -> Result<()> {
        if session.schema != 1 {
            bail!("unsupported session schema");
        }
        fs::write(
            self.path().join("session.json"),
            serde_json::to_vec(session)?,
        )?;
        let exe = exe.canonicalize().context("locate current CLI binary")?;
        let program = exe
            .to_str()
            .context("CLI executable path must be valid Unicode for the Core manifest")?;
        if program.contains("{app_dir}") {
            bail!("CLI executable path must not contain the Core manifest token {{app_dir}}");
        }
        let app_id = format!("org.nativehtmlkit.cli.i{}", std::process::id());
        // `{app_dir}` is Core's only manifest substitution and resolves to this private
        // session directory (the manifest's parent). Using it for both the backend argument
        // and its cwd avoids depending on the user's cwd (which may be deleted or non-Unicode).
        let txt = format!(
            "[app]\nid = {}\nname = {}\n\n[backend]\nprogram = {}\nargs = [\"__backend\", \"{{app_dir}}\"]\ncwd = \"{{app_dir}}\"\n\n[host]\ninstance = \"multiple\"\nmax_windows = 1\nstartup_timeout_ms = {}\nshutdown_timeout_ms = {}\n",
            toml::Value::String(app_id),
            toml::Value::String(session.title.clone()),
            toml::Value::String(program.to_owned()),
            startup_timeout_ms,
            HOST_SHUTDOWN_TIMEOUT_MS,
        );
        fs::write(self.manifest(), txt).context("write private host manifest")?;
        Ok(())
    }
}

/// How long the host waits for the backend to exit after `app.shutdown` (manifest value).
pub const HOST_SHUTDOWN_TIMEOUT_MS: u64 = 5000;

/// Read at most `limit` bytes; a larger file is an error, never a truncated success.
fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        bail!("private session file exceeds {limit} bytes");
    }
    Ok(bytes)
}

fn write_atomically(dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    let pending = dir.join(format!("{name}.{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&pending, dir.join(name))?;
    Ok(())
}

// Progress files written by the backend and watched by the launcher. They contain no user
// data: a process id, a counter and a payload-free failure classification.
const READY_FILE: &str = "ready";
const HEARTBEAT_FILE: &str = "heartbeat";
const DONE_FILE: &str = "done";
const FAILURE_FILE: &str = "error.json";

/// The backend authenticated, loaded the document and the host confirmed `app.ready`.
/// Records the host's process id when the host reported one.
pub fn mark_ready(dir: &Path, host_pid: Option<u32>) -> Result<()> {
    let text = host_pid.map(|pid| pid.to_string()).unwrap_or_default();
    write_atomically(dir, READY_FILE, text.as_bytes()).context("record backend readiness")
}

/// `None`: not ready yet. `Some(pid)`: ready, with the host pid if it was reported.
pub fn read_ready(dir: &Path) -> Option<Option<u32>> {
    let bytes = read_bounded(&dir.join(READY_FILE), 32).ok()?;
    Some(
        std::str::from_utf8(&bytes)
            .ok()
            .and_then(|t| t.trim().parse().ok()),
    )
}

/// The backend finished its conversation with the host without a failure. From here on
/// the only thing left is for the host process to exit.
pub fn mark_done(dir: &Path) {
    let _ = fs::write(dir.join(DONE_FILE), b"");
}

pub fn is_done(dir: &Path) -> bool {
    dir.join(DONE_FILE).is_file()
}

/// Best-effort progress marker: the launcher only checks that the content keeps changing.
pub fn beat(dir: &Path, counter: u64) {
    let _ = fs::write(dir.join(HEARTBEAT_FILE), counter.to_string());
}

pub fn read_beat(dir: &Path) -> Option<Vec<u8>> {
    read_bounded(&dir.join(HEARTBEAT_FILE), 32)
        .ok()
        .filter(|bytes| !bytes.is_empty())
}

pub fn save_failure(dir: &Path, failure: &Failure) -> Result<()> {
    write_atomically(dir, FAILURE_FILE, &serde_json::to_vec(failure)?)
        .context("record backend failure")
}

pub fn read_failure(dir: &Path) -> Option<Failure> {
    let bytes = read_bounded(&dir.join(FAILURE_FILE), 64 * 1024).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Read the private session and remove it at once: the piped data should not stay at
/// rest on disk for the lifetime of the window (the backend is its only reader).
pub fn take_session(dir: &Path) -> Result<Session> {
    let session = read_session(dir)?;
    fs::remove_file(dir.join("session.json")).context("remove private session file")?;
    Ok(session)
}

pub fn read_session(dir: &Path) -> Result<Session> {
    // 8 MiB of input can at most double as JSON string escapes plus the cell copies.
    let data = read_bounded(&dir.join("session.json"), 64 * 1024 * 1024)
        .context("read private session file")?;
    let session: Session = serde_json::from_slice(&data)?;
    if session.schema != 1 {
        bail!("unsupported session format");
    }
    Ok(session)
}

pub fn save_outcome(dir: &Path, result: &Outcome) -> Result<()> {
    let target = dir.join("result.json");
    if target.exists() {
        bail!("duplicate session completion");
    }
    write_atomically(dir, "result.json", &serde_json::to_vec(result)?)
        .context("atomically commit session result")
}

pub fn read_outcome(dir: &Path) -> Result<Option<Outcome>> {
    let path = dir.join("result.json");
    if !path.exists() {
        return Ok(None);
    }
    let bytes = read_bounded(&path, 1024 * 1024).map_err(|e| anyhow!("unreadable result: {e}"))?;
    Ok(Some(serde_json::from_slice(&bytes)?))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn atomic_result_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        assert!(read_outcome(dir.path()).unwrap().is_none());
        save_outcome(
            dir.path(),
            &Outcome::Selected {
                indices: vec![1, 3],
            },
        )
        .unwrap();
        match read_outcome(dir.path()).unwrap().unwrap() {
            Outcome::Selected { indices } => assert_eq!(indices, vec![1, 3]),
            _ => panic!("wrong outcome"),
        }
        assert!(save_outcome(dir.path(), &Outcome::Viewed).is_err());
    }

    fn sample(title: &str) -> Session {
        Session {
            schema: 1,
            mode: crate::model::Mode::View,
            title: title.into(),
            data: crate::input::empty_data(),
            multi: false,
            allow_empty: true,
            css: None,
            html: None,
            runtime: Default::default(),
        }
    }

    #[test]
    fn progress_files_roundtrip_and_tolerate_absence() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_ready(dir.path()), None);
        assert_eq!(read_beat(dir.path()), None);
        assert_eq!(read_failure(dir.path()), None);
        mark_ready(dir.path(), Some(4321)).unwrap();
        assert_eq!(read_ready(dir.path()), Some(Some(4321)));
        beat(dir.path(), 7);
        assert_eq!(read_beat(dir.path()).unwrap(), b"7");
        let failure = Failure::new(crate::error::code::RPC_TIMEOUT, "late");
        save_failure(dir.path(), &failure).unwrap();
        assert_eq!(read_failure(dir.path()), Some(failure));
        // Only the declared files exist: no temporary leftovers.
        let mut names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["error.json", "heartbeat", "ready"]);
        assert!(!is_done(dir.path()));
        mark_done(dir.path());
        assert!(is_done(dir.path()));
    }

    #[test]
    fn ready_without_a_host_pid_is_still_ready() {
        let dir = tempfile::tempdir().unwrap();
        mark_ready(dir.path(), None).unwrap();
        assert_eq!(read_ready(dir.path()), Some(None));
    }

    #[test]
    fn oversized_result_is_an_error_not_a_truncated_success() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("result.json"), vec![b' '; 1024 * 1024 + 1]).unwrap();
        assert!(read_outcome(dir.path()).is_err());
    }

    #[test]
    fn manifest_is_valid_toml_with_hostile_title() {
        // Quotes, backslashes, TOML syntax and Unicode in the title must stay data.
        let title = "a\"b\\c ]] [backend] program='x' Příliš 😀";
        let exe = std::env::current_exe().unwrap();
        let dir = SessionDir::create(&sample(title), &exe, 15_000).unwrap();
        let text = std::fs::read_to_string(dir.manifest()).unwrap();
        let parsed: toml::Value = toml::from_str(&text).unwrap();
        assert_eq!(parsed["app"]["name"].as_str(), Some(title));
        assert_eq!(
            parsed["backend"]["program"].as_str(),
            Some(exe.canonicalize().unwrap().to_str().unwrap())
        );
        let args: Vec<_> = parsed["backend"]["args"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(args, ["__backend", "{app_dir}"]);
        assert_eq!(parsed["backend"]["cwd"].as_str(), Some("{app_dir}"));
        assert_eq!(parsed["host"]["instance"].as_str(), Some("multiple"));
        assert_eq!(
            parsed["host"]["startup_timeout_ms"].as_integer(),
            Some(15_000)
        );
        assert_eq!(
            parsed["host"]["shutdown_timeout_ms"].as_integer(),
            Some(5_000)
        );
        assert!(read_session(dir.path()).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn session_directory_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let exe = std::env::current_exe().unwrap();
        let dir = SessionDir::create(&sample("t"), &exe, 15_000).unwrap();
        let mode = std::fs::metadata(dir.path()).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o077,
            0,
            "session dir must not be group/world accessible"
        );
    }
}
