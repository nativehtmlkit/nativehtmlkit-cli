# select: choose rows (Windows)

`nativehtmlkit select` shows the records piped into it as a table with a pick column and
writes the rows the user submits to stdout. This page shows every option of the command
with a PowerShell example; each one works in Windows PowerShell 5.1 and PowerShell 7. The
exact rules are in the [OS-neutral reference](../../reference/select.md).

```text
nativehtmlkit select [OPTIONS] < records
```

| Outcome | `$LASTEXITCODE` | stdout |
|---|---|---|
| **Submit selection** | 0 | the chosen rows, in input order |
| **Cancel**, or the window closed | 2 | empty |
| `--timeout` expired | 124 | empty |
| error (bad input or option, no host) | 1 | empty; `nativehtmlkit: error[<code>]: ...` on stderr |

The examples run in the `examples` folder of a clone of this repository, which has the
sample files `data\servers.csv`, `data\issues.json` and `css\light.css`. They were run
against the released Windows CLI 0.1.2 in Windows PowerShell 5.1 (and in PowerShell 7) by
`scripts/test-docs.ps1`; a "Submit prints" block shows the exact text the released code
writes when the user ticks the rows named above it
([how the examples are verified](../index.md#how-the-examples-are-verified)). Set up UTF-8
first when your data is not plain ASCII ([why](../index.md#set-up-utf-8-once)).

## Without options: one line

Each string piped in is one row (`--input-format lines`). The window has one radio button
per row; the chosen line is printed.

<!-- test: exit=124 calls="124@3x1" -->
```powershell
'small', 'medium', 'large' | nativehtmlkit select
```

Submit prints, after picking `medium`:

<!-- submit: pick=2 -->
```text
medium
```

Capture it in a variable and check `$LASTEXITCODE` right after the call. A non-zero status
is not an exception:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
$size = 'small', 'medium', 'large' | nativehtmlkit select
switch ($LASTEXITCODE) {
    0       { "size: $size" }
    2       { 'cancelled' }
    124     { 'no answer in time' }
    default { Write-Error "failed with $LASTEXITCODE" }
}
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
medium
```

After the user picks `medium` the script prints:

<!-- stdout -->
```text
size: medium
```

## `--multi`

Checkboxes instead of radio buttons: any number of rows. The chosen rows come back in
**input order**, whatever order they were ticked in; several lines arrive in PowerShell as
an array of strings.

<!-- test: exit=124 calls="124@4x1" -->
```powershell
'alpha', 'beta', 'gamma', 'delta' | nativehtmlkit select --multi
```

Submit prints, after ticking `delta`, then `alpha`:

<!-- submit: pick=4,1 -->
```text
alpha
delta
```

Submit with nothing ticked is refused: the window stays open and says *select at least one
row before submitting*:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit select --multi
```

<!-- submit: pick= rejected=empty -->

## `--allow-empty`

Accept Submit with nothing ticked. stdout is then empty for `lines` (and `ndjson`), `[]`
for `json`, the header line for `csv`/`tsv`:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
$extras = @('clear cache', 'rotate logs', 'vacuum database' |
    nativehtmlkit select --multi --allow-empty --title 'Also run')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
"$($extras.Count) extra task(s)"
```

Submit with nothing ticked prints nothing and exits 0:

<!-- submit: pick= -->
```text
```

<!-- test: exit=124 calls="124@2x2" -->
```powershell
'name,size', 'a.txt,1', 'b.txt,2' |
    nativehtmlkit select --multi --allow-empty --input-format csv --output-format json
```

<!-- submit: pick= -->
```json
[]
```

## `--input-format FORMAT`

How stdin is parsed: `lines` (default), `csv`, `tsv`, `json`, `ndjson`. In PowerShell the
most useful one is `json`: choose the properties with `Select-Object`, then `ConvertTo-Json`
([input formats](../input-formats.md)):

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --input-format csv
```

<!-- test: exit=124 calls="124@*x3" -->
```powershell
Get-ChildItem -File | Select-Object Name, Length, @{ n = 'Modified'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } } |
    ConvertTo-Json | nativehtmlkit select --input-format json
```

## `--no-headers`

For `csv` and `tsv`: the first record is data, and the columns are named `column_1` ...
`column_N`:

<!-- test: exit=124 calls="124@3x2" -->
```powershell
'web-01,healthy', 'web-02,degraded', 'db-01,healthy' |
    nativehtmlkit select --input-format csv --no-headers --output-format json
```

Submit prints, after picking `web-02`:

<!-- submit: pick=2 -->
```json
[{"column_1":"web-02","column_2":"degraded"}]
```

## `--output-format FORMAT`

What Submit writes: `same` (default: the input format), `lines`, `csv`, `tsv`, `json`,
`ndjson` ([output formats](../output-formats.md)). JSON out, read back as objects:

<!-- test: exit=124 calls="124@7x7" -->
```powershell
$json = Get-Content data\servers.csv |
    nativehtmlkit select --multi --input-format csv --output-format json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
(ConvertFrom-Json -InputObject ($json -join "`n")) | ForEach-Object { $_.host }
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"host":"web-02","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"degraded","notes":"disk 91% full, cleanup scheduled"},{"host":"db-02","role":"database","region":"us-east","cpu_cores":"16","memory_gib":"128","status":"maintenance","notes":"replica, patching until 18:00"}]
```

The replayed result above is what Submit prints after ticking `web-02` and `db-02`; the
script then prints:

<!-- stdout -->
```text
web-02
db-02
```

<!-- test: exit=124 calls="124@7x7" -->
```powershell
Get-Content data\servers.csv | nativehtmlkit select --multi --input-format csv --output-format json
```

<!-- submit: pick=2,6 -->
```json
[{"host":"web-02","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"degraded","notes":"disk 91% full, cleanup scheduled"},{"host":"db-02","role":"database","region":"us-east","cpu_cores":"16","memory_gib":"128","status":"maintenance","notes":"replica, patching until 18:00"}]
```

## `--title TITLE`

The window title and the heading of the page (default `Select an item`). 1 to 128
characters, no control characters; it is shown as text, never as markup:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'main', 'feature/login' | nativehtmlkit select --title 'Switch to <branch> & pull'
```

A title that is too long (or empty) is refused before any window opens:

<!-- test: exit=1 calls="1@none" -->
```powershell
'a' | nativehtmlkit select --title ('x' * 129)
```

<!-- stderr -->
```text
nativehtmlkit: error[usage.invalid]: --title must be nonempty, at most 128 characters, with no control characters
```

Windows PowerShell 5.1 does not pass an empty string argument (`''`) to a native program
at all, so `--title ''` there is a usage error of the argument parser instead (also exit 1).

## `--css FILE`

A trusted UTF-8 style sheet (at most 256 KiB) added after the built-in one
([CSS and forms](../css-and-forms.md)):

<!-- test: exit=124 calls="124@3x1" -->
```powershell
'Europe/Prague', 'America/New_York', 'Asia/Tokyo' |
    nativehtmlkit select --title 'Time zone' --css css/light.css
```

## `--timeout SECONDS`

Give the user a deadline. Without it the window waits as long as it takes. When the
deadline passes the window is closed, stderr says so, stdout stays empty and
`$LASTEXITCODE` is 124:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'deploy', 'skip' | nativehtmlkit select --title 'Deploy now?' --timeout 60
"exit status: $LASTEXITCODE"
```

Nobody answered within the deadline (60 s here; the test uses a shorter one):

<!-- stdout -->
```text
exit status: 124
```

<!-- stderr -->
```text
nativehtmlkit: no decision before the --timeout deadline; the window was closed
```

## `--host PATH`

Use this Core host executable instead of the one beside the CLI. The release archive has
the qualified host next to `nativehtmlkit.exe`, so you only need this for development
builds:

<!-- test: exit=124 calls="0@none 124@2x1" -->
```powershell
$coreHost = (nativehtmlkit doctor | Select-String '^Core host: (.+)$').Matches[0].Groups[1].Value
'a', 'b' | nativehtmlkit select --host $coreHost
```

(`$host` is a built-in variable in PowerShell, hence `$coreHost`.) A path that does not
exist is an error, before anything else happens:

<!-- test: exit=1 calls="1@none" -->
```powershell
'a' | nativehtmlkit select --host C:\missing\nativehtmlkit-host.exe
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: C:\missing\nativehtmlkit-host.exe
```

## `--diagnostics LEVEL`

`off`, `normal` (default), `debug`, `trace`: structured JSON records about the session on
stderr, separate from the result on stdout
([environment and diagnostics](../environment-and-diagnostics.md)):

<!-- test: exit=124 calls="124@2x1" -->
```powershell
$log = 'a', 'b' | nativehtmlkit select --diagnostics debug 2>&1 | ForEach-Object { "$_" }
$events = $log | Where-Object { $_.StartsWith('{') } | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
    Where-Object { $_.component -eq 'nativehtmlkit-cli' } | ForEach-Object { $_.event }
$events -contains 'window.ready'
```

<!-- stdout -->
```text
True
```

## `--rpc-timeout SECONDS`

How long the CLI waits for the host to answer one request before it treats the host as
hung (default 30). The person in front of the window is never affected by it:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit select --rpc-timeout 10
```

## `--liveness-interval SECONDS`

Idle time between the CLI's "are you alive?" probes to the host while the window is open
(default 5; `0` turns probing off):

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit select --liveness-interval 2 --rpc-timeout 5
```

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit select --liveness-interval 0
```

## `--startup-timeout SECONDS`

How long the host may take to open the window (default 15). Raise it on a slow, loaded
machine:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit select --startup-timeout 60
```

## `-h`, `--help`

<!-- test: exit=0 shim=off -->
```powershell
(nativehtmlkit select --help | Select-String -SimpleMatch -- '--multi').Line
```

<!-- stdout -->
```text
      --multi
```

The usage line names the program `nativehtmlkit.exe select [OPTIONS]`. `-h` prints the
same options in one line each.

## Options in any order

Options can come before or after the command name; each may be given once:

<!-- test: exit=124 calls="124@2x1" -->
```powershell
'a', 'b' | nativehtmlkit --rpc-timeout 10 select --multi --allow-empty
```

A repeated or unknown option is a usage error, exit 1:

<!-- test: exit=1 calls="1@none" -->
```powershell
'a' | nativehtmlkit select --multi --multi
```

## Related

- [view](view.md), [form](form.md), [doctor](doctor.md)
- [Exit codes and scripting](../exit-codes-and-scripting.md)
- Recipes: [pick a Git branch](../recipes/git-branch.md), [delete files](../recipes/delete-files.md),
  [Windows services](../recipes/services.md)
