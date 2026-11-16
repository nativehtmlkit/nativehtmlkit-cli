<#
Run every tested code block of docs/windows/ against a real nativehtmlkit CLI, headless.

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-docs.ps1 -Cli <nativehtmlkit.exe> [-Shell powershell.exe]
  pwsh -File scripts/test-docs.ps1 -Cli <nativehtmlkit> [-Filter TEXT]

-Cli          the CLI to test; its Core host is found the normal way (beside the CLI).
-Shell        the PowerShell that runs each block (default: the one running this script):
              powershell.exe for Windows PowerShell 5.1, pwsh for PowerShell 7.
-Filter       run only blocks whose name (page:line) contains this text; skips coverage.
-SubmitCases  where to write the "Submit prints" cases (default: <work dir>/submit-cases.json).

The same markers and the same method as scripts/test-docs.py (read its header): HTML comments
`<!-- test: exit=N calls="..." [shim=off] [cli-timeout=S] [requires=windows|ps51|ps7|git] -->`
above a ```powershell block (or a ```bat block, run by cmd.exe on Windows only, always
without the shim), followed by optional `replay:`, `stdout`, `stderr` and `submit:` blocks.
Each block runs in a fresh copy of examples/ inside a fresh Git repository, in a child
PowerShell (-EncodedCommand; its status is its `exit` value, else $LASTEXITCODE after the
last line). A `nativehtmlkit` program first on PATH (a C# shim compiled at start on Windows,
the bash shim of test-docs.py elsewhere) replaces any --timeout with a short one, runs the
real CLI headless (NATIVEHTMLKIT_CLI_TEST_HEADLESS=1, set for the block) and records each
call; `docker` is a harmless stand-in function.

"Submit prints" cases record the exact stdin bytes and options PowerShell gave the CLI. They
are checked against the released formatter by
  python3 scripts/test-docs.py --only-submit-cases --check-submit-cases <file>
on a machine with cargo (this script does that itself when python3 and cargo are on PATH).

