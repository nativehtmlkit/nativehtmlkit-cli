#!/usr/bin/env bash
# grep-selected.sh - tick files in a window, then search only those files with grep.
#
# Teaches: using `select --multi` as one stage of a pipeline into xargs, and reading the
# CLI's own exit status from PIPESTATUS, because a pipeline's status is normally that of its
# last command (here grep/xargs), which would hide a Cancel or a timeout.
#
# Run:   ./grep-selected.sh PATTERN [DIRECTORY]      e.g. ./grep-selected.sh TODO src
# Needs: nativehtmlkit on PATH, GNU find and xargs (-d), grep.
# Exit:  0 matches found, 1 no match or error, 2 cancelled, 124 no decision in time.
set -uo pipefail     # no -e: every status of the pipeline is inspected below

pattern=${1:?usage: grep-selected.sh PATTERN [DIRECTORY]}
dir=${2:-.}

# `lines` input and output: one path per line. A file name that itself contains a newline
# cannot be represented in this format (use JSON or NDJSON for such names).
find "$dir" -type f -not -path '*/.git/*' -size -2M | sort | head -n 2000 |
  nativehtmlkit select --multi --title "Search for: ${pattern:0:100}" |
  xargs -r -d '\n' grep -n -H -e "$pattern" --
status=("${PIPESTATUS[@]}")      # find, sort, head, nativehtmlkit, xargs

case ${status[3]} in
  0)   [[ ${status[4]} -eq 0 ]] && exit 0 || exit 1 ;;   # xargs: 123 = grep found nothing
  2)   echo "grep-selected: cancelled" >&2; exit 2 ;;
  124) echo "grep-selected: no files chosen in time" >&2; exit 124 ;;
  *)   exit 1 ;;
esac
