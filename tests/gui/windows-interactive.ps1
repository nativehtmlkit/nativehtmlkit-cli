# Native Windows interactive-desktop qualification for the NativeHTMLKit CLI.
#
# Must run INSIDE a logged-in interactive desktop (RDP or console), e.g. started from an
# administrative SSH session with the original UI4ME helper:
#   start_interactive.ps1 -UserName <desktop user> -ScriptPath <this file> -TimeoutSeconds 900
# $Root\bin is a clean extraction of the release archive (nativehtmlkit.exe, nhk.exe,
# nativehtmlkit-host.exe, examples\sample-form.html).
# SSH alone has no desktop and is not GUI evidence. UI Automation is used ONLY to locate
# elements; all actions are real OS input (SendInput mouse/keyboard) on the real window.
# Each case records exact stdout bytes, stderr, exit code, screenshots and leftover
# processes under evidence\<case>\, and a PASS/FAIL row in evidence\results.tsv.
param(
    [string]$Root = (Split-Path -Parent $PSCommandPath),
    [string[]]$Cases = @()
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class NhkInput {
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll")] public static extern bool FreeConsole();
  [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
  [DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  // Freeze every thread of a process (PROCESS_SUSPEND_RESUME), as a debugger would.
  public static int Suspend(uint pid) {
    IntPtr h = OpenProcess(0x0800, false, pid);
    if (h == IntPtr.Zero) return Marshal.GetLastWin32Error();
    try { return NtSuspendProcess(h); } finally { CloseHandle(h); }
  }
  public static void Click(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(80);
    var a = new INPUT[2];
    a[0].type = 0; a[0].u.mi.flags = 0x0002; a[1].type = 0; a[1].u.mi.flags = 0x0004;
    SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Key(ushort vk) {
    var a = new INPUT[2];
    a[0].type = 1; a[0].u.ki.vk = vk; a[1].type = 1; a[1].u.ki.vk = vk; a[1].u.ki.flags = 0x0002;
    SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Text(string s) {
    foreach (char c in s) {
      var a = new INPUT[2];
      a[0].type = 1; a[0].u.ki.scan = c; a[0].u.ki.flags = 0x0004;
      a[1].type = 1; a[1].u.ki.scan = c; a[1].u.ki.flags = 0x0004 | 0x0002;
      SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(15);
    }
  }
}
'@
$UIA = [System.Windows.Automation.AutomationElement]
$Bin = Join-Path $Root 'bin'
$Out = Join-Path $Root 'evidence'
New-Item -ItemType Directory -Force $Out | Out-Null
$Results = Join-Path $Out 'results.tsv'
if (-not (Test-Path $Results)) { "case`tresult`texpected_rc`tactual_rc`tdetail" | Set-Content -Encoding UTF8 $Results }
$env:NATIVEHTMLKIT_HOST_BINARY = Join-Path $Bin 'nativehtmlkit-host.exe'
$script:Log = Join-Path $Out 'suite.log'

function Log($m) { "$(Get-Date -Format o) $m" | Add-Content -Encoding UTF8 $script:Log }
function Fixture($name, [byte[]]$bytes) { $p = Join-Path $Out $name; [IO.File]::WriteAllBytes($p, $bytes); $p }
function Utf8([string]$s) { [Text.UTF8Encoding]::new($false).GetBytes($s) }

function Shot($name) {
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $screen.Size); $bmp.Save((Join-Path $script:CaseDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $g.Dispose(); $bmp.Dispose() }
}

function Start-Case($name, $inputFile, [string[]]$arguments) {
    $script:Case = $name
    $script:CaseDir = Join-Path $Out $name
    Remove-Item -Recurse -Force $script:CaseDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $script:CaseDir | Out-Null
    Copy-Item $inputFile (Join-Path $script:CaseDir 'stdin.bin')
    ('nhk.exe ' + ($arguments -join ' ') + ' < ' + (Split-Path $inputFile -Leaf)) | Set-Content -Encoding UTF8 (Join-Path $script:CaseDir 'command.txt')
    $quoted = $arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $script:Proc = Start-Process -FilePath (Join-Path $Bin 'nhk.exe') -ArgumentList $quoted -PassThru -NoNewWindow `
        -RedirectStandardInput $inputFile -RedirectStandardOutput (Join-Path $script:CaseDir 'stdout.bin') `
        -RedirectStandardError (Join-Path $script:CaseDir 'stderr.txt')
    # Cache the process handle now; otherwise .NET reports a null ExitCode after exit.
    $null = $script:Proc.Handle
    Log "start $name pid=$($script:Proc.Id) args=$($arguments -join ' ')"
}

function Find-Window($title, $timeout = 20) {
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        $cond = [System.Windows.Automation.PropertyCondition]::new($UIA::NameProperty, $title)
        $w = $UIA::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
        if ($w) { Start-Sleep -Milliseconds 700; return $w }
        if ($script:Proc.HasExited) { return $null }
        Start-Sleep -Milliseconds 200
    }
    $null
}
function Find-Element($window, $name, $type = $null) {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $all = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($e in $all) {
            $c = $e.Current
            if ($c.Name -eq $name -and (-not $type -or $c.ControlType.ProgrammaticName -eq $type)) { return $e }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "element '$name' not found"
}
# A row's selection control (the table cell carries the same accessible name).
function Find-Pick($window, $row) {
    try { Find-Element $window "Select row $row" 'ControlType.CheckBox' } catch { Find-Element $window "Select row $row" 'ControlType.RadioButton' }
}
function Click-Element($element) {
    $r = $element.Current.BoundingRectangle
    [NhkInput]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 350
}
function Focus-Window($w) {
    [void][NhkInput]::SetForegroundWindow([IntPtr]$w.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 300
}
function Dump-Tree($w) {
    $rows = foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current; "{0}`t{1}`t{2}" -f $c.ControlType.ProgrammaticName, $c.Name, $c.BoundingRectangle
    }
    $rows | Set-Content -Encoding UTF8 (Join-Path $script:CaseDir 'uia-tree.tsv')
}
# Only this suite's own processes count (started from $Bin, in this desktop session); other
# NativeHTMLKit sessions on the shared desktop are none of this suite's business.
function Session-Hosts {
    $session = (Get-Process -Id $PID).SessionId
    @(Get-Process nativehtmlkit, nhk, nativehtmlkit-host -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}
function Own-Processes { @(Session-Hosts | Where-Object { $_.Path -and $_.Path.StartsWith($Bin, [StringComparison]::OrdinalIgnoreCase) }) }
function Foreign-Windows { @(Session-Hosts | Where-Object { $_.ProcessName -eq 'nativehtmlkit-host' -and -not ($_.Path -and $_.Path.StartsWith($Bin, [StringComparison]::OrdinalIgnoreCase)) }).Count }
function Leftovers { (Own-Processes).Count }
# Remove everything this suite started, so nothing of ours stays on the shared desktop.
function Cleanup-Own { Own-Processes | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
function Verdict($wantRc, [byte[]]$wantOut) {
    if (-not $script:Proc.WaitForExit(30000)) { $rc = 'TIMEOUT'; try { $script:Proc.Kill() } catch {} } else { $rc = $script:Proc.ExitCode }
    Start-Sleep -Milliseconds 800
    [IO.File]::WriteAllBytes((Join-Path $script:CaseDir 'expected-stdout.bin'), $wantOut)
    $got = [IO.File]::ReadAllBytes((Join-Path $script:CaseDir 'stdout.bin'))
    $ok = $true; $detail = ''
    if ("$rc" -ne "$wantRc") { $ok = $false; $detail += "rc $rc!=$wantRc; " }
    if ([Convert]::ToBase64String($got) -ne [Convert]::ToBase64String($wantOut)) { $ok = $false; $detail += 'stdout mismatch; ' }
    $left = if ($script:SkipLeftovers) { 0 } else { Leftovers }
    "leftover_processes=$left" | Set-Content (Join-Path $script:CaseDir 'cleanup.txt')
    if ($left -ne 0) { $ok = $false; $detail += "leftovers=$left (removed); "; Cleanup-Own }
    ($got | ForEach-Object { '{0:x2}' -f $_ }) -join ' ' | Set-Content (Join-Path $script:CaseDir 'stdout.hex.txt')
    $res = if ($ok) { 'PASS' } else { 'FAIL' }
    if (-not $detail) { $detail = 'exact stdout, no leftovers' }
    "$script:Case`t$res`t$wantRc`t$rc`t$detail" | Add-Content -Encoding UTF8 $Results
    Log "$script:Case $res $detail"
}
# An additional assertion recorded as its own PASS/FAIL row.
function Check($name, [bool]$ok, $detail) {
    $res = if ($ok) { 'PASS' } else { 'FAIL' }
    "$name`t$res`t-`t-`t$detail" | Add-Content -Encoding UTF8 $Results
    Log "$name $res $detail"
}
function Stderr-Text { [IO.File]::ReadAllText((Join-Path $script:CaseDir 'stderr.txt'), [Text.Encoding]::UTF8) }
$Sentinel = 'S3NTINEL-do-not-log-7f3a'
function Guard([scriptblock]$body) {
    try { & $body } catch {
        Log "case $script:Case exception: $_"
        try { Shot 'zz-exception' } catch {}
        Cleanup-Own
        "$script:Case`tFAIL`t-`t-`texception: $($_.Exception.Message -replace '\s+', ' ')" | Add-Content -Encoding UTF8 $Results
    }
}

$abc = Fixture 'abc.txt' (Utf8 "alpha`nbeta`ngamma`n")
$C = @{}
$C['s01_work_area'] = {
    # Core 1.0.3: a new window's frame is inside the monitor's work area when it is shown,
    # also for the later windows of a cascade. Eight windows are opened one after another.
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $outside = @(); $frames = @()
    foreach ($i in 1..8) {
        Start-Case 's01-work-area' $abc @('view', '--title', "NHK area $i")
        $w = Find-Window "NHK area $i"
        $f = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$f)
        $frames += "$($f.Left),$($f.Top),$($f.Right),$($f.Bottom)"
        if ($f.Left -lt $area.Left -or $f.Top -lt $area.Top -or $f.Right -gt $area.Right -or $f.Bottom -gt $area.Bottom) { $outside += $i }
        if ($i -eq 8) { Shot '01-eighth-window' }
        Click-Element (Find-Element $w 'Close' 'ControlType.Button')
        if (-not $script:Proc.WaitForExit(15000)) { try { $script:Proc.Kill() } catch {} }
    }
    "work_area=$($area.Left),$($area.Top),$($area.Right),$($area.Bottom)`r`n" + ($frames -join "`r`n") | Set-Content (Join-Path $script:CaseDir 'geometry.txt')
    Check 's01-work-area' ($outside.Count -eq 0 -and (Leftovers) -eq 0) "8 windows opened in a row; frames outside the work area $($area.Width)x$($area.Height): $(if ($outside.Count) { $outside -join ',' } else { 'none' }) (see geometry.txt)"
    Cleanup-Own
}
$C['s02_multi'] = {
    Start-Case 's02-multi-beta' $abc @('select', '--multi', '--title', 'NHK s02')
    $w = Find-Window 'NHK s02'; Focus-Window $w; Dump-Tree $w; Shot '01-open'
    Click-Element (Find-Pick $w 2); Shot '02-beta-checked'
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "beta`n")
}
$C['s02_single'] = {
    Start-Case 's02-single-radio' $abc @('select', '--title', 'NHK single')
    $w = Find-Window 'NHK single'; Focus-Window $w
    Click-Element (Find-Pick $w 1); Click-Element (Find-Pick $w 3); Shot '01-radio-gamma'
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "gamma`n")
}
$C['s03_cancel'] = {
    Start-Case 's03-cancel' $abc @('select', '--multi', '--title', 'NHK cancel')
    $w = Find-Window 'NHK cancel'; Focus-Window $w
    Click-Element (Find-Pick $w 2); Click-Element (Find-Element $w 'Cancel' 'ControlType.Button')
    Verdict 2 ([byte[]]@())
}
$C['s03_close'] = {
    Start-Case 's03-titlebar-close' $abc @('select', '--multi', '--title', 'NHK close')
    $w = Find-Window 'NHK close'; Focus-Window $w; Click-Element (Find-Pick $w 1); Shot '01-before-close'
    # The native caption Close button (non-client area; AccessKit owns the UIA tree, so the
    # caption is located from the live window rectangle). Real mouse click.
    Focus-Window $w
    # AccessKit's UIA root rectangle is the client area; the caption needs the frame rect.
    $frame = New-Object NhkInput+RECT
    [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$frame)
    $x = $frame.Right - 30; $y = $frame.Top + 16
    "client=$($w.Current.BoundingRectangle) frame=$($frame.Left),$($frame.Top),$($frame.Right),$($frame.Bottom) click=$x,$y" | Set-Content (Join-Path $script:CaseDir 'geometry.txt')
    [NhkInput]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 400; Shot '02-hover-close'
    [NhkInput]::Click($x, $y); Start-Sleep -Milliseconds 800; Shot '03-after-click'
    Verdict 2 ([byte[]]@())
}
$C['s03_empty_submit'] = {
    Start-Case 's03-empty-submit-error' $abc @('select', '--multi', '--title', 'NHK empty')
    $w = Find-Window 'NHK empty'; Focus-Window $w
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button'); Start-Sleep -Milliseconds 500; Shot '01-error-shown'
    Click-Element (Find-Pick $w 3); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "gamma`n")
}
$C['s04_invalid'] = {
    Start-Case 's04-invalid-json' (Fixture 'bad.json' (Utf8 '[1,')) @('select', '--input-format', 'json'); Verdict 1 ([byte[]]@())
    Start-Case 's04-invalid-csv' (Fixture 'bad.csv' (Utf8 "a,b`n1,2,3`n")) @('select', '--input-format', 'csv'); Verdict 1 ([byte[]]@())
    Start-Case 's04-empty-input' (Fixture 'empty.txt' ([byte[]]@())) @('select'); Verdict 1 ([byte[]]@())
    Start-Case 's04-bad-utf8' (Fixture 'bad.txt' ([byte[]]@(0xff, 0xfe, 0x0a))) @('select'); Verdict 1 ([byte[]]@())
    Start-Case 's04-usage-error' $abc @('select', '--bogus'); Verdict 1 ([byte[]]@())
}
$C['s05_bounds'] = {
    $rows = Fixture 'rows2000.txt' (Utf8 ((1..2000 | ForEach-Object { "row $_" }) -join "`n"))
    Start-Case 's05-2000-rows' $rows @('select', '--title', 'NHK 2000')
    $w = Find-Window 'NHK 2000' 40; Focus-Window $w; Shot '01-open'
    Click-Element (Find-Element $w 'Cancel' 'ControlType.Button')
    Verdict 2 ([byte[]]@())
    Start-Case 's05-2001-rows' (Fixture 'rows2001.txt' (Utf8 ((1..2001) -join "`n"))) @('select'); Verdict 1 ([byte[]]@())
}
$C['s06_json'] = {
    $typed = Fixture 'typed.json' (Utf8 '[{"id":1,"ok":true,"name":"x","tags":["a"],"none":null},{"id":2.5,"ok":false,"name":"Příliš 😀","tags":[],"none":null}]')
    Start-Case 's06-json-types' $typed @('select', '--input-format', 'json', '--title', 'NHK json')
    $w = Find-Window 'NHK json'; Focus-Window $w; Shot '01-open'
    Click-Element (Find-Pick $w 2); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "[{`"id`":2.5,`"ok`":false,`"name`":`"Příliš 😀`",`"tags`":[],`"none`":null}]`n")
}
$C['s07_csv'] = {
    $csv = Fixture 'quoting.csv' (Utf8 "name,comment`nplain,`"has, comma`"`nquote,`"say `"`"hi`"`"`"`nnl,`"line1`nline2`"`n")
    Start-Case 's07-csv-quoting' $csv @('select', '--input-format', 'csv', '--multi', '--title', 'NHK csv')
    $w = Find-Window 'NHK csv'; Focus-Window $w; Shot '01-open'
    1..3 | ForEach-Object { Click-Element (Find-Pick $w $_) }
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "name,comment`nplain,`"has, comma`"`nquote,`"say `"`"hi`"`"`"`nnl,`"line1`nline2`"`n")
}
$C['s08_form'] = {
    Start-Case 's08-form' $abc @('form', '--html', (Join-Path $Bin 'examples\sample-form.html'), '--title', 'NHK form')
    $w = Find-Window 'NHK form'; Focus-Window $w; Dump-Tree $w; Shot '01-open'
    Click-Element (Find-Element $w 'Submit' 'ControlType.Button'); Start-Sleep -Milliseconds 500; Shot '02-required-error'
    $edit = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit))
    Click-Element $edit; [NhkInput]::Text('Demo Příliš'); Start-Sleep -Milliseconds 300
    Click-Element (Find-Element $w 'I confirm the details' 'ControlType.CheckBox'); Shot '03-filled'
    Click-Element (Find-Element $w 'Submit' 'ControlType.Button')
    Verdict 0 (Utf8 "{`"entries`":[{`"kind`":`"text`",`"name`":`"project`",`"value`":`"Demo Příliš`"},{`"kind`":`"text`",`"name`":`"environment`",`"value`":`"development`"},{`"kind`":`"text`",`"name`":`"confirm`",`"value`":`"yes`"}]}`n")
}
$C['s09_keyboard'] = {
    Start-Case 's09-keyboard' $abc @('select', '--multi', '--title', 'NHK keys')
    $w = Find-Window 'NHK keys'; Focus-Window $w
    Click-Element (Find-Pick $w 1)        # focus lands on row 1's checkbox (now checked)
    [NhkInput]::Key(0x20)                                   # Space: uncheck row 1
    [NhkInput]::Key(0x09); [NhkInput]::Key(0x20)            # Tab to row 2, Space: check
    Start-Sleep -Milliseconds 300; Shot '01-keyboard-row2'
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "beta`n")
}
$C['s09_resize'] = {
    Start-Case 's09-resize' $abc @('view', '--title', 'NHK resize')
    $w = Find-Window 'NHK resize'; Focus-Window $w; Shot '01-before'
    $hwnd = [IntPtr]$w.Current.NativeWindowHandle
    $before = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$before)
    $sig = '[DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);'
    if (-not ('NhkMouse' -as [type])) { Add-Type -Name NhkMouse -Namespace '' -MemberDefinition $sig }
    # Grab the real frame's sizing border (outside the client area) with the mouse. Windows
    # cascades new windows, so the bottom-right corner can lie below the screen edge; the
    # top-left corner is always on screen. Dragging it inwards shrinks the window.
    $x0 = $before.Left + 4; $y0 = $before.Top + 4
    [void][NhkInput]::SetCursorPos($x0, $y0); Start-Sleep -Milliseconds 300
    [NhkMouse]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    1..15 | ForEach-Object { [void][NhkInput]::SetCursorPos($x0 + 17 * $_, $y0 + 10 * $_); Start-Sleep -Milliseconds 40 }
    [NhkMouse]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 800; Shot '02-after-resize'
    $after = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$after)
    $client = $w.Current.BoundingRectangle
    "frame_before=$($before.Left),$($before.Top),$($before.Right),$($before.Bottom) frame_after=$($after.Left),$($after.Top),$($after.Right),$($after.Bottom) client_after=$client" | Set-Content (Join-Path $script:CaseDir 'geometry.txt')
    Click-Element (Find-Element $w 'Close' 'ControlType.Button')
    Verdict 0 ([byte[]]@())
    if (($after.Right - $after.Left) -ge ($before.Right - $before.Left) -or ($after.Bottom - $after.Top) -ge ($before.Bottom - $before.Top)) {
        "s09-resize-geometry`tFAIL`t-`t-`twindow size did not shrink: $($before.Right-$before.Left)x$($before.Bottom-$before.Top) -> $($after.Right-$after.Left)x$($after.Bottom-$after.Top)" | Add-Content -Encoding UTF8 $Results
    } else {
        "s09-resize-geometry`tPASS`t-`t-`tframe $($before.Right-$before.Left)x$($before.Bottom-$before.Top) -> $($after.Right-$after.Left)x$($after.Bottom-$after.Top); document re-laid out (see 02-after-resize.png)" | Add-Content -Encoding UTF8 $Results
    }
}
$C['s09_resize_keeps_footer'] = {
    # A long list in a window made 150 px shorter: the table must give up the height and the
    # buttons must stay inside the window. (With viewport-height units the host kept the old
    # layout and the footer left the window; see the project bug register.)
    $rows60 = Fixture 'rows60.txt' (Utf8 ((1..60 | ForEach-Object { "row $_" }) -join "`n"))
    Start-Case 's09-resize-keeps-footer' $rows60 @('select', '--multi', '--title', 'NHK footer')
    $w = Find-Window 'NHK footer'; Focus-Window $w; Shot '01-before'
    $hwnd = [IntPtr]$w.Current.NativeWindowHandle
    # No repositioning: since Core 1.0.3 a new window's frame is inside the work area (s01).
    Click-Element (Find-Pick $w 2)
    $before = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$before)
    $x0 = [int](($before.Left + $before.Right) / 2); $y0 = $before.Bottom - 4      # bottom sizing border
    [void][NhkInput]::SetCursorPos($x0, $y0); Start-Sleep -Milliseconds 300
    [NhkInput]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    1..15 | ForEach-Object { [void][NhkInput]::SetCursorPos($x0, $y0 - 10 * $_); Start-Sleep -Milliseconds 40 }
    [NhkInput]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 800; Shot '02-after-vertical-shrink'
    $after = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$after)
    $submit = Find-Element $w 'Submit selection' 'ControlType.Button'
    $r = $submit.Current.BoundingRectangle
    $inside = ($r.Y -ge $after.Top) -and (($r.Y + $r.Height) -le $after.Bottom)
    Click-Element $submit
    Verdict 0 (Utf8 "row 2`n")
    Check 's09-resize-keeps-footer-geometry' ((($after.Bottom - $after.Top) -lt ($before.Bottom - $before.Top)) -and $inside) "frame height $($before.Bottom - $before.Top) -> $($after.Bottom - $after.Top); Submit button at y=$([int]$r.Y)..$([int]($r.Y + $r.Height)) inside the frame $($after.Top)..$($after.Bottom): $inside"
}
$C['s09_resize_vh_css'] = {
    # The same shrink with a user stylesheet that sizes the list in viewport-height units
    # (the CLI's own layout up to 0.1.1). Core re-resolves vh on resize since 1.0.3
    # (NHK-CROSS-0005); with an older host the Submit button leaves the window.
    $css = Fixture 'vh.css' (Utf8 'main{display:block;height:auto;min-height:100vh}#nhk-selection-form{display:block}.scroll{max-height:calc(100vh - 170px)}')
    $rows60 = Fixture 'rows60.txt' (Utf8 ((1..60 | ForEach-Object { "row $_" }) -join "`n"))
    Start-Case 's09-resize-vh-css' $rows60 @('select', '--multi', '--css', $css, '--title', 'NHK vh')
    $w = Find-Window 'NHK vh'; Focus-Window $w; Shot '01-before'
    $hwnd = [IntPtr]$w.Current.NativeWindowHandle
    Click-Element (Find-Pick $w 2)
    $before = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$before)
    $x0 = [int](($before.Left + $before.Right) / 2); $y0 = $before.Bottom - 4
    [void][NhkInput]::SetCursorPos($x0, $y0); Start-Sleep -Milliseconds 300
    [NhkInput]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    1..15 | ForEach-Object { [void][NhkInput]::SetCursorPos($x0, $y0 - 10 * $_); Start-Sleep -Milliseconds 40 }
    [NhkInput]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 800; Shot '02-after-vertical-shrink'
    $after = New-Object NhkInput+RECT; [void][NhkInput]::GetWindowRect($hwnd, [ref]$after)
    $submit = Find-Element $w 'Submit selection' 'ControlType.Button'
    $r = $submit.Current.BoundingRectangle
    $inside = ($r.Y -ge $after.Top) -and (($r.Y + $r.Height) -le $after.Bottom)
    Click-Element $submit
    Verdict 0 (Utf8 "row 2`n")
    Check 's09-resize-vh-css-geometry' ((($after.Bottom - $after.Top) -lt ($before.Bottom - $before.Top)) -and $inside) "frame height $($before.Bottom - $before.Top) -> $($after.Bottom - $after.Top); Submit button at y=$([int]$r.Y)..$([int]($r.Y + $r.Height)) inside the frame $($after.Top)..$($after.Bottom): $inside"
}
$C['s10_hostile'] = {
    $h = Fixture 'hostile.txt' (Utf8 "<script>alert(1)</script>`n<b>bold?</b> & `"q`" 's`nPříliš žluťoučký kůň 漢字 😀 עברית`n")
    Start-Case 's10-hostile-text' $h @('select', '--multi', '--title', '<i>T</i> & 😀')
    $w = Find-Window '<i>T</i> & 😀'; Focus-Window $w; Shot '01-literal-text'
    Click-Element (Find-Pick $w 1); Click-Element (Find-Pick $w 3)
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "<script>alert(1)</script>`nPříliš žluťoučký kůň 漢字 😀 עברית`n")
}
$C['view'] = {
    Start-Case 'view-lines-close' (Fixture 'ps.txt' (Utf8 "PID CMD`n1 init`n42 <shell> & co`n")) @('view', '--title', 'NHK view')
    $w = Find-Window 'NHK view'; Focus-Window $w; Shot '01-open'
    Click-Element (Find-Element $w 'Close' 'ControlType.Button')
    Verdict 0 ([byte[]]@())
}
$C['s11_kill'] = {
    Start-Case 's11-kill-launcher' $abc @('select', '--multi', '--title', 'NHK kill')
    $w = Find-Window 'NHK kill'; Shot '01-open'
    Stop-Process -Id $script:Proc.Id -Force; Start-Sleep -Seconds 3; Shot '02-after-kill'
    $left = Leftovers
    $res = if ($left -eq 0) { 'PASS' } else { 'FAIL' }
    "$script:Case`t$res`t-`t-`tafter TerminateProcess of CLI: leftover processes=$left" | Add-Content -Encoding UTF8 $Results
}
$C['s11_ctrlc'] = {
    # nhk gets its own console (no -NoNewWindow); a helper attaches to that console and
    # raises a genuine CTRL_C_EVENT for every process on it, as a terminal Ctrl+C would.
    $script:Case = 's11-ctrl-c'; $script:CaseDir = Join-Path $Out $script:Case
    Remove-Item -Recurse -Force $script:CaseDir -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $script:CaseDir | Out-Null
    $script:Proc = Start-Process -FilePath (Join-Path $Bin 'nhk.exe') -ArgumentList @('select','--multi','--title','"NHK ctrlc"') -PassThru `
        -RedirectStandardInput $abc -RedirectStandardOutput (Join-Path $script:CaseDir 'stdout.bin') -RedirectStandardError (Join-Path $script:CaseDir 'stderr.txt')
    $null = $script:Proc.Handle
    $w = Find-Window 'NHK ctrlc'; Shot '01-open'
    $helper = @"
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern bool FreeConsole(); [DllImport(\"kernel32.dll\")] public static extern bool AttachConsole(uint p); [DllImport(\"kernel32.dll\")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool a); [DllImport(\"kernel32.dll\")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'
[W.K]::FreeConsole() | Out-Null
if (-not [W.K]::AttachConsole($($script:Proc.Id))) { exit 3 }
[W.K]::SetConsoleCtrlHandler([System.IntPtr]::Zero, `$true) | Out-Null
if (-not [W.K]::GenerateConsoleCtrlEvent(0, 0)) { exit 4 }
Start-Sleep -Milliseconds 500
exit 0
"@
    $hp = Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command', $helper) -PassThru -WindowStyle Hidden -Wait
    "helper_exit=$($hp.ExitCode)" | Set-Content (Join-Path $script:CaseDir 'ctrl-event.txt')
    Verdict 130 ([byte[]]@())
}
$C['s13_parallel'] = {
    Start-Case 's13-parallel-a' $abc @('select', '--title', 'NHK first'); $pa = $script:Proc; $da = $script:CaseDir
    $xyz = Fixture 'xyz.txt' (Utf8 "x-ray`nyankee`nzulu`n")
    Start-Case 's13-parallel-b' $xyz @('select', '--title', 'NHK second'); $pb = $script:Proc
    $wa = Find-Window 'NHK first'; $wb = Find-Window 'NHK second'; Shot '01-two-windows'
    Focus-Window $wb; Click-Element (Find-Pick $wb 3); Click-Element (Find-Element $wb 'Submit selection' 'ControlType.Button')
    $script:Proc = $pb; $script:SkipLeftovers = $true; Verdict 0 (Utf8 "zulu`n"); $script:SkipLeftovers = $false   # window A is still open by design
    $script:Case = 's13-parallel-a'; $script:CaseDir = $da; $script:Proc = $pa
    Focus-Window $wa; Click-Element (Find-Pick $wa 1); Click-Element (Find-Element $wa 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "alpha`n")
}

