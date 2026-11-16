#!/usr/bin/env bash
# Branch picker tutorial, step 1: offer the local branches in a native list and report the choice.
#
# Teaches: piping lines into `nativehtmlkit select`, capturing stdout, and the exit statuses
#          0 (chosen), 2 (cancelled), 124 (--timeout expired) and anything else (error).
# Run:     bash step1-pick.sh [--timeout SECONDS]     (inside a Git work tree)
# Guide:   docs/linux/tutorial-branch-picker.md (step 1 of 2)
set -euo pipefail

status=0
choice=$(git for-each-ref --format='%(refname:short)' refs/heads/ \
  | nativehtmlkit select --title "Pick a branch" "$@") || status=$?

case $status in
  0) echo "You chose: $choice" ;;
  2) echo "Cancelled" >&2 ;;
  124) echo "No choice made in time" >&2 ;;
  *) echo "nativehtmlkit select failed with exit status $status" >&2 ;;
esac
exit "$status"
