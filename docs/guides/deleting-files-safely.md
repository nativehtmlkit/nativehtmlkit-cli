# Delete files with confirmation

Tick files in a window, confirm in a second window, then delete exactly the ticked files.
Script: [examples/delete-files.sh](../../examples/delete-files.sh) /
[examples/delete-files.ps1](../../examples/delete-files.ps1).

## 1. List files without breaking on odd names

File names may contain spaces, quotes, tabs and even newlines. `lines` input cannot carry a
newline inside a name, so the script lists the directory NUL-separated and lets `jq` build
JSON rows:

```bash
rows=$(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\0' |
  jq -R -s -c 'split("\u0000") | map(select(length > 0) | split("\t") | (.[2:] | join("\t")) as $path | {
      Name: ($path | split("/") | last), "Size (KiB)": ((.[0] | tonumber) / 1024 | ceil),
      Modified: .[1], Path: $path
    }) | sort_by(.Modified) | .[:2000]')     # the CLI shows at most 2,000 rows
```

`select` refuses empty input (exit 1), so check for zero rows first and exit 0 with a message.

## 2. Pick, then confirm

```bash
picked=$(pick --multi --input-format json --output-format json --title "Files to delete" <<<"$rows")
count=$(jq length <<<"$picked")
answer=$(printf 'No, keep them\nYes, delete %d file(s)\n' "$count" | pick --title "Delete $count file(s)?")
[[ $answer == Yes* ]] || { echo "kept all files" >&2; exit 0; }
```

`pick` is the helper from [handling exit statuses](handling-exit-status.md) that ends the
script on Cancel or timeout. The confirmation is a single-choice `select`: nothing is
preselected, so deleting needs a deliberate click on the second row and Submit; Cancel,
closing the window or the deadline delete nothing.

## 3. Delete exactly what was chosen

```bash
jq -j '.[].Path + "\u0000"' <<<"$picked" | xargs -0 rm -v --
```

NUL-separated paths and `--` mean no name can be split or read as an option.

## PowerShell

```powershell
$json = $rows | ConvertTo-Json -Compress |
    Invoke-Picker select --multi --input-format json --output-format json --title 'Files to delete'
$picked = @(ConvertFrom-Json -InputObject $json)
$answer = "No, keep them", "Yes, delete $($picked.Count) file(s)" | Invoke-Picker select --title "Delete $($picked.Count) file(s)?"
if (-not $answer.StartsWith('Yes')) { exit 0 }
foreach ($file in $picked) {
    if ($PSCmdlet.ShouldProcess($file.Path, 'Delete file')) { Remove-Item -LiteralPath $file.Path }
}
```

The script declares `[CmdletBinding(SupportsShouldProcess)]`, so `-WhatIf` shows what would
be deleted and `-Confirm` adds PowerShell's own prompt. Always use `-LiteralPath`: names with
`[` `]` are wildcards for `-Path`.

## A form as the confirmation

For a stronger confirmation, use `form` with a required checkbox. Escape the list of names
when you put it into the HTML:

```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }
{
  echo '<form id="nhk-form"><p>These files will be deleted:</p><ul>'
  jq -r '.[].Path' <<<"$picked" | while IFS= read -r p; do echo "<li>$(esc "$p")</li>"; done
  echo '</ul><label><input type="checkbox" name="sure" value="yes" required> I understand</label></form>'
} > confirm.html
nativehtmlkit form --html confirm.html --title 'Confirm deletion' >/dev/null || exit
```

Submit is only accepted with the box ticked (Core validates `required`), so exit 0 means
confirmed.
