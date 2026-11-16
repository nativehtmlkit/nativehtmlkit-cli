# View logs and events (Windows)

Show a text log in a scrolling, wrapping pane, or the newest Windows events as a table.
`view` has no result: closing it exits 0. Script:
[examples/view-logs.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/view-logs.ps1), samples [data/app.log](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/app.log) and
[data/app.ndjson](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/app.ndjson).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Text files

<!-- test: exit=124 calls="124@5x1" -->
```powershell
.\view-logs.ps1 -Path data\app.log
```

The script shows the last 1,000 lines (`-Lines` changes that), each cut to 400 characters.
Markup in log lines is shown literally. The same without the script:

<!-- test: exit=124 calls="124@5x1" -->
```powershell
Get-Content -LiteralPath data\app.log -Tail 1000 -Encoding UTF8 |
    ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } } |
    nativehtmlkit view --title 'app.log'
```

Two limits matter for logs ([limits](../../reference/limits.md)): at most **2,000 lines**
(more is an error, so use `-Tail`), and the page must stay under **1 MiB** (2,000 lines of
500 characters fit, 600 do not):

<!-- test: exit=124 calls="124@1000x1" -->
```powershell
$long = Join-Path (Get-Location) 'long.log'
[IO.File]::WriteAllLines($long, [string[]] (1..3000 | ForEach-Object { 'line {0}: {1}' -f $_, ('x' * 700) }))
.\view-logs.ps1 -Path $long
```

## The Windows event log

<!-- test: exit=124 calls="124@*x5" requires=windows -->
```powershell
.\view-logs.ps1 -LogName System
```

The newest 200 events with `Time`, `Level`, `Id`, `ProviderName` and the first line of the
`Message`:

<!-- not-tested: excerpt of examples/view-logs.ps1, which is run above -->
```powershell
Get-WinEvent -LogName $LogName -MaxEvents 200 |
    Select-Object @{ n = 'Time'; e = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
        @{ n = 'Level'; e = { $_.LevelDisplayName } }, Id, ProviderName,
        @{ n = 'Message'; e = { ("$($_.Message)" -split "`r?`n")[0] } } |
    ConvertTo-Json -Compress |
    nativehtmlkit view --input-format json --title "Events: $LogName"
```

Only errors and warnings of the last day:

<!-- test: exit=124 calls="124@*x4" requires=windows -->
```powershell
$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 500 -ErrorAction SilentlyContinue |
    Select-Object @{ n = 'Time'; e = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
        @{ n = 'Level'; e = { $_.LevelDisplayName } }, Id, ProviderName)
if ($events.Count -eq 0) { $events = @([pscustomobject]@{ Time = ''; Level = ''; Id = ''; ProviderName = 'no errors or warnings' }) }
ConvertTo-Json -InputObject $events -Compress | nativehtmlkit view --input-format json --title 'System: errors and warnings'
```

## JSON lines

<!-- test: exit=124 calls="124@3x3" -->
```powershell
Get-Content data\app.ndjson | ForEach-Object {
    $r = ConvertFrom-Json -InputObject $_
    [pscustomobject]@{ time = $r.time; level = $r.level; msg = $r.msg } | ConvertTo-Json -Compress
} | nativehtmlkit view --input-format ndjson --title 'app.ndjson'
```

## Keep the script going

`view` blocks until the window is closed. Exit 0 (closed) and 124 (`--timeout`) both mean
"done looking":

<!-- test: exit=0 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --timeout 300 --title 'Build log'
if ($LASTEXITCODE -notin 0, 124) { exit 1 }
'next step'
exit 0
```

<!-- stdout -->
```text
next step
```

Linux: [View logs (Linux)](../../linux/recipes/logs.md).
