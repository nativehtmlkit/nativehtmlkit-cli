# Recipes (Linux)

Task-oriented bash recipes for CLI 0.1.2. Each one runs a complete script from the
repository's [examples](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md)
and explains the parts that matter. Every example was run against the released CLI by
`scripts/test-docs.py` ([how](../index.md#how-the-examples-are-verified)).

| Recipe | You want to | Script |
|---|---|---|
| [Pick a Git branch](git-branch.md) | switch branches from a table of recent branches | `pick-git-branch.sh` |
| [Delete files with confirmation](delete-files.md) | tick files, confirm, delete exactly those | `delete-files.sh` |
| [Choose processes to signal](processes.md) | pick processes and a signal | `kill-process.sh` |
| [Choose a Docker container](docker.md) | pick a container, then logs, restart, stop or a shell | `pick-container.sh` |
| [Choose from JSON API output](json-api.md) | reshape a REST response and use the chosen records | `pick-from-api.sh` |
| [Review and export CSV reports](csv-report.md) | view a CSV, export the rows you tick | `csv-report.sh` |
| [View logs](logs.md) | show text or JSON-lines logs | `view-logs.sh` |
| [Multi-select in pipelines and xargs](pipelines.md) | use `select` as one stage of a pipeline | `grep-selected.sh` |
| [A deployment form](deploy-form.md) | collect validated parameters and confirm | `deploy-form.sh` |
| [Choose a time zone in a light theme](timezone.md) | one value from a long list, restyled with `--css` | `pick-timezone.sh` |
| [Test your scripts without a desktop](headless-testing.md) | run your own scripts in CI | |

New to the CLI? Start with the [tutorial](../tutorial.md). Every option:
[select](../commands/select.md), [view](../commands/view.md), [form](../commands/form.md),
[doctor](../commands/doctor.md).
