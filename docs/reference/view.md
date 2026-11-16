# `nativehtmlkit view`

Show piped records read-only. There is no result: stdout stays empty.

```text
nativehtmlkit view [OPTIONS]
```

| Option | Default | Meaning |
|---|---|---|
| `--input-format <FORMAT>` | `lines` | `lines`, `csv`, `tsv`, `json`, `ndjson` ([input formats](input-formats.md)) |
| `--no-headers` | off | `csv`/`tsv`: the first record is data (`column_1` ... `column_N`) |
| `--title <TITLE>` | `Output viewer` | 1-128 characters, no control characters, shown as text |
| `--css <PATH>` | none | trusted UTF-8 CSS file, at most 256 KiB |
| global options | | [global options](global-options.md) |

`view` has no `--multi`, `--allow-empty` or `--output-format`; passing one is a usage error
(exit 1).

## Behaviour

- stdin must not be a terminal and is parsed exactly as for `select`; parse and limit errors
  exit 1 with `error[input.invalid]`.
- Unlike `select`, **no records is fine**: empty stdin, `[]`, or a CSV header without data
  rows opens an empty viewer. (Completely empty stdin with `--input-format csv`/`tsv` is still
  an error: *expected at least one header column*.)
- `lines` input is shown as one wrapped, scrolling text block (`<pre>`), so the 65,536-node
  limit does not apply; only the 1 MiB page limit does ([limits](limits.md)). Every other
  format is shown as a table, one column per input column.
- The only button is **Close**. Close, or closing the window: exit 0, empty stdout.
- `--timeout` expired: exit 124, empty stdout.

## Examples

Every option of `view` with a verified example: [Linux (bash)](../linux/commands/view.md),
[Windows (PowerShell)](../windows/commands/view.md).

`view` returns only when the window is closed (or the deadline passes), so a script waits
at that line. Related: viewing logs ([Linux](../linux/recipes/logs.md),
[Windows](../windows/recipes/logs.md)).
