# A deployment form (Linux)

Collect deployment parameters in a form with validation, check a rule HTML cannot express,
ask for confirmation before production, and print the parameters as typed JSON for the
next tool. Script:
[examples/deploy-form.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/deploy-form.sh)
with [css/form.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/form.css)
(needs `jq`; `git` optional, to prefill the version).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)). Writing forms in general:
[CSS and forms](../css-and-forms.md).

## Run it

<!-- test: exit=124 calls="124@0x1" -->
```bash
./deploy-form.sh api web worker
```

The form offers the services given on the command line, *Staging* or *Production*, a
version (prefilled from `git describe`, checked with a `pattern`), replicas (1-20), an
optional e-mail address, change notes and a *Dry run only* checkbox. Service names are
HTML-escaped into the form, so hostile names are harmless:

<!-- test: exit=124 calls="124@0x1" -->
```bash
./deploy-form.sh '<script>x</script>' 'a"b' "it's&more"
```

After a staging Submit the CLI prints the entries, and the script turns them into typed
JSON (numbers as numbers, the checkbox as a boolean, an empty e-mail as `null`):

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"staging"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":""},{"kind":"text","name":"dry_run","value":"yes"}]}
```

<!-- stdout -->
```text
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

Production without change notes is refused by the script (exit 1):

<!-- replay: call=1 exit=0 expect=1 -->
```json
{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":"  "}]}
```

<!-- stderr -->
```text
deploy-form: production deploys need change notes
```

A real production deploy (no dry run) asks once more in a `select`. Anything but **Yes**
(here: nobody answered in time) stops with exit 2:

<!-- replay: call=1 exit=0 expect=2 -->
```json
{"entries":[{"kind":"text","name":"service","value":"web"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"2.0.0"},{"kind":"text","name":"replicas","value":"4"},{"kind":"text","name":"notify","value":"ops@example.com"},{"kind":"text","name":"notes","value":"Rollout of the new login"}]}
```

<!-- stderr -->
```text
deploy-form: not confirmed
```

Answering **Yes, deploy web 2.0.0 to production** prints the parameters:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Yes, deploy web 2.0.0 to production
```

<!-- stdout -->
```text
{
  "service": "web",
  "environment": "production",
  "version": "2.0.0",
  "replicas": 4,
  "notify": "ops@example.com",
  "notes": "Rollout of the new login",
  "dry_run": false
}
```

## How it works

Every dynamic value is escaped with `jq`'s `@html` while the form is written:

<!-- not-tested: excerpt of examples/deploy-form.sh, which is run above -->
```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }    # escapes & < > " ' for HTML text and attributes
for s in "${services[@]}"; do
  printf '<option value="%s">%s</option>' "$(esc "$s")" "$(esc "$s")"
done
printf '<label>Version <input name="version" required value="%s" pattern="v?[0-9]+\\.[0-9]+\\.[0-9]+" title="a version such as v1.4.2"></label>\n' "$(esc "$version")"
```

Core validates `required`, `pattern`, `min`/`max` and `type="email"` before it accepts
Submit. The script reads the entries with one helper; an unticked checkbox has no entry, so
`// ""` supplies the default:

<!-- not-tested: excerpt of examples/deploy-form.sh, which is run above -->
```bash
field() { jq -r --arg n "$1" 'first(.entries[] | select(.name == $n) | .value) // ""' <<<"$result"; }
dry_run=false; [[ $(field dry_run) == yes ]] && dry_run=true
```

Use the output as input for the next step:

<!-- test: exit=124 calls="124@0x1" -->
```bash
params=$(./deploy-form.sh api web) || exit
jq -r '"deploying \(.service) \(.version) x\(.replicas) to \(.environment)"' <<<"$params"
```

Windows: [A deployment form (Windows)](../../windows/recipes/deploy-form.md).
