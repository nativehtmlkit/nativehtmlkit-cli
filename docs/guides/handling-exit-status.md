# Handle Cancel, timeout and errors

Every `nativehtmlkit` command reports what happened through its exit status, and only a
successful Submit puts anything on stdout:

| Status | Means | Typical reaction |
|---|---|---|
| 0 | submitted / viewer closed | use stdout |
| 2 | the user cancelled or closed the window | stop quietly, change nothing |
| 124 | `--timeout` passed | stop, maybe say so; change nothing |
| 1 | error (bad input, missing host, host failure); `nativehtmlkit: error[<code>]: ...` is on stderr | fail |
| 130 / 143 / 129 | SIGINT / SIGTERM / SIGHUP | stop |

## bash: capture the status without losing it

`var=$(command)` sets `$?` to the command's status, but `set -e` would end the script on 2
before you can look at it. Capture it explicitly:

```bash
status=0
choice=$(printf 'small\nmedium\nlarge\n' | nativehtmlkit select --title 'Size' --timeout 60) || status=$?
case $status in
  0)   echo "size: $choice" ;;
  2)   echo "cancelled" >&2; exit 2 ;;
  124) echo "no answer within 60 s" >&2; exit 124 ;;
  *)   exit "$status" ;;    # the CLI already explained the error on stderr
esac
```

Inside `$( ... )` the status is that of the **last** command of the pipeline, here the CLI.
With `set -o pipefail` it is the last non-zero one, which is still the CLI's when the CLI is
last.

A reusable helper that ends the script on anything but a submit (its `exit` runs in the
command substitution's subshell; `set -e` then ends the script with the same status):

```bash
set -euo pipefail
choose() {
  local status=0 out
  out=$(nativehtmlkit select "$@") || status=$?
  [[ $status -eq 0 ]] || { echo "${0##*/}: nothing chosen" >&2; exit "$status"; }
  printf '%s' "$out"
}
color=$(printf 'red\ngreen\n' | choose --title 'Colour')
```

The examples use this pattern: [delete-files.sh](../../examples/delete-files.sh),
[pick-container.sh](../../examples/pick-container.sh), [proj.sh](../../examples/tutorial/proj.sh).

## bash: the CLI in the middle of a pipeline

When `select` feeds another command, the pipeline's status is the last command's. Read the
CLI's own status from `PIPESTATUS` immediately after the pipeline:

```bash
printf 'a.txt\nb.txt\n' | nativehtmlkit select --multi | xargs -r -d '\n' wc -l
status=("${PIPESTATUS[@]}")        # printf, nativehtmlkit, xargs
case ${status[1]} in
  0)   ;;
  2)   echo "cancelled" >&2 ;;
  124) echo "timed out" >&2 ;;
  *)   echo "selection failed" >&2; exit 1 ;;
esac
```

After Cancel or a timeout the CLI writes nothing, so `xargs -r` runs nothing. Without `-r`,
GNU xargs would run the command once with no arguments. See
[grep-selected.sh](../../examples/grep-selected.sh).

## Never write a file before you know the outcome

`nativehtmlkit select ... > out.csv` creates or truncates `out.csv` even when the user
cancels. Write to a temporary file and move it into place only on 0:

```bash
tmp=$(mktemp out.csv.XXXXXX)
if nativehtmlkit select --multi --input-format csv --output-format csv < report.csv > "$tmp"; then
  mv -- "$tmp" out.csv
else
  status=$?; rm -f -- "$tmp"; exit "$status"
fi
```

([csv-report.sh](../../examples/csv-report.sh) does this with a trap.)

## PowerShell: `$LASTEXITCODE`

A native command's status is in `$LASTEXITCODE`; non-zero is not an exception by default.

```powershell
$choice = 'small', 'medium', 'large' | nativehtmlkit select --title 'Size' --timeout 60
switch ($LASTEXITCODE) {
    0       { "size: $choice" }
    2       { Write-Warning 'Cancelled.'; exit 2 }
    124     { Write-Warning 'No answer within 60 s.'; exit 124 }
    default { exit $LASTEXITCODE }
}
```

Inside a function, `exit` ends the whole script, which makes a helper like this possible:

```powershell
function Invoke-Picker {
    $out = $input | nativehtmlkit @args
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Nothing chosen.'; exit $LASTEXITCODE }
    $out -join "`n"
}
$color = 'red', 'green' | Invoke-Picker select --title 'Colour'
```

Multi-line output arrives as an array of lines; `-join "`n"` turns it back into one string
before `ConvertFrom-Json`.

## Timeouts are for people, not for hangs

Use `--timeout` when an unattended window must not block a job forever (a deploy prompt, a
nightly script on a workstation). You do not need it to protect against a hung host: the CLI
detects that itself and exits 1 with `error[host.unresponsive]`
([global options](../reference/global-options.md#host-watchdogs---rpc-timeout---liveness-interval---startup-timeout)).

## Ctrl+C

Ctrl+C in the terminal closes the window and exits 130 with nothing on stdout; SIGTERM 143,
SIGHUP 129. A trap in your script runs as usual.
