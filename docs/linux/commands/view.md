# view: show records read-only (Linux)

`nativehtmlkit view` shows the records piped into it in a window with a single **Close**
button. It never writes to stdout. Plain lines are shown as one wrapping, scrolling text
block; every other input format as a table. Exact rules:
[OS-neutral reference](../../reference/view.md).

```text
nativehtmlkit view [OPTIONS] < records
```

| Outcome | Exit status | stdout |
|---|---|---|
| **Close**, or the window closed | 0 | empty |
| `--timeout` expired | 124 | empty |
| error | 1 | empty; `nativehtmlkit: error[<code>]: ...` on stderr |

`view` blocks until the window is closed. Unlike `select` it accepts **no records**: an
empty viewer is fine. It has no `--multi`, `--allow-empty` or `--output-format`.

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Without options: text

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view < data/app.log
```

Markup in the text is shown literally: the `<script>` in that log stays text.

Command output works the same way:

<!-- test: exit=124 calls="124@*x1" -->
```bash
ps -eo pid,user,pcpu,args --sort=-pcpu | head -n 200 | nativehtmlkit view
```

Nothing to show is not an error:

<!-- test: exit=124 calls="124@0x1" -->
```bash
printf '' | nativehtmlkit view
```

## `--input-format FORMAT`

`lines` (default), `csv`, `tsv`, `json`, `ndjson`; every format except `lines` is shown as a
table ([input formats](../input-formats.md)):

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit view --input-format csv < data/servers.csv
```

<!-- test: exit=124 calls="124@3x7" -->
```bash
nativehtmlkit view --input-format ndjson < data/app.ndjson
```

<!-- test: exit=124 calls="124@4x7" -->
```bash
nativehtmlkit view --input-format json < data/issues.json
```

`issues.json` has nested values (`user`, `labels`): they appear as compact JSON in their
cells. Reshape with `jq` first for a readable table:

<!-- test: exit=124 calls="124@4x4" -->
```bash
jq -c '[.[] | {"#": .number, Title: .title, Author: .user.login, Labels: ([.labels[].name] | join(", "))}]' data/issues.json |
  nativehtmlkit view --input-format json
```

<!-- test: exit=124 calls="124@2x3" -->
```bash
printf 'name\tsize\tmodified\nreport.pdf\t120 KiB\t2026-11-14\nnotes.txt\t2 KiB\t2026-11-16\n' |
  nativehtmlkit view --input-format tsv
```

## `--no-headers`

For `csv`/`tsv` without a header row; columns are named `column_1` ... `column_N`:

<!-- test: exit=124 calls="124@3x3" -->
```bash
printf 'alice,admin,2026-01-04\nbob,dev,2026-03-17\ncarol,ops,2026-06-30\n' |
  nativehtmlkit view --input-format csv --no-headers
```

## `--title TITLE`

Window title and heading (default `Output viewer`), 1-128 characters, shown as text:

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --title "app.log ($(wc -l < data/app.log) lines)" < data/app.log
```

## `--css FILE`

A trusted style sheet added after the built-in one ([CSS and forms](../css-and-forms.md)):

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit view --input-format csv --css css/light.css < data/servers.csv
```

## `--timeout SECONDS`

Close the viewer by itself after a while. Exit 0 (closed) and 124 (deadline) both mean
"done looking", so a script can carry on after either:

<!-- test: exit=0 calls="124@5x1" -->
```bash
nativehtmlkit view --timeout 300 --title 'Build log' < data/app.log || [[ $? -eq 124 ]] || exit 1
echo 'continuing'
```

<!-- stdout -->
```text
continuing
```

## `--host PATH`

<!-- test: exit=124 calls="0@none 124@1x1" -->
```bash
host=$(nativehtmlkit doctor | sed -n 's/^Core host: //p')
echo 'pinned host' | nativehtmlkit view --host "$host"
```

## `--diagnostics LEVEL`

<!-- test: exit=0 calls="124@1x1" -->
```bash
echo 'hello' | nativehtmlkit view --diagnostics debug 2> view.log || true
jq -rR 'fromjson? | select(.event == "session.started") | .context | "\(.mode) \(.rows)x\(.columns)"' view.log
```

<!-- stdout -->
```text
view 1x1
```

## `--rpc-timeout SECONDS`, `--liveness-interval SECONDS`, `--startup-timeout SECONDS`

The host watchdogs (defaults 30, 5 and 15 seconds). They limit how long the CLI waits for
a *host* that stopped working, never the person reading
([global options](../../reference/global-options.md#host-watchdogs)):

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --rpc-timeout 10 < data/app.log
```

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --liveness-interval 10 < data/app.log
```

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --startup-timeout 45 < data/app.log
```

## `-h`, `--help`

<!-- test: exit=0 shim=off -->
```bash
nativehtmlkit view --help | head -n 1
```

<!-- stdout -->
```text
Usage: nativehtmlkit view [OPTIONS]
```

## Options that `view` does not have

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | nativehtmlkit view --multi
```

<!-- stderr -->
```text
error: unexpected argument '--multi' found
```

## Limits

At most 2,000 lines or records, 32 columns and an 8 MiB stdin; the generated page must stay
under 1 MiB. More is an error, never a silent truncation, so cut first:

<!-- test: exit=124 calls="124@2000x1" -->
```bash
seq 1 100000 | tail -n 2000 | nativehtmlkit view --title 'last 2000'
```

<!-- test: exit=1 calls="1@none" -->
```bash
seq 1 2001 | nativehtmlkit view
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: 2001 rows exceeds the 2000-row initial GUI limit
```

See [view logs](../recipes/logs.md) for long lines and the
[limits reference](../../reference/limits.md).

## Related

[select](select.md), [form](form.md), [doctor](doctor.md),
[recipes](../recipes/index.md).
