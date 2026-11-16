# Style windows with CSS

Every command accepts `--css FILE`: a trusted UTF-8 stylesheet (at most 256 KiB) inserted
after the CLI's built-in one. The structure it styles is documented in
[page structure](../reference/page-structure.md).

## Recolour with the custom properties

The built-in style sheet takes its colours from custom properties on `:root`. Overriding
them is enough for a theme; [examples/css/light.css](../../examples/css/light.css):

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

```bash
./examples/pick-timezone.sh                                  # uses css/light.css
printf 'a\nb\n' | nativehtmlkit select --css examples/css/light.css
```

Header cells, row hover and buttons use fixed colours in the built-in sheet, so a light theme
overrides those rules too.

## Lay out a form

[examples/css/form.css](../../examples/css/form.css) turns `#nhk-form` into a grid of labelled
fields and styles inputs with the page's variables:

```css
#nhk-form { display: grid; gap: 12px; max-width: 520px; }
#nhk-form label { display: grid; gap: 4px; }
#nhk-form input:not([type=checkbox]):not([type=radio]), #nhk-form select, #nhk-form textarea {
  background: var(--panel); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 7px 9px; font: inherit;
}
```

## Small adjustments

```css
/* examples/tutorial/proj.css */
:root { --accent: #3fa37a; }                 /* tick boxes and radio buttons */
h1 { font-size: 18px; letter-spacing: .02em; }
button.primary { background: #2f8a63; border-color: #3fa37a; }
```

## Rules

- CSS is trusted input: write it yourself; do not build it from data.
- Keep it self-contained (no remote fonts, images or `@import` URLs).
- Do not hide `footer` or the `nhk-*` buttons: they are the only way to submit or cancel.
- Viewport units (`vh`) follow window resizes with Core 1.0.3.
- The window opens at 900 x 610; the table area scrolls between the heading and the
  buttons, so a long list never pushes the buttons out of view.
