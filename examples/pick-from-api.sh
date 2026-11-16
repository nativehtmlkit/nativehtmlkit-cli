#!/usr/bin/env bash
# pick-from-api.sh - choose issues from a JSON API response and print their URLs.
#
# Teaches: reshaping nested API JSON with jq into flat rows (one column per key, at most 32),
# keeping a hidden-in-plain-sight key (`url`) for the follow-up step, multi-select with JSON
# output, and printing a pipe-friendly result (one URL per line on stdout).
#
# Run:   curl -fsS 'https://api.github.com/repos/OWNER/REPO/issues?per_page=100' | ./pick-from-api.sh
#        ./pick-from-api.sh data/issues.json          (the sample response in this directory)
# Needs: nativehtmlkit on PATH, jq.
# Exit:  0 printed the chosen URLs, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

source=${1:--}     # a file name, or - for stdin

# GitHub lists pull requests as issues too; they carry a "pull_request" key.
rows=$(jq -c '[.[] | select(has("pull_request") | not) | {
          "#": .number,
          Title: .title,
          Author: .user.login,
          Labels: ([.labels[].name] | join(", ")),
          Updated: .updated_at[:10],
          url: .html_url
        }]' "$source")

if [[ $(jq length <<<"$rows") -eq 0 ]]; then
  echo "pick-from-api: the response contains no issues" >&2
  exit 0
fi

status=0
picked=$(nativehtmlkit select --multi --input-format json --output-format json \
           --title "Open issues" <<<"$rows") || status=$?
[[ $status -eq 0 ]] || exit "$status"

# Records come back exactly as they went in (key order, number text), in input order.
jq -r '.[].url' <<<"$picked"
