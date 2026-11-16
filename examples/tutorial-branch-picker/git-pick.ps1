<#
git-pick.ps1: choose a local Git branch in a native window and switch to it (CLI tutorial final code).

Teaches: objects -> ConvertTo-Json -> `select --input-format json`, reading the chosen records
back, handling every exit status (0 chosen, 2 cancelled, 124 timed out, anything else an
error), multi-select with --multi, and stopping the script cleanly from a helper function.
The PowerShell counterpart of git-pick.sh.

Run:   .\git-pick.ps1 [-Timeout SECONDS]                 switch to the chosen branch
       .\git-pick.ps1 -DeleteMerged [-Timeout SECONDS]   delete chosen branches already merged
       .\git-pick.ps1 -Print                             show the table that would be offered
       (inside a Git work tree; needs `nativehtmlkit` on PATH)
Guide: docs/windows/tutorial-branch-picker.md
#>
param([double] $Timeout = 0, [switch] $DeleteMerged, [switch] $Print)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# One object per branch, most recently committed first. JSON carries any character safely,
# so commit subjects need no clean-up.
function Get-BranchTable([string[]] $Filter) {
    git for-each-ref --sort=-committerdate '--format=%(refname:short)%09%(committerdate:relative)%09%(subject)' @Filter refs/heads/ |
        ForEach-Object {
            $f = $_ -split "`t", 3
            [pscustomobject]@{ branch = $f[0]; updated = $f[1]; 'last commit' = $f[2] }
        }
}

# Runs `nativehtmlkit select` on the rows and returns the chosen branch names. On anything
# but a submit it explains the status and ends the script with it.
function Select-Branch([object[]] $Rows, [string] $Title, [string[]] $More = @()) {
    $extra = @()
    if ($Timeout -gt 0) { $extra = '--timeout', [string] $Timeout }
    $json = ConvertTo-Json -InputObject $Rows -Compress |
        nativehtmlkit select --input-format json --output-format json --title $Title @extra @More
    $status = $LASTEXITCODE
    switch ($status) {
        0       { return ConvertFrom-Json -InputObject ($json -join "`n") | ForEach-Object { $_ } | ForEach-Object { $_.branch } }
        2       { Write-Warning 'git-pick: cancelled; nothing changed' }
        124     { Write-Warning 'git-pick: no choice made in time; nothing changed' }
        default { Write-Warning "git-pick: nativehtmlkit select failed with exit status $status" }
    }
    exit $status
}

try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'git-pick: not inside a Git repository'; exit 1 }
    $current = git symbolic-ref --quiet --short HEAD
    if (-not $current) { $current = '(detached HEAD)' }

    if ($Print) {
        Get-BranchTable | Format-Table -AutoSize | Out-String -Stream -Width 200
        exit 0
    }
    if (-not $DeleteMerged) {
        $branch = Select-Branch @(Get-BranchTable) "Switch branch (current: $current)"
        if ($branch -eq $current) { "Already on $branch"; exit 0 }
        git switch --quiet $branch
        if ($LASTEXITCODE -ne 0) { exit 1 }
        "Switched to $branch"
        exit 0
    }

    # Offer every merged branch except the one you are on.
    $merged = @(Get-BranchTable '--merged', 'HEAD' | Where-Object { $_.branch -ne $current })
    if ($merged.Count -eq 0) { 'No merged branches to delete'; exit 0 }
    foreach ($branch in (Select-Branch $merged 'Delete merged branches' '--multi')) {
        git branch --quiet -d $branch
        if ($LASTEXITCODE -ne 0) { exit 1 }
        "Deleted $branch"
    }
    exit 0
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
