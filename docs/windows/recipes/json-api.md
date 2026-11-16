# Choose from JSON API output (Windows)

Reshape a REST response, let the user pick records, and use fields of the chosen records.
Script: [examples/pick-from-api.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-from-api.ps1) with `Invoke-RestMethod`, or
the sample response [examples/data/issues.json](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/issues.json) (GitHub's issue list
format).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Run it

With the saved response, or live with
`.\pick-from-api.ps1 -Uri 'https://api.github.com/repos/OWNER/REPO/issues?per_page=100'`:

<!-- test: exit=124 calls="124@3x6" -->
```powershell
.\pick-from-api.ps1 -Path data\issues.json
```

The response has four entries; one is a pull request, so three issues are offered. The
script prints the URLs of the chosen issues:

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"#":42,"Title":"Window opens off-screen on a second monitor","Author":"ada","Labels":"bug, windows","Updated":"2026-11-12","url":"https://example.invalid/issues/42"},{"#":39,"Title":"Unicode in titles","Author":"zoe","Labels":"i18n","Updated":"2026-11-01","url":"https://example.invalid/issues/39"}]
```

<!-- stdout -->
```text
https://example.invalid/issues/42
https://example.invalid/issues/39
```

## How it works

The CLI shows one column per top-level property and nested values as compact JSON, so
flatten first, and keep the property you need afterwards (`url`):

<!-- test: exit=124 calls="124@3x6" -->
```powershell
$response = Get-Content -Raw data\issues.json | ConvertFrom-Json
$rows = @($response | ForEach-Object { $_ } | Where-Object { -not $_.PSObject.Properties['pull_request'] } | ForEach-Object {
    [pscustomobject]@{
        '#' = $_.number; Title = $_.title; Author = $_.user.login
        Labels = ($_.labels.name -join ', ')
        Updated = if ($_.updated_at -is [datetime]) { $_.updated_at.ToString('yyyy-MM-dd') } else { "$($_.updated_at)".Substring(0, 10) }
        url = $_.html_url
    }
})
ConvertTo-Json -InputObject $rows -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues'
```

<!-- submit: pick=2 -->
```json
[{"#":41,"Title":"Document the <form> limits","Author":"grace","Labels":"docs","Updated":"2026-11-10","url":"https://example.invalid/issues/41"}]
```

Two edition differences the script handles: PowerShell 7 turns ISO date strings into
`[datetime]` while Windows PowerShell keeps the text (hence the `-is [datetime]` test),
and a parsed JSON array goes down the pipeline as one object in 5.1 (`ForEach-Object { $_ }`
unrolls it). What comes back is the array of the chosen records exactly as they went in.

Linux: [Choose from JSON API output (Linux)](../../linux/recipes/json-api.md).
