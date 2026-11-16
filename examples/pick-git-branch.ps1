<#
pick-git-branch.ps1 - choose a local Git branch in a native window and switch to it.

Teaches: objects -> ConvertTo-Json -> `select --input-format json`, reading the JSON result
back with ConvertFrom-Json, and handling Cancel (2) and --timeout (124) through
$LASTEXITCODE. Works in Windows PowerShell 5.1 and PowerShell 7.

Run:   .\pick-git-branch.ps1 [-Repository <dir>]
Needs: nativehtmlkit on PATH, git.
Exit:  0 switched, 2 cancelled, 124 no choice before the deadline, 1 error.
#>
param([string] $Repository = '.')
$ErrorActionPreference = 'Stop'

# The CLI reads and writes UTF-8. Windows PowerShell 5.1 would otherwise send ASCII to it
# and decode its output with the console code page. Restored at the end.
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    $format = '%(HEAD)%09%(refname:short)%09%(committerdate:relative)%09%(upstream:short)%09%(subject)'
    $rows = @(git -C $Repository for-each-ref --sort=-committerdate "--format=$format" refs/heads |
        ForEach-Object {
            $f = $_ -split "`t", 5
            [pscustomobject]@{ Current = $f[0]; Branch = $f[1]; Updated = $f[2]; Upstream = $f[3]; 'Last commit' = $f[4] }
        })
    if ($rows.Count -eq 0) { Write-Error "no local branches in $Repository" }

    $picked = $rows | ConvertTo-Json -Compress |
        nativehtmlkit select --input-format json --output-format json --title 'Switch branch' --timeout 120
    switch ($LASTEXITCODE) {
        0       { }
        2       { Write-Warning 'Cancelled; staying on the current branch.'; exit 2 }
        124     { Write-Warning 'No branch chosen within 120 s.'; exit 124 }
        default { exit $LASTEXITCODE }    # the CLI already printed "nativehtmlkit: error[...]"
    }

    # -InputObject keeps a one-element JSON array an array in both PowerShell editions.
    $branch = (ConvertFrom-Json -InputObject ($picked -join "`n"))[0].Branch
    git -C $Repository switch $branch
    exit $LASTEXITCODE
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
