#!/usr/bin/env bash
# kill-process.sh - pick processes from a table, choose the signal, and send it.
#
# Teaches: turning `ps` output into correctly quoted CSV, multi-select over CSV input with
# JSON output (field access by column name), and a second `select` that chooses an action.
#
# Run:   ./kill-process.sh [NAME-FILTER]           e.g. ./kill-process.sh python
# Needs: nativehtmlkit on PATH, procps `ps` (Linux), awk, jq.
# Exit:  0 signal sent, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

filter=${1:-}

# Take the snapshot first, then filter it: a filter running while ps runs would list itself.
listing=$(ps -eo pid=,user=,pcpu=,pmem=,etime=,args= --sort=-pcpu)

# CSV with a header row. The command is the only free-text field; it is quoted and any "
# inside it doubled, as RFC 4180 requires, so the CLI parses it as one cell.
rows=$(awk -v filter="$filter" -v self=$$ '
    BEGIN { print "PID,User,CPU %,Mem %,Running,Command" }
    $1 == self || n >= 500 { next }
    {
      cmd = $6; for (i = 7; i <= NF; i++) cmd = cmd " " $i
      if (filter != "" && index(cmd, filter) == 0) next
      if (length(cmd) > 160) cmd = substr(cmd, 1, 157) "..."
      gsub(/"/, "\"\"", cmd)
      printf "%s,%s,%s,%s,%s,\"%s\"\n", $1, $2, $3, $4, $5, cmd; n++
    }' <<<"$listing")

if [[ $(wc -l <<<"$rows") -le 1 ]]; then
  echo "kill-process: no process matches '${filter}'" >&2
  exit 0
fi

status=0
picked=$(nativehtmlkit select --multi --input-format csv --output-format json \
           --title "Processes to signal" <<<"$rows") || status=$?
[[ $status -eq 0 ]] || { echo "kill-process: nothing signalled" >&2; exit "$status"; }

mapfile -t pids < <(jq -r '.[].PID' <<<"$picked")

status=0
signal=$(printf 'TERM  - ask the process to exit\nINT   - like Ctrl+C\nKILL  - force, cannot be caught\n' |
         nativehtmlkit select --title "Signal for ${#pids[@]} process(es)") || status=$?
[[ $status -eq 0 ]] || { echo "kill-process: nothing signalled" >&2; exit "$status"; }

signal=${signal%% *}
kill -s "$signal" -- "${pids[@]}"
echo "kill-process: sent SIG$signal to ${pids[*]}" >&2
