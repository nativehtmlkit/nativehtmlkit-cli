//! The process the Core host launches for a session (`nativehtmlkit __backend <dir>`).
use crate::diag::{self, Level};
use crate::error::{code, Failure};
use crate::model::{Mode, Outcome, Session};
use crate::protocol::{known_name, method, Client};
use crate::{render, session};
use anyhow::Result;
use serde_json::{json, Value};
use std::path::Path;
use std::time::{Duration, Instant};

/// v1 launch variables. The names are permanent for protocol v1 (Core `protocol/README.md`).
const LAUNCH_ENV: [&str; 4] = [
    "UI4ME_ENDPOINT",
    "UI4ME_TOKEN",
    "UI4ME_APP_ID",
    "UI4ME_PROTOCOL_VERSION",
];
/// Wait slice when liveness probing is disabled (still needed to notice `--timeout`).
const IDLE_SLICE: Duration = Duration::from_millis(500);

fn command(client: &mut Client, window: &str, document: &str, op: Value) -> Result<Value> {
    Ok(client.call(
        method::DOCUMENT_COMMAND,
        json!({"window_id":window,"document_id":document,"command":op}),
    )?)
}

fn read_entries(
    client: &mut Client,
    window: &str,
    document: &str,
    form: &str,
) -> Result<Vec<Value>> {
    let result = command(
        client,
        window,
        document,
        json!({"op":"get_form_data","element":form}),
    )?;
    let entries = result
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::new(code::VIOLATION, "Core form-data response has no entries"))?;
    Ok(entries.clone())
}

/// Why a submitted selection was not accepted.
#[derive(Debug, PartialEq, Eq)]
enum Rejection {
    /// Nothing selected and `--allow-empty` was not given: the user can correct this.
    Empty,
    /// The host returned something the generated page cannot produce: fail the session.
    Invalid(&'static str),
}

fn selection(
    entries: &[Value],
    max_rows: usize,
    multi: bool,
    allow_empty: bool,
) -> Result<Vec<usize>, Rejection> {
    let mut result = Vec::new();
    for entry in entries {
        if entry.get("name").and_then(Value::as_str) != Some("selection") {
            continue;
        }
        let index: usize = entry
            .get("value")
            .and_then(Value::as_str)
            .and_then(|text| text.parse().ok())
            .ok_or(Rejection::Invalid(
                "Core returned a non-numeric selection index",
            ))?;
        if index >= max_rows || result.contains(&index) {
            return Err(Rejection::Invalid(
                "Core returned an out-of-range or duplicate selection index",
            ));
        }
        result.push(index);
    }
    if result.len() > 1 && !multi {
        return Err(Rejection::Invalid(
            "Core returned several rows for a single-select session",
        ));
    }
    if result.is_empty() && !allow_empty {
        return Err(Rejection::Empty);
    }
    // The documented contract is input order. Core reports successful controls in document
    // order already; sorting makes the guarantee the CLI's own.
    result.sort_unstable();
    Ok(result)
}

/// The CLI's own controls that a click event addresses. Core reports `element` as the
/// nearest identified ancestor of the target and `path` as the identified bubbling route,
/// so author markup with ids inside a button (or a custom form) still resolves correctly.
fn clicked_control(event: &Value) -> &str {
    const CONTROLS: [&str; 3] = ["nhk-cancel", "nhk-done", "nhk-submit"];
    let direct = event.get("element").and_then(Value::as_str);
    let route = event
        .get("path")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    direct
        .into_iter()
        .chain(route)
        .find(|id| CONTROLS.contains(id))
        .unwrap_or("")
}

fn error_on_page(client: &mut Client, window: &str, document: &str, message: &str) -> Result<()> {
    command(
        client,
        window,
        document,
        json!({"op":"set_text","element":"nhk-error","text":message}),
    )?;
    Ok(())
}

fn text_member(value: &Value, key: &str, what: &'static str) -> Result<String> {
    Ok(value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::new(code::VIOLATION, format!("Core returned no {what}")))?
        .to_owned())
}

