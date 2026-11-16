# Choose processes to stop (Windows)

Pick processes in a table and stop exactly those. Script:
[examples/stop-process.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/stop-process.ps1); it supports `-WhatIf` and `-Confirm`
and also runs in PowerShell 7 on Linux.

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Run it

Offer the processes of the PowerShell you are using (the script leaves itself out):

<!-- test: exit=124 calls="124@*x4" -->
```powershell
.\stop-process.ps1 -Name (Get-Process -Id $PID).ProcessName
```

The table shows `Id`, `ProcessName`, `CPU (s)` and `Memory (MiB)`. With `-WhatIf`, a
Submit shows what would be stopped and stops nothing:

<!-- test: exit=124 calls="124@*x4" -->
```powershell
.\stop-process.ps1 -Name (Get-Process -Id $PID).ProcessName -WhatIf
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"Id":4242,"ProcessName":"demo","CPU (s)":0.4,"Memory (MiB)":35}]
```

<!-- stdout -->
```text
What if: Performing the operation "Stop process" on target "demo (4242)".
```

After Cancel nothing is stopped:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: Nothing stopped.
```

No match: the script exits 0 without a window:

<!-- test: exit=0 calls="" -->
```powershell
.\stop-process.ps1 -Name no-such-process-42
```

<!-- stdout -->
```text
No process matches no-such-process-42.
```

## How it works

A raw `Process` object has far more properties than the 32 columns the CLI accepts, and
converting it is slow; `Select-Object` keeps the table small and readable:

<!-- not-tested: excerpt of examples/stop-process.ps1, which is run above -->
```powershell
$rows = @(Get-Process -Name $Name -ErrorAction SilentlyContinue |
    Where-Object Id -ne $PID |
    Sort-Object CPU -Descending | Select-Object -First 500 |
    Select-Object Id, ProcessName,
        @{ n = 'CPU (s)'; e = { [math]::Round($_.CPU, 1) } },
        @{ n = 'Memory (MiB)'; e = { [math]::Round($_.WorkingSet64 / 1MB) } })
$json = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Processes to stop'
if ($LASTEXITCODE -ne 0) { Write-Warning 'Nothing stopped.'; exit $LASTEXITCODE }
```

Each chosen object then goes through `$PSCmdlet.ShouldProcess(...)` and `Stop-Process -Id`.

Linux: [Choose processes to signal (Linux)](../../linux/recipes/processes.md).
