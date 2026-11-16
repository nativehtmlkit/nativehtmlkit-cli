# Environment and diagnostics (Linux)

This page shows the environment variables the CLI reads, how it finds the Core host, and
how to get a timeline of a session with `--diagnostics`. Specifications:
[environment](../reference/environment.md), [diagnostics](../reference/diagnostics.md),
[host discovery](../reference/global-options.md#host-discovery).

The examples were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](index.md#how-the-examples-are-verified)).

## Environment variables

| Variable | Effect |
|---|---|
| `NATIVEHTMLKIT_HOST_BINARY` | the Core host to use when `--host` is not given (an empty value is ignored) |
| `NATIVEHTMLKIT_DIAGNOSTICS` | default for `--diagnostics`: `off`, `normal`, `debug`, `trace`; the host reads it too |
| `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` | correlation id put into every CLI and host record (1-128 characters of `A-Z a-z 0-9 . _ : -`) |
| `PATH` | the last place the CLI looks for `nativehtmlkit-host` |
| `TMPDIR` | where the private, per-session directory `nativehtmlkit-cli-*` is created and removed again |

The CLI reads no configuration files.

## Which host is used

The first match wins: `--host PATH`, then `NATIVEHTMLKIT_HOST_BINARY`, then
`nativehtmlkit-host` in the directory of the real CLI executable (symbolic links resolved),
then each `PATH` directory. `doctor` shows the result:

<!-- test: exit=0 calls="0@none 0@none" -->
```bash
host=$(nativehtmlkit doctor | sed -n 's/^Core host: //p')
NATIVEHTMLKIT_HOST_BINARY=$host nativehtmlkit doctor | tail -n 1
```

<!-- stdout -->
```text
nativehtmlkit-host 1.0.3
```

A variable that names no file is an error; `--host` wins over it:

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | NATIVEHTMLKIT_HOST_BINARY=/opt/missing/nativehtmlkit-host nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: /opt/missing/nativehtmlkit-host
```

<!-- test: exit=124 calls="0@none 124@1x1" -->
```bash
host=$(nativehtmlkit doctor | sed -n 's/^Core host: //p')
echo a | NATIVEHTMLKIT_HOST_BINARY=/opt/missing/nativehtmlkit-host nativehtmlkit select --host "$host"
```

The CLI 0.1.2 is qualified with Core host 1.0.3, the one in its release archive; use the
override for development builds only.

## `--diagnostics` levels

The CLI writes structured records, one JSON object per line, to **stderr**; stdout only
ever carries the result. The Core host writes its own JSON log records to the same stderr
(`"target":"nativehtmlkit_host..."`); the CLI's carry `"component":"nativehtmlkit-cli"`.

| Level | CLI records |
|---|---|
| `off` | none |
| `normal` (default) | failures only |
| `debug` | the session's lifecycle with timings |
| `trace` | also every request, host event and liveness probe |

Count the CLI's records per level for the same window:

<!-- test: exit=0 calls="124@none" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --diagnostics off 2> off.log
jq -cR 'fromjson? | select(.component == "nativehtmlkit-cli")' off.log | wc -l
```

<!-- stdout -->
```text
0
```

<!-- test: exit=0 calls="124@none" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --diagnostics normal 2> normal.log
jq -cR 'fromjson? | select(.component == "nativehtmlkit-cli")' normal.log | wc -l
```

A deadline is not a failure, so `normal` writes nothing here either:

<!-- stdout -->
```text
0
```

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --diagnostics debug 2> debug.log
jq -rR 'fromjson? | select(.component == "nativehtmlkit-cli") | .event' debug.log | sort -u | grep -c .
jq -rR 'fromjson? | select(.event == "session.completed") | .context | "\(.outcome) \(.exit_code)"' debug.log
```

<!-- stdout -->
```text
11
deadline 124
```

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --diagnostics trace 2> trace.log
jq -rR 'fromjson? | select(.component == "nativehtmlkit-cli") | .event' trace.log | grep -m1 -x rpc.started
```

<!-- stdout -->
```text
rpc.started
```

`NATIVEHTMLKIT_DIAGNOSTICS` sets the default; the flag wins:

<!-- test: exit=0 calls="124@2x1" -->
```bash
export NATIVEHTMLKIT_DIAGNOSTICS=debug
printf 'a\nb\n' | nativehtmlkit select 2> env.log
jq -rR 'fromjson? | select(.component == "nativehtmlkit-cli") | .event' env.log | grep -m1 -x window.ready
```

<!-- stdout -->
```text
window.ready
```

## A timeline of one session

Keep the result and the log apart, then read the CLI's records:

<!-- test: exit=0 calls="124@3x1" -->
```bash
printf 'one\ntwo\nthree\n' > items.txt
nativehtmlkit --diagnostics debug select < items.txt > choice.txt 2> session.log
jq -cR 'fromjson? | select(.component == "nativehtmlkit-cli" and .event != "rpc.completed") | {role, event}' session.log
```

<!-- stdout -->
```text
{"role":"launcher","event":"session.started"}
{"role":"launcher","event":"host.spawned"}
{"role":"backend","event":"backend.started"}
{"role":"backend","event":"handshake.completed"}
{"role":"backend","event":"window.ready"}
{"role":"backend","event":"deadline.expired"}
{"role":"backend","event":"host.request"}
{"role":"backend","event":"session.shutdown"}
{"role":"launcher","event":"host.exited"}
{"role":"launcher","event":"session.completed"}
```

With a Submit instead of a deadline you would see `submit.accepted` where
`deadline.expired` is. `rpc.completed` records carry the protocol `operation` and
`duration_ms` of each request. Records never contain your data, titles, paths or form
values; the host's records are a separate log, so review those before sharing one.

## Correlate with your own logs

`NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` puts your id into every CLI record (`session_id`) and
every host record (`diagnostic_session_id`):

<!-- test: exit=0 calls="124@1x1" -->
```bash
echo 'build ok' > build.log
NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID="nightly-42" nativehtmlkit --diagnostics debug view < build.log 2>> all.log || [[ $? -eq 124 ]]
jq -rR 'fromjson? | .session_id // .diagnostic_session_id' all.log | sort -u
```

<!-- stdout -->
```text
nightly-42
```

An id with other characters is replaced by a generated one, and a `session_id.replaced`
record says so:

<!-- test: exit=0 calls="124@none" -->
```bash
echo 'x' | NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID='my id/1' nativehtmlkit view --diagnostics normal 2> replaced.log || true
jq -rR 'fromjson? | select(.component == "nativehtmlkit-cli") | .event' replaced.log
```

<!-- stdout -->
```text
session_id.replaced
```

## Temporary files

Each session uses a private directory `nativehtmlkit-cli-*` under `TMPDIR` (or `/tmp`) and
removes it when the command ends, whatever the outcome:

<!-- test: exit=0 calls="124@1x1" -->
```bash
mkdir -p session-tmp
echo x | TMPDIR=$PWD/session-tmp nativehtmlkit view || true
ls -A session-tmp | wc -l
```

<!-- stdout -->
```text
0
```
