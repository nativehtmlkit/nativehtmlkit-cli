<#
deploy-form.ps1 - collect deployment parameters in a native form and return them as an object.

Teaches: building a trusted `--html` form in PowerShell with every dynamic value encoded by
[System.Net.WebUtility]::HtmlEncode, Core's HTML constraint validation (required, pattern,
min/max, type=email, maxlength), turning {"entries":[...]} into a hashtable, an extra rule
checked by the script, and a production confirmation.

Run:   .\deploy-form.ps1 [-Service api, web, worker]
       $p = .\deploy-form.ps1 -Service api; $p.replicas
Needs: nativehtmlkit on PATH; git (optional, to prefill the version).
Exit:  0 parameters returned, 2 cancelled, 124 no decision in time, 1 error.
#>
param([string[]] $Service = @('api', 'web', 'worker'))
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }   # & < > " '

$form = Join-Path ([IO.Path]::GetTempPath()) "deploy-form-$PID.html"
try {
    $version = 'v1.0.0'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $described = & { $ErrorActionPreference = 'Continue'; git describe --tags --abbrev=0 2>$null }
        if ($LASTEXITCODE -eq 0 -and $described) { $version = "$described".Trim() }
    }
    $options = ($Service | ForEach-Object { "<option value=`"$(Enc $_)`">$(Enc $_)</option>" }) -join ''
    $html = @"
<form id="nhk-form">
<label>Service <select name="service" required><option value="">Choose...</option>$options</select></label>
<fieldset><legend>Environment</legend>
<label><input type="radio" name="environment" value="staging" required checked> Staging</label>
<label><input type="radio" name="environment" value="production"> Production</label>
</fieldset>
<label>Version <input name="version" required value="$(Enc $version)" pattern="v?[0-9]+\.[0-9]+\.[0-9]+" title="a version such as v1.4.2"></label>
<label>Replicas <input name="replicas" type="number" min="1" max="20" value="2" required></label>
<label>Notify <input name="notify" type="email" placeholder="team@example.com"></label>
<label>Change notes <textarea name="notes" maxlength="500" rows="3"></textarea></label>
<label class="check"><input type="checkbox" name="dry_run" value="yes" checked> Dry run only</label>
</form>
"@
    [IO.File]::WriteAllText($form, $html, [System.Text.UTF8Encoding]::new($false))

    $json = nativehtmlkit form --html $form --css (Join-Path $PSScriptRoot 'css/form.css') --title 'Deploy' --timeout 600
    switch ($LASTEXITCODE) {
        0       { }
        2       { Write-Warning 'Cancelled.'; exit 2 }
        124     { Write-Warning 'The form was left open for 10 minutes; closed.'; exit 124 }
        default { exit $LASTEXITCODE }
    }

    # One entry per successful control, in document order; an unchecked checkbox has none.
    $values = @{}
    foreach ($entry in (ConvertFrom-Json -InputObject ($json -join "`n")).entries) {
        if (-not $values.ContainsKey($entry.name)) { $values[$entry.name] = $entry.value }
    }

    if ($values.environment -eq 'production' -and -not "$($values.notes)".Trim()) {
        Write-Error 'Production deploys need change notes.'    # ends the script with exit 1
    }
    $dryRun = $values.dry_run -eq 'yes'
    if ($values.environment -eq 'production' -and -not $dryRun) {
        $answer = 'No, stop here', "Yes, deploy $($values.service) $($values.version) to production" |
            nativehtmlkit select --title 'Really deploy to production?'
        if ($LASTEXITCODE -ne 0 -or -not "$answer".StartsWith('Yes')) { Write-Warning 'Not confirmed.'; exit 2 }
    }

    [pscustomobject]@{
        service     = $values.service
        environment = $values.environment
        version     = $values.version
        replicas    = [int] $values.replicas
        notify      = if ($values.notify) { $values.notify } else { $null }
        notes       = "$($values.notes)"
        dry_run     = $dryRun
    }
}
finally {
    Remove-Item -LiteralPath $form -ErrorAction SilentlyContinue
    [Console]::OutputEncoding = $previousEncoding
}
