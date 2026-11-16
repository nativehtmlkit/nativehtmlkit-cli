# Script the CLI in Windows PowerShell

`nativehtmlkit.exe` is an ordinary native program: PowerShell pipes **text** to its stdin and
reads its stdout as **lines of text**. Everything below was verified with the Windows
release archive in Windows PowerShell 5.1 (Windows Server 2022) and in PowerShell 7 (Linux).

## 1. Set the encodings once per script

The CLI reads and writes UTF-8. Windows PowerShell 5.1 by default sends `us-ascii` to native
programs (`$OutputEncoding`) and decodes their output with the console code page (for
example IBM437), so non-ASCII text would arrive as `?` and come back garbled.

```powershell
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    # ... use nativehtmlkit ...
}
finally {
    [Console]::OutputEncoding = $previousEncoding    # process-wide setting: restore it
}
```

Use `[System.Text.UTF8Encoding]::new($false)`, **not** `[Text.Encoding]::UTF8`: the latter
makes Windows PowerShell 5.1 write a byte-order mark first, and the CLI's `json` format
then fails with `error[input.invalid]: invalid JSON input: expected value at line 1 column 1`
(observed on 5.1). PowerShell 7 already defaults to UTF-8 without BOM; the lines above are
harmless there.

## 2. Send objects as JSON, choosing the properties

```powershell
Get-Service | Select-Object Name, DisplayName, @{ n = 'Status'; e = { "$($_.Status)" } } |
    ConvertTo-Json -Compress |
    nativehtmlkit select --multi --input-format json --output-format json --title 'Services'
```

- `Select-Object` first: raw objects have dozens of properties (the CLI accepts 32 columns)
  and nested objects would be shown as JSON text.
- Turn enums and dates into strings yourself (`"$($_.Status)"`, `.ToString('yyyy-MM-dd')`):
  `ConvertTo-Json` writes enums as numbers, and Windows PowerShell 5.1 writes dates as
  `"\/Date(...)\/"`.
- One object serialises as a JSON object, several as an array; the CLI accepts both.
- Zero objects produce no input at all, which `select` refuses (exit 1): check the count
  first.

## 3. Read the result back

```powershell
$json = $rows | ConvertTo-Json -Compress | nativehtmlkit select --multi --input-format json --output-format json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$picked = @(ConvertFrom-Json -InputObject ($json -join "`n"))
$picked | ForEach-Object { $_.Name }
```

- stdout arrives as a string, or as an array of strings when there are several lines:
  `-join "`n"` makes it one string.
- `ConvertFrom-Json -InputObject` returns the array's elements in both editions; piping into
  `ConvertFrom-Json` in 5.1 can yield the whole array as one object.
- `lines` output (`select` without `--output-format`) comes back as one string per line,
  ready for `ForEach-Object`.

## 4. Exit statuses

`$LASTEXITCODE` holds the CLI's status; a non-zero status is not an exception. Branch on it
right after the call ([handling exit statuses](handling-exit-status.md#powershell-lastexitcode)).
`exit $LASTEXITCODE` hands it on to whoever started the script:
`powershell -File .\pick-service.ps1` exits 2 when the user cancelled.

## 5. Native stderr and `$ErrorActionPreference = 'Stop'`

The CLI and the host write diagnostics to stderr. Left alone, stderr goes to the console and
does not affect the script. If you redirect it (`2>&1`, `2> file`) Windows PowerShell 5.1
turns each line into an error record, and with `$ErrorActionPreference = 'Stop'` the first
one ends the script. Redirect with `'Continue'` in effect, as
[pick-container.ps1](../../examples/pick-container.ps1) does around `docker logs 2>&1`.

## 6. Generating HTML for `form`

Encode every dynamic value with `[System.Net.WebUtility]::HtmlEncode` and write the file as
UTF-8 without BOM:

```powershell
[IO.File]::WriteAllText($path, $html, [System.Text.UTF8Encoding]::new($false))
nativehtmlkit form --html $path --title 'Deploy'
```

`Set-Content -Encoding UTF8` writes a BOM in 5.1 but not in 7; the explicit .NET call
behaves the same in both.

## Examples

| Script | Shows |
|---|---|
| [pick-git-branch.ps1](../../examples/pick-git-branch.ps1) | objects from tab-separated output, single choice |
| [delete-files.ps1](../../examples/delete-files.ps1) | `SupportsShouldProcess`, confirmation window, `-LiteralPath` |
| [stop-process.ps1](../../examples/stop-process.ps1) | `Get-Process` with computed properties |
| [pick-service.ps1](../../examples/pick-service.ps1) | Windows services, an action chosen in a second window |
| [pick-container.ps1](../../examples/pick-container.ps1) | NDJSON from `docker`, stderr handling |
| [pick-from-api.ps1](../../examples/pick-from-api.ps1) | `Invoke-RestMethod`, date handling across editions |
| [csv-report.ps1](../../examples/csv-report.ps1) | raw CSV text in and out, UTF-8 without BOM |
| [deploy-form.ps1](../../examples/deploy-form.ps1) | generated form, entries to a hashtable, returned object |
| [view-logs.ps1](../../examples/view-logs.ps1) | `Get-Content -Tail`, `Get-WinEvent` |
