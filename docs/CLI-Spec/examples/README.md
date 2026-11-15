# Examples — proposed commands, not currently implemented

The examples describe the planned `nhk` executable. They are **not** working commands until their respective milestone is delivered.

## Linux (Wayland desktop)

```bash
# P1: simple selectable lines
printf 'alpha\nbeta\ngamma\n' | nhk select --multi

# P1: use selected text in another command; pipefail preserves nhk cancellation
set -o pipefail
printf 'alpha\nbeta\ngamma\n' | nhk select --multi | sort

# P2: inspect command output; no pipeline output from viewer
journalctl -n 100 --no-pager | nhk view --title 'Latest logs'

# P2: choose actual structured records rather than attempting to parse whitespace output
# Requires docker. Format produces one JSON object per line.
docker ps --format '{{json .}}' | nhk select --input ndjson --multi --output ndjson

# P2: select CSV rows; quotes and header preserved as CSV values
cat contacts.csv | nhk select --input csv --multi --output csv

# P3: ask for a single line of text
project=$(nhk input --label 'Project name') || exit $?
printf 'Selected project: %s\n' "$project"

# P3: gate a script on explicit human approval
nhk confirm --message 'Continue?' || exit $?
printf 'Approved\n'

# P3: typed JSON form request; no JS
nhk form --spec examples/request-form.json > form-result.json
```

Do not use destructive downstream commands in introductory examples. If a selected value is fed to `xargs`, command execution is by the user's shell, not an implicit `nhk` feature; quote and validate input.

## Windows PowerShell 7.x

```powershell
# P1: from a PowerShell string array
@('alpha','beta','gamma') | nhk select --multi

# P2: preserve structured process fields through JSON text
$items = @(Get-Process | Select-Object -First 12 Id, ProcessName, CPU)
$json = ConvertTo-Json -InputObject $items -Depth 4 -Compress
$result = $json | nhk select --input json --multi --output json
$code = $LASTEXITCODE
if ($code -eq 10) { 'Selection cancelled'; return }
if ($code -ne 0) { throw "nhk failed: $code" }
$result | ConvertFrom-Json

# P2: preview a file (prefer UTF-8)
Get-Content -Raw -Encoding utf8 .\notes.txt | nhk view --title 'Notes'

# P3: simple form
nhk form --spec .\request-form.json | ConvertFrom-Json
```

## Windows PowerShell 5.1 caveat

It can execute native `nhk.exe` without a Python or PowerShell SDK, but its default encodings and handling of external executable stdin/stdout differ. PowerShell 7.4+ improved native byte pipe preservation, while Windows PowerShell 5.1 remains text-encoding dependent. Initial testing must explicitly validate UTF-8 Czech characters and emoji and may require `$OutputEncoding = New-Object System.Text.UTF8Encoding($false)` in that shell. Do not claim full Unicode parity until the exact staging and output methods have passed clean-system tests.

## Input/IDL fixtures

- `request-select-lines.json` — normalized selection request.
- `request-select-json.json` — structured selection request (PowerShell-style columns).
- `request-form.json` — declarative P3 form specification.
- `result-envelope.json` — selected rows in optional `result-json` mode.
- `receipt-submitted.json`, `receipt-cancelled.json` — internal staged completion artifacts with **dummy test nonces and hashes**, not credentials.
