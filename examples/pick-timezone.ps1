<#
pick-timezone.ps1 - choose a time zone from a long list in a light-themed window.

Teaches: restyling the CLI's window with a trusted --css file (css/light.css overrides the
page's colour custom properties), a table built from .NET objects, and returning one field
of the chosen row. The PowerShell counterpart of pick-timezone.sh.

Run:   .\pick-timezone.ps1                       prints the zone id, e.g. Tokyo Standard Time
       $zone = .\pick-timezone.ps1; [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $zone)
Needs: nativehtmlkit on PATH.
Exit:  0 printed the zone, 2 cancelled, 124 no decision in time, 1 error.
#>
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    $rows = @([TimeZoneInfo]::GetSystemTimeZones() | Select-Object -First 2000 | ForEach-Object {
        $offset = $_.BaseUtcOffset
        [pscustomobject]@{
            Id     = $_.Id
            Offset = '{0}{1:hh\:mm}' -f $(if ($offset -lt [TimeSpan]::Zero) { '-' } else { '+' }), $offset
            Name   = $_.DisplayName
        }
    })
    $json = $rows | ConvertTo-Json -Compress |
        nativehtmlkit select --input-format json --output-format json --title 'Time zone' `
            --css (Join-Path $PSScriptRoot 'css/light.css')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    (ConvertFrom-Json -InputObject ($json -join "`n"))[0].Id
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
