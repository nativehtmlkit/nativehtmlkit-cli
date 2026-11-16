#!/usr/bin/env bash
# deploy-form.sh - collect deployment parameters in a native form and print them as JSON.
#
# Teaches: generating a trusted `--html` form from a script while escaping every dynamic
# value (jq's @html), Core's HTML constraint validation (required, pattern, min/max,
# type=email, maxlength) that runs before Submit is accepted, parsing the
# {"entries":[...]} result, an extra check in the script, and a confirmation step for
# production.
#
# Run:   ./deploy-form.sh [SERVICE...]            e.g. ./deploy-form.sh api web worker
#        ./deploy-form.sh api web | your-deploy-tool --params -
# Needs: nativehtmlkit on PATH, jq; git (optional, to prefill the version).
# Exit:  0 parameters printed, 2 cancelled, 124 no decision in time, 1 error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
services=("$@")
[[ ${#services[@]} -gt 0 ]] || services=(api web worker)

esc() { jq -rn --arg s "$1" '$s | @html'; }    # escapes & < > " ' for HTML text and attributes

version=$(git describe --tags --abbrev=0 2>/dev/null || echo v1.0.0)

form=$(mktemp --suffix=.html)
trap 'rm -f -- "$form"' EXIT
{
  echo '<form id="nhk-form">'
  echo '<label>Service <select name="service" required><option value="">Choose...</option>'
  for s in "${services[@]}"; do
    printf '<option value="%s">%s</option>' "$(esc "$s")" "$(esc "$s")"
  done
  echo '</select></label>'
  echo '<fieldset><legend>Environment</legend>'
  echo '<label><input type="radio" name="environment" value="staging" required checked> Staging</label>'
  echo '<label><input type="radio" name="environment" value="production"> Production</label>'
  echo '</fieldset>'
  printf '<label>Version <input name="version" required value="%s" pattern="v?[0-9]+\\.[0-9]+\\.[0-9]+" title="a version such as v1.4.2"></label>\n' "$(esc "$version")"
  echo '<label>Replicas <input name="replicas" type="number" min="1" max="20" value="2" required></label>'
  echo '<label>Notify <input name="notify" type="email" placeholder="team@example.com"></label>'
  echo '<label>Change notes <textarea name="notes" maxlength="500" rows="3"></textarea></label>'
  echo '<label class="check"><input type="checkbox" name="dry_run" value="yes" checked> Dry run only</label>'
  echo '</form>'
} >"$form"

status=0
result=$(nativehtmlkit form --html "$form" --css "$here/css/form.css" \
           --title "Deploy" --timeout 600) || status=$?
case $status in
  0)   ;;
  2)   echo "deploy-form: cancelled" >&2; exit 2 ;;
  124) echo "deploy-form: the form was left open for 10 minutes; closed" >&2; exit 124 ;;
  *)   exit "$status" ;;
esac

# {"entries":[{"kind":"text","name":"service","value":"api"}, ...]}: one entry per
# successful control, in document order. An unchecked checkbox has no entry at all.
field() { jq -r --arg n "$1" 'first(.entries[] | select(.name == $n) | .value) // ""' <<<"$result"; }

service=$(field service) environment=$(field environment) version=$(field version)
replicas=$(field replicas) notify=$(field notify) notes=$(field notes)
dry_run=false; [[ $(field dry_run) == yes ]] && dry_run=true

# A rule HTML cannot express: production deploys need change notes.
if [[ $environment == production && -z ${notes//[[:space:]]/} ]]; then
  echo "deploy-form: production deploys need change notes" >&2
  exit 1
fi

if [[ $environment == production && $dry_run == false ]]; then
  status=0
  answer=$(printf 'No, stop here\nYes, deploy %s %s to production\n' "$service" "$version" |
           nativehtmlkit select --title "Really deploy to production?") || status=$?
  [[ $status -eq 0 && $answer == Yes* ]] || { echo "deploy-form: not confirmed" >&2; exit 2; }
fi

jq -n --arg service "$service" --arg environment "$environment" --arg version "$version" \
      --argjson replicas "$replicas" --arg notify "$notify" --arg notes "$notes" \
      --argjson dry_run "$dry_run" \
      '{service: $service, environment: $environment, version: $version, replicas: $replicas,
        notify: (if $notify == "" then null else $notify end), notes: $notes, dry_run: $dry_run}'
