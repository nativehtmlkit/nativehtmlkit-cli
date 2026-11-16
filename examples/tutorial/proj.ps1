<#
proj.ps1 - a small project-directory bookmark tool, built step by step in
docs/windows/tutorial.md. The PowerShell counterpart of proj.sh.

Teaches: one storage format (NDJSON) used directly as CLI input and output, a shared
wrapper for the exit contract, a generated and encoded form, multi-select with
confirmation, a read-only table, and a custom stylesheet.

Run:   .\proj.ps1 add [DIR]                  bookmark DIR (default: the current directory)
       Set-Location (.\proj.ps1 pick)        jump to a bookmarked project
       .\proj.ps1 list                       show all bookmarks
       .\proj.ps1 remove                     tick bookmarks to remove, then confirm
Store: $env:PROJ_FILE, default %APPDATA%\proj\projects.ndjson (~/.config/proj on Linux)
Needs: nativehtmlkit on PATH.
Exit:  0 done, 2 cancelled, 124 no answer in time, 1 error.
#>
param(
    [ValidateSet('pick', 'add', 'list', 'remove')] [string] $Command = 'pick',
    [string] $Directory = '.'
)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Utf8 = [System.Text.UTF8Encoding]::new($false)

$store = $env:PROJ_FILE
if (-not $store) {
    $base = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME '.config' }
    $store = Join-Path $base 'proj/projects.ndjson'
}
$style = '--css', (Join-Path $PSScriptRoot 'proj.css')

function Stop-Proj([string] $Message) { Write-Warning "proj: $Message"; exit 1 }
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }

# ui ARGS... - run the CLI with ARGS (and the pipeline input) and return its stdout as one
# string. Cancel, timeout and errors end the whole script with the CLI's status.
function ui {
    $out = $input | nativehtmlkit @args @style
    switch ($LASTEXITCODE) {
        0       { return ($out -join "`n") }
        2       { exit 2 }
        124     { Write-Warning 'proj: no answer in time'; exit 124 }
        default { exit $LASTEXITCODE }
    }
}

function Get-Records {
    if (-not (Test-Path -LiteralPath $store)) { return @() }
    @([IO.File]::ReadAllLines($store, $Utf8) | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
}
function Assert-Projects { if ((Get-Records).Count -eq 0) { Stop-Proj 'no projects yet; add one with: proj add [DIR]' } }
function Get-StoreText { [IO.File]::ReadAllText($store, $Utf8) }

function Invoke-Pick {
    Assert-Projects
    $picked = Get-StoreText | ui select --input-format ndjson --output-format json --title 'Open project'
    (ConvertFrom-Json -InputObject $picked)[0].path
}

function Invoke-Add {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { Stop-Proj "no such directory: $Directory" }
    $dir = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $html = Join-Path ([IO.Path]::GetTempPath()) "proj-add-$PID.html"
    $form = @"
<form id="nhk-form">
  <p><label>Name <input name="name" required maxlength="60" value="$(Enc (Split-Path -Leaf $dir))"></label></p>
  <p><label>Directory <input name="path" required value="$(Enc $dir)"></label></p>
  <p><label>Tags <input name="tags" placeholder="work, rust" pattern="[A-Za-z0-9 ,_-]*"
         title="letters, digits, spaces, commas, - and _"></label></p>
</form>
"@
    [IO.File]::WriteAllText($html, $form, $Utf8)
    try { $result = ui form --html $html --title 'Add project' }
    finally { Remove-Item -LiteralPath $html -ErrorAction SilentlyContinue }

    # {"entries":[{"kind":"text","name":"name","value":"..."},...]} -> one ordered record
    $values = @{}
    foreach ($e in (ConvertFrom-Json -InputObject $result).entries) { $values[$e.name] = $e.value }
    $record = [ordered]@{ name = $values.name; path = $values.path; tags = "$($values.tags)"; added = (Get-Date -Format 'yyyy-MM-dd') }
    if (-not (Test-Path -LiteralPath $record.path -PathType Container)) { Stop-Proj "not a directory: $($record.path)" }
    if (@(Get-Records | Where-Object { $_.path -eq $record.path }).Count) { Stop-Proj "already bookmarked: $($record.path)" }
    $parent = Split-Path -Parent $store
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    [IO.File]::AppendAllText($store, (ConvertTo-Json -InputObject $record -Compress) + "`n", $Utf8)
    Write-Warning "proj: added $($record.path)"
}

function Invoke-List {
    Assert-Projects
    Get-StoreText | ui view --input-format ndjson --title "Projects ($((Get-Records).Count))" | Out-Null
}

function Invoke-Remove {
    Assert-Projects
    $picked = @((Get-StoreText | ui select --multi --input-format ndjson --output-format ndjson --title 'Remove projects') -split "`n" |
        Where-Object { $_ } | ForEach-Object { (ConvertFrom-Json -InputObject $_).path })
    $count = $picked.Count
    $answer = 'Keep them', "Remove $count project(s)" | ui select --title "Remove $count project(s)?"
    if (-not $answer.StartsWith('Remove')) { Write-Warning 'proj: nothing removed'; return }
    $keep = @([IO.File]::ReadAllLines($store, $Utf8) | Where-Object { $_.Trim() -and $picked -notcontains (ConvertFrom-Json -InputObject $_).path })
    $tmp = "$store.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $(if ($keep.Count) { ($keep -join "`n") + "`n" } else { '' }), $Utf8)
    Move-Item -LiteralPath $tmp -Destination $store -Force
    Write-Warning "proj: removed $count project(s)"
}

try {
    switch ($Command) {
        'pick'   { Invoke-Pick }
        'add'    { Invoke-Add }
        'list'   { Invoke-List }
        'remove' { Invoke-Remove }
    }
    exit 0
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
