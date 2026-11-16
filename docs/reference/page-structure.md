# Page structure

The CLI generates the HTML page for each window. `--css` (all commands) and `--html`
(`form`) are inserted into it as **trusted** content, so it helps to know what is there.
This is the 0.1.2 page; ids and classes are not a stable API across versions, but the custom
properties and the `nhk-*` ids below are what the CLI itself relies on.

```html
<!doctype html><html><head><meta charset='utf-8'>
<style> built-in style sheet, then the contents of --css </style></head>
<body><main>
  <h1>escaped --title</h1>

  <!-- select -->
  <form id="nhk-selection-form"><div class="scroll">
    <table><thead><tr><th>Pick</th><th>column...</th></tr></thead>
      <tbody><tr><td><input type="checkbox|radio" id="nhk-row-0" name="selection" value="0"
                     aria-label="Select row 1"></td><td>escaped cell...</td></tr>...</tbody></table>
  </div></form>
  <div class="error" id="nhk-error"></div>
  <footer><button id="nhk-cancel">Cancel</button><button class="primary" id="nhk-submit">Submit selection</button></footer>

  <!-- view, lines input -->
  <section class="scroll"><pre>escaped lines</pre></section>
  <!-- view, other formats: the same <table> without the Pick column -->
  <footer><button class="primary" id="nhk-done">Close</button></footer>

  <!-- form -->
  your --html fragment (must contain <form id="nhk-form">)
  <div class="error" id="nhk-error"></div>
  <footer><button id="nhk-cancel">Cancel</button><button id="nhk-submit" class="primary">Submit</button></footer>
</main></body></html>
```

The window is created 900 x 610 and can be resized; the table area scrolls, the heading and
footer stay visible.

## Built-in style sheet

Colours are custom properties on `:root`, so a theme only has to override them:

```css
:root{color-scheme:dark;--background:#202734;--panel:#2b3444;--border:#4e5b70;--text:#edf2f7;--accent:#6798d5}
body{margin:0;background:var(--background);color:var(--text);font:14px sans-serif}
main{padding:20px;height:100%;display:flex;flex-direction:column}
h1{font-size:20px;margin:0 0 8px;font-weight:600;flex:none}
.scroll{flex:0 1 auto;min-height:0;overflow:auto;border:1px solid var(--border);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:13px}
td,th{padding:9px 12px;border-bottom:1px solid #415068;text-align:left}
th{position:sticky;top:0;background:#344258;z-index:1}  tr:hover{background:#34435a}
footer{display:flex;gap:10px;justify-content:flex-end;margin-top:14px;flex:none}
button{border:1px solid #66768c;border-radius:7px;color:var(--text);padding:9px 18px;background:#39465b;cursor:pointer}
button.primary{background:#2867b4;border-color:#4384d1}
pre{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.45;padding:12px;margin:0}
.error{color:#ffaeae;min-height:22px;flex:none}
input[type=checkbox],input[type=radio]{accent-color:var(--accent)}
```

(abridged; the exact text is `CSS` in `src/render.rs`). `--css` comes after it, so equal
selectors in your file win. [examples/css/light.css](../../examples/css/light.css) is a
complete light theme; [examples/css/form.css](../../examples/css/form.css) lays out a form.

## Rules for trusted content

- `--css` and `--html` are inserted verbatim. Treat them like code: write them yourself, and
  escape every dynamic value you put into a generated `--html` file.
- Core runs no JavaScript; `<script>` does nothing. Do not reference remote resources
  (fonts, images, `@import` URLs): the page is meant to be self-contained.
- Keep the CLI's ids (`nhk-form`, `nhk-error`, `nhk-cancel`, `nhk-submit`, `nhk-done`,
  `nhk-selection-form`, `nhk-row-N`) unique: do not reuse them in your fragment.
- Do not hide the footer: the CLI's buttons are the only way to submit.
- Layout that relies on viewport units (`vh`) follows a resize with Core 1.0.3.
