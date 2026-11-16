# select: choose rows (Linux)

`nativehtmlkit select` shows the records piped into it as a table with a pick column and
writes the rows the user submits to stdout. This page shows every option of the command
with a bash example. The exact rules are in the
[OS-neutral reference](../../reference/select.md).

```text
nativehtmlkit select [OPTIONS] < records
```

| Outcome | Exit status | stdout |
|---|---|---|
| **Submit selection** | 0 | the chosen rows, in input order |
| **Cancel**, or the window closed | 2 | empty |
| `--timeout` expired | 124 | empty |
| error (bad input or option, no host) | 1 | empty; `nativehtmlkit: error[<code>]: ...` on stderr |

The examples run in the `examples` directory of a clone of this repository, which has the
sample files `data/servers.csv`, `data/issues.json` and `css/light.css`. Each example on
this page was run against the released CLI 0.1.2 by `scripts/test-docs.py`; a "Submit
prints" block shows the exact bytes the released code writes when the user ticks the rows
named above it ([how the examples are verified](../index.md#how-the-examples-are-verified)).

## Without options: one line

stdin is read as lines (`--input-format lines`). The window has one radio button per line;
the chosen line is printed.

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf 'small\nmedium\nlarge\n' | nativehtmlkit select
```

Submit prints, after picking `medium`:

<!-- submit: pick=2 -->
```text
medium
```

Capture it in a variable and check the status. `|| status=$?` keeps `set -e` from ending
the script on Cancel:

<!-- test: exit=0 calls="124@3x1" -->
```bash
status=0
size=$(printf 'small\nmedium\nlarge\n' | nativehtmlkit select) || status=$?
case $status in
  0)   echo "size: $size" ;;
  2)   echo "cancelled" ;;
  124) echo "no answer in time" ;;
  *)   echo "failed with $status" >&2; exit 1 ;;
esac
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
medium
```

After the user picks `medium` the script prints:

<!-- stdout -->
```text
size: medium
```

## `--multi`

Checkboxes instead of radio buttons: any number of rows. The chosen rows come back in
**input order**, whatever order they were ticked in.

<!-- test: exit=124 calls="124@4x1" -->
```bash
printf 'alpha\nbeta\ngamma\ndelta\n' | nativehtmlkit select --multi
```

Submit prints, after ticking `delta`, then `alpha`:

<!-- submit: pick=4,1 -->
```text
alpha
delta
```

Without `--multi`, Submit with nothing picked is refused: the window stays open and says
*select at least one row before submitting*. With `--multi` the same applies:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --multi
```

<!-- submit: pick= rejected=empty -->

## `--allow-empty`

Accept Submit with nothing ticked. stdout is then empty for `lines` (and `ndjson`), `[]`
for `json`, the header line for `csv`/`tsv`. Useful for "also do this" questions where
"nothing" is a valid answer:

<!-- test: exit=124 calls="124@3x1" -->
```bash
extras=$(printf 'clear cache\nrotate logs\nvacuum database\n' |
  nativehtmlkit select --multi --allow-empty --title 'Also run') || exit
printf 'extra: %s\n' $extras
```

Submit with nothing ticked prints nothing and exits 0:

<!-- submit: pick= -->
```text
```

<!-- test: exit=124 calls="124@2x2" -->
```bash
printf 'name,size\na.txt,1\nb.txt,2\n' |
  nativehtmlkit select --multi --allow-empty --input-format csv --output-format json
```

<!-- submit: pick= -->
```json
[]
```

## `--input-format FORMAT`

How stdin is parsed: `lines` (default), `csv`, `tsv`, `json`, `ndjson`. Every format is
shown in detail on [input formats](../input-formats.md).

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit select --input-format csv < data/servers.csv
```

<!-- test: exit=124 calls="124@2x6" -->
```bash
docker ps --all --format '{{json .}}' | jq -c '{Names, Image, State, Status, Ports, ID}' |
  nativehtmlkit select --input-format ndjson
```

## `--no-headers`

For `csv` and `tsv`: the first record is data, and the columns are named `column_1` ...
`column_N`:

<!-- test: exit=124 calls="124@3x2" -->
```bash
printf 'web-01,healthy\nweb-02,degraded\ndb-01,healthy\n' |
  nativehtmlkit select --input-format csv --no-headers --output-format json
```

Submit prints, after picking `web-02`:

<!-- submit: pick=2 -->
```json
[{"column_1":"web-02","column_2":"degraded"}]
```

## `--output-format FORMAT`

What Submit writes: `same` (default: the input format), `lines`, `csv`, `tsv`, `json`,
`ndjson`. Each is shown on [output formats](../output-formats.md). CSV in, JSON out, then
`jq` by column name:

<!-- test: exit=0 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --output-format json < data/servers.csv |
  jq -r '.[].host'
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"host":"web-02","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"degraded","notes":"disk 91% full, cleanup scheduled"},{"host":"db-02","role":"database","region":"us-east","cpu_cores":"16","memory_gib":"128","status":"maintenance","notes":"replica, patching until 18:00"}]
```

