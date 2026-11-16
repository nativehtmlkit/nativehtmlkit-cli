# Diagnostics and troubleshooting

## Start with the error line

On failure the CLI exits 1 and writes one line to stderr:

```text
nativehtmlkit: error[<code>]: <message> (<details>)
```

| You see | Cause | Fix |
|---|---|---|
| `error[host.not_found]: NativeHTMLKit Core host not found...` | no `nativehtmlkit-host` beside the CLI or on `PATH` | keep the extracted archive together; run `nativehtmlkit doctor`; or set `NATIVEHTMLKIT_HOST_BINARY` |
| `error[host.not_found]: Core host binary does not exist: <path>` | `--host` or `NATIVEHTMLKIT_HOST_BINARY` points nowhere | correct or unset it |
| `error[host.not_found]: cannot start the Core host (permission denied)` | the file is not executable | `chmod +x`, or extract the archive again with `tar` |
| `error[input.invalid]: stdin is a terminal; pipe records in...` | `select`/`view` without piped input | pipe or redirect records in |
| `error[input.invalid]: no selectable input rows...` | the command before the CLI printed nothing | check for empty input before calling `select` |
| `error[input.invalid]: stdin must contain UTF-8...` | Latin-1/UTF-16 text; Windows PowerShell without UTF-8 `$OutputEncoding` | convert (`iconv -f latin1 -t utf-8`), or set the encoding ([PowerShell](windows-powershell.md)) |
| `error[input.invalid]: invalid JSON input: expected value at line 1 column 1` | empty-looking or BOM-prefixed JSON | in PowerShell use `UTF8Encoding($false)` |
| `error[input.invalid]: malformed CSV/TSV record: ... found record with N fields...` | ragged rows, or a TSV field starting with `"` | fix the data, or build JSON instead of TSV |
| `error[input.invalid]: input is too large to display: ...` | over the 1 MiB page or 65,536-node limit | the message says how many rows fit; filter rows or columns first |
| `error[usage.invalid]: --title must be nonempty...` | empty, too long (over 128) or with a tab/newline | shorten it: `${title:0:128}` |
| `error[output.failed]: selected value contains newline...` | `--output-format lines` and a value with a line break | use `json` or `ndjson` output |
| `error[host.startup_timeout]` | the host did not show the window within `--startup-timeout` + 5 s | a slow first start (cold disk, busy machine): raise `--startup-timeout` |
| `error[host.unresponsive]` | the host stopped answering while the window was open | the host hung; it has been stopped. Report it with a `--diagnostics debug` log |
| `error[host.failed]: the Core host ended with ...` | the host process failed | run with `--diagnostics debug` and read the host's records on stderr |

The full list of codes is in [exit status and errors](../reference/exit-status.md).

## Get a timeline

```bash
nativehtmlkit --diagnostics debug select < items.txt > choice.txt 2> session.log
jq -cR 'fromjson? | select(.component == "nativehtmlkit-cli") | {role, event, operation, duration_ms, error_code}' session.log
```

`session.log` then holds the CLI's records (`"component":"nativehtmlkit-cli"`) and the host's
records (`"target":"nativehtmlkit_host::..."`), plus the error line if any. `trace` adds
every request, event and liveness probe. Records never contain your data; the host's
records are a separate log, review them before you share one. Details:
[diagnostics reference](../reference/diagnostics.md).

To find one run in a shared log, set a correlation id:

```bash
NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID="nightly-42" nativehtmlkit --diagnostics debug view < report.txt 2>> all.log
```

## "Nothing happens when I click Submit"

- `select` without `--multi`/`--allow-empty`: something must be ticked. The window then says
  *select at least one row before submitting*.
- `form`: a constraint failed; the window says *Some required fields are invalid*. Check
  `required`, `pattern` (it must match the whole value), `min`/`max`.
- At `normal` level a `host.notifications_dropped` record means the host discarded events
  because the CLI was not reading fast enough; a click may have been lost. Click again and
  report it.

## The script stops at the CLI

The CLI waits for the person indefinitely unless `--timeout` is given. That is by design.
For unattended runs add `--timeout`; the host watchdogs (`--rpc-timeout`,
`--liveness-interval`) only stop a *hung host*.
