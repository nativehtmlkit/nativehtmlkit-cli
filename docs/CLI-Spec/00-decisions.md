# Decisions and constraints — proposed baseline

## Priority zero: protect the existing architecture

1. **Core stays Rust-only in product API ownership.** Keep its five internal crates, native host, local authenticated protocol, and platform supervision. Build tooling written in Python is fine inside a Rust repository; publishing Python/PowerShell SDKs there is not the desired destination.
2. **CLI is the first independent consumer.** Implement it from day one in the separate `nativehtmlkit-cli` Git repository. Use the same released Core host with a pinned protocol/artifact contract; do not require Python or PowerShell at runtime.
3. **Do not fork the renderer.** `nhk` must use the exact same host artifact and protocol that eventual Python and PowerShell packages consume.
4. **No breaking host-protocol change for v0.1.** The first CLI backend is a normal app with `host.hello`, `window.create`, `document.load`, `app.ready`, event notifications, `document.command`, and close/quit handling.
5. **Two `nhk` execution roles:** launcher (owns stdin and stdout) and backend (has authenticated IPC; owns GUI business logic). The existing host is a third process.
6. **Explicitly distinguish cancellation, empty selection and errors.** No stdout on any cancellation or pre-commit failure. A submit with zero rows is invalid unless `--allow-empty` is supplied.
7. **No network, JavaScript, Chromium, local HTTP server, or plugin runtime.** Keep the CLI honest to the native engine.
8. **Screen-mode vs data-mode separation.** Ordinary `nhk select/view/form` runs are interactive local-desktop operations. Reject noninteractive sessions clearly; never open invisible windows or silently fall back to terminal prompts.

## First acceptance target

```sh
printf 'alpha\nbeta\ngamma\n' | nhk select --multi
```

Select `alpha` and `gamma`, Submit: stdout `alpha\ngamma\n`, status 0. Cancel/close/Escape: stdout empty, status 10. Failure: stdout empty, nonzero diagnostic status. Host and backend leave no orphan processes.

## Rust CLI distribution

- `nativehtmlkit` is the **canonical executable name**; `nhk` is an installed short alias to the same implementation. Verify distribution/command-name conflicts before release.
- Release **matching Core/CLI pairs** first. Versioned SDKs can later have independent versions with pinned `host_build_id` and `protocol_version`.
- Linux: currently qualified host baseline is x86-64 Wayland, glibc >= 2.34, systemd user bus; Windows: x64 interactive Desktop Experience, not Server Core/SSH noninteractive GUI.

## Phased functionality

| Stage | Included | Explicitly deferred |
|---|---|---|
| P0: contract harness | `--help`, `--version`, parsers, stdout/exit invariants, fixture validation, mock backend | GUI |
| P1: first GUI | `select`, text lines, single/multi, keyboard, Cancel/Submit, process cleanup | CSV, forms, custom HTML |
| P2: useful CLI | `view`, CSV/TSV/JSON/NDJSON, search, pagination, output formats | unbounded streams |
| P3: forms | `input`, `confirm`, declarative `form`, labels/validation, JSON result | arbitrary JS-like binding |
| P4: advanced UI | opt-in custom trusted HTML/CSS and forms, schema-driven layout, protocol compatibility | MCP server, remote UI, true live streaming |

## Gates for splitting Python and PowerShell

The Core+CLI must publish reproducible native executable artifacts and an explicit compatibility manifest. Python and PowerShell must then consume **Core artifacts directly**, not the Python wheels as today. Preserve old UI4ME 1.0.1 releases and provide deliberate package/API migration rather than republishing or breaking them.