Coverage: every option of every command, every format, level, variable, exit status
(0, 1, 2, 124, 130) and every Windows example file of examples/catalog.toml must have a
tested block on its page; items whose only blocks were skipped (Windows-only blocks run
elsewhere) are reported as SKIP. Exit status 0 only when nothing failed.
#>
param(
    [Parameter(Mandatory)] [string] $Cli,
    [string] $Shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
    [double] $Timeout = 0.5,
    [string] $Filter = '',
    [string] $SubmitCases = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Root 'docs/windows'
$Cli = (Resolve-Path -LiteralPath $Cli).ProviderPath
$IsWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$Utf8 = [System.Text.UTF8Encoding]::new($false)
$Work = Join-Path ([IO.Path]::GetTempPath()) ('nhk-docs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work, "$Work/cases", "$Work/tmp" | Out-Null
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Covered = @{}      # page -> list of tested block texts
$script:SkippedText = @{}  # page -> list of skipped block texts
$script:ExitSeen = @{}     # page -> list of exit statuses
$script:Submit = New-Object System.Collections.Generic.List[object]

function Record([string] $Status, [string] $Name, [string] $Detail) {
    $script:Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    Write-Host "$Status`t$Name`t$Detail"
}

# ---- the shim -----------------------------------------------------------------------------
# A program named nativehtmlkit (and nhk) first on PATH, so blocks call it exactly like the
# real executable: pipeline input, stderr, 2>&1 and $LASTEXITCODE behave the same. On
# Windows it is a small C# program compiled here; elsewhere the bash shim of test-docs.py.
New-Item -ItemType Directory -Path "$Work/bin" | Out-Null
if ($IsWin) {
    $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class NhkShim {
    static string Quote(string a) {
        if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1); sb.Append('"'); slashes = 0; continue; }
            sb.Append('\\', slashes); slashes = 0; sb.Append(c);
        }
        sb.Append('\\', slashes * 2); sb.Append('"');
        return sb.ToString();
    }
    static void Copy(Stream from, Stream to) {
        var buf = new byte[65536]; int n;
        while ((n = from.Read(buf, 0, buf.Length)) > 0) to.Write(buf, 0, n);
    }
    public static int Main(string[] argv) {
        string dir = Environment.GetEnvironmentVariable("NHK_SHIM_DIR");
        var list = new List<string>(); bool skip = false, window = false;
        foreach (string a in argv) {
            if (skip) { skip = false; continue; }
            if (a == "--timeout") { skip = true; continue; }
            if (a.StartsWith("--timeout=")) continue;
            if (a == "select" || a == "view" || a == "form") window = true;
            list.Add(a);
        }
        string countFile = Path.Combine(dir, "count");
        int n = File.Exists(countFile) ? int.Parse(File.ReadAllText(countFile)) + 1 : 1;
        File.WriteAllText(countFile, n.ToString());
        File.WriteAllText(Path.Combine(dir, n + ".args"), string.Join("\0", list.ToArray()));
        if (window) { list.Add("--timeout"); list.Add(Environment.GetEnvironmentVariable("NHK_T")); }
        var quoted = new List<string>();
        foreach (string a in list) quoted.Add(Quote(a));
        var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("NHK_REAL"), string.Join(" ", quoted.ToArray()));
        psi.UseShellExecute = false;
        psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NATIVEHTMLKIT_DIAGNOSTICS")))
            psi.EnvironmentVariables["NATIVEHTMLKIT_DIAGNOSTICS"] = "debug";
        Process p = Process.Start(psi);
        bool capture = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NHK_CAPTURE"));
        var stdinThread = new Thread(delegate () {
            try {
                Stream input = Console.OpenStandardInput();
                Stream cap = capture ? (Stream) File.Create(Path.Combine(dir, n + ".in")) : Stream.Null;
                var buf = new byte[65536]; int r;
                try {
                    while ((r = input.Read(buf, 0, buf.Length)) > 0) {
                        cap.Write(buf, 0, r);
                        try { p.StandardInput.BaseStream.Write(buf, 0, r); } catch (IOException) { }
                    }
                } finally { cap.Dispose(); }
            } catch (Exception) { }
            try { p.StandardInput.Close(); } catch (Exception) { }
        });
        stdinThread.IsBackground = true; stdinThread.Start();
        var outMs = new MemoryStream(); var errMs = new MemoryStream();
        var outThread = new Thread(delegate () { Copy(p.StandardOutput.BaseStream, outMs); });
        var errThread = new Thread(delegate () { Copy(p.StandardError.BaseStream, errMs); });
        outThread.Start(); errThread.Start();
        p.WaitForExit(); outThread.Join(); errThread.Join();
        int rc = p.ExitCode;
        byte[] errBytes = errMs.ToArray();
        File.WriteAllBytes(Path.Combine(dir, n + ".err"), errBytes);
        using (Stream e = Console.OpenStandardError()) { e.Write(errBytes, 0, errBytes.Length); }
        string err = Encoding.UTF8.GetString(errBytes);
        Match m = Regex.Match(err, "\"event\":\"session.started\",\"context\":\\{[^}]*\"rows\":(\\d+),\"columns\":(\\d+)");
        string shape = m.Success ? m.Groups[1].Value + "x" + m.Groups[2].Value : "none";
        string ready = err.Contains("\"event\":\"window.ready\"") ? "ready" : "notready";
        if (!m.Success) ready = "unknown";
        string errLine = err.Contains("error[") ? "error" : "clean";
        File.AppendAllText(Path.Combine(dir, "calls"), rc + "@" + shape + " " + outMs.Length + " " + ready + " " + errLine + "\n");
        string replay = Path.Combine(Path.Combine(dir, "replay"), n + ".rc");
        using (Stream o = Console.OpenStandardOutput()) {
            if (File.Exists(replay)) {
                byte[] text = File.ReadAllBytes(Path.Combine(Path.Combine(dir, "replay"), n + ".out"));
                o.Write(text, 0, text.Length);
                return int.Parse(File.ReadAllText(replay).Trim());
            }
            byte[] outBytes = outMs.ToArray();
            o.Write(outBytes, 0, outBytes.Length);
        }
        return rc;
    }
}
'@
    Add-Type -TypeDefinition $source -OutputAssembly "$Work/bin/nativehtmlkit.exe" -OutputType ConsoleApplication
    Copy-Item -LiteralPath "$Work/bin/nativehtmlkit.exe" -Destination "$Work/bin/nhk.exe"
} else {
    $py = [IO.File]::ReadAllText((Join-Path $Root 'scripts/test-docs.py'))
    $m = [regex]::Match($py, "(?s)SHIM = r'''(.*?)'''")
    [IO.File]::WriteAllText("$Work/bin/nativehtmlkit", $m.Groups[1].Value, $Utf8)
    & chmod +x "$Work/bin/nativehtmlkit"
    & ln -s nativehtmlkit "$Work/bin/nhk"
}
$prelude = @'
# Stand-in for docker: lists two containers and records every other command.
function global:docker {
    [IO.File]::AppendAllText((Join-Path $env:NHK_SHIM_DIR 'docker.log'), ($args -join ' ') + "`n")
    if ($args[0] -eq 'ps') {
        '{"Command":"\"/docker-entrypoint.sh nginx\"","CreatedAt":"2026-11-16 09:00:00 +0000 UTC","ID":"3f2a9c1d7b44","Image":"nginx:1.27","Labels":"","LocalVolumes":"0","Mounts":"","Names":"web","Networks":"bridge","Ports":"0.0.0.0:8080->80/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}'
        '{"Command":"\"docker-entrypoint.sh postgres\"","CreatedAt":"2026-11-15 18:00:00 +0000 UTC","ID":"9b8e7d6c5a43","Image":"postgres:17","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"db <primary>","Networks":"bridge","Ports":"5432/tcp","RunningFor":"17 hours ago","Size":"0B","State":"exited","Status":"Exited (0) 3 minutes ago"}'
    } elseif ($args[0] -eq 'logs') {
        '2026-11-16T09:00:00Z ready'
        '2026-11-16T09:00:01Z <b>not markup</b> & more'
    }
    $global:LASTEXITCODE = 0
}
'@
[IO.File]::WriteAllText("$Work/prelude.ps1", $prelude, $Utf8)
$hostName = if ($IsWin) { 'nativehtmlkit-host.exe' } else { 'nativehtmlkit-host' }
$RealDir = Split-Path -Parent $Cli    # shim=off blocks find nativehtmlkit and nhk here

