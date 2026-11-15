# UI, accessibility, interaction and event contract

## v0.1 selection window

- Title bar with CLI-provided title (default `Select items`).
- Optional prompt/instruction text explaining action and single/multi mode.
- Search input (filters all records; filtering never silently clears selections).
- Scrollable semantic HTML table or list with selection controls. A line input displays one label per row. Structured inputs display columns, capped and escaped.
- Footer: count `N selected`, optional `Page X / Y`, Cancel and Submit buttons. Submit disabled until `min..max` selection cardinality is valid.
- Consistent theme with desktop light/dark preferences; CSS in CLI-owned resources, no required UI library dependency.
- On keyboard: arrows navigate among actionable rows, Space selects/toggles, Enter submits only when valid and not inside a multiline editor; Escape cancels. Tab order is deterministic. Ctrl+A in multi mode is a later explicit behavior (must state whether it targets all rows or current filter).
- Multi-select toggles by stable row index; single-select replaces the selected index.
- Search initially case-insensitive substring match; fuzzy matching deferred to P2 or feature flag. Search results must not mutate source order.
- P1 may provide pages with Next/Previous buttons. Pagination is the supported limit-management strategy; advanced virtual scroll is a later performance feature.

## HTML and Core mappings

| Action | Existing host route | Notes |
|---|---|---|
| Initial window | `window.create` | Do not use hidden windows on Wayland |
| Load UI | `document.load` | Generated markup + local CSS, <=1 MiB |
| Ready | `app.ready` | Only after registering event state |
| Checkbox/submit | `document.event` notification | `element` IDs map to stable row index |
| Update count/page/filter | `document.command` `set_text`, `replace_children_html`, `set_attribute` or `batch` | All untrusted text HTML-escaped or set via text API |
| Close / Cancel | `window.before_close`, `app.before_quit` | Commit cancellation receipt before allowing close |
| Quit after Submit | `app.request_quit` | Submit receipt first; no data via host stdout |
| Form validation | `document.command` `check_validity`, `get_form_data` | P3; host does not navigate on submit |

- Native Core events are **post-input notifications**; if preventing default action, register `set_default_action` rules before it occurs. Do not attempt a JS-style synchronous `event.preventDefault()` round-trip.
- Keep the Rust IPC reader thread independent from user-event processing and write calls, so close requests are always serviced while UI logic is busy.
- `window.event` closed/shutdown notifications may arrive while commits are in progress; state transitions must be idempotent.

## Accessibility

- Use semantic `<main>`, `<h1>`, `<label>`, `<table>`/`<thead>`/`<tbody>` or `<ul>` as appropriate.
- Selection control has a real label, not only a CSS checkbox icon. Use `aria-selected` on rows if selection pattern needs it; ensure native keyboard focus remains visible.
- Counts and invalid submission use `aria-live` feedback. Don't rely solely on color.
- Test NVDA/UI Automation on Windows and AT-SPI screen-reader traversal on Linux; automated DOM checks are insufficient.
- Verify the host's accessibility profile and known limitations before claiming WCAG-complete support.

## Styling guidance

- Default neutral/darkish theme with responsive layout, contrast-aware focus rings and compact/comfortable density.
- Keep CSS small and external to generated data. No remote fonts/CDN references. Fall back to system fonts.
- `--theme system|dark|light` affects only theme, not shell pipeline records.
- Custom HTML/CSS is P4, and it remains local trusted source files. Text from stdin must not become HTML templates.

## Forms roadmap

P3 declarative fields: text, textarea, number, checkbox, radio, select/multi-select and password (with explicit sensitive-output policy). Native Core does **not** support `<input type=date/time/color>`; only add those when a custom widget is explicitly implemented and tested. Validation uses existing required/min/max/pattern support where available, plus CLI-level validation and typed coercion.

Form results are JSON objects. File fields, rich editors, wizards, and arbitrary event routing are deferred. If a custom HTML form is introduced, require a known `<form id="nhk-form">` and `name` attributes; a cancel control with id `nhk-cancel`. No inline JS or submit HTTP action is allowed.
