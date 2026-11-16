# Exit codes and scripting (Linux)

Every `nativehtmlkit` command reports what happened through its exit status, and only a
successful Submit writes anything to stdout. This page shows how to use that in bash. The
complete specification, including every `error[<code>]`, is the
[exit status reference](../reference/exit-status.md).

| Status | Meaning | stdout | Typical reaction |
|---|---|---|---|
| 0 | submitted (`select`, `form`), closed (`view`), done (`doctor`, `--help`, `--version`) | the result | use it |
| 1 | error: usage, input, host missing or failed; one `nativehtmlkit: error[<code>]: ...` line on stderr | empty | fail |
| 2 | **Cancel**, or the window was closed without submitting | empty | stop quietly, change nothing |
| 124 | `--timeout` expired | empty | stop, maybe say so |
| 130 | SIGINT (Ctrl+C) | empty | stop |
| 143 | SIGTERM | empty | stop |
| 129 | SIGHUP (the terminal went away) | empty | stop |

Usage errors exit 1 (not 2), so 2 always means *the user said no*.

The examples were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](index.md#how-the-examples-are-verified)). Headless, nobody clicks, so windows end
with 124; replayed results show the 0 and 2 paths.

## Capture the status under `set -e`

`var=$(command)` gives `$?` the command's status, but with `set -e` a 2 would end the script
before you could look at it. Capture it explicitly:

<!-- test: exit=124 calls="124@3x1" -->
```bash
set -euo pipefail
status=0
size=$(printf 'small\nmedium\nlarge\n' | nativehtmlkit select --title 'Size' --timeout 60) || status=$?
case $status in
  0)   echo "size: $size" ;;
  2)   echo 'cancelled' >&2; exit 2 ;;
  124) echo 'no answer within 60 s' >&2; exit 124 ;;
  *)   exit "$status" ;;    # the CLI already explained the error on stderr
esac
```

<!-- stderr -->
```text
no answer within 60 s
```

When the user clicks Cancel:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stderr -->
```text
cancelled
```

When the user picks `large`:

<!-- replay: call=1 exit=0 expect=0 -->
```text
large
```

<!-- stdout -->
```text
size: large
```

Inside `$( ... )` the status is the pipeline's: the last command's, or with `pipefail` the
last non-zero one. Both are the CLI's when it is the last command.

## A helper that ends the script on anything but Submit

Its `exit` runs in the command substitution's subshell; `set -e` then ends the script with
the same status, so a cancelled script exits 2 and a timed-out one 124:

<!-- test: exit=124 calls="124@2x1" -->
```bash
set -euo pipefail
choose() {
  local status=0 out
  out=$(nativehtmlkit select "$@") || status=$?
  [[ $status -eq 0 ]] || { echo "${0##*/}: nothing chosen" >&2; exit "$status"; }
  printf '%s' "$out"
}
colour=$(printf 'red\ngreen\n' | choose --title 'Colour')
echo "colour: $colour"
```

After Cancel the script exits 2 without printing anything:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
```

After picking `green`:

<!-- replay: call=1 exit=0 expect=0 -->
```text
green
```

<!-- stdout -->
```text
colour: green
```

## The CLI in the middle of a pipeline: `PIPESTATUS`

A pipeline's status is the last command's. Read the CLI's own status from `PIPESTATUS`
right after the pipeline:

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'a.txt\nb.txt\n' | nativehtmlkit select --multi | xargs -r -d '\n' wc -l
status=("${PIPESTATUS[@]}")        # printf, nativehtmlkit, xargs
case ${status[1]} in
  0)   ;;
  2)   echo 'cancelled' >&2 ;;
  124) echo 'timed out' >&2 ;;
  *)   echo 'selection failed' >&2; exit 1 ;;
esac
```

<!-- stderr -->
```text
timed out
```

After Cancel or a timeout the CLI writes nothing, so `xargs -r` runs nothing. Without
`-r`, GNU `xargs` would run `wc -l` once with no file and read its own stdin.

## Errors: status 1 and the error code

Each failure writes exactly one line `nativehtmlkit: error[<code>]: <message>` to stderr.
stderr also carries the Core host's own log records, so match the line, never parse stderr
for results:

<!-- test: exit=0 calls="1@none" -->
```bash
status=0
printf 'a,b\n1,2,3\n' | nativehtmlkit select --input-format csv 2> err.log || status=$?
code=$(grep -o 'error\[[a-z_.]*\]' err.log | head -n 1)
echo "status $status, $code"
```

<!-- stdout -->
```text
status 1, error[input.invalid]
```

A usage error from the argument parser has no code but also exits 1:

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | nativehtmlkit select --input-format xml
```

<!-- stderr -->
```text
error: invalid value 'xml' for '--input-format <INPUT_FORMAT>'
```

## Write files only after success

`nativehtmlkit select ... > out.csv` creates (or empties) `out.csv` even when the user
cancels. Write to a temporary file and move it into place on 0 only:

<!-- test: exit=124 calls="124@7x7" -->
```bash
tmp=$(mktemp out.csv.XXXXXX)
if nativehtmlkit select --multi --input-format csv --output-format csv < data/servers.csv > "$tmp"; then
  mv -- "$tmp" out.csv
else
  status=$?; rm -f -- "$tmp"; ls out.csv* 2>/dev/null; exit "$status"
fi
```

Nothing is left behind after Cancel or a timeout (the block ended with 124 and listed no
file). [csv-report.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/csv-report.sh)
does the same with a `trap`.

<a id="timeout-is-for-people"></a>

## `--timeout` is for people, not for hangs

Without `--timeout` a window waits as long as the person needs. Add it when an unattended
window must not block a job forever:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'deploy\nskip\n' | nativehtmlkit select --title 'Nightly deploy?' --timeout 900
```

<!-- stderr -->
```text
nativehtmlkit: no decision before the --timeout deadline; the window was closed
```

You do not need `--timeout` against a hung host: the CLI notices that itself (liveness
probes) and exits 1 with `error[host.unresponsive]`
([environment and diagnostics](environment-and-diagnostics.md)).

## Signals: 130, 143, 129

Ctrl+C in the terminal closes the window and exits 130; SIGTERM exits 143, SIGHUP 129.
stdout stays empty, even if the user had just clicked Submit. `timeout --preserve-status`
sends a signal after a delay and returns the command's own status, which shows all three:

<!-- test: exit=0 calls="130@2x1" cli-timeout=60 -->
```bash
printf 'a\nb\n' | timeout --preserve-status -s INT 3 nativehtmlkit select
echo "after SIGINT: $?"
```

<!-- stdout -->
```text
after SIGINT: 130
```

<!-- test: exit=0 calls="143@2x1" cli-timeout=60 -->
```bash
printf 'a\nb\n' | timeout --preserve-status -s TERM 3 nativehtmlkit select
echo "after SIGTERM: $?"
```

<!-- stdout -->
```text
after SIGTERM: 143
```

<!-- test: exit=0 calls="129@2x1" cli-timeout=60 -->
```bash
printf 'a\nb\n' | timeout --preserve-status -s HUP 3 nativehtmlkit select
echo "after SIGHUP: $?"
```

<!-- stdout -->
```text
after SIGHUP: 129
```

A `trap` in your own script runs as usual; the CLI cleans up its window and host itself.

## `view` and `doctor`

`view` has no Cancel: closing it is 0, and 124 is "the deadline closed it". Treat both as
done:

<!-- test: exit=0 calls="124@5x1" -->
```bash
nativehtmlkit view --timeout 120 < data/app.log || [[ $? -eq 124 ]] || exit 1
echo 'carry on'
```

<!-- stdout -->
```text
carry on
```

`doctor` exits 0 or 1 and suits a start-of-script check:

<!-- test: exit=0 calls="0@none" -->
```bash
nativehtmlkit doctor > /dev/null || { echo 'NativeHTMLKit CLI is not installed correctly' >&2; exit 1; }
echo 'ready'
```

<!-- stdout -->
```text
ready
```
