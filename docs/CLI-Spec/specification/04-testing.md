# Acceptance, qualification and release gates

## Test pyramid

1. **Pure Rust unit/property/fuzz:** arguments, format parsers, JSON schema, HTML escaping, record identity, filtered selection, output normalization, status codes, size limits, hash and receipt validation.
2. **Protocol mock conformance:** simulator of framed JSON-RPC v1, host.hello, reverse requests, notifications, rejected frames, concurrent responses, close decisions; no desktop.
3. **Real host headless:** build/pin real Core host; run CLI internal backend and exercise protocol, lifecycle, generated HTML, error injection. Use documented explicit test mode, never count as desktop qualification.
4. **Native interactive Linux:** KDE Plasma Wayland, actual pointer and keyboard, screenshots and AT-SPI, user-session supervision and process tree cleanup.
5. **Native interactive Windows:** Windows Server 2022 Desktop Experience (user's existing Windows VM is suitable after arranging an interactive RDP/session), keyboard, mouse, UI Automation/NVDA, process/job cleanup. SSH alone is not proof of GUI access.
6. **Installed artifacts:** tar/zip deployment of `nhk` + host, no development source, no Python/PowerShell/Node runtime dependencies. Verify all checksums and licensing.

## P1 functional acceptance matrix

| ID | Test | Required result |
|---|---|---|
| CLI-001 | `--help`, `--version` | status 0; no GUI |
| CLI-002 | `doctor` in interactive Linux/Windows | detect host/protocol and actual desktop availability |
| CLI-003 | simple `printf 'alpha\nbeta\ngamma\n' | nhk select` | opens window, one row can be chosen, exact stdout |
| CLI-004 | `--multi` select rows 0 and 2 | `alpha\ngamma\n`, status 0 |
| CLI-005 | Cancel button | 0 stdout bytes, status 10 |
| CLI-006 | Escape | 0 stdout bytes, status 10 |
| CLI-007 | native close button | 0 stdout bytes, status 10 |
| CLI-008 | malformed/invalid CLI flags | status 2, no GUI/data |
| CLI-009 | no interactive desktop | status 3, no UI hang |
| CLI-010 | bad UTF-8/oversize input | status 5, no stdout |
| CLI-011 | host unavailable/protocol mismatch | status 4, actionable stderr |
| CLI-012 | backend crash during interaction | status 4, stdout empty, clean host |
| CLI-013 | double Submit | exactly one committed receipt, no duplicate output |
| CLI-014 | same label in multiple rows | stable unique index selection |
| CLI-015 | search/filter/page navigation | selections persist; stdout original input order |
| CLI-016 | stdout pipeline `| sort`, `| cat` | no banners/logs mixed with data |
| CLI-017 | interrupted launcher / Ctrl+C | no remaining host/backend or temp artifacts |
| CLI-018 | closed downstream pipe | status 6 or documented equivalent, no deadlock |
| CLI-019 | Unicode + CRLF + empty lines | exact selection/data semantics |
| CLI-020 | long display text injection | escaped, bounded, no script or UI corruption |
| CLI-021 | host writes diagnostics | stderr only, stdout clean |
| CLI-022 | forged/partial receipt, symlink swap | reject; no stdout |
| CLI-023 | installed artifact with host pinned | same behavior without Rust/Python/PowerShell |
| CLI-024 | keyboard-only selection, screen-reader smoke | usable controls, focus, correct selected count |
| CLI-025 | concurrent CLI invocations | no session collision or cross-contamination |
| CLI-026 | forced host exit after Submit receipt | fail closed, no stdout; stage cleaned |
| CLI-027 | power loss / SIGKILL stale stage | no stale folder reused; safe owned-only cleanup |
| CLI-028 | hidden internal backend direct invocation | rejects absent host token and stage |

## P2 data-contract tests

- CSV fields with commas, quotes, embedded line breaks and CRLF.
- CSV duplicate headers, inconsistent columns, encoding error.
- JSON array records with repeated labels, numbers, booleans/null, nested values.
- NDJSON valid input, non-object scalars, malformed line with line number, blank-line policy.
- `--columns` display projection cannot remove underlying JSON fields.
- Output `same`, `json`, `ndjson`, `values` contracts; selections across filtered pages.
- Header-only and empty inputs: intentional behavior documented (no selectable records; input error vs allow-empty only as specified).

## P3 forms and P4 custom HTML tests

- Required field, numeric bounds, radio group, checkbox, multiple selection, invalid form does not commit.
- Keyboard navigation and submission; PowerShell UTF-8 end-to-end.
- Custom HTML lacks form id or has malicious `<script>`/inline event: fail cleanly or Core rejects, never execute.
- Asset-root symlinks, local file restrictions and form data text escaping.

## Platform test fixture requirements

- Linux: Wayland env, usable `systemd-run --user`, D-Bus and actual compositor. Include controlled teardown after each test; test Ctrl+C and terminal-close.
- Windows: native interactive logon (Desktop Experience). The orchestration host can stage code via SSH, but actual GUI tests require a process in a logged-on interactive user session. Test both PowerShell 7.x and 5.1 as **CLI callers** later; not runtime requirements.
- Persist immutable evidence: host and CLI commit, artifact SHA256, OS/session, run ID, test ID, result, diagnostic log and optional screenshot. No credentials or sensitive stdin in reports.

## Release gates

- All P1 tests pass on **both** platforms against canonical native release artifacts. No quarantine of failures merely to show green CI.
- Source formatting/Clippy, parser fuzz corpus, dependency/license manifest, binary scan, artifact reproducibility/provenance records.
- No orphan processes after cancel/crash/interrupt and no stderr→stdout leaks in clean-room tests.
- CLI version and Core protocol negotiation explicitly validated; useful failure when incompatible.
- Tagging/publishing is manual after qualification, with immutable release artifacts.
