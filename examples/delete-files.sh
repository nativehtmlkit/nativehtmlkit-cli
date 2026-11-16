#!/usr/bin/env bash
# delete-files.sh - tick files in a directory, confirm, and delete exactly those files.
#
# Teaches: NUL-safe file lists (find -print0 -> jq), multi-select with JSON output, a second
# `select` as a confirmation dialog whose safe answer is the default, and passing the chosen
# paths to rm NUL-separated so spaces, quotes and newlines in names cannot split them.
#
# Run:   ./delete-files.sh DIRECTORY [GLOB]       e.g. ./delete-files.sh ~/Downloads '*.iso'
# Needs: nativehtmlkit on PATH, GNU find, jq, xargs.
# Exit:  0 deleted or nothing to do, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

dir=${1:?usage: delete-files.sh DIRECTORY [GLOB]}
glob=${2:-*}

# size<TAB>mtime<TAB>path<NUL>; only the path can contain a tab, and it is the last field.
rows=$(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\0' |
  jq -R -s -c 'split("\u0000") | map(select(length > 0) | split("\t") | (.[2:] | join("\t")) as $path | {
      Name: ($path | split("/") | last), "Size (KiB)": ((.[0] | tonumber) / 1024 | ceil),
      Modified: .[1], Path: $path
    }) | sort_by(.Modified) | .[:2000]')     # the CLI shows at most 2,000 rows

if [[ $(jq length <<<"$rows") -eq 0 ]]; then
  echo "delete-files: nothing in $dir matches $glob" >&2
  exit 0
fi

# Run one picker; on anything but a submitted choice, leave without deleting. `pick` runs in
# a command substitution, so its `exit` ends only that subshell; `set -e` then ends the
# script with the same status.
pick() {
  local status=0 out
  out=$(nativehtmlkit select "$@") || status=$?
  case $status in
    0)   printf '%s' "$out" ;;
    2)   echo "delete-files: cancelled, nothing deleted" >&2; exit 2 ;;
    124) echo "delete-files: no decision in time, nothing deleted" >&2; exit 124 ;;
    *)   exit "$status" ;;
  esac
}

picked=$(pick --multi --input-format json --output-format json \
              --title "Files to delete in $(basename -- "$dir")" <<<"$rows")
count=$(jq length <<<"$picked")

answer=$(printf 'No, keep them\nYes, delete %d file(s)\n' "$count" |
         pick --title "Delete $count file(s)?")
if [[ $answer != Yes* ]]; then
  echo "delete-files: kept all files" >&2
  exit 0
fi

jq -j '.[].Path + "\u0000"' <<<"$picked" | xargs -0 rm -v --
