# Input formats (Windows)

`select` and `view` read all of stdin, then parse it as `--input-format lines` (default),
`csv`, `tsv`, `json` or `ndjson`. PowerShell sends each object of the pipeline to a native
program as one line of text, so strings become `lines`, and objects are best sent as
`json`. This page shows each format with PowerShell examples; the complete rules are in the
[input formats reference](../reference/input-formats.md).

Common rules:

- stdin must be piped (not the console), **UTF-8**, at most **8 MiB**
  ([set up UTF-8](index.md#set-up-utf-8-once)).
- At most **2,000 rows** and **32 columns**.
- Any problem exits 1 with `nativehtmlkit: error[input.invalid]: ...` before a window opens.
- Every cell is shown as text: markup in the data is never interpreted.

The examples were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and
PowerShell 7 by `scripts/test-docs.ps1` ([how](index.md#how-the-examples-are-verified));
"Submit prints" blocks are the exact output of the released code for the bytes PowerShell
sent and the rows named.

## `lines` (default)

One row per line, one column named `Value`. PowerShell ends each line with CR LF on
Windows; the `\r` is removed. Empty strings are rows too.

<!-- test: exit=124 calls="124@4x1" -->
```powershell
'first', '', 'third', 'fourth' | nativehtmlkit select --input-format lines --multi
```

Submit prints, after ticking rows 1 and 4:

<!-- submit: pick=1,4 -->
```text
first
fourth
```

Lines are kept exactly, including leading spaces and markup:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
'  indented', '<b>not bold</b>', 'Příliš žluťoučký kůň 😀' | nativehtmlkit select --multi
```

<!-- submit: pick=1,2,3 -->
```text
  indented
<b>not bold</b>
Příliš žluťoučký kůň 😀
```

Without the UTF-8 setup Windows PowerShell 5.1 sends `us-ascii`: every non-ASCII character
silently becomes `?` before the CLI sees it. The same happens in any edition with an ASCII
`$OutputEncoding`:

<!-- test: exit=124 calls="124@1x1" -->
```powershell
$OutputEncoding = [Text.Encoding]::ASCII
'café' | nativehtmlkit select
```

<!-- submit: pick=1 -->
```text
caf?
```

No input at all is refused by `select` (an empty `view` is fine):

<!-- test: exit=1 calls="1@none" -->
```powershell
@() | nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: no selectable input rows; stdin was empty or contained no records
```

## `csv`

Comma-separated values with a header row, RFC 4180 quoting: inside `"..."` commas and line
breaks are data and `""` is one `"`. Blank lines are skipped; a byte-order mark before the
header is ignored. `Get-Content` sends a file line by line, which keeps quoted line breaks
intact:

<!-- test: exit=124 calls="124@2x3" -->
```powershell
@'
name,comment,n
plain,"has, comma",1

quote,"say ""hi""",2
'@ | Set-Content -Path notes.csv
Get-Content notes.csv | nativehtmlkit select --input-format csv --multi
```

Two rows (the blank line is skipped). Submit prints, after ticking both (CSV output is
re-quoted where needed):

<!-- submit: pick=1,2 -->
```text
name,comment,n
plain,"has, comma",1
quote,"say ""hi""",2
```

A quoted field may also contain a line break. PowerShell sends lines with CR LF on Windows,
so such a field keeps the CR LF as data, and the `csv` output writes it back unchanged.

`ConvertTo-Csv` produces input the CLI reads directly. Windows PowerShell 5.1 needs
`-NoTypeInformation` (otherwise the first line is `#TYPE ...`) and quotes every field,
which is fine:

<!-- test: exit=124 calls="124@2x2" -->
```powershell
[pscustomobject]@{ Host = 'web-01'; Status = 'healthy' }, [pscustomobject]@{ Host = 'web-02'; Status = 'degraded' } |
    ConvertTo-Csv -NoTypeInformation | nativehtmlkit select --input-format csv --output-format json
```

<!-- submit: pick=2 -->
```json
[{"Host":"web-02","Status":"degraded"}]
```

Every record must have as many fields as the header, and header names must be unique:

<!-- test: exit=1 calls="1@none" -->
```powershell
'host,role', 'web-01,frontend,extra' | nativehtmlkit select --input-format csv
```

<!-- stderr -->
```text
found record with 3 fields, but the previous record has 2 fields
```

<!-- test: exit=1 calls="1@none" -->
```powershell
'name,name', 'a,b' | nativehtmlkit select --input-format csv
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: duplicate CSV/TSV column names cannot be represented as JSON objects
```

Only `,` is a delimiter. Convert semicolon files (a common Excel export in many locales)
with `Import-Csv -Delimiter ';'`:

<!-- test: exit=124 calls="124@2x2" -->
```powershell
'host;status', 'web-01;healthy', 'web-02;degraded' | Set-Content -Path semicolons.csv
Import-Csv -Path semicolons.csv -Delimiter ';' | ConvertTo-Csv -NoTypeInformation |
    nativehtmlkit select --input-format csv
```

A header without data rows: `select` refuses it, `view` shows an empty table:

<!-- test: exit=124 calls="124@0x2" -->
```powershell
'host,status' | nativehtmlkit view --input-format csv
```

## `tsv`

Tab-separated values, otherwise like `csv` (same header and quoting rules). In PowerShell
`` `t `` is a tab:

<!-- test: exit=124 calls="124@2x3" -->
```powershell
"branch`tupdated`tsubject", "main`t2 hours ago`tMerge fix/typo", "feature/login`t3 days ago`tAdd login form" |
    nativehtmlkit select --input-format tsv
```

<!-- submit: pick=2 -->
```text
branch	updated	subject
feature/login	3 days ago	Add login form
```

**Pitfall:** TSV uses CSV quoting, so a field that *starts* with `"` is read as a quoted
field: the quotes are removed, and a quote that is never closed swallows the following tabs
and lines. Two data lines, but one row:

<!-- test: exit=124 calls="124@1x2" -->
```powershell
"branch`tsubject", "main`t`"unclosed quote", "feature`tsecond row" | nativehtmlkit select --input-format tsv
```

For free text such as commit subjects send JSON instead (below).

## `--no-headers`

For `csv` and `tsv`: the first record is data; columns are named `column_1` ...
`column_N`. (Accepted, without effect, for the other formats.)

<!-- test: exit=124 calls="124@3x2" -->
```powershell
"web-01`thealthy", "web-02`tdegraded", "db-01`thealthy" |
    nativehtmlkit select --input-format tsv --no-headers --multi --output-format json
```

<!-- submit: pick=1,2 -->
```json
[{"column_1":"web-01","column_2":"healthy"},{"column_1":"web-02","column_2":"degraded"}]
```

## `json`: PowerShell objects

The natural way to send objects. Exactly one JSON document: an array gives one row per
element, any other value is one row. Columns are the union of the objects' properties;
cells show strings as they are, `$null` as empty, numbers and booleans as JSON text, nested
values as compact JSON.

<!-- test: exit=124 calls="124@2x4" -->
```powershell
$rows = [pscustomobject]@{ id = 1; name = 'web'; tags = @('a', 'b') },
        [pscustomobject]@{ id = 2; name = 'db'; owner = $null }
ConvertTo-Json -InputObject $rows -Compress | nativehtmlkit select --input-format json
```

Columns `id`, `name`, `tags`, `owner`. The result is the original element, unchanged:

<!-- submit: pick=2 -->
```json
[{"id":2,"name":"db","owner":null}]
```

Rules that keep this working:

- **Choose the properties first** with `Select-Object`: raw objects have many properties
  (the CLI accepts 32 columns) and nested objects would be shown as JSON text.
- **Turn enums and dates into strings** yourself: `ConvertTo-Json` writes enums as numbers,
  and Windows PowerShell 5.1 writes dates as `"\/Date(...)\/"`.
- **One object** is serialised as an object, not an array; the CLI accepts both (one row).
- **Zero objects** produce no input at all, which `select` refuses: check the count first.

<!-- test: exit=124 calls="124@*x3" -->
```powershell
Get-ChildItem -File | Select-Object Name,
    @{ n = 'Size (KiB)'; e = { [math]::Ceiling($_.Length / 1KB) } },
    @{ n = 'Modified'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } } |
    ConvertTo-Json -Compress | nativehtmlkit select --multi --input-format json
```

Too many properties:

<!-- test: exit=1 calls="1@none" -->
```powershell
$wide = [ordered]@{}; 1..33 | ForEach-Object { $wide["p$_"] = $_ }
[pscustomobject] $wide | ConvertTo-Json -Compress | nativehtmlkit select --input-format json
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: 33 columns exceeds the 32-column limit
```

An array of strings is a one-column table:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
ConvertTo-Json -InputObject @('red', 'green', 'blue') -Compress |
    nativehtmlkit select --input-format json --output-format lines
```

<!-- submit: pick=2 -->
```text
green
```

A file that already holds JSON: send it as one string with `Get-Content -Raw`:

<!-- test: exit=124 calls="124@4x7" -->
```powershell
Get-Content -Raw data\issues.json | nativehtmlkit select --multi --input-format json
```

Only one document is accepted, and **no byte-order mark**. Windows PowerShell 5.1 writes one
when `$OutputEncoding` is `[Text.Encoding]::UTF8` (PowerShell 7 does not):

<!-- test: exit=1 calls="1@none" requires=ps51 -->
```powershell
$OutputEncoding = [Text.Encoding]::UTF8
'[1]' | nativehtmlkit select --input-format json
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: invalid JSON input: expected value at line 1 column 1
```

<!-- test: exit=124 calls="124@1x1" -->
```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
'[1]' | nativehtmlkit select --input-format json
```

## `ndjson`

One JSON value per line. Blank lines are skipped; a line holding an array is one row.
Convert objects one at a time with `-Compress`:

<!-- test: exit=124 calls="124@3x2" -->
```powershell
1..3 | ForEach-Object { [pscustomobject]@{ n = $_; square = $_ * $_ } | ConvertTo-Json -Compress } |
    nativehtmlkit select --input-format ndjson --multi
```

<!-- submit: pick=2,3 -->
```text
{"n":2,"square":4}
{"n":3,"square":9}
```

JSON Lines files and tools that print one JSON object per line feed it directly:

<!-- test: exit=124 calls="124@3x7" -->
```powershell
Get-Content data\app.ndjson | nativehtmlkit select --input-format ndjson
```

<!-- test: exit=124 calls="124@2x14" -->
```powershell
docker ps --all --format '{{json .}}' | nativehtmlkit select --input-format ndjson
```

Pretty-printed JSON is not NDJSON (`ConvertTo-Json` without `-Compress` spans lines):

<!-- test: exit=1 calls="1@none" -->
```powershell
[pscustomobject]@{ a = 1 } | ConvertTo-Json | nativehtmlkit select --input-format ndjson
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: invalid NDJSON line 1: EOF while parsing an object at line 1 column 1
```

## Limits

<!-- test: exit=124 calls="124@2000x1" -->
```powershell
1..2000 | nativehtmlkit select --multi
```

<!-- test: exit=1 calls="1@none" -->
```powershell
1..2001 | nativehtmlkit select
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: 2001 rows exceeds the 2000-row initial GUI limit
```

Also refused: more than 8 MiB, and a page over 1 MiB or 65,536 elements (the message says
how many rows would fit). See the [limits reference](../reference/limits.md).

## Which format to use

| Your data | Format |
|---|---|
| strings, names, paths | `lines` |
| PowerShell objects | `json` via `Select-Object ... \| ConvertTo-Json` |
| a CSV file, `ConvertTo-Csv -NoTypeInformation` output | `csv` |
| `docker ps --format '{{json .}}'`, JSON Lines log files | `ndjson` |
| text that may contain tabs, quotes or newlines | `json`/`ndjson` (not `tsv`) |
