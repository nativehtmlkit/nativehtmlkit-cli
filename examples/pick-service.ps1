<#
pick-service.ps1 - choose Windows services and start, stop or restart them.

Teaches: a Windows-only workflow: Get-Service -> JSON table, multi-select, an action chosen
in a second window, and -WhatIf through SupportsShouldProcess. Changing services needs an
elevated session.

Run:   .\pick-service.ps1 [-Name 'w*'] [-WhatIf]
Needs: Windows, nativehtmlkit on PATH.
Exit:  0 done, 2 cancelled, 124 no decision in time, 1 error.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string] $Name = '*')
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Invoke-Picker {
    $out = $input | nativehtmlkit @args
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Nothing changed.'; exit $LASTEXITCODE }
    $out -join "`n"
}

try {
    $rows = @(Get-Service -Name $Name | Sort-Object DisplayName | Select-Object -First 2000 |
        Select-Object Name, DisplayName, @{ n = 'Status'; e = { "$($_.Status)" } }, @{ n = 'Start type'; e = { "$($_.StartType)" } })
    if ($rows.Count -eq 0) { Write-Host "No service matches $Name."; exit 0 }

    # ForEach-Object unrolls the array: Windows PowerShell 5.1 returns a JSON array as one object.
    $picked = @(ConvertFrom-Json -InputObject ($rows | ConvertTo-Json -Compress |
        Invoke-Picker select --multi --input-format json --output-format json --title 'Services') | ForEach-Object { $_ })
    $action = 'Restart', 'Stop', 'Start' | Invoke-Picker select --title "Action for $($picked.Count) service(s)"

    foreach ($service in $picked) {
        if ($PSCmdlet.ShouldProcess($service.DisplayName, "$action service")) {
            switch ($action) {
                'Restart' { Restart-Service -Name $service.Name }
                'Stop'    { Stop-Service -Name $service.Name }
                'Start'   { Start-Service -Name $service.Name }
            }
        }
    }
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
