<#
Verify examples/*.ps1 against a real nativehtmlkit CLI and its Core host, without a desktop.

  pwsh -File scripts/test-examples.ps1 -Cli <path-to-nativehtmlkit[.exe]> [-Shell powershell.exe] [-Timeout 0.5]

-Cli      the CLI to test; its Core host is found the normal way (beside the CLI).
-Shell    the PowerShell that runs each example (default: the one running this script), e.g.
          powershell.exe for Windows PowerShell 5.1 or pwsh for PowerShell 7.
-Filter   run only cases whose name contains this text.

Same method as scripts/test-examples.sh: NATIVEHTMLKIT_CLI_TEST_HEADLESS=1 makes the host
run without a window, and a `nativehtmlkit` function (PowerShell resolves functions before
executables) replaces each example's --timeout with a short one, runs the real CLI at debug
diagnostics and records exit status, stdout size and rows x columns per call. Headless cases
assert every call ended with 124 and empty stdout and the example exited as documented with
no side effect. Replay cases hand the example a recorded result (format as asserted by the
GUI qualification suites) after the real call was accepted, to check what it does with it.
Exit status 0 only when every case passed.
#>
param(
    [Parameter(Mandatory)] [string] $Cli,
    [string] $Shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
    [double] $Timeout = 0.5,
    [string] $Filter = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Examples = Join-Path $Root 'examples'
$Cli = (Resolve-Path -LiteralPath $Cli).ProviderPath
$IsWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("nhk-ps-examples-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work, "$Work/cases", "$Work/tmp", "$Work/fixtures" | Out-Null
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$Results = Join-Path $Work 'results.tsv'

# ---- shim and fakes ----------------------------------------------------------------------
$shim = @'
function global:nativehtmlkit {
    $ErrorActionPreference = 'Continue'
    $list = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($a in $args) {
        $s = [string] $a
        if ($skip) { $skip = $false; continue }
        if ($s -eq '--timeout') { $skip = $true; continue }
        if ($s -like '--timeout=*') { continue }
        $list.Add($s)
    }
    $dir = $env:NHK_SHIM_DIR
    $countFile = Join-Path $dir 'count'
    $n = 1
    # [IO.File] rather than cmdlets: an example run with -WhatIf passes $WhatIfPreference on
    # to this function, and Set-Content/Add-Content would then write nothing.
    if ([IO.File]::Exists($countFile)) { $n = [int] [IO.File]::ReadAllText($countFile) + 1 }
    [IO.File]::WriteAllText($countFile, [string] $n)
    $env:NATIVEHTMLKIT_DIAGNOSTICS = 'debug'
    $all = @($input | & $env:NHK_REAL @list --timeout $env:NHK_T 2>&1)
    $rc = $LASTEXITCODE
    $stdout = @(); $stderr = @()
    foreach ($item in $all) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $stderr += $item.ToString() } else { $stdout += [string] $item }
    }
    [IO.File]::WriteAllLines((Join-Path $dir "$n.err"), [string[]] $stderr)
    $joined = $stderr -join "`n"
    $shape = 'none'
    if ($joined -match '"event":"session.started","context":\{[^}]*"rows":(\d+),"columns":(\d+)') { $shape = "$($Matches[1])x$($Matches[2])" }
    $ready = if ($joined -match '"event":"window.ready"') { 'ready' } else { 'notready' }
    $errorLine = if ($joined -match 'error\[') { 'error' } else { 'clean' }
    [IO.File]::AppendAllText((Join-Path $dir 'calls'), "$rc@$shape $(($stdout -join "`n").Length) $ready $errorLine`n")
    $replay = Join-Path $dir "replay/$n.rc"
    if (Test-Path -LiteralPath $replay) {
        $out = Join-Path $dir "replay/$n.out"
        if ((Get-Item -LiteralPath $out).Length -gt 0) { Get-Content -LiteralPath $out -Encoding UTF8 }
        $global:LASTEXITCODE = [int] (Get-Content -LiteralPath $replay)
        return
    }
    $stdout
    $global:LASTEXITCODE = $rc
}
function global:docker {
    [IO.File]::AppendAllText((Join-Path $env:NHK_SHIM_DIR 'docker.log'), ($args -join ' ') + "`n")
    if ($args[0] -eq 'ps') {
        '{"ID":"3f2a9c1d7b44","Image":"nginx:1.27","Names":"web","Ports":"0.0.0.0:8080->80/tcp","State":"running","Status":"Up 2 hours","Labels":"","Mounts":""}'
        '{"ID":"9b8e7d6c5a43","Image":"postgres:17","Names":"db <primary>","Ports":"5432/tcp","State":"exited","Status":"Exited (0) 3 minutes ago","Labels":"","Mounts":"pgdata"}'
    } elseif ($args[0] -eq 'logs') {
        '2026-11-16T09:00:00Z ready'
        '2026-11-16T09:00:01Z <b>not markup</b> & more'
    }
    $global:LASTEXITCODE = 0
}
'@
[IO.File]::WriteAllText("$Work/shim.ps1", $shim, $Utf8)

$env:NHK_REAL = $Cli
$env:NHK_T = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Timeout)
$env:NATIVEHTMLKIT_CLI_TEST_HEADLESS = '1'
$env:TMP = "$Work/tmp"; $env:TEMP = "$Work/tmp"; $env:TMPDIR = "$Work/tmp"
Remove-Item Env:NATIVEHTMLKIT_HOST_BINARY -ErrorAction SilentlyContinue

# ---- helpers -----------------------------------------------------------------------------
function Record([string] $Status, [string] $Name, [string] $Detail) {
    "$Status`t$Name`t$Detail" | Tee-Object -FilePath $Results -Append | Write-Host
    switch ($Status) { 'PASS' { $script:Pass++ } 'FAIL' { $script:Fail++ } 'SKIP' { $script:Skip++ } }
}

function Invoke-Child([string] $Command, [string] $Dir) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Shell
    # An uncaught terminating error ends `pwsh -File script.ps1` with exit 1; do the same here.
    # -EncodedCommand carries multi-line commands and non-ASCII text intact.
    $text = ". '$Work/shim.ps1'`ntry {`n$Command`n} catch { [Console]::Error.WriteLine(`$_); exit 1 }`nexit `$LASTEXITCODE"
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Examples
    $psi.EnvironmentVariables['NHK_SHIM_DIR'] = $Dir
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "child timed out: $Command" }
    $p.WaitForExit()
    # pwsh writes terminal mode sequences even to a redirected stdout; drop them.
    [pscustomobject]@{ Exit = $p.ExitCode; Out = ($outTask.Result -replace "$([char]27)\[[0-9;?]*[A-Za-z]", ''); Err = $errTask.Result }
}

# Case NAME WANT-EXIT CALLS COMMAND [-Replay @(@(rc, 'stdout'), ...)] [-Check { param($r, $dir) ... }]
# CALLS: "124@3x5 124@2x1"; a '*' in it matches anything (for host-dependent row counts).
function Case {
    param([string] $Name, [int] $Want, [string] $Calls, [string] $Command, [object[]] $Replay = @(), [scriptblock] $Check, [string] $CheckName = 'result as expected')
    if ($Filter -and -not $Name.Contains($Filter)) { return }
    $dir = Join-Path $Work "cases/$Name"
    New-Item -ItemType Directory -Path $dir, "$dir/replay" -Force | Out-Null
    for ($i = 0; $i -lt $Replay.Count; $i++) {
        if ($null -eq $Replay[$i]) { continue }
        [IO.File]::WriteAllText("$dir/replay/$($i + 1).rc", [string] $Replay[$i][0], $Utf8)
        [IO.File]::WriteAllText("$dir/replay/$($i + 1).out", [string] $Replay[$i][1], $Utf8)
    }
    $r = Invoke-Child $Command $dir
    [IO.File]::WriteAllText("$dir/stdout", $r.Out, $Utf8); [IO.File]::WriteAllText("$dir/stderr", $r.Err, $Utf8)
    $lines = @(if (Test-Path "$dir/calls") { Get-Content "$dir/calls" })
    $got = ($lines | ForEach-Object { ($_ -split ' ')[0] }) -join ' '
    $problems = @()
    if ($r.Exit -ne $Want) { $problems += "exit $($r.Exit), want $Want" }
    if ($got -notlike $Calls) { $problems += "calls '$got', want '$Calls'" }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $f = $lines[$i] -split ' '
        $status = ($f[0] -split '@')[0]
        if (-not (Test-Path "$dir/replay/$($i + 1).rc") -and $status -ne '0' -and $f[1] -ne '0') { $problems += "call $($i + 1) wrote stdout with exit $status" }
        if ($status -eq '124' -and $f[2] -ne 'ready') { $problems += "call $($i + 1): document never became ready" }
        if ($status -eq '124' -and $f[3] -ne 'clean') { $problems += "call $($i + 1): error line despite 124" }
    }
    if ($problems.Count) { Record FAIL $Name ($problems -join '; ') } else { Record PASS $Name "exit $($r.Exit); calls: $got" }
    if ($Check) {
        $ok = $false
        try { $ok = [bool] (& $Check $r $dir) } catch { $ok = $false }
        if ($ok) { Record PASS "${Name}: $CheckName" ok } else { Record FAIL "${Name}: $CheckName" 'check failed' }
    }
}

function Q([string] $s) { "'" + $s.Replace("'", "''") + "'" }

# ---- fixtures ----------------------------------------------------------------------------
$fx = Join-Path $Work 'fixtures'
$repo = Join-Path $fx 'repo'
$haveGit = [bool] (Get-Command git -ErrorAction SilentlyContinue)
if ($haveGit) {
    $env:GIT_AUTHOR_NAME = 'example'; $env:GIT_AUTHOR_EMAIL = 'example@example.invalid'
    $env:GIT_COMMITTER_NAME = 'example'; $env:GIT_COMMITTER_EMAIL = 'example@example.invalid'
    & { $ErrorActionPreference = 'Continue'
        git init -q $repo 2>&1 | Out-Null
        git -C $repo checkout -q -b main 2>&1 | Out-Null
        git -C $repo commit -q --allow-empty -m 'initial commit' 2>&1 | Out-Null
        git -C $repo branch feature/login 2>&1 | Out-Null
        git -C $repo branch 'fix-quotes&tags' 2>&1 | Out-Null }
}
function New-Files {
    $d = Join-Path $fx 'files'
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $d | Out-Null
    'one' | Set-Content -LiteralPath (Join-Path $d 'a b.txt')
    'two' | Set-Content -LiteralPath (Join-Path $d "it's [quoted].log")
    'three' | Set-Content -LiteralPath (Join-Path $d "P$([char]0x0159)$([char]0x00ED)li$([char]0x0161) $([char]0x017E)lu$([char]0x0165)ou$([char]0x010D)k$([char]0x00FD).txt") -Encoding UTF8
    $d
}
function Count-Files($d) { @(Get-ChildItem -LiteralPath $d -File).Count }

# ---- cases -------------------------------------------------------------------------------
if ($haveGit) {
    Case git-branch-headless 124 '124@3x5' "& ./pick-git-branch.ps1 -Repository $(Q $repo)" -Check {
        (git -C $repo branch --show-current) -eq 'main' } -CheckName 'branch unchanged'
    Case git-branch-replay-submit 0 '124@3x5' "& ./pick-git-branch.ps1 -Repository $(Q $repo)" -Replay @(, @(0, '[{"Current":" ","Branch":"feature/login","Updated":"now","Upstream":"","Last commit":"initial commit"}]')) -Check {
        (git -C $repo branch --show-current) -eq 'feature/login' } -CheckName 'switched to the chosen branch'
    & { $ErrorActionPreference = 'Continue'; git -C $repo switch -q main 2>&1 | Out-Null }
    Case git-branch-replay-cancel 2 '124@3x5' "& ./pick-git-branch.ps1 -Repository $(Q $repo)" -Replay @(, @(2, ''))
} else { Record SKIP git-branch 'git not available' }

$files = New-Files
Case delete-files-headless 124 '124@3x4' "& ./delete-files.ps1 -Path $(Q $files)" -Check { (Count-Files $files) -eq 3 } -CheckName 'all files still exist'
$pickA = ConvertTo-Json -Compress -InputObject @([pscustomobject]@{ Name = 'a b.txt'; 'Size (KiB)' = 1; Modified = '2026-11-16 09:00'; Path = (Join-Path $files 'a b.txt') })
Case delete-files-replay-confirm 0 '124@3x4 124@2x1' "& ./delete-files.ps1 -Path $(Q $files)" -Replay @(@(0, $pickA), @(0, 'Yes, delete 1 file(s)')) -Check {
    (Count-Files $files) -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $files 'a b.txt')) } -CheckName 'exactly the chosen file was deleted'
$files = New-Files
Case delete-files-replay-whatif 0 '124@3x4 124@2x1' "& ./delete-files.ps1 -Path $(Q $files) -WhatIf" -Replay @(@(0, $pickA), @(0, 'Yes, delete 1 file(s)')) -Check { (Count-Files $files) -eq 3 } -CheckName '-WhatIf deleted nothing'
Case delete-files-replay-keep 0 '124@3x4 124@2x1' "& ./delete-files.ps1 -Path $(Q $files)" -Replay @(@(0, $pickA), @(0, 'No, keep them')) -Check { (Count-Files $files) -eq 3 } -CheckName 'nothing deleted'
Case delete-files-replay-cancel 2 '124@3x4' "& ./delete-files.ps1 -Path $(Q $files)" -Replay @(, @(2, '')) -Check { (Count-Files $files) -eq 3 } -CheckName 'nothing deleted'

# A uniquely named long-running process of our own.
$sleeperDir = Join-Path $fx 'sleeper'
New-Item -ItemType Directory -Path $sleeperDir | Out-Null
if ($IsWin) {
    Copy-Item "$env:SystemRoot\System32\PING.EXE" (Join-Path $sleeperDir 'nhksleeper.exe')
    $sleeper = Start-Process -FilePath (Join-Path $sleeperDir 'nhksleeper.exe') -ArgumentList '-n', '300', '127.0.0.1' -WindowStyle Hidden -PassThru
} else {
    Copy-Item (Get-Command sleep).Source (Join-Path $sleeperDir 'nhksleeper')
    $sleeper = Start-Process -FilePath (Join-Path $sleeperDir 'nhksleeper') -ArgumentList '300' -PassThru
}
Start-Sleep -Milliseconds 500
Case stop-process-headless 124 '124@1x4' "& ./stop-process.ps1 -Name nhksleeper" -Check { -not $sleeper.HasExited } -CheckName 'process still running'
$pickP = ConvertTo-Json -Compress -InputObject @([pscustomobject]@{ Id = $sleeper.Id; ProcessName = 'nhksleeper'; 'CPU (s)' = 0; 'Memory (MiB)' = 1 })
Case stop-process-replay-whatif 0 '124@1x4' "& ./stop-process.ps1 -Name nhksleeper -WhatIf" -Replay @(, @(0, $pickP)) -Check { -not $sleeper.HasExited } -CheckName '-WhatIf stopped nothing'
Case stop-process-replay-stop 0 '124@1x4' "& ./stop-process.ps1 -Name nhksleeper" -Replay @(, @(0, $pickP)) -Check { $sleeper.WaitForExit(5000) } -CheckName 'the chosen process was stopped'
if (-not $sleeper.HasExited) { $sleeper.Kill() }

Case container-headless 124 '124@2x6' "& ./pick-container.ps1" -Check { param($r, $d) (Get-Content "$d/docker.log") -eq 'ps --all --format {{json .}}' } -CheckName 'docker was only asked to list'
Case container-replay-restart 0 '124@2x6 124@3x1' "& ./pick-container.ps1" -Replay @(@(0, '[{"Name":"web","Image":"nginx:1.27","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp","ID":"3f2a9c1d7b44"}]'), @(0, 'restart')) -Check {
    param($r, $d) @(Get-Content "$d/docker.log") -contains 'restart 3f2a9c1d7b44' } -CheckName 'docker restart got the chosen id'
Case container-replay-logs-view 124 '124@2x6 124@3x1 124@2x1' "& ./pick-container.ps1" -Replay @(@(0, '[{"Name":"db <primary>","Image":"postgres:17","State":"exited","Status":"Exited","Ports":"5432/tcp","ID":"9b8e7d6c5a43"}]'), @(0, 'logs'))

Case api-file-headless 124 '124@3x6' "& ./pick-from-api.ps1 -Path data/issues.json" -Check { param($r) $r.Out -eq '' } -CheckName 'stdout empty'
Case api-replay-submit 0 '124@3x6' "& ./pick-from-api.ps1 -Path data/issues.json" -Replay @(, @(0, '[{"#":42,"Title":"x","Author":"ada","Labels":"bug","Updated":"2026-11-12","url":"https://example.invalid/issues/42"},{"#":39,"Title":"y","Author":"zoe","Labels":"","Updated":"2026-11-01","url":"https://example.invalid/issues/39"}]')) -Check {
    param($r) ($r.Out.Trim() -split "`r?`n") -join ',' -eq 'https://example.invalid/issues/42,https://example.invalid/issues/39' } -CheckName 'prints the chosen URLs'
Case api-replay-single 0 '124@3x6' "& ./pick-from-api.ps1 -Path data/issues.json" -Replay @(, @(0, '[{"#":41,"Title":"x","Author":"grace","Labels":"docs","Updated":"2026-11-10","url":"https://example.invalid/issues/41"}]')) -Check {
    param($r) $r.Out.Trim() -eq 'https://example.invalid/issues/41' } -CheckName 'a one-element array is still read as a list'

$subset = Join-Path $fx 'subset.csv'
Case csv-report-view 124 '124@7x7' "& ./csv-report.ps1 -Report data/servers.csv"
Case csv-report-export-headless 124 '124@7x7' "& ./csv-report.ps1 -Report data/servers.csv -Output $(Q $subset)" -Check { -not (Test-Path -LiteralPath $subset) } -CheckName 'no output file written'
Case csv-report-export-replay 0 '124@7x7' "& ./csv-report.ps1 -Report data/servers.csv -Output $(Q $subset)" -Replay @(, @(0, "host,role,region,cpu_cores,memory_gib,status,notes`nweb-02,frontend,eu-west,4,8,degraded,`"disk 91% full, cleanup scheduled`"`n")) -Check {
    $t = [IO.File]::ReadAllText($subset); $t.StartsWith('host,role') -and $t.Contains('"disk 91% full, cleanup scheduled"') -and $t[0] -ne [char] 0xFEFF } -CheckName 'export written as UTF-8 without BOM'

Case deploy-form-headless 124 '124@0x1' "& ./deploy-form.ps1 -Service api, web"
Case deploy-form-hostile-names 124 '124@0x1' "& ./deploy-form.ps1 -Service '<script>x</script>', 'a`"b', 'it''s&more'"
$staging = '{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"staging"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":""},{"kind":"text","name":"dry_run","value":"yes"}]}'
Case deploy-form-replay-staging 0 '124@0x1' "& ./deploy-form.ps1 -Service api | ConvertTo-Json -Compress" -Replay @(, @(0, $staging)) -Check {
    param($r) $r.Out.Trim() -eq '{"service":"api","environment":"staging","version":"v1.4.2","replicas":3,"notify":null,"notes":"","dry_run":true}' } -CheckName 'parameters returned as an object'
$prodNoNotes = '{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":"  "}]}'
Case deploy-form-replay-production-needs-notes 1 '124@0x1' "& ./deploy-form.ps1 -Service api" -Replay @(, @(0, $prodNoNotes))
$prod = '{"entries":[{"kind":"text","name":"service","value":"web"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"2.0.0"},{"kind":"text","name":"replicas","value":"4"},{"kind":"text","name":"notify","value":"ops@example.com"},{"kind":"text","name":"notes","value":"Rollout"}]}'
Case deploy-form-replay-production-confirmed 0 '124@0x1 124@2x1' "& ./deploy-form.ps1 -Service web | ConvertTo-Json -Compress" -Replay @(@(0, $prod), @(0, 'Yes, deploy web 2.0.0 to production')) -Check {
    param($r) $o = $r.Out | ConvertFrom-Json; $o.dry_run -eq $false -and $o.replicas -eq 4 -and $o.environment -eq 'production' } -CheckName 'confirmed production parameters'
Case deploy-form-replay-production-declined 2 '124@0x1 124@2x1' "& ./deploy-form.ps1 -Service web" -Replay @(@(0, $prod), @(0, 'No, stop here'))

Case view-logs-file 124 '124@5x1' "& ./view-logs.ps1 -Path data/app.log"
$long = Join-Path $fx 'long.log'
[IO.File]::WriteAllLines($long, [string[]] (1..1500 | ForEach-Object { (('{0:D700} ' -f $_) + [char] 0x017E) }), $Utf8)
Case view-logs-long-lines 124 '124@1000x1' "& ./view-logs.ps1 -Path $(Q $long)"
if ($IsWin) {
    Case view-logs-windows-events 124 '124@*x5' "& ./view-logs.ps1 -LogName System"
    Case pick-service-headless 124 '124@*x4' "& ./pick-service.ps1 -Name 'w*'"
    Case pick-service-none 0 '' "& ./pick-service.ps1 -Name 'no-such-service-*'"
} else {
    Record SKIP view-logs-windows-events 'Windows only'
    Record SKIP pick-service 'Windows only'
}

# The encoding rules the examples rely on, shown directly.
# Built from code points so that this file stays ASCII (Windows PowerShell 5.1 reads a .ps1
# without BOM in the ANSI code page) and the child's command line carries no non-ASCII text.
$unicode = '$name = "P$([char]0x0159)$([char]0x00ED)li$([char]0x0161) $([char]0x017E)lu$([char]0x0165)ou$([char]0x010D)k$([char]0x00FD) " + [char]::ConvertFromUtf32(0x1F600)'
Case encoding-utf8-no-bom 124 '124@1x2' "$unicode; `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); [pscustomobject]@{ name = `$name; n = 1 } | ConvertTo-Json -Compress | nativehtmlkit select --input-format json"
Case encoding-pipeline-objects 124 '124@2x2' "`$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); Get-ChildItem -LiteralPath $(Q $Examples) -Filter 'pick-git-branch.*' | Select-Object Name, Length | ConvertTo-Json | nativehtmlkit select --input-format json"

# ---- documentation snippets (README.md, docs/), run as written ----------------------------
$snip = Join-Path $fx 'snip'
New-Item -ItemType Directory -Path $snip | Out-Null
Copy-Item (Join-Path $Examples 'data/app.log') (Join-Path $snip 'app.log')
Copy-Item (Join-Path $Examples 'sample-form.html') (Join-Path $snip 'deploy.html')
'first' | Set-Content -LiteralPath (Join-Path $snip 'one.log')
'second' | Set-Content -LiteralPath (Join-Path $snip 'two.log')
$in = "Set-Location $(Q $snip); `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)"
Case doc-readme-processes 124 '124@*x2' "$in; Get-Process | Select-Object Id, ProcessName | ConvertTo-Json |
    nativehtmlkit select --input-format json --output-format json --multi
if (`$LASTEXITCODE -eq 2) { 'cancelled' }; exit `$LASTEXITCODE"
Case doc-view-get-content 124 '124@5x1' "$in; Get-Content .\app.log -Tail 500 | nativehtmlkit view --title 'app.log'; exit `$LASTEXITCODE"
Case doc-view-get-childitem 124 '124@*x3' "$in; Get-ChildItem -File | Select-Object Name, Length, @{ n = 'Modified'; e = { `$_.LastWriteTime.ToString('s') } } |
    ConvertTo-Json | nativehtmlkit view --input-format json; exit `$LASTEXITCODE"
Case doc-form-read 124 '124@0x1' "$in; `$json = nativehtmlkit form --html deploy.html
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
'unreachable'"
Case doc-exit-status-switch 1 '124@2x1' "$in; `$out = 'a', 'b' | nativehtmlkit select
switch (`$LASTEXITCODE) {
    0       { `"chose: `$out`" }
    2       { Write-Warning 'cancelled' }
    124     { Write-Warning 'no answer in time'; exit 1 }
    default { throw `"nativehtmlkit failed (`$LASTEXITCODE)`" }
}"
Case doc-guide-size-switch 124 '124@3x1' "$in; `$choice = 'small', 'medium', 'large' | nativehtmlkit select --title 'Size' --timeout 60
switch (`$LASTEXITCODE) {
    0       { `"size: `$choice`" }
    2       { Write-Warning 'Cancelled.'; exit 2 }
    124     { Write-Warning 'No answer within 60 s.'; exit 124 }
    default { exit `$LASTEXITCODE }
}"
Case doc-guide-invoke-picker 124 '124@2x1' "$in; function Invoke-Picker {
    `$out = `$input | nativehtmlkit @args
    if (`$LASTEXITCODE -ne 0) { Write-Warning 'Nothing chosen.'; exit `$LASTEXITCODE }
    `$out -join `"``n`"
}
`$color = 'red', 'green' | Invoke-Picker select --title 'Colour'
'unreachable'" -Check { param($r) -not $r.Out.Contains('unreachable') } -CheckName 'the helper ended the script'
Case doc-guide-compress 0 '124@3x1' "$in; `$chosen = Get-ChildItem *.log | ForEach-Object Name | nativehtmlkit select --multi --title 'Compress'
if (`$LASTEXITCODE -eq 0) { `$chosen | ForEach-Object { Compress-Archive -LiteralPath `$_ -DestinationPath `"`$_.zip`" } }
exit 0" -Check { @(Get-ChildItem -LiteralPath $snip -Filter *.zip).Count -eq 0 } -CheckName 'nothing was compressed'
Case doc-guide-view-logs-text 124 '124@5x1' "$in; Get-Content -LiteralPath .\app.log -Tail 1000 -Encoding UTF8 |
    ForEach-Object { if (`$_.Length -gt 400) { `$_.Substring(0, 400) + '...' } else { `$_ } } |
    nativehtmlkit view --title 'app.log'; exit `$LASTEXITCODE"
Case doc-windows-readback 124 '124@2x2' "$in; `$rows = @([pscustomobject]@{ Name = 'a'; N = 1 }, [pscustomobject]@{ Name = 'b'; N = 2 })
`$json = `$rows | ConvertTo-Json -Compress | nativehtmlkit select --multi --input-format json --output-format json
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
`$picked = @(ConvertFrom-Json -InputObject (`$json -join `"``n`"))
`$picked | ForEach-Object { `$_.Name }"
Case doc-windows-readback-replay 0 '124@2x2' "$in; `$rows = @([pscustomobject]@{ Name = 'a'; N = 1 }, [pscustomobject]@{ Name = 'b'; N = 2 })
`$json = `$rows | ConvertTo-Json -Compress | nativehtmlkit select --multi --input-format json --output-format json
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
`$picked = @(ConvertFrom-Json -InputObject (`$json -join `"``n`"))
`$picked | ForEach-Object { `$_.Name }" -Replay @(, @(0, '[{"Name":"b","N":2}]')) -Check { param($r) $r.Out.Trim() -eq 'b' } -CheckName 'one chosen object read back'
Case doc-form-generate 124 '124@0x1' "$in; function Enc([string] `$s) { [System.Net.WebUtility]::HtmlEncode(`$s) }
`$name = 'a <b> & `"c`"'
`$path = Join-Path (Get-Location) 'gen.html'
`$html = `"<form id='nhk-form'><select name='s'><option value=```"`$(Enc `$name)```">`$(Enc `$name)</option></select></form>`"
[IO.File]::WriteAllText(`$path, `$html, [System.Text.UTF8Encoding]::new(`$false))
nativehtmlkit form --html `$path --title 'Deploy'; exit `$LASTEXITCODE" -Check { (Get-Content -LiteralPath (Join-Path $snip 'gen.html') -Raw).Contains('a &lt;b&gt; &amp; &quot;c&quot;') } -CheckName 'value encoded'
if ($IsWin) {
    Case doc-select-get-service 124 '124@*x2' "$in; `$json = Get-Service | Select-Object Name, Status | ConvertTo-Json |
    nativehtmlkit select --input-format json --output-format json --multi
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }"
    Case doc-windows-services 124 '124@*x3' "$in; Get-Service | Select-Object Name, DisplayName, @{ n = 'Status'; e = { `"`$(`$_.Status)`" } } |
    ConvertTo-Json -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Services'; exit `$LASTEXITCODE"
    Case doc-view-winevent 124 '124@*x5' "$in; Get-WinEvent -LogName System -MaxEvents 200 |
    Select-Object @{ n = 'Time'; e = { `$_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') } },
        @{ n = 'Level'; e = { `$_.LevelDisplayName } }, Id, ProviderName,
        @{ n = 'Message'; e = { (`"`$(`$_.Message)`" -split `"``r?``n`")[0] } } |
    ConvertTo-Json -Compress |
    nativehtmlkit view --input-format json --title 'Events: System'; exit `$LASTEXITCODE"
} else {
    Record SKIP doc-windows-only-snippets 'Get-Service / Get-WinEvent: Windows only'
}
# The BOM pitfall documented in the Windows PowerShell guide (5.1 only: 7 writes no BOM here).
if ($IsWin -and ((& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.Major') -eq '5')) {
    Case doc-windows-utf8-bom-breaks-json 1 '1@none' "$in; `$OutputEncoding = [Text.Encoding]::UTF8; '[1]' | nativehtmlkit select --input-format json; exit `$LASTEXITCODE" -Check {
        param($r, $d) (Get-Content -LiteralPath "$d/1.err") -match 'invalid JSON input: expected value at line 1 column 1' } -CheckName 'BOM rejected as documented'
    Case doc-windows-default-encoding 0 '' "`"`$(`$OutputEncoding.WebName)`"" -Check { param($r) $r.Out.Trim() -eq 'us-ascii' } -CheckName 'Windows PowerShell 5.1 sends us-ascii by default'
}

# ---- leftovers ---------------------------------------------------------------------------
Start-Sleep -Seconds 1
$hostPath = Join-Path (Split-Path -Parent $Cli) ($(if ($IsWin) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' }))
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $hostPath } catch { $false } }).Count
$dirs = @(Get-ChildItem -LiteralPath "$Work/tmp" -Directory -Filter 'nativehtmlkit-cli-*').Count
if ($left -eq 0 -and $dirs -eq 0) { Record PASS zz-no-leftovers 'no host process left, every private session directory removed' }
else { Record FAIL zz-no-leftovers "host processes left: $left; session directories: $dirs" }

$edition = (& $Shell -NoProfile -Command '[string]$PSVersionTable.PSVersion')
Write-Host "test-examples.ps1: $($script:Pass) PASS, $($script:Fail) FAIL, $($script:Skip) SKIP (CLI $((& $Cli --version) -replace 'nativehtmlkit ', ''), examples run by PowerShell $edition, work dir $Work)"
if ($script:Fail -eq 0) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
