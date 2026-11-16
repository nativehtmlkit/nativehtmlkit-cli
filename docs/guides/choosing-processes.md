# Choose processes to stop

Scripts: [examples/kill-process.sh](../../examples/kill-process.sh) (Linux, procps `ps`) and
[examples/stop-process.ps1](../../examples/stop-process.ps1) (Windows PowerShell 5.1,
PowerShell 7 on Windows and Linux).

## bash: `ps` to CSV, pick, choose the signal

`ps` output is whitespace-aligned and the command line contains spaces, so convert it to CSV
with the free-text field quoted (and any `"` doubled, as CSV requires). Take the snapshot
before filtering it, otherwise the filter process would list itself:

```bash
listing=$(ps -eo pid=,user=,pcpu=,pmem=,etime=,args= --sort=-pcpu)
rows=$(awk -v filter="$filter" -v self=$$ '
    BEGIN { print "PID,User,CPU %,Mem %,Running,Command" }
    $1 == self || n >= 500 { next }
    {
      cmd = $6; for (i = 7; i <= NF; i++) cmd = cmd " " $i
      if (filter != "" && index(cmd, filter) == 0) next
      if (length(cmd) > 160) cmd = substr(cmd, 1, 157) "..."
      gsub(/"/, "\"\"", cmd)
      printf "%s,%s,%s,%s,%s,\"%s\"\n", $1, $2, $3, $4, $5, cmd; n++
    }' <<<"$listing")

picked=$(nativehtmlkit select --multi --input-format csv --output-format json \
           --title "Processes to signal" <<<"$rows") || exit
mapfile -t pids < <(jq -r '.[].PID' <<<"$picked")
```

`--output-format json` turns each CSV row into an object keyed by the header, so
`.[].PID` reads the column by name. A second `select` chooses the signal:

```bash
signal=$(printf 'TERM  - ask the process to exit\nINT   - like Ctrl+C\nKILL  - force, cannot be caught\n' |
         nativehtmlkit select --title "Signal for ${#pids[@]} process(es)") || exit
kill -s "${signal%% *}" -- "${pids[@]}"
```

## PowerShell: choose the properties first

```powershell
$rows = @(Get-Process -Name $Name -ErrorAction SilentlyContinue |
    Where-Object Id -ne $PID | Sort-Object CPU -Descending | Select-Object -First 500 |
    Select-Object Id, ProcessName,
        @{ n = 'CPU (s)'; e = { [math]::Round($_.CPU, 1) } },
        @{ n = 'Memory (MiB)'; e = { [math]::Round($_.WorkingSet64 / 1MB) } })
$json = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Processes to stop'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
foreach ($p in @(ConvertFrom-Json -InputObject ($json -join "`n"))) {
    if ($PSCmdlet.ShouldProcess("$($p.ProcessName) ($($p.Id))", 'Stop process')) { Stop-Process -Id $p.Id }
}
```

A raw `Process` object serialises to far more than the 32 columns the CLI accepts (and takes
long to convert); `Select-Object` keeps the table readable and fast. `-WhatIf` lists what
would be stopped.
