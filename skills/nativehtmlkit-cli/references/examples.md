# CLI examples

Verified scripts: https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/README.md

Pick with explicit status handling:

```bash
status=0
choice=$(printf 'small\nmedium\nlarge\n' | nativehtmlkit select --title 'Size' --timeout 60) || status=$?
case $status in
  0)   echo "size: $choice" ;;
  2)   echo "cancelled" >&2; exit 2 ;;
  124) echo "no answer within 60 s" >&2; exit 124 ;;
  *)   exit "$status" ;;
esac
```

CSV in, structured JSON out, one field per chosen row:

```bash
nativehtmlkit select --multi --input-format csv --output-format json < servers.csv | jq -r '.[].host'
```

The CLI in the middle of a pipeline:

```bash
ls -1 *.log | nativehtmlkit select --multi | xargs -r -d '\n' gzip --
status=("${PIPESTATUS[@]}")     # ls, nativehtmlkit, xargs: ${status[1]} is the CLI's
```

Form with escaped dynamic values, parsed result:

```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }
printf '<form id="nhk-form"><label>Version <input name="version" required value="%s"></label></form>\n' "$(esc "$version")" > f.html
result=$(nativehtmlkit form --html f.html) || exit
jq -r 'first(.entries[] | select(.name == "version") | .value)' <<<"$result"
```

PowerShell:

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$json = Get-Process | Select-Object Id, ProcessName | ConvertTo-Json |
    nativehtmlkit select --multi --input-format json --output-format json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
(ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object Id
```

Cancellation is not an error: handle exit status `2`. Errors are `1`, timeout `124`. Never
parse stderr as selected results.
