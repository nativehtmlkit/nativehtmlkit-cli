# Output formats

What `select` writes to stdout after a successful Submit (exit 0). `view` never writes to
stdout; `form` always writes one JSON line ([form](form.md)). On every other exit status
stdout is empty.

Common rules:

- The chosen rows are written in **input order**, whatever order they were ticked in.
- The whole result is encoded first and written in one piece, then stdout is flushed; a
  failed write is `error[output.failed]`, exit 1.
- Output is UTF-8; every format ends with a newline.
- With `--allow-empty` and nothing ticked: `lines`, `ndjson` write nothing; `json` writes
  `[]` and a newline; `csv`/`tsv` write the header line only.

`--output-format same` (the default) means: the format named by `--input-format`.

## `lines`

One line per chosen row, each ending in `\n`:

- a `lines` row: the original line text;
- any other row whose value is a string (a JSON string, an NDJSON string line): that string;
- any other row: its display cells joined with a tab (a CSV row `web-01,frontend` becomes
  `web-01<TAB>frontend`; a JSON object row its cell texts in column order).

If a value to be written contains `\n` or `\r`, nothing is written and the command fails:
`error[output.failed]: selected value contains newline: use --output-format json or ndjson`,
exit 1. A line therefore never turns into two records downstream.

## `json`

One JSON array of the chosen rows' **values**, on one line:

| Input | Element written |
|---|---|
| `lines` | the line as a JSON string |
| `csv`/`tsv` | an object `{"header": "field", ...}`, all values strings, keys in header order |
| `json`/`ndjson` | the original value: key order, nesting, `null`, booleans and number text are kept (`12345678901234567890123`, `2.50`); only an exponent is normalised (`1e3` is written `1e+3`, the same number) |

```text
$ printf '[{"id":1,"name":"x"},{"id":2.50,"name":"y"}]' | nativehtmlkit select --input-format json --multi
[{"id":1,"name":"x"},{"id":2.50,"name":"y"}]        # both ticked
```

## `ndjson`

The same values as `json`, one compact JSON document per line.

## `csv` and `tsv`

A header line with the column names, then one record per chosen row with its display
cells, quoted where needed (`"has, comma"`, `"say ""hi"""`, a field with a line break is
quoted and keeps it). `tsv` uses a tab as delimiter and the same quoting rules. Line ends are
`\n`.

For `json`/`ndjson` input the columns are the union of keys and the cells are the display
texts described in [input formats](input-formats.md) (nested values as compact JSON, `null`
as an empty field).

## Examples of exact output

These are the byte sequences the release's GUI qualification asserts after real clicks:

| Command (input) | Rows ticked | stdout |
|---|---|---|
| `select --multi` (`alpha\nbeta\ngamma\n`) | gamma, then alpha | `alpha\ngamma\n` |
| `select --input-format json` (objects with number, boolean, string, array, null) | row 2 | `[{"id":2.5,"ok":false,"name":"Příliš 😀","tags":[],"none":null}]\n` |
| `select --input-format ndjson --multi` (`{"a":1}`, `{"a":"two"}`, blank line, `{"a":[3]}`) | rows 1 and 3 | `{"a":1}\n{"a":[3]}\n` |
| `select --input-format csv --multi` (header `name,comment`, fields with comma, quotes, line break) | first three | `name,comment\nplain,"has, comma"\nquote,"say ""hi"""\nnl,"line1\nline2"\n` |
| `select --input-format csv --output-format tsv` (same input) | first | `name\tcomment\nplain\thas, comma\n` |
| `select --input-format csv --output-format lines` (same input) | the row with a line break | exit 1, empty stdout |
| `select --multi` (`<script>alert(1)</script>` ...) | rows 1 and 3 | the original lines, unchanged |
