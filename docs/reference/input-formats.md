# Input formats

`select` and `view` read all of stdin, then parse it with `--input-format` (default `lines`).
Common rules for every format:

- stdin must not be a terminal; at most **8 MiB** (8,388,608 bytes) is read; it must be
  **UTF-8** (`error[input.invalid]: stdin must contain UTF-8; use ConvertTo-Json or UTF-8
  output: invalid utf-8 sequence ...`).
- At most **2,000 rows** and **32 columns**; the generated page must also fit the host's
  1 MiB / 65,536-node limits ([limits](limits.md)).
- Each row keeps its original **value** (a string for `lines`, an object of strings for
  `csv`/`tsv`, the JSON value itself for `json`/`ndjson`) and a list of display **cells**.
  The table shows the cells, escaped as text; the output formats write values or cells
  ([output formats](output-formats.md)).
- Every error exits 1 with `nativehtmlkit: error[input.invalid]: <message>` before a window
  opens. Messages quote positions, never data.

## `lines` (default)

| Rule | Detail |
|---|---|
| Row boundary | `\n`; a `\r` before it is removed (`\r\n` files work) |
| Last line | a final line without `\n` is a row; a final `\n` does not create an empty row |
| Empty lines | are rows (an empty or whitespace-only line is a selectable row) |
| Columns | one, named `Value` |
| Value | the line text, unchanged (no trimming) |
| Byte-order mark | not removed: it becomes part of the first line |

`printf 'a\r\n\nb\nlast'` gives 4 rows: `a`, (empty), `b`, `last`.

## `csv` and `tsv`

RFC 4180-style parsing with `,` (`csv`) or a tab (`tsv`) as delimiter:

| Rule | Detail |
|---|---|
| Header | the first record names the columns, unless `--no-headers` (then `column_1` ... `column_N`, N from the first record) |
| Quoting | `"` quotes a field; inside quotes the delimiter and line breaks are data and `""` is one `"`. **This also applies to TSV**: a field that *starts* with `"` is parsed as quoted, so its quotes are removed (`"quoted" start` becomes `quoted start`), and a quote that is never closed swallows the following delimiters and lines (two data lines can become one row; `"x<TAB>y` with too few fields is an error). A `"` inside an unquoted field is data (`say "hi"` is fine). |
| Record boundary | `\n` or `\r\n` outside quotes |
| Blank lines | skipped |
| Field count | every record must have as many fields as the first one: `malformed CSV/TSV record: CSV error: record 1 (line: 2, byte: 4): found record with 3 fields, but the previous record has 2 fields` |
| Header names | must be unique (`duplicate CSV/TSV column names cannot be represented as JSON objects`); an empty name is allowed |
| Empty input | `expected at least one header column` (also for `view`) |
| Header only | zero rows: `select` refuses it (*no selectable input rows*), `view` shows an empty table |
| Byte-order mark | a UTF-8 BOM before the header is ignored |
| Other delimiters | not supported: `a;b` is one column named `a;b` |
| Value / cells | value: object `{header: field}` of strings; cells: the fields |
| Limits | more than 2,000 records: `too many records`; more than 32 columns: `too many columns` |

## `json`

| Rule | Detail |
|---|---|
| Document | exactly one JSON document; trailing content is an error (`invalid JSON input: trailing characters at line 1 column 5`) |
| Array | each element is a row |
| Any other value | (object, string, number, ...) is a single row |
| Empty or whitespace-only stdin | zero rows (`select` refuses it, `view` shows an empty viewer); `[]` is the same |
| Byte-order mark | **not accepted**: `invalid JSON input: expected value at line 1 column 1` |
| Columns, all rows objects | the union of keys, in order of first appearance across rows; a row without a key shows an empty cell |
| Columns, otherwise | one column `Value` (scalars, arrays, or arrays mixing objects and other values) |
| Cells | strings as-is; `null` as an empty cell; numbers and booleans as JSON text; arrays and objects as compact JSON |
| Value | the element exactly as given: key order and number text (big integers, `2.50`) are kept |
| Limits | more than 2,000 rows: `2001 rows exceeds the 2000-row initial GUI limit`; more than 32 distinct keys: `33 columns exceeds the 32-column limit` |

Note: in an array that mixes objects and non-objects, the single `Value` column shows each
object's `"Value"` member, which is usually absent, so those rows look empty. Use arrays of
one kind.

## `ndjson`

One JSON document per line (JSON Lines):

| Rule | Detail |
|---|---|
| Lines | each non-blank line is parsed as one JSON value; whitespace-only lines are skipped |
| Pretty-printed JSON | not supported: a value must fit on one line (`invalid NDJSON line 1: EOF while parsing an object at line 1 column 1`) |
| Errors | name the 1-based physical line: `invalid NDJSON line 2: ...` |
| A line holding an array | is one row (its value is the array) |
| Columns, cells, values | as for `json` |
| Limits | more than 2,000 rows: `too many NDJSON rows`; more than 32 keys as for `json` |

## Choosing a format

| Source | Use |
|---|---|
| plain names, paths, one item per line | `lines` |
| spreadsheet exports, `--format csv` of a tool | `csv` |
| `docker ps --format '{{json .}}'`, `kubectl ... -o json` items via `jq -c '.items[]'`, log files in JSON Lines | `ndjson` |
| `jq` output, `ConvertTo-Json`, REST responses | `json` |
| fields that may contain tabs or quotes | `json`/`ndjson` (build with `jq -R`/`ConvertTo-Json`), not `tsv` |

PowerShell: send objects as JSON (`Select-Object ... | ConvertTo-Json | nativehtmlkit select
--input-format json`), choosing the properties first: a raw object easily has more than 32
properties. In Windows PowerShell 5.1 set `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)`
first; `[Text.Encoding]::UTF8` would prepend a BOM, which the `json` format rejects
([Windows input formats](../windows/input-formats.md)).
