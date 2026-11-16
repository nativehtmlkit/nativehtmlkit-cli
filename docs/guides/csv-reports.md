# Review and export CSV reports

Scripts: [examples/csv-report.sh](../../examples/csv-report.sh),
[examples/csv-report.ps1](../../examples/csv-report.ps1); sample
[examples/data/servers.csv](../../examples/data/servers.csv).

## Look at it

```bash
nativehtmlkit view --input-format csv --title 'Servers' < examples/data/servers.csv
```

The first record is the header. Quoted fields (`"disk 91% full, cleanup scheduled"`,
`"canary for ""v2"" API"`) are shown unquoted. A file without a header row:
`--no-headers` (columns `column_1`, `column_2`, ...). Semicolon-separated files are not
supported; convert them first (for example with `python3 -c` and the `csv` module, or
`Import-Csv -Delimiter ';' | ConvertTo-Csv` in PowerShell).

## Export the rows you tick

`--output-format csv` writes the header and the chosen records, re-quoted where needed, in
input order. Write through a temporary file so Cancel leaves no empty output file:

```bash
tmp=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
status=0
nativehtmlkit select --multi --input-format csv --output-format csv \
  --title "Rows to export" <"$report" >"$tmp" || status=$?
[[ $status -eq 0 ]] && mv -- "$tmp" "$output"
exit "$status"
```

Other useful output formats for the same input:

| `--output-format` | You get |
|---|---|
| `json` | `[{"host":"web-02","role":"frontend",...}]`: all values are strings |
| `tsv` | header and rows, tab-separated |
| `lines` | each row's fields joined with a tab, no header; refused if a field holds a line break |

```bash
# only the host names of the chosen rows
nativehtmlkit select --multi --input-format csv --output-format json < servers.csv | jq -r '.[].host'
```

## PowerShell

Send the file's text unchanged; let the CLI parse it:

```powershell
$text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Report).ProviderPath, [Text.Encoding]::UTF8)
$csv = $text | nativehtmlkit select --multi --input-format csv --output-format csv --title 'Rows to export'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
[IO.File]::WriteAllText($target, (($csv -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
```

`[IO.File]::WriteAllText` with `UTF8Encoding($false)` writes UTF-8 without a BOM in both
PowerShell editions (`Set-Content -Encoding UTF8` adds a BOM in Windows PowerShell 5.1).
To work with the chosen rows as objects instead, ask for JSON:
`... --output-format json` then `ConvertFrom-Json -InputObject ($json -join "`n")`.
