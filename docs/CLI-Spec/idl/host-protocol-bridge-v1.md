# Map NativeHTMLKit CLI requests onto current Core host JSON-RPC v1

This document is intentionally a **bridge map**, not a new host wire protocol. Source authority remains Core's `docs/reference/protocol.md` and Rust `crates/ui4me-host/src/protocol.rs`.

## Framing and authentication (existing)

- Unix socket / Windows named pipe; 4-byte unsigned big-endian JSON frame length + UTF-8 JSON body.
- JSON-RPC 2.0 subset; string IDs 1–128 bytes; strict params; max frame 2 MiB.
- Read `UI4ME_ENDPOINT`, `UI4ME_TOKEN` from host-started backend environment. Connect, send `host.hello` FIRST. Check `protocol_version: 1`, token authentication, `host_version` and capabilities; scrub secrets after connection.
- Only one authenticated backend; do not connect launcher directly to host concurrently.

## Initial sequence

```json
{"jsonrpc":"2.0","id":"nhk-1","method":"host.hello","params":{"token":"<host-provided token>","protocol_version":1,"client":{"name":"nativehtmlkit-cli","version":"0.1.0"}}}
```

```json
{"jsonrpc":"2.0","id":"nhk-2","method":"window.create","params":{"title":"Select items","width":850,"height":540}}
```

The host returns window identifier (e.g. `w1`). Then:

```json
{"jsonrpc":"2.0","id":"nhk-3","method":"document.load","params":{"window_id":"w1","html":"<main><h1>Select items</h1><button id='nhk-submit'>Submit</button></main>"}}
```

Then `app.ready`, with empty params. The backend receives document events as **notifications**:

```json
{"jsonrpc":"2.0","method":"document.event","params":{"window_id":"w1","document_id":"d3","event":{"type":"click","element":"nhk-submit"}}}
```

`document_id` and `window_id` are returned by host and should never be fabricated. The event example IDs are placeholders.

## Incremental UI

- `document.command` with `{ "window_id":..., "document_id":..., "command": {"op":"set_text","element":"nhk-count","text":"2 selected"}}` (check exact operation field names against current Core before use).
- `replace_children_html`, `set_attribute` and `batch` support dynamic pages. Never send >1 MiB HTML load or >2 MiB serialized frames.
- Forms `get_form_data`, `check_validity`, `request_submit` as in Core's protocol reference.

## Reverse requests and lifecycle

- Host sends `window.before_close` and `app.before_quit` as **requests**. Backend MUST reply with a standard JSON-RPC result, e.g. `{"allow":true}`, promptly. Before allowing user close, backend writes explicit cancellation receipt atomically.
- On Submit, write `submitted` receipt then send `app.request_quit` and answer subsequent `app.before_quit` appropriately.
- Host sends `document.event`, `window.event`, `app.shutdown` as notifications. Treat stale/late messages as normal race conditions, not an opportunity to double-commit.
- `app.force_quit` is **not** an ordinary Cancel and may prevent receipt creation.
- The host app config uses a backend executable plus args, cwd, timeouts and `instance` policy. Always use per-invocation identity/`instance=multiple` behavior to avoid second invocation activating a different pipeline's window.

## Core compatibility and namespace transition

As long as NativeHTMLKit uses host protocol v1, internal wire environment identifiers remain `UI4ME_*`; do not silently replace with `NHK_*` or `NATIVEHTMLKIT_*` while claiming v1 compatibility. This is separate from publicly naming the executable `nhk` and the package `NativeHTMLKit`. A future protocol v2 can negotiate a new namespace explicitly.
