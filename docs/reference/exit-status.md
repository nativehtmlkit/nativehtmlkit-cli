# Exit status, errors and streams

## Exit statuses

| Status | Meaning | stdout |
|---|---|---|
| `0` | `select`/`form`: submitted; `view`: closed; `doctor`, `--help`, `--version`: done | the result (empty for `view`) |
| `1` | any error: usage, input, host not found, host failure or hang, protocol violation, output write failure | empty |
| `2` | Cancel, or the window was closed without submitting (`select`, `form`) | empty |
| `124` | `--timeout` passed before a decision | empty |
| `130` | interrupted by SIGINT / Ctrl+C | empty |
| `143` | SIGTERM | empty |
| `129` | SIGHUP | empty |

Notes:

- Usage errors (unknown option, invalid value, missing `--html`) exit **1**, not clap's usual
  2, so that 2 always means *the user cancelled*.
- `view` has no Cancel: closing it is exit 0.
- On 143 and 129 the window is closed at once; on 130 the CLI gives the host up to 3 s to end
  by itself (a terminal Ctrl+C reaches the whole process group), then stops it.
- Exit statuses 124/130/143/129 never come with a result, even if the user had just clicked
  Submit.

## stdout and stderr

- **stdout** carries only the result, written once after the window has closed. Never parse
  stderr for results.
- **stderr** is shared by the CLI and the Core host:
  - the host's own JSON log records (one object per line, `"target":"nativehtmlkit_host..."`);
  - the CLI's diagnostic records (`"component":"nativehtmlkit-cli"`), as chosen by
    `--diagnostics` ([diagnostics](diagnostics.md));
  - on failure exactly one human line `nativehtmlkit: error[<code>]: <message>`;
  - on exit 124 the line `nativehtmlkit: no decision before the --timeout deadline; the window was closed`;
  - clap's `error: ...` text for usage errors.
- Every line is written with a single write, so lines from the CLI and the host cannot be
  interleaved inside one another.
- Error lines never quote stdin data, selections, form values, host-authored messages or the
  launch credential.

## The error line

```text
nativehtmlkit: error[<code>]: <message>[ (<details>)]
```

`<details>` is a comma-separated list of what is known: `operation <protocol method>`,
`request <id>`, `host code <n>`, `after <n> ms`, `remote outcome unknown`. Example:

```text
nativehtmlkit: error[rpc.timeout]: the Core host did not answer the request in time (operation document.load, request nhk-4, after 30000 ms, remote outcome unknown)
```

The `<code>` is stable and meant for scripts:

| Code | Meaning |
|---|---|
| `usage.invalid` | an option value clap accepted but the CLI rejects (`--title` empty, over 128 characters, or with control characters) |
| `input.invalid` | stdin, the `--html` or the `--css` file cannot be used: terminal stdin, not UTF-8, too large, parse error, limits, missing `nhk-form` |
| `output.failed` | the result could not be encoded (`lines` and a value with a newline) or written to stdout |
| `host.not_found` | no Core host executable, or it cannot be started |
| `host.startup_timeout` | the host did not get the window ready within `--startup-timeout` (+5 s) |
| `host.unresponsive` | the window was open but the host stopped answering liveness probes |
| `host.shutdown_timeout` | the host accepted the quit request, or the session ended, but the host did not exit |
| `host.failed` | the host process ended unsuccessfully without a more specific cause; `doctor`'s version check failed |
| `backend.unresponsive` | the CLI's own backend process stopped reporting progress |
| `rpc.timeout` | a request got no response within `--rpc-timeout` |
| `rpc.rejected` | the host answered a request with a JSON-RPC error (`host code N`) |
| `transport.connect_failed` | the local connection to the host could not be made |
| `transport.disconnected` | the connection ended (the host exited or closed it) |
| `protocol.truncated_frame`, `protocol.invalid_frame`, `protocol.violation`, `protocol.handshake_failed` | the host broke the wire-v1 contract, or the launch credentials were not accepted |
| `document.error` | the host reported a renderer/document error |
| `session.invalid` | the CLI's private session files are missing or inconsistent |
| `internal` | unclassified: a CLI defect, please report it |

A usage error printed by the argument parser has no code; it looks like this and also exits 1:

```text
error: unexpected argument '--bogus' found

Usage: nativehtmlkit select [OPTIONS]

For more information, try '--help'.
```

## Handling it in scripts

```bash
status=0
out=$(printf 'a\nb\n' | nativehtmlkit select) || status=$?
case $status in
  0)   echo "chose: $out" ;;
  2)   echo "cancelled" >&2 ;;
  124) echo "no answer in time" >&2 ;;
  *)   echo "failed ($status)" >&2; exit 1 ;;
esac
```

```powershell
$out = 'a', 'b' | nativehtmlkit select
switch ($LASTEXITCODE) {
    0       { "chose: $out" }
    2       { Write-Warning 'cancelled' }
    124     { Write-Warning 'no answer in time' }
    default { throw "nativehtmlkit failed ($LASTEXITCODE)" }
}
```

In a pipeline the status of the CLI is not the pipeline's status: see
[handling exit statuses](../guides/handling-exit-status.md) for `PIPESTATUS` and `pipefail`.
