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
| Error (bad input, usage error, host failure or hang) | 1 | empty |
| Cancel button or window closed without submitting | 2 | empty |
| `--timeout` expired before the user decided | 124 | empty |
| Interrupted by Ctrl+C / SIGINT | 130 | empty |
| Terminated by SIGTERM / SIGHUP (the window is closed at once) | 143 / 129 | empty |

The result is written in one piece after the window closes, never partially. Everything else
goes to stderr: the Core host's JSON log, the CLI's own diagnostic records and, on failure, one
line `nativehtmlkit: error[<code>]: <text>`. The code is stable and meant for scripts:

| Code | Meaning |
|---|---|
| `input.invalid`, `usage.invalid` | stdin, `--html`/`--css` file or an option value cannot be used |
| `host.not_found` | no Core host executable, or it cannot be started |
| `host.startup_timeout` | the host did not open the window within `--startup-timeout` |
| `host.unresponsive` | the window was open but the host stopped answering liveness probes: it hung |
| `host.shutdown_timeout` | the host accepted the quit request and never closed the session |
| `host.failed` | the host process ended unsuccessfully without a more specific cause |
| `backend.unresponsive` | the CLI's own backend process stopped reporting progress |
| `rpc.timeout` | a request got no response within `--rpc-timeout` (remote outcome unknown) |
| `rpc.rejected` | the host answered with a JSON-RPC error (`host code N`) |
| `transport.connect_failed`, `transport.disconnected` | the local connection could not be made / ended |
| `protocol.truncated_frame`, `protocol.invalid_frame`, `protocol.violation`, `protocol.handshake_failed` | the host broke the v1 wire contract |
| `document.error`, `session.invalid`, `output.failed`, `internal` | renderer error, private session files, stdout write failure, CLI defect |

Error text never quotes stdin data, selections, form values, host-authored messages or the
launch token.

- **Input** (`--input-format`): `lines` (default), `csv`, `tsv` (first row = headers unless
  `--no-headers`), `json` (array or single value), `ndjson`. UTF-8 only; at most 8 MiB, 2,000 rows,
  32 columns. `select`/`view` refuse a terminal stdin.
- **What fits in a window**: the generated page must stay inside the host's document limits,
  1 MiB of HTML and 65,536 document nodes. A table needs about
  `48 + 2 × (columns + 1) + rows × (3 + 2 × columns)` nodes (`view`: `rows × (1 + 2 × columns)`),
  so for example 2,000 rows × 14 columns, 1,870 × 16 or 976 × 32 fit, and 2,000 × 32 does not.
  Anything larger is refused with `input.invalid` before a window opens; the message says how
  many rows would fit at that width.
- **Output** (`--output-format`, default `same`): selected rows in input order (not click order).
  JSON/NDJSON records keep their key order and number text (big integers, trailing zeros).
  CSV/TSV are re-quoted correctly; `lines` refuses values containing newlines (use JSON).
- **Form**: `--html` is a *trusted* fragment (at most 256 KiB) containing `<form id="nhk-form">`
  with named controls; Submit runs Core constraint validation and returns Core's
  successful-control entries (`{"kind","name","value"}`, duplicates preserved). `--css` adds
  trusted CSS. A fragment without `<form id="nhk-form">` is refused before a window opens.
- Untrusted input is always HTML-escaped; Core runs no scripts.

## Waiting for the user vs. a hung host

A window may stay open for as long as the user needs: there is no default limit on thinking
time. What is bounded is the *host*:

| Option | Default | Bounds |
|---|---|---|
| `--rpc-timeout SECONDS` | 30 | one request/response, a frame that has started arriving, one write |
| `--liveness-interval SECONDS` | 5 | idle time before the host is asked `host.capabilities` (answer due within 2 × `--rpc-timeout`); `0` disables probing |
| `--startup-timeout SECONDS` | 15 | host start until the window is ready (plus a 5 s launcher margin) |
| `--timeout SECONDS` | none | the user: closes the window and exits 124 |

