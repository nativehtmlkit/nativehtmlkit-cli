# Competitive research and standards

Inspected public documentation 2026-11-15; links in `SOURCES.md`.

| Project | Proven use | Gap relative to NativeHTMLKit CLI | Lesson |
|---|---|---|---|
| PowerShell `Out-GridView` | Windows-only interactive table and `-PassThru` selected PowerShell objects | Linux and generic shell native text; UI themed with HTML/CSS | Select-and-return is a useful mature pattern |
| Charmbracelet `gum` | Terminal-based `choose`, `filter`, `input`, `write`, `confirm`, `table`; stdout-friendly | Not a native desktop window | One command = one clear input/output contract |
| KDE `kdialog` | Scripting GUI dialogs, checklists/radiolists/paths | KDE-specific; not cross-platform | Zero SDK requirement matters |
| GNOME `zenity` | GUI lists, checklists, multi-select, separator output | Dialog toolkit-specific and custom layouts limited | Keep short commands, consistent exit statuses |
| `yad` | Flexible dialog frontend (not relied upon as design authority here) | Linux ecosystem dependence | Useful later for comparing power-user flags |

## Real differentiation, not invention of a new category

NativeHTMLKit offers an explicitly **desktop native HTML/CSS renderer**, shared with Python and PowerShell SDKs, with no browser/JS server. The CLI provides a quick on-ramp. It should not claim to invent selection dialogs or claim fully portable desktop sessions unsupported by Core.

## Relevant standards

- **JSON Schema 2020-12** — machine-readable config, form and result envelopes. Avoid OpenAPI because no HTTP server is involved.
- **JSON Lines / NDJSON** — UTF-8, one complete JSON value per newline. Use as practical format; distinguish from JSON arrays.
- **CSV** — RFC 4180 dialect as default reference with deliberate explicit handling of LF/CRLF, quotes, header, commas; reject unparseable or ambiguous headers.
- **PowerShell pipelines** — external native applications receive encoded text, *not live PSObjects*. Recommend `ConvertTo-Json` / `ConvertFrom-Json`. PowerShell 7.4 improves byte-preserving native pipelines, but Windows PowerShell 5.1 has different encoding defaults. Test UTF-8, BOM and CRLF explicitly.
- **Windows interactive session** — services/SSH logons are not an implied GUI desktop. Fail with a clear message and status code rather than hang.
- **Security** — preserve untrusted data as text, respect Core's local asset restrictions, prevent untrusted HTML injection, and warn about spreadsheet formula injection on CSV exports.

## A decision on data purity

`nhk select` should be an identity-preserving filter by default: a row is selected, not transformed. Search, sorting and presentation columns must not silently alter the records being emitted. This makes pipelines predictable and avoids the class of `Out-GridView` formatting traps.
