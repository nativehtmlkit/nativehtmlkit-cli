# Normative CLI contract — candidate v0.1 and planned commands

This is the **proposed public surface**. Mark a command `P1` etc as planned until implemented and accepted. Flags are stable only after publication; the agent should freeze the syntax in tests before release.

## Executable and modes

- Primary command: `nhk`; long fallback alias: `nativehtmlkit` (confirm executable/package name availability before distribution).
- Rust console application, Linux x64 Wayland and Windows x64 Desktop Experience.
- Hidden `__internal-backend` mode is not a public API and requires the host-provided authenticated session environment.
- `nhk --help`, `nhk --version`, `nhk doctor` provide CLI diagnostics. `doctor` should report host compatibility and desktop availability without starting a window.
- Interactive commands never print banners/progress/diagnostics to stdout; output is data only.

## Proposed command synopsis

```text
nhk select [--multi] [--title TEXT] [--input lines|csv|tsv|json|ndjson]
           [--output same|lines|json|ndjson|csv|tsv|values|result-json]
           [--file PATH] [--columns A,B,...] [--value-field FIELD]
           [--min N] [--max N] [--allow-empty] [--search TEXT]
           [--theme system|dark|light]
nhk view [--title TEXT] [--file PATH] [--input text|json|ndjson|csv|tsv]
nhk input --label TEXT [--default TEXT] [--required] [--title TEXT]
nhk confirm --message TEXT [--title TEXT]
nhk form (--spec PATH | --html PATH [--css PATH]) [--input json]
         [--file PATH] [--output json|result-json]
nhk doctor [--json]
nhk --help
nhk --version
```

## Roadmap of CLI command availability

| Command | Initial stage | Initial behavior |
|---|---|---|
| `select --input lines` | P1 | Single/multi selection of lines, search, Submit/Cancel, stdout lines |
| `select` structured formats | P2 | CSV, TSV, JSON array, NDJSON, display columns, stable row IDs |
| `view` | P2 | Read-only text/structured viewer; no stdout |
| `input` | P3 | One text value; output UTF-8 line |
| `confirm` | P3 | No stdout; status indicates approved/cancelled |
| `form --spec` | P3 | Declarative supported controls with JSON output |
| `form --html/--css` | P4 | Trusted user-supplied local HTML/CSS; form names serialized |
| `doctor` | P0 | No GUI; test host/runtime/desktop prerequisites |
| `--follow` | Future | Live streams with separate bounded data path |

## Selection details

- Without `--multi`, exactly one row may be submitted. With `--multi`, any number from `--min` to `--max` (inclusive) if supplied. Default `--min=1`, `--max=1` for single and unset maximum for multi (subject to row count). `--allow-empty` changes minimum to 0 if `--min` is not explicitly specified.
- `--input` defaults to `lines`; no implicit guessing. For `view`, input defaults to `text`.
- `--output` defaults to `same` on `select`: lines → lines, csv → csv, tsv → tsv, json → json, ndjson → ndjson. On all structured selections, **emit selected records**, not screen text. CSV/TSV include the canonical header once when at least one record is emitted, unless a future `--no-header` flag is introduced.
- `--columns` controls display projection only, never modifies underlying records. `--value-field` with `--output values` extracts one named field and outputs one scalar per line; reject nested objects, embedded newlines and NUL in line mode.
- `--file` specifies a UTF-8 input file; otherwise input comes from stdin. If no piped stdin and no file, fail usage instead of blocking indefinitely on interactive TTY.
- No `--exec`, file mutation, network fetch or shell command interpolation from selected records.

## Exit code contract

| Code | Meaning | stdout |
|---:|---|---|
| 0 | successful Submit / accepted confirm; `view` closed normally | submitted data for result commands; empty for `view`/`confirm` |
| 2 | CLI syntax, configuration or incompatible flag combinations | empty |
| 3 | no supported interactive desktop available | empty |
| 4 | host, backend, protocol, result receipt or lifecycle failure | empty |
| 5 | input parse/encoding/size/row-limit error | empty |
| 6 | post-submit stdout/write error (including broken downstream pipe) | may be partially written; do not claim rollback |
| 10 | explicit user Cancel/Escape/normal close | empty |
| 124 | explicit timeout after feature added | empty |
| 130 | terminal interruption (Ctrl+C / SIGINT) | empty |

Avoid overloading exit 1 with every error. The exact taxonomy can be adjusted **before** publishing P1, but must then be contract-tested. No automatic TUI fallback when desktop is unavailable.

## Example v0.1

```bash
printf 'alpha\nbeta\ngamma\n' | nhk select --multi | sort
```

If the user selects alpha and gamma, stdout from `nhk` is `alpha\ngamma\n` and status 0. A sorted display does not affect output order. If the user cancels, status 10 and stdout 0 bytes. In Bash use `set -o pipefail` when you need the pipeline to report cancellation; `sort` alone may otherwise mask it.

## Command-line hygiene

- Help and errors identify flags and include self-contained examples.
- Reject duplicate single-valued options, unknown options and values outside documented enum/range.
- Use built-in `clap` help; avoid shell-specific parsing or environment-driven hidden mutations.
- Do not process stdin before checking syntax and desktop preconditions where possible, but avoid losing useful parse errors: define test order as args → input presence/format → desktop preflight → read snapshot → GUI. Desktop preflight should not depend on stdin.
