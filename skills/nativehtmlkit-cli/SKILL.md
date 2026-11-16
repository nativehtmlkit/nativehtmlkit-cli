---
name: nativehtmlkit-cli
description: Use the NativeHTMLKit standalone native CLI for interactive selection, read-only views and HTML forms from a shell.
---

# NativeHTMLKit CLI

The executable `nativehtmlkit` (alias `nhk`) 0.1.2 is an **independent Rust CLI** that opens
a native window through a bundled Core 1.0.3 host. It is not installed by the Python or
PowerShell SDKs. `nativehtmlkit doctor` shows which host it uses.

```bash
printf 'one\ntwo\nthree\n' | nativehtmlkit select --multi                    # chosen lines, input order
printf 'name,age\nAda,30\nBob,40\n' | nativehtmlkit select --input-format csv --output-format json
docker ps --format '{{json .}}' | nativehtmlkit select --input-format ndjson --output-format json
ps aux | nativehtmlkit view                                                   # read-only, no stdout
nativehtmlkit form --html form.html --timeout 600                             # {"entries":[{"kind","name","value"}...]}
```

Rules:

- Exit status: `0` submitted / viewer closed, `2` Cancel or window closed, `124` `--timeout`
  passed, `1` error (`nativehtmlkit: error[<code>]: ...` on stderr), `130`/`143`/`129` signals.
  stdout holds only the result and is empty on every non-zero status. Never parse stderr.
- Capture the status explicitly (`out=$(...) || status=$?`); in a pipeline read
  `PIPESTATUS`; in PowerShell check `$LASTEXITCODE`. Use `xargs -r`.
- Input formats `lines` (default), `csv`, `tsv` (header row unless `--no-headers`; `"` quotes
  also in TSV), `json` (one document; array = rows), `ndjson`. UTF-8 only, at most 8 MiB,
  2,000 rows, 32 columns, and a generated page under 1 MiB / 65,536 nodes; errors exit 1
  before a window opens. `select` needs at least one row.
- Output `--output-format same|lines|csv|tsv|json|ndjson`: rows in input order, JSON values
  unchanged; `lines` refuses values with newlines.
- stdin rows and `--title` are always escaped. `--html`/`--css` are trusted files (max 256 KiB):
  escape dynamic values yourself (`jq -rn --arg s "$v" '$s|@html'`,
  `[System.Net.WebUtility]::HtmlEncode`). The form needs `<form id="nhk-form">` and named
  controls; Core validates `required`, `pattern`, `min`/`max`, `type=email` on Submit.
- No default limit on user thinking time; `--timeout` adds one. `--rpc-timeout`,
  `--liveness-interval`, `--startup-timeout` only bound a hung host.
- Windows PowerShell 5.1: set `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` (not
  `[Text.Encoding]::UTF8`, whose BOM breaks `json` input) and `[Console]::OutputEncoding`
  likewise; pipe `Select-Object ... | ConvertTo-Json`; read results with
  `ConvertFrom-Json -InputObject ($out -join "`n")`.

[Examples](references/examples.md) and the full
[reference](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/REFERENCE.md).
