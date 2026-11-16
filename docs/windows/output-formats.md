# Output formats (Windows)

After **Submit selection**, `select` writes the chosen rows to stdout in the format named by
`--output-format`: `same` (default), `lines`, `csv`, `tsv`, `json` or `ndjson`. `view` never
writes to stdout; `form` always writes one JSON line ([form](commands/form.md)). The complete
rules are in the [output formats reference](../reference/output-formats.md).

Common rules:

- Rows are written in **input order**, whatever order they were ticked in.
- The result is written in one piece after the window has closed, and only when
  `$LASTEXITCODE` is 0. On Cancel (2), timeout (124), error (1) or Ctrl+C (130) nothing is
  written, so a variable assigned from the CLI is `$null` then.
- UTF-8, `\n` line ends, a newline at the end. PowerShell receives several lines as an array
  of strings: `-join "`n"` makes one string before `ConvertFrom-Json`.

Every "Submit prints" block below is the exact output of the released code for the bytes
of the example above it and the rows named, checked by `scripts/test-docs.ps1`
([how](index.md#how-the-examples-are-verified)). The examples read the sample file
`data\servers.csv` from the repository's `examples` folder:

```text
host,role,region,cpu_cores,memory_gib,status,notes
web-01,frontend,eu-west,4,8,healthy,
web-02,frontend,eu-west,4,8,degraded,"disk 91% full, cleanup scheduled"
api-01,backend,eu-west,8,32,healthy,
api-02,backend,us-east,8,32,healthy,"canary for ""v2"" API"
db-01,database,eu-west,16,128,healthy,primary
db-02,database,us-east,16,128,maintenance,"replica, patching until 18:00"
cache-01,cache,eu-west,2,16,healthy,
```

## `same` (default)

The format of the input: `lines` in, `lines` out; `csv` in, `csv` out; and so on.

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format same
```

Submit prints, after ticking `api-02` and `web-02`:

<!-- submit: pick=4,2 -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
web-02,frontend,eu-west,4,8,degraded,"disk 91% full, cleanup scheduled"
api-02,backend,us-east,8,32,healthy,"canary for ""v2"" API"
```

## `lines`

One line per chosen row. A `lines` row is written as it was read; a row whose value is a
JSON string is written as that string; any other row is written as its cells joined by a
tab.

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format lines
```

<!-- submit: pick=1,5 -->
```text
web-01	frontend	eu-west	4	8	healthy	
db-01	database	eu-west	16	128	healthy	primary
```

Split a line into its cells with `-split "`t"`:

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$chosen = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format lines
if ($LASTEXITCODE -eq 0) { $chosen | ForEach-Object { 'checking ' + ($_ -split "`t")[0] } }
exit 0
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
web-01	frontend	eu-west	4	8	healthy	
db-01	database	eu-west	16	128	healthy	primary
```

<!-- stdout -->
```text
checking web-01
checking db-01
```

A `lines` result can never turn one row into two: if a chosen value contains a line break,
nothing is written and the command fails with exit 1. Use `json` or `ndjson` for such data:

<!-- test: exit=124 calls="124@2x2" -->
```powershell
'name,comment', 'plain,ok', 'multi,"line one', 'line two"' |
    nativehtmlkit select --input-format csv --output-format lines
```

Submit after picking `multi`:

<!-- submit: pick=2 error="selected value contains newline" -->
```text
nativehtmlkit: error[output.failed]: selected value contains newline: use --output-format json or ndjson
```

JSON strings come back as plain lines:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
ConvertTo-Json -InputObject @('red', 'green', 'blue') -Compress |
    nativehtmlkit select --multi --input-format json --output-format lines
```

<!-- submit: pick=1,3 -->
```text
red
blue
```

## `csv`

The header line, then each chosen row's cells, quoted where needed. `ConvertFrom-Csv` reads
it back as objects:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format csv
```

<!-- submit: pick=6 -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
db-02,database,us-east,16,128,maintenance,"replica, patching until 18:00"
```

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$csv = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format csv
if ($LASTEXITCODE -eq 0) { $csv | ConvertFrom-Csv | ForEach-Object { "$($_.host): $($_.notes)" } }
exit 0
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
db-02,database,us-east,16,128,maintenance,"replica, patching until 18:00"
```

<!-- stdout -->
```text
db-02: replica, patching until 18:00
```

From `json` or `ndjson` input the columns are the union of the keys; nested values are
written as compact JSON and `null` as an empty field:

<!-- test: exit=124 calls="124@3x7" -->
```powershell
Get-Content data\app.ndjson | nativehtmlkit select --multi --input-format ndjson --output-format csv
```

<!-- submit: pick=1,3 -->
```text
time,level,msg,port,duration_ms,retry,upstream
2026-11-16T09:00:01Z,info,server listening,8080,,,
2026-11-16T09:02:40Z,error,upstream timeout,,,1,"{""host"":""api-01""}"
```

Write a result file only after a successful Submit
([exit codes and scripting](exit-codes-and-scripting.md#write-files-only-after-success)).

## `tsv`

Like `csv` with a tab as delimiter (and the same quoting):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format tsv
```

<!-- submit: pick=2,3 -->
```text
host	role	region	cpu_cores	memory_gib	status	notes
web-02	frontend	eu-west	4	8	degraded	disk 91% full, cleanup scheduled
api-01	backend	eu-west	8	32	healthy	
```

## `json`

One JSON array with the chosen rows' **values** on one line. A `lines` row is a string, a
`csv`/`tsv` row an object of strings keyed by the header, a `json`/`ndjson` row the original
value unchanged. Read it back with `ConvertFrom-Json -InputObject` and enumerate it with
`foreach` or a pipeline. Do not wrap it in `@(...)` to count the rows: Windows PowerShell
5.1 returns a JSON array as **one** object, so `@(ConvertFrom-Json ...)` holds a single item
there; `ConvertFrom-Json ... | ForEach-Object { $_ }` gives the rows in both editions:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
```

<!-- submit: pick=3 -->
```json
[{"host":"api-01","role":"backend","region":"eu-west","cpu_cores":"8","memory_gib":"32","status":"healthy","notes":""}]
```

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$json = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
if ($LASTEXITCODE -ne 0) { exit 0 }
$rows = @(ConvertFrom-Json -InputObject ($json -join "`n") | ForEach-Object { $_ })
"$($rows.Count) row(s)"
foreach ($row in $rows) { "$($row.host) has $($row.memory_gib) GiB" }
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"host":"api-01","role":"backend","region":"eu-west","cpu_cores":"8","memory_gib":"32","status":"healthy","notes":""},{"host":"db-01","role":"database","region":"eu-west","cpu_cores":"16","memory_gib":"128","status":"healthy","notes":"primary"}]
```

<!-- stdout -->
```text
2 row(s)
api-01 has 32 GiB
db-01 has 128 GiB
```

`lines` input as JSON keeps every character of each line:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
'a.txt', 'b c.txt', "it's.txt" | nativehtmlkit select --multi --output-format json
```

