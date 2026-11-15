# CLI qualification — v0.1.1 against Core 1.0.2 (2026-11-15)

**Status: qualified source checkpoint, not a published release.** Every gate below was executed
against the pinned final Core 1.0.2 hosts on both platforms, from one CLI source tree, and
passed: **132 records, 132 PASS, 0 FAIL, 0 BLOCKED**. Two things keep this from being a release:
the CLI tree is uncommitted (`source_dirty: true` on commit `35b170a`) and the Core release
itself was built from a dirty tree (`4f63398c…`, `source_dirty: true`). The archives must be
rebuilt from committed sources before publication; nothing has been published. The results
recorded for v0.1.0 (`9ec8b606`, Core 1.0.1) are not inherited.

| | Linux | Windows |
|---|---|---|
| Non-GUI gates | Debian 13 workstation, rustc 1.99.1 | Windows Server 2022 VM `winDEV` over SSH, rustc 1.100.0 |
| GUI session | KDE Plasma 6.6.6 native Wayland, Ubuntu 26.04.1 (lab VM `linuxDEV`), ydotool/uinput, spectacle | interactive RDP desktop of dedicated user `nhk_gui` (winDEV), SendInput, `CopyFromScreen`; UI Automation only locates elements |
| CLI source tree hash | `7b2929fde5fbbeeed28e7cbb50e99b324337a2c6ed0ff0a12e8949688e44f569` | same (verified on the VM through `SOURCE-IDENTITY.json`) |
| Core host 1.0.2 (source tree `4f63398c948d8d674b7992e916b551042f646b7a`) | sha256 `702adafcbfe3c969cb12d0de5d37546727ee13b147c8fc866c7afa18aa741d2a` | sha256 `64d4502f27782bd17329ab6d560fc27b4e3d404b719ddd9bafc507d46d8638f4` |
| CLI binary | sha256 `e191d59df64b6a01c12ed9e7e702478019fa85279721ceb83c60989bfb0d4ad5` | sha256 `16834292b66602f8140f1041065a9a00d84e0bea15d86de1a2a26abb028f5f82` |
| Archive | `nativehtmlkit-cli-v0.1.1-linux-x64.tar.gz` sha256 `c19e9827c48c42e6388d332d91e6b3179efcc6c645417ca37f52edd5286dffde` | `nativehtmlkit-cli-v0.1.1-windows-x64.zip` sha256 `db5223a5cee46ec41f6d746bdc02ad225c3fe54f1d483784589dd1971c2b4912` |
| Records | **67: 67 PASS** | **65: 65 PASS** |

Commands, durations, exit codes, logs and screenshots: `final2/results.json`, `final2/linux/` and
`final2/windows/` under `nativehtmlkit-project/verification/2026-11-15-sdk/cli/` (local, not
committed). Kept beside it: `final/` (the same hosts before the independent final review; superseded, with
the frame-sequence recordings) and the development-host checkpoint (`linux/`, `windows/`).

## Gates

| Gate | Record | Linux | Windows |
|---|---|---|---|
| G8 | host matches the pinned SHA-256 | PASS | PASS |
| G0 | repository boundaries (`scripts/check-repo.py`) | PASS | PASS |
| G0 | dependency policy (`cargo deny --offline check licenses bans sources advisories`) | PASS | PASS |
| G0 | `cargo fmt --all -- --check` | PASS | PASS |
| G0 | `cargo clippy --locked --all-targets -- -D warnings` | PASS | PASS |
| G2 | unit tests (`cargo test --locked --bins`) | 41 passed | 38 passed |
| G3 | `tests/fake_host_roundtrip.rs` | 8 passed | 8 passed |
| G4 | `tests/fake_host_faults.rs` | 25 passed | 25 passed |
| G4 | `tests/launcher_e2e.rs` | 30 passed | 25 passed, 5 ignored (need POSIX signals, `/dev/full`, procfs) |
| G0 | `scripts/build-release.py` (`cargo build --locked --release` with local paths remapped) | PASS | PASS |
| G7 | real host, headless: `doctor` | PASS | PASS |
| G7 | real host: handshake, document load, liveness probes, `--timeout` → 124 | PASS | PASS |
| G7 | real host: one session id in launcher, backend and host records; all 9 CLI request ids appear host-side as `rpc.received` and `rpc.completed` | PASS | PASS |
| G7 | real host: 1870 × 16 accepted; 1871 × 16, 2000 × 32 and a 1.2 MB page refused as `input.invalid` before any host start | PASS | PASS |
| G4 | real host: backend-side failure reports its cause, 10 of 10 runs (`rpc.rejected`, host code -32005) | PASS | PASS |
| G4 | real host: trace output has no user data and no 64-hex credential | PASS | PASS |
| G4 | real host frozen (SIGSTOP / `NtSuspendProcess`) → `error[host.unresponsive]`, exit 1, host killed | PASS (6.4 s) | PASS (6.3 s) |
| G4 | real host killed → error, not Cancel | PASS | PASS |
| G8 | package with the pinned host from the Core release directory; clean extraction; checksums; bundled-host headless session | PASS | PASS |
| G6 | GUI suite from a clean extraction of the archive (below) | 48/48 PASS | 46/46 PASS |