/// Entry point. Any failure is classified, recorded in the session directory for the
/// launcher (which reports it and stops a host that does not stop by itself) and returned.
pub fn run(dir: &Path) -> Result<()> {
    let mut connection = None;
    let outcome = serve(dir, &mut connection);
    // Record the outcome while the connection is still open. The host kills the backend the
    // moment it sees the connection close, so anything written after that may never land.
    match &outcome {
        Ok(()) => session::mark_done(dir),
        Err(error) => {
            let failure = crate::error::classify(error, code::INTERNAL);
            // A second failure cannot replace the first; a missing directory is the
            // launcher's signal that the session is already gone.
            let _ = session::save_failure(dir, &failure);
            diag::record(Level::Normal, "backend.failed")
                .failure(&failure)
                .emit();
        }
    }
    diag::finish();
    drop(connection);
    outcome
}

fn serve(dir: &Path, connection: &mut Option<Client>) -> Result<()> {
    // Take the credentials out of the environment before anything else can fail or spawn.
    let endpoint = std::env::var("UI4ME_ENDPOINT");
    let token = std::env::var("UI4ME_TOKEN");
    for key in LAUNCH_ENV {
        std::env::remove_var(key);
    }
    let endpoint = endpoint.map_err(|_| {
        Failure::new(
            code::HANDSHAKE,
            "__backend may only run when started by the Core host",
        )
    })?;
    let token = token
        .map_err(|_| Failure::new(code::HANDSHAKE, "missing authenticated Core launch token"))?;
    if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(Failure::new(code::HANDSHAKE, "invalid host launch credential format").into());
    }
    let specification =
        session::take_session(dir).map_err(|error| crate::error::tag(error, code::SESSION))?;
    let runtime = &specification.runtime;
    diag::init_file(runtime.diagnostics, &runtime.session_id, "backend", dir);
    let inherited = std::env::var(diag::SESSION_ENV).ok();
    diag::record(Level::Debug, "backend.started")
        .flag(
            "session_id_inherited_through_host",
            inherited.as_deref() == Some(runtime.session_id.as_str()),
        )
        .flag(
            "launch_environment_cleared",
            LAUNCH_ENV.iter().all(|key| std::env::var_os(key).is_none()),
        )
        .emit();
    // Everything that can fail without the host is done before a window exists. The
    // launcher has validated the same document already; this is the backend's own check.
    let html =
        render::markup(&specification).map_err(|error| crate::error::tag(error, code::INPUT))?;

    let rpc_timeout = Duration::from_millis(runtime.rpc_timeout_ms.max(1));
    let client = connection.insert(Client::connect(&endpoint, rpc_timeout)?);
    let hello = client.hello(&token)?;
    drop(token);
    diag::record(Level::Debug, "handshake.completed")
        .ident(
            "host_version",
            hello
                .get("host_version")
                .and_then(Value::as_str)
                .unwrap_or(""),
        )
        .emit();
    // The launcher needs the real host's process id to stop a hung host: on Linux the
    // process it started is only the supervising launcher of the host's systemd unit.
    let host_pid = client
        .call(method::DIAGNOSTICS, json!({}))
        .ok()
        .and_then(|d| d.get("pid").and_then(Value::as_u64))
        .and_then(|pid| u32::try_from(pid).ok());

    // The window cannot be created hidden and shown after the document is loaded: the host
    // refuses hidden windows on Wayland (-32001). Its placeholder page may therefore be
    // visible for a moment before the document appears.
    let window = client.call(
        method::WINDOW_CREATE,
        json!({"title":specification.title,"width":900,"height":610}),
    )?;
    let window_id = text_member(&window, "window_id", "window_id")?;
    let loaded = client.call(
        method::DOCUMENT_LOAD,
        json!({"window_id":window_id,"html":html}),
    )?;
    drop(html);
    let doc_id = text_member(&loaded, "document_id", "document_id")?;
    client.call(method::READY, json!({}))?;
    session::mark_ready(dir, host_pid)?;
    // From here on every answer and every frame from the host is reported to the launcher,
    // so a host that is slow but answering is never taken for a dead backend.
    client.report_progress_to(dir);
    diag::record(Level::Debug, "window.ready").emit();

    interact(dir, client, &specification, &window_id, &doc_id)
}

/// What a `document.event` click means for this session.
enum Action {
    None,
    Cancel,
    Done,
    Submit,
}

