# NativeHTMLKit CLI

**Give a shell command a native desktop window** without embedding a browser or shipping a
Python runtime. Pipe records in, let a person pick, view or fill in a form, and get exactly
the chosen data back on stdout, with an exit status your script can trust.

```bash
printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi                 # tick rows -> chosen lines
git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch'
docker ps --format '{{json .}}' | nativehtmlkit select --input-format ndjson --output-format json
nativehtmlkit select --input-format csv --output-format json --multi < servers.csv | jq -r '.[].host'
ps aux | nativehtmlkit view --title 'Processes'                              # read-only, no stdout
nativehtmlkit form --html examples/sample-form.html --timeout 600            # -> {"entries":[...]}
nativehtmlkit doctor                                                         # which host, which version
```

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Get-Process | Select-Object Id, ProcessName | ConvertTo-Json |
    nativehtmlkit select --input-format json --output-format json --multi
if ($LASTEXITCODE -eq 2) { 'cancelled' }
```

| Exit | Meaning | stdout |
|---|---|---|
| 0 | submitted / viewer closed | the result only (nothing for `view`) |
| 2 | Cancel or window closed | empty |
| 124 | `--timeout` passed | empty |
| 1 | error; `nativehtmlkit: error[<code>]: ...` on stderr | empty |
| 130 / 143 / 129 | SIGINT / SIGTERM / SIGHUP | empty |

Input formats `lines`, `csv`, `tsv`, `json`, `ndjson` (UTF-8, at most 8 MiB, 2,000 rows,
32 columns); rows come back in input order and byte-exact. Piped data is always shown as
escaped text; only `--html` and `--css` files are trusted markup. There is no default limit
on how long a person may take, while a hung host is detected and stopped.

## Install

Release **0.1.2** (Linux x86-64, Windows x86-64) on
[GitHub Releases](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.2).
Each archive bundles the exact Core host 1.0.3 it was qualified with: verify it against
`SHA256SUMS`, extract it anywhere and run `nhk doctor`. The executable is `nativehtmlkit`, with
the alias `nhk`. It is an independent Rust client of Core's local wire protocol v1 and is
not installed by the Python or PowerShell SDKs.

## Documentation

| | |
|---|---|
| **Linux (bash)** | [Install, every command and option with examples, formats, exit codes, recipes, tutorials](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/linux/index.md) |
| **Windows (PowerShell, cmd.exe)** | [The same for Windows PowerShell 5.1 and PowerShell 7](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/windows/index.md) |
| **Tutorials** | Project picker ([Linux](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/linux/tutorial.md), [Windows](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/windows/tutorial.md)), Git branch picker ([Linux](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/linux/tutorial-branch-picker.md), [Windows](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/windows/tutorial-branch-picker.md)) |
| **Recipes** | Git branches, files, processes, services, Docker, JSON APIs, CSV, logs, pipelines, forms, time zones, headless tests ([Linux](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/linux/recipes/index.md), [Windows](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/windows/recipes/index.md)) |
| **Reference** | [Every command, option, format, limit, exit status and diagnostic](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/REFERENCE.md) |
| **Explanation** | [Architecture: process model, host discovery, security, lifecycle and watchdogs](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/ARCHITECTURE.md) |
| **Examples** | [Verified bash and PowerShell scripts, with a machine-readable catalogue](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md) |
| Qualification | [What was tested for 0.1.2, known limitations](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/QUALIFICATION.md) |
| Build and test | [Build](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/BUILD.md), [test suites](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/tests/README.md) |

## Project navigation

- [Overview and tutorials](https://github.com/nativehtmlkit/nativehtmlkit) — public developer landing page.
- [Capability and platform matrix](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/matrix.md) — which API works where.
- [Known limitations](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/limitations.md) — known defects and qualification limits.
- Active private development work is tracked in `nativehtmlkit-project`, not in this repository's documentation.
