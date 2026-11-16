#!/usr/bin/env bash
# view-logs.sh - show the end of a log file (plain text or JSON lines) in a native viewer.
#
# Teaches: `view` for plain text (a scrolling, wrapped text pane) and for NDJSON (a table
# with one column per key), and keeping input inside the CLI limits: at most 2,000 rows
# and a generated page of at most 1 MiB, so long lines are shortened first.
#
# Run:   ./view-logs.sh data/app.log
#        ./view-logs.sh data/app.ndjson
#        journalctl -n 500 --no-pager | ./view-logs.sh -
# Needs: nativehtmlkit on PATH, tail, perl.
# Exit:  0 viewer closed, 124 closed by the deadline, 1 error.
set -euo pipefail

file=${1:?usage: view-logs.sh FILE|-}
lines=${LINES_SHOWN:-1000}

if [[ $file == - ]]; then
  name=stdin
else
  name=$(basename -- "$file")
fi

case $file in
  *.ndjson | *.jsonl)
    # JSON lines are not shortened (that would break them); keep the row limit only.
    tail -n "$lines" -- "$file" |
      nativehtmlkit view --input-format ndjson --title "Log: ${name:0:100}" ;;
  *)
    # Shorten by characters, not bytes: cutting bytes could split a UTF-8 sequence, and
    # the CLI refuses input that is not valid UTF-8.
    tail -n "$lines" -- "$file" | perl -CSD -pe 's/^(.{400}).+/$1.../' |
      nativehtmlkit view --title "Log: ${name:0:100}" ;;
esac
