use crate::model::{Mode, Session};
use anyhow::{bail, Result};

pub const MAX_HTML_BYTES: usize = 1024 * 1024;

/// Core refuses a document with more than this many nodes (elements and text nodes).
pub const MAX_DOCUMENT_NODES: usize = 65_536;
/// Nodes of the generated page around the table (document skeleton, heading, footer,
/// table scaffolding), rounded up.
const PAGE_OVERHEAD_NODES: usize = 48;

/// Number of document nodes the generated page needs, counted the way the page is built:
/// one row element, one element per cell plus its text node, and for `select` the pick cell
/// with its control. Trusted `--html` forms are not parsed and are not counted here.
#[cfg(test)]
pub fn node_estimate(session: &Session) -> usize {
    let (fixed, rows) = node_parts(session);
    fixed + rows
}

/// (nodes that do not depend on the number of rows, nodes of all rows).
fn node_parts(session: &Session) -> (usize, usize) {
    let lines_view =
        session.mode == Mode::View && session.data.format == crate::model::InputFormat::Lines;
    if session.mode == Mode::Form || lines_view {
        return (PAGE_OVERHEAD_NODES, 0);
    }
    let pick = if session.mode == Mode::Select { 2 } else { 0 };
    let header = 2 * (session.data.columns.len() + pick / 2);
    let body = session
        .data
        .rows
        .iter()
        .map(|row| {
            let cells: usize = row
                .cells
                .iter()
                .map(|c| 1 + usize::from(!c.is_empty()))
                .sum();
            1 + pick + cells
        })
        .sum();
    (PAGE_OVERHEAD_NODES + header, body)
}

/// Launcher-side check that the host will accept the generated document, so the user gets
/// an actionable message instead of a window that fails to load.
pub fn validate(session: &Session) -> Result<()> {
    let (fixed, body) = node_parts(session);
    if fixed + body > MAX_DOCUMENT_NODES {
        let rows = session.data.rows.len().max(1);
        let per_row = body.div_ceil(rows).max(1);
        bail!(
            "input is too large to display: {} rows x {} columns need about {} document nodes, the host accepts {MAX_DOCUMENT_NODES}; at this width at most {} rows fit (prefilter the input or select fewer columns)",
            session.data.rows.len(),
            session.data.columns.len(),
            fixed + body,
            (MAX_DOCUMENT_NODES - fixed) / per_row
        );
    }
    markup(session).map(drop)
}

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
*{box-sizing:border-box}html,body{height:100%}body{margin:0;background:var(--background);color:var(--text);font:14px sans-serif}
main{padding:20px;height:100%;display:flex;flex-direction:column}h1{font-size:20px;margin:0 0 8px;font-weight:600;flex:none}
#nhk-selection-form{display:flex;flex-direction:column;min-height:0;flex:0 1 auto}
small,.muted{color:#bac7d9}.scroll{flex:0 1 auto;min-height:0;overflow:auto;border:1px solid var(--border);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:9px 12px;border-bottom:1px solid #415068;text-align:left}
th{position:sticky;top:0;background:#344258;z-index:1}tr:hover{background:#34435a}
footer{display:flex;gap:10px;justify-content:flex-end;margin-top:14px;flex:none}
button{border:1px solid #66768c;border-radius:7px;color:var(--text);padding:9px 18px;background:#39465b;cursor:pointer}
button.primary{background:#2867b4;border-color:#4384d1}button:hover{filter:brightness(1.12)}
pre{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.45;padding:12px;margin:0}
.error{color:#ffaeae;min-height:22px;flex:none}input[type=checkbox],input[type=radio]{accent-color:var(--accent)}
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
        bail!(
            "input is too large to display: the generated page is {} bytes, the host accepts {MAX_HTML_BYTES} (1 MiB); prefilter the input",
            html.len()
        );
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
            runtime: Default::default(),
        };
        let html = markup(&session).unwrap();
        assert!(html.contains("&lt;img src=x onerror=evil&gt;"));
        assert!(!html.contains("<img src=x onerror=evil>"));
        assert!(html.contains("&lt;script&gt;"));
    }
    #[test]
    fn node_estimate_follows_the_documented_formula() {
        let table = |rows: usize, cols: usize, mode| {
            let record: Vec<String> = (0..cols).map(|c| format!("\"c{c}\":\"v\"")).collect();
            let json = format!(
                "[{}]",
                vec![format!("{{{}}}", record.join(",")); rows].join(",")
            );
            Session {
                schema: 1,
                mode,
                title: "t".into(),
                data: parse(&json, InputFormat::Json, false).unwrap(),
                multi: true,
                allow_empty: false,
                css: None,
                html: None,
                runtime: Default::default(),
            }
        };
        // select: 48 + 2 x (columns + 1) + rows x (3 + 2 x columns)
        assert_eq!(
            node_estimate(&table(10, 4, Mode::Select)),
            48 + 10 + 10 * 11
        );
        // view: no pick column
        assert_eq!(node_estimate(&table(10, 4, Mode::View)), 48 + 8 + 10 * 9);
        assert!(validate(&table(1870, 16, Mode::Select)).is_ok());
        let refused = validate(&table(1871, 16, Mode::Select))
            .unwrap_err()
            .to_string();
        assert!(refused.contains("at most 1870 rows fit"), "{refused}");
        assert!(validate(&table(2000, 14, Mode::Select)).is_ok());
        assert!(validate(&table(2000, 32, Mode::Select)).is_err());
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
            runtime: Default::default(),
        };
        session.css = Some("X".repeat(MAX_HTML_BYTES));
        assert!(markup(&session).is_err());
    }
}
