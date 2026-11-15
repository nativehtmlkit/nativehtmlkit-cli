# Lifecycle, shell pipes, state machine and completion

## Normal selection sequence

```mermaid
sequenceDiagram
  participant P as Shell pipeline
  participant L as nhk launcher
  participant F as Private session files
  participant H as NativeHTMLKit host
  participant B as nhk backend
  P->>L: stdin bytes (until EOF)
  L->>L: parse, validate caps, preserve original row order
  L->>F: securely stage dataset + manifest
  L->>H: spawn host run --app manifest
  H->>B: spawn nhk __internal-backend + IPC environment
  B->>H: host.hello(token, protocol_version=1)
  B->>H: window.create; document.load; app.ready
  H-->>B: document.event (select, submit)
  B->>F: atomic result receipt: submitted + chosen indices
  B->>H: app.request_quit
  H-->>B: app.before_quit; app.shutdown
  B-->>H: allow / exit clean
  H-->>L: exit 0
  L->>F: verify result receipt and staged data
  L->>P: only selected record serialization on stdout
  L->>F: cleanup, exit 0
```

## States

```text
NEW -> READING_INPUT -> STAGED -> HOST_STARTING -> INTERACTIVE
  -> [SUBMIT] COMMITTING -> COMMITTED -> HOST_STOPPING -> OUTPUTTING -> DONE
  -> [CANCEL] CANCEL_COMMIT -> HOST_STOPPING -> CANCELLED (status 10)
  -> [ERROR] FAILED (status 2/3/4/5/6/...)
```

Rules: exactly one terminal result (`submitted` or `cancelled`) is accepted. Output occurs only on a `submitted` receipt and clean host exit. If host exits without a valid receipt, classify as a failure, never as implicit cancellation. For the future read-only `view` command, an intentional close is a terminal `submitted` receipt with no selected rows and empty stdout; this is distinct from `select` cancellation. If host closes unexpectedly after a receipt, fail closed (no stdout), even if this means retrying the selection.

## Mechanism of record delivery

**V0.1 choice:** write JSON receipts atomically to a private session folder (same-volume temp + rename). The receipt has `schema_version`, `kind`, `status`, `nonce`, `selected_indices`, and optional payload checksum. It contains no raw selected row strings; the launcher holds original parsed input for serialization. This reduces large or dangerous data transfer from backend.

1. Launcher creates a per-invocation folder using secure random name and restrictive permissions, and writes the canonical dataset separately.
2. Host manifest invokes the same `nhk` executable as a backend with a session path. Backend verifies host-provided token/endpoint before accepting the role.
3. Backend operates only on indices into immutable staged records. On Submit, commits receipt via create-write-flush-close-atomic rename within session folder; on Cancel, writes explicit cancellation receipt.
4. Backend requests graceful application quit; replies promptly to host close/quit decisions.
5. Launcher waits for host exit. Only on clean exit does it validate receipt, nonce, index uniqueness and ranges, then serialize results from its canonical dataset.
6. Launcher cleans the stage, prints to stdout only for Submit, and exits with the defined code.

Never treat the host's backend stdout/stderr logging as a data channel: `backend.rs` and `logging.rs` intentionally bound and drop records when needed.

## Native close, Escape and forced kill

- **Cancel button/Escape/normal window close:** write explicit `cancelled` receipt **before** allowing close. If Core needs request/notification scheduling refinements to achieve this reliably, document and qualify them without changing v1 wire semantics.
- **User closes during startup or Ctrl+Shift+Q forces quit:** if no committed receipt, treat as runtime abort/failure, not a normal Cancel. In future, refine user-visible cancel mapping only when deterministically provable.
- **Ctrl+C at terminal:** launcher handles termination and tears down its host/children; status 130 is conventional. On Windows Ctrl+C needs dedicated console-handler tests.
- **Host/backend crash:** never emit data. Clean stage; diagnostic on stderr.
- **Result already emitted and downstream consumer closes:** no guarantee that an OS pipe can retract earlier bytes. Report BrokenPipe appropriately and do not retry automatically.

## Input snapshot model

V0.1 `select` and `view` read input fully until EOF before opening the UI, and enforce byte/row limits. **Infinite streams (`tail -f`, `journalctl -f`) do not show a window in V0.1**. Future `--follow` must create GUI before EOF and establish separate bounded incremental delivery/backpressure contracts.

`input`, `confirm`, and no-data `form` do not read stdin by default. `select` and `view` require piped stdin or an explicit `--file` path, to avoid appearing hung when called with an attached terminal.
