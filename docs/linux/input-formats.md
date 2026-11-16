# Input formats (Linux)

`select` and `view` read all of stdin, then parse it as `--input-format lines` (default),
`csv`, `tsv`, `json` or `ndjson`. This page shows each format with bash examples; the
complete rules are in the [input formats reference](../reference/input-formats.md).

Common rules:

- stdin must be piped or redirected (not a terminal), **UTF-8**, at most **8 MiB**.
- At most **2,000 rows** and **32 columns**.
- Any problem exits 1 with `nativehtmlkit: error[input.invalid]: ...` before a window opens.
  Messages give positions, never your data.
- Every cell is shown as text: markup in the data is never interpreted.

The examples were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](index.md#how-the-examples-are-verified)); "Submit prints" blocks are the exact output
of the released code for the rows named.

## `lines` (default)

One row per line, one column named `Value`. A `\r` before the `\n` is removed, so Windows
text files work; a last line without `\n` is still a row; empty lines are rows too.

<!-- test: exit=124 calls="124@4x1" -->
```bash
printf 'first\r\n\nthird\nlast-without-newline' | nativehtmlkit select --input-format lines --multi
```

Four rows: `first`, an empty row, `third`, `last-without-newline`. Submit prints, after
ticking rows 1 and 4:

<!-- submit: pick=1,4 -->
```text
first
last-without-newline
```

Lines are kept exactly, including leading spaces and markup:

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf '  indented\n<b>not bold</b>\nPříliš žluťoučký kůň 😀\n' | nativehtmlkit select --multi
```

<!-- submit: pick=1,2,3 -->
```text
  indented
<b>not bold</b>
Příliš žluťoučký kůň 😀
```

Empty stdin has no rows: `select` refuses it, `view` shows an empty viewer:

<!-- test: exit=1 calls="1@none" -->
```bash
printf '' | nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: no selectable input rows; stdin was empty or contained no records
```

Text that is not UTF-8 is refused; convert it first:

<!-- test: exit=1 calls="1@none" -->
```bash
printf 'caf\xe9\n' | nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: stdin must contain UTF-8; use ConvertTo-Json or UTF-8 output
```

<!-- test: exit=124 calls="124@1x1" -->
```bash
printf 'caf\xe9\n' | iconv -f latin1 -t utf-8 | nativehtmlkit select
```

## `csv`

Comma-separated values with a header row, RFC 4180 quoting: inside `"..."` commas and line
breaks are data and `""` is one `"`. Blank lines are skipped. A UTF-8 byte-order mark
before the header is ignored.

<!-- test: exit=124 calls="124@3x3" -->
```bash
cat > notes.csv <<'CSV'
name,comment,n
plain,"has, comma",1

quote,"say ""hi""",2
multi,"line one
line two",3
CSV
nativehtmlkit select --input-format csv --multi < notes.csv
```

Three rows (the blank line is skipped), columns `name`, `comment`, `n`. Submit prints,
after ticking all three (CSV output is re-quoted where needed):

<!-- submit: pick=1,2,3 -->
```text
name,comment,n
plain,"has, comma",1
quote,"say ""hi""",2
multi,"line one
line two",3
```

Every record must have as many fields as the header, and header names must be unique:

<!-- test: exit=1 calls="1@none" -->
```bash
printf 'host,role\nweb-01,frontend,extra\n' | nativehtmlkit select --input-format csv
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: malformed CSV/TSV record: CSV error: record 1 (line: 2, byte: 10): found record with 3 fields, but the previous record has 2 fields
```

<!-- test: exit=1 calls="1@none" -->
```bash
printf 'name,name\na,b\n' | nativehtmlkit select --input-format csv
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: duplicate CSV/TSV column names cannot be represented as JSON objects
```

Only `,` is a delimiter: `a;b` is one column named `a;b`. Convert semicolon files first,
for example with Python's `csv` module:

<!-- test: exit=124 calls="124@2x2" -->
```bash
printf 'host;status\nweb-01;healthy\nweb-02;degraded\n' |
  python3 -c 'import csv,sys; csv.writer(sys.stdout, lineterminator="\n").writerows(csv.reader(sys.stdin, delimiter=";"))' |
  nativehtmlkit select --input-format csv
```

A header without data rows: `select` refuses it, `view` shows an empty table:

<!-- test: exit=124 calls="124@0x2" -->
```bash
printf 'host,status\n' | nativehtmlkit view --input-format csv
```

## `tsv`

Tab-separated values, otherwise like `csv` (same header and quoting rules):

<!-- test: exit=124 calls="124@2x3" -->
```bash
printf 'branch\tupdated\tsubject\nmain\t2 hours ago\tMerge fix/typo\nfeature/login\t3 days ago\tAdd login form\n' |
  nativehtmlkit select --input-format tsv
```

<!-- submit: pick=2 -->
```text
branch	updated	subject
feature/login	3 days ago	Add login form
```

**Pitfall:** TSV uses CSV quoting, so a field that *starts* with `"` is read as a quoted
field. A `"` inside a field is data, but at the start the quotes are removed, and a quote that
is never closed swallows the following tabs and lines:

<!-- test: exit=124 calls="124@1x2" -->
```bash
printf 'branch\tsubject\nmain\t"quoted" start\n' | nativehtmlkit select --input-format tsv
```

<!-- submit: pick=1 -->
```text
branch	subject
main	quoted start
```

<!-- test: exit=124 calls="124@1x2" -->
```bash
printf 'branch\tsubject\nmain\t"unclosed quote\nfeature\tsecond row\n' | nativehtmlkit select --input-format tsv
```

Two data lines, but only **one** row: the second line became part of the first row's
subject. For free text such as commit subjects build JSON with `jq` instead (see
[pick a Git branch](recipes/git-branch.md)), or replace the quotes first:

<!-- test: exit=124 calls="124@2x2" -->
```bash
printf 'branch\tsubject\nmain\t"unclosed quote\nfeature\tsecond row\n' | tr '"' "'" |
  nativehtmlkit select --input-format tsv
```

## `--no-headers`

For `csv` and `tsv`: the first record is data; columns are named `column_1` ...
`column_N`. (Accepted, without effect, for the other formats.)

<!-- test: exit=124 calls="124@3x2" -->
```bash
printf 'web-01\thealthy\nweb-02\tdegraded\ndb-01\thealthy\n' |
  nativehtmlkit select --input-format tsv --no-headers --multi --output-format json
```

<!-- submit: pick=1,2 -->
```json
[{"column_1":"web-01","column_2":"healthy"},{"column_1":"web-02","column_2":"degraded"}]
```

## `json`

Exactly one JSON document. An array gives one row per element; any other value is one
row. If every row is an object, the columns are the union of their keys in order of first
appearance; otherwise there is one column `Value`. Cells show strings as they are, `null`
as empty, numbers and booleans as JSON text, nested arrays and objects as compact JSON.

<!-- test: exit=124 calls="124@2x4" -->
```bash
echo '[{"id":1,"name":"web","tags":["a","b"]},{"id":2,"name":"db","owner":null}]' |
  nativehtmlkit select --input-format json
```

Columns `id`, `name`, `tags`, `owner`. The result is the original element, unchanged: key
order, nesting and number text are kept.

<!-- submit: pick=2 -->
```json
[{"id":2,"name":"db","owner":null}]
```

A single object is one row; an array of strings is a one-column table:

<!-- test: exit=124 calls="124@1x2" -->
```bash
echo '{"name":"api","replicas":3}' | nativehtmlkit select --input-format json
```

<!-- test: exit=124 calls="124@3x1" -->
```bash
jq -c '[.[].title]' data/issues.json | jq -c '.[:3]' | nativehtmlkit select --input-format json --output-format lines
```

<!-- submit: pick=2 -->
```text
Document the <form> limits
```

Big numbers and trailing zeros survive the round trip:

<!-- test: exit=124 calls="124@1x2" -->
```bash
echo '[{"id":12345678901234567890123,"price":2.50}]' | nativehtmlkit select --input-format json
```

<!-- submit: pick=1 -->
```json
[{"id":12345678901234567890123,"price":2.50}]
```

Only one document is accepted; a byte-order mark is refused:

<!-- test: exit=1 calls="1@none" -->
```bash
echo '[1] [2]' | nativehtmlkit select --input-format json
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: invalid JSON input: trailing characters at line 1 column 5
```

<!-- test: exit=1 calls="1@none" -->
```bash
printf '\xef\xbb\xbf[1]' | nativehtmlkit select --input-format json
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: invalid JSON input: expected value at line 1 column 1
```

`jq` output and REST responses are usually `json`. Pick the fields you want to see first:

<!-- test: exit=124 calls="124@4x4" -->
```bash
jq -c 'map({"#": .number, Title: .title, Author: .user.login, url: .html_url})' data/issues.json |
  nativehtmlkit select --multi --input-format json
```

## `ndjson`

One JSON value per line (JSON Lines). Blank lines are skipped; a line holding an array is
one row. Columns, cells and values follow the `json` rules.

<!-- test: exit=124 calls="124@3x7" -->
```bash
nativehtmlkit select --input-format ndjson --multi < data/app.ndjson
```

<!-- submit: pick=2,3 -->
```text
{"time":"2026-11-16T09:01:12Z","level":"warn","msg":"slow query","duration_ms":812}
{"time":"2026-11-16T09:02:40Z","level":"error","msg":"upstream timeout","retry":1,"upstream":{"host":"api-01"}}
```

Tools that print one JSON object per line feed it directly:

<!-- test: exit=124 calls="124@2x14" -->
```bash
docker ps --all --format '{{json .}}' | nativehtmlkit select --input-format ndjson
```

Pretty-printed JSON is not NDJSON; compact it with `jq -c`:

<!-- test: exit=1 calls="1@none" -->
```bash
printf '{\n  "a": 1\n}\n' | nativehtmlkit select --input-format ndjson
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: invalid NDJSON line 1: EOF while parsing an object at line 1 column 1
```

<!-- test: exit=124 calls="124@1x1" -->
```bash
printf '{\n  "a": 1\n}\n' | jq -c . | nativehtmlkit select --input-format ndjson
```

## Limits

<!-- test: exit=124 calls="124@2000x1" -->
```bash
seq 1 2000 | nativehtmlkit select --multi
```

<!-- test: exit=1 calls="1@none" -->
```bash
jq -nc '[range(33) | {key: "k\(.)", value: 1}] | from_entries' | nativehtmlkit select --input-format json
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: 33 columns exceeds the 32-column limit
```

Also refused: more than 8 MiB on stdin, and a page over 1 MiB or 65,536 elements (the
message says how many rows would fit). See the [limits reference](../reference/limits.md).

## Which format to use

| Your data | Format |
|---|---|
| names, paths, one item per line | `lines` |
| a spreadsheet export, `--format csv` of a tool | `csv` |
| `jq` output, a REST response | `json` |
| `docker ps --format '{{json .}}'`, `kubectl ... -o json \| jq -c '.items[]'`, JSON log files | `ndjson` |
| fields that may contain tabs, quotes or newlines | `json`/`ndjson` built with `jq` (not `tsv`) |
