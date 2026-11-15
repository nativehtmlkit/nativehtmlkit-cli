# Security, privacy, safety and failure boundaries

## Threats

The CLI handles arbitrary shell output, potentially malicious text, malformed JSON/CSV, local file paths, and interactive values. The CLI is **not** a sandbox: it runs with user permissions. Default to bounded, local, non-network, non-executable behavior.

| Risk | Required control | Acceptance evidence |
|---|---|---|
| Untrusted text becomes active markup | HTML-escape all dataset values; use native `set_text`/`set_value` for updates; never concatenate untrusted string into trusted HTML | HTML injection corpus with `<script>`, tags, ampersands, style escapes |
| Path traversal through custom local CSS/images | Core `asset_root` checks, canonicalize path, reject symlink escape | Path corpus with symlinks, `../` and UNC cases |
| World-readable stage/result | Mode 0700 dir / 0600 files on Unix; explicit user-only DACL on Windows; O_NOFOLLOW or equivalent | Inspect filesystem ACLs in both platforms |
| Symlink/reparse-point replacement | exclusive create, randomized session, no following links, same-directory atomic rename; check ownership/identity | Race tests / malicious temp dir entry |
| Oversize/malicious input | hard byte and row caps, strict UTF-8, bounded parser, limit HTML/UI page bytes and IPC frames | fuzz + max tests; no unbounded allocations |
| Result injection or data corruption | random per-session nonce, receipt schema validation, range-check row indices, duplicate-check, atomic commit, host status check | forge/stale/partial receipt tests |
| Race double-Submit | idempotent state transitions: first valid commit wins; disable Submit immediately | double-click and concurrent event tests |
| Backend invoked directly without host | internal mode requires valid `UI4ME_ENDPOINT`, `UI4ME_TOKEN`, and session identity; never launches host recursively | direct invocation failure test |
| Secret leakage | no tokens in args, stdout, logs or temp manifest; redact diagnostic values; clean temp files | log scan, process argv scan |
| CSV formula injection downstream | CLI keeps row values unchanged by default; document spreadsheet risk; optional future spreadsheet-safe explicit output mode rather than silently changing values | export examples, OWASP risk note |
| Accessibility/focus spoof | semantic markup, clear labels, native focus, no external navigation | AT-SPI / UIA screen reader checks |
| GUI invoked from elevated service | no automatic interactive desktop bridging, fail with explicit status | headless/service tests |
| External command execution from received data | No `--exec` / actions that evaluate piped text | grep for unsupported execution surfaces and malicious fixtures |

## Limits: proposed initial defaults, subject to measurement

- Input snapshot **4 MiB** after reading; cap **2,000 records**, **24 columns** for table data, and **64 KiB/record**. Reject overlimit as exit 5 with actionable stderr.
- Display **50 rows/page**; truncate individual *display labels only* to **512 UTF-8 bytes at code point boundary**, while preserving original row values for stdout. Never truncate result data silently.
- Generated HTML load **< 1 MiB** (existing Core limit); result RPC **< 2 MiB** (existing Core limit). `document.command` batch max 1024 operations (existing Core).
- Default no network, no remote resources, no shell interpolation, no `eval`, no JS.
- Input size and record counts are initial product caps, not Core limitations. Version them in docs, benchmark before raising.

## Logging and stdout invariant

- Only the launcher touches original stdout; no banner, warning, spinner, host log or progress line is allowed there for interactive commands.
- Diagnostics go to stderr and should not contain input values by default. `--verbose` opts into more diagnostic events but **never credentials or full dataset**.
- `nhk --help` and `nhk --version` may print ordinary help/version text to stdout; this is not data-command behavior.
- Stderr should be useful in noninteractive scripts. Every failure must have a documented exit code.

## Sensitive form values

Passwords and tokens are not a primary v0.1 use case. For later `form` with password controls, mark fields as sensitive and require explicit user acknowledgement if sending secrets to stdout. Local receipt storage must use appropriate controls, but no local ephemeral file can protect secrets from every same-user privileged process. Avoid offering false confidentiality guarantees.

## Filesystem and process cleanup

Write temporary manifests under a private session root. Use RAII cleanup and OS process lifetime controls, but also test SIGTERM, SIGKILL, crashed host, and forced quit. On next startup sweep only **owned, proven-nativehtmlkit stale session directories**, never arbitrary `/tmp` directories; keep a maximum age. Do not follow symlinks during cleanup. On Windows use Job Objects to prevent orphaned process trees, and handle ConsoleCtrl events without detaching the launcher console.
