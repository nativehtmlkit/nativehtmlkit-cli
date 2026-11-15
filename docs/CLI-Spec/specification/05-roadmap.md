# Development roadmap and autonomous-agent work packages

## Ordering and parallelism

Proceed sequentially on contract/integration dependencies, parallelize independent test fixtures and documentation only. **No concurrent edits to the host protocol and CLI protocol client without a shared contract gate.**

| Work ID | Scope | Dependency | Completion gate |
|---|---|---|---|
| NHK-001 | Clone/freeze baseline, record commit and release artifact hashes | none | repository inventory and tests untouched |
| NHK-002 | Separate native Core build/release ownership, preserve v1 protocol | 001 | Linux/Windows host artifacts runnable and qualified |
| NHK-003 | CLI argument parser, error taxonomy, data model and fixture schemas | 001 | unit/property tests |
| NHK-004 | Standalone host artifact locator + compatibility checks | 002,003 | doctor works on both platforms |
| NHK-005 | Private per-run session dir + bounded stdin staging | 003 | OS temp ACL tests, malformed-input tests |
| NHK-006 | Rust protocol-v1 client with host request/notification handling | 002,003 | mock-host conformance + real host headless |
| NHK-007 | Selection UI generated HTML/CSS and stable row state | 005,006 | real host headless window/document events |
| NHK-008 | Atomic Submit/Cancel receipt + launcher stdout writer | 005,007 | no output on cancel or failure; exact rows |
| NHK-009 | Native Linux Wayland E2E acceptance | 008 | all P1 native Linux cases |
| NHK-010 | Native Windows Desktop E2E acceptance | 008 | all P1 native Windows cases |
| NHK-011 | P1 binary packaging and release qualifications | 009,010 | clean installed CLI+host artifacts |
| NHK-012 | P2 CSV/TSV/JSON/NDJSON, view, search and pagination | 011 | structured data corpus, both platforms |
| NHK-013 | P3 input/confirm/declarative forms | 012 | form-schema tests, keyboard and validity |
| NHK-014 | P4 optional trusted HTML/CSS forms | 013 | custom template security and correctness |
| NHK-015 | Extract CLI repo after artifacts+contract stable (optional) | 011 | cross-repo CI green and pinned host artifacts |
| NHK-016 | Extract Python SDK from existing core | 002,011 | same host pinned and Python E2E green |
| NHK-017 | Extract PowerShell SDK from existing core | 002,011 | no Python wheel dependency; PS 5.1/7 green |

The user-requested migration order is Core→CLI→Python→PowerShell. Items 012–014 (advanced CLI) need not block Python/PowerShell if the initial CLI has already proven independent host packaging and protocol compatibility. Avoid delaying SDK migration for unrelated CLI features.

## Detailed P1 acceptance gates

**Gate A: source health** — existing Rust engine tests remain green; patch only demonstrably necessary Core behavior; no removal of old published artifacts.

**Gate B: protocol** — Rust `nhk` backend authenticates to Core and responds correctly to `window.before_close`, `app.before_quit`, and `app.shutdown`; no Python or PowerShell involved.

**Gate C: shell semantics** — `nhk select --multi` emits exactly selected rows on Submit, zero stdout on Cancel or failure; process return status correct, including Ctrl+C and stdout pipe closure.

**Gate D: native Linux** — KDE Wayland real window, pointer/keyboard actions, accessible controls, clean session teardown, artifact-accurate tests.

**Gate E: native Windows** — Windows Server 2022 Desktop Experience interactive window, UIA/keyboard tests, Job Object/process cleanup, artifact-accurate tests.

**Gate F: distribution** — both binaries install side-by-side without Rust/Python/PowerShell; checksum/pinning and license manifests recorded.

## Work-product policy for implementation agent

- Inspect source before edits; explicitly map changed files and dependencies.
- Work autonomously until current gate passes; do not turn experimental observations into release claims.
- Prefer minimal host modifications; never fork renderer or implement UI in native OS widgets outside Core.
- Keep test records and screenshots in a verification directory but don't commit sensitive data/large temporary artifacts.
- Commit after each passing gate with clear summaries, then proceed.
- No publication, repository rename or destructive removal without explicit release authorization.
