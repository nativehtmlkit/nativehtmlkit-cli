# View logs (Linux)

Show a text log in a scrolling, wrapping pane, or JSON lines as a table. `view` has no
result: closing it exits 0. Script:
[examples/view-logs.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/view-logs.sh)
(needs `tail`, `perl`), samples
[data/app.log](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/app.log) and
[data/app.ndjson](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/app.ndjson).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Plain text

<!-- test: exit=124 calls="124@5x1" -->
```bash
./view-logs.sh data/app.log
```

The script shows the last 1,000 lines (`LINES_SHOWN` changes that), each cut to 400
characters. Markup in log lines is shown literally (`<script>` stays text). From stdin:

<!-- test: exit=124 calls="124@1000x1" -->
```bash
for i in $(seq 3000); do printf 'line %d: %0700d\n' "$i" 0; done | ./view-logs.sh -
```

Two limits matter for logs ([limits](../../reference/limits.md)):

- at most **2,000 lines**; more is an error, not a truncation, so use `tail -n`;
- the page must stay under **1 MiB**: 2,000 lines of 500 characters fit, 2,000 of 600 do
  not. Shorten by characters (`perl -CSD` as below), not with `cut -c`, which counts bytes
  and could split a UTF-8 character; invalid UTF-8 is refused.

<!-- test: exit=124 calls="124@5x1" -->
```bash
tail -n 1000 data/app.log | perl -CSD -pe 's/^(.{400}).+/$1.../' | nativehtmlkit view --title 'app.log'
```

The system journal (`journalctl -n` counts entries, and one entry can span lines, so cut
lines too):

<!-- test: exit=124 calls="124@*x1" requires=journalctl -->
```bash
journalctl -n 500 --no-pager | tail -n 2000 | ./view-logs.sh -
```

## JSON lines

<!-- test: exit=124 calls="124@3x7" -->
```bash
./view-logs.sh data/app.ndjson
```

Columns are the union of all keys in order of first appearance (at most 32); nested objects
appear as compact JSON. Never shorten JSON lines (a cut line is invalid JSON); choose
columns with `jq` instead:

<!-- test: exit=124 calls="124@3x3" -->
```bash
tail -n 1000 data/app.ndjson | jq -c '{time, level, msg}' | nativehtmlkit view --input-format ndjson --title 'app.ndjson'
```

Only warnings and errors:

<!-- test: exit=124 calls="124@2x3" -->
```bash
jq -c 'select(.level != "info") | {time, level, msg}' data/app.ndjson | nativehtmlkit view --input-format ndjson
```

## Keep the script going

`view` blocks until the window is closed. Exit 0 (closed) and 124 (`--timeout`) both mean
"done looking":

<!-- test: exit=0 calls="124@5x1" -->
```bash
nativehtmlkit view --timeout 300 --title 'Build log' < data/app.log || [[ $? -eq 124 ]] || exit 1
echo 'next step'
```

<!-- stdout -->
```text
next step
```

To show a log *and* continue at once, start the viewer in the background:

<!-- test: exit=124 calls="124@5x1" -->
```bash
nativehtmlkit view --title 'Build log' < data/app.log &
viewer=$!
echo 'building...'
wait "$viewer"
```

Windows (text files and the Windows event log): [View logs (Windows)](../../windows/recipes/logs.md).
