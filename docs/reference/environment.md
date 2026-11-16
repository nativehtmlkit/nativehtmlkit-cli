# Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `NATIVEHTMLKIT_HOST_BINARY` | CLI | host executable to use when `--host` is not given; an empty value is ignored ([host discovery](global-options.md#host-discovery)) |
| `NATIVEHTMLKIT_DIAGNOSTICS` | CLI and host | diagnostics level when `--diagnostics` is not given: `off`, `normal`, `debug`, `trace` (case-insensitive, surrounding spaces ignored); anything else means `normal`. The host reads the same variable. |
| `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` | CLI, passed to the host | correlation id put into every CLI record (`session_id`) and every host record (`diagnostic_session_id`). Accepted when it is 1-128 characters of `A-Z a-z 0-9 . _ : -` (after trimming spaces); otherwise a fresh id is generated and a `session_id.replaced` record is written. |
| `PATH` | CLI | last step of host discovery |
| `TMPDIR` (Unix), `TMP`/`TEMP` (Windows) | CLI | where the private session directory `nativehtmlkit-cli-*` is created |

Set by the CLI for the host process (not for you to set):

| Variable | Value |
|---|---|
| `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` | the session id in use |
| `NATIVEHTMLKIT_DIAGNOSTICS` | the level given with `--diagnostics`, only when the flag was given |

The Core host passes wire-v1 launch variables (`UI4ME_ENDPOINT`, `UI4ME_TOKEN`,
`UI4ME_APP_ID`, `UI4ME_PROTOCOL_VERSION`; the names are fixed by protocol v1) to the CLI's
internal backend, which removes them from its environment before doing anything else.

## Test-only switches

Not part of the user contract; they may change without notice:

| Variable | Effect |
|---|---|
| `NATIVEHTMLKIT_CLI_TEST_HEADLESS` | any value: start the host with `--headless`, so the whole protocol runs without a window. Nobody can click, so every session ends by `--timeout` (124), Ctrl+C or an error. Used by `scripts/test-examples.sh` and the release qualification. |
| `NATIVEHTMLKIT_WATCHDOG_GRACE_MS` | shortens the launcher watchdog margins (default 5000 ms) |
