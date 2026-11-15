# NativeHTMLKit CLI — agent instructions

This is an **independent Rust CLI repository**. It currently holds research/IDL and placeholders, **not a working CLI**.

In the standard workspace read `../../AGENTS.md`, `../../agents/shared.md`, `../../docs/architecture/boundaries.md`, `../../docs/bugs/bug_list.md`, and `../../MIGRATION-HANDOFF.md`. If cloned alone, follow these rules and treat the Project repository as optional local context.

1. CLI source, Cargo workspace and releases are owned here, **not inside Core**. Older `docs/CLI-Spec/` research suggested an initial in-Core crate; that choice was superseded. Never add source-path dependencies on private Core Rust crates.
2. Consume qualified, pinned NativeHTMLKit Core **host binaries and protocol contract** with hashes; allow explicit local binary path only for development. No Python wheels, mandatory Python/PowerShell, Node, browser, or HTTP server.
3. Canonical executable name `nativehtmlkit`; short `nhk` executable alias. Keep CLI and wire/API versions distinct.
4. First gate: `printf 'alpha\nbeta\ngamma\n' | nhk select --multi` on Linux KDE Wayland and interactive Windows. Submit emits only selected lines from the **launcher** to stdout; diagnostics to stderr. Cancel emits nothing and has a distinct status. Handle broken pipe, SIGINT, Unicode, injection, race and process cleanup.
5. If Core fails or lacks a needed function, **do not modify Core while acting as the CLI agent**. Reproduce it, record expected/observed, platform/version and a workaround in Project `docs/bugs/bug_list.md`; then request/coordinate a Core-owned fix. Don't weaken tests.
6. GitHub Actions **manual `workflow_dispatch` only**; never auto-publish or trigger on Core releases. Report actual test evidence and hashes. Do not claim CLI commands work until implementation passes acceptance.
7. Read `docs/CLI-Spec/README.md` and technical files as **proposals**, not authoritative runtime state. Project and this file take precedence over conflicting older research prompts.