$C['s09_keyboard_submit'] = {
    # No mouse after the first focus click: Tab through row 2, row 3, Cancel to Submit,
    # then Enter / Space activates the button.
    foreach ($k in @(@('enter', 0x0D), @('space', 0x20))) {
        Start-Case "s09-keyboard-submit-$($k[0])" $abc @('select', '--multi', '--title', "NHK kbd $($k[0])")
        $w = Find-Window "NHK kbd $($k[0])"; Focus-Window $w
        Click-Element (Find-Pick $w 1)
        1..4 | ForEach-Object { [NhkInput]::Key(0x09); Start-Sleep -Milliseconds 120 }
        Start-Sleep -Milliseconds 300; Shot '01-submit-focused'
        [NhkInput]::Key([uint16]$k[1])
        Verdict 0 (Utf8 "alpha`n")
    }
}
$C['s15_slow_user'] = {
    # The user thinks for three per-request deadlines; a healthy host is not a hung host.
    Start-Case 's15-slow-user' $abc @('--diagnostics', 'debug', '--liveness-interval', '1', '--rpc-timeout', '3', 'select', '--multi', '--title', 'NHK slow')
    $w = Find-Window 'NHK slow'; Focus-Window $w; Shot '01-open'
    Start-Sleep -Seconds 9; Shot '02-still-open-after-idle'
    Click-Element (Find-Pick $w 2); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "beta`n")
    $err = Stderr-Text
    $probes = ([regex]::Matches($err, '"event":"rpc\.completed"[^\n]*"operation":"host\.diagnostics"')).Count
    Check 's15-slow-user-probes' ($probes -ge 6 -and $err -notmatch 'error\[') "liveness probes answered while idle: $probes (need >= 6), no error line"
}
$C['s15_modal_hold'] = {
    # Holding the title bar puts the window into the native modal move loop. The host must
    # keep answering liveness probes, or a slow drag would be reported as a hang.
    Start-Case 's15-modal-hold' $abc @('--diagnostics', 'debug', '--liveness-interval', '1', '--rpc-timeout', '3', 'select', '--multi', '--title', 'NHK hold')
    $w = Find-Window 'NHK hold'; Focus-Window $w
    $frame = New-Object NhkInput+RECT
    [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$frame)
    $x = [int](($frame.Left + $frame.Right) / 2); $y = $frame.Top + 16
    [void][NhkInput]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 300
    [NhkInput]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    1..8 | ForEach-Object { [void][NhkInput]::SetCursorPos($x + 6 * $_, $y + 4 * $_); Start-Sleep -Seconds 1 }
    Shot '01-held-in-move-loop'
    [NhkInput]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 600
    $moved = New-Object NhkInput+RECT
    [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$moved)
    Click-Element (Find-Pick $w 3); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "gamma`n")
    $err = Stderr-Text
    Check 's15-modal-hold-moved' ($moved.Left -ne $frame.Left -and $err -notmatch 'error\[') "window really was dragged for 8 s: left $($frame.Left) -> $($moved.Left); no error line"
}
$C['s15_resize_hold'] = {
    # FR-R-10: a sizing border held for 8 s keeps the window in the native modal size loop,
    # more than two per-request deadlines. A healthy host must not be reported as hung.
    Start-Case 's15-resize-hold' $abc @('--diagnostics', 'debug', '--liveness-interval', '1', '--rpc-timeout', '3', 'select', '--multi', '--title', 'NHK grip')
    $w = Find-Window 'NHK grip'; Focus-Window $w
    $frame = New-Object NhkInput+RECT
    [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$frame)
    $x = $frame.Left + 4; $y = $frame.Top + 4
    [void][NhkInput]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 300
    [NhkInput]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    [void][NhkInput]::SetCursorPos($x + 40, $y + 30); Start-Sleep -Seconds 8; Shot '01-held-in-size-loop'
    [NhkInput]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 600
    $sized = New-Object NhkInput+RECT
    [void][NhkInput]::GetWindowRect([IntPtr]$w.Current.NativeWindowHandle, [ref]$sized)
    Click-Element (Find-Pick $w 3); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "gamma`n")
    Check 's15-resize-hold-sized' ($sized.Left -ne $frame.Left -and (Stderr-Text) -notmatch 'error\[') "sizing border really was held for 8 s: left $($frame.Left) -> $($sized.Left); no error line"
}
$C['s15_file_dialog'] = {
    # FR-R-10: a native file dialog left open for 8 s (the user is browsing). The session
    # must survive it and still deliver the form.
    $html = Fixture 'file-form.html' (Utf8 '<form id="nhk-form"><p><label>Attachment <input type="file" name="attachment"></label></p><p><label>Note <input name="note" value="kept"></label></p></form>')
    Start-Case 's15-file-dialog' $abc @('--diagnostics', 'debug', '--liveness-interval', '1', '--rpc-timeout', '3', 'form', '--html', $html, '--title', 'NHK dialog')
    $w = Find-Window 'NHK dialog'; Focus-Window $w; Dump-Tree $w; Shot '01-open'
    $picker = $null
    foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($e.Current.ControlType.ProgrammaticName -eq 'ControlType.Button' -and $e.Current.Name -notin @('Cancel', 'Submit')) { $picker = $e; break }
    }
    if (-not $picker) { throw 'no file-picker control found in the accessibility tree (see uia-tree.tsv)' }
    Click-Element $picker
    $dialogs = { @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new($UIA::ClassNameProperty, '#32770'))).Count }
    $seen = 0; foreach ($i in 1..20) { $seen = & $dialogs; if ($seen) { break }; Start-Sleep -Milliseconds 250 }
    Start-Sleep -Seconds 8; Shot '02-dialog-open-8s'
    [NhkInput]::Key(0x1B); Start-Sleep -Milliseconds 800; Shot '03-dialog-dismissed'
    $after = & $dialogs
    Focus-Window $w
    Click-Element (Find-Element $w 'Submit' 'ControlType.Button')
    if (-not $script:Proc.WaitForExit(15000)) { try { $script:Proc.Kill() } catch {} }
    $out = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $script:CaseDir 'stdout.bin')))
    $ok = $script:Proc.ExitCode -eq 0 -and $out.Contains('"name":"note","value":"kept"') -and (Stderr-Text) -notmatch 'error\['
    Check 's15-file-dialog' ($ok -and $seen -gt 0 -and $after -eq 0 -and (Leftovers) -eq 0) "native dialog seen: $seen, open 8 s, dismissed (left: $after); exit $($script:Proc.ExitCode); form delivered with the note field: $($out.Contains('"note"')); no error line"
    Cleanup-Own
}
$C['s16_hung_host'] = {
    # Freeze the real host process while its window is open.
    # Detection takes the probe interval plus twice the per-request deadline (1 s + 2 x 2 s).
    Start-Case 's16-hung-host' $abc @('--liveness-interval', '1', '--rpc-timeout', '2', 'select', '--multi', '--title', 'NHK hung')
    $w = Find-Window 'NHK hung'; Focus-Window $w; Shot '01-open'
    $session = (Get-Process -Id $PID).SessionId
    $hostProc = @(Get-Process nativehtmlkit-host | Where-Object { $_.SessionId -eq $session })[0]
    $status = [NhkInput]::Suspend([uint32]$hostProc.Id)
    $t0 = Get-Date
    "host_pid=$($hostProc.Id) NtSuspendProcess=$status" | Set-Content (Join-Path $script:CaseDir 'hang.txt')
    Start-Sleep -Milliseconds 1500; Shot '02-frozen-window'
    Verdict 1 ([byte[]]@())
    $seconds = [int]((Get-Date) - $t0).TotalSeconds
    "seconds_until_cli_exit=$seconds" | Add-Content (Join-Path $script:CaseDir 'hang.txt')
    Shot '03-window-gone'
    Check 's16-hung-host-report' ($status -eq 0 -and (Stderr-Text) -match '(?m)^nativehtmlkit: error\[host\.unresponsive\]: ' -and $seconds -le 20) "host suspended (status $status); stderr names error[host.unresponsive]; CLI exited after $seconds s"
}
$C['s17_deadline'] = {
    # 8 s leaves room for UI Automation to locate the window and a row before the deadline
    # (--multi: Find-Pick looks for a check box first and would spend 10 s on a radio row).
    Start-Case 's17-deadline' $abc @('--timeout', '8', 'select', '--multi', '--title', 'NHK deadline')
    $w = Find-Window 'NHK deadline'; Focus-Window $w; Shot '01-open'
    Click-Element (Find-Pick $w 1)        # a selection alone is not a decision
    Verdict 124 ([byte[]]@())
    Shot '02-closed-by-deadline'
}
$C['s18_diagnostics'] = {
    # "Submit did nothing" support scenario: full trace, one session id across launcher,
    # host and backend, and none of the user's data or the launch token in it.
    $secret = Fixture 'secret.txt' (Utf8 "first $Sentinel`nsecond $Sentinel`nthird`n")
    $env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID = 'gui-s18.windows'
    try { Start-Case 's18-trace' $secret @('--diagnostics', 'trace', 'select', '--multi', '--title', "Trace $Sentinel") }
    finally { Remove-Item Env:NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID }
    $w = Find-Window "Trace $Sentinel"; Focus-Window $w; Shot '01-open'
    Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button'); Start-Sleep -Milliseconds 500; Shot '02-empty-submit-rejected'
    Click-Element (Find-Pick $w 2); Click-Element (Find-Element $w 'Submit selection' 'ControlType.Button')
    Verdict 0 (Utf8 "second $Sentinel`n")
    $err = Stderr-Text
    $lines = $err -split "`r?`n" | Where-Object { $_ }
    Check 's18-trace-private' (-not $err.Contains($Sentinel) -and $err -notmatch '[0-9a-fA-F]{64}') "no user data and no 64-hex credential anywhere on stderr ($($lines.Count) lines)"
    $cli = @($lines | Where-Object { $_.StartsWith('{"schema_version"') })
    $foreign = @($cli | Where-Object { -not $_.Contains('"session_id":"gui-s18.windows"') }).Count
    $roles = @('launcher', 'backend' | Where-Object { $r = $_; @($cli | Where-Object { $_.Contains("`"role`":`"$r`"") }).Count -gt 0 }).Count
    $hostTagged = @($lines | Where-Object { $_.StartsWith('{"diagnostic_session_id":"gui-s18.windows"') }).Count
    Check 's18-trace-correlated' ($foreign -eq 0 -and $roles -eq 2) "CLI records: $($cli.Count), with another session id: $foreign, roles seen: $roles/2"
    # Core tags its own records with the id from 1.0.2 on; an older host cannot (BLOCKED).
    $hostVersion = [version](((& (Join-Path $Bin 'nativehtmlkit-host.exe') --version) -split ' ')[1])
    if ($hostTagged -gt 0) {
        Check 's18-trace-host-correlated' $true "host $hostVersion tagged $hostTagged of its records with the same id"
        # Each document.command the CLI completed is visible host-side under the same request id.
        $ids = @([regex]::Matches($err, '"event":"rpc\.completed","request_id":"(nhk-\d+)","operation":"document\.command"') | ForEach-Object { $_.Groups[1].Value })
        $missing = @($ids | Where-Object { -not ($err.Contains("`"event`":`"rpc.received`",`"method`":`"document.command`",`"id`":`"$_`"") -and $err.Contains("`"event`":`"rpc.completed`",`"method`":`"document.command`",`"id`":`"$_`"")) }).Count
        Check 's18-trace-host-request-ids' ($ids.Count -ge 3 -and $missing -eq 0) "host trace shows rpc.received and rpc.completed for $($ids.Count) document.command request ids of the CLI (missing: $missing)"
    }
    elseif ($hostVersion -lt [version]'1.0.2') { "s18-trace-host-correlated`tBLOCKED`t-`t-`thost $hostVersion predates diagnostic_session_id tagging (Core 1.0.2)" | Add-Content -Encoding UTF8 $Results }
    else { Check 's18-trace-host-correlated' $false "host $hostVersion wrote no record tagged with the session id" }
    $explains = ($err -match '"event":"submit\.rejected"[^\n]*"reason":"empty_selection"') -and ($err -match '"event":"submit\.accepted"') -and ($err -match '"event":"rpc\.completed","request_id":"nhk-\d+","operation":"document\.command","duration_ms":\d')
    Check 's18-trace-explains-submit' $explains 'trace shows the rejected and the accepted submit with request ids and durations'
}

$names = if ($Cases.Count) { $Cases } else { @('s01_work_area','s02_multi','s02_single','s03_cancel','s03_close','s03_empty_submit','s04_invalid','s05_bounds','s06_json','s07_csv','s08_form','s09_keyboard','s09_keyboard_submit','s09_resize','s09_resize_keeps_footer','s09_resize_vh_css','s10_hostile','view','s11_kill','s11_ctrlc','s13_parallel','s15_slow_user','s15_modal_hold','s15_resize_hold','s15_file_dialog','s16_hung_host','s17_deadline','s18_diagnostics') }
Log "suite start session=$((Get-Process -Id $PID).SessionId) user=$env:USERNAME cases=$($names -join ',')"
# Pre-flight: the desktop is shared. Another NativeHTMLKit window would take our clicks, so
# the suite does not start (BLOCKED, not FAIL) while one is open.
foreach ($i in 1..6) { if ((Foreign-Windows) -eq 0) { break }; Start-Sleep -Seconds 5 }
if ((Foreign-Windows) -ne 0) {
    "suite-preflight`tBLOCKED`t-`t-`t$(Foreign-Windows) foreign NativeHTMLKit window(s) open on this desktop; suite not started" | Add-Content -Encoding UTF8 $Results
    Log 'suite blocked by foreign windows'; exit 3
}
try {
    foreach ($n in $names) { Guard $C[$n] }
    Start-Sleep -Seconds 1
    $left = Leftovers
    Check 'suite-cleanup' ($left -eq 0) "own processes left at the end: $left (anything left was removed)"
    $scope = if ($Cases.Count) { "partial run: $($names -join ',')" } else { "full suite: all $($names.Count) case groups ran to the end" }
    "suite-complete`tPASS`t-`t-`t$scope" | Add-Content -Encoding UTF8 $Results
} finally {
    # Always, also when the suite is aborted: leave no window of ours behind.
    Cleanup-Own
    Log 'suite end'
}