While the window is idle the backend probes the host's event loop with `host.capabilities` (a
v1 method; no wire extension). Any answer proves the host is alive, so a slow user never trips
a deadline. A probe is allowed twice `--rpc-timeout`: a healthy host may be busy for a while
(a large relayout, a native modal loop), and ending such a session would discard the user's
input, which is worse than noticing a real hang late. No answer in that time means the host has
hung (65 s after it stopped responding with the defaults): the backend records
`host.unresponsive`, and the launcher stops the host (on Linux including the supervised host
process, found through the process id the host reports in `host.diagnostics`) and exits 1.
The launcher also has its own watchdog for a host that never starts the backend, for a host
that never exits after the session ended, and for a backend that stops reporting. Every frame
the backend receives from the host counts as progress, so a host that answers slowly but
within the deadlines is not taken for a dead one. All waits are counted in time actually spent waiting, so a
suspended laptop is not mistaken for a hung host. Failures are fail-closed: once a failure is
recorded, nothing is written to stdout even if a result had been captured.

Limits of this design: with `--liveness-interval 0` a hung host is only noticed at the next
request; a host that hangs while the CLI itself is SIGKILLed is left to Core's supervision
(see `docs/QUALIFICATION.md`, known limitations).

## Host discovery

`--host PATH` > `NATIVEHTMLKIT_HOST_BINARY` > `nativehtmlkit-host` beside the CLI executable >
`PATH`. Release archives bundle the exact qualified host; its SHA-256 and version are recorded in
the archive's `manifest.json`. The override variable is for development.

## Process and data safety

- The session directory is created with mode `0700` (Unix) and holds the generated manifest and
  piped data; the backend deletes `session.json` right after reading it; the directory is removed
  when the CLI exits, including on SIGINT/SIGTERM/SIGHUP (if the CLI itself is SIGKILLed, the
  now data-free directory is left in the temp directory). Besides the result it only ever
  contains progress markers and diagnostic records without user data.
- The host is bound to the CLI's lifetime (Linux `PR_SET_PDEATHSIG`, Windows kill-on-close Job
  Object): killing the CLI closes the window and its backend.
- Core v1 launch credentials (`UI4ME_*`, the names are fixed by wire protocol v1) are read by
  the internal backend and removed from its environment before anything else happens.

On Windows PowerShell, serialize objects first:
`Get-Process | Select-Object Id, ProcessName | ConvertTo-Json | nhk select --input-format json`.

## Diagnostics

`--diagnostics off|normal|debug|trace` (or `NATIVEHTMLKIT_DIAGNOSTICS`; the flag wins) sets the
level for the CLI and is exported to the Core host. CLI records are single-line JSON on stderr:

```json
{"schema_version":1,"timestamp":"2026-11-15T17:47:07.177Z","session_id":"nhk-4242-18e8…","component":"nativehtmlkit-cli","role":"backend","pid":4250,"level":"debug","event":"rpc.completed","request_id":"nhk-4","operation":"document.load","duration_ms":28}
```

| Level | CLI records |
|---|---|
| `off` | none |
| `normal` (default) | host/transport/protocol failures only: `rpc.timeout`, `rpc.failed`, `backend.failed`, `host.watchdog`, `host.killed`, `session.failed` |
| `debug` | plus lifecycle and timings: `session.started`, `host.spawned`, `backend.started`, `handshake.completed`, `rpc.completed`, `window.ready`, `host.request`, `submit.rejected`, `submit.accepted`, `user.cancelled`, `deadline.expired`, `session.shutdown`, `host.exited`, `session.completed` |
| `trace` | plus `rpc.started`, `event.received`, `liveness.ok` |

`session_id` comes from `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` when the caller sets a
well-formed one (`[A-Za-z0-9._:-]`, at most 128 characters), otherwise it is generated; a
malformed value is replaced and that is disclosed (`session_id.replaced`). The same id is
exported to the host, whose records carry it as `diagnostic_session_id` (Core 1.0.2 and later),
and reaches the backend through the host. `role` is `launcher` (the process you started) or
`backend` (the process the host started); backend records are written to a private file and
relayed by the launcher, at most 1 MiB per session (`diagnostics.dropped` reports any excess).

