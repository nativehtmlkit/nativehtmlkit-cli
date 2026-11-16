# Restart, stop or start Windows services (Windows only)

Pick services in a table, then the action to apply to them. Script:
[examples/pick-service.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-service.ps1); it supports `-WhatIf` and `-Confirm`.
Changing services needs an elevated PowerShell. This recipe has no Linux counterpart
(`systemctl` units would be the equivalent).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Run it

<!-- test: exit=124 calls="124@*x4" requires=windows -->
```powershell
.\pick-service.ps1 -Name 'w*'
```

The table shows `Name`, `DisplayName`, `Status` and `Start type`. After a Submit a second
window offers **Restart**, **Stop** and **Start**. With `-WhatIf` nothing is changed:

<!-- test: exit=124 calls="124@*x4" requires=windows -->
```powershell
.\pick-service.ps1 -Name 'w*' -WhatIf
```

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"W32Time","DisplayName":"Windows Time","Status":"Running","Start type":"Manual"}]
```

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Restart
```

<!-- stdout -->
```text
What if: Performing the operation "Restart service" on target "Windows Time".
```

No match: the script exits 0 without a window:

<!-- test: exit=0 calls="" requires=windows -->
```powershell
.\pick-service.ps1 -Name 'no-such-service-*'
```

<!-- stdout -->
```text
No service matches no-such-service-*.
```

## How it works

`ConvertTo-Json` writes enums such as `Status` as numbers, so the script turns them into
strings first:

<!-- not-tested: excerpt of examples/pick-service.ps1, which is run above -->
```powershell
$rows = @(Get-Service -Name $Name | Sort-Object DisplayName | Select-Object -First 2000 |
    Select-Object Name, DisplayName, @{ n = 'Status'; e = { "$($_.Status)" } }, @{ n = 'Start type'; e = { "$($_.StartType)" } })
$picked = @(ConvertFrom-Json -InputObject ($rows | ConvertTo-Json -Compress |
    Invoke-Picker select --multi --input-format json --output-format json --title 'Services') | ForEach-Object { $_ })
$action = 'Restart', 'Stop', 'Start' | Invoke-Picker select --title "Action for $($picked.Count) service(s)"
```

A one-liner for a quick look at running services:

<!-- test: exit=124 calls="124@*x3" requires=windows -->
```powershell
Get-Service | Where-Object Status -eq 'Running' |
    Select-Object Name, DisplayName, @{ n = 'Status'; e = { "$($_.Status)" } } |
    ConvertTo-Json -Compress | nativehtmlkit view --input-format json --title 'Running services'
```
