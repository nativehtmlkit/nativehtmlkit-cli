# Examples

Small, complete tools built on `nativehtmlkit` 0.1.2. Each script starts with a comment that
says what it teaches, how to run it, what it needs and how it exits. All of them follow the
same contract: **0** done, **2** cancelled, **124** no decision before the deadline, **1**
error, and nothing is changed unless the user submitted.

Put the CLI on `PATH` first ([install](../docs/guides/install-and-host-discovery.md)); run the
scripts from this directory (`cd examples`).

## bash (Linux)

| Script | What it does | Teaches |
|---|---|---|
| [pick-git-branch.sh](pick-git-branch.sh) | switch to a branch chosen from a table of recent branches | `jq -R` to JSON rows, single choice, `.[0].Branch` |
| [delete-files.sh](delete-files.sh) | tick files, confirm, delete exactly those | NUL-safe lists, confirmation `select`, `xargs -0 rm --` |
| [kill-process.sh](kill-process.sh) | pick processes and a signal | `ps` to quoted CSV, CSV in / JSON out |
| [pick-container.sh](pick-container.sh) | pick a Docker container, then logs/restart/stop/shell | NDJSON from `docker ps`, chained selections, `view` |
| [pick-from-api.sh](pick-from-api.sh) | choose issues from an API response, print their URLs | reshaping nested JSON, records returned unchanged |
| [csv-report.sh](csv-report.sh) | view a CSV report, export ticked rows | `view`, CSV in/out, writing through a temporary file |
| [grep-selected.sh](grep-selected.sh) | grep only the files you tick | `select` inside a pipeline, `PIPESTATUS`, `xargs -r -d '\n'` |
| [view-logs.sh](view-logs.sh) | show the end of a text or JSON-lines log | `view` for text and NDJSON, staying inside the page limit |
| [deploy-form.sh](deploy-form.sh) | collect deployment parameters, print them as JSON | generated and escaped `--html`, constraint validation, parsing `entries`, confirmation |
| [pick-timezone.sh](pick-timezone.sh) | choose a time zone in a light-themed window | `--css` theme via custom properties |
| [tutorial/proj.sh](tutorial/proj.sh) | bookmark project directories, `cd "$(proj.sh pick)"` | everything above in one tool; built in the [tutorial](../docs/tutorials/build-a-project-picker.md) |

Needs: bash 4+, `jq`; some scripts also `git`, GNU `find`/`xargs`, procps `ps`, `perl`, `docker`.

## PowerShell (Windows PowerShell 5.1 and PowerShell 7)

| Script | What it does | Teaches |
|---|---|---|
| [pick-git-branch.ps1](pick-git-branch.ps1) | switch to a branch chosen from a table | objects -> `ConvertTo-Json`, `$LASTEXITCODE`, `ConvertFrom-Json -InputObject` |
| [delete-files.ps1](delete-files.ps1) | tick files, confirm, delete | `SupportsShouldProcess` (`-WhatIf`), `-LiteralPath` |
| [stop-process.ps1](stop-process.ps1) | pick processes and stop them | `Get-Process` with computed properties |
| [pick-service.ps1](pick-service.ps1) | restart, stop or start chosen Windows services (Windows only) | an action chosen in a second window |
| [pick-container.ps1](pick-container.ps1) | pick a Docker container and an action | NDJSON, native stderr with `$ErrorActionPreference` |
| [pick-from-api.ps1](pick-from-api.ps1) | choose issues from `Invoke-RestMethod` or a saved response | date handling in 5.1 vs 7 |
| [csv-report.ps1](csv-report.ps1) | view a CSV, export ticked rows | raw text in/out, UTF-8 without BOM |
| [deploy-form.ps1](deploy-form.ps1) | collect deployment parameters, return an object | `HtmlEncode`, entries -> hashtable |
| [view-logs.ps1](view-logs.ps1) | show a log file, or recent Windows events | `Get-Content -Tail`, `Get-WinEvent` |

Every PowerShell script sets `[Console]::OutputEncoding` and `$OutputEncoding` to UTF-8
without BOM and restores the console encoding at the end
([why](../docs/guides/windows-powershell.md)).

## Data and styles

| File | Used by |
|---|---|
| [sample-form.html](sample-form.html) | the smallest `form`: `nativehtmlkit form --html sample-form.html` (also shipped in the release archive) |
| [data/issues.json](data/issues.json) | `pick-from-api.*` (a sample API response) |
| [data/servers.csv](data/servers.csv) | `csv-report.*` |
| [data/app.log](data/app.log), [data/app.ndjson](data/app.ndjson) | `view-logs.*` |
| [css/light.css](css/light.css) | `pick-timezone.sh`; any command with `--css` |
| [css/form.css](css/form.css) | `deploy-form.*` |
| [tutorial/proj.css](tutorial/proj.css) | `tutorial/proj.sh` |

## Verification

```bash
scripts/test-examples.sh --cli /path/to/nativehtmlkit                  # bash examples, tutorial, reference contract
pwsh -File scripts/test-examples.ps1 -Cli /path/to/nativehtmlkit       # PowerShell examples (PowerShell 7)
powershell.exe -File scripts\test-examples.ps1 -Cli C:\path\nativehtmlkit.exe -Shell powershell.exe   # Windows PowerShell 5.1
```

Run from the repository root. The harnesses use the test-only switch
`NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` (the real host, no window) and a short `--timeout`, so
every window ends with exit 124; they assert each call's parsed rows x columns, the example's
exit status and that it changed nothing. Replay cases feed a recorded result to check what
the example does after a Submit. How it works:
[testing scripts without a desktop](../docs/guides/testing-scripts-headless.md).
