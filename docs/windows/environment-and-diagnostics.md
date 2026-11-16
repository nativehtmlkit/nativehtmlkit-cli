# Environment and diagnostics (Windows)

This page shows the environment variables the CLI reads, how it finds the Core host, and
how to get a timeline of a session with `--diagnostics`. Specifications:
[environment](../reference/environment.md), [diagnostics](../reference/diagnostics.md),
[host discovery](../reference/global-options.md#host-discovery).

The examples were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and
PowerShell 7 by `scripts/test-docs.ps1` ([how](index.md#how-the-examples-are-verified)).
In PowerShell an environment variable is set for the session with `$env:NAME = 'value'`
and removed with `Remove-Item Env:NAME`; in `cmd.exe` with `set NAME=value`.

## Environment variables

| Variable | Effect |
|---|---|
| `NATIVEHTMLKIT_HOST_BINARY` | the Core host to use when `--host` is not given (an empty value is ignored) |
| `NATIVEHTMLKIT_DIAGNOSTICS` | default for `--diagnostics`: `off`, `normal`, `debug`, `trace`; the host reads it too |
| `NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` | correlation id put into every CLI and host record (1-128 characters of `A-Z a-z 0-9 . _ : -`) |
| `PATH` | the last place the CLI looks for `nativehtmlkit-host.exe` |
| `TMP` / `TEMP` | where the private, per-session folder `nativehtmlkit-cli-*` is created and removed again |

The CLI reads no configuration files and no registry keys.

## Which host is used

The first match wins: `--host PATH`, then `NATIVEHTMLKIT_HOST_BINARY`, then
`nativehtmlkit-host.exe` in the folder of the CLI executable, then each `PATH` folder.
`doctor` shows the result:

<!-- test: exit=0 calls="0@none 0@none" -->
```powershell
$coreHost = (nativehtmlkit doctor | Select-String '^Core host: (.+)$').Matches[0].Groups[1].Value
$env:NATIVEHTMLKIT_HOST_BINARY = $coreHost
nativehtmlkit doctor | Select-Object -Last 1
Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY
```

<!-- stdout -->
```text
nativehtmlkit-host 1.0.3
```

A variable that names no file is an error; `--host` wins over it:

<!-- test: exit=1 calls="1@none" -->
```powershell
$env:NATIVEHTMLKIT_HOST_BINARY = 'C:\missing\nativehtmlkit-host.exe'
'a' | nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: C:\missing\nativehtmlkit-host.exe
```

<!-- test: exit=124 calls="0@none 124@1x1" -->
```powershell
$coreHost = (nativehtmlkit doctor | Select-String '^Core host: (.+)$').Matches[0].Groups[1].Value
$env:NATIVEHTMLKIT_HOST_BINARY = 'C:\missing\nativehtmlkit-host.exe'
'a' | nativehtmlkit select --host $coreHost
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

A small helper collects the CLI's records from stderr (`2>&1` turns each stderr line into
an error record; `"$_"` is its text):

<!-- test: exit=0 calls="124@none" -->
```powershell
function Get-CliRecords { process { $line = "$_"; if ($line.StartsWith('{')) { $r = ConvertFrom-Json -InputObject $line; if ($r.component -eq 'nativehtmlkit-cli') { $r } } } }
@('a', 'b' | nativehtmlkit select --diagnostics off 2>&1 | Get-CliRecords).Count
exit 0
```

<!-- stdout -->
```text
0
```

<!-- test: exit=0 calls="124@none" -->
```powershell
function Get-CliRecords { process { $line = "$_"; if ($line.StartsWith('{')) { $r = ConvertFrom-Json -InputObject $line; if ($r.component -eq 'nativehtmlkit-cli') { $r } } } }
@('a', 'b' | nativehtmlkit select --diagnostics normal 2>&1 | Get-CliRecords).Count
exit 0
```

A deadline is not a failure, so `normal` writes nothing here either:

<!-- stdout -->
```text
0
```

<!-- test: exit=0 calls="124@2x1" -->
```powershell
function Get-CliRecords { process { $line = "$_"; if ($line.StartsWith('{')) { $r = ConvertFrom-Json -InputObject $line; if ($r.component -eq 'nativehtmlkit-cli') { $r } } } }
$records = @('a', 'b' | nativehtmlkit select --diagnostics debug 2>&1 | Get-CliRecords)
@($records | ForEach-Object { $_.event } | Sort-Object -Unique).Count
$done = $records | Where-Object { $_.event -eq 'session.completed' }
"$($done.context.outcome) $($done.context.exit_code)"
exit 0
```

<!-- stdout -->
```text
11
deadline 124
```

<!-- test: exit=0 calls="124@2x1" -->
```powershell
function Get-CliRecords { process { $line = "$_"; if ($line.StartsWith('{')) { $r = ConvertFrom-Json -InputObject $line; if ($r.component -eq 'nativehtmlkit-cli') { $r } } } }
$records = @('a', 'b' | nativehtmlkit select --diagnostics trace 2>&1 | Get-CliRecords)
($records | Where-Object { $_.event -eq 'rpc.started' } | Select-Object -First 1).event
exit 0
```

<!-- stdout -->
```text
rpc.started
```

`NATIVEHTMLKIT_DIAGNOSTICS` sets the default; the flag wins:

<!-- test: exit=0 calls="124@2x1" -->
```powershell
$env:NATIVEHTMLKIT_DIAGNOSTICS = 'debug'
$log = 'a', 'b' | nativehtmlkit select 2>&1 | ForEach-Object { "$_" }
[bool] ($log | Where-Object { $_ -like '*"event":"window.ready"*' })
exit 0
```

<!-- stdout -->
```text
True
```

## A timeline of one session

Keep the result and the log apart: with `2>&1` the stderr lines arrive as error records and
the result lines as strings, so they can be split again:

<!-- test: exit=0 calls="124@3x1" -->
```powershell
$all = 'one', 'two', 'three' | nativehtmlkit --diagnostics debug select 2>&1
$result = $all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
$log = $all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }
$log | Where-Object { $_.StartsWith('{') } | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
    Where-Object { $_.component -eq 'nativehtmlkit-cli' -and $_.event -ne 'rpc.completed' } |
    ForEach-Object { '{0,-8} {1}' -f $_.role, $_.event }
exit 0
```

<!-- stdout -->
```text
launcher session.started
launcher host.spawned
backend  backend.started
backend  handshake.completed
backend  window.ready
backend  deadline.expired
backend  host.request
backend  session.shutdown
launcher host.exited
launcher session.completed
```

With a Submit instead of a deadline you would see `submit.accepted` where
`deadline.expired` is. `rpc.completed` records carry the protocol `operation` and
`duration_ms` of each request. Records never contain your data, titles, paths or form
values; the host's records are a separate log, so review those before sharing one.

Avoid `2> file` for these logs in Windows PowerShell 5.1: it writes the first stderr line as
a formatted error record and wraps long lines, so the JSON records no longer parse.
PowerShell 7 and `cmd.exe` (`2> session.log`) write the lines unchanged.

## Correlate with your own logs

`NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID` puts your id into every CLI record (`session_id`) and
every host record (`diagnostic_session_id`):

<!-- test: exit=0 calls="124@1x1" -->
```powershell
$env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = 'nightly-42'
$log = 'build ok' | nativehtmlkit --diagnostics debug view 2>&1 | ForEach-Object { "$_" }
$log | Where-Object { $_.StartsWith('{') } | ForEach-Object { $r = ConvertFrom-Json -InputObject $_; if ($r.session_id) { $r.session_id } else { $r.diagnostic_session_id } } |
    Sort-Object -Unique
exit 0
```

<!-- stdout -->
```text
nightly-42
```

An id with other characters is replaced by a generated one, and a `session_id.replaced`
record says so:

<!-- test: exit=0 calls="124@none" -->
```powershell
$env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = 'my id/1'
$log = 'x' | nativehtmlkit view --diagnostics normal 2>&1 | ForEach-Object { "$_" }
$log | Where-Object { $_ -like '*"component":"nativehtmlkit-cli"*' } | ForEach-Object { (ConvertFrom-Json -InputObject $_).event }
exit 0
```

<!-- stdout -->
```text
session_id.replaced
```

## Temporary files

Each session uses a private folder `nativehtmlkit-cli-*` under `TMP` and removes it when the
command ends, whatever the outcome:

<!-- test: exit=0 calls="124@1x1" -->
```powershell
New-Item -ItemType Directory -Path session-tmp | Out-Null
$env:TMP = (Resolve-Path session-tmp).ProviderPath; $env:TEMP = $env:TMP; $env:TMPDIR = $env:TMP
'x' | nativehtmlkit view
@(Get-ChildItem -Force -Directory session-tmp -Filter 'nativehtmlkit-cli-*').Count
exit 0
```

<!-- stdout -->
```text
0
```

On Windows the Core host also creates a folder `nativehtmlkit-bitmaps` in `TMP` and leaves it
there (empty) after the session; it is the host's, not the CLI's, and can be deleted.
