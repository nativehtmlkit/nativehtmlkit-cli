# NativeHTMLKit CLI on Windows

`nativehtmlkit.exe` (alias `nhk.exe`) puts a native window into a PowerShell or `cmd.exe`
pipeline: pipe records in, let a person pick, view or fill in something, and read the
result from stdout. This section documents CLI **0.1.2** (bundled with Core host 1.0.3) for
Windows x86-64, with examples for Windows PowerShell 5.1 and PowerShell 7. For bash on Linux
see the [Linux section](../linux/index.md).

<!-- test: exit=124 calls="124@*x2" -->
```powershell
Get-ChildItem -Directory | Select-Object Name, @{ n = 'Modified'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd') } } |
    ConvertTo-Json | nativehtmlkit select --input-format json --title 'Open folder'
```

## Install

Download the Windows archive and the checksum file from the
[v0.1.2 release](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.2)
(in the browser, or with the GitHub CLI as below) and compare the hash:

<!-- not-tested: needs the network; the same commands were run by hand for this release -->
```powershell
gh release download v0.1.2 -R nativehtmlkit/nativehtmlkit-cli -p '*windows-x64*' -p SHA256SUMS
$want = ((Get-Content SHA256SUMS | Select-String 'windows-x64.zip').Line -split '\s+')[0]
$got = (Get-FileHash .\nativehtmlkit-cli-v0.1.2-windows-x64.zip -Algorithm SHA256).Hash
if ($got -eq $want) { 'checksum OK' } else { throw 'checksum mismatch' }
```

Without `gh`: `Invoke-WebRequest -OutFile` with
`https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/download/v0.1.2/nativehtmlkit-cli-v0.1.2-windows-x64.zip`
(and the same for `SHA256SUMS`). `-eq` compares strings case-insensitively, so the
upper-case hash of `Get-FileHash` matches the lower-case one in the file.

Extract it to a permanent place and add that folder to your `PATH`:

<!-- not-tested: changes the user's PATH; done by hand for this release -->
```powershell
Expand-Archive .\nativehtmlkit-cli-v0.1.2-windows-x64.zip -DestinationPath "$env:LOCALAPPDATA\Programs"
$dir = "$env:LOCALAPPDATA\Programs\nativehtmlkit-cli-v0.1.2-windows-x64"
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$dir", 'User')
$env:Path += ";$dir"     # this session too
```

The folder contains:

| File | What it is |
|---|---|
| `nativehtmlkit.exe` | the CLI |
| `nhk.exe` | an identical copy under the short name |
| `nativehtmlkit-host.exe` | Core host 1.0.3, the program that draws the window; keep it beside the CLI |
| `manifest.json`, `SHA256SUMS` | versions, source commits, protocol version and hashes |
| `examples\sample-form.html` | the smallest form for `nativehtmlkit form` |
| `LICENSE`, `licenses\` | licences of the CLI, Core and third-party components |

Check it:

<!-- test: exit=0 calls="0@none" -->
```powershell
nativehtmlkit doctor
```

```text
NativeHTMLKit CLI 0.1.2
Core host: C:\Users\me\AppData\Local\Programs\nativehtmlkit-cli-v0.1.2-windows-x64\nativehtmlkit-host.exe
nativehtmlkit-host 1.0.3
```

The CLI writes no configuration files and needs no installer; to uninstall, delete the
folder and remove it from `PATH`.

## Set up UTF-8 once

The CLI reads and writes UTF-8. Windows PowerShell 5.1 sends text to native programs as
`us-ascii` by default (`$OutputEncoding`) and decodes their output with the console code
page, so non-ASCII text would arrive as `?` and come back garbled. Put this at the top of
every script (or in your `$PROFILE`); it is harmless in PowerShell 7, which already uses
UTF-8:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
'Příliš žluťoučký kůň', 'naïve café 😀' | nativehtmlkit select
```

<!-- submit: pick=1 -->
```text
Příliš žluťoučký kůň
```

