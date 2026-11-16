# Troubleshooting (Linux)

On failure the CLI exits 1 and writes one line to stderr:

```text
nativehtmlkit: error[<code>]: <message> (<details>)
```

Find the line in the table, or reproduce the error with the example below it. Every code is
listed in the [exit status reference](../reference/exit-status.md). The examples were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](index.md#how-the-examples-are-verified)).

| You see | Cause | Fix |
|---|---|---|
| `error[host.not_found]: NativeHTMLKit Core host not found...` | no `nativehtmlkit-host` beside the CLI or on `PATH` | keep the extracted archive together; run `nativehtmlkit doctor`; or set `NATIVEHTMLKIT_HOST_BINARY` |
| `error[host.not_found]: Core host binary does not exist: <path>` | `--host` or `NATIVEHTMLKIT_HOST_BINARY` points nowhere | correct or unset it |
| `error[host.not_found]: cannot start the Core host (...)` | the file is not executable | `chmod +x`, or extract the archive again with `tar` |
| `error[input.invalid]: stdin is a terminal; pipe records in...` | `select`/`view` without piped input | pipe or redirect records in |
| `error[input.invalid]: no selectable input rows...` | the command before the CLI printed nothing | check for empty input first |
| `error[input.invalid]: stdin must contain UTF-8...` | Latin-1 or UTF-16 text | `iconv -f latin1 -t utf-8` |
| `error[input.invalid]: invalid JSON input: ...` | not JSON, two documents, or a byte-order mark | validate with `jq .`; strip the BOM |
| `error[input.invalid]: malformed CSV/TSV record: ...` | ragged rows, a TSV field starting with `"` | fix the data, or build JSON |
| `error[input.invalid]: input is too large to display: ...` | over the 1 MiB page or 65,536-node limit | the message says how many rows fit; filter first |
| `error[input.invalid]: ... exceeds the 2000-row ...` / `too many records` | more than 2,000 rows | `head -n 2000`, or filter |
| `error[usage.invalid]: --title must be nonempty...` | empty, over 128 characters, or a tab/newline | `${title:0:128}` |
| `error[output.failed]: selected value contains newline...` | `lines` output of a value with a line break | `--output-format json` or `ndjson` |
| `error[host.startup_timeout]` | no window within `--startup-timeout` (+5 s) | slow first start on a busy machine: raise `--startup-timeout` |
| `error[host.unresponsive]` | the host stopped answering while the window was open | it has been stopped; report it with a `--diagnostics debug` log |
| `error[host.failed]: ...` | the host process failed | run with `--diagnostics debug`, read the host's records |
| `error: unexpected argument ...` (no code) | a typo in an option | `nativehtmlkit <command> --help` |

## Check the installation

<!-- test: exit=0 calls="0@none" -->
```bash
nativehtmlkit doctor
```

If that fails with `host.not_found`, the host is not beside the CLI. A symbolic link to
`nativehtmlkit` is fine (the CLI resolves it); a *copy* of the executable elsewhere is not:

<!-- test: exit=1 shim=off -->
```bash
cp "$(realpath -- "$(command -v nativehtmlkit)")" ./nativehtmlkit-copy
PATH=/usr/bin:/bin ./nativehtmlkit-copy doctor
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: NativeHTMLKit Core host not found. Install a qualified release beside the CLI or set NATIVEHTMLKIT_HOST_BINARY.
```

<!-- test: exit=0 shim=off -->
```bash
ln -s "$(realpath -- "$(command -v nativehtmlkit)")" ./nativehtmlkit-link
./nativehtmlkit-link doctor | tail -n 1
```

<!-- stdout -->
```text
nativehtmlkit-host 1.0.3
```

A host file without the execute bit:

<!-- test: exit=1 calls="0@none 1@none" -->
```bash
cp "$(nativehtmlkit doctor | sed -n 's/^Core host: //p')" ./host-copy
chmod -x ./host-copy
nativehtmlkit doctor --host ./host-copy
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: cannot start the Core host (permission denied)
```

## Input problems

Nothing was piped in. In a terminal `select` would wait for typing, so it refuses instead
(here `script` provides a terminal):

<!-- test: exit=0 requires=script -->
```bash
script -qec 'nativehtmlkit select' /dev/null | tr -d '\r' | grep -o 'error\[input.invalid\]: stdin is a terminal'
```

<!-- stdout -->
```text
error[input.invalid]: stdin is a terminal
```

An empty pipe (the previous command found nothing). Check before calling `select`:

<!-- test: exit=0 calls="" -->
```bash
matches=$(find . -name '*.nothing-here')
if [[ -z $matches ]]; then echo 'no files to choose from'; exit 0; fi
nativehtmlkit select <<<"$matches"
```

<!-- stdout -->
```text
no files to choose from
```

Too large to display. The message says how many rows fit at this width:

<!-- test: exit=1 calls="1@none" -->
```bash
jq -nc '[range(1871) | [range(16) | {key: "c\(.)", value: "v"}] | from_entries]' |
  nativehtmlkit select --input-format json --multi
```

<!-- stderr -->
```text
at most 1870 rows fit
```

Long lines push a page over 1 MiB; shorten them by characters (not bytes):

<!-- test: exit=1 calls="1@none" -->
```bash
for i in $(seq 2000); do printf '%0600d\n' "$i"; done | nativehtmlkit view
```

<!-- stderr -->
```text
the host accepts 1048576 (1 MiB)
```

<!-- test: exit=124 calls="124@2000x1" -->
```bash
for i in $(seq 2000); do printf '%0600d\n' "$i"; done | perl -CSD -pe 's/^(.{400}).+/$1.../' | nativehtmlkit view
```

## "Nothing happens when I click Submit"

- `select`: something must be ticked, unless `--allow-empty` is given. The window says
  *select at least one row before submitting*.
- `form`: a constraint failed; the window says *Some required fields are invalid*. Check
  `required`, `pattern` (it must match the whole value), `min`/`max`.
- With `--diagnostics debug` the stderr log shows `submit.rejected` with the reason
  (`empty_selection`, `invalid_form`).

## The script stops at the CLI

That is by design: the window waits for the person. Add `--timeout` for unattended runs
([exit codes and scripting](exit-codes-and-scripting.md#--timeout-is-for-people-not-for-hangs)).

## Get a log to report a problem

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'a\nb\n' | NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID=report-1 nativehtmlkit --diagnostics trace select 2> report.log || true
jq -cR 'fromjson? | select(.component == "nativehtmlkit-cli") | {role, event, operation, error_code}' report.log | head -n 3
```

<!-- stdout -->
```text
{"role":"launcher","event":"session.started","operation":null,"error_code":null}
{"role":"launcher","event":"host.spawned","operation":null,"error_code":null}
{"role":"backend","event":"backend.started","operation":null,"error_code":null}
```

The CLI's records contain no data from your input; the host's records (also in the file)
are a separate log, review them before you share it. More in
[environment and diagnostics](environment-and-diagnostics.md).
