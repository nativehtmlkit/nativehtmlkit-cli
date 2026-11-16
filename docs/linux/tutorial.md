# Tutorial: build a project picker (Linux)

In this tutorial you build `proj`, a small bash tool that remembers project directories and
lets you jump to one by picking it in a native window:

```bash
proj add ~/src/website     # a form asks for name and tags
cd "$(proj pick)"          # a table of projects; pick one, Submit
proj list                  # a read-only table
proj remove                # tick projects, confirm
```

On the way you use all three interactive commands (`select`, `form`, `view`), two input
formats, the exit contract, escaping for trusted HTML, and a stylesheet. The finished script
is [examples/tutorial/proj.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial/proj.sh) (about 100 lines); every step
below is a part of it.

You need: the CLI release extracted and `nativehtmlkit` on `PATH`
([install](index.md#install)), bash 4 or later, and `jq`.

## Step 1: a first picker

`select` reads records from stdin, one per line by default, and prints the chosen one:

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf '%s\n' ~/src/website ~/src/cli ~/notes | nativehtmlkit select --title "Open project"
```

A window lists the three paths with a radio button each. Pick one and press
**Submit selection**: the path is printed and the exit status is 0. Press **Cancel**: nothing
is printed and the status is 2. Try `echo $?` after each.

That is already a usable tool, but a path alone is a poor label, and we want to store more
(a name, tags, the date added).

## Step 2: store projects as JSON lines

Keep one JSON object per line in a file. NDJSON is both easy to append to and an input format
of the CLI, so the file can be piped straight into `select`:

```json
{"name":"website","path":"/home/me/src/website","tags":"work, web","added":"2026-11-16"}
{"name":"cli","path":"/home/me/src/cli","tags":"rust","added":"2026-11-16"}
```

With `--input-format ndjson` the window shows a table with the columns `name`, `path`,
`tags`, `added`. With `--output-format json` the result is a JSON array holding the chosen
record exactly as stored, so `jq` can read any field:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
store=${PROJ_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/proj/projects.ndjson}

cmd_pick() {
  need_projects
  local picked
  picked=$(ui select --input-format ndjson --output-format json --title "Open project" <"$store")
  jq -r '.[0].path' <<<"$picked"
}
```

`select` refuses empty input (exit 1, `no selectable input rows`), so check first:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
die() { echo "proj: $*" >&2; exit 1; }
need_projects() { [[ -s $store ]] || die "no projects yet; add one with: proj add [DIR]"; }
```

## Step 3: one place for the exit contract

Every call of the CLI can end in four ways: 0 (a result on stdout), 2 (Cancel), 124
(`--timeout`), or 1 and others (an error already explained on stderr). Handle that once:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
set -euo pipefail

# ui ARGS... - run the CLI with ARGS and print its result. Cancel and timeout end the
# script with the CLI's status (called inside $(...), so set -e carries the exit through).
ui() {
  local status=0 out
  out=$(nativehtmlkit "$@" "${style[@]}") || status=$?
  case $status in
    0)   printf '%s' "$out" ;;
    2)   exit 2 ;;
    124) echo "proj: no answer in time" >&2; exit 124 ;;
    *)   exit "$status" ;;
  esac
}
```

`ui` is always called as `x=$(ui ...)`. Its `exit` ends only that command substitution, but
the substitution then fails with the same status and `set -e` ends the script with it. So a
cancelled `proj pick` exits 2 and prints nothing, and the caller can tell. (`style` is
filled in step 7; until then define `style=()`.)

## Step 4: add projects with a form

`form --html FILE` shows your own HTML form and prints `{"entries":[...]}` on Submit. The
fragment is *trusted* HTML, so the directory name and path, which come from the file system,
must be escaped before they go into it. `jq`'s `@html` does that:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
esc() { jq -rn --arg s "$1" '$s | @html'; }

cmd_add() {
  local dir result record path
  dir=$(cd -- "${1:-.}" && pwd) || die "no such directory: ${1:-.}"
  html=$(mktemp --suffix=.html)          # global: the EXIT trap runs after this function
  trap 'rm -f -- "$html"' EXIT
  cat >"$html" <<HTML
<form id="nhk-form">
  <p><label>Name <input name="name" required maxlength="60" value="$(esc "$(basename -- "$dir")")"></label></p>
  <p><label>Directory <input name="path" required value="$(esc "$dir")"></label></p>
  <p><label>Tags <input name="tags" placeholder="work, rust" pattern="[A-Za-z0-9 ,_-]*"
         title="letters, digits, spaces, commas, - and _"></label></p>
</form>
HTML
  result=$(ui form --html "$html" --title "Add project")
```

The form element must have `id="nhk-form"`. Core checks `required`, `maxlength` and
`pattern` when the user presses Submit; an invalid form stays open with a message. The
result looks like this:

```json
{"entries":[{"kind":"text","name":"name","value":"website"},{"kind":"text","name":"path","value":"/home/me/src/website"},{"kind":"text","name":"tags","value":"work, web"}]}
```

One `jq` expression turns it into the stored record, then the script checks it:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
  # {"entries":[{"kind":"text","name":"name","value":"..."},...]} -> {"name":"...",...}
  record=$(jq -c --arg added "$(date +%F)" \
             '(.entries | map({(.name): .value}) | add) + {added: $added}' <<<"$result")
  path=$(jq -r '.path' <<<"$record")
  [[ -d $path ]] || die "not a directory: $path"
  mkdir -p -- "$(dirname -- "$store")"
  touch -- "$store"
  if jq -e --arg p "$path" 'select(.path == $p)' "$store" >/dev/null; then
    die "already bookmarked: $path"
  fi
  printf '%s\n' "$record" >>"$store"
  echo "proj: added $path" >&2
}
```

Messages go to stderr; stdout is reserved for results (that is what makes
`cd "$(proj pick)"` work).

## Step 5: list them

`view` shows the same file read-only. It has no result; closing it exits 0:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
cmd_list() {
  need_projects
  ui view --input-format ndjson --title "Projects ($(wc -l <"$store"))" <"$store"
}
```

## Step 6: remove with confirmation

`--multi` turns the radio buttons into checkboxes. `--output-format ndjson` returns the
chosen records one per line, exactly as stored. A second `select` asks for confirmation;
its safe answer is first and nothing is preselected:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
cmd_remove() {
  need_projects
  local picked count answer tmp
  picked=$(ui select --multi --input-format ndjson --output-format ndjson \
             --title "Remove projects" <"$store")
  count=$(wc -l <<<"$picked")
  answer=$(printf 'Keep them\nRemove %d project(s)\n' "$count" |
           ui select --title "Remove $count project(s)?")
  [[ $answer == Remove* ]] || { echo "proj: nothing removed" >&2; return 0; }
  tmp=$(mktemp "$store.XXXXXX")
  jq -c --slurpfile drop <(printf '%s\n' "$picked") \
     'select(.path as $p | any($drop[]; .path == $p) | not)' "$store" >"$tmp"
  mv -- "$tmp" "$store"
  echo "proj: removed $count project(s)" >&2
}
```

The store is rewritten through a temporary file and `mv`, so an interrupted run never
leaves half a file.

## Step 7: give it a look

`--css` adds a stylesheet after the built-in one. The page's colours are CSS custom
properties, so small overrides go a long way
([examples/tutorial/proj.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial/proj.css)):

```css
:root { --accent: #3fa37a; }
h1 { font-size: 18px; letter-spacing: .02em; }
td { color: #dfe7f1; }
button.primary { background: #2f8a63; border-color: #3fa37a; }
```

Pass it on every call through `ui`:

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
style=(--css "$here/proj.css")
```

## Step 8: the command dispatcher

<!-- not-tested: excerpt of examples/tutorial/proj.sh, run in "Try it" below -->
```bash
case ${1:-pick} in
  pick | add | remove | list) cmd_"${1:-pick}" "${@:2}" ;;
  *) echo "usage: proj.sh [pick | add [DIR] | list | remove]" >&2; exit 1 ;;
esac
```

Put the script on your `PATH` as `proj` and add a shell function, because a script cannot
change its caller's directory:

```bash
p() { local dir; dir=$(proj pick) && cd -- "$dir"; }
```

After Cancel, `proj pick` exits 2 with no output and `p` stays where it is.

## Step 9: try it

The examples below run `proj.sh` from the repository's `examples` directory with a store
in the current directory. They were run against the released CLI 0.1.2 by
`scripts/test-docs.py`, headless and with replayed results
([how](index.md#how-the-examples-are-verified)).

Add a project. The form opens with the directory's name and path filled in:

<!-- test: exit=124 calls="124@0x1" -->
```bash
export PROJ_FILE=$PWD/projects.ndjson
./tutorial/proj.sh add /tmp
```

When the user submits it, the record is stored:

<!-- replay: call=1 exit=0 expect=0 -->
```json
{"entries":[{"kind":"text","name":"name","value":"scratch"},{"kind":"text","name":"path","value":"/tmp"},{"kind":"text","name":"tags","value":"temp, demo"}]}
```

<!-- stderr -->
```text
proj: added /tmp
```

Pick one (the store here has two projects):

<!-- test: exit=124 calls="124@2x4" -->
```bash
export PROJ_FILE=$PWD/projects.ndjson
printf '%s\n' '{"name":"scratch","path":"/tmp","tags":"temp","added":"2026-11-16"}' \
               '{"name":"system","path":"/usr","tags":"","added":"2026-11-16"}' > "$PROJ_FILE"
./tutorial/proj.sh pick
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"name":"system","path":"/usr","tags":"","added":"2026-11-16"}]
```

<!-- stdout -->
```text
/usr
```

After Cancel, `proj pick` prints nothing and exits 2, so `cd "$(proj pick)"` and the `p`
function stay where they are:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
```

