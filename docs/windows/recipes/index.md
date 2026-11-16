# Recipes (Windows)

Task-oriented PowerShell recipes for CLI 0.1.2. Each one runs a complete script from the
repository's [examples](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md)
and explains the parts that matter. Every script works in Windows PowerShell 5.1 and
PowerShell 7, and every example was run against the released CLI by `scripts/test-docs.ps1`
([how](../index.md#how-the-examples-are-verified)).

| Recipe | You want to | Script |
|---|---|---|
| [Pick a Git branch](git-branch.md) | switch branches from a table of recent branches | `pick-git-branch.ps1` |
| [Delete files with confirmation](delete-files.md) | tick files, confirm, delete exactly those (`-WhatIf`) | `delete-files.ps1` |
| [Choose processes to stop](processes.md) | pick processes and stop them (`-WhatIf`) | `stop-process.ps1` |
| [Restart, stop or start Windows services](services.md) | pick services, then the action (Windows only) | `pick-service.ps1` |
| [Choose a Docker container](docker.md) | pick a container, then logs, restart or stop | `pick-container.ps1` |
| [Choose from JSON API output](json-api.md) | reshape a REST response and use the chosen records | `pick-from-api.ps1` |
| [Review and export CSV reports](csv-report.md) | view a CSV, export the rows you tick | `csv-report.ps1` |
| [View logs and events](logs.md) | show a text log or the Windows event log | `view-logs.ps1` |
| [Multi-select in pipelines](pipelines.md) | use `select` between PowerShell commands | `search-selected.ps1` |
| [A deployment form](deploy-form.md) | collect validated parameters, confirm, return an object | `deploy-form.ps1` |
| [Choose a time zone in a light theme](timezone.md) | one value from a long list, restyled with `--css` | `pick-timezone.ps1` |
| [Test your scripts without a desktop](headless-testing.md) | run your own scripts in CI | |

New to the CLI? Start with the [tutorial](../tutorial.md). Every option:
[select](../commands/select.md), [view](../commands/view.md), [form](../commands/form.md),
[doctor](../commands/doctor.md).