Records contain event names, operation names, request ids, durations, counts and codes. They
cannot contain stdin data, selections, form values, HTML, titles, paths or the launch token:
the recording API only accepts fixed strings, numbers, booleans and identifier-shaped text.
The Core host's own records are a separate channel; review them before sharing.

## Build, test, package (local only)

```bash
bash scripts/test-local.sh            # boundary check, fmt, clippy -D warnings, all tests, release build
python3 scripts/build-release.py      # the release build used for packaging: local paths remapped
NATIVEHTMLKIT_HOST_BINARY=/path/to/nativehtmlkit-host cargo run --release -- doctor

# Everything except the GUI, against one exact host; writes results.json, logs and dist/
python3 scripts/qualify.py run --host /path/to/nativehtmlkit-host --host-version 1.0.2 \
    --host-sha256 <from the Core release> --evidence /path/to/evidence

# Packaging alone (also run by qualify.py). The host is an input pinned by SHA-256.
python3 scripts/package-local.py --host /path/to/nativehtmlkit-host --host-version 1.0.2 --host-sha256 <sha>
```

The host given to the packager must be the executable inside an unpacked Core release (next to
its `release-manifest.json`, `LICENSE`, `THIRD_PARTY_NOTICES.md` and `licenses/`). `dist/` then
holds the archive, its `.sha256`, `SHA256SUMS` and the staged tree with `manifest.json` (CLI and
host SHA-256, the host's source tree, protocol version, CLI source tree hash, commit and dirty
flag, `Cargo.lock` hash, toolchain), `licenses/cli/THIRD-PARTY-LICENSES.txt` (full licence
texts of every crate linked into the CLI for that target) and `licenses/core/` (the bundled
host's licence, notices and release manifest, copied from the Core release). The packager
refuses a Core release whose files do not match its own `SHA256SUMS`, a host whose hash or
release manifest differs from the pin, a crate without licence text or declared licence, a CLI
binary older than its sources or one that embeds local build paths (build with
`scripts/build-release.py`). The archive is deterministic: sorted members, owner 0/0, a fixed
timestamp (`SOURCE_DATE_EPOCH` or 2000-01-01), so repackaging the same inputs gives the same
bytes. `--publish` (never run by any script here) additionally requires a clean commit, the tag
`v<version>` pointing at it, and no existing release of that tag. The packager also verifies the
archive from a clean extraction, including a headless protocol session between the extracted
CLI and the bundled host.

Dependencies are registry-only and locked; `deny.toml` is the licence/source/advisory policy
that `qualify.py` checks offline with `cargo deny` when it is installed.

Tests: unit tests in `src/`; `tests/fake_host_roundtrip.rs` and `tests/fake_host_faults.rs`
drive the backend with a scripted host over the real transport (Unix socket / Windows named
pipe); `tests/launcher_e2e.rs` runs the real executable as a pipeline stage against a scripted
host process. See `tests/README.md`. Native GUI qualification harnesses:
`tests/gui/linux-kde-wayland.sh` (inside a KDE Wayland session, ydotool input, spectacle
screenshots) and `tests/gui/windows-interactive.ps1` (inside an interactive Windows desktop,
SendInput + UI Automation). The complete run per platform, including the GUI stage on the lab
machines, is `scripts/lab/qualify-linux.sh` and `scripts/lab/qualify-windows.sh`. Results:
`docs/QUALIFICATION.md`.

This repository is independent of Core (no crate/source dependency) and has no GitHub Actions.
Releases are built and verified locally and uploaded to GitHub Releases only on explicit request.

## Releases

Current: [v0.1.1](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.1)
(prerelease; Linux x86-64 `.tar.gz` and Windows x86-64 `.zip`, each bundling Core host 1.0.2).
Extract the archive anywhere and run `nhk`; the CLI finds the host beside itself. Verify the
download against the release's `SHA256SUMS`. What was qualified, and the known limitations, are
in `docs/QUALIFICATION.md`.
