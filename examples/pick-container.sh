#!/usr/bin/env bash
# pick-container.sh - choose a Docker container, then choose what to do with it.
#
# Teaches: NDJSON input (`docker ps --format '{{json .}}'` prints one object per line),
# projecting a wide record down to the columns worth showing, chaining two selections, and
# showing command output in a read-only `view` window.
#
# Run:   ./pick-container.sh
# Needs: nativehtmlkit on PATH, docker, jq, perl.
# Exit:  0 action done, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

# Stop on anything but a submitted choice (Cancel 2, timeout 124, error 1).
choose() {
  local status=0 out
  out=$(nativehtmlkit select "$@") || status=$?
  [[ $status -eq 0 ]] || { echo "pick-container: no action taken" >&2; exit "$status"; }
  printf '%s' "$out"
}

rows=$(docker ps --all --format '{{json .}}' |
       jq -c '{Name: .Names, Image, State, Status, Ports, ID}')
if [[ -z $rows ]]; then
  echo "pick-container: no containers" >&2
  exit 0
fi

container=$(choose --input-format ndjson --output-format json --title "Containers" <<<"$rows")
id=$(jq -r '.[0].ID' <<<"$container")
name=$(jq -r '.[0].Name' <<<"$container")

action=$(printf 'logs\nrestart\nstop\nshell\n' |
         choose --title "Container ${name:0:80}")     # --title allows at most 128 characters

case $action in
  logs)    docker logs --tail 1000 --timestamps "$id" 2>&1 | perl -CSD -pe 's/^(.{400}).+/$1.../' |
             nativehtmlkit view --title "Logs: ${name:0:80}" ;;
  restart) docker restart "$id" ;;
  stop)    docker stop "$id" ;;
  shell)   docker exec -it "$id" sh ;;
esac
