# Troubleshooting (Windows)

On failure the CLI exits 1 and writes one line to stderr:

```text
nativehtmlkit: error[<code>]: <message> (<details>)
```

Find the line in the table, or reproduce the error with the example below it. Every code is
listed in the [exit status reference](../reference/exit-status.md). The examples were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](index.md#how-the-examples-are-verified)).

| You see | Cause | Fix |
|---|---|---|
| `nativehtmlkit : The term 'nativehtmlkit' is not recognized ...` | the folder is not on `PATH` | add it ([install](index.md#install)) or call it by full path |
| `error[host.not_found]: NativeHTMLKit Core host not found...` | `nativehtmlkit-host.exe` is not beside the CLI | keep the extracted archive together; run `nativehtmlkit doctor` |
| `error[host.not_found]: Core host binary does not exist: <path>` | `--host` or `NATIVEHTMLKIT_HOST_BINARY` points nowhere | correct or remove it |
| `error[host.not_found]: cannot start the Core host (...)` | the file is not a working program (blocked, damaged) | extract the archive again |
| non-ASCII text shows as `?` | Windows PowerShell 5.1 sends `us-ascii` | [set up UTF-8](index.md#set-up-utf-8-once) |
| `error[input.invalid]: invalid JSON input: expected value at line 1 column 1` | a byte-order mark from `$OutputEncoding = [Text.Encoding]::UTF8` (5.1) | use `[System.Text.UTF8Encoding]::new($false)` |
| `error[input.invalid]: no selectable input rows...` | the pipeline before the CLI produced nothing | check the count first |
| `error[input.invalid]: ... 33 columns exceeds the 32-column limit` | a raw object with many properties | `Select-Object` the properties first |
| `error[input.invalid]: malformed CSV/TSV record: ...` | ragged rows, `#TYPE` line from `ConvertTo-Csv` in 5.1, a TSV field starting with `"` | `-NoTypeInformation`; send JSON |
| `error[input.invalid]: input is too large to display: ...` | over the 1 MiB page or 65,536-node limit | the message says how many rows fit; filter first |
| `error[usage.invalid]: --title must be nonempty...` | over 128 characters, or a tab/newline | `$title.Substring(0, [Math]::Min(128, $title.Length))` |
| `error[output.failed]: selected value contains newline...` | `lines` output of a value with a line break | `--output-format json` or `ndjson` |
| `error[host.startup_timeout]` | no window within `--startup-timeout` (+5 s) | slow first start on a busy machine: raise `--startup-timeout` |
| `error[host.unresponsive]` | the host stopped answering while the window was open | it has been stopped; report it with a `--diagnostics debug` log |
| `error: unexpected argument ...` (no code) | a typo in an option | `nativehtmlkit <command> --help` |

## Check the installation

<!-- test: exit=0 calls="0@none" -->
```powershell
nativehtmlkit doctor
```

If that fails with `host.not_found`, the host is not beside the CLI. Copying only
`nativehtmlkit.exe` somewhere else is the usual cause:

<!-- test: exit=1 shim=off requires=windows -->
```powershell
New-Item -ItemType Directory -Path lonely | Out-Null
Copy-Item -Path (Get-Command nativehtmlkit).Source -Destination lonely\
$env:PATH = "$env:SystemRoot\System32"
.\lonely\nativehtmlkit.exe doctor
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: NativeHTMLKit Core host not found. Install a qualified release beside the CLI or set NATIVEHTMLKIT_HOST_BINARY.
```

Which `nativehtmlkit` PowerShell runs, if there are several:

<!-- test: exit=0 shim=off -->
```powershell
@(Get-Command nativehtmlkit -All | ForEach-Object { $_.CommandType }) | Select-Object -First 1
```

<!-- stdout -->
```text
Application
```

## Encoding problems

Symptoms: `?` instead of letters, or `invalid JSON input` for JSON that looks fine. After
the [UTF-8 setup](index.md#set-up-utf-8-once) the session sends UTF-8 without a byte-order
mark:

<!-- test: exit=0 calls="" -->
```powershell
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
"sending: $($OutputEncoding.WebName), BOM: $($OutputEncoding.GetPreamble().Length -gt 0)"
```

<!-- stdout -->
```text
sending: utf-8, BOM: False
```

Without it, Windows PowerShell 5.1 sends `us-ascii` (PowerShell 7 sends UTF-8):

<!-- test: exit=0 calls="" requires=ps51 -->
```powershell
"default: $($OutputEncoding.WebName)"
```

<!-- stdout -->
```text
default: us-ascii
```

## Input problems

An empty pipeline (the previous command found nothing). Check before calling `select`:

<!-- test: exit=0 calls="" -->
```powershell
$files = @(Get-ChildItem -Filter *.nothing-here)
if ($files.Count -eq 0) { 'no files to choose from'; exit 0 }
$files | ForEach-Object Name | nativehtmlkit select
```

<!-- stdout -->
```text
no files to choose from
```

Too large to display. The message says how many rows fit at this width:

<!-- test: exit=1 calls="1@none" -->
```powershell
$row = [ordered]@{}; 0..15 | ForEach-Object { $row["c$_"] = 'v' }
$rows = 1..1871 | ForEach-Object { [pscustomobject] $row }
ConvertTo-Json -InputObject $rows -Compress | nativehtmlkit select --input-format json --multi
```

<!-- stderr -->
```text
at most 1870 rows fit
```

Long lines push a page over 1 MiB; shorten them first:

<!-- test: exit=1 calls="1@none" -->
```powershell
1..2000 | ForEach-Object { "$_".PadLeft(600, '0') } | nativehtmlkit view
```

<!-- stderr -->
```text
the host accepts 1048576 (1 MiB)
```

<!-- test: exit=124 calls="124@2000x1" -->
```powershell
1..2000 | ForEach-Object { "$_".PadLeft(600, '0') } |
    ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } } | nativehtmlkit view
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
([exit codes and scripting](exit-codes-and-scripting.md#timeout-is-for-people)).

## Get a log to report a problem

<!-- test: exit=0 calls="124@2x1" -->
```powershell
$env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = 'report-1'
$log = 'a', 'b' | nativehtmlkit --diagnostics trace select 2>&1 | ForEach-Object { "$_" }
[IO.File]::WriteAllLines((Join-Path (Get-Location) 'report.log'), [string[]] $log)
$log | Where-Object { $_ -like '*"component":"nativehtmlkit-cli"*' } | Select-Object -First 3 |
    ForEach-Object { $r = ConvertFrom-Json -InputObject $_; "$($r.role) $($r.event)" }
exit 0
```

<!-- stdout -->
```text
launcher session.started
launcher host.spawned
backend backend.started
```

The CLI's records contain no data from your input; the host's records (also in the file)
are a separate log, review them before you share it. More in
[environment and diagnostics](environment-and-diagnostics.md).
