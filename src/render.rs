use crate::model::{Mode, Session};
use anyhow::{bail, Result};

pub const MAX_HTML_BYTES: usize = 1024 * 1024;

pub fn escape(raw: &str) -> String {
    let mut result = String::with_capacity(raw.len());
    for c in raw.chars() {
        match c {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            '"' => result.push_str("&quot;"),
            '\'' => result.push_str("&#39;"),
            _ => result.push(c),
        }
    }
    result
}

const CSS: &str = r#"
:root{color-scheme:dark;--background:#202734;--panel:#2b3444;--border:#4e5b70;--text:#edf2f7;--accent:#6798d5}
*{box-sizing:border-box}body{margin:0;background:var(--background);color:var(--text);font:14px sans-serif}
main{padding:20px;min-height:100vh}h1{font-size:20px;margin:0 0 8px;font-weight:600}
small,.muted{color:#bac7d9}.scroll{max-height:calc(100vh - 170px);overflow:auto;border:1px solid var(--border);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:9px 12px;border-bottom:1px solid #415068;text-align:left}
th{position:sticky;top:0;background:#344258;z-index:1}tr:hover{background:#34435a}
footer{display:flex;gap:10px;justify-content:flex-end;margin-top:14px}
button{border:1px solid #66768c;border-radius:7px;color:var(--text);padding:9px 18px;background:#39465b;cursor:pointer}
button.primary{background:#2867b4;border-color:#4384d1}button:hover{filter:brightness(1.12)}
pre{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.45;padding:12px;margin:0}
.error{color:#ffaeae;min-height:22px}input[type=checkbox],input[type=radio]{accent-color:var(--accent)}
"#;

pub fn markup(session: &Session) -> Result<String> {
    let title = escape(&session.title);
    let mut html = String::with_capacity(4096);
    html.push_str("<!doctype html><html><head><meta charset='utf-8'><style>");
    html.push_str(CSS);
    if let Some(css) = &session.css {
        html.push_str(css);
    }
    html.push_str("</style></head><body><main><h1>");
    html.push_str(&title);
    html.push_str("</h1>");
    match session.mode {
        Mode::Form => {
            let custom = session
                .html
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("form mode needs --html"))?;
            html.push_str(custom);
            html.push_str("<div class='error' id='nhk-error'></div>");
            // Custom HTML must contain <form id=nhk-form> and submit/cancel event targets.
            html.push_str("<footer><button type='button' id='nhk-cancel'>Cancel</button><button type='button' id='nhk-submit' class='primary'>Submit</button></footer>");
        }
        Mode::View => {
            if session.data.format == crate::model::InputFormat::Lines {
                html.push_str("<section class='scroll'><pre>");
                for (i, row) in session.data.rows.iter().enumerate() {
                    if i != 0 {
                        html.push('\n');
                    }
                    html.push_str(&escape(&row.cells[0]));
                }
                html.push_str("</pre></section>");
            } else {
                html.push_str(&table(session, false));
            }
            html.push_str("<footer><button class='primary' type='button' id='nhk-done'>Close</button></footer>");
        }
        Mode::Select => {
            html.push_str("<form id='nhk-selection-form'><div class='scroll'>");
            html.push_str(&table(session, true));
            html.push_str("</div></form><div class='error' id='nhk-error'></div>");
            html.push_str("<footer><button type='button' id='nhk-cancel'>Cancel</button><button type='button' class='primary' id='nhk-submit'>Submit selection</button></footer>");
        }
    }
    html.push_str("</main></body></html>");
    if html.len() > MAX_HTML_BYTES {
        bail!("rendered HTML exceeds Core's 1 MiB document limit; prefilter the input");
    }
    Ok(html)
}

fn table(session: &Session, selection: bool) -> String {
    let mut result = String::from("<table><thead><tr>");
    if selection {
        result.push_str("<th>Pick</th>");
    }
    for c in &session.data.columns {
        result.push_str("<th>");
        result.push_str(&escape(c));
        result.push_str("</th>");
    }
    result.push_str("</tr></thead><tbody>");
    for (i, row) in session.data.rows.iter().enumerate() {
        result.push_str("<tr>");
        if selection {
            let kind = if session.multi { "checkbox" } else { "radio" };
            result.push_str(&format!("<td><input type='{kind}' id='nhk-row-{i}' name='selection' value='{i}' aria-label='Select row {}'></td>",i+1));
        }
        for v in &row.cells {
            result.push_str("<td>");
            result.push_str(&escape(v));
            result.push_str("</td>");
        }
        result.push_str("</tr>");
    }
    result.push_str("</tbody></table>");
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::parse;
    use crate::model::{InputFormat, Mode, Session};
    #[test]
    fn malicious_input_is_rendered_as_text() {
        let session = Session {
            schema: 1,
            mode: Mode::Select,
            title: "<script>alert(1)</script>".into(),
            data: parse("<img src=x onerror=evil>\n", InputFormat::Lines, false).unwrap(),
            multi: false,
            allow_empty: false,
            css: None,
            html: None,
        };
        let html = markup(&session).unwrap();
        assert!(html.contains("&lt;img src=x onerror=evil&gt;"));
        assert!(!html.contains("<img src=x onerror=evil>"));
        assert!(html.contains("&lt;script&gt;"));
    }
    #[test]
    fn one_megabyte_limit() {
        let mut session = Session {
            schema: 1,
            mode: Mode::View,
            title: "x".into(),
            data: parse("x\n", InputFormat::Lines, false).unwrap(),
            multi: false,
            allow_empty: false,
            css: None,
            html: None,
        };
        session.css = Some("X".repeat(MAX_HTML_BYTES));
        assert!(markup(&session).is_err());
    }
}