Use `[System.Text.UTF8Encoding]::new($false)`, **not** `[Text.Encoding]::UTF8`: the latter
makes Windows PowerShell 5.1 send a byte-order mark first, which the `json` input format
rejects ([input formats](input-formats.md#json-powershell-objects)). The example scripts also restore the
console encoding when they finish.

## First command

<!-- test: exit=124 calls="124@3x1" -->
```powershell
'alpha', 'beta', 'gamma' | nativehtmlkit select --multi
```

A window lists the three lines with a checkbox each. Tick some and click **Submit
selection**: they are printed, one per line, and `$LASTEXITCODE` is 0. Click **Cancel**:
nothing is printed and `$LASTEXITCODE` is 2.

<!-- submit: pick=1,3 -->
```text
alpha
gamma
```

## The four commands

| Command | Reads stdin | stdout on success | Page |
|---|---|---|---|
| `select` | records | the chosen rows | [select](commands/select.md) |
| `view` | records | nothing (read-only) | [view](commands/view.md) |
| `form` | no | one JSON line with the form values | [form](commands/form.md) |
| `doctor` | no | which host is used, and its version | [doctor, help, version](commands/doctor.md) |

Global options (`--timeout`, `--host`, `--diagnostics`, `--rpc-timeout`,
`--liveness-interval`, `--startup-timeout`) work with every command, before or after its
name. Each command page shows each of them with that command.

## Pages in this section

| Page | Contents |
|---|---|
| [select](commands/select.md), [view](commands/view.md), [form](commands/form.md), [doctor](commands/doctor.md) | every option of every command, with a verified PowerShell example |
| [Input formats](input-formats.md) | `lines`, `csv`, `tsv`, `json`, `ndjson`, `--no-headers`; objects as JSON |
| [Output formats](output-formats.md) | `same`, `lines`, `csv`, `tsv`, `json`, `ndjson`: the exact text, read back as objects |
| [Exit codes and scripting](exit-codes-and-scripting.md) | 0, 1, 2, 124, 130 with `$LASTEXITCODE`; helper functions; `cmd.exe` |
| [Environment and diagnostics](environment-and-diagnostics.md) | environment variables, `--diagnostics` levels, reading the records |
| [CSS and forms](css-and-forms.md) | `--css` themes, writing and generating `--html` forms safely |
| [Troubleshooting](troubleshooting.md) | every error line and what to do, encoding pitfalls |
| [Recipes](recipes/index.md) | Git branches, files, processes, services, Docker, JSON APIs, CSV, logs and events, pipelines, a deployment form, time zones, headless tests |
| [Tutorial: a project picker](tutorial.md) | build `proj.ps1`, a bookmark tool using all three window commands |
| [Tutorial: a Git branch picker](tutorial-branch-picker.md) | build `git-pick.ps1` with `select`, JSON and `--multi` |

The exact, OS-neutral specification is the [reference](../REFERENCE.md); runnable scripts
are listed in the [example catalogue](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md).

## How the examples are verified

The examples on these pages run in the `examples` folder of a clone of this repository:

<!-- not-tested: needs the network -->
```powershell
git clone https://github.com/nativehtmlkit/nativehtmlkit-cli.git
Set-Location nativehtmlkit-cli\examples
```

Every PowerShell (and `cmd.exe`) block that calls the CLI is run by
[`scripts/test-docs.ps1`](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/scripts/test-docs.ps1)
against the released Windows archive (CLI 0.1.2, Core host 1.0.3) in **Windows PowerShell
5.1** on Windows Server 2022, and the portable ones also in **PowerShell 7** on Linux, with
the real host in headless mode (no window and nobody to click). That proves the input and
options are accepted, the page renders, and the documented exit status and output follow;
since nobody clicks, each window ends by its deadline. Three kinds of results are shown:

- **stdout / stderr** blocks: the text the example printed in that run.
- **"Submit prints"** blocks: what the CLI writes when the user ticks the named rows. They
  are checked by running the release's own parsing, selection and output code on the exact
  bytes and options PowerShell gave the CLI.
- **Replayed results**: a recorded Submit result, in the exact output format, handed to the
  script after the real CLI call was accepted, to show what the script does with it.

What a person sees and clicks (layout, keyboard, Cancel, closing the window, Ctrl+C) is
covered by the release's GUI qualification on Windows Server 2022 and KDE Plasma.
