# CLI tests

| Suite | What it proves | Needs |
|---|---|---|
| unit tests in `src/*.rs` | parsing, encoding, escaping, framing limits, failure classification, timestamps, session files, wait budgets | nothing |
| `fake_host_roundtrip.rs` | the backend's protocol conversation with a scripted host: startup, selection, form, Cancel, host requests, a slow user with liveness probes, `--timeout`, diagnostics content | nothing |
| `fake_host_faults.rs` | every host fault ends in a classified, bounded, payload-free failure: host never answers, dropped RPC, hang while idle, death mid-request, truncated/stalled/malformed/oversized/zero-length frames, uncorrelated responses, host errors, renderer errors, invalid selections, quit that never completes, missing credentials | nothing |
| `launcher_e2e.rs` | the real `nativehtmlkit` executable as a pipeline stage: exact stdout bytes, exit status, stderr discipline, watchdog (hung, crashed, never-started host), signals, diagnostics propagation, privacy sentinel, cleanup of processes and the session directory | nothing |
| `scripts/qualify.py run` (real-host checks) | the release binary against the real pinned Core host, headless: handshake, liveness, deadline, session-id correlation with host records, privacy at trace level, a frozen host, a killed host | a Core host binary |
| `scripts/test-publish-gates.py` | every publish gate of the packager (dirty tree, missing or misplaced tag, missing `gh`, existing release, stale manifest) and the upload step, against a throw-away Git repository and a fake `gh`; nothing is published | git |
| `scripts/test-examples.sh` | every bash example in `examples/`, the tutorial, the snippets in `README.md`/`docs/`, and the documented input formats, limits, option validation, exit statuses and stderr lines, against a real CLI and host, headless; replay cases check the examples' handling of a submitted result | a CLI release (its host beside it), `jq`, `git`, `perl` |
| `scripts/test-examples.ps1` | the PowerShell examples and documentation snippets the same way, in Windows PowerShell 5.1 (`-Shell powershell.exe`) or PowerShell 7 | a CLI release, PowerShell |
| `scripts/test-docs.py` | every bash block of `docs/linux/` marked `<!-- test: ... -->`, run as written against a real CLI and host, headless, with replayed results; the "Submit prints" outputs checked by compiling the formatter of tag v0.1.2 (`scripts/doc-outputs/doc_outputs.rs`) with the exact stdin and options of each block; coverage of every `--help` option, format, level, variable, exit status and catalogue example | a CLI release, `jq`, `git`, `cargo` (offline registry cache) |
| `scripts/test-docs.ps1` | the same for `docs/windows/` (PowerShell and `cmd.exe` blocks; a real Ctrl+C on Windows), in Windows PowerShell 5.1 (`-Shell powershell.exe`) or PowerShell 7 | a CLI release, PowerShell, `git` |
| `tests/gui/linux-kde-wayland.sh`, `tests/gui/windows-interactive.ps1` | real windows and real input on KDE Plasma Wayland and an interactive Windows desktop, from a clean extraction of the release archive | a desktop session |

`cargo test` runs the first four on Linux and Windows. They use the platform's real transport
(Unix stream socket, Windows named pipe) but no window; they are not GUI evidence.

`tests/support/mod.rs` is the scripted host. `launcher_e2e.rs` has `harness = false` because
the test binary is also the "host" executable the CLI launches (`<test exe> run --app …`); it
prints libtest-style lines, runs its cases concurrently, accepts name filters
(`cargo test --test launcher_e2e -- hung`) and reports cases that do not apply to the current
platform as `ignored`, never as `ok`.

Test-only switches of the CLI (not part of the user contract):

- `NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` adds `--headless` to the host command line, so a real
  host runs the whole protocol without opening a window.
- `NATIVEHTMLKIT_WATCHDOG_GRACE_MS` shortens the launcher watchdog margins (default 5000).

Timing: fault tests use a 0.4 s per-request deadline and assert both a lower bound (the
deadline was honoured) and an upper bound with 4 s of slack for a loaded machine. Three tests
are slow by design: an unreachable endpoint (10 s connect patience), a quit that never
completes (5 s host shutdown allowance) and a hung `doctor` (10 s).

The GUI harnesses record, per case, the command, stdin, exact stdout bytes, stderr, exit
status, screenshots and leftover processes, and append PASS/FAIL rows to `results.tsv`; the
last row `suite-complete` distinguishes a full run from a partial or aborted one.
