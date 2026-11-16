# `nativehtmlkit select`

Show piped records as a table with a pick column and return the rows the user submits.

```text
nativehtmlkit select [OPTIONS]
```

| Option | Default | Meaning |
|---|---|---|
| `--input-format <FORMAT>` | `lines` | how stdin is parsed: `lines`, `csv`, `tsv`, `json`, `ndjson` ([input formats](input-formats.md)) |
| `--no-headers` | off | `csv`/`tsv`: the first record is data; columns are named `column_1` ... `column_N`. Accepted but without effect for the other formats. |
| `--multi` | off | checkboxes, any number of rows; without it, radio buttons and exactly one row |
| `--allow-empty` | off | Submit with nothing ticked is accepted and returns an empty result |
| `--output-format <FORMAT>` | `same` | `same`, `lines`, `csv`, `tsv`, `json`, `ndjson` ([output formats](output-formats.md)) |
| `--title <TITLE>` | `Select an item` | window title and page heading; 1-128 characters, no control characters, shown as text |
| `--css <PATH>` | none | trusted UTF-8 CSS file, at most 256 KiB, appended to the built-in style sheet ([page structure](page-structure.md)) |
| global options | | `--host`, `--diagnostics`, `--timeout`, `--rpc-timeout`, `--liveness-interval`, `--startup-timeout` ([global options](global-options.md)) |

## Behaviour

1. stdin must not be a terminal. A terminal stdin is refused at once:
   `nativehtmlkit: error[input.invalid]: stdin is a terminal; pipe records in, e.g. ...`, exit 1.
2. stdin is read to the end (at most 8 MiB), decoded as UTF-8 and parsed. Every parse or limit
   problem exits 1 with `error[input.invalid]` before any window opens.
3. At least one record is required:
   `error[input.invalid]: no selectable input rows; stdin was empty or contained no records`.
4. The window shows the title as a heading, a scrolling table (a `Pick` column, then one
   column per input column), an error line, and the buttons **Cancel** and **Submit selection**.
   Every cell and the title are HTML-escaped: input is always shown as text.
5. **Submit selection**:
   - nothing ticked and no `--allow-empty`: the window stays open and shows
     *select at least one row before submitting*;
   - otherwise the window closes and the chosen rows are written to stdout in **input order**
     (not click order), exit 0.
6. **Cancel**, or closing the window: exit 2, empty stdout. If Submit and a close arrive at the
   same instant, the close wins (exit 2).
7. `--timeout` expired: the window is closed, exit 124, empty stdout.

Keyboard: the pick controls and buttons are ordinary focusable controls (Tab moves, Space
toggles, Enter or Space activates a focused button).

## Examples

Every option of `select` with a verified example: [Linux (bash)](../linux/commands/select.md),
[Windows (PowerShell)](../windows/commands/select.md).

Related: exit statuses in scripts ([Linux](../linux/exit-codes-and-scripting.md),
[Windows](../windows/exit-codes-and-scripting.md)).
