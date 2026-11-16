# Collect input with a form

`nativehtmlkit form --html FILE` shows your HTML form with the CLI's **Cancel** and **Submit**
buttons and prints the values as JSON. Scripts:
[examples/deploy-form.sh](../../examples/deploy-form.sh),
[examples/deploy-form.ps1](../../examples/deploy-form.ps1),
[examples/sample-form.html](../../examples/sample-form.html); reference: [form](../reference/form.md).

## 1. Write the form

```html
<form id="nhk-form">
  <label>Service <select name="service" required>
    <option value="">Choose...</option><option value="api">api</option><option value="web">web</option>
  </select></label>
  <fieldset><legend>Environment</legend>
    <label><input type="radio" name="environment" value="staging" required checked> Staging</label>
    <label><input type="radio" name="environment" value="production"> Production</label>
  </fieldset>
  <label>Version <input name="version" required value="v1.0.0"
         pattern="v?[0-9]+\.[0-9]+\.[0-9]+" title="a version such as v1.4.2"></label>
  <label>Replicas <input name="replicas" type="number" min="1" max="20" value="2" required></label>
  <label>Notify <input name="notify" type="email" placeholder="team@example.com"></label>
  <label>Change notes <textarea name="notes" maxlength="500" rows="3"></textarea></label>
  <label><input type="checkbox" name="dry_run" value="yes" checked> Dry run only</label>
</form>
```

- The form element must have `id="nhk-form"`; every control to return needs a `name`.
- No submit button of your own: the CLI adds the buttons below your fragment.
- Validation runs in Core when the user clicks Submit: `required`, `pattern` (must match the
  whole value), `min`/`max`/`step` on numbers, `type="email"`/`"url"`, `minlength`/`maxlength`.
  An invalid form stays open with *Some required fields are invalid*.
- An empty `<option value="">` plus `required` forces a real choice.

## 2. Generate it safely

The fragment is trusted HTML. Anything dynamic (service names, a default version from Git,
user names) must be escaped, or a value like `<b>` or `"` would change the markup:

```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }     # escapes & < > " ' as entities
version=$(git describe --tags --abbrev=0 2>/dev/null || echo v1.0.0)
printf '<label>Version <input name="version" required value="%s"></label>\n' "$(esc "$version")"
```

```powershell
function Enc([string] $s) { [System.Net.WebUtility]::HtmlEncode($s) }
"<option value=`"$(Enc $name)`">$(Enc $name)</option>"
```

Do not use bash `${var//</&lt;}`: in bash 5.2 an unquoted `&` in the replacement means "the
matched text", so the result would be `<lt;`.

## 3. Run it and handle the outcome

```bash
status=0
result=$(nativehtmlkit form --html "$form" --css css/form.css --title "Deploy" --timeout 600) || status=$?
case $status in
  0)   ;;
  2)   echo "cancelled" >&2; exit 2 ;;
  124) echo "the form was left open for 10 minutes; closed" >&2; exit 124 ;;
  *)   exit "$status" ;;
esac
```

## 4. Parse the result

stdout is one line:

```json
{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"staging"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":""},{"kind":"text","name":"dry_run","value":"yes"}]}
```

All values are strings; an unchecked checkbox has no entry at all; an empty text field is
`""`.

```bash
field() { jq -r --arg n "$1" 'first(.entries[] | select(.name == $n) | .value) // ""' <<<"$result"; }
service=$(field service) environment=$(field environment) replicas=$(field replicas)
dry_run=false; [[ $(field dry_run) == yes ]] && dry_run=true
```

```powershell
$values = @{}
foreach ($entry in (ConvertFrom-Json -InputObject ($json -join "`n")).entries) {
    if (-not $values.ContainsKey($entry.name)) { $values[$entry.name] = $entry.value }
}
$dryRun = $values.dry_run -eq 'yes'
```

## 5. Rules HTML cannot express

Check them in the script after Submit and fail clearly, or ask again:

```bash
if [[ $environment == production && -z ${notes//[[:space:]]/} ]]; then
  echo "deploy-form: production deploys need change notes" >&2
  exit 1
fi
if [[ $environment == production && $dry_run == false ]]; then
  answer=$(printf 'No, stop here\nYes, deploy %s %s to production\n' "$service" "$version" |
           nativehtmlkit select --title "Really deploy to production?") || exit
  [[ $answer == Yes* ]] || exit 2
fi
```

The example then prints the parameters as typed JSON (numbers as numbers, the checkbox as a
boolean) for the next tool:

```bash
./deploy-form.sh api web | jq .
{
  "service": "api",
  "environment": "staging",
  "version": "v1.4.2",
  "replicas": 3,
  "notify": null,
  "notes": "",
  "dry_run": true
}
```

The PowerShell version returns a `[pscustomobject]` with the same properties.

## Styling

`--css` adds your stylesheet after the built-in one. [examples/css/form.css](../../examples/css/form.css)
lays the form out as a grid and styles inputs with the page's colour variables; see
[styling](styling-with-css.md).
