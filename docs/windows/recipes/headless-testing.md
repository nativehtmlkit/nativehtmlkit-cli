# Test your scripts without a desktop (Windows)

A script that opens a window is hard to test in CI: nobody clicks. This repository tests its
examples and these pages headless; you can do the same for your own PowerShell scripts.

> `NATIVEHTMLKIT_CLI_TEST_HEADLESS` is a **test-only switch**, not part of the user contract
> of CLI 0.1.2, and may change in a later release. Never set it for real use.

The examples were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and
PowerShell 7 by `scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## What headless mode proves

With `NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` the CLI starts the real Core host with
`--headless`: the host runs the whole protocol (handshake, window, document, events,
shutdown) without showing anything. With no input, every session ends by `--timeout`:

<!-- test: exit=0 shim=off -->
```powershell
$env:NATIVEHTMLKIT_CLI_TEST_HEADLESS = '1'
'a', 'b' | nativehtmlkit select --timeout 0.5 2>$null
"exit $LASTEXITCODE"
exit 0
```

<!-- stdout -->
```text
exit 124
```

Exit 124 with empty stdout shows that the input was parsed, the page was accepted by the
host and the exit contract held. `--diagnostics debug` shows how the input was understood:

<!-- test: exit=0 shim=off -->
```powershell
$env:NATIVEHTMLKIT_CLI_TEST_HEADLESS = '1'
$log = 'a,b', '1,2', '3,4' | nativehtmlkit select --input-format csv --timeout 0.5 --diagnostics debug 2>&1 | ForEach-Object { "$_" }
$started = $log | Where-Object { $_ -like '*"event":"session.started"*' } | ForEach-Object { ConvertFrom-Json -InputObject $_ }
"rows $($started.context.rows), columns $($started.context.columns)"
exit 0
```

<!-- stdout -->
```text
rows 2, columns 2
```

Input errors still fail at once with exit 1, so a headless run also proves your data is
acceptable (UTF-8, valid JSON, row, column and page limits).

## Testing a whole script

Your script probably sets its own `--timeout` (or none). PowerShell resolves **functions
before executables**, so a function named `nativehtmlkit` defined before the script runs
can replace the deadline with a short one, and hand the script a recorded result to test
what happens after a Submit:

<!-- test: exit=0 shim=off -->
```powershell
$real = (Get-Command nativehtmlkit -CommandType Application | Select-Object -First 1).Source
function global:nativehtmlkit {
    $ErrorActionPreference = 'Continue'     # the tested script may use 'Stop'
    $keep = @(); $skip = $false
    foreach ($a in $args) {
        if ($skip) { $skip = $false; continue }
        if ($a -eq '--timeout') { $skip = $true; continue }
        $keep += $a
    }
    $env:NATIVEHTMLKIT_CLI_TEST_HEADLESS = '1'
    $out = $input | & $real @keep --timeout 0.5 2>$null
    $global:calls += "$($keep[0]) -> $LASTEXITCODE"
    if ($global:replay) { $global:replay; $global:LASTEXITCODE = 0 } else { $out; $global:LASTEXITCODE = $LASTEXITCODE }
}
$global:calls = @()
$global:replay = $null
& .\tutorial-branch-picker\step1-pick.ps1 3> $null
"headless: $LASTEXITCODE"
$global:replay = 'release/1.4'
& .\tutorial-branch-picker\step1-pick.ps1
"replayed: $LASTEXITCODE"
$global:calls
exit 0
```

<!-- stdout -->
```text
headless: 124
You chose: release/1.4
replayed: 0
select -> 124
select -> 124
```

The first run proves the script's window opened and that it passes 124 on (`3> $null`
hides its warning); the second, with a recorded result in the exact output format
([output formats](../output-formats.md)), what it does after a Submit.

This repository's harnesses do the same with more checks (rows x columns per call, document
ready, no stdout on a non-zero status, no leftover processes):

<!-- not-tested: runs the repository's own harnesses -->
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-examples.ps1 -Cli C:\Tools\nativehtmlkit-cli-v0.1.2-windows-x64\nativehtmlkit.exe -Shell powershell.exe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-docs.ps1 -Cli C:\Tools\nativehtmlkit-cli-v0.1.2-windows-x64\nativehtmlkit.exe -Shell powershell.exe
```

What this does **not** prove: anything that needs a person or a real screen (clicking,
keyboard focus, layout, colours). The CLI release's GUI qualification covers those.

Linux: [Test your scripts without a desktop (Linux)](../../linux/recipes/headless-testing.md).
