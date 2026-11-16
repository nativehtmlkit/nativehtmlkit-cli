# view: show records read-only (Windows)

`nativehtmlkit view` shows the records piped into it in a window with a single **Close**
button. It never writes to stdout. Plain lines are shown as one wrapping, scrolling text
block; every other input format as a table. Exact rules:
[OS-neutral reference](../../reference/view.md).

```text
nativehtmlkit view [OPTIONS] < records
```

| Outcome | `$LASTEXITCODE` | stdout |
|---|---|---|
| **Close**, or the window closed | 0 | empty |
| `--timeout` expired | 124 | empty |
| error | 1 | empty; `nativehtmlkit: error[<code>]: ...` on stderr |

`view` blocks until the window is closed. Unlike `select` it accepts **no records**: an
empty viewer is fine. It has no `--multi`, `--allow-empty` or `--output-format`.

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Without options: text

<!-- test: exit=124 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view
```

Markup in the text is shown literally: the `<script>` in that log stays text. Any command
output works; `Out-String -Stream` turns formatted objects into lines first:

<!-- test: exit=124 calls="124@*x1" -->
```powershell
Get-Process | Sort-Object CPU -Descending | Select-Object -First 30 |
    Format-Table Id, ProcessName, CPU -AutoSize | Out-String -Stream -Width 200 | nativehtmlkit view
```

Nothing to show is not an error:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
@() | nativehtmlkit view
```

## `--input-format FORMAT`

`lines` (default), `csv`, `tsv`, `json`, `ndjson`; every format except `lines` is shown as a
table ([input formats](../input-formats.md)):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit view --input-format csv
```

<!-- test: exit=124 calls="124@3x7" -->
```powershell
Get-Content data\app.ndjson | nativehtmlkit view --input-format ndjson
```

<!-- test: exit=124 calls="124@4x7" -->
```powershell
Get-Content -Raw data\issues.json | nativehtmlkit view --input-format json
```

`issues.json` has nested values (`user`, `labels`): they appear as compact JSON in their
cells. Reshape the objects first for a readable table:

<!-- test: exit=124 calls="124@4x4" -->
```powershell
Get-Content -Raw data\issues.json | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object {
    [pscustomobject]@{ '#' = $_.number; Title = $_.title; Author = $_.user.login; Labels = ($_.labels.name -join ', ') }
} | ConvertTo-Json -Compress | nativehtmlkit view --input-format json
```

(`ForEach-Object { $_ }` unrolls the array: Windows PowerShell 5.1 passes a parsed JSON
array down the pipeline as one object.)

<!-- test: exit=124 calls="124@2x3" -->
```powershell
"name`tsize`tmodified", "report.pdf`t120 KiB`t2026-11-14", "notes.txt`t2 KiB`t2026-11-16" |
    nativehtmlkit view --input-format tsv
```

## `--no-headers`

For `csv`/`tsv` without a header row; columns are named `column_1` ... `column_N`:

<!-- test: exit=124 calls="124@3x3" -->
```powershell
'alice,admin,2026-01-04', 'bob,dev,2026-03-17', 'carol,ops,2026-06-30' |
    nativehtmlkit view --input-format csv --no-headers
```

## `--title TITLE`

Window title and heading (default `Output viewer`), 1-128 characters, shown as text:

<!-- test: exit=124 calls="124@5x1" -->
```powershell
$lines = Get-Content data\app.log
$lines | nativehtmlkit view --title "app.log ($($lines.Count) lines)"
```

## `--css FILE`

A trusted style sheet added after the built-in one ([CSS and forms](../css-and-forms.md)):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit view --input-format csv --css css/light.css
```

## `--timeout SECONDS`

Close the viewer by itself after a while. Exit 0 (closed) and 124 (deadline) both mean
"done looking", so a script can carry on after either:

<!-- test: exit=0 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --timeout 300 --title 'Build log'
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 124) { exit 1 }
'continuing'
exit 0
```

<!-- stdout -->
```text
continuing
```

## `--host PATH`

<!-- test: exit=124 calls="0@none 124@1x1" -->
```powershell
$coreHost = (nativehtmlkit doctor | Select-String '^Core host: (.+)$').Matches[0].Groups[1].Value
'pinned host' | nativehtmlkit view --host $coreHost
```

## `--diagnostics LEVEL`

<!-- test: exit=0 calls="124@1x1" -->
```powershell
$log = 'hello' | nativehtmlkit view --diagnostics debug 2>&1 | ForEach-Object { "$_" }
$started = $log | Where-Object { $_ -like '*"event":"session.started"*' } | ForEach-Object { ConvertFrom-Json -InputObject $_ }
"$($started.context.mode) $($started.context.rows)x$($started.context.columns)"
exit 0
```

<!-- stdout -->
```text
view 1x1
```

## `--rpc-timeout SECONDS`, `--liveness-interval SECONDS`, `--startup-timeout SECONDS`

The host watchdogs (defaults 30, 5 and 15 seconds). They limit how long the CLI waits for
a *host* that stopped working, never the person reading
([global options](../../reference/global-options.md#host-watchdogs---rpc-timeout---liveness-interval---startup-timeout)):

<!-- test: exit=124 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --rpc-timeout 10
```

<!-- test: exit=124 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --liveness-interval 10
```

<!-- test: exit=124 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --startup-timeout 45
```

## `-h`, `--help`

<!-- test: exit=0 shim=off -->
```powershell
(nativehtmlkit view --help | Select-String -SimpleMatch -- '--no-headers').Line
```

<!-- stdout -->
```text
      --no-headers
```

## Options that `view` does not have

<!-- test: exit=1 calls="1@none" -->
```powershell
'a' | nativehtmlkit view --multi
```

<!-- stderr -->
```text
error: unexpected argument '--multi' found
```

## Limits

At most 2,000 lines or records, 32 columns and an 8 MiB stdin; the generated page must stay
under 1 MiB. More is an error, never a silent truncation, so cut first:

<!-- test: exit=124 calls="124@2000x1" -->
```powershell
1..100000 | Select-Object -Last 2000 | nativehtmlkit view --title 'last 2000'
```

<!-- test: exit=1 calls="1@none" -->
```powershell
1..2001 | nativehtmlkit view
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: 2001 rows exceeds the 2000-row initial GUI limit
```

See [view logs](../recipes/logs.md) for long lines and the Windows event log, and the
[limits reference](../../reference/limits.md).

## Related

[select](select.md), [form](form.md), [doctor](doctor.md), [recipes](../recipes/index.md).
