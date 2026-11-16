# Exit codes and scripting (Windows)

Every `nativehtmlkit` command reports what happened through its exit status, and only a
successful Submit writes anything to stdout. In PowerShell the status is in
`$LASTEXITCODE`, in `cmd.exe` in `%ERRORLEVEL%`. This page shows how to use it. The
complete specification, including every `error[<code>]`, is the
[exit status reference](../reference/exit-status.md).

| Status | Meaning | stdout | Typical reaction |
|---|---|---|---|
| 0 | submitted (`select`, `form`), closed (`view`), done (`doctor`, `--help`, `--version`) | the result | use it |
| 1 | error: usage, input, host missing or failed; one `nativehtmlkit: error[<code>]: ...` line on stderr | empty | fail |
| 2 | **Cancel**, or the window was closed without submitting | empty | stop quietly, change nothing |
| 124 | `--timeout` expired | empty | stop, maybe say so |
| 130 | Ctrl+C in the console | empty | stop |

Usage errors exit 1 (not 2), so 2 always means *the user said no*. (143 and 129 are the Unix
SIGTERM and SIGHUP statuses; they do not occur on Windows.)

The examples were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and
PowerShell 7 by `scripts/test-docs.ps1` ([how](index.md#how-the-examples-are-verified)).
Headless, nobody clicks, so windows end with 124; replayed results show the other paths.

## `$LASTEXITCODE` right after the call

A native program's non-zero status is not an exception: branch on `$LASTEXITCODE`
immediately, before another native command overwrites it.

<!-- test: exit=124 calls="124@3x1" -->
```powershell
$size = 'small', 'medium', 'large' | nativehtmlkit select --title 'Size' --timeout 60
switch ($LASTEXITCODE) {
    0       { "size: $size" }
    2       { Write-Warning 'cancelled'; exit 2 }
    124     { Write-Warning 'no answer within 60 s'; exit 124 }
    default { exit $LASTEXITCODE }    # the CLI already explained the error on stderr
}
```

When the user clicks Cancel:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: cancelled
```

When the user picks `large`:

<!-- replay: call=1 exit=0 expect=0 -->
```text
large
```

<!-- stdout -->
```text
size: large
```

(`Write-Warning` goes to the warning stream; with the script's output redirected, as in these
runs, PowerShell prints it to stdout with the `WARNING:` prefix.)

## A helper that ends the script on anything but Submit

Inside a function, `exit` ends the whole script, with the CLI's status. `$input` passes the
pipeline on to the CLI:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
function Invoke-Picker {
    $out = $input | nativehtmlkit @args
    if ($LASTEXITCODE -ne 0) { Write-Warning 'nothing chosen'; exit $LASTEXITCODE }
    $out -join "`n"
}
$colour = 'red', 'green' | Invoke-Picker select --title 'Colour'
"colour: $colour"
```

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: nothing chosen
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
green
```

<!-- stdout -->
```text
colour: green
```

## Hand the status on to the caller

`exit $LASTEXITCODE` makes a script return the CLI's status, so whoever started it can
tell Cancel from success. The example scripts do this:

<!-- test: exit=0 calls="124@4x5" -->
```powershell
$ps = (Get-Process -Id $PID).Path
& $ps -NoProfile -ExecutionPolicy Bypass -File .\pick-git-branch.ps1 *> $null
"pick-git-branch.ps1 exited with $LASTEXITCODE"
exit 0
```

<!-- stdout -->
```text
pick-git-branch.ps1 exited with 124
```

## PowerShell 7: native errors as exceptions

PowerShell 7.4 and later can turn a non-zero native status into an error with
`$PSNativeCommandUseErrorActionPreference`. Then Cancel throws under
`$ErrorActionPreference = 'Stop'`, so catch it where 2 or 124 are normal answers:

<!-- test: exit=0 calls="124@2x1" requires=ps7 -->
```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
try {
    $choice = 'a', 'b' | nativehtmlkit select
    "chose $choice"
} catch {
    "no choice (status $LASTEXITCODE)"
}
exit 0
```

<!-- stdout -->
```text
no choice (status 124)
```

## Errors: status 1 and the error code

Each failure writes exactly one line `nativehtmlkit: error[<code>]: <message>` to stderr.
stderr also carries the Core host's log records, so match the line; never parse stderr for
results. With `2>&1` each stderr line arrives as an error record; `"$_"` gives its text:

<!-- test: exit=0 calls="1@none" -->
```powershell
$err = 'a,b', '1,2,3' | nativehtmlkit select --input-format csv 2>&1 | ForEach-Object { "$_" }
$status = $LASTEXITCODE
$code = ($err | Select-String -Pattern 'error\[[a-z_.]+\]' | Select-Object -First 1).Matches[0].Value
"status $status, $code"
exit 0
```

<!-- stdout -->
```text
status 1, error[input.invalid]
```

A usage error from the argument parser has no code but also exits 1:

<!-- test: exit=1 calls="1@none" -->
```powershell
'a' | nativehtmlkit select --input-format xml
```

<!-- stderr -->
```text
error: invalid value 'xml' for '--input-format <INPUT_FORMAT>'
```

With `$ErrorActionPreference = 'Stop'`, Windows PowerShell 5.1 turns the first *redirected*
stderr line of a native program into a terminating error. Redirect stderr only while
`'Continue'` is in effect, as
[pick-container.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-container.ps1)
does around `docker logs 2>&1`.

## Write files only after success

Check the status first, then write. `[IO.File]::WriteAllText` with
`UTF8Encoding($false)` writes UTF-8 without a BOM in both editions (`Set-Content -Encoding
UTF8` adds one in 5.1):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
$csv = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format csv
if ($LASTEXITCODE -ne 0) { "out.csv exists: $(Test-Path out.csv)"; exit $LASTEXITCODE }
$target = Join-Path (Get-Location) 'out.csv'
[IO.File]::WriteAllText($target, ($csv -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
```

<!-- stdout -->
```text
out.csv exists: False
```

## `--timeout` is for people, not for hangs

Without `--timeout` a window waits as long as the person needs. Add it when an unattended
window must not block a job forever:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'deploy', 'skip' | nativehtmlkit select --title 'Nightly deploy?' --timeout 900
```

<!-- stderr -->
```text
nativehtmlkit: no decision before the --timeout deadline; the window was closed
```

You do not need `--timeout` against a hung host: the CLI notices that itself (liveness
probes) and exits 1 with `error[host.unresponsive]`
([environment and diagnostics](environment-and-diagnostics.md)).

## Ctrl+C: 130

Ctrl+C in the console window closes the CLI's window and exits 130; stdout stays empty,
even if the user had just clicked Submit. A script sees it like any other status (here the
130 is replayed; `scripts/test-docs.ps1` separately sends a real Ctrl+C to the released
CLI on Windows and checks for 130):

<!-- test: exit=124 calls="124@2x1" -->
```powershell
$choice = 'a', 'b' | nativehtmlkit select
if ($LASTEXITCODE -eq 130) { Write-Warning 'interrupted'; exit 130 }
exit $LASTEXITCODE
```

<!-- replay: call=1 exit=130 expect=130 -->
```text
```

<!-- stdout -->
```text
WARNING: interrupted
```

## `view` and `doctor`

`view` has no Cancel: closing it is 0, and 124 is "the deadline closed it". Treat both as
done:

<!-- test: exit=0 calls="124@5x1" -->
```powershell
Get-Content data\app.log | nativehtmlkit view --timeout 120
if ($LASTEXITCODE -notin 0, 124) { exit 1 }
'carry on'
exit 0
```

<!-- stdout -->
```text
carry on
```

`-notin` needs PowerShell 3 or later (both editions have it). `doctor` exits 0 or 1 and
suits a start-of-script check:

<!-- test: exit=0 calls="0@none" -->
```powershell
nativehtmlkit doctor | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'NativeHTMLKit CLI is not installed correctly' }
'ready'
```

<!-- stdout -->
```text
ready
```

## `cmd.exe` and batch files

The CLI works the same from `cmd.exe`: `<` and `|` feed stdin, `%ERRORLEVEL%` holds the
status. `cmd.exe` passes bytes unchanged, so save input files as UTF-8.

<!-- test: exit=0 calls="124@3x1" -->
```bat
(echo small& echo medium& echo large) > sizes.txt
nativehtmlkit select --title "Size" < sizes.txt > choice.txt
if %ERRORLEVEL% equ 0 (
  set /p CHOICE=<choice.txt
) else (
  echo no choice: %ERRORLEVEL%
)
exit /b 0
```

<!-- stdout -->
```text
no choice: 124
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
medium
```

`if errorlevel N` means "N or greater", so test the higher statuses first, or compare
`%ERRORLEVEL%` with `equ` as above:

<!-- test: exit=0 calls="124@5x1" -->
```bat
type data\app.log | nativehtmlkit view --title "app.log"
if errorlevel 124 (echo closed by the deadline) else if errorlevel 1 (echo failed) else (echo closed)
exit /b 0
```

<!-- stdout -->
```text
closed by the deadline
```

<!-- test: exit=0 calls="0@none" -->
```bat
nativehtmlkit doctor > nul || echo the CLI is not installed correctly
echo doctor: %ERRORLEVEL%
```

<!-- stdout -->
```text
doctor: 0
```
