# CSS and forms (Linux)

Two options insert **your own trusted content** into the page the CLI generates:
`--css FILE` (every window command) adds a style sheet, and `--html FILE` (`form`) is the
form itself. This page shows how to write both, and how to generate them from data safely.
The generated page, its element ids and the built-in style sheet are documented in
[page structure](../reference/page-structure.md).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](index.md#how-the-examples-are-verified)). How the windows *look* is checked by the
release's GUI qualification, not here.

## Trusted means: written by you

- `--css` and `--html` are inserted verbatim. Write them yourself; never paste data into
  them without escaping it (below).
- Core runs no JavaScript: `<script>` does nothing. Keep the files self-contained: no remote
  fonts, images or `@import` URLs.
- Each file is UTF-8 and at most 256 KiB.
- Do not hide the footer or reuse the CLI's ids (`nhk-form`, `nhk-error`, `nhk-cancel`,
  `nhk-submit`, `nhk-done`, `nhk-selection-form`, `nhk-row-N`): the CLI's buttons are the
  only way to submit.

Data piped into `select` and `view`, and the `--title`, are always escaped by the CLI: they
can never become markup.

## `--css`: themes

The built-in style sheet takes its colours from custom properties on `:root`
(`--background`, `--panel`, `--border`, `--text`, `--accent`); your file comes after it, so
overriding them is enough for most themes. The repository's
[css/light.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/light.css):

```css
:root {
  color-scheme: light;
  --background: #f6f7f9; --panel: #ffffff; --border: #c9d1dc; --text: #1d2430; --accent: #2f6fd0;
}
th { background: #e8edf4; }
tr:hover { background: #eef3fb; }
button.primary { background: #2f6fd0; border-color: #2f6fd0; color: #ffffff; }
.error { color: #b3261e; }
```

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --css css/light.css < data/servers.csv
```

The same file works for `view` and `form`:

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --css css/light.css < data/app.log
```

A small accent change, written on the fly:

<!-- test: exit=124 calls="124@2x1" -->
```bash
cat > accent.css <<'CSS'
:root { --accent: #3fa37a; }
h1 { font-size: 18px; letter-spacing: .02em; }
button.primary { background: #2f8a63; border-color: #3fa37a; }
CSS
printf 'keep\nremove\n' | nativehtmlkit select --css accent.css --title 'Green'
```

Files over 256 KiB, unreadable files and non-UTF-8 files are refused before a window opens:

<!-- test: exit=1 calls="1@none" -->
```bash
head -c 300000 /dev/zero | tr '\0' ' ' > huge.css
echo a | nativehtmlkit select --css huge.css
```

<!-- stderr -->
```text
nativehtmlkit: error[input.invalid]: custom HTML or CSS file exceeds 256 KiB
```

## `--html`: writing a form

The fragment must contain `<form id="nhk-form">`. Put every control inside it and give each
a `name`. Do not add a submit button; the CLI adds **Cancel** and **Submit** below your
fragment. Core validates these constraints when the user clicks Submit and keeps an invalid
form open with *Some required fields are invalid*:

| Attribute / type | Checked |
|---|---|
| `required` | text, `select`, checkbox, radio group |
| `minlength`, `maxlength` | text, `textarea` |
| `pattern` | the whole value must match |
| `type="number"` with `min`, `max`, `step` | number range |
| `type="email"`, `type="url"` | format |
| date/time types with `min`, `max` | range |

A deployment form using most of them (the repository's
[deploy-form.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/deploy-form.sh)
generates this):

<!-- test: exit=124 calls="124@0x1" -->
```bash
cat > deploy.html <<'HTML'
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
  <label class="check"><input type="checkbox" name="dry_run" value="yes" checked> Dry run only</label>
</form>
HTML
nativehtmlkit form --html deploy.html --css css/form.css --title 'Deploy'
```

[css/form.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/form.css)
lays it out as a grid of labelled fields using the page's colour variables:

```css
#nhk-form { display: grid; gap: 12px; max-width: 520px; }
#nhk-form label { display: grid; gap: 4px; }
#nhk-form input:not([type=checkbox]):not([type=radio]), #nhk-form select, #nhk-form textarea {
  background: var(--panel); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 7px 9px; font: inherit;
}
```

## Reading the result

Submit prints one line `{"entries":[...]}`: one entry per named control that has a value, in
document order. All values are strings; an unticked checkbox has **no entry**; an empty
text field is `""`. A `jq` helper reads one field:

<!-- test: exit=124 calls="124@0x1" -->
```bash
result=$(nativehtmlkit form --html sample-form.html) || exit
field() { jq -r --arg n "$1" 'first(.entries[] | select(.name == $n) | .value) // ""' <<<"$result"; }
[[ $(field confirm) == yes ]] || { echo 'not confirmed' >&2; exit 1; }
echo "creating $(field project) for $(field environment)"
```

<!-- replay: call=1 exit=0 expect=1 -->
```json
{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"production"}]}
```

<!-- stderr -->
```text
not confirmed
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"confirm","value":"yes"}]}
```

<!-- stdout -->
```text
creating Demo App for production
```

Rules HTML cannot express (for example "production needs change notes") are checked by the
script after Submit; see the [deployment form recipe](recipes/deploy-form.md).

## Generating a form from data

Anything that comes from outside the script (file names, Git tags, user names, API data)
must be HTML-escaped before it goes into the fragment, or a value such as `<b>` or `"` would
change the markup. `jq`'s `@html` escapes `& < > " '`:

<!-- test: exit=124 calls="124@0x1" -->
```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }
{
  echo '<form id="nhk-form"><p>These files will be deleted:</p><ul>'
  for f in 'a <b>.txt' 'notes & "more".log'; do echo "<li>$(esc "$f")</li>"; done
  echo '</ul><label><input type="checkbox" name="sure" value="yes" required> I understand</label></form>'
} > confirm.html
grep '<li>' confirm.html >&2
nativehtmlkit form --html confirm.html --title 'Confirm deletion' > /dev/null
```

<!-- stderr -->
```text
<li>a &lt;b&gt;.txt</li>
<li>notes &amp; &quot;more&quot;.log</li>
```

Do not use bash `${var//</&lt;}`: in bash 5.2 an unquoted `&` in the replacement means "the
matched text". Python's `html.escape` is a good alternative to `jq`.

Options for a `select` built from data need no escaping: pipe the data in and the CLI
escapes it.

## Related

[form](commands/form.md), [deployment form recipe](recipes/deploy-form.md),
[page structure](../reference/page-structure.md).
