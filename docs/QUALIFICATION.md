# CLI native qualification — results 2026-11-15

Binaries under test were taken **from clean extractions of the release archives** (S14), not from
`target/`. Every case asserts exact stdout bytes, exit status and that no `nativehtmlkit`/`nhk`/
`nativehtmlkit-host` process (and on Linux no `nativehtmlkit-host-*` systemd unit) remains.
Input was injected as real OS input; UI Automation on Windows was used only to locate elements.

| Item | Linux | Windows |
|---|---|---|
| Session | KDE Plasma 6.6.6 native Wayland, Ubuntu 26.04 (lab VM `linuxDEV`), ydotool/uinput, spectacle | Windows Server 2022, interactive RDP desktop of dedicated user `nhk_gui` (winDEV), SendInput, `CopyFromScreen` |
| CLI source | `9ec8b606` | `9ec8b606` |
| Archive | `nativehtmlkit-cli-v0.1.0-linux-x64.tar.gz` sha256 `69748bc5…ef21` | `nativehtmlkit-cli-v0.1.0-windows-x64.zip` sha256 `eb105663…621f` |
| CLI binary | `58903946…b4c9` | `9b7a5376…9d38` |
| Bundled Core host 1.0.1 | `e7b82986…1a3a` (Core `a1a78c8`) | `32930fba…f04c` (Core `a1a78c8`) |
| Harness | `tests/gui/linux-kde-wayland.sh` | `tests/gui/windows-interactive.ps1` |
| Result | **28/28 PASS** | **24/24 PASS** |

| ID | Scenario | Linux | Windows |
|---|---|---|---|
| S01 | `nhk select --multi` opens a real native window | PASS | PASS |
| S02 | click row 2 + Submit → stdout exactly `beta\n`; two rows → document order; single-select radio | PASS | PASS |
| S03 | Cancel → exit 2, empty stdout; title-bar close → exit 2; empty Submit shows in-window error then succeeds | PASS | PASS |
| S04 | invalid JSON, ragged CSV, empty input, invalid UTF-8, unknown flag → exit 1, empty stdout | PASS | PASS |
| S05 | 2,000 rows open and scroll; 2,001 rows and > 8 MiB → exit 1 | PASS | PASS (8 MiB case Linux only) |
| S06 | JSON types, key order and Unicode preserved; NDJSON multi-select | PASS | PASS (JSON) |
| S07 | CSV re-quoting (comma, quotes, embedded newline), TSV output, `lines` refuses newline values | PASS | PASS (CSV) |
| S08 | form: required validation error, typed text, checkbox → exact `{"entries":[…]}` (Unicode typed on Windows) | PASS | PASS |
| S09 | keyboard selection (Space/Tab); live window resize with re-layout | PASS (resize verified by screenshot + GIF) | PASS (frame 916×649 → 661×499 asserted) |
| S10 | `<script>`, tags, quotes, Czech, CJK, emoji, Hebrew rendered as text; exact bytes out; hostile `--title` | PASS | PASS |
| S11 | kill CLI (SIGKILL / TerminateProcess) → no orphan host/backend/unit; Ctrl+C → exit 130 | PASS | PASS (real `CTRL_C_EVENT`) |
| S12 | handshake/version failures fail closed | covered by fake-host test + Core golden (`auth.*`) | Core golden on Windows |
| S13 | two concurrent CLIs, outputs isolated | PASS | PASS |
| S14 | packaged binaries from clean extraction | PASS | PASS |
| — | `view` + Close → exit 0, empty stdout | PASS | PASS |

Recordings (frame sequences of real screenshots, Linux): resize and 2,000-row scroll GIFs.
Evidence and gallery: `nativehtmlkit-project/verification/2026-11-15-core-cli/index.html` (local,
not committed).

## Defects found and fixed during qualification

| Defect | Found by | Fix |
|---|---|---|
| SIGKILLed/terminated CLI left an orphaned window holding the piped data | S11 | host bound to CLI lifetime (PDEATHSIG / Job Object) |
| Session directory created `0775` (umask) — piped data readable by other local users | unit test | explicit `0700`; `session.json` deleted after read |
| clap usage errors exited 2 (= "cancelled") | review | usage errors exit 1 |
| JSON/NDJSON object keys re-sorted; big numbers re-formatted | S06 | `preserve_order` + `arbitrary_precision` |

## Not qualified (BLOCKED / not run)

- **IME** composition (Linux: fcitx5 present but KWin only loads an input method at session start;
  enabling needs a Plasma session restart on the shared VM. Windows: no IME installed).
- DPI/scale factors above 100 %, multi-monitor, screen-reader journeys.
- PowerShell object pipelines into `nhk` beyond `ConvertTo-Json` text.
- Cosmetic: `view`/`form` pages show a small page-level overflow scrollbar (both platforms).
- The fake-host integration test is Unix-only; Windows protocol coverage comes from the real host.
