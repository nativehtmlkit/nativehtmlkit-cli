<#
pick-from-api.ps1 - choose issues from a JSON API response and output their URLs.

Teaches: Invoke-RestMethod (or a saved response) -> flat objects -> JSON rows, keeping a
`url` column for the follow-up step, multi-select, and emitting plain strings so the script
can feed another command.

Run:   .\pick-from-api.ps1 -Uri 'https://api.github.com/repos/OWNER/REPO/issues?per_page=100'
       .\pick-from-api.ps1 -Path data\issues.json      (the sample response in this folder)
Needs: nativehtmlkit on PATH.
Exit:  0 printed the chosen URLs, 2 cancelled, 124 no decision in time, 1 error.
#>
param([string] $Uri, [string] $Path)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    $response = if ($Path) {
        ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [Text.Encoding]::UTF8))
    } else {
        Invoke-RestMethod -Uri $Uri -Headers @{ Accept = 'application/vnd.github+json' }
    }
    # GitHub lists pull requests as issues too; they carry a pull_request property.
    $rows = @($response | Where-Object { -not $_.PSObject.Properties['pull_request'] } | ForEach-Object {
        [pscustomobject]@{
            '#'     = $_.number
            Title   = $_.title
            Author  = $_.user.login
            Labels  = ($_.labels.name -join ', ')
            # PowerShell 7 turns ISO dates into [datetime]; Windows PowerShell keeps the text.
            Updated = if ($_.updated_at -is [datetime]) { $_.updated_at.ToString('yyyy-MM-dd') } else { "$($_.updated_at)".Substring(0, 10) }
            url     = $_.html_url
        }
    })
    if ($rows.Count -eq 0) { Write-Host 'The response contains no issues.'; exit 0 }

    $json = $rows | ConvertTo-Json -Compress |
        nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    (ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { $_.url }
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