<!-- submit: pick=2,3 -->
```json
["b c.txt","it's.txt"]
```

## `ndjson`

The same values as `json`, one per line; each line is a complete JSON document:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format ndjson
```

<!-- submit: pick=1,5 -->
```text
{"host":"web-01","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"healthy","notes":""}
{"host":"db-01","role":"database","region":"eu-west","cpu_cores":"16","memory_gib":"128","status":"healthy","notes":"primary"}
```

<!-- test: exit=0 calls="124@7x7" -->
```powershell
$lines = Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format ndjson
if ($LASTEXITCODE -eq 0) {
    $lines | ForEach-Object { $r = ConvertFrom-Json -InputObject $_; "would restart $($r.role) on $($r.host)" }
}
exit 0
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
{"host":"web-01","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"healthy","notes":""}
{"host":"db-01","role":"database","region":"eu-west","cpu_cores":"16","memory_gib":"128","status":"healthy","notes":"primary"}
```

<!-- stdout -->
```text
would restart frontend on web-01
would restart database on db-01
```

## Nothing chosen (`--allow-empty`)

With `--allow-empty`, Submit with nothing ticked is a valid answer (exit 0). `lines` and
`ndjson` print nothing, `json` prints `[]`, `csv`/`tsv` print the header line only:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --allow-empty --input-format csv --output-format csv
```

<!-- submit: pick= -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
```

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --allow-empty --input-format csv --output-format ndjson
```

<!-- submit: pick= -->
```text
```

## Which one to use

| You need | Output format |
|---|---|
| strings for `ForEach-Object` | `lines` (single-column input) |
| objects | `json` + `ConvertFrom-Json -InputObject ... \| ForEach-Object { $_ }` |
| a spreadsheet file, or objects via `ConvertFrom-Csv` | `csv` |
| exactly the records you put in | `same` |
| values that may contain line breaks | `json` or `ndjson` |
