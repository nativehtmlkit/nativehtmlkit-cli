# doctor, help and version (Windows)

`nativehtmlkit doctor` reports which Core host executable the CLI would use and checks that
it starts. `help`, `--help` and `--version` print information. None of them opens a window
or reads stdin. Exact rules: [OS-neutral reference](../../reference/doctor.md).

The examples were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and
PowerShell 7 by `scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## `doctor`

<!-- test: exit=0 calls="0@none" -->
```powershell
nativehtmlkit doctor
```

prints three lines, for example:

```text
NativeHTMLKit CLI 0.1.2
Core host: C:\Tools\nativehtmlkit-cli-v0.1.2-windows-x64\nativehtmlkit-host.exe
nativehtmlkit-host 1.0.3
```

The third line is the host's own `--version` output. Check it in a script:

<!-- test: exit=0 calls="0@none" -->
```powershell
if ((nativehtmlkit doctor) -contains 'nativehtmlkit-host 1.0.3') {
    'qualified host found'
} else {
    Write-Error 'install the release archive, or set NATIVEHTMLKIT_HOST_BINARY'
}
```

<!-- stdout -->
```text
qualified host found
```

| Situation | Exit | stderr |
|---|---|---|
| host found and it answered `--version` | 0 | |
| no host anywhere | 1 | `error[host.not_found]: NativeHTMLKit Core host not found. ...` |
| `--host`/`NATIVEHTMLKIT_HOST_BINARY` names no file | 1 | `error[host.not_found]: Core host binary does not exist: <path>` |
| the file cannot be started | 1 | `error[host.not_found]: cannot start the Core host (<reason>)` |
| it failed, printed nothing, or took over 10 s | 1 | `error[host.failed]: ...` |

## `doctor --host PATH`

Check a specific host executable:

<!-- test: exit=1 calls="1@none" -->
```powershell
nativehtmlkit doctor --host C:\missing\nativehtmlkit-host.exe
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: C:\missing\nativehtmlkit-host.exe
```

A file that is not a program cannot be started:

<!-- test: exit=1 calls="1@none" requires=windows -->
```powershell
Set-Content -Path fake-host.exe -Value 'not a program'
nativehtmlkit doctor --host .\fake-host.exe
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: cannot start the Core host
```

## `doctor --diagnostics LEVEL`

`doctor` writes no diagnostic records of its own at any level; the option is accepted so
that the same global options work for every command:

<!-- test: exit=0 calls="0@none" -->
```powershell
$err = nativehtmlkit doctor --diagnostics trace 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
@($err).Count
```

<!-- stdout -->
```text
0
```

## `doctor --timeout`, `--rpc-timeout`, `--liveness-interval`, `--startup-timeout`

Accepted and ignored by `doctor`: it never opens a window, and its version check has its own
fixed 10-second limit. They are useful when one array of options is splatted into every
command:

<!-- test: exit=124 calls="0@none 124@2x1" -->
```powershell
$opts = '--timeout', '120', '--rpc-timeout', '10', '--liveness-interval', '2', '--startup-timeout', '30'
nativehtmlkit doctor @opts | Out-Null
if ($LASTEXITCODE -eq 0) { 'doctor ok' }
'a', 'b' | nativehtmlkit select @opts
"select ended with $LASTEXITCODE"
```

<!-- stdout -->
```text
doctor ok
select ended with 124
```

## `--version`, `-V`

<!-- test: exit=0 shim=off -->
```powershell
nativehtmlkit --version
nhk -V
```

<!-- stdout -->
```text
nativehtmlkit 0.1.2
nativehtmlkit 0.1.2
```

## `--help`, `-h`, `help COMMAND`

`--help` prints the full help, `-h` a summary; after a command they describe that command.
`help COMMAND` is the same as `COMMAND --help`:

<!-- test: exit=0 shim=off -->
```powershell
nativehtmlkit --help | Select-Object -Last 1
```

<!-- stdout -->
```text
Exit status: 0 submitted/viewed, 1 error, 2 cancelled, 124 --timeout expired, 130 Ctrl+C/SIGINT, 143 SIGTERM, 129 SIGHUP.
```

(143 and 129 are Unix signals; on Windows the interruption is Ctrl+C, 130.)

<!-- test: exit=0 shim=off -->
```powershell
(nativehtmlkit doctor --help | Select-String -SimpleMatch -- '--host <HOST>' | Select-Object -First 1).Line
nativehtmlkit -h | Select-Object -First 1
(nativehtmlkit help select | Select-String -SimpleMatch -- '--allow-empty').Line
```

<!-- stdout -->
```text
      --host <HOST>
Native HTML/CSS windows for shell pipelines (alias: nhk)
      --allow-empty
```

`help` takes a command name, not options: `nativehtmlkit help --help` is a usage error
(exit 1).

## The `nhk.exe` alias

The release archive contains `nhk.exe`, an identical copy of `nativehtmlkit.exe`; it finds
the host beside itself the same way:

<!-- test: exit=0 calls="0@none" -->
```powershell
nhk doctor | Select-Object -First 1
```

<!-- stdout -->
```text
NativeHTMLKit CLI 0.1.2
```

## Related

[Installation](../index.md), [environment and diagnostics](../environment-and-diagnostics.md),
[troubleshooting](../troubleshooting.md).
