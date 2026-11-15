# Implementation prompt — NativeHTMLKit CLI (current decisions)

You are implementing a Rust CLI in the **independent repository** `nativehtmlkit-project/repositories/nativehtmlkit-cli`, after NativeHTMLKit Core has been extracted and its host artifact/contract qualified. Read Project `AGENTS.md`, `MIGRATION-HANDOFF.md`, and `agents/shared.md`, then this repository's `AGENTS.md`, then the CLI research `README.md`, `00-decisions.md`, architecture, specification, and IDL. If cloned alone, use the repo-local `AGENTS.md` and treat unprovided Project instructions as unavailable rather than guessed.

**Do not follow the earlier proposal to add CLI inside Core's Cargo workspace.** That plan was superseded by the decided separate repository architecture. Do not add private Core crates as path dependencies. For local development only, run against an explicitly selected Core host executable; for release, consume a versioned SHA-256-verified qualified Core release with its tested wire contract.

## Goal and first acceptance gate

Ship a Rust console executable `nativehtmlkit`, with the short alias `nhk`. Implement a shell-facing launcher and a host-started backend. Use Core's existing authenticated local JSON-RPC and native HTML/CSS host. First acceptance: `printf 'alpha\nbeta\ngamma\n' | nhk select --multi` opens a native window, selects lines by mouse/keyboard and returns exact original selected records on Submit. Cancel emits **no** stdout and a distinct exit code; crash, broken pipe, Ctrl+C and close leave no orphaned processes. Qualify on Linux KDE Wayland and interactive Windows Desktop Experience.

## Execution sequence

1. Confirm Core artifact, host SHA, protocol version, capabilities and source commit. If Core is still a placeholder or contract is unqualified, **report the prerequisite** rather than silently rebuilding from its source tree or importing it from Python wheels.
2. Build separate CLI `Cargo.toml`, Rust source and tests in **this** repository. Keep Core internals out. Canonical CLI naming `nativehtmlkit`, alias `nhk`; no mandatory Python, PowerShell, Node, browser, HTTP server or daemon.
3. Implement bounded stdin snapshots and stable selection record IDs. Generate trusted HTML/CSS markup and properly escape untrusted input text. Backend must send a private validated/atomic completion receipt to the launcher; the launcher alone writes pipeline results to stdout, never via Core's bounded diagnostics.
4. Implement correct request/response/callback and shutdown semantics using Core's released protocol. Verify hostile/malformed data, forged receipts, cancellation races, double Submit, no partial output, Unicode and bounded memory.
5. Run unit/property and mock protocol tests, real host headless tests, then native GUI acceptance on both OS targets. An SSH session alone is not Windows GUI proof. Preserve logs, exact commands, exit statuses, SHA-256, source commits and qualification evidence.
6. **If Core is broken or lacks a required operation, do not patch Core from the CLI task.** Capture minimal reproduction, version, observed/expected outcome and workaround in Project `docs/bugs/bug_list.md` and create a Core-owned follow-up task. Do not relax assertions to pass.
7. Follow the staged CLI `specification/05-roadmap.md` for further formats, forms and viewers only after first proof passes. Update local docs, IDL, examples and tests together. Treat proposed schemas as candidates until tested.
8. GitHub Actions in every repository **must be manual `workflow_dispatch` only**. Test locally autonomously, but do not publish, tag, force-push, modify repository visibility or trigger workflows without explicit user authorization.

Report a per-gate table with CLI commit, Core host artifact SHA, protocol version, Linux and Windows results, missing capabilities and next gate. Do not claim functionality exists in the initial research/placeholder state.
