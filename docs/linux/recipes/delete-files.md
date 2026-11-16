# Delete files with confirmation (Linux)

Tick files in a window, confirm in a second window, then delete exactly the ticked files.
Cancel, closing a window or the deadline delete nothing. Script:
[examples/delete-files.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/delete-files.sh)
(needs GNU `find`, `jq`, `xargs`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Run it

<!-- test: exit=124 calls="124@4x4" -->
```bash
mkdir -p scratch
printf 'one\n' > 'scratch/a b.txt'
printf 'two\n' > "scratch/it's \"quoted\".log"
printf 'three\n' > scratch/notes.md
printf 'four\n' > scratch/-rf.txt
./delete-files.sh scratch
```

A table of the four files (`Name`, `Size (KiB)`, `Modified`, `Path`) opens. Suppose the user
ticks `a b.txt` and `-rf.txt`, then picks **Yes, delete 2 file(s)** in the confirmation
window:

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"a b.txt","Size (KiB)":1,"Modified":"2026-11-16 09:00","Path":"scratch/a b.txt"},{"Name":"-rf.txt","Size (KiB)":1,"Modified":"2026-11-16 09:00","Path":"scratch/-rf.txt"}]
```

The script then asks in a second window (here nobody answers, so it ends with 124 and
deletes nothing):

<!-- stderr -->
```text
delete-files: no decision in time, nothing deleted
```

With **Yes, delete 2 file(s)** picked in the second window, exactly those two files go:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Yes, delete 2 file(s)
```

<!-- stdout -->
```text
removed 'scratch/a b.txt'
removed 'scratch/-rf.txt'
```

With **No, keep them** the script exits 0 and deletes nothing:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
No, keep them
```

<!-- stderr -->
```text
delete-files: kept all files
```

Only a file glob:

<!-- test: exit=124 calls="124@1x4" -->
```bash
mkdir -p scratch && printf 'x\n' > scratch/old.iso && printf 'y\n' > scratch/keep.txt
./delete-files.sh scratch '*.iso'
```

Nothing matches: the script says so and exits 0 without opening a window:

<!-- test: exit=0 calls="" -->
```bash
mkdir -p empty-dir
./delete-files.sh empty-dir
```

## How it works

1. **List without breaking on odd names.** File names may contain spaces, quotes or
   newlines, so the script lists the directory NUL-separated and builds JSON rows with `jq`:

   ```bash
   rows=$(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\0' |
     jq -R -s -c 'split("\u0000") | map(select(length > 0) | split("\t") | (.[2:] | join("\t")) as $path | {
         Name: ($path | split("/") | last), "Size (KiB)": ((.[0] | tonumber) / 1024 | ceil),
         Modified: .[1], Path: $path
       }) | sort_by(.Modified) | .[:2000]')
   ```

2. **Pick, then confirm.** The confirmation is a single-choice `select` whose safe answer
   comes first; nothing is preselected, so deleting needs a deliberate choice and Submit:

   ```bash
   answer=$(printf 'No, keep them\nYes, delete %d file(s)\n' "$count" | pick --title "Delete $count file(s)?")
   ```

3. **Delete exactly what was chosen**, NUL-separated and after `--`, so no name can be split
   or read as an option (`-rf.txt` stays a file name):

   ```bash
   jq -j '.[].Path + "\u0000"' <<<"$picked" | xargs -0 rm -v --
   ```

## A form as the confirmation

For a stronger confirmation use `form` with a required checkbox; Submit is only accepted
with the box ticked. Escape the names you put into the HTML:

<!-- test: exit=124 calls="124@0x1" -->
```bash
picked='[{"Path":"scratch/a <b>.txt"},{"Path":"scratch/notes & more.md"}]'
esc() { jq -rn --arg s "$1" '$s | @html'; }
{
  echo '<form id="nhk-form"><p>These files will be deleted:</p><ul>'
  jq -r '.[].Path' <<<"$picked" | while IFS= read -r p; do echo "<li>$(esc "$p")</li>"; done
  echo '</ul><label><input type="checkbox" name="sure" value="yes" required> I understand</label></form>'
} > confirm.html
nativehtmlkit form --html confirm.html --title 'Confirm deletion' > /dev/null || exit
echo 'confirmed'
```

Exit 0 means confirmed; anything else ends the script before deleting.

Windows: [Delete files with confirmation (Windows)](../../windows/recipes/delete-files.md).
