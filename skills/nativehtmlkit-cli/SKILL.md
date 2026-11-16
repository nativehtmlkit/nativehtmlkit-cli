---
name: nativehtmlkit-cli
description: Use the NativeHTMLKit standalone native CLI for interactive selection, read-only views and HTML forms from a shell.
---

# NativeHTMLKit CLI

The executable `nativehtmlkit` (optional alias `nhk`) is an **independent Rust CLI**. It is not installed by the Python SDK.

```bash
printf 'one\ntwo\nthree\n' | nativehtmlkit select --multi
printf 'name,age\nAda,30\nBob,40\n' | nativehtmlkit select --input-format csv --output-format json
ps aux | nativehtmlkit view
nativehtmlkit doctor
```

Use only valid input formats (lines/csv/tsv/json/ndjson). Check exit codes: `0` submit/view closed, `2` cancel, `124` timeout, `1` error, `130` interrupt. Keep stdout strictly for selection results. Do not treat a slow human as hung; CLI host liveness and user timeout are different controls.

`nativehtmlkit form --html path` needs a trusted `<form id="nhk-form">`. Never embed untrusted HTML as a form fragment; input rows are escaped. Check the installed `nativehtmlkit --help` for exact flags. [Examples](references/examples.md) and [reference](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/docs/REFERENCE.md).
