# Examples

Small, complete tools built on `nativehtmlkit` 0.1.2, each in bash (Linux) and PowerShell
(Windows PowerShell 5.1 and PowerShell 7). Each script starts with a comment that says what
it teaches, how to run it, what it needs and how it exits. All of them follow the same
contract: **0** done, **2** cancelled, **124** no decision before the deadline, **1** error,
and nothing is changed unless the user submitted.

The machine-readable list is [catalog.toml](catalog.toml) (id, title, summary, what it
teaches, the Linux and Windows file, the exact command, the related documentation page).
Put the CLI on `PATH` first (install on [Linux](../docs/linux/index.md#install) or
[Windows](../docs/windows/index.md#install)) and run the scripts from this directory.

| Example | Linux (bash) | Windows (PowerShell) | Recipe |
|---|---|---|---|
| Pick a Git branch | [pick-git-branch.sh](pick-git-branch.sh) | [pick-git-branch.ps1](pick-git-branch.ps1) | [Linux](../docs/linux/recipes/git-branch.md), [Windows](../docs/windows/recipes/git-branch.md) |
| Delete files with confirmation | [delete-files.sh](delete-files.sh) | [delete-files.ps1](delete-files.ps1) | [Linux](../docs/linux/recipes/delete-files.md), [Windows](../docs/windows/recipes/delete-files.md) |
| Choose processes to stop | [kill-process.sh](kill-process.sh) | [stop-process.ps1](stop-process.ps1) | [Linux](../docs/linux/recipes/processes.md), [Windows](../docs/windows/recipes/processes.md) |
| Choose a Docker container | [pick-container.sh](pick-container.sh) | [pick-container.ps1](pick-container.ps1) | [Linux](../docs/linux/recipes/docker.md), [Windows](../docs/windows/recipes/docker.md) |
| Choose from JSON API output | [pick-from-api.sh](pick-from-api.sh) | [pick-from-api.ps1](pick-from-api.ps1) | [Linux](../docs/linux/recipes/json-api.md), [Windows](../docs/windows/recipes/json-api.md) |
| Review and export CSV reports | [csv-report.sh](csv-report.sh) | [csv-report.ps1](csv-report.ps1) | [Linux](../docs/linux/recipes/csv-report.md), [Windows](../docs/windows/recipes/csv-report.md) |
| View logs (Windows: also events) | [view-logs.sh](view-logs.sh) | [view-logs.ps1](view-logs.ps1) | [Linux](../docs/linux/recipes/logs.md), [Windows](../docs/windows/recipes/logs.md) |
| Search only the files you tick | [grep-selected.sh](grep-selected.sh) | [search-selected.ps1](search-selected.ps1) | [Linux](../docs/linux/recipes/pipelines.md), [Windows](../docs/windows/recipes/pipelines.md) |
| A deployment form | [deploy-form.sh](deploy-form.sh) | [deploy-form.ps1](deploy-form.ps1) | [Linux](../docs/linux/recipes/deploy-form.md), [Windows](../docs/windows/recipes/deploy-form.md) |
| Choose a time zone in a light theme | [pick-timezone.sh](pick-timezone.sh) | [pick-timezone.ps1](pick-timezone.ps1) | [Linux](../docs/linux/recipes/timezone.md), [Windows](../docs/windows/recipes/timezone.md) |
| Windows services (Windows only) | | [pick-service.ps1](pick-service.ps1) | [Windows](../docs/windows/recipes/services.md) |
| Project picker (tutorial) | [tutorial/proj.sh](tutorial/proj.sh) | [tutorial/proj.ps1](tutorial/proj.ps1) | [Linux](../docs/linux/tutorial.md), [Windows](../docs/windows/tutorial.md) |
| Branch picker, step 1 (tutorial) | [step1-pick.sh](tutorial-branch-picker/step1-pick.sh) | [step1-pick.ps1](tutorial-branch-picker/step1-pick.ps1) | [Linux](../docs/linux/tutorial-branch-picker.md), [Windows](../docs/windows/tutorial-branch-picker.md) |
| git-pick (tutorial) | [git-pick.sh](tutorial-branch-picker/git-pick.sh) | [git-pick.ps1](tutorial-branch-picker/git-pick.ps1) | [Linux](../docs/linux/tutorial-branch-picker.md), [Windows](../docs/windows/tutorial-branch-picker.md) |

bash scripts need bash 4+ and `jq`; some also `git`, GNU `find`/`xargs`, procps `ps`, `perl`,
`docker`. Every PowerShell script sets `[Console]::OutputEncoding` and `$OutputEncoding` to
UTF-8 without BOM and restores the console encoding at the end
([why](../docs/windows/index.md#set-up-utf-8-once)).

## Data and styles

| File | Used by |
|---|---|
| [sample-form.html](sample-form.html) | the smallest `form`: `nativehtmlkit form --html sample-form.html` (also shipped in the release archive) |
| [data/issues.json](data/issues.json) | `pick-from-api.*` (a sample API response) |
| [data/servers.csv](data/servers.csv) | `csv-report.*` and many documentation examples |
| [data/app.log](data/app.log), [data/app.ndjson](data/app.ndjson) | `view-logs.*` |
| [css/light.css](css/light.css) | `pick-timezone.*`; any command with `--css` |
| [css/form.css](css/form.css) | `deploy-form.*` |
| [tutorial/proj.css](tutorial/proj.css) | `tutorial/proj.*` |

## Verification

```bash
scripts/test-examples.sh --cli /path/to/nativehtmlkit                  # bash examples, tutorials, reference contract
pwsh -File scripts/test-examples.ps1 -Cli /path/to/nativehtmlkit       # PowerShell examples (PowerShell 7)
powershell.exe -File scripts\test-examples.ps1 -Cli C:\path\nativehtmlkit.exe -Shell powershell.exe   # Windows PowerShell 5.1
```

Run from the repository root. The harnesses use the test-only switch
`NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` (the real host, no window) and a short `--timeout`, so
every window ends with exit 124; they assert each call's parsed rows x columns, the example's
exit status and that it changed nothing. Replay cases feed a recorded result to check what
the example does after a Submit. Each harness fails when an example listed in
[catalog.toml](catalog.toml) for its OS is not run. The documentation pages that use these
scripts are verified by `scripts/test-docs.py` and `scripts/test-docs.ps1`. How it works:
testing scripts without a desktop ([Linux](../docs/linux/recipes/headless-testing.md),
[Windows](../docs/windows/recipes/headless-testing.md)).
