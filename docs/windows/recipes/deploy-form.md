# A deployment form (Windows)

Collect deployment parameters in a form with validation, check a rule HTML cannot express,
ask for confirmation before production, and return the parameters as an object. Script:
[examples/deploy-form.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/deploy-form.ps1) with
[css/form.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/form.css) (`git` optional, to prefill the version).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).
Writing forms in general: [CSS and forms](../css-and-forms.md).

## Run it

<!-- test: exit=124 calls="124@0x1" -->
```powershell
.\deploy-form.ps1 -Service api, web, worker
```

The form offers the services given, *Staging* or *Production*, a version (prefilled from
`git describe`, checked with a `pattern`), replicas (1-20), an optional e-mail address,
change notes and a *Dry run only* checkbox. Service names are HTML-encoded into the form,
so hostile names are harmless:

<!-- test: exit=124 calls="124@0x1" -->
```powershell
.\deploy-form.ps1 -Service '<script>x</script>', 'a"b', "it's&more"
```

After a staging Submit the script returns an object (shown here as JSON):

<!-- test: exit=124 calls="124@0x1" -->
```powershell
$params = .\deploy-form.ps1 -Service api, web
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$params | ConvertTo-Json -Compress
"deploying $($params.service) $($params.version) x$($params.replicas) to $($params.environment)"
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"staging"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":""},{"kind":"text","name":"dry_run","value":"yes"}]}
```

<!-- stdout -->
```text
{"service":"api","environment":"staging","version":"v1.4.2","replicas":3,"notify":null,"notes":"","dry_run":true}
deploying api v1.4.2 x3 to staging
```

Production without change notes is refused by the script (`Write-Error`, exit 1):

<!-- replay: call=1 exit=0 expect=1 -->
```json
{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":"  "}]}
```

<!-- stderr -->
```text
Production deploys need change notes.
```

A real production deploy (no dry run) asks once more in a `select`. Anything but **Yes**
(here: nobody answered in time) stops with exit 2:

<!-- replay: call=1 exit=0 expect=2 -->
```json
{"entries":[{"kind":"text","name":"service","value":"web"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"2.0.0"},{"kind":"text","name":"replicas","value":"4"},{"kind":"text","name":"notify","value":"ops@example.com"},{"kind":"text","name":"notes","value":"Rollout of the new login"}]}
```

<!-- stdout -->
```text
WARNING: Not confirmed.
```

Answering **Yes, deploy web 2.0.0 to production**:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Yes, deploy web 2.0.0 to production
```

<!-- stdout -->
```text
{"service":"web","environment":"production","version":"2.0.0","replicas":4,"notify":"ops@example.com","notes":"Rollout of the new login","dry_run":false}
deploying web 2.0.0 x4 to production
```

## How it works

Every dynamic value is encoded with `HtmlEncode` while the form is built:

<!-- not-tested: excerpt of examples/deploy-form.ps1, which is run above -->
```powershell
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }   # & < > " '
$options = ($Service | ForEach-Object { "<option value=`"$(Enc $_)`">$(Enc $_)</option>" }) -join ''
```

Core validates `required`, `pattern`, `min`/`max` and `type="email"` before it accepts
Submit. The script turns the entries into a hashtable (an unticked checkbox has no entry)
and builds a typed object:

<!-- not-tested: excerpt of examples/deploy-form.ps1, which is run above -->
```powershell
$values = @{}
foreach ($entry in (ConvertFrom-Json -InputObject ($json -join "`n")).entries) {
    if (-not $values.ContainsKey($entry.name)) { $values[$entry.name] = $entry.value }
}
$dryRun = $values.dry_run -eq 'yes'
```

Linux: [A deployment form (Linux)](../../linux/recipes/deploy-form.md).
