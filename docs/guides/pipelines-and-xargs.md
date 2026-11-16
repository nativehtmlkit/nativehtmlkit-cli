# Multi-select into xargs and pipelines

`select --multi` writes one line per chosen row, in input order, and nothing at all on Cancel
or timeout. That makes it a filter stage:

```bash
# compress the logs you tick
ls -1 *.log | nativehtmlkit select --multi --title 'Compress' | xargs -r -d '\n' gzip --

# search only the files you tick: examples/grep-selected.sh
find "$dir" -type f -not -path '*/.git/*' -size -2M | sort | head -n 2000 |
  nativehtmlkit select --multi --title "Search for: ${pattern:0:100}" |
  xargs -r -d '\n' grep -n -H -e "$pattern" --
status=("${PIPESTATUS[@]}")      # find, sort, head, nativehtmlkit, xargs
```

Rules that keep such pipelines safe:

- `xargs -r` (`--no-run-if-empty`): run nothing when nothing was chosen.
- `xargs -d '\n'` (GNU): split on newlines only, so spaces and quotes in names survive.
  Names containing newlines cannot be represented in `lines`; use JSON and NUL separators
  (`jq -j '.[].path + "\u0000"' | xargs -0 ...`, see [deleting files](deleting-files-safely.md)).
- `head -n 2000` before the CLI: more than 2,000 rows is an error, not a truncation.
- `--` before the arguments, so a name starting with `-` is not an option.
- The CLI's own status is `PIPESTATUS[i]`, not `$?` ([handling exit statuses](handling-exit-status.md#bash-the-cli-in-the-middle-of-a-pipeline)).

## Values with more than one field

For rows with several fields, choose a format that keeps them apart:

```bash
# CSV in, the "host" column of each chosen row out
nativehtmlkit select --multi --input-format csv --output-format json < servers.csv | jq -r '.[].host' |
  xargs -r -d '\n' -I{} ssh -o BatchMode=yes {} uptime
```

`--output-format ndjson` gives one JSON object per line, handy for `while read -r` loops:

```bash
nativehtmlkit select --multi --input-format csv --output-format ndjson < servers.csv |
  while IFS= read -r row; do
    host=$(jq -r .host <<<"$row"); role=$(jq -r .role <<<"$row")
    echo "would restart $role on $host"
  done
```

## PowerShell

The pipeline passes strings; filter on `$LASTEXITCODE` before acting:

```powershell
$chosen = Get-ChildItem *.log | ForEach-Object Name | nativehtmlkit select --multi --title 'Compress'
if ($LASTEXITCODE -eq 0) { $chosen | ForEach-Object { Compress-Archive -LiteralPath $_ -DestinationPath "$_.zip" } }
```
