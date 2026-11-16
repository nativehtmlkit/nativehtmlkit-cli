#!/usr/bin/env bash
# git-pick: choose a local Git branch in a native window and switch to it (CLI tutorial final code).
#
# Teaches: feeding TSV to `nativehtmlkit select`, reading the selection from stdout, handling every
#          exit status (0 chosen, 2 cancelled, 124 timed out, anything else an error), multi-select
#          with --multi, and keeping the shell script safe with `set -euo pipefail`.
# Run:     bash git-pick.sh [--timeout SECONDS]                 switch to the chosen branch
#          bash git-pick.sh --delete-merged [--timeout SECONDS] delete chosen branches already merged
#          bash git-pick.sh --print                             show the table that would be offered
#          (inside a Git work tree; needs `nativehtmlkit` on PATH)
# Guide:   docs/linux/tutorial-branch-picker.md
set -euo pipefail

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "git-pick: $*" >&2; exit 1; }

mode=switch
select_options=()
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ $# -ge 2 ] || die "--timeout needs a number of seconds"
      select_options+=(--timeout "$2"); shift 2 ;;
    --delete-merged) mode=delete; shift ;;
    --print) mode=print; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "git-pick: unknown option: $1 (try --help)" >&2; exit 64 ;;
  esac
done

command -v nativehtmlkit >/dev/null 2>&1 || die "nativehtmlkit is not on PATH (see the CLI install guide)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a Git repository"
current=$(git symbolic-ref --quiet --short HEAD || echo "(detached HEAD)")

# One TSV row per branch, most recently committed first. The CLI treats a double quote as CSV/TSV
# quoting, so quotes in commit subjects are replaced by apostrophes.
branch_table() {
  printf 'branch\tupdated\tlast commit\n'
  git for-each-ref --sort=-committerdate \
    --format='%(refname:short)%09%(committerdate:relative)%09%(subject)' "$@" | tr '"' "'"
}

# Runs `nativehtmlkit select`, prints the chosen branch names (first column), returns its status.
pick() {
  local title=$1; shift
  local output status
  set +e
  output=$(nativehtmlkit select --input-format tsv --output-format lines --title "$title" \
    "${select_options[@]}" "$@")
  status=$?
  set -e
  case $status in
    0) printf '%s\n' "$output" | cut -f1 ;;
    2) echo "git-pick: cancelled; nothing changed" >&2 ;;
    124) echo "git-pick: no choice made in time; nothing changed" >&2 ;;
    *) echo "git-pick: nativehtmlkit select failed with exit status $status" >&2 ;;
  esac
  return $status
}

case $mode in
  print)
    branch_table refs/heads/
    ;;
  switch)
    branch=$(branch_table refs/heads/ | pick "Switch branch (current: $current)") || exit $?
    [ -n "$branch" ] || die "no branch selected"
    if [ "$branch" = "$current" ]; then
      echo "Already on $branch"
    else
      git switch --quiet -- "$branch"
      echo "Switched to $branch"
    fi
    ;;
  delete)
    if [ -z "$(git for-each-ref --merged HEAD --format='%(refname:short)' refs/heads/ | grep -vxF -- "$current" || true)" ]; then
      echo "No merged branches to delete"
      exit 0
    fi
    # Offer every merged branch except the one you are on (row 1 is the header).
    chosen=$(branch_table --merged HEAD refs/heads/ | awk -F'\t' -v current="$current" 'NR == 1 || $1 != current' \
      | pick "Delete merged branches" --multi) || exit $?
    while IFS= read -r branch; do
      if [ -n "$branch" ]; then
        git branch --quiet -d -- "$branch"
        echo "Deleted $branch"
      fi
    done <<< "$chosen"
    ;;
esac
