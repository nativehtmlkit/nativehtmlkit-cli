# Review and export CSV reports (Windows)

Look at a CSV file in a table, or tick rows and export them as a new CSV file. Script:
[examples/csv-report.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/csv-report.ps1), sample [examples/data/servers.csv](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/servers.csv).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Look at it

<!-- test: exit=124 calls="124@7x7" -->
```powershell
.\csv-report.ps1 -Report data\servers.csv
```

The first record is the header; quoted fields are shown unquoted. Without the script:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit view --input-format csv --title 'Servers'
```

## Export the rows you tick

<!-- test: exit=124 calls="124@7x7" -->
```powershell
.\csv-report.ps1 -Report data\servers.csv -Output degraded.csv
"degraded.csv exists: $(Test-Path degraded.csv)"
exit $LASTEXITCODE
```

On Cancel or a timeout no file is written:

<!-- stdout -->
```text
WARNING: No decision in time; degraded.csv not written.
degraded.csv exists: False
```

After ticking `web-02` and Submit:

<!-- replay: call=1 exit=0 expect=0 -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
web-02,frontend,eu-west,4,8,degraded,"disk 91% full, cleanup scheduled"
```

<!-- stdout -->
```text
Wrote 1 row(s) to degraded.csv
degraded.csv exists: True
```

The script sends the file's text unchanged and writes the result as UTF-8 without a BOM:

<!-- not-tested: excerpt of examples/csv-report.ps1, which is run above -->
```powershell
$text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Report).ProviderPath, [Text.Encoding]::UTF8)
$csv = $text | nativehtmlkit select --multi --input-format csv --output-format csv --title 'Rows to export'
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
[IO.File]::WriteAllText($target, (($csv -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
```

## Other shapes of the same rows

Objects instead of text: ask for JSON, or read the CSV result with `ConvertFrom-Csv`:

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$json = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
if ($LASTEXITCODE -eq 0) { (ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { $_.host } }
exit 0
```

A file without a header row needs `--no-headers` (columns `column_1`, ...):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | Select-Object -Skip 1 | nativehtmlkit view --input-format csv --no-headers
```

Semicolon-separated files: convert with `Import-Csv -Delimiter ';' | ConvertTo-Csv
-NoTypeInformation` ([input formats](../input-formats.md#csv)).

Linux: [Review and export CSV reports (Linux)](../../linux/recipes/csv-report.md).
