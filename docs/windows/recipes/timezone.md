# Choose a time zone in a light theme (Windows)

Choose one value from a long list in a window restyled with `--css`, and use it in the
next command. Script: [examples/pick-timezone.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-timezone.ps1) with
[css/light.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/light.css).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Run it

<!-- test: exit=124 calls="124@*x3" -->
```powershell
.\pick-timezone.ps1
```

The table lists every time zone of the system (`Id`, `Offset`, `Name`); on Windows the ids
are Windows names such as `Tokyo Standard Time`, in PowerShell 7 on Linux IANA names such
as `Asia/Tokyo`. The script prints the chosen id:

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"Id":"Tokyo Standard Time","Offset":"+09:00","Name":"(UTC+09:00) Osaka, Sapporo, Tokyo"}]
```

<!-- stdout -->
```text
Tokyo Standard Time
```

Use the choice for the next command:

<!-- test: exit=124 calls="124@*x3" -->
```powershell
$zone = .\pick-timezone.ps1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $zone)
'{0:HH:mm} in {1}' -f $now, $zone
```

## How it works

The rows are .NET `TimeZoneInfo` objects reduced to three strings, sent as JSON, with a style
sheet; single choice is the default, so exactly one row comes back:

<!-- not-tested: excerpt of examples/pick-timezone.ps1, which is run above -->
```powershell
$json = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --input-format json --output-format json --title 'Time zone' `
        --css (Join-Path $PSScriptRoot 'css/light.css')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
(ConvertFrom-Json -InputObject ($json -join "`n"))[0].Id
```

The same with plain strings:

<!-- test: exit=124 calls="124@4x1" -->
```powershell
'Europe/Prague', 'Europe/London', 'America/New_York', 'Asia/Tokyo' |
    nativehtmlkit select --title 'Time zone' --css css/light.css
```

<!-- submit: pick=4 -->
```text
Asia/Tokyo
```

`css/light.css` overrides the page's colour custom properties and a few fixed colours
([CSS and forms](../css-and-forms.md)).

Linux: [Choose a time zone in a light theme (Linux)](../../linux/recipes/timezone.md).
