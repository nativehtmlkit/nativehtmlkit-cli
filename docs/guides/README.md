# How-to guides

Task recipes for `nativehtmlkit` 0.1.2. Each guide has bash and PowerShell versions; the
complete scripts are in [examples/](../../examples/README.md) and are verified by
`scripts/test-examples.sh` (bash) and `scripts/test-examples.ps1` (Windows PowerShell 5.1 and
PowerShell 7).

| Guide | You want to |
|---|---|
| [Install and find the host](install-and-host-discovery.md) | get the release running and know which Core host it uses |
| [Handle Cancel, timeout and errors](handling-exit-status.md) | write scripts that treat exit 2, 124 and 1 correctly, also inside pipelines |
| [Pick a Git branch](picking-a-git-branch.md) | switch branches from a table of recent branches |
| [Delete files with confirmation](deleting-files-safely.md) | tick files, confirm, delete exactly those |
| [Choose processes to stop](choosing-processes.md) | pick processes and a signal |
| [Choose a Docker container](choosing-a-docker-container.md) | pick a container, then an action |
| [Choose from JSON API output](choosing-from-json-apis.md) | reshape REST/`jq` output into rows and use the selection |
| [Review and export CSV reports](csv-reports.md) | view a CSV, export chosen rows as CSV |
| [Multi-select into xargs and pipelines](pipelines-and-xargs.md) | use `select` as one stage of a pipeline |
| [Collect input with a form](collecting-input-with-forms.md) | deployment parameters with validation, parsed from JSON |
| [View logs](viewing-logs.md) | show text or JSON logs in a window |
| [Style windows with CSS](styling-with-css.md) | themes and form layout with `--css` |
| [Script in Windows PowerShell](windows-powershell.md) | encodings, objects, `$LASTEXITCODE`, 5.1 vs 7 |
| [Diagnostics and troubleshooting](diagnostics-and-troubleshooting.md) | find out why a command failed |
| [Test scripts without a desktop](testing-scripts-headless.md) | run your own scripts in CI the way this repository tests its examples |

New to the CLI? Start with the [tutorial](../tutorials/build-a-project-picker.md). Exact
behaviour of every option is in the [reference](../REFERENCE.md).