List and remove:

<!-- test: exit=124 calls="124@2x4" -->
```bash
export PROJ_FILE=$PWD/projects.ndjson
printf '%s\n' '{"name":"scratch","path":"/tmp","tags":"temp","added":"2026-11-16"}' \
               '{"name":"system","path":"/usr","tags":"","added":"2026-11-16"}' > "$PROJ_FILE"
./tutorial/proj.sh list
```

<!-- test: exit=124 calls="124@2x4" -->
```bash
export PROJ_FILE=$PWD/projects.ndjson
printf '%s\n' '{"name":"scratch","path":"/tmp","tags":"temp","added":"2026-11-16"}' \
               '{"name":"system","path":"/usr","tags":"","added":"2026-11-16"}' > "$PROJ_FILE"
./tutorial/proj.sh remove
status=$?
wc -l < "$PROJ_FILE"
exit "$status"
```

<!-- stdout -->
```text
2
```

Tick `scratch`, then confirm with **Remove 1 project(s)**:

<!-- replay: call=1 exit=0 expect=124 -->
```text
{"name":"scratch","path":"/tmp","tags":"temp","added":"2026-11-16"}
```

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
Remove 1 project(s)
```

<!-- stdout -->
```text
1
```

<!-- stderr -->
```text
proj: removed 1 project(s)
```

To test your own tools like this, see
[test your scripts without a desktop](recipes/headless-testing.md).

## Where next

- [Recipes](recipes/index.md): Git branches, files, processes, Docker, APIs, CSV,
  logs, pipelines, forms.
- [Tutorial: a Git branch picker](tutorial-branch-picker.md): TSV input and `--multi`.
- Every option with an example: [select](commands/select.md), [view](commands/view.md),
  [form](commands/form.md); the exact [reference](../REFERENCE.md).
- The same tutorial in PowerShell: [Windows](../windows/tutorial.md).
- [Architecture](../ARCHITECTURE.md): what happens between your pipe and the window.
