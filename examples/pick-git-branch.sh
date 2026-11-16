#!/usr/bin/env bash
# pick-git-branch.sh - choose a local Git branch in a native window and switch to it.
#
# Teaches: turning tab-separated command output into JSON rows with jq, a single-choice
# `select`, reading one field of the JSON result, and telling Cancel (2) and --timeout (124)
# apart from errors (1).
#
# Run:   ./pick-git-branch.sh [REPOSITORY]        (default: the current directory)
# Needs: nativehtmlkit on PATH, git, jq.
# Exit:  0 switched, 2 cancelled, 124 no choice before the deadline, 1 error.
set -euo pipefail

repo=${1:-.}

# One JSON object per branch, newest first. The subject is the last field, so a tab inside
# it is joined back instead of shifting the columns.
rows=$(git -C "$repo" for-each-ref --sort=-committerdate \
    --format='%(HEAD)%09%(refname:short)%09%(committerdate:relative)%09%(upstream:short)%09%(subject)' \
    refs/heads |
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {
      Current: .[0], Branch: .[1], Updated: .[2], Upstream: .[3], "Last commit": (.[4:] | join("\t"))
    })')

if [[ $(jq length <<<"$rows") -eq 0 ]]; then
  echo "pick-git-branch: no local branches in $repo" >&2
  exit 1
fi

status=0
picked=$(nativehtmlkit select --input-format json --output-format json \
           --title "Switch branch" --timeout 120 <<<"$rows") || status=$?
case $status in
  0)   ;;
  2)   echo "pick-git-branch: cancelled; still on $(git -C "$repo" branch --show-current)" >&2
       exit 2 ;;
  124) echo "pick-git-branch: no branch chosen within 120 s" >&2
       exit 124 ;;
  *)   exit "$status" ;;   # the CLI already printed "nativehtmlkit: error[...]" on stderr
esac

branch=$(jq -r '.[0].Branch' <<<"$picked")
git -C "$repo" switch "$branch"
