# Delete files with confirmation (Windows)

Tick files in a window, confirm in a second window, then delete exactly the ticked files.
Cancel, closing a window or the deadline delete nothing. Script:
[examples/delete-files.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/delete-files.ps1); it supports `-WhatIf` and `-Confirm`.

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Run it

<!-- test: exit=124 calls="124@4x4" -->
```powershell
New-Item -ItemType Directory -Path scratch | Out-Null
'one' | Set-Content -LiteralPath 'scratch/a b.txt'
'two' | Set-Content -LiteralPath "scratch/it's [quoted].log"
'three' | Set-Content -LiteralPath 'scratch/notes.md'
'four' | Set-Content -LiteralPath 'scratch/-rf.txt'
.\delete-files.ps1 -Path scratch
```

A table of the four files (`Name`, `Size (KiB)`, `Modified`, `Path`) opens. Suppose the user
ticks `a b.txt` and `it's [quoted].log`:

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"a b.txt","Size (KiB)":1,"Modified":"2026-11-16 09:00","Path":"scratch/a b.txt"},{"Name":"it's [quoted].log","Size (KiB)":1,"Modified":"2026-11-16 09:00","Path":"scratch/it's [quoted].log"}]
```

The script then asks in a second window (here nobody answers, so it ends with 124 and
deletes nothing):

<!-- stdout -->
```text
WARNING: Nothing deleted.
```

With **Yes, delete 2 file(s)** picked in the second window, exactly those two files go:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Yes, delete 2 file(s)
```

<!-- stdout -->
```text
deleted scratch/a b.txt
deleted scratch/it's [quoted].log
```

With **No, keep them** nothing is deleted:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
No, keep them
```

<!-- stdout -->
```text
Kept all files.
```

`-WhatIf` shows what would be deleted and deletes nothing:

<!-- test: exit=124 calls="124@1x4" -->
```powershell
New-Item -ItemType Directory -Path scratch | Out-Null
'x' | Set-Content -LiteralPath 'scratch/old.iso'
.\delete-files.ps1 -Path scratch -Filter *.iso -WhatIf
```

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"old.iso","Size (KiB)":1,"Modified":"2026-11-16 09:00","Path":"scratch/old.iso"}]
```

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Yes, delete 1 file(s)
```

<!-- stdout -->
```text
What if: Performing the operation "Delete file" on target "scratch/old.iso".
```

Nothing matches: the script says so and exits 0 without opening a window:

<!-- test: exit=0 calls="" -->
```powershell
New-Item -ItemType Directory -Path empty-dir | Out-Null
.\delete-files.ps1 -Path empty-dir
```

<!-- stdout -->
```text
Nothing in empty-dir matches *.
```

## How it works

1. **List the files as objects**, newest last, at most 2,000 (the CLI's row limit), and send
   them as JSON.
2. **Pick, then confirm** with `Invoke-Picker`, a helper that ends the script on anything
   but a Submit. The confirmation is a single-choice `select` whose safe answer comes first:

   ```powershell
   $answer = "No, keep them", "Yes, delete $($picked.Count) file(s)" |
       Invoke-Picker select --title "Delete $($picked.Count) file(s)?"
   ```

3. **Delete exactly what was chosen** with `-LiteralPath` (names with `[` `]` are
   wildcards for `-Path`) and `ShouldProcess`, which gives `-WhatIf` and `-Confirm`:

   ```powershell
   if ($PSCmdlet.ShouldProcess($file.Path, 'Delete file')) { Remove-Item -LiteralPath $file.Path }
   ```

## A form as the confirmation

For a stronger confirmation use `form` with a required checkbox; Submit is only accepted
with the box ticked. Encode the names you put into the HTML:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }
$items = ('scratch/a <b>.txt', 'scratch/notes & more.md' | ForEach-Object { "<li>$(Enc $_)</li>" }) -join ''
$html = "<form id=`"nhk-form`"><p>These files will be deleted:</p><ul>$items</ul>" +
        '<label><input type="checkbox" name="sure" value="yes" required> I understand</label></form>'
[IO.File]::WriteAllText((Join-Path (Get-Location) 'confirm.html'), $html, [System.Text.UTF8Encoding]::new($false))
nativehtmlkit form --html confirm.html --title 'Confirm deletion' | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
'confirmed'
```

Linux: [Delete files with confirmation (Linux)](../../linux/recipes/delete-files.md).
