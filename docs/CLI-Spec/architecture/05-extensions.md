# Future extensions without contaminating v0.1

## CLI as a stable UI request transport

The CLI's `InvocationSpec` and result envelope make it possible for callers (scripts, language SDKs, local orchestrators) to open a user-facing window and receive an explicit result. This is a **tool interface**, not a new Core renderer API.

## Agent and MCP feasibility

Possible later flow: agent invokes a local MCP tool → tool validates and authorizes a request → local interactive-session broker runs `nhk` → a human sees an input/selection form → results return to MCP client. This needs stronger ownership, pairing, timeout, cancellation, audit and user-consent semantics. It must not silently approve privileged operations or open GUI windows on an unrelated machine.

**Critical caveat:** MCP over stdio owns stdin/stdout for JSON-RPC (confirmed by the MCP specification, including its 2026-07-28 stdio transport revision). Do **not** reuse normal `nhk select` stdout in the same process as an MCP stdio server. A separate `nhk-mcp` or `nhk mcp` mode with distinct framed transport and request/response messaging is required; ideally a separate adapter package.

## A2A / orchestration

A2A can eventually expose a user-in-the-loop step, but is not necessary for the first CLI. No remote browser, no exposed HTTP listener. For remote Windows/Linux interactive usage, an authenticated per-user desktop broker is a separate product/security design.

## Candidate advanced CLI commands

- `nhk watch` / `view --follow`: incremental log viewer with bounded ring and backpressure.
- `nhk pick-file`, `nhk pick-folder`: existing Core native dialog primitives.
- `nhk menu`, `nhk checklist`: thin UX aliases around `select`.
- `nhk inspect`: read-only schema-assisted table/JSON detail view.
- `nhk form --html`: trusted local HTML and CSS; declarative mapping of named inputs to JSON output.
- `nhk charts`: data-to-HTML/CSS native charts or eventually live bitmap-based graphics.
- `nhk prompt --spec`: one request format for local agents or coding tools, without auto-execution privileges.

## Temptations to reject early

- Arbitrary JS or template expressions in CLI options.
- TCP/HTTP server solely to send input to the GUI.
- Background system daemon or privileged service.
- Full-blown component library and plugin marketplace inside CLI.
- Direct SSH display forwarding assumptions.
- Persistent desktop process by default; CLI should exit with its pipe once a one-shot interaction completes.
