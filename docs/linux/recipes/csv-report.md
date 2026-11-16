# Review and export CSV reports (Linux)

Look at a CSV file in a table, or tick rows and export them as a new CSV file. Script:
[examples/csv-report.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/csv-report.sh),
sample [examples/data/servers.csv](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/servers.csv).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Look at it

<!-- test: exit=124 calls="124@7x7" -->
```bash
./csv-report.sh data/servers.csv
```

The first record is the header; quoted fields (`"disk 91% full, cleanup scheduled"`,
`"canary for ""v2"" API"`) are shown unquoted. Without the script:

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit view --input-format csv --title 'Servers' < data/servers.csv
```

## Export the rows you tick

<!-- test: exit=124 calls="124@7x7" -->
```bash
./csv-report.sh data/servers.csv degraded.csv
status=$?
ls degraded.csv* 2>/dev/null
exit "$status"
```

On Cancel or a timeout no output file, and no temporary file, is left behind (the `ls`
found nothing):

<!-- stdout -->
```text
```

After ticking `web-02` and Submit, `degraded.csv` exists:

<!-- replay: call=1 exit=0 expect=0 -->
```text
host,role,region,cpu_cores,memory_gib,status,notes
web-02,frontend,eu-west,4,8,degraded,"disk 91% full, cleanup scheduled"
```

<!-- stdout -->
```text
degraded.csv
```

<!-- stderr -->
```text
csv-report: wrote 1 row(s) to degraded.csv
```

The script writes through a temporary file and moves it into place only on exit 0:

<!-- not-tested: excerpt of examples/csv-report.sh, which is run above -->
```bash
tmp=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
status=0
nativehtmlkit select --multi --input-format csv --output-format csv \
  --title "Rows to export" <"$report" >"$tmp" || status=$?
case $status in
  0)   mv -- "$tmp" "$output"
```

## Other shapes of the same rows

| `--output-format` | You get |
|---|---|
| `csv` | header and chosen rows, re-quoted where needed |
| `tsv` | the same, tab-separated |
| `json` | `[{"host":"web-02","role":"frontend",...}]`, all values strings |
| `lines` | each row's fields joined by a tab, no header |

Only the host names of the chosen rows:

<!-- test: exit=0 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --output-format json < data/servers.csv | jq -r '.[].host'
```

A file without a header row needs `--no-headers` (columns `column_1`, ...):

<!-- test: exit=124 calls="124@7x7" -->
```bash
tail -n +2 data/servers.csv | nativehtmlkit view --input-format csv --no-headers
```

Semicolon-separated files are not supported; convert them first
([input formats](../input-formats.md#csv)).

Windows: [Review and export CSV reports (Windows)](../../windows/recipes/csv-report.md).
