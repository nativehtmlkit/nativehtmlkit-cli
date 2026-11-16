<#
delete-files.ps1 - tick files in a folder, confirm, and delete exactly those files.

Teaches: Get-ChildItem objects as JSON rows, multi-select, a second `select` as the
confirmation dialog (nothing is preselected, so the safe answer needs no click), and
SupportsShouldProcess so -WhatIf shows what would be deleted.

Run:   .\delete-files.ps1 -Path C:\Temp\logs [-Filter *.log] [-WhatIf]
Needs: nativehtmlkit on PATH.
Exit:  0 deleted or nothing to do, 2 cancelled, 124 no decision in time, 1 error.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Filter = '*'
)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Run the CLI on pipeline input; return its stdout. Cancel, timeout and errors end the
# script with the CLI's exit status (`exit` inside a function ends the whole script).
function Invoke-Picker {
    $out = $input | nativehtmlkit @args
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Nothing deleted.'
        exit $LASTEXITCODE
    }
    $out -join "`n"
}

try {
    $files = @(Get-ChildItem -LiteralPath $Path -File -Filter $Filter | Sort-Object LastWriteTime |
        Select-Object -First 2000)              # the CLI shows at most 2,000 rows
    if ($files.Count -eq 0) { Write-Host "Nothing in $Path matches $Filter."; exit 0 }

    $rows = $files | ForEach-Object {
        [pscustomobject]@{
            Name         = $_.Name
            'Size (KiB)' = [math]::Ceiling($_.Length / 1KB)
            Modified     = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Path         = $_.FullName
        }
    }
    $json = $rows | ConvertTo-Json -Compress |
        Invoke-Picker select --multi --input-format json --output-format json --title "Files to delete in $(Split-Path -Leaf $Path)"
    # ForEach-Object unrolls the array: Windows PowerShell 5.1 returns a JSON array as one object.
    $picked = @(ConvertFrom-Json -InputObject $json | ForEach-Object { $_ })

    $answer = "No, keep them", "Yes, delete $($picked.Count) file(s)" |
        Invoke-Picker select --title "Delete $($picked.Count) file(s)?"
    if (-not $answer.StartsWith('Yes')) { Write-Host 'Kept all files.'; exit 0 }

    foreach ($file in $picked) {
        if ($PSCmdlet.ShouldProcess($file.Path, 'Delete file')) {
            Remove-Item -LiteralPath $file.Path
            Write-Host "deleted $($file.Path)"
        }
    }
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
