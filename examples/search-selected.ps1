<#
search-selected.ps1 - tick files in a window, then search only those files for a pattern.

Teaches: `select --multi` as one stage between PowerShell commands: paths go in as lines,
the ticked paths come back as lines, and $LASTEXITCODE says whether the user submitted
before anything is searched. The PowerShell counterpart of grep-selected.sh.

Run:   .\search-selected.ps1 -Pattern TODO [-Path src]
Needs: nativehtmlkit on PATH.
Exit:  0 matches found, 1 no match or error, 2 cancelled, 124 no decision in time.
#>
param(
    [Parameter(Mandatory)] [string] $Pattern,
    [string] $Path = '.'
)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    # Relative paths, sorted, without .git, at most 2,000 (more would be an error, not a cut).
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Length -lt 2MB } |
        ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') } |
        Sort-Object | Select-Object -First 2000)
    if ($files.Count -eq 0) { Write-Warning "search-selected: no files in $Path"; exit 1 }

    $title = 'Search for: ' + $Pattern.Substring(0, [Math]::Min(100, $Pattern.Length))
    $chosen = @($files | nativehtmlkit select --multi --title $title)
    switch ($LASTEXITCODE) {
        0       { }
        2       { Write-Warning 'search-selected: cancelled'; exit 2 }
        124     { Write-Warning 'search-selected: no files chosen in time'; exit 124 }
        default { exit 1 }
    }

    $hits = @(Select-String -LiteralPath ($chosen | ForEach-Object { Join-Path $root $_ }) -Pattern $Pattern)
    foreach ($hit in $hits) {
        '{0}:{1}:{2}' -f $hit.Path.Substring($root.Length).TrimStart('\', '/'), $hit.LineNumber, $hit.Line
    }
    exit $(if ($hits.Count) { 0 } else { 1 })
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
