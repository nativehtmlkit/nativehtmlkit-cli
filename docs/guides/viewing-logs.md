# View logs

`view` shows text in a scrolling, wrapping pane and structured records as a table. It has no
result: closing it exits 0. Scripts: [examples/view-logs.sh](../../examples/view-logs.sh),
[examples/view-logs.ps1](../../examples/view-logs.ps1).

## Plain text

```bash
tail -n 1000 app.log | perl -CSD -pe 's/^(.{400}).+/$1.../' | nativehtmlkit view --title 'app.log'
journalctl -n 500 --no-pager | ./examples/view-logs.sh -
```

Two limits matter for logs ([limits](../reference/limits.md)):

- at most **2,000 lines** (more is an error, not a truncation): use `tail -n`. Note that
  `journalctl -n 500` counts *entries*, and one entry can span many lines;
- the generated page must stay under **1 MiB**: 2,000 lines of 500 characters fit, of 600 do
  not. Shorten long lines by characters (the `perl -CSD` above), not with `cut -c`, which
  counts bytes and could split a UTF-8 sequence; invalid UTF-8 is refused.

Markup in log lines is shown literally (`<script>` stays text).

## JSON lines

```bash
tail -n 1000 app.ndjson | nativehtmlkit view --input-format ndjson --title 'app.ndjson'
```

Columns are the union of all keys in order of first appearance (at most 32); nested objects
appear as compact JSON. Do not shorten JSON lines: a cut line is invalid JSON. To select
columns, reshape first: `jq -c '{time, level, msg}'`.

## Windows event logs

```powershell
Get-WinEvent -LogName System -MaxEvents 200 |
    Select-Object @{ n = 'Time'; e = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
        @{ n = 'Level'; e = { $_.LevelDisplayName } }, Id, ProviderName,
        @{ n = 'Message'; e = { ("$($_.Message)" -split "`r?`n")[0] } } |
    ConvertTo-Json -Compress |
    nativehtmlkit view --input-format json --title 'Events: System'
```

Text files in PowerShell:

```powershell
Get-Content -LiteralPath .\app.log -Tail 1000 -Encoding UTF8 |
    ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } } |
    nativehtmlkit view --title 'app.log'
```

## Keep the script going

`view` blocks until the window is closed. Exit 0 (closed) and 124 (`--timeout`) both mean
"done looking"; treat only other statuses as errors:

```bash
nativehtmlkit view --timeout 300 --title 'Build log' < build.log || [[ $? -eq 124 ]] || exit 1
```