## GUI cases (real windows, real input)

Every case asserts exact stdout bytes, exit status and that none of the suite's own
`nativehtmlkit` / `nhk` / `nativehtmlkit-host` processes (Linux: nor its systemd units) remain.

| ID | Scenario | Linux | Windows |
|---|---|---|---|
| S02 | click row 2 + Submit → exactly `beta\n`; two rows → input order; single-select radio | PASS | PASS |
| S03 | Cancel → 2; title-bar close → 2; empty Submit shows the in-window message, then succeeds | PASS | PASS |
| S04 | invalid JSON, ragged CSV, empty input, invalid UTF-8, unknown flag → 1, empty stdout | PASS | PASS |
| S05 | 2,000 rows open and scroll; 2,001 rows and > 8 MiB → 1 | PASS | PASS (8 MiB case Linux only) |
| S06 | JSON types, key order, Unicode preserved; NDJSON multi-select | PASS | PASS (JSON) |
| S07 | CSV re-quoting, TSV output, `lines` refuses newline values | PASS | PASS (CSV) |
| S08 | form from the archive's `examples/sample-form.html`: required-field error, typed text, checkbox → exact entries | PASS | PASS |
| S09 | keyboard selection; **keyboard-only Submit with Enter and with Space**; live resize | PASS | PASS (frame size asserted) |
| S09 | **60 rows, window made 150 px shorter**: the table gives up the height, Submit stays reachable → exact result | PASS | PASS (button inside the frame asserted) |
| S10 | hostile text and title rendered literally; exact bytes out | PASS | PASS |
| S11 | kill the CLI → no orphan; Ctrl+C → 130 | PASS | PASS (real `CTRL_C_EVENT`) |
| S13 | two concurrent CLIs, outputs isolated | PASS | PASS |
| view | `view` + Close → 0, empty stdout | PASS | PASS |
| S15 | **slow user**: 9 s idle with `--rpc-timeout 3 --liveness-interval 1`, liveness probes answered, then Submit → result | PASS | PASS |
| S15 | **title bar held for 8 s** (native modal move loop): probes still answered, no false hang | not applicable (KWin moves windows) | PASS |
| S15 | **sizing border held for 8 s** with `--rpc-timeout 3 --liveness-interval 1` (interactive resize in progress), then Submit → result, no false hang | PASS | PASS (native modal size loop) |
| S15 | **native file dialog left open for 8 s**, dismissed, then Submit → form delivered, no false hang | PASS | PASS |
| S16 | **host frozen while the window is open** → `error[host.unresponsive]`, exit 1, window and (Linux) unit gone | PASS | PASS |
| S16 | **only the host's event-loop thread frozen (ptrace), then the CLI SIGKILLed**: the host and its unit end by themselves (Core's launcher-loss watchdog, NHK-CROSS-0001) | PASS (6 s) | not applicable (the host is in the CLI's kill-on-close job) |
| S17 | **`--timeout`** with a row selected but not submitted → 124, empty stdout, window closed | PASS | PASS |
| S18 | **trace diagnostics**: rejected then accepted Submit visible with request ids and durations; launcher and backend share the caller's session id; no sentinel and no 64-hex string on stderr | PASS | PASS |
| S18 | host records carry the same id (`diagnostic_session_id`); each `document.command` request id of the CLI appears host-side as `rpc.received` and `rpc.completed` | PASS | PASS |
| suite | pre-flight (no foreign NativeHTMLKit window), `suite-cleanup` (none of the suite's processes left), `suite-complete` | PASS | PASS |

Cases S15–S18, the keyboard-only Submit, the vertical-shrink case and the suite rows are new in
this version. Frame-sequence recordings of open → resize → scroll → submit on both platforms
(made with the pre-review archives; true video is BLOCKED, no encoder in the lab) are in
`final/recordings/` with `recordings.json`.

## Runs that are not evidence

Kept with a note each, under the evidence directory:

- `final2/windows-run1-superseded/` (64 PASS, one FAIL in the then-new vertical-shrink case: the
  window had been cascaded below the screen edge and the button lay under the taskbar; the case
  now places the window on screen first) and `final2/linux-run1-superseded/` (67 PASS; rerun only
  so that both platforms are recorded for one source tree).
- `final/`: 119 PASS against the same hosts for CLI tree `0fe47c95`, superseded by the fixes for
  the independent final review; and inside it `windows-run1-superseded/` (resize case grabbing
  an off-screen border) and `linux-run1-superseded/`.
- Development-host checkpoint: `windows-run1-superseded/` (two test-side failures) and
  `linux-run2-contaminated/` (another agent's window over the CLI windows on the shared desktop).
  Since then the harnesses refuse to start while a foreign NativeHTMLKit window is open
  (`suite-preflight` BLOCKED), count and remove only their own processes, and clean up after a
  failed case, at the end and on abort.

## Review, mutations, defects

`verification/2026-11-15-sdk/cli/REVIEW.md` holds the source review against the whole
engineering-review catalog, the reproduction of each defect on the pre-fix binary, the 21 + 9
deliberate mutations (all killed) and the status of every finding of the independent final
review (FR-R ids). Fixed in 0.1.1:

- unbounded protocol reads (A04) and no host-hang watchdog (A05);
- failure text quoting host frames; `--diagnostics` without CLI records;
- unbounded `--css`/`--html` read and unbounded `doctor`;
- SIGTERM/SIGHUP without cleanup, slow, and reported as 130 (now 143 / 129, immediate);
- output order depending on the host; impossible selections shown instead of failing;
- host that never exits after a finished session; form fragment without `nhk-form`;
- backend failure cause lost when the host kills the backend first (FR-R-01);
- inputs inside the documented limits refused by the host after the window opened (FR-R-02/03);
- slow-but-answering host killed as unresponsive (FR-R-09); host left running if lifetime
  binding fails (FR-R-11); queued notifications bounded only by count (FR-R-16);
- buttons leaving the window after a vertical shrink (CLI layout; Core NHK-CROSS-0005);
- packaging: unpinned host, no licence texts, non-deterministic archive with the local account
  name, local paths in the binary, unverified Core release directory, weak publish gates.

## Known limitations

- **Core, Linux (NHK-CROSS-0001):** fixed in Core 1.0.2 for a host whose event loop is blocked
  (verified above, S16). A host whose whole process is stopped (SIGSTOP) runs no watchdog; the
  CLI kills such a host itself while the CLI is alive (S16), and if the CLI is SIGKILLed at the
  same time the window, the unit and the backend stay until removed by hand. Accepted by Core.
- A hung host is noticed late by design: a liveness probe is allowed twice `--rpc-timeout`
  (65 s after the host stops answering with the defaults), because ending a healthy but busy
  session would discard the user's input. No false hang was observed with a title bar or sizing
  border held, or a native file dialog open, for 8 s at a 3 s deadline on either platform.
- With `--liveness-interval 0` a host that hangs while idle is only noticed at the next request.
- **Core (NHK-CROSS-0006):** a new window briefly shows the host's placeholder page before the
  document appears (seen on Linux). Not avoidable in the CLI: hidden windows are refused on
  Wayland. **Core (NHK-CROSS-0005):** viewport-height units are not re-resolved on resize; the
  CLI's own page no longer uses them, but trusted `--css`/`--html` that does is affected.
- `--publish` was never executed; its gates after "clean commit" (tag, existing release) are
  untested. A real Windows job-object failure (FR-R-11) was injected in a unit test, not provoked.
- Failures are fail-closed: after a recorded failure (including a host that will not exit after
  the session ended) no result is written even if one had been captured.
- A request that races with the host shutting down (for example Submit clicked and the window
  closed in the same instant) ends as an error (exit 1), not as Cancel. Not reproduced by a test.
- On Windows the GUI suite runs as a scheduled task in the desktop session; if the SSH side that
  started it dies, the task runs to its end without the desktop lock.
- Not qualified: IME composition, DPI scaling above 100 %, multi-monitor, screen readers, real
  suspend/resume, PowerShell object pipelines beyond `ConvertTo-Json` text. The Linux harness
  depends on a 1280×800 screen and KWin's default window placement.
- Cosmetic: `view`/`form` pages show a small page-level overflow scrollbar (both platforms).

## Rerun

```bash
# <host path> is the executable inside an unpacked Core release directory (the packager
# copies that release's licence files and checks its release-manifest.json against the pin).
# Linux: gates + real host + package on this machine, GUI on the Wayland session machine
NHK_LAB_GUI_LOCK=<lock file> scripts/lab/qualify-linux.sh <host path> <host version> <host sha256> <evidence dir>

# Windows: source copied to the build VM, gates + real host + package there, GUI in its desktop session
NHK_LAB_WINDOWS_INTERACTIVE=<start_interactive.ps1 on the VM> NHK_LAB_WINDOWS_PYTHON=<python.exe> \
NHK_LAB_WINDOWS_EXTRA_PATH=<directory with cargo-deny.exe> \
NHK_LAB_GUI_LOCK=<lock file> scripts/lab/qualify-windows.sh <host path on Windows> <host version> <host sha256> <evidence dir>

python3 scripts/qualify.py merge --out <evidence dir>/results.json <evidence dir>/linux/results.json <evidence dir>/windows/results.json
```

Without the lab: `python3 scripts/qualify.py run --host … --host-version … --host-sha256 …
--evidence …` runs every non-GUI gate and packaging on the current machine.
