# form: collect values with an HTML form (Windows)

`nativehtmlkit form --html FILE` shows your own HTML form with the CLI's **Cancel** and
**Submit** buttons below it. When the user submits a valid form, one line of JSON with the
values is written to stdout. stdin is not read. Exact rules:
[OS-neutral reference](../../reference/form.md).

```text
nativehtmlkit form [OPTIONS] --html FILE
```

| Outcome | `$LASTEXITCODE` | stdout |
|---|---|---|
| **Submit**, every constraint satisfied | 0 | `{"entries":[...]}` |
| **Cancel**, or the window closed | 2 | empty |
| `--timeout` expired | 124 | empty |
| error (missing file, no `nhk-form`, ...) | 1 | empty |

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)). How to write
and style forms: [CSS and forms](../css-and-forms.md).

## `--html FILE` (required)

A trusted UTF-8 HTML fragment (at most 256 KiB) that contains `<form id="nhk-form">`. Give
every control a `name`; do not add a submit button of your own.
[sample-form.html](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/sample-form.html)
(also in the release archive) is the smallest useful one:

```html
<form id="nhk-form">
  <label>Project name <input id="project" name="project" required placeholder="My NativeHTMLKit App"></label>
  <p><label>Environment
    <select name="environment"><option value="development">Development</option><option value="production">Production</option></select>
  </label></p>
  <p><label><input type="checkbox" name="confirm" value="yes"> I confirm the details</label></p>
</form>
```

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html
```

After typing `Demo App`, keeping *Development* and ticking the checkbox, Submit prints this
line (the exact result the release's GUI qualification asserts on Windows and Linux):

```json
{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"development"},{"kind":"text","name":"confirm","value":"yes"}]}
```

Turn the entries into a hashtable. A checkbox that is not ticked has **no entry**:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
$json = nativehtmlkit form --html sample-form.html
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$values = @{}
foreach ($e in (ConvertFrom-Json -InputObject ($json -join "`n")).entries) { $values[$e.name] = $e.value }
"project=$($values.project) environment=$($values.environment) confirm=$($values.confirm)"
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"development"}]}
```

With that result (checkbox not ticked) the script prints:

<!-- stdout -->
```text
project=Demo App environment=development confirm=
```

The fragment must contain the form element `nhk-form`; otherwise nothing opens:

<!-- test: exit=1 calls="1@none" -->
```powershell
Set-Content -Path no-id.html -Value '<form><input name="a"></form>'
nativehtmlkit form --html no-id.html
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: --html must contain <form id="nhk-form"> with the controls to submit
```

`--html` is required:

<!-- test: exit=1 calls="1@none" -->
```powershell
nativehtmlkit form
```

<!-- stderr -->
```text
error: the following required arguments were not provided:
```

### Generated forms: encode every value

The fragment is trusted markup. Anything that comes from data (file names, Git tags, user
names) must be HTML-encoded before it goes in, with
`[System.Net.WebUtility]::HtmlEncode`. Write the file as UTF-8 without BOM:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }
$version = 'v1.2.3 <rc> & "beta"'
$html = @"
<form id="nhk-form">
  <label>Version <input name="version" required value="$(Enc $version)"></label>
  <label><input type="checkbox" name="publish" value="yes"> Publish now</label>
</form>
"@
$path = Join-Path (Get-Location) 'release.html'
[IO.File]::WriteAllText($path, $html, [System.Text.UTF8Encoding]::new($false))
[Console]::Error.WriteLine(([regex]::Match($html, 'value="[^"]*"')).Value)
nativehtmlkit form --html $path
```

<!-- stderr -->
```text
value="v1.2.3 &lt;rc&gt; &amp; &quot;beta&quot;"
```

## `--title TITLE`

Window title and heading (default `Input form`), 1-128 characters, shown as text:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html --title 'New project'
```

## `--css FILE`

A trusted style sheet added after the built-in one.
[css/form.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/form.css)
lays the form out as a grid of labelled fields:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html --css css/form.css --title 'New project'
```

## `--timeout SECONDS`

A form left open is closed after the deadline, with exit 124 and no output:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
$json = nativehtmlkit form --html sample-form.html --timeout 600
switch ($LASTEXITCODE) {
    0       { $json }
    2       { Write-Warning 'cancelled'; exit 2 }
    124     { Write-Warning 'the form was left open for 10 minutes'; exit 124 }
    default { exit $LASTEXITCODE }
}
```

<!-- stdout -->
```text
WARNING: the form was left open for 10 minutes
```

`Write-Warning` text goes to the warning stream; when a script's output is redirected, as
here, PowerShell writes it to stdout with the `WARNING:` prefix.

## `--host PATH`

<!-- test: exit=124 calls="0@none 124@0x1" -->
```powershell
$coreHost = (nativehtmlkit doctor | Select-String '^Core host: (.+)$').Matches[0].Groups[1].Value
nativehtmlkit form --html sample-form.html --host $coreHost
```

## `--diagnostics LEVEL`

<!-- test: exit=0 calls="124@0x1" -->
```powershell
$log = nativehtmlkit form --html sample-form.html --diagnostics debug 2>&1 | ForEach-Object { "$_" }
($log | Where-Object { $_ -like '*"event":"session.started"*' } | ForEach-Object { ConvertFrom-Json -InputObject $_ }).context.mode
exit 0
```

<!-- stdout -->
```text
form
```

## `--rpc-timeout SECONDS`, `--liveness-interval SECONDS`, `--startup-timeout SECONDS`

Host watchdogs; they never limit the person filling in the form:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html --rpc-timeout 15
```

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html --liveness-interval 15
```

<!-- test: exit=124 calls="124@0x1" -->
```powershell
nativehtmlkit form --html sample-form.html --startup-timeout 30
```

## `-h`, `--help`

<!-- test: exit=0 shim=off -->
```powershell
(nativehtmlkit form --help | Select-String -SimpleMatch -- '--html <HTML>' | Select-Object -Last 1).Line
```

<!-- stdout -->
```text
      --html <HTML>
```

## What the result contains

`entries` are the form's *successful controls* in document order, as HTML form submission
defines them: one `{"kind":"text","name":...,"value":...}` per named, enabled control that
has a value. All values are strings. Unticked checkboxes and radio groups have no entry; a
`<select multiple>` has one entry per chosen option; names may repeat; a file input gives
`{"kind":"file","name":...,"path":...,"filename":...}`. Core checks `required`, `pattern`,
`min`/`max`/`step`, `minlength`/`maxlength` and `type="email"`/`"url"` when the user clicks
Submit; an invalid form stays open with *Some required fields are invalid*. Details:
[form reference](../../reference/form.md).

## Related

[CSS and forms](../css-and-forms.md), [deployment form recipe](../recipes/deploy-form.md),
[tutorial](../tutorial.md).
