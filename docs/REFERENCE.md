# Command reference

Reference for **`nativehtmlkit` 0.1.2** (alias `nhk`), built for and bundled with Core host
1.0.3. Everything here was taken from the released binary's `--help`, from the source of the
release commit, and checked against the released Linux and Windows archives (see
[Verification](#verification)).

```text
nativehtmlkit [GLOBAL OPTIONS] <COMMAND> [COMMAND OPTIONS]
```

| Command | Purpose | stdin | stdout on success | Page |
|---|---|---|---|---|
| `select` | choose one row (or several with `--multi`) from piped records | records, required, not a terminal | the chosen rows, in input order | [select](reference/select.md) |
| `view` | show piped records read-only | records, required, not a terminal | nothing | [view](reference/view.md) |
| `form` | show a trusted HTML form and return its values | not read | one JSON object `{"entries":[...]}` | [form](reference/form.md) |
| `doctor` | show which Core host would be used and its version | not read | three lines of text | [doctor](reference/doctor.md) |
| `help [COMMAND]` | print help | not read | help text | |

| Topic | Page |
|---|---|
| Options every command accepts (`--host`, `--timeout`, `--rpc-timeout`, ...) | [Global options](reference/global-options.md) |
| `lines`, `csv`, `tsv`, `json`, `ndjson`: exact parsing rules | [Input formats](reference/input-formats.md) |
| `same`, `lines`, `csv`, `tsv`, `json`, `ndjson`: exact output bytes | [Output formats](reference/output-formats.md) |
| Exit statuses, the `error[<code>]` line, stdout/stderr discipline | [Exit status and errors](reference/exit-status.md) |
| Size limits (8 MiB, 2,000 rows, 32 columns, 1 MiB page, 65,536 nodes, 256 KiB files) | [Limits](reference/limits.md) |
| Environment variables | [Environment](reference/environment.md) |
| `--diagnostics` records on stderr | [Diagnostics](reference/diagnostics.md) |
| The generated page (element ids and classes) for `--css` and `--html` authors | [Page structure](reference/page-structure.md) |

## Contract in one table

| Outcome | Exit | stdout | stderr |
|---|---|---|---|
| Submitted (`select`, `form`) or viewer closed (`view`) | 0 | the result (nothing for `view`) | host log only |
| Error: bad input or option, host missing, host failure or hang | 1 | empty | one line `nativehtmlkit: error[<code>]: <text>` (usage errors: the usual `error: ...` help text) |
| Cancel button, or window closed without submitting | 2 | empty | nothing extra |
| `--timeout` expired before a decision | 124 | empty | `nativehtmlkit: no decision before the --timeout deadline; the window was closed` |
| SIGINT / Ctrl+C | 130 | empty | |
| SIGTERM | 143 | empty | |
| SIGHUP | 129 | empty | |

`--help`, `-h`, `--version`, `-V` exit 0. The result is written in one piece after the window
has closed, never partially, and never after an error or an interruption.

## Quick examples

```bash
printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi             # -> e.g. "alpha\ngamma\n"
printf 'name,status\na,up\nb,down\n' | nativehtmlkit select --input-format csv --output-format json
docker ps --format '{{json .}}' | nativehtmlkit select --input-format ndjson
ps aux | nativehtmlkit view --title 'Processes'
nativehtmlkit form --html examples/sample-form.html --timeout 300
nativehtmlkit doctor
```

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # Windows PowerShell 5.1: send UTF-8 without BOM
Get-Process | Select-Object Id, ProcessName | ConvertTo-Json | nativehtmlkit select --input-format json --multi
if ($LASTEXITCODE -eq 2) { 'cancelled' }
```

More: [how-to guides](guides/README.md), [tutorial](tutorials/build-a-project-picker.md),
[runnable examples](../examples/README.md), [architecture](ARCHITECTURE.md).

## Verification

The statements in this reference that concern input parsing, limits, option validation, exit
statuses and the stderr lines are asserted by `scripts/test-examples.sh` against the released
`nativehtmlkit-cli-v0.1.2-linux-x64` archive with its bundled Core 1.0.3 host, headless
(`NATIVEHTMLKIT_CLI_TEST_HEADLESS=1`). Output formats and the GUI behaviour (selection order,
Cancel, window close, form validation, keyboard use) are asserted by the release's GUI
qualification on KDE Plasma Wayland and Windows Server 2022 (`tests/gui/`, 49/49 per platform)
and by the unit tests in `src/output.rs`. See [QUALIFICATION.md](QUALIFICATION.md).
