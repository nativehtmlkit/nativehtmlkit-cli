# NativeHTMLKit CLI on Linux

`nativehtmlkit` (alias `nhk`) puts a native window into a shell pipeline: pipe records in,
let a person pick, view or fill in something, and read the result from stdout. This
section documents CLI **0.1.2** (bundled with Core host 1.0.3) for bash on Linux x86-64.
For Windows and PowerShell see the [Windows section](../windows/index.md).

<!-- test: exit=124 calls="124@4x1" -->
```bash
git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch'
```

## Install

Download the Linux archive and the checksum file from the
[v0.1.2 release](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/tag/v0.1.2)
(in the browser, or with the GitHub CLI as below) and check the archive:

<!-- not-tested: needs the network; the same commands were run by hand for this release -->
```bash
gh release download v0.1.2 -R nativehtmlkit/nativehtmlkit-cli -p '*linux-x64*' -p SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

```text
nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz: OK
```

Without `gh`: `curl -fLO https://github.com/nativehtmlkit/nativehtmlkit-cli/releases/download/v0.1.2/nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz`
and the same for `SHA256SUMS`.

Extract it and check the files inside against the archive's own `SHA256SUMS`:

<!-- not-tested: runs on the downloaded archive; done by hand for this release -->
```bash
tar -xzf nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz
cd nativehtmlkit-cli-v0.1.2-linux-x64
sha256sum -c SHA256SUMS
./nhk doctor
```

The directory contains:

| File | What it is |
|---|---|
| `nativehtmlkit` | the CLI |
| `nhk` | a symbolic link to `nativehtmlkit` (the short alias) |
| `nativehtmlkit-host` | Core host 1.0.3, the program that draws the window; keep it beside the CLI |
| `manifest.json`, `SHA256SUMS` | versions, source commits, protocol version and hashes |
| `examples/sample-form.html` | the smallest form for `nativehtmlkit form` |
| `LICENSE`, `licenses/` | licences of the CLI, Core and third-party components |

### Put it on PATH

Move the directory somewhere permanent and link the executables into a directory on your
`PATH`. Leave `nativehtmlkit-host` where it is: the CLI resolves its own symbolic link and
finds the host beside the real file.

<!-- not-tested: changes the system; done by hand for this release -->
```bash
sudo mv nativehtmlkit-cli-v0.1.2-linux-x64 /opt/nativehtmlkit-cli
mkdir -p ~/.local/bin
ln -s /opt/nativehtmlkit-cli/nativehtmlkit ~/.local/bin/nativehtmlkit
ln -s /opt/nativehtmlkit-cli/nativehtmlkit ~/.local/bin/nhk
```

Check it (open a new terminal if `~/.local/bin` was not on `PATH` yet):

<!-- test: exit=0 calls="0@none" -->
```bash
nativehtmlkit doctor
```

```text
NativeHTMLKit CLI 0.1.2
Core host: /opt/nativehtmlkit-cli/nativehtmlkit-host
nativehtmlkit-host 1.0.3
```

Needs a graphical session (Wayland or X11). The CLI writes no configuration files; to
uninstall, delete the directory and the links.

## First command

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi
```

A window lists the three lines with a checkbox each. Tick some and click **Submit
selection**: they are printed, one per line, and the exit status is 0. Click **Cancel**:
nothing is printed and the status is 2.

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
| [select](commands/select.md), [view](commands/view.md), [form](commands/form.md), [doctor](commands/doctor.md) | every option of every command, with a verified bash example |
| [Input formats](input-formats.md) | `lines`, `csv`, `tsv`, `json`, `ndjson`, `--no-headers` |
| [Output formats](output-formats.md) | `same`, `lines`, `csv`, `tsv`, `json`, `ndjson`: the exact bytes |
| [Exit codes and scripting](exit-codes-and-scripting.md) | 0, 1, 2, 124, 129, 130, 143; `set -e`, `PIPESTATUS`, temporary files |
| [Environment and diagnostics](environment-and-diagnostics.md) | environment variables, `--diagnostics` levels, reading the records |
| [CSS and forms](css-and-forms.md) | `--css` themes, writing and generating `--html` forms safely |
| [Troubleshooting](troubleshooting.md) | every error line and what to do |
| [Recipes](recipes/index.md) | Git branches, files, processes, Docker, JSON APIs, CSV, logs, pipelines, a deployment form, time zones, headless tests |
| [Tutorial: a project picker](tutorial.md) | build `proj`, a bookmark tool using all three window commands |
| [Tutorial: a Git branch picker](tutorial-branch-picker.md) | build `git-pick` with `select`, TSV and `--multi` |

The exact, OS-neutral specification is the [reference](../REFERENCE.md); runnable scripts
are listed in the [example catalogue](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md).

## How the examples are verified

The examples on these pages run in the `examples` directory of a clone of this repository:

```bash
git clone https://github.com/nativehtmlkit/nativehtmlkit-cli.git
cd nativehtmlkit-cli/examples
```

Every bash block that calls the CLI is run by
[`scripts/test-docs.py`](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/scripts/test-docs.py)
against the released Linux archive (CLI 0.1.2, Core host 1.0.3) with its real host, in
headless mode (no window and nobody to click). That proves the input and options are
accepted, the page renders, and the documented exit status and output follow; since nobody
clicks, each window ends by its deadline. Three kinds of results are shown:

- **stdout / stderr** blocks: the text the example printed in that run.
- **"Submit prints"** blocks: what the CLI writes when the user ticks the named rows. They
  are checked by running the release's own parsing, selection and output code on the exact
  stdin and options the example gave the CLI.
- **Replayed results**: a recorded Submit result, in the exact output format, handed to the
  script after the real CLI call was accepted, to show what the script does with it.

What a person sees and clicks (layout, keyboard, Cancel, closing the window) is covered by the
release's GUI qualification on KDE Plasma (Wayland) and Windows.
