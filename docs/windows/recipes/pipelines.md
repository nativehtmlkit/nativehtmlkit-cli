# Multi-select in pipelines (Windows)

`select --multi` writes one line per chosen row, in input order, and nothing at all on
Cancel or a timeout. In PowerShell it sits between commands as a filter; check
`$LASTEXITCODE` before acting on what came out. Script:
[examples/search-selected.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/search-selected.ps1) (the counterpart of
`grep-selected.sh`).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Search only the files you tick

<!-- test: exit=124 calls="124@*x1" -->
```powershell
.\search-selected.ps1 -Pattern 'nativehtmlkit view' -Path .
```

The window lists the files under `.` as relative paths (at most 2,000). Suppose the user
ticks two scripts:

<!-- replay: call=1 exit=0 expect=0 -->
```text
csv-report.ps1
view-logs.ps1
```

<!-- stdout -->
```text
csv-report.ps1:20:        $text | nativehtmlkit view --input-format csv --title $title
view-logs.ps1:25:            nativehtmlkit view --title "Log: $(Split-Path -Leaf $Path)"
view-logs.ps1:32:            nativehtmlkit view --input-format json --title "Events: $LogName"
```

After Cancel the script exits 2 and nothing is searched:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: search-selected: cancelled
```

## The pattern

<!-- test: exit=0 calls="124@2x1" -->
```powershell
'first' | Set-Content one.log; 'second' | Set-Content two.log
$chosen = Get-ChildItem *.log | ForEach-Object Name | nativehtmlkit select --multi --title 'Compress'
if ($LASTEXITCODE -eq 0) { $chosen | ForEach-Object { Compress-Archive -LiteralPath $_ -DestinationPath "$_.zip" } }
@(Get-ChildItem *.zip).Count
exit 0
```

<!-- stdout -->
```text
0
```

- Check `$LASTEXITCODE` first: after Cancel or a timeout the variable is `$null`, and
  `$null | ForEach-Object` would still run once in Windows PowerShell 5.1 with `$_` empty.
- Use `-LiteralPath` with the chosen names, so `[` and `]` are not wildcards.
- Send at most 2,000 rows (`Select-Object -First 2000`): more is an error, not a cut.
- Names containing line breaks cannot be represented in `lines`; use JSON.

## Rows with several fields

Choose an output format that keeps the fields apart, then work with objects:

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$json = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
if ($LASTEXITCODE -ne 0) { exit 0 }
foreach ($server in @(ConvertFrom-Json -InputObject ($json -join "`n") | ForEach-Object { $_ })) {
    "would restart $($server.role) on $($server.host)"
}
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"host":"api-01","role":"backend","region":"eu-west","cpu_cores":"8","memory_gib":"32","status":"healthy","notes":""},{"host":"cache-01","role":"cache","region":"eu-west","cpu_cores":"2","memory_gib":"16","status":"healthy","notes":""}]
```

<!-- stdout -->
```text
would restart backend on api-01
would restart cache on cache-01
```

One `Test-Connection` (or any command) per chosen host:

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$json = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
if ($LASTEXITCODE -eq 0) {
    (ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { "checking $($_.host)" }
}
exit 0
```

Linux: [Multi-select in pipelines and xargs (Linux)](../../linux/recipes/pipelines.md).
