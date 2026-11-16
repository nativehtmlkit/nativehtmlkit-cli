#!/usr/bin/env bash
# csv-report.sh - review a CSV report in a native table, then export only the rows you tick.
#
# Teaches: `view` for read-only tables, `select --input-format csv --output-format csv`
# (the header is written back and every cell is re-quoted as needed), and writing the result
# through a temporary file so a Cancel never leaves a truncated or empty output file behind.
#
# Run:   ./csv-report.sh data/servers.csv [OUTPUT.csv]
#        Without OUTPUT only the viewer is shown.
# Needs: nativehtmlkit on PATH.
# Exit:  0 viewed / exported, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

report=${1:?usage: csv-report.sh REPORT.csv [OUTPUT.csv]}
output=${2:-}
title="Report: $(basename -- "$report")"

if [[ -z $output ]]; then
  # A viewer has no result: closing it exits 0 and prints nothing.
  exec nativehtmlkit view --input-format csv --title "${title:0:128}" <"$report"
fi

tmp=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

status=0
nativehtmlkit select --multi --input-format csv --output-format csv \
  --title "Rows to export" <"$report" >"$tmp" || status=$?
case $status in
  0)   mv -- "$tmp" "$output"
       echo "csv-report: wrote $(( $(wc -l <"$output") - 1 )) row(s) to $output" >&2 ;;
  2)   echo "csv-report: cancelled, $output not written" >&2 ;;
  124) echo "csv-report: no decision in time, $output not written" >&2 ;;
esac
exit "$status"
