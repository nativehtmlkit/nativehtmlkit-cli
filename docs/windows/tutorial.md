# Tutorial: build a project picker (Windows)

In this tutorial you build `proj.ps1`, a small PowerShell tool that remembers project
folders and lets you jump to one by picking it in a native window:

```powershell
.\proj.ps1 add C:\src\website       # a form asks for name and tags
Set-Location (.\proj.ps1 pick)      # a table of projects; pick one, Submit
.\proj.ps1 list                     # a read-only table
.\proj.ps1 remove                   # tick projects, confirm
```

On the way you use all three interactive commands (`select`, `form`, `view`), two input
formats, the exit contract, encoding for trusted HTML, and a stylesheet. The finished
script is
[examples/tutorial/proj.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial/proj.ps1)
(about 120 lines, Windows PowerShell 5.1 and PowerShell 7); every step below is a part of
it. The same tutorial for bash: [Linux](../linux/tutorial.md).

You need: the CLI release extracted and on `PATH` ([install](index.md#install)).

## Step 1: a first picker

`select` reads records from stdin, one per line by default, and prints the chosen one:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
'C:\src\website', 'C:\src\cli', 'C:\notes' | nativehtmlkit select --title 'Open project'
```

A window lists the three paths with a radio button each. Pick one and press
**Submit selection**: the path is printed and `$LASTEXITCODE` is 0. Press **Cancel**:
nothing is printed and `$LASTEXITCODE` is 2.

That is already a usable tool, but a path alone is a poor label, and we want to store more
(a name, tags, the date added).

## Step 2: store projects as JSON lines

Keep one JSON object per line in a file. NDJSON is both easy to append to and an input format
of the CLI, so the file can be piped straight into `select`:

```json
{"name":"website","path":"C:\\src\\website","tags":"work, web","added":"2026-11-16"}
{"name":"cli","path":"C:\\src\\cli","tags":"rust","added":"2026-11-16"}
```

The store lives in `%APPDATA%\proj\projects.ndjson` unless `$env:PROJ_FILE` says otherwise,
and is always read and written as UTF-8 without BOM:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
$store = $env:PROJ_FILE
if (-not $store) {
    $base = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME '.config' }
    $store = Join-Path $base 'proj/projects.ndjson'
}
```

With `--input-format ndjson` the window shows a table with the columns `name`, `path`,
`tags`, `added`. With `--output-format json` the result is a JSON array holding the chosen
record exactly as stored:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
function Invoke-Pick {
    Assert-Projects
    $picked = Get-StoreText | ui select --input-format ndjson --output-format json --title 'Open project'
    (ConvertFrom-Json -InputObject $picked)[0].path
}
```

`select` refuses empty input (exit 1, `no selectable input rows`), so check first:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
function Stop-Proj([string] $Message) { Write-Warning "proj: $Message"; exit 1 }
function Assert-Projects { if ((Get-Records).Count -eq 0) { Stop-Proj 'no projects yet; add one with: proj add [DIR]' } }
```

## Step 3: one place for the exit contract

Every call of the CLI can end in four ways: 0 (a result on stdout), 2 (Cancel), 124
(`--timeout`), or 1 and others (an error already explained on stderr). Handle that once.
Inside a function, `exit` ends the whole script, with that status:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
function ui {
    $out = $input | nativehtmlkit @args @style
    switch ($LASTEXITCODE) {
        0       { return ($out -join "`n") }
        2       { exit 2 }
        124     { Write-Warning 'proj: no answer in time'; exit 124 }
        default { exit $LASTEXITCODE }
    }
}
```

`$input` passes the pipeline on to the CLI, `@args` the arguments, and `@style` the
stylesheet from step 7. A cancelled `proj.ps1 pick` exits 2 and prints nothing, so the
caller can tell.

## Step 4: add projects with a form

`form --html FILE` shows your own HTML form and prints `{"entries":[...]}` on Submit. The
fragment is *trusted* HTML, so the folder name and path, which come from the file system,
must be encoded before they go into it:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }
```

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
    $form = @"
<form id="nhk-form">
  <p><label>Name <input name="name" required maxlength="60" value="$(Enc (Split-Path -Leaf $dir))"></label></p>
  <p><label>Directory <input name="path" required value="$(Enc $dir)"></label></p>
  <p><label>Tags <input name="tags" placeholder="work, rust" pattern="[A-Za-z0-9 ,_-]*"
         title="letters, digits, spaces, commas, - and _"></label></p>
</form>
"@
    [IO.File]::WriteAllText($html, $form, $Utf8)
    try { $result = ui form --html $html --title 'Add project' }
    finally { Remove-Item -LiteralPath $html -ErrorAction SilentlyContinue }
```

The form element must have `id="nhk-form"`. Core checks `required`, `maxlength` and
`pattern` when the user presses Submit; an invalid form stays open with a message. The
result looks like this:

```json
{"entries":[{"kind":"text","name":"name","value":"website"},{"kind":"text","name":"path","value":"C:\\src\\website"},{"kind":"text","name":"tags","value":"work, web"}]}
```

The entries become one ordered record, which is checked and appended:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
    $values = @{}
    foreach ($e in (ConvertFrom-Json -InputObject $result).entries) { $values[$e.name] = $e.value }
    $record = [ordered]@{ name = $values.name; path = $values.path; tags = "$($values.tags)"; added = (Get-Date -Format 'yyyy-MM-dd') }
    if (-not (Test-Path -LiteralPath $record.path -PathType Container)) { Stop-Proj "not a directory: $($record.path)" }
    if (@(Get-Records | Where-Object { $_.path -eq $record.path }).Count) { Stop-Proj "already bookmarked: $($record.path)" }
```

Messages go to the warning stream; the success output is reserved for results (that is what
makes `Set-Location (.\proj.ps1 pick)` work).

## Step 5: list them

`view` shows the same file read-only. It has no result; closing it exits 0:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
function Invoke-List {
    Assert-Projects
    Get-StoreText | ui view --input-format ndjson --title "Projects ($((Get-Records).Count))" | Out-Null
}
```

## Step 6: remove with confirmation

`--multi` turns the radio buttons into checkboxes. `--output-format ndjson` returns the
chosen records one per line, exactly as stored. A second `select` asks for confirmation;
its safe answer is first and nothing is preselected:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
    $count = $picked.Count
    $answer = 'Keep them', "Remove $count project(s)" | ui select --title "Remove $count project(s)?"
    if (-not $answer.StartsWith('Remove')) { Write-Warning 'proj: nothing removed'; return }
```

The store is rewritten through a temporary file and `Move-Item`, so an interrupted run never
leaves half a file.

## Step 7: give it a look

`--css` adds a stylesheet after the built-in one. The page's colours are CSS custom
properties, so small overrides go a long way
([examples/tutorial/proj.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial/proj.css)):

```css
:root { --accent: #3fa37a; }
h1 { font-size: 18px; letter-spacing: .02em; }
td { color: #dfe7f1; }
button.primary { background: #2f8a63; border-color: #3fa37a; }
```

`ui` passes it on every call:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
$style = '--css', (Join-Path $PSScriptRoot 'proj.css')
```

## Step 8: the command dispatcher

A validated parameter chooses the command; the console encoding is restored at the end:

<!-- not-tested: excerpt of examples/tutorial/proj.ps1, run in "Try it" below -->
```powershell
param(
    [ValidateSet('pick', 'add', 'list', 'remove')] [string] $Command = 'pick',
    [string] $Directory = '.'
)
```

A script cannot change its caller's location by itself, so add a function to your
`$PROFILE`:

```powershell
function p { $dir = & "$HOME\tools\proj.ps1" pick; if ($LASTEXITCODE -eq 0) { Set-Location -LiteralPath $dir } }
```

After Cancel, `proj.ps1 pick` exits 2 with no output and `p` stays where it is.

## Step 9: try it

The examples below run `proj.ps1` from the repository's `examples` folder with a store in
the current folder. They were run against the released CLI 0.1.2 in Windows PowerShell 5.1
and PowerShell 7 by `scripts/test-docs.ps1`, headless and with replayed results
([how](index.md#how-the-examples-are-verified)).

Add a project. The form opens with the folder's name and path filled in:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
$env:PROJ_FILE = Join-Path (Get-Location) 'projects.ndjson'
.\tutorial\proj.ps1 add data
```

When the user submits it, the record is stored:

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"name","value":"sample data"},{"kind":"text","name":"path","value":"data"},{"kind":"text","name":"tags","value":"demo"}]}
```

<!-- stdout -->
```text
WARNING: proj: added data
```

Pick one (the store here has two projects):

<!-- test: exit=124 calls="124@2x4" -->
```powershell
$env:PROJ_FILE = Join-Path (Get-Location) 'projects.ndjson'
$lines = '{"name":"sample data","path":"data","tags":"demo","added":"2026-11-16"}',
         '{"name":"styles","path":"css","tags":"","added":"2026-11-16"}'
