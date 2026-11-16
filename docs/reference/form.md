# `nativehtmlkit form`

Show a trusted HTML form fragment and print its values as JSON when the user submits.

```text
nativehtmlkit form [OPTIONS] --html <HTML>
```

| Option | Default | Meaning |
|---|---|---|
| `--html <PATH>` | required | trusted UTF-8 HTML fragment, at most 256 KiB, containing `<form id="nhk-form">` |
| `--title <TITLE>` | `Input form` | 1-128 characters, no control characters, shown as text |
| `--css <PATH>` | none | trusted UTF-8 CSS file, at most 256 KiB |
| global options | | [global options](global-options.md) |

stdin is not read; `form` has no `--input-format`/`--output-format`.

## The fragment

- The file is inserted as-is into the page body, after the heading and before an error line
  and the buttons **Cancel** and **Submit** that the CLI adds itself
  ([page structure](page-structure.md)). It is **trusted markup**: never paste untrusted text
  into it without HTML-escaping it first (bash: `jq -rn --arg s "$v" '$s|@html'`,
  PowerShell: `[System.Net.WebUtility]::HtmlEncode($v)`).
- It must contain the form element with id `nhk-form`. Before a window opens the CLI checks,
  after removing all whitespace, that the text contains `id="nhk-form"`, `id='nhk-form'` or
  `id=nhk-form`; otherwise: `error[input.invalid]: --html must contain <form id="nhk-form">
  with the controls to submit`, exit 1. (This is a text check, not an HTML parse.)
- Put the controls to submit inside that form and give each a `name`. Do not add your own
  submit button: only the CLI's **Submit** button ends the session.
- The file must be valid UTF-8 (`error[input.invalid]: <path> is not UTF-8: ...`), readable
  (`error[input.invalid]: read <path>: ...`) and at most 256 KiB
  (`custom HTML or CSS file exceeds 256 KiB`). Core runs no scripts; there is no JavaScript.

## Submit, validation and the result

**Submit** asks Core to check the form's HTML constraints (`check_validity` on `nhk-form`).
Core 1.0.3 implements `required` (text, `select`, checkbox, radio group), `minlength`,
`maxlength`, `pattern` (whole-value match), `type="email"`, `type="url"`,
`type="number"` with `min`/`max`/`step`, and the date/time input types with `min`/`max`.
Disabled, read-only and hidden controls are not validated.

- Any constraint fails: the window stays open and shows *Some required fields are invalid*.
- All valid: the window closes and stdout receives **one line**:

```json
{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"development"},{"kind":"text","name":"confirm","value":"yes"}]}
```

That line is the exact result the release's GUI qualification asserts for
[examples/sample-form.html](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/sample-form.html) after typing `Demo App`, keeping
the default environment and ticking the checkbox.

`entries` are Core's *successful controls* in document order, as HTML form submission defines
them: one entry per named, enabled control that contributes a value. A checkbox or radio
button that is not checked has **no entry**, a checked one without a `value` attribute
reports `"on"`; a `<select multiple>` contributes one entry per selected option; buttons
contribute nothing; names may repeat. Each entry is an object with `kind` (`"text"` for
ordinary controls), `name` and `value`. A file input produces
`{"kind":"file","name":...,"path":...,"filename":...}` instead (`"path":null,"filename":""`
when no file was chosen). Parse the line as JSON; do not rely on key order.

| Outcome | Exit | stdout |
|---|---|---|
| Submitted, form valid | 0 | `{"entries":[...]}` and a newline |
| Cancel or window closed | 2 | empty |
| `--timeout` expired | 124 | empty |
| Error (missing/invalid file, no `nhk-form`, host failure) | 1 | empty |

## Reading the result

Parse the line as JSON and look entries up by name: [Linux (bash, `jq`)](../linux/commands/form.md),
[Windows (PowerShell, `ConvertFrom-Json`)](../windows/commands/form.md). Writing and
generating forms safely: CSS and forms ([Linux](../linux/css-and-forms.md),
[Windows](../windows/css-and-forms.md)).