fn interact(
    dir: &Path,
    client: &mut Client,
    specification: &Session,
    window_id: &str,
    doc_id: &str,
) -> Result<()> {
    let runtime = &specification.runtime;
    let liveness = (runtime.liveness_interval_ms != 0)
        .then(|| Duration::from_millis(runtime.liveness_interval_ms));
    let deadline = runtime.deadline_ms.map(Duration::from_millis);
    let rpc_timeout = Duration::from_millis(runtime.rpc_timeout_ms.max(1));
    // After a quit request the host asks `app.before_quit`, then announces `app.shutdown`.
    let quit_allowance = rpc_timeout + Duration::from_millis(session::HOST_SHUTDOWN_TIMEOUT_MS);
    let opened = Instant::now();
    let mut idle = Duration::ZERO;
    let mut quit_requested: Option<Instant> = None;

    loop {
        let mut slice = liveness.unwrap_or(IDLE_SLICE);
        if let (Some(limit), None) = (deadline, quit_requested) {
            slice = slice.min(
                limit
                    .saturating_sub(opened.elapsed())
                    .max(Duration::from_millis(1)),
            );
        }
        let Some(event) = client.next_event(slice)? else {
            idle += slice;
            if let Some(since) = quit_requested {
                if since.elapsed() >= quit_allowance {
                    return Err(Failure::new(
                        code::HOST_SHUTDOWN,
                        "the Core host accepted the quit request but did not shut down",
                    )
                    .after(since.elapsed())
                    .into());
                }
            } else if deadline.is_some_and(|limit| opened.elapsed() >= limit) {
                diag::record(Level::Debug, "deadline.expired")
                    .duration(opened.elapsed())
                    .emit();
                session::save_outcome(dir, &Outcome::TimedOut)?;
                client.call(method::REQUEST_QUIT, json!({}))?;
                quit_requested = Some(Instant::now());
            }
            if liveness.is_some_and(|interval| idle >= interval) {
                // Silence alone proves nothing: the user may simply be reading. Ask.
                client.probe()?;
                idle = Duration::ZERO;
            }
            continue;
        };
        // Any frame from the host is evidence that it is alive.
        idle = Duration::ZERO;
        let name = event.get("method").and_then(Value::as_str).unwrap_or("");
        diag::record(Level::Trace, "event.received")
            .tag("name", known_name(name))
            .emit();
        match name {
            "app.shutdown" => {
                diag::record(Level::Debug, "session.shutdown")
                    .duration(opened.elapsed())
                    .emit();
                return Ok(());
            }
            // The message is host-authored text about the document and is not repeated.
            "document.error" => {
                return Err(
                    Failure::new(code::DOCUMENT, "the Core host reported a document error").into(),
                )
            }
            "document.event" if quit_requested.is_none() => {}
            // window.event: closing the native window is handled by the host's quit
            // lifecycle. Unknown notifications must be ignored (v1 compatibility policy).
            _ => continue,
        }
        let action = click_action(&event, window_id, doc_id, specification.mode)?;
        let quit = match action {
            Action::None => false,
            Action::Cancel => {
                diag::record(Level::Debug, "user.cancelled").emit();
                true
            }
            Action::Done => {
                session::save_outcome(dir, &Outcome::Viewed)?;
                true
            }
            Action::Submit => submit(dir, client, specification, window_id, doc_id)?,
        };
        if quit {
            client.call(method::REQUEST_QUIT, json!({}))?;
            quit_requested = Some(Instant::now());
        }
    }
}

fn click_action(
    event: &Value,
    window_id: &str,
    doc_id: &str,
    mode: Mode,
) -> Result<Action, Failure> {
    let malformed = || Failure::new(code::VIOLATION, "host sent a malformed document.event");
    let params = event.get("params").ok_or_else(malformed)?;
    if params.get("window_id").and_then(Value::as_str) != Some(window_id)
        || params.get("document_id").and_then(Value::as_str) != Some(doc_id)
    {
        return Ok(Action::None);
    }
    let inner = params.get("event").ok_or_else(malformed)?;
    if inner.get("type").and_then(Value::as_str) != Some("click") {
        return Ok(Action::None);
    }
    Ok(match (clicked_control(inner), mode) {
        ("nhk-cancel", _) => Action::Cancel,
        ("nhk-done", Mode::View) => Action::Done,
        ("nhk-submit", Mode::Select | Mode::Form) => Action::Submit,
        _ => Action::None,
    })
}

