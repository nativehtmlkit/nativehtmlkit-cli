<#
view-logs.ps1 - show the end of a log file, or recent Windows events, in a native viewer.

Teaches: `view` for plain text (Get-Content -Tail, lines shortened to stay inside the 1 MiB
page limit) and for structured records (Get-WinEvent -> Select-Object -> JSON table).

Run:   .\view-logs.ps1 -Path data\app.log
       .\view-logs.ps1 -LogName System            (Windows: the newest 200 events)
Needs: nativehtmlkit on PATH.
Exit:  0 viewer closed, 124 closed by the deadline, 1 error.
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')] [string] $Path,
    [Parameter(Mandatory, ParameterSetName = 'Event')] [string] $LogName,
    [int] $Lines = 1000
)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        Get-Content -LiteralPath $Path -Tail $Lines -Encoding UTF8 |
            ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } } |
            nativehtmlkit view --title "Log: $(Split-Path -Leaf $Path)"
    } else {
        Get-WinEvent -LogName $LogName -MaxEvents 200 |
            Select-Object @{ n = 'Time'; e = { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
                @{ n = 'Level'; e = { $_.LevelDisplayName } }, Id, ProviderName,
                @{ n = 'Message'; e = { ("$($_.Message)" -split "`r?`n")[0] } } |
            ConvertTo-Json -Compress |
            nativehtmlkit view --input-format json --title "Events: $LogName"
    }
    exit $LASTEXITCODE
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
