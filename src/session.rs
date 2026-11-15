use crate::model::{Outcome, Session};
use anyhow::{anyhow, bail, Context, Result};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use tempfile::{Builder, TempDir};

pub struct SessionDir {
    dir: TempDir,
}
impl SessionDir {
    pub fn create(data: &Session, executable: &Path) -> Result<Self> {
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
        session.save(data, executable)?;
        Ok(session)
    }
    pub fn path(&self) -> &Path {
        self.dir.path()
    }
    pub fn manifest(&self) -> PathBuf {
        self.path().join("app.toml")
    }
    fn save(&self, session: &Session, exe: &Path) -> Result<()> {
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
            "[app]\nid = {}\nname = {}\n\n[backend]\nprogram = {}\nargs = [\"__backend\", \"{{app_dir}}\"]\ncwd = \"{{app_dir}}\"\n\n[host]\ninstance = \"multiple\"\nmax_windows = 1\nstartup_timeout_ms = 15000\nshutdown_timeout_ms = 5000\n",
            toml::Value::String(app_id),
            toml::Value::String(session.title.clone()),
            toml::Value::String(program.to_owned()),
        );
        fs::write(self.manifest(), txt).context("write private host manifest")?;
        Ok(())
    }
}

/// Read the private session and remove it at once: the piped data should not stay at
/// rest on disk for the lifetime of the window (the backend is its only reader).
pub fn take_session(dir: &Path) -> Result<Session> {
    let session = read_session(dir)?;
    fs::remove_file(dir.join("session.json")).context("remove private session file")?;
    Ok(session)
}

pub fn read_session(dir: &Path) -> Result<Session> {
    let data = fs::read(dir.join("session.json")).context("read private session file")?;
    if data.len() > 16 * 1024 * 1024 {
        bail!("session payload is too large");
    }
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
    let pending = dir.join(format!("result.{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending)?;
    let bytes = serde_json::to_vec(result)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&pending, &target).context("atomically commit session result")?;
    Ok(())
}

pub fn read_outcome(dir: &Path) -> Result<Option<Outcome>> {
    let path = dir.join("result.json");
    if !path.exists() {
        return Ok(None);
    }
    let bytes = fs::read(path)?;
    if bytes.len() > 1024 * 1024 {
        return Err(anyhow!("result exceeds 1 MiB"));
    }
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
        }
    }

    #[test]
    fn manifest_is_valid_toml_with_hostile_title() {
        // Quotes, backslashes, TOML syntax and Unicode in the title must stay data.
        let title = "a\"b\\c ]] [backend] program='x' Příliš 😀";
        let exe = std::env::current_exe().unwrap();
        let dir = SessionDir::create(&sample(title), &exe).unwrap();
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
        assert!(read_session(dir.path()).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn session_directory_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let exe = std::env::current_exe().unwrap();
        let dir = SessionDir::create(&sample("t"), &exe).unwrap();
        let mode = std::fs::metadata(dir.path()).unwrap().permissions().mode();
        assert_eq!(
            mode & 0o077,
            0,
            "session dir must not be group/world accessible"
        );
    }
}
