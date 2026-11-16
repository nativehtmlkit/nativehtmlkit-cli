# Multi-select in pipelines and xargs (Linux)

`select --multi` writes one line per chosen row, in input order, and nothing at all on
Cancel or a timeout. That makes it a filter stage in a pipeline. Script:
[examples/grep-selected.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/grep-selected.sh)
(GNU `find` and `xargs`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Search only the files you tick

<!-- test: exit=124 calls="124@*x1" -->
```bash
./grep-selected.sh 'nativehtmlkit view' .
```

The window lists the files under `.` (at most 2,000). Suppose the user ticks two scripts:

<!-- replay: call=1 exit=0 expect=0 -->
```text
./csv-report.sh
./view-logs.sh
```

<!-- stdout -->
```text
./csv-report.sh:20:  exec nativehtmlkit view --input-format csv --title "${title:0:128}" <"$report"
./view-logs.sh:28:      nativehtmlkit view --input-format ndjson --title "Log: ${name:0:100}" ;;
./view-logs.sh:33:      nativehtmlkit view --title "Log: ${name:0:100}" ;;
```

After Cancel the script exits 2 and `grep` never runs:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stderr -->
```text
grep-selected: cancelled
```

## The rules that keep such pipelines safe

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'first\n' > one.log; printf 'second\n' > two.log
ls *.log | nativehtmlkit select --multi --title 'Compress' | xargs -r -d '\n' gzip --
ls *.gz 2>/dev/null | wc -l
```

<!-- stdout -->
```text
0
```

- `xargs -r`: run nothing when nothing was chosen (nothing was compressed above).
- `xargs -d '\n'` (GNU): split on newlines only, so spaces and quotes in names survive.
  Names containing newlines cannot be represented in `lines`; use JSON and NUL separators
  (`jq -j '.[].Path + "\u0000"' | xargs -0 ...`, see [delete files](delete-files.md)).
- `head -n 2000` before the CLI: more than 2,000 rows is an error, not a truncation.
- `--` before the arguments, so a name that starts with `-` is not an option.
- The CLI's own status is in `PIPESTATUS`, not `$?`:

<!-- test: exit=124 calls="124@*x1" -->
```bash
find . -type f -name '*.sh' | sort | head -n 2000 |
  nativehtmlkit select --multi --title 'Lint' |
  xargs -r -d '\n' bash -n --
status=("${PIPESTATUS[@]}")      # find, sort, head, nativehtmlkit, xargs
[[ ${status[3]} -eq 0 ]] || exit "${status[3]}"
```

## Rows with several fields

Choose an output format that keeps the fields apart. CSV in, one column of the chosen rows
out, one `ssh` per host:

<!-- test: exit=0 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --output-format json < data/servers.csv | jq -r '.[].host' |
  xargs -r -d '\n' -I{} ssh -o BatchMode=yes {} uptime
```

`ndjson` gives one JSON object per line, handy for `while read` loops:

<!-- test: exit=0 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --output-format ndjson < data/servers.csv |
  while IFS= read -r row; do
    echo "would restart $(jq -r .role <<<"$row") on $(jq -r .host <<<"$row")"
  done
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
{"host":"api-01","role":"backend","region":"eu-west","cpu_cores":"8","memory_gib":"32","status":"healthy","notes":""}
```

<!-- stdout -->
```text
would restart backend on api-01
```

Windows: [Multi-select in pipelines (Windows)](../../windows/recipes/pipelines.md).