The replayed result above is what Submit prints after ticking `web-02` and `db-02`; the
pipeline then prints:

<!-- stdout -->
```text
web-02
db-02
```

<!-- test: exit=124 calls="124@7x7" -->
```bash
nativehtmlkit select --multi --input-format csv --output-format json < data/servers.csv
```

<!-- submit: pick=2,6 -->
```json
[{"host":"web-02","role":"frontend","region":"eu-west","cpu_cores":"4","memory_gib":"8","status":"degraded","notes":"disk 91% full, cleanup scheduled"},{"host":"db-02","role":"database","region":"us-east","cpu_cores":"16","memory_gib":"128","status":"maintenance","notes":"replica, patching until 18:00"}]
```

## `--title TITLE`

The window title and the heading of the page (default `Select an item`). 1 to 128
characters, no control characters; it is shown as text, never as markup:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'main\nfeature/login\n' | nativehtmlkit select --title 'Switch to <branch> & pull'
```

An empty title is refused before any window opens:

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | nativehtmlkit select --title ''
```

<!-- stderr -->
```text
nativehtmlkit: error[usage.invalid]: --title must be nonempty, at most 128 characters, with no control characters
```

## `--css FILE`

A trusted UTF-8 style sheet (at most 256 KiB) added after the built-in one. The page uses
CSS custom properties for its colours, so a theme is a few lines
([CSS and forms](../css-and-forms.md)):

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf 'Europe/Prague\nAmerica/New_York\nAsia/Tokyo\n' |
  nativehtmlkit select --title 'Time zone' --css css/light.css
```

## `--timeout SECONDS`

Give the user a deadline. Without it the window waits as long as it takes. When the
deadline passes the window is closed, stderr says so, stdout stays empty and the exit
status is 124:

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'deploy\nskip\n' | nativehtmlkit select --title 'Deploy now?' --timeout 60
echo "exit status: $?"
```

Nobody answered within the deadline (60 s here; the test uses a shorter one):

<!-- stdout -->
```text
exit status: 124
```

<!-- stderr -->
```text
nativehtmlkit: no decision before the --timeout deadline; the window was closed
```

## `--host PATH`

Use this Core host executable instead of the one beside the CLI. The release archive has
the qualified host next to `nativehtmlkit`, so you only need this for development builds:

<!-- test: exit=124 calls="0@none 124@2x1" -->
```bash
host=$(nativehtmlkit doctor | sed -n 's/^Core host: //p')   # the host found the normal way
printf 'a\nb\n' | nativehtmlkit select --host "$host"
```

A path that does not exist is an error, before anything else happens:

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | nativehtmlkit select --host /opt/missing/nativehtmlkit-host
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: /opt/missing/nativehtmlkit-host
```

## `--diagnostics LEVEL`

`off`, `normal` (default), `debug`, `trace`: structured JSON records about the session on
stderr, separate from the result on stdout
([environment and diagnostics](../environment-and-diagnostics.md)):

<!-- test: exit=0 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --diagnostics debug 2> session.log
jq -rR 'fromjson? | select(.component == "nativehtmlkit-cli") | .event' session.log | grep -x -m1 window.ready
```

<!-- stdout -->
```text
window.ready
```

## `--rpc-timeout SECONDS`

How long the CLI waits for the host to answer one request before it treats the host as
hung (default 30). Lower it for unattended scripts that should fail fast; the person in
front of the window is never affected by it:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --rpc-timeout 10
```

## `--liveness-interval SECONDS`

Idle time between the CLI's "are you alive?" probes to the host while the window is open
(default 5; `0` turns probing off). Together with `--rpc-timeout` it decides how soon a hung
host is noticed:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --liveness-interval 2 --rpc-timeout 5
```

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --liveness-interval 0
```

## `--startup-timeout SECONDS`

How long the host may take to open the window (default 15). Raise it on a slow, loaded
machine:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit select --startup-timeout 60
```

## `-h`, `--help`

<!-- test: exit=0 shim=off -->
```bash
nativehtmlkit select --help | head -n 3
```

<!-- stdout -->
```text
Usage: nativehtmlkit select [OPTIONS]

Options:
```

`-h` prints the same options in one line each.

## Options in any order

Options can come before or after the command name; each may be given once:

<!-- test: exit=124 calls="124@2x1" -->
```bash
printf 'a\nb\n' | nativehtmlkit --rpc-timeout 10 select --multi --allow-empty
```

A repeated or unknown option is a usage error, exit 1:

<!-- test: exit=1 calls="1@none" -->
```bash
echo a | nativehtmlkit select --multi --multi
```

## Related

- [view](view.md), [form](form.md), [doctor](doctor.md)
- [Exit codes and scripting](../exit-codes-and-scripting.md)
- Recipes: [pick a Git branch](../recipes/git-branch.md), [delete files](../recipes/delete-files.md),
  [pipelines and xargs](../recipes/pipelines.md)
