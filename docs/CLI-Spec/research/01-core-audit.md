# Evidence-based current Core audit

Source: `https://github.com/ui4me/ui4me-core` at reviewed `main` commit `c6fd71dc5c15dcdfdcdc1500dc156c1b929c216c`, dated 2026-11-14 (verify again before migration). Findings below describe source, **not freshly executed acceptance tests**.

## Real architecture

- Rust workspace crates: `ui4me-host`, `ui4me-renderer`, `ui4me-document`, `ui4me-assets`, `ui4me-engine-types`.
- Host is a native executable with `run --app`, `probe`, `render --html --output`, and `doctor`; there is **no interactive selection CLI** today.
- Backend runs as a **separate supervised process**. Transport is framed JSON-RPC 2.0 subset over Unix domain socket (Linux) / restricted named pipe (Windows). `host.hello` authenticates with an ephemeral token and checks `protocol_version = 1`.
- Host-to-backend notifications and requests are asynchronous. Host sends `window.before_close` and `app.before_quit` and requires prompt responses. Message size is max 2 MiB; HTML document load max 1 MiB.
- Host launches a configured backend described by `app.toml`; Python and PowerShell direct startup use a two-role launcher/backend pattern already. The new Rust CLI should follow this pattern.
- Native host captures backend **stdout/stderr as bounded logs** in `crates/ui4me-host/src/backend.rs`. These are not a reliable result transport. The logger can drop output. No business data may traverse this channel.

## Existing primitives usable without changing Core

| CLI requirement | Existing primitive | Evidence | Confidence |
|---|---|---|---|
| Create native window | `window.create` | `docs/reference/protocol.md` | Implemented |
| Load HTML/CSS | `document.load`, CSS from local files | protocol and HTML/CSS scope docs | Implemented |
| Update document | `document.command` (`set_text`, `set_attribute`, `replace_children_html`, batch) | protocol | Implemented |
| Selection UI | `<input type=checkbox/radio>`, `<select multiple>`, native click and key events | HTML/CSS scope docs | Building blocks exist; custom table selection needed |
| Text viewer | Scrollable blocks, text selection, copy, CSS | HTML/CSS scope docs | Building blocks exist |
| Forms | `<form>`, `submit`, `get_form_data`, constraint validation | HTML/CSS scope docs | Implemented primitives |
| Custom local files | `document.load path`, `asset_root` | protocol and resource restrictions | Implemented primitives |
| Basic accessibility | HTML and ARIA → AT-SPI/UIA via AccessKit | capability docs | Implemented; CLI UX still needs qualification |
| Date/time picker | `<input type=date/time/...>` | explicitly rejected in HTML/CSS scope | **Not available** |
| Unlimited/virtualized table widget | not a built-in table data model | no documented native data grid/virtualization | **CLI implements paging; don't assume virtualization** |
| Data stdout | backend output captured as logs | backend.rs/logging.rs | **Must be new in CLI launcher** |
| Background notifications/MCP | not CLI functionality | no CLI adapter | Future, not v0.1 |

## Constraints to respect

- `document.load` HTML limit **1 MiB**, IPC frame limit **2 MiB**. Do not render an unbounded table in one HTML fragment; cap to a page and use incremental replacements.
- Core validates manifest paths and rejects reserved transport env overrides; use normal manifest loading, not an unauthenticated direct socket connection.
- Linux host only supports native Wayland in existing qualified profile; X11 not supported. `systemd-run --user` supervision and an active user D-Bus session are involved.
- Windows needs an actual interactive Desktop session (the source cites Windows Server 2022 Desktop Experience interactive RDP). Remote SSH does not itself create such a desktop.
- Core rejects JS/inline handlers, `http(s)` resource fetching, and contenteditable. It supports ordinary semantic tables, forms, CSS grid/flex, dialog, and markup changes.
- File input and file dialogs have platform dependencies; do not use them in MVP.

## Present release coupling to fix as part of migration

- Current `setup.py` compiles the Rust host and bundles it in platform-tagged Python wheels.
- Current PowerShell publish workflow downloads **Python release wheels**, verifies their hashes, then extracts host executables into a Python-independent PowerShell module.
- Current release verifier checks all Rust/Python/PowerShell versions as exactly 1.0.1.
- Desired Core release flow should publish platform binaries and metadata **independently of either language SDK**. The CLI should use the Core artifacts first, making downstream package extraction simple and uniform.

## Useful source paths

- `crates/ui4me-host/src/main.rs`
- `crates/ui4me-host/src/backend.rs`
- `crates/ui4me-host/src/logging.rs`
- `crates/ui4me-host/src/host/mod.rs`
- `crates/ui4me-host/src/host/requests.rs`
- `crates/ui4me-host/src/host/documents.rs`
- `crates/ui4me-host/src/host/document_commands.rs`
- `crates/ui4me-host/src/protocol.rs`
- `crates/ui4me-host/src/config.rs`
- `docs/reference/protocol.md`
- `docs/concepts/architecture.md`
- `docs/concepts/html-css-scope.md`
- `docs/guides/platforms.md`
- `tools/release/build_psgallery.py`
- `.github/workflows/publish.yaml`
- `.github/workflows/publish-powershell.yaml`
