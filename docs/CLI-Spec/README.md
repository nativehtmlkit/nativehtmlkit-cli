# NativeHTMLKit CLI — Research, Architecture, Specification, IDL

**Planning baseline:** 2026-11-15

> **Current project decision supersedes older planning details:** the CLI is implemented in its own `nativehtmlkit-cli` repository from the start (not as a crate within Core). Canonical executable: `nativehtmlkit`, convenience alias: `nhk`. Read the repository `AGENTS.md` and Project `MIGRATION-HANDOFF.md` first. This research remains proposed until tested.  
**Status:** Proposed, not implemented; repository inspection of `ui4me/ui4me-core` at its `main` branch (the reviewed 1.0.1 codebase).  
**Scope:** first independent Rust client of the native HTML/CSS host; Linux Wayland and interactive Windows x64.  
**Migration order:** Core → CLI → Python SDK → PowerShell SDK → UI libraries/applications.

## Executive decision

Ship **`nativehtmlkit`** (full executable name) with **`nhk`** as its short alias as a Rust console application with two internal roles: a shell-facing launcher and a host-started backend. Reuse the existing native host and its authenticated JSON-RPC version-1 protocol. The launcher is the **only process permitted to emit pipeline results**. Backend-to-launcher results use a private, atomic, bounded, validated handoff, never the host's bounded diagnostic streams.

First proof: `printf 'alpha\nbeta\ngamma\n' | nhk select --multi`. A native window opens, Submit prints the exact selected line values in original input order to stdout, and Cancel prints nothing and exits 10. Validate on Linux Wayland and interactive Windows before broadening scope.

## Contents and reading order

1. [Decision summary](00-decisions.md)
2. [Current Core evidence](research/01-core-audit.md)
3. [Competitor and standards research](research/02-market-and-standards.md)
4. [Use cases and feasibility](research/03-scenarios-and-gaps.md)
5. [System architecture](architecture/01-system.md)
6. [Process lifecycle and result delivery](architecture/02-lifecycle.md)
7. [Threat model](architecture/03-security.md)
8. [Packaging and migration](architecture/04-migration.md)
9. [Future extensions: SDK and MCP](architecture/05-extensions.md)
10. [CLI contract](specification/01-cli-contract.md)
11. [Input/output data contract](specification/02-data-model.md)
12. [UI and event handling](specification/03-ui-interactions.md)
13. [Test and release gates](specification/04-testing.md)
14. [Work packages and release plan](specification/05-roadmap.md)
15. [Risks and ADRs](specification/06-decisions-and-risks.md)
16. [Performance and observability](specification/07-performance-and-observability.md)
17. [IDL and JSON Schemas](idl/README.md)
18. [Runnable examples](examples/README.md)
19. [Agent implementation prompt](AGENT-IMPLEMENTATION-PROMPT.md)
20. [Sources](SOURCES.md)

## Contract stability

- **Existing host protocol:** current v1 is **private**, not a public frozen API. This plan does not redefine it.
- **Proposed CLI v0.1 command/output conventions:** should be treated as external API immediately after first published release.
- **`InvocationSpec`, `FormSpec`, `ResultEnvelope`:** machine-readable proposals. `ResultEnvelope` is optional and does not replace default stdout row records.
- **Future items:** marked by milestone, not presumed implemented.

## Non-goals

This is an **engineering specification, not executable NativeHTMLKit code**, and nothing in the ZIP claims local acceptance tests have run. The CLI is not a browser, server, app store, network GUI, agent approval authority, or replacement for the Python/PowerShell SDKs.