# ---- fixture: examples/ in a Git repository -------------------------------------------------
$Template = Join-Path $Work 'template'
$repo = Join-Path $Template 'repo'
New-Item -ItemType Directory -Path $repo | Out-Null
Copy-Item -Recurse -LiteralPath (Join-Path $Root 'examples') -Destination (Join-Path $repo 'examples')
$env:GIT_AUTHOR_NAME = 'example'; $env:GIT_AUTHOR_EMAIL = 'example@example.invalid'
$env:GIT_COMMITTER_NAME = 'example'; $env:GIT_COMMITTER_EMAIL = 'example@example.invalid'
function Git-At([string] $Date) {
    $env:GIT_AUTHOR_DATE = $Date; $env:GIT_COMMITTER_DATE = $Date
    & { $ErrorActionPreference = 'Continue'; git -C $repo @args 2>&1 | Out-Null } @args
    Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
}
& { $ErrorActionPreference = 'Continue'
    git -C $repo init -q 2>&1 | Out-Null
    git -C $repo checkout -q -b main 2>&1 | Out-Null
    git -C $repo config core.autocrlf false 2>&1 | Out-Null
    git -C $repo add -A 2>&1 | Out-Null }
Git-At '2026-11-10T09:00:00Z' commit -q -m 'Add the example scripts'
& { $ErrorActionPreference = 'Continue'
    git -C $repo branch feature/login 2>&1 | Out-Null
    git -C $repo branch release/1.4 2>&1 | Out-Null
    git -C $repo switch -q -c fix/typo 2>&1 | Out-Null }
[IO.File]::WriteAllText((Join-Path $repo 'examples/TYPO.txt'), "fixed`n")
& { $ErrorActionPreference = 'Continue'; git -C $repo add -A 2>&1 | Out-Null }
# -F: Windows PowerShell 5.1 does not escape the quotes of a native argument.
[IO.File]::WriteAllText((Join-Path $Work 'msg.txt'), 'Fix the "quick start" typo')
Git-At '2026-11-12T09:00:00Z' commit -q -F (Join-Path $Work 'msg.txt')
& { $ErrorActionPreference = 'Continue'; git -C $repo switch -q main 2>&1 | Out-Null }
Git-At '2026-11-14T09:00:00Z' merge -q --no-ff -m 'Merge fix/typo' fix/typo

$script:Edition = (& $Shell -NoProfile -Command '[string]$PSVersionTable.PSVersion')