[IO.File]::WriteAllText($env:PROJ_FILE, ($lines -join "`n") + "`n")
.\tutorial\proj.ps1 pick
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"name":"styles","path":"css","tags":"","added":"2026-11-16"}]
```

<!-- stdout -->
```text
css
```

After Cancel, `proj.ps1 pick` prints nothing and exits 2:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
```

List and remove:

<!-- test: exit=124 calls="124@2x4" -->
```powershell
$env:PROJ_FILE = Join-Path (Get-Location) 'projects.ndjson'
$lines = '{"name":"sample data","path":"data","tags":"demo","added":"2026-11-16"}',
         '{"name":"styles","path":"css","tags":"","added":"2026-11-16"}'
[IO.File]::WriteAllText($env:PROJ_FILE, ($lines -join "`n") + "`n")
.\tutorial\proj.ps1 list
```

<!-- test: exit=124 calls="124@2x4" -->
```powershell
$env:PROJ_FILE = Join-Path (Get-Location) 'projects.ndjson'
$lines = '{"name":"sample data","path":"data","tags":"demo","added":"2026-11-16"}',
         '{"name":"styles","path":"css","tags":"","added":"2026-11-16"}'
[IO.File]::WriteAllText($env:PROJ_FILE, ($lines -join "`n") + "`n")
.\tutorial\proj.ps1 remove 3> $null
$status = $LASTEXITCODE
@(Get-Content $env:PROJ_FILE).Count
exit $status
```

<!-- stdout -->
```text
2
```

Tick `sample data`, then confirm with **Remove 1 project(s)**:

<!-- replay: call=1 exit=0 expect=124 -->
```text
{"name":"sample data","path":"data","tags":"demo","added":"2026-11-16"}
```

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Remove 1 project(s)
```

<!-- stdout -->
```text
1
```

To test your own tools like this, see
[test your scripts without a desktop](recipes/headless-testing.md).

## Where next

- [Recipes](recipes/index.md): Git branches, files, processes, services, Docker, APIs, CSV,
  logs, pipelines, forms.
- [Tutorial: a Git branch picker](tutorial-branch-picker.md): JSON tables and `--multi`.
- Every option with an example: [select](commands/select.md), [view](commands/view.md),
  [form](commands/form.md); the exact [reference](../REFERENCE.md).
- [Architecture](../ARCHITECTURE.md): what happens between your pipeline and the window.
