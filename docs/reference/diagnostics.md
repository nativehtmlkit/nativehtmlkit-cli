# Diagnostics

`--diagnostics off|normal|debug|trace` (or `NATIVEHTMLKIT_DIAGNOSTICS`; the flag wins) sets
the level of the CLI's own records on stderr. When given as a flag it is also exported to the
Core host, which has its own, separate log on the same stderr.

## Record format

One JSON object per line, schema version 1:

```json
{"schema_version":1,"timestamp":"2026-11-16T14:14:45.106Z","session_id":"nhk-2322069-18e88c17ba30360d","component":"nativehtmlkit-cli","role":"backend","pid":2322075,"level":"debug","event":"rpc.completed","request_id":"nhk-4","operation":"document.load","duration_ms":41}
```

| Member | Always | Meaning |
|---|---|---|
| `schema_version` | yes | `1` |
| `timestamp` | yes | UTC, ISO 8601 with milliseconds |
| `session_id` | yes | correlation id ([environment](environment.md)); generated as `nhk-<pid>-<hex>` unless inherited |
| `component` | yes | `nativehtmlkit-cli` |
| `role` | yes | `launcher` (the process you started) or `backend` (the process the host started for the session; its records are written to a private file and relayed to stderr by the launcher, at most 1 MiB per session) |
| `pid` | yes | process id of that role |
| `level` | yes | the record's level |
| `event` | yes | event name, below |
| `request_id`, `operation`, `duration_ms`, `error_code`, `context` | when known | request correlation (`nhk-1`, `nhk-2`, ...), protocol method, timing, the stable `error[<code>]`, small numeric or fixed-text details |

Records can only contain fixed event names, identifier-shaped strings, numbers and booleans.
They never contain stdin data, selections, form values, HTML, titles, paths or the launch
token. The host's records are a separate channel (`"target":"nativehtmlkit_host..."`); review
them before sharing a log.

## Levels and events

| Level | Adds |
|---|---|
| `off` | no CLI records |
| `normal` (default) | failures only: `session.failed`, `backend.failed`, `rpc.timeout`, `rpc.failed`, `host.watchdog`, `host.killed`, `session_id.replaced`, `diagnostics.dropped`, and `host.notifications_dropped` (the host discarded window/document events because the backend was not reading: a click may have been lost). `session.failed` for usage and input errors appears only at `debug`. |
| `debug` | lifecycle and timings: `session.started` (`context.mode`, `rows`, `columns`), `host.spawned`, `backend.started`, `handshake.completed` (`context.host_version`), `rpc.completed`, `window.ready`, `host.request`, `submit.rejected` (`context.reason`: `empty_selection` or `invalid_form`), `submit.accepted`, `submit.superseded_by_shutdown`, `host.already_shutting_down`, `user.cancelled`, `deadline.expired`, `session.shutdown`, `host.exited`, `session.completed` (`context.outcome`: `submitted`, `viewed`, `cancelled`, `deadline`, `interrupted`, `terminated`, `hangup`; `context.exit_code`) |
| `trace` | every request start (`rpc.started`), every host notification (`event.received`), every liveness probe answer (`liveness.ok`) |

## Using it

Reading the records, a session timeline and correlation ids, with verified examples:
[Linux](../linux/environment-and-diagnostics.md), [Windows](../windows/environment-and-diagnostics.md).

A debug session that reached the window and timed out looks like this (CLI records only):
`session.started` -> `host.spawned` -> `backend.started` -> `rpc.completed` for `host.hello`,
`host.diagnostics`, `window.create`, `document.load`, `app.ready` -> `window.ready` ->
`deadline.expired` -> `host.request` (`app.before_quit`) -> `rpc.completed` (`app.request_quit`)
-> `session.shutdown` -> `host.exited` -> `session.completed` (`deadline`, 124).

See also troubleshooting ([Linux](../linux/troubleshooting.md), [Windows](../windows/troubleshooting.md)).