# ---- markdown parsing -----------------------------------------------------------------------
function Parse-Attrs([string] $Text) {
    $h = @{}
    foreach ($m in [regex]::Matches($Text, '([a-z-]+)=("(?:[^"\\]|\\.)*"|\S*)')) {
        $v = $m.Groups[2].Value
        if ($v.StartsWith('"')) { $v = $v.Substring(1, $v.Length - 2).Replace('\"', '"').Replace('\\', '\') }
        $h[$m.Groups[1].Value] = $v
    }
    $h
}
function Get-Blocks([string] $Path) {
    $lines = [IO.File]::ReadAllLines($Path, $Utf8)
    $pending = $null
    $i = 0
    while ($i -lt $lines.Count) {
        $t = $lines[$i].Trim()
        $m = [regex]::Match($t, '^<!--\s*(test|replay|stdout|stderr|submit|not-tested)\s*:?\s*(.*?)\s*-->\s*$')
        if ($m.Success) {
            $pending = @($m.Groups[1].Value, $m.Groups[2].Value)
            if ($pending[0] -eq 'submit' -and $pending[1].Contains('rejected=')) {
                [pscustomobject]@{ Line = $i + 1; Marker = 'submit'; Attrs = (Parse-Attrs $pending[1]); Lang = ''; Code = $null }
                $pending = $null
            }
            $i++; continue
        }
        $f = [regex]::Match($lines[$i], '^(```+|~~~+)\s*([A-Za-z0-9_-]*)')
        if ($f.Success) {
            $fence = $f.Groups[1].Value; $lang = $f.Groups[2].Value; $start = $i + 1
            $j = $i + 1
            while ($j -lt $lines.Count -and -not $lines[$j].StartsWith($fence)) { $j++ }
            $code = if ($j -gt $i + 1) { ($lines[($i + 1)..($j - 1)]) -join "`n" } else { '' }
            if ($pending) {
                $attrs = if ($pending[0] -eq 'not-tested') { @{ reason = $pending[1] } } else { Parse-Attrs $pending[1] }
                [pscustomobject]@{ Line = $start; Marker = $pending[0]; Attrs = $attrs; Lang = $lang; Code = $code }
            } else {
                [pscustomobject]@{ Line = $start; Marker = $null; Attrs = @{}; Lang = $lang; Code = $code }
            }
            $pending = $null
            $i = $j + 1; continue
        }
        if ($t) { $pending = $null }
        $i++
    }
}

# ---- running a block ------------------------------------------------------------------------
function Invoke-Block([string] $Name, [string] $Code, [string] $Lang, [hashtable] $Attrs, [object[]] $Replays, [bool] $Capture) {
    $case = Join-Path $Work ('cases/' + ($Name -replace '[^A-Za-z0-9_.-]', '_'))
    if (Test-Path -LiteralPath $case) { Remove-Item -LiteralPath $case -Recurse -Force }
    New-Item -ItemType Directory -Path $case, "$case/replay" | Out-Null
    $fx = Join-Path $case 'fx'
    Copy-Item -Recurse -LiteralPath $Template -Destination $fx
    New-Item -ItemType Directory -Path "$fx/home" | Out-Null
    foreach ($r in $Replays) {
        [IO.File]::WriteAllText("$case/replay/$($r[0]).rc", [string] $r[1], $Utf8)
        [IO.File]::WriteAllText("$case/replay/$($r[0]).out", [string] $r[2], $Utf8)
    }
    $shimOn = $Attrs['shim'] -ne 'off'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $sep = [IO.Path]::PathSeparator
    $path = if ($shimOn) { "$Work/bin$sep$($env:PATH)" } else { "$RealDir$sep$($env:PATH)" }
    if ($Lang -eq 'bat') {
        [IO.File]::WriteAllText("$case/block.cmd", "@echo off`r`n" + ($Code -replace "`r?`n", "`r`n") + "`r`n", [Text.Encoding]::Default)
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = "/d /c `"$case\block.cmd`""
    } else {
        # A script file run with -File, as a user would run it (UTF-8 with BOM, so Windows
        # PowerShell 5.1 reads non-ASCII text correctly). -EncodedCommand would switch the
        # child to CLIXML on stderr.
        $text = ". '$Work/prelude.ps1'`n`$ErrorActionPreference = 'Continue'`ntry {`n$Code`n} catch { [Console]::Error.WriteLine(`$_); exit 1 }`nexit `$LASTEXITCODE`n"
        [IO.File]::WriteAllText("$case/block.ps1", $text, [System.Text.UTF8Encoding]::new($true))
        $psi.FileName = $Shell
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$case/block.ps1`""
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
    $psi.WorkingDirectory = Join-Path $fx 'repo/examples'
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -like 'NATIVEHTMLKIT*') { $psi.EnvironmentVariables.Remove($k) } }
    $psi.EnvironmentVariables['PATH'] = $path
    $psi.EnvironmentVariables['NHK_SHIM_DIR'] = $case
    $psi.EnvironmentVariables['NHK_REAL'] = $Cli
    $t = $Attrs['cli-timeout']; if (-not $t) { $t = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Timeout) }
    $psi.EnvironmentVariables['NHK_T'] = $t
    $psi.EnvironmentVariables['NATIVEHTMLKIT_CLI_TEST_HEADLESS'] = '1'
    foreach ($v in 'TMP', 'TEMP', 'TMPDIR') { $psi.EnvironmentVariables[$v] = "$Work/tmp" }
    $psi.EnvironmentVariables['APPDATA'] = "$fx/home"
    $psi.EnvironmentVariables.Remove('PROJ_FILE')
    if ($Capture) { $psi.EnvironmentVariables['NHK_CAPTURE'] = '1' }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "block timed out: $Name" }
    $p.WaitForExit()
    $calls = @(if (Test-Path "$case/calls") { [IO.File]::ReadAllLines("$case/calls") })
    [pscustomobject]@{
        Exit = $p.ExitCode
        Out = ($outTask.Result -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '')
        Err = $errTask.Result
        Calls = $calls
        Case = $case
    }
}

function Test-Run([string] $Name, $Run, [int] $Want, $CallsWant, [int[]] $Replayed = @()) {
    $problems = @()
    if ($Run.Exit -ne $Want) { $problems += "exit $($Run.Exit), want $Want" }
    $got = ($Run.Calls | ForEach-Object { ($_ -split ' ')[0] }) -join ' '
    if ($null -ne $CallsWant -and -not ($got -like $CallsWant)) { $problems += "calls '$got', want '$CallsWant'" }
    for ($i = 0; $i -lt $Run.Calls.Count; $i++) {
        $f = $Run.Calls[$i] -split ' '
        $status = ($f[0] -split '@')[0]
        if ($Replayed -notcontains ($i + 1) -and $status -ne '0' -and $f[1] -ne '0') { $problems += "call $($i + 1) wrote stdout with exit $status" }
        if ($status -eq '124' -and $f[2] -eq 'notready') { $problems += "call $($i + 1): document never became ready" }
        if ($status -eq '124' -and $f[3] -ne 'clean') { $problems += "call $($i + 1): error line despite 124" }
    }
    if ($problems.Count) {
        $tail = $Run.Err; if ($tail.Length -gt 400) { $tail = $tail.Substring($tail.Length - 400) }
        Record FAIL $Name (($problems -join '; ') + " | stderr tail: $tail")
    } else { Record PASS $Name "exit $($Run.Exit); calls: $(if ($got) { $got } else { 'none' })" }
}

function Note-Exits([string] $Page, [int[]] $Codes) {
    if (-not $script:ExitSeen.ContainsKey($Page)) { $script:ExitSeen[$Page] = New-Object System.Collections.Generic.List[int] }
    foreach ($c in $Codes) { $script:ExitSeen[$Page].Add($c) }
}
function Add-Text([hashtable] $Map, [string] $Page, [string] $Text) {
    if (-not $Map.ContainsKey($Page)) { $Map[$Page] = New-Object System.Collections.Generic.List[string] }
    $Map[$Page].Add($Text)
}

function Available([string] $Req) {
    switch ($Req) {
        'windows' { return $IsWin }
        'git' { return [bool] (Get-Command git -ErrorAction SilentlyContinue) }
        'ps51' { return $script:Edition -like '5.*' }
        'ps7' { return $script:Edition -notlike '5.*' }
        default { return [bool] (Get-Command $Req -ErrorAction SilentlyContinue) }
    }
}

function New-SubmitCase([string] $Name, [string] $Case, [int] $Call, [hashtable] $Attrs, $Code) {
    $argFile = Join-Path $Case "$Call.args"
    if (-not (Test-Path -LiteralPath $argFile)) { Record FAIL $Name "call $Call did not happen"; return }
    $argv = @([IO.File]::ReadAllText($argFile) -split [char] 0 | Where-Object { $_ })
    $inFile = Join-Path $Case "$Call.in"
    $stdin = ''
    if (Test-Path -LiteralPath $inFile) { $stdin = [IO.File]::ReadAllText($inFile, $Utf8) }
    function Opt([string] $Flag, $Default) {
        for ($i = 0; $i -lt $argv.Count; $i++) {
            if ($argv[$i] -eq $Flag -and $i + 1 -lt $argv.Count) { return $argv[$i + 1] }
            if ($argv[$i].StartsWith("$Flag=")) { return $argv[$i].Substring($Flag.Length + 1) }
        }
        $Default
    }
    $out = Opt '--output-format' $null
    $picks = @()
    if ($Attrs['pick']) { $picks = @($Attrs['pick'] -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [int] $_ }) }
    $expect = $null
    if (-not $Attrs.ContainsKey('error') -and -not $Attrs.ContainsKey('rejected')) { $expect = if ($Code) { $Code + "`n" } else { '' } }
    $command = ''
    foreach ($a in $argv) { if ('select', 'view', 'form' -contains $a) { $command = $a; break } }
    $script:Submit.Add([pscustomobject][ordered]@{
        name = $Name; command = $command; stdin = $stdin
        input_format = (Opt '--input-format' 'lines'); output_format = $(if ($out) { $out } else { 'same' })
        explicit_output = [bool] $out; no_headers = $argv -contains '--no-headers'
        multi = $argv -contains '--multi'; allow_empty = $argv -contains '--allow-empty'
        picks = [object[]] $picks; expect = $expect; expect_error = $Attrs['error']; expect_rejected = $Attrs['rejected']
    })
}

# ---- pages ----------------------------------------------------------------------------------
$CliPattern = '(?<![\w/.-])(nativehtmlkit|nhk)(?![\w-])'
foreach ($file in (Get-ChildItem -LiteralPath $Docs -Recurse -Filter *.md | Sort-Object FullName)) {
    $rel = $file.FullName.Substring($Docs.Length + 1).Replace('\', '/')
    $blocks = @(Get-Blocks $file.FullName)
    $k = 0
    while ($k -lt $blocks.Count) {
        $b = $blocks[$k]; $k++
        if ($b.Marker -eq 'not-tested') {
            $m = [regex]::Match($b.Attrs['reason'], '^excerpt of (examples/[^\s,;]+)')
            if ($m.Success -and (-not $Filter -or $rel.Contains($Filter))) {
                $src = Join-Path $Root $m.Groups[1].Value
                $have = @{}
                if (Test-Path -LiteralPath $src) { foreach ($l in [IO.File]::ReadAllLines($src, $Utf8)) { $have[$l.Trim()] = 1 } }
                $missing = @(($b.Code -split "`n") | Where-Object { $_.Trim() -and -not $have.ContainsKey($_.Trim()) })
                if ($missing.Count) { Record FAIL "${rel}:$($b.Line)" "excerpt differs from $($m.Groups[1].Value): $($missing[0])" }
                else { Record PASS "${rel}:$($b.Line)" "excerpt matches $($m.Groups[1].Value)" }
            }
            continue
        }
        if ($null -eq $b.Marker) {
            if ($b.Code -and ('powershell', 'ps1', 'pwsh', 'bat', 'cmd') -contains $b.Lang -and $b.Code -match $CliPattern) {
                Record FAIL "${rel}:$($b.Line)" 'block calls the CLI but has no test: or not-tested: marker'
            }
            continue
        }
        if ($b.Marker -ne 'test') { Record FAIL "${rel}:$($b.Line)" "'$($b.Marker)' marker without a test block before it"; continue }
        $name = "${rel}:$($b.Line)"
        $follow = @()
        while ($k -lt $blocks.Count -and ('replay', 'stdout', 'stderr', 'submit') -contains $blocks[$k].Marker) { $follow += $blocks[$k]; $k++ }
        if ($Filter -and -not $name.Contains($Filter)) { continue }
        $lang = if ($b.Lang -eq 'cmd') { 'bat' } else { $b.Lang }
        $req = $b.Attrs['requires']
        if ($lang -eq 'bat' -and -not $IsWin) { $req = 'windows' }
        if ($req -and -not (Available $req)) { Record SKIP $name "requires $req"; Add-Text $script:SkippedText $rel $b.Code; continue }
        Add-Text $script:Covered $rel $b.Code
        $want = [int] $b.Attrs['exit']
        $capture = @($follow | Where-Object { $_.Marker -eq 'submit' }).Count -gt 0
        $run = Invoke-Block $name $b.Code $lang $b.Attrs @() $capture
        $callsWant = if ($b.Attrs.ContainsKey('calls')) { $b.Attrs['calls'] } else { $null }
        Test-Run $name $run $want $callsWant
        Note-Exits $rel (@($want) + @($run.Calls | ForEach-Object { [int] (($_ -split '@')[0]) }))
        $last = $run
        $replays = @()
        foreach ($f in $follow) {
            $fname = "$name > $($f.Marker)@$($f.Line)"
            switch ($f.Marker) {
                'replay' {
                    $n = 1; if ($f.Attrs['call']) { $n = [int] $f.Attrs['call'] }
                    $rc = 0; if ($f.Attrs['exit']) { $rc = [int] $f.Attrs['exit'] }
                    $text = if ($f.Code) { $f.Code + "`n" } else { '' }
                    if ($f.Attrs['keep']) { $replays = @($replays) + , @($n, $rc, $text) } else { $replays = @(, @($n, $rc, $text)) }
                    $r = Invoke-Block $fname $b.Code $lang $b.Attrs $replays $false
                    Test-Run $fname $r ([int] $f.Attrs['expect']) $null ([int[]] @($replays | ForEach-Object { $_[0] }))
                    Note-Exits $rel @([int] $f.Attrs['expect'], $rc)
                    $last = $r
                }
                'stdout' {
                    $got = ($last.Out -replace "`r`n", "`n").TrimEnd("`n")
                    $wantText = ([string] $f.Code).TrimEnd("`n")
                    if ($got -ceq $wantText) { Record PASS $fname 'stdout as documented' }
                    else { Record FAIL $fname "stdout '$got', documented '$wantText'" }
                }
                'stderr' {
                    $missing = @(([string] $f.Code -split "`n") | Where-Object { $_.Trim() -and -not $last.Err.Contains($_.Trim()) })
                    if ($missing.Count) { Record FAIL $fname "not in stderr: $($missing -join ' | ')" } else { Record PASS $fname 'stderr lines as documented' }
                }
                'submit' {
                    $n = 1; if ($f.Attrs['call']) { $n = [int] $f.Attrs['call'] }
                    New-SubmitCase $fname $run.Case $n $f.Attrs $f.Code
                    Note-Exits $rel @($(if ($f.Attrs.ContainsKey('error')) { 1 } else { 0 }))
                }
            }
        }
    }
}

# ---- coverage -------------------------------------------------------------------------------
function Cover([string] $What, [string] $Page, [string[]] $Needles, [scriptblock] $Match) {
    if (-not $Match) { $Match = { param($text) $ok = $true; foreach ($n in $Needles) { if (-not $text.Contains($n)) { $ok = $false } }; $ok } }
    foreach ($t in @($script:Covered[$Page])) { if ($t -and (& $Match $t)) { Record PASS "coverage $What" 'tested example'; return } }
    foreach ($t in @($script:SkippedText[$Page])) { if ($t -and (& $Match $t)) { Record SKIP "coverage $What" 'only in blocks skipped here'; return } }
    Record FAIL "coverage $What" 'no tested example'
}
function Help-Options([string[]] $Cmd) {
    $text = (& $Cli @Cmd --help) -join "`n"
    @([regex]::Matches($text, '(?m)^\s+(?:-\w, )?(--[a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
if (-not $Filter) {
    foreach ($cmd in 'select', 'view', 'form', 'doctor') {
        foreach ($opt in (Help-Options @($cmd))) { Cover "commands/$cmd.md $opt" "commands/$cmd.md" @($cmd, $opt) }
    }
    foreach ($opt in (Help-Options @())) {
        $found = $false
        foreach ($cmd in 'select', 'view', 'form', 'doctor') { foreach ($t in @($script:Covered["commands/$cmd.md"])) { if ($t -and $t.Contains($opt)) { $found = $true } } }
        if ($found) { Record PASS "coverage nativehtmlkit $opt" 'tested example' } else { Record FAIL "coverage nativehtmlkit $opt" 'missing' }
    }
    foreach ($short in '-h', '-V') { Cover "nativehtmlkit $short" 'commands/doctor.md' @() { param($text) $text -cmatch ('(?<![\w-])' + $short + '(?![\w-])') } }
    Cover 'nativehtmlkit help COMMAND' 'commands/doctor.md' @('help select')
    foreach ($f in 'lines', 'csv', 'tsv', 'json', 'ndjson') { Cover "input-formats.md --input-format $f" 'input-formats.md' @("--input-format $f") }
    Cover 'input-formats.md --no-headers' 'input-formats.md' @('--no-headers')
    foreach ($f in 'same', 'lines', 'csv', 'tsv', 'json', 'ndjson') { Cover "output-formats.md --output-format $f" 'output-formats.md' @("--output-format $f") }
    foreach ($l in 'off', 'normal', 'debug', 'trace') { Cover "environment-and-diagnostics.md --diagnostics $l" 'environment-and-diagnostics.md' @("--diagnostics $l") }
    foreach ($v in 'NATIVEHTMLKIT_HOST_BINARY', 'NATIVEHTMLKIT_DIAGNOSTICS', 'NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID') { Cover "environment-and-diagnostics.md $v" 'environment-and-diagnostics.md' @($v) }
    Cover 'css-and-forms.md --css' 'css-and-forms.md' @('--css')
    Cover 'css-and-forms.md --html' 'css-and-forms.md' @('--html')
    $subs = @($script:Submit | Where-Object { $_.name.StartsWith('output-formats.md') })
    foreach ($f in 'same', 'lines', 'csv', 'tsv', 'json', 'ndjson') {
        $ok = @($subs | Where-Object { ($_.output_format -eq $f -and $_.explicit_output) -or ($f -eq 'same' -and -not $_.explicit_output) }).Count -gt 0
        if ($ok) { Record PASS "coverage output-formats.md submit output $f" 'verified output' } else { Record FAIL "coverage output-formats.md submit output $f" 'missing' }
    }
    $seen = @($script:ExitSeen['exit-codes-and-scripting.md'])
    foreach ($e in 0, 1, 2, 124, 130) {
        if ($seen -contains $e) { Record PASS "coverage exit-codes-and-scripting.md exit $e" 'tested' }
        elseif ($e -eq 130 -and -not $IsWin) { Record SKIP "coverage exit-codes-and-scripting.md exit $e" 'Ctrl+C example is Windows only' }
        else { Record FAIL "coverage exit-codes-and-scripting.md exit $e" 'missing' }
    }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Root 'examples/catalog.toml'))) {
        $m = [regex]::Match($line, '^windows\s*=\s*"([^"]+)"')
        if (-not $m.Success) { continue }
        $f = $m.Groups[1].Value
        $rx = '(?<![\w/.-])(\.[\\/])?' + [regex]::Escape($f).Replace('/', '[\\/]') + '(?![\w.-])'
        $found = $false; $skipped = $false
        foreach ($page in $script:Covered.Keys) { foreach ($t in $script:Covered[$page]) { if ($t -match $rx) { $found = $true } } }
        foreach ($page in $script:SkippedText.Keys) { foreach ($t in $script:SkippedText[$page]) { if ($t -match $rx) { $skipped = $true } } }
        if ($found) { Record PASS "coverage catalog $f" 'run by a tested block' }
        elseif ($skipped) { Record SKIP "coverage catalog $f" 'only in blocks skipped here' }
        else { Record FAIL "coverage catalog $f" 'no tested block runs it' }
    }
}

# ---- a real Ctrl+C (Windows) ------------------------------------------------------------------
# The exit-codes page shows how a script handles 130 with a replayed status; this proves the
# released CLI really exits 130 on Ctrl+C. A wrapper PowerShell gets its own (hidden) console,
# starts the CLI on that console, waits for the document to be ready and raises CTRL_C_EVENT
# for the console, ignoring it itself. Nothing else shares that console.
if ($IsWin -and (-not $Filter -or $Filter -like 'exit-codes*')) {
    $cc = Join-Path $Work 'ctrlc'
    New-Item -ItemType Directory -Path $cc | Out-Null
    [IO.File]::WriteAllText("$cc/in.txt", "a`nb`n", $Utf8)
    $wrapper = @'
param($Cli, $Dir)
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool a); [DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'
$env:NATIVEHTMLKIT_CLI_TEST_HEADLESS = '1'; $env:NATIVEHTMLKIT_DIAGNOSTICS = 'debug'
# A process started from a service such as sshd may inherit "ignore Ctrl+C"; clear it so the
# CLI starts as it would in an ordinary console.
[W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
$p = Start-Process -FilePath $Cli -ArgumentList 'select', '--title', 'ctrl-c', '--timeout', '60' -NoNewWindow -PassThru `
    -RedirectStandardInput "$Dir\in.txt" -RedirectStandardOutput "$Dir\out.txt" -RedirectStandardError "$Dir\err.txt"
$null = $p.Handle
for ($i = 0; $i -lt 150; $i++) {
    Start-Sleep -Milliseconds 100
    try { if ([IO.File]::ReadAllText("$Dir\err.txt") -match '"event":"window.ready"') { break } } catch { }
}
[W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
$sent = [W.K]::GenerateConsoleCtrlEvent(0, 0)
$done = $p.WaitForExit(20000)
[IO.File]::WriteAllText("$Dir\result.txt", "$sent $done $($p.ExitCode) $((Get-Item "$Dir\out.txt").Length)")
'@
    [IO.File]::WriteAllText("$cc/ctrlc.ps1", $wrapper, $Utf8)
    $env:TMP = "$Work\tmp"; $env:TEMP = "$Work\tmp"
    Start-Process -FilePath $Shell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$cc\ctrlc.ps1`"", "`"$Cli`"", "`"$cc`"" -WindowStyle Hidden -Wait
    $res = if (Test-Path "$cc/result.txt") { [IO.File]::ReadAllText("$cc/result.txt") } else { 'no result' }
    if ($res -eq 'True True 130 0') { Record PASS 'ctrl-c exits 130' 'real CTRL_C_EVENT: exit 130, empty stdout' }
    else { Record FAIL 'ctrl-c exits 130' "result: $res" }
    Note-Exits 'exit-codes-and-scripting.md' @(130)
}

# ---- submit cases -----------------------------------------------------------------------------
if (-not $SubmitCases) { $SubmitCases = Join-Path $Work 'submit-cases.json' }
$json = ConvertTo-Json -InputObject ([object[]] $script:Submit.ToArray()) -Depth 5
if ($script:Submit.Count -eq 0) { $json = '[]' }
[IO.File]::WriteAllText($SubmitCases, $json, $Utf8)
$py = Get-Command python3 -ErrorAction SilentlyContinue
if ($script:Submit.Count -and $py -and (Get-Command cargo -ErrorAction SilentlyContinue) -and -not $IsWin) {
    $lines = & $py.Source -I (Join-Path $Root 'scripts/test-docs.py') --only-submit-cases --check-submit-cases $SubmitCases
    foreach ($l in $lines) {
        $p = $l -split "`t", 3
        if ($p.Count -eq 3 -and ('PASS', 'FAIL') -contains $p[0]) { Record $p[0] $p[1] $p[2] }
    }
} elseif ($script:Submit.Count) {
    Record SKIP 'submit-outputs' "$($script:Submit.Count) cases written to $SubmitCases; check them with: python3 scripts/test-docs.py --only-submit-cases --check-submit-cases FILE"
}

# ---- leftovers --------------------------------------------------------------------------------
Start-Sleep -Seconds 1
$hostPath = Join-Path $RealDir $hostName
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $hostPath } catch { $false } }).Count
$dirs = @(Get-ChildItem -LiteralPath "$Work/tmp" -Directory -Filter 'nativehtmlkit-cli-*').Count
if ($left -eq 0 -and $dirs -eq 0) { Record PASS zz-no-leftovers 'no host process left, every private session directory removed' }
else { Record FAIL zz-no-leftovers "host processes left: $left; session directories: $dirs ($((Get-ChildItem -LiteralPath "$Work/tmp" -Directory -Filter 'nativehtmlkit-cli-*' | ForEach-Object { $_.Name + ' ' + $_.CreationTime.ToString('HH:mm:ss') }) -join ', '))" }

$pass = @($script:Results | Where-Object Status -eq 'PASS').Count
$fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
$skip = @($script:Results | Where-Object Status -eq 'SKIP').Count
$edition = (& $Shell -NoProfile -Command '[string]$PSVersionTable.PSVersion')
Write-Host "test-docs.ps1 (windows): $pass PASS, $fail FAIL, $skip SKIP (CLI $((& $Cli --version) -replace 'nativehtmlkit ', ''), blocks run by PowerShell $edition, work dir $Work)"
if ($fail -eq 0) { Get-ChildItem -LiteralPath $Work -Exclude 'submit-cases.json' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
exit $(if ($fail -eq 0) { 0 } else { 1 })
