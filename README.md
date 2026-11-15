# NativeHTMLKit CLI

**Native graphical windows in ordinary command pipelines.** An independent Rust client of
NativeHTMLKit Core's local host protocol v1. No Python, PowerShell, web server, Electron, Chromium
or JavaScript runtime. Canonical executable `nativehtmlkit`; `nhk` is an alias.

```bash
printf 'alpha\nbeta\ngamma\n' | nhk select --multi            # check rows, Submit -> chosen lines
ps aux | nhk view                                              # read-only viewer, no stdout
printf 'name,status\na,up\nb,down\n' | nhk select --input-format csv --multi --output-format json
cat containers.ndjson | nhk select --input-format ndjson --multi
nhk form --html examples/sample-form.html                      # -> {"entries":[...]}
nhk doctor                                                     # which host is used, its version
```

## Contract

| Outcome | Exit | stdout |
|---|---|---|
| Submitted / viewer closed | 0 | only the result (nothing for `view`) |
| Error (bad input, usage error, host failure) | 1 | empty |
| Cancel button or window closed without submitting | 2 | empty |
| Interrupted (Ctrl+C / SIGINT) | 130 | empty |

Diagnostics and host logs go to stderr. The result is written in one piece after the window
closes, never partially.

- **Input** (`--input-format`): `lines` (default), `csv`, `tsv` (first row = headers unless
  `--no-headers`), `json` (array or single value), `ndjson`. UTF-8 only; at most 8 MiB, 2,000 rows,
  32 columns; generated HTML at most 1 MiB. `select`/`view` refuse a terminal stdin.
- **Output** (`--output-format`, default `same`): selected rows in input order (not click order).
  JSON/NDJSON records keep their key order and number text (big integers, trailing zeros).
  CSV/TSV are re-quoted correctly; `lines` refuses values containing newlines (use JSON).
- **Form**: `--html` is a *trusted* fragment containing `<form id="nhk-form">` with named controls;
  Submit runs Core constraint validation and returns Core's successful-control entries
  (`{"kind","name","value"}`, duplicates preserved). `--css` adds trusted CSS.
- Untrusted input is always HTML-escaped; Core runs no scripts.

## Host discovery

`--host PATH` > `NATIVEHTMLKIT_HOST_BINARY` > `nativehtmlkit-host` beside the CLI executable >
`PATH`. Release archives bundle the exact qualified host; its SHA-256 and version are recorded in
the archive's `manifest.json`. The override variable is for development.

## Process and data safety

- The session directory is created with mode `0700` (Unix) and holds the generated manifest and
  piped data; the backend deletes `session.json` right after reading it; the directory is removed
  when the CLI exits (if the CLI itself is SIGKILLed, the now data-free directory with the
  generated manifest is left in the temp directory).
- The host is bound to the CLI's lifetime (Linux `PR_SET_PDEATHSIG`, Windows kill-on-close Job
  Object): killing the CLI closes the window and its backend.
- Core v1 launch credentials (`UI4ME_*`) are read by the internal backend and removed from its
  environment immediately.

On Windows PowerShell, serialize objects first:
`Get-Process | Select-Object Id, ProcessName | ConvertTo-Json | nhk select --input-format json`.

## Build, test, package (local only)

```bash
bash scripts/test-local.sh            # fmt, clippy -D warnings, unit + fake-host tests, release build
NATIVEHTMLKIT_HOST_BINARY=/path/to/nativehtmlkit-host cargo run --release -- doctor
python3 scripts/package-local.py --host /path/to/nativehtmlkit-host --host-version 1.0.1 --host-sha256 <from Core release-manifest.json>
```

Native GUI qualification harnesses: `tests/gui/linux-kde-wayland.sh` (inside a KDE Wayland session,
ydotool input, spectacle screenshots) and `tests/gui/windows-interactive.ps1` (inside an interactive
Windows desktop, SendInput + UI Automation). Results: `docs/QUALIFICATION.md`.

This repository is independent of Core (no crate/source dependency) and has no GitHub Actions.
Releases are built and verified locally and uploaded to GitHub Releases only on explicit request.
