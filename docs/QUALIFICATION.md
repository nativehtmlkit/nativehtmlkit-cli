# CLI qualification

## v0.1.2 against Core 1.0.3 (2026-11-16)

**Status: released as the full release
[v0.1.2](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.2)**, built
from the clean commit `5d2c727b63de54331431995ab4d6c164ea12b0c9` (source tree hash
`13646c2ab2a87b958c9a20730810e7254dfc9a0b06f340ad4eab691f8644f646`) and qualified from the two
release archives against their bundled Core 1.0.3 hosts:
**138 records, 138 PASS, 0 FAIL, 0 BLOCKED**.

| | Linux x86-64 | Windows x86-64 |
|---|---|---|
| Platform | Debian 13 workstation (non-GUI gates); KDE Plasma 6.6.6 native Wayland on Ubuntu 26.04 (GUI) | Windows Server 2022 (non-GUI gates over SSH; GUI on an interactive desktop) |
| Toolchain | rustc 1.99.1 | rustc 1.100.0 |
| CLI executable | `5bd01e05fc26ddce08ae9b4b7f9b3bcaef7b149370198d9c9d74394d180cff9f` | `b578177b78af10db0f4a6586d7f525fff2d04b103de3c339e09ada86ab07f73c` |
| Bundled Core host 1.0.3 | `1cd4e9de701f3ef8d8b870b678765243f2365d69d7352c0543f171ff249c999f` | `15967208d2e20d208d69b97bba6f397056e28c57add126909a8734361ae8f8c8` |
| Archive | `nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz` `7c55d7c346cb70db0a24e0f2795f4896fd0a36021b3815209e7e68e1f6496aa2` | `nativehtmlkit-cli-v0.1.2-windows-x64.zip` `e64c9eaeafc15450291c9bf22834dbd2024dd3d7d13657119beb439bc37f92d1` |

| Gate | Linux | Windows |
|---|---|---|
| Source gates: repository boundaries, dependency policy (`cargo deny`), `cargo fmt`, `cargo clippy -D warnings`, release build | 5 PASS | 5 PASS |
| Unit tests (`cargo test --locked --bins`) | 43 passed | 40 passed |
| Scripted-host protocol suite / fault suite | 10 / 30 passed | 10 / 30 passed |
| Launcher end-to-end suite | 32 passed | 27 passed, 5 not applicable (POSIX signals, `/dev/full`, procfs) |
| Real host, headless: `doctor`; handshake, liveness and `--timeout` -> 124; session-id correlation with host records; document limits (1870 x 16 accepted, 1871 x 16, 2000 x 32 and a 1.2 MB page refused before any host start); backend failure cause reported; trace privacy sentinel; frozen host detected and killed; killed host reported as an error | 8 PASS | 8 PASS |
| Host pin, publish-gate simulation, packaging with clean extraction and bundled-host session | 3 PASS | 3 PASS |
| GUI suite from the extracted archive, real input (`tests/gui/`) | 49/49 PASS | 49/49 PASS |
| **Total** | **69 PASS** | **69 PASS** |

GUI cases (each asserts exact stdout bytes, exit status and no leftover processes): single
and multi-select, input order independent of click order, Cancel and title-bar close (2),
empty-Submit message then success, invalid JSON / ragged CSV / empty input / invalid UTF-8 /
unknown flag (1), 2,000 rows open and scroll, 2,001 rows and over 8 MiB refused, JSON types and
Unicode preserved, NDJSON multi-select, CSV re-quoting, TSV output, `lines` refusing
newlines, hostile text rendered literally, `view` + Close, `form` with required-field error,
typed text and checkbox, keyboard-only selection and Submit, resize with the footer kept in
view (also with `vh`-based user CSS), killed CLI leaves no orphan, Ctrl+C (130), two
concurrent windows, a slow user with liveness probes, held title bar / sizing border and an
open native file dialog without a false hang, hung host reported as `host.unresponsive`,
`--timeout` (124), trace privacy and correlation.

## Documentation examples (2026-11-16)

The examples in [examples/](../examples/README.md) and the statements of the
[reference](REFERENCE.md) about input parsing, limits, option validation, exit statuses and
stderr lines were verified against the released archives, headless
(`NATIVEHTMLKIT_CLI_TEST_HEADLESS=1`), with recorded-result replay for the scripts' handling
of a submitted result:

| Harness | Environment | Result |
|---|---|---|
| `scripts/test-examples.sh --cli <linux archive>/nativehtmlkit` | Debian 13, bash 5.2, jq 1.7 | 223 PASS, 0 FAIL, 0 SKIP |
| `pwsh -File scripts/test-examples.ps1 -Cli <linux archive>/nativehtmlkit` | PowerShell 7.7 on Debian 13 | 66 PASS, 0 FAIL, 3 SKIP (Windows-only cases) |
| `powershell.exe -File scripts\test-examples.ps1 -Cli <windows archive>\nativehtmlkit.exe -Shell powershell.exe` | Windows PowerShell 5.1 on Windows Server 2022, over SSH (no desktop) | 76 PASS, 0 FAIL, 0 SKIP |

`cargo test --locked` on the same Linux workstation at the documentation commit: 43 + 30 + 10
+ 32 passed (source unchanged since the release).

These harnesses do not click; GUI behaviour is covered by the release qualification above.

## Known limitations

As published in the [v0.1.2 release notes](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.2):

- Hang detection is deliberately slow: a liveness probe is allowed twice `--rpc-timeout`, so
  with the defaults a hung host is reported about 65 s after it stops answering. With
  `--liveness-interval 0` a hang is only noticed at the next request.
- Stopped host (SIGSTOP): if the host process is stopped as a whole and the CLI is killed at
  the same time, the window, its systemd unit and the backend remain until removed by hand.
- Core defect NHK-CROSS-0010: the Orca screen reader does not announce value changes of a
  collapsed drop-down (`<select>`), which affects `form` pages that use one.
- Failures are fail-closed: after a recorded failure no result is written, even if one had
  been captured.
- The Submit/close collision is tested with a scripted host only.
- Not qualified: mixed per-monitor scale factors on Windows and DPI scaling above 100 %,
  multi-monitor set-ups, real suspend/resume, IME composition, screen-reader journeys,
  PowerShell object pipelines beyond `ConvertTo-Json` text.

## Earlier versions

v0.1.1 (Core 1.0.2, prerelease, 2026-11-15) and v0.1.0 (Core 1.0.1) were qualified
separately; their results are not inherited by v0.1.2. See their
[release notes](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases).
