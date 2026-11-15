# Use-case map, feature feasibility, gaps

## Practical scenarios

| Scenario | Example | Stage | Key constraints |
|---|---|---|---|
| Filter command output | `printf ... \| nhk select --multi` | P1 | Exact stdout, Cancel semantics |
| Select processes | `ps -eo pid,comm \| nhk view` initially; structured JSON via CLI for select | P2 | Avoid parsing arbitrary whitespace as structured table |
| Select Docker containers | `docker ps --format '{{json .}}' \| nhk select --input ndjson` | P2 | Return unchanged JSON records |
| Inspect logs | `journalctl -n 200 \| nhk view` | P2 | Read-only, no stdout |
| Select rows from CSV | `cat data.csv \| nhk select --input csv --multi` | P2 | Header/quotes/newlines; formula cells preserved as data |
| Native prompt in scripts | `nhk input --label Name` | P3 | Do not consume stdin accidentally from terminal |
| Confirmation gate | `nhk confirm --message 'Proceed?'` | P3 | Explicit semantics and status |
| Parameter form | `nhk form --spec form.json` | P3 | Typed JSON data, validation, labels |
| Custom HTML/CSS | `nhk form --html form.html --css style.css` | P4 | HTML must be trusted local template, no JS |
| Agent-driven approval | MCP local tool sends user-visible request, receives result | Future | Explicit human session and trust, separate MCP transport |
| Remote SSH automation | invocation on machine with GUI unavailable | Not initial | Need authorized interactive desktop agent/broker, not blind SSH |
| Continuous log viewer | `journalctl -f \| nhk view --follow` | Future | Streaming, backpressure, incremental UI and cancellation |
| Portable browser substitute | open internet pages / run scripts | Never | No JS / network browser semantics |

## Feasibility classes

**Available now in renderer, CLI implementation required:** list/table UI, text inputs, checkboxes, radio buttons, focus, forms, dialog, local HTML/CSS, native file dialogs, basic accessibility, clipboard.

**Implement in CLI Rust:** pipe parsing, stable row identity, multi-select state, keyboard shortcut logic, search/filter, pagination, rendering templates, role changes, submit/cancel transactional result, exit codes, version checking, test harness and wrappers.

**May require Core improvements later:** efficient diff/virtual table updates for 100k+ rows, advanced selectable grid accessibility, generic rich editor, robust window activation across compositors, true stream-driven table viewer, broader platform support.

**Not currently available in Core:** native date/time/color picker, JavaScript, embedded browser, audio/video, canvas/WebGL, printing/PDF, macOS/X11, ARM64. Avoid treating these as prerequisites for v0.1.

## Failure scenarios to prioritize

1. Upstream command never closes stdin → CLI cannot open the window unless explicit streaming mode exists. v0.1 is **snapshot after EOF**; document the limitation.
2. GUI backend crashes after user clicks Submit → reject partial/missing result; never confuse crash with Cancel.
3. Ctrl+C/terminal closes → process-tree cleanup; no orphaned native host or temporary session folder.
4. Closing native window or Escape → cancellation state committed before approving close, no stdout.
5. Backend logs to stdout → logs captured by host; launcher stdout remains clean.
6. A slow or closed downstream consumer → bounded write behavior and BrokenPipe handling; unavoidable partially written bytes on a post-commit pipe failure must be documented.
7. Non-UTF-8 or malformed NDJSON/CSV → clear error and nonzero exit, no invisible fallback.
8. Renderer rejects 1 MiB HTML or 2 MiB IPC payload → bounded pages and display cell truncation, original records preserved.
9. Windows PowerShell 5.1 character conversion → explicit UTF-8 examples and tests for Cyrillic, Czech characters, emoji, CRLF.
10. Large data or malicious CSV formula cells → bounded resource consumption, text escape; spreadsheet export warnings.
11. User sorts list then submits → output default stays original input order, not display order.
12. Duplicate display labels → index-based row identity, never label-based selection.