/// Handle a Submit click. Returns true when the result was committed and the session
/// should end; false when the page now shows a validation message and stays open.
fn submit(
    dir: &Path,
    client: &mut Client,
    specification: &Session,
    window_id: &str,
    doc_id: &str,
) -> Result<bool> {
    let started = Instant::now();
    let rejected = |reason: &'static str| {
        diag::record(Level::Debug, "submit.rejected")
            .tag("reason", reason)
            .duration(started.elapsed())
            .emit();
    };
    let outcome = if specification.mode == Mode::Select {
        let entries = read_entries(client, window_id, doc_id, "nhk-selection-form")?;
        match selection(
            &entries,
            specification.data.rows.len(),
            specification.multi,
            specification.allow_empty,
        ) {
            Ok(indices) => Outcome::Selected { indices },
            Err(Rejection::Invalid(message)) => {
                return Err(Failure::new(code::VIOLATION, message).into())
            }
            Err(Rejection::Empty) => {
                rejected("empty_selection");
                error_on_page(
                    client,
                    window_id,
                    doc_id,
                    "select at least one row before submitting",
                )?;
                return Ok(false);
            }
        }
    } else {
        let validity = command(
            client,
            window_id,
            doc_id,
            json!({"op":"check_validity","element":"nhk-form"}),
        )?;
        if validity.get("valid").and_then(Value::as_bool) != Some(true) {
            rejected("invalid_form");
            error_on_page(
                client,
                window_id,
                doc_id,
                "Some required fields are invalid",
            )?;
            return Ok(false);
        }
        Outcome::Form {
            entries: read_entries(client, window_id, doc_id, "nhk-form")?,
        }
    };
    session::save_outcome(dir, &outcome)?;
    diag::record(Level::Debug, "submit.accepted")
        .duration(started.elapsed())
        .emit();
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clicks_route_through_identified_ancestors() {
        assert_eq!(
            clicked_control(&json!({"type":"click","element":"nhk-submit","path":["nhk-submit"]})),
            "nhk-submit"
        );
        // Author markup with an id inside the button: the button is on the path.
        assert_eq!(
            clicked_control(&json!({"type":"click","element":"icon","path":["icon","nhk-cancel"]})),
            "nhk-cancel"
        );
        assert_eq!(
            clicked_control(
                &json!({"type":"click","element":"nhk-row-1","path":["nhk-row-1","nhk-selection-form"]})
            ),
            ""
        );
        assert_eq!(clicked_control(&json!({"type":"click"})), "");
    }

    #[test]
    fn selected_indices_are_validated() {
        let e = vec![json!({"name":"selection","kind":"text","value":"1"})];
        assert_eq!(selection(&e, 4, false, false).unwrap(), vec![1]);
        assert!(matches!(
            selection(&e, 1, false, false),
            Err(Rejection::Invalid(_))
        ));
        assert_eq!(selection(&[], 4, false, false), Err(Rejection::Empty));
        assert_eq!(selection(&[], 4, false, true).unwrap(), Vec::<usize>::new());
        let two = vec![
            json!({"name":"selection","value":"0"}),
            json!({"name":"other","value":"9"}),
            json!({"name":"selection","value":"2"}),
        ];
        assert_eq!(selection(&two, 4, true, false).unwrap(), vec![0, 2]);
        let reversed: Vec<Value> = two.iter().rev().cloned().collect();
        assert_eq!(selection(&reversed, 4, true, false).unwrap(), vec![0, 2]);
        assert!(matches!(
            selection(&two, 4, false, false),
            Err(Rejection::Invalid(_))
        ));
        let duplicate = vec![e[0].clone(), e[0].clone()];
        assert!(matches!(
            selection(&duplicate, 4, true, false),
            Err(Rejection::Invalid(_))
        ));
        for bad in [
            json!({"name":"selection","value":7}),
            json!({"name":"selection","value":"x"}),
        ] {
            assert!(matches!(
                selection(&[bad], 4, true, false),
                Err(Rejection::Invalid(_))
            ));
        }
    }
}
