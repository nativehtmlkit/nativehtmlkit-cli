use crate::model::{Mode, Outcome};
use crate::{protocol::Client, render, session};
use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::path::Path;

fn command(client: &mut Client, window: &str, document: &str, op: Value) -> Result<Value> {
    client.call(
        "document.command",
        json!({"window_id":window,"document_id":document,"command":op}),
    )
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
        .ok_or_else(|| anyhow!("Core form-data response has no entries"))?;
    Ok(entries.clone())
}

fn selection(
    entries: &[Value],
    max_rows: usize,
    multi: bool,
    allow_empty: bool,
) -> Result<Vec<usize>> {
    let mut result = Vec::new();
    for entry in entries {
        if entry.get("name").and_then(Value::as_str) != Some("selection") {
            continue;
        }
        let text = entry
            .get("value")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("selected item has no string value"))?;
        let idx: usize = text.parse().context("non-numeric selection index")?;
        if idx >= max_rows || result.contains(&idx) {
            bail!("invalid selection index: {idx}");
        }
        result.push(idx);
    }
    if result.len() > 1 && !multi {
        bail!("single-select returned multiple rows");
    }
    if result.is_empty() && !allow_empty {
        bail!("select at least one row before submitting");
    }
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

pub fn run(dir: &Path) -> Result<()> {
    // v1 wire protocol keeps these legacy names to avoid breaking existing clients.
    let endpoint = std::env::var("UI4ME_ENDPOINT")
        .context("__backend may only run when started by Core host")?;
    let token = std::env::var("UI4ME_TOKEN").context("missing authenticated Core launch token")?;
    if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("invalid host launch credential format");
    }
    let mut client = Client::connect(&endpoint)?;
    let hello = client.hello(&token)?;
    if hello.get("protocol_version").and_then(Value::as_u64) != Some(1) {
        bail!("Core host does not speak protocol version 1");
    }
    for key in [
        "UI4ME_ENDPOINT",
        "UI4ME_TOKEN",
        "UI4ME_APP_ID",
        "UI4ME_PROTOCOL_VERSION",
    ] {
        std::env::remove_var(key);
    }
    let specification = session::take_session(dir)?;
    let window = client.call(
        "window.create",
        json!({"title":specification.title,"width":900,"height":610}),
    )?;
    let window_id = window
        .get("window_id")
        .and_then(Value::as_str)
        .context("Core returned no window_id")?
        .to_string();
    let html = render::markup(&specification)?;
    let loaded = client.call("document.load", json!({"window_id":window_id,"html":html}))?;
    let doc_id = loaded
        .get("document_id")
        .and_then(Value::as_str)
        .context("Core returned no document_id")?
        .to_string();
    client.call("app.ready", json!({}))?;

    let mut requested_quit = false;
    loop {
        let event = client
            .next_event()
            .context("native host stopped unexpectedly")?;
        let method = event.get("method").and_then(Value::as_str).unwrap_or("");
        if method == "app.shutdown" {
            return Ok(());
        }
        if method == "document.error" {
            bail!(
                "renderer error: {}",
                event
                    .get("params")
                    .and_then(|p| p.get("message"))
                    .unwrap_or(&Value::Null)
            );
        }
        if method == "window.event" {
            // If the user closes the native window, the host handles the quit lifecycle.
            continue;
        }
        if method != "document.event" || requested_quit {
            continue;
        }
        let params = event
            .get("params")
            .context("document event missing params")?;
        if params.get("window_id").and_then(Value::as_str) != Some(window_id.as_str())
            || params.get("document_id").and_then(Value::as_str) != Some(doc_id.as_str())
        {
            continue;
        }
        let inner = params
            .get("event")
            .context("document event missing event")?;
        if inner.get("type").and_then(Value::as_str) != Some("click") {
            continue;
        }
        let element = clicked_control(inner);
        match element {
            "nhk-cancel" => {
                client.call("app.request_quit", json!({}))?;
                requested_quit = true;
            }
            "nhk-done" if specification.mode == Mode::View => {
                session::save_outcome(dir, &Outcome::Viewed)?;
                client.call("app.request_quit", json!({}))?;
                requested_quit = true;
            }
            "nhk-submit" if specification.mode == Mode::Select => {
                let entries = read_entries(&mut client, &window_id, &doc_id, "nhk-selection-form")?;
                match selection(
                    &entries,
                    specification.data.rows.len(),
                    specification.multi,
                    specification.allow_empty,
                ) {
                    Ok(indices) => {
                        session::save_outcome(dir, &Outcome::Selected { indices })?;
                        client.call("app.request_quit", json!({}))?;
                        requested_quit = true;
                    }
                    Err(error) => {
                        error_on_page(&mut client, &window_id, &doc_id, &error.to_string())?
                    }
                }
            }
            "nhk-submit" if specification.mode == Mode::Form => {
                let validity = command(
                    &mut client,
                    &window_id,
                    &doc_id,
                    json!({"op":"check_validity","element":"nhk-form"}),
                )?;
                if validity.get("valid").and_then(Value::as_bool) != Some(true) {
                    error_on_page(
                        &mut client,
                        &window_id,
                        &doc_id,
                        "Some required fields are invalid",
                    )?;
                    continue;
                }
                let entries = read_entries(&mut client, &window_id, &doc_id, "nhk-form")?;
                session::save_outcome(dir, &Outcome::Form { entries })?;
                client.call("app.request_quit", json!({}))?;
                requested_quit = true;
            }
            _ => {}
        }
    }
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
        assert!(selection(&e, 1, false, false).is_err());
        assert!(selection(&[], 4, false, false).is_err());
        assert_eq!(selection(&[], 4, false, true).unwrap(), Vec::<usize>::new());
    }
}
