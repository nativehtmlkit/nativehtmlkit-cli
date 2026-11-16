#!/usr/bin/env bash
# proj.sh - a small project-directory bookmark tool, built step by step in
# docs/linux/tutorial.md.
#
# Teaches: one storage format (NDJSON) used directly as CLI input and output, a shared
# wrapper for the exit contract, a generated and escaped form, multi-select with
# confirmation, a read-only table, and a custom stylesheet.
#
# Run:   ./proj.sh add [DIR]      bookmark DIR (default: the current directory)
#        cd "$(./proj.sh pick)"   jump to a bookmarked project
#        ./proj.sh list           show all bookmarks
#        ./proj.sh remove         tick bookmarks to remove, then confirm
# Store: $PROJ_FILE, default ${XDG_CONFIG_HOME:-~/.config}/proj/projects.ndjson
# Needs: nativehtmlkit on PATH, jq.
# Exit:  0 done, 2 cancelled, 124 no answer in time, 1 error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
store=${PROJ_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/proj/projects.ndjson}
style=(--css "$here/proj.css")

die() { echo "proj: $*" >&2; exit 1; }
esc() { jq -rn --arg s "$1" '$s | @html'; }

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

need_projects() { [[ -s $store ]] || die "no projects yet; add one with: proj add [DIR]"; }

cmd_pick() {
  need_projects
  local picked
  picked=$(ui select --input-format ndjson --output-format json --title "Open project" <"$store")
  jq -r '.[0].path' <<<"$picked"
}

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

cmd_list() {
  need_projects
  ui view --input-format ndjson --title "Projects ($(wc -l <"$store"))" <"$store"
}

case ${1:-pick} in
  pick | add | remove | list) cmd_"${1:-pick}" "${@:2}" ;;
  *) echo "usage: proj.sh [pick | add [DIR] | list | remove]" >&2; exit 1 ;;
esac
