# Choose from JSON API output

Scripts: [examples/pick-from-api.sh](../../examples/pick-from-api.sh) (`jq`),
[examples/pick-from-api.ps1](../../examples/pick-from-api.ps1) (`Invoke-RestMethod`), sample
response [examples/data/issues.json](../../examples/data/issues.json).

API responses are nested; the CLI shows one column per top-level key (at most 32) and
displays nested values as compact JSON. Flatten first, and keep a key you need afterwards
(here `url`) even if it is not interesting to look at:

```bash
curl -fsS 'https://api.github.com/repos/OWNER/REPO/issues?per_page=100' |
  jq -c '[.[] | select(has("pull_request") | not) | {
           "#": .number, Title: .title, Author: .user.login,
           Labels: ([.labels[].name] | join(", ")), Updated: .updated_at[:10], url: .html_url
         }]' |
  nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues' |
  jq -r '.[].url'
```

What comes back is the array of the chosen records **exactly as they went in**: key order,
numbers (`42`, not `42.0`), Unicode, `null`. So the second `jq` can rely on the shape you
built. In this one-line form a Cancel simply produces no output; the example script checks
the status and exits 2 or 124 instead.

Rows that are not objects work too: `jq -c '[.[].name]'` gives a one-column table of
strings, and `--output-format lines` returns the chosen strings one per line.

## PowerShell

```powershell
$response = Invoke-RestMethod -Uri $Uri -Headers @{ Accept = 'application/vnd.github+json' }
$rows = @($response | Where-Object { -not $_.PSObject.Properties['pull_request'] } | ForEach-Object {
    [pscustomobject]@{
        '#'     = $_.number
        Title   = $_.title
        Author  = $_.user.login
        Labels  = ($_.labels.name -join ', ')
        Updated = if ($_.updated_at -is [datetime]) { $_.updated_at.ToString('yyyy-MM-dd') } else { "$($_.updated_at)".Substring(0, 10) }
        url     = $_.html_url
    }
})
$json = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
(ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { $_.url }
```

Two PowerShell details the script handles: PowerShell 7 converts ISO date strings to
`[datetime]` while Windows PowerShell keeps the text, and a single object serialises as a
JSON object rather than an array (the CLI accepts both: a single value is one row).
