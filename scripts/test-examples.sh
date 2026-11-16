#!/usr/bin/env bash
# Verify examples/*.sh, the tutorial and the documented input/limit/exit contract against a
# real nativehtmlkit CLI and its Core host, without a desktop.
#
#   scripts/test-examples.sh [--cli PATH] [--timeout SECONDS] [--keep] [FILTER]
#
# --cli      the nativehtmlkit executable to test (default: $NATIVEHTMLKIT_CLI, then PATH);
#            its Core host is found the normal way (--host is not used, so beside the CLI).
# --timeout  deadline given to every CLI call (default 0.5).
# FILTER     run only the cases whose name contains FILTER.
#
# How it works. `NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` (a test-only switch, tests/README.md)
# makes the real host run the whole protocol without a window. Nobody can click, so every
# call ends by its --timeout: a shim named `nativehtmlkit` placed first on PATH replaces any
# --timeout of the example with a short one, runs the real CLI at debug diagnostics and
# records exit status, stdout size and the parsed rows x columns of each call. A case
# asserts that each call was accepted, rendered and ended with exit 124 and empty stdout,
# that the example itself exited with the documented status and made no side effect.
#
# "Replay" cases then check what an example does with a submitted result: the real CLI still
# runs (and must end with 124, proving its input was accepted) but the shim hands the example
# a recorded result instead, in the exact format the GUI qualification suites assert
# (tests/gui/). They prove the example's parsing and side effects, not the GUI.
#
# Exit status 0 only when every case passed. Nothing outside the work directory is changed,
# except that the kill-process cases start and signal a `sleep` process of their own.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EX=$ROOT/examples
CLI=${NATIVEHTMLKIT_CLI:-$(command -v nativehtmlkit || true)}
T=0.5
KEEP=0
FILTER=
while [[ $# -gt 0 ]]; do
  case $1 in
    --cli) CLI=$2; shift 2 ;;
    --timeout) T=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) FILTER=$1; shift ;;
  esac
done
[[ -n $CLI && -x $CLI ]] || { echo "test-examples: no nativehtmlkit executable (use --cli PATH)" >&2; exit 1; }
CLI=$(realpath -- "$CLI")
for tool in jq git perl find xargs; do
  command -v "$tool" >/dev/null || { echo "test-examples: $tool is required" >&2; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nhk-examples.XXXXXX")
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/tmp" "$WORK/cases"
RESULTS=$WORK/results.tsv
PASS=0 FAIL=0 SKIP=0

# ---- the shim ----------------------------------------------------------------------------
cat >"$WORK/bin/nativehtmlkit" <<'SHIM'
#!/usr/bin/env bash
args=() skip=0
for a in "$@"; do
  if ((skip)); then skip=0; continue; fi
  case $a in
    --timeout) skip=1 ;;
    --timeout=*) ;;
    *) args+=("$a") ;;
  esac
done
d=$NHK_SHIM_DIR
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/count"
printf '%q ' "${args[@]}" >"$d/$n.args"
NATIVEHTMLKIT_DIAGNOSTICS=debug "$NHK_REAL" "${args[@]}" --timeout "$NHK_T" >"$d/$n.out" 2>"$d/$n.err"
rc=$?
cat "$d/$n.err" >&2       # stderr still reaches the caller (after the call)
shape=$(grep -o '"event":"session.started","context":{[^}]*}' "$d/$n.err" |
        sed -E 's/.*"rows":([0-9]+),"columns":([0-9]+).*/\1x\2/')
echo "$rc@${shape:-none} $(wc -c <"$d/$n.out")" >>"$d/calls"
if [[ -f $d/replay/$n.rc ]]; then
  cat "$d/replay/$n.out"
  exit "$(cat "$d/replay/$n.rc")"
fi
cat "$d/$n.out"
exit "$rc"
SHIM
chmod +x "$WORK/bin/nativehtmlkit"
ln -s nativehtmlkit "$WORK/bin/nhk"

# A stand-in for docker: lists two containers and records every other command.
cat >"$WORK/fakebin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER_LOG"
case $1 in
  ps)
    printf '%s\n' \
      '{"Command":"\"/docker-entrypoint.sh nginx\"","CreatedAt":"2026-11-16 09:00:00 +0000 UTC","ID":"3f2a9c1d7b44","Image":"nginx:1.27","Labels":"","LocalVolumes":"0","Mounts":"","Names":"web","Networks":"bridge","Ports":"0.0.0.0:8080->80/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}' \
      '{"Command":"\"docker-entrypoint.sh postgres\"","CreatedAt":"2026-11-15 18:00:00 +0000 UTC","ID":"9b8e7d6c5a43","Image":"postgres:17","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"db <primary>","Networks":"bridge","Ports":"5432/tcp","RunningFor":"17 hours ago","Size":"0B","State":"exited","Status":"Exited (0) 3 minutes ago"}' ;;
  logs) printf '2026-11-16T09:00:00Z ready\n2026-11-16T09:00:01Z <b>not markup</b> & more\n' ;;
esac
DOCKER
chmod +x "$WORK/fakebin/docker"

export NHK_REAL=$CLI NHK_T=$T NATIVEHTMLKIT_CLI_TEST_HEADLESS=1 TMPDIR=$WORK/tmp
export PATH="$WORK/bin:$PATH"
unset NATIVEHTMLKIT_DIAGNOSTICS NATIVEHTMLKIT_HOST_BINARY

# ---- case helpers ------------------------------------------------------------------------
CASE= CDIR= ACTIVE=0
record() {  # record STATUS NAME DETAIL
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$RESULTS"
  case $1 in PASS) PASS=$((PASS + 1)) ;; FAIL) FAIL=$((FAIL + 1)) ;; SKIP) SKIP=$((SKIP + 1)) ;; esac
}
begin() {  # begin NAME
  CASE=$1 CDIR=$WORK/cases/$1 ACTIVE=1
  if [[ -n $FILTER && $CASE != *"$FILTER"* ]]; then ACTIVE=0; return; fi
  mkdir -p "$CDIR/replay"; : >"$CDIR/calls"
  export NHK_SHIM_DIR=$CDIR FAKE_DOCKER_LOG=$CDIR/docker.log
}
skip() { ((ACTIVE)) && record SKIP "$CASE" "$1"; ACTIVE=0; }
replay() {  # replay CALL-NUMBER EXIT-STATUS STDOUT-TEXT
  ((ACTIVE)) || return 0
  printf '%s' "$2" >"$CDIR/replay/$1.rc"
  printf '%b' "$3" >"$CDIR/replay/$1.out"
}
# go WANT-STATUS "CALLS" COMMAND...   CALLS: one "status@ROWSxCOLUMNS" per CLI call, in order
# ("124@3x6"); a call that never reached the host has shape "none"; * matches anything.
go() {
  ((ACTIVE)) || return 0
  local want=$1 calls=$2 rc; shift 2
  printf '%s\n' "$*" >>"$WORK/invoked"
  (cd "$EX" && "$@") >"$CDIR/stdout" 2>"$CDIR/stderr" </dev/null
  rc=$?
  local got; got=$(cut -d' ' -f1 "$CDIR/calls" 2>/dev/null | paste -sd' ')
  local problems=()
  [[ $rc == "$want" ]] || problems+=("exit $rc, want $want")
  # shellcheck disable=SC2053  # CALLS may contain * for host-dependent row counts
  [[ $got == $calls ]] || problems+=("calls '$got', want '$calls'")
  local n=0 line
  while read -r line; do
    n=$((n + 1))
    local status=${line%%@*} bytes=${line##* }
    if [[ ! -f $CDIR/replay/$n.rc && $status != 0 && $bytes != 0 ]]; then
      problems+=("call $n wrote $bytes bytes to stdout with exit $status")
    fi
    if [[ $status == 124 ]] && grep -q 'error\[' "$CDIR/$n.err"; then
      problems+=("call $n: error line despite exit 124")
    fi
    if [[ $status == 124 ]] && ! grep -q '"event":"window.ready"' "$CDIR/$n.err"; then
      problems+=("call $n: the document never became ready")
    fi
  done <"$CDIR/calls" 2>/dev/null
  if ((${#problems[@]})); then
    record FAIL "$CASE" "$(IFS=';'; echo "${problems[*]}")"
  else
    record PASS "$CASE" "exit $rc; calls: ${got:-none}"
  fi
}
check() {  # check DESCRIPTION COMMAND...
  local what=$1; shift
  ((ACTIVE)) || return 0
  if (cd "$EX" && "$@") >/dev/null 2>&1; then record PASS "$CASE: $what" ok
  else record FAIL "$CASE: $what" "check failed"; fi
}
stdout_is() { check "stdout is exactly the expected text" bash -c 'diff <(printf "%b" "$1") "$2"' _ "$1" "$CDIR/stdout"; }
error_code() { check "stderr names error[$1]" grep -qF "error[$1]" "$CDIR/1.err"; }
stderr_has() { check "stderr says: $1" grep -qF -- "$1" "$CDIR/1.err"; }

# ---- fixtures ----------------------------------------------------------------------------
FIX=$WORK/fixtures
mkdir -p "$FIX/files" "$FIX/grep" "$FIX/store"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.invalid
export GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.invalid
git init -q -b main "$FIX/repo"
git -C "$FIX/repo" commit -q --allow-empty -m 'initial commit'
git -C "$FIX/repo" branch feature/login
git -C "$FIX/repo" branch 'fix-"quotes"&<tags>'
make_files() {
  rm -rf "$FIX/files"; mkdir -p "$FIX/files"
  printf 'one\n' >"$FIX/files/a b.txt"
  printf 'two\n' >"$FIX/files/it's \"quoted\".log"
  printf 'three\n' >"$FIX/files/new"$'\n'"line.txt"
}
printf 'alpha TODO\n' >"$FIX/grep/one.txt"
printf 'nothing here\n' >"$FIX/grep/two.txt"
printf 'x\n%.0s' $(seq 2001) >"$FIX/rows2001.txt"

# ---- examples: headless (every call ends by the deadline) --------------------------------
begin git-branch-headless
go 124 "124@3x5" ./pick-git-branch.sh "$FIX/repo"
check "branch unchanged" test "$(git -C "$FIX/repo" branch --show-current)" = main

begin git-branch-replay-submit
replay 1 0 '[{"Current":" ","Branch":"feature/login","Updated":"1 second ago","Upstream":"","Last commit":"initial commit"}]\n'
go 0 "124@3x5" ./pick-git-branch.sh "$FIX/repo"
check "switched to the chosen branch" test "$(git -C "$FIX/repo" branch --show-current)" = feature/login
git -C "$FIX/repo" switch -q main

begin git-branch-replay-cancel
replay 1 2 ''
go 2 "124@3x5" ./pick-git-branch.sh "$FIX/repo"
check "branch unchanged" test "$(git -C "$FIX/repo" branch --show-current)" = main

make_files
begin delete-files-headless
go 124 "124@3x4" ./delete-files.sh "$FIX/files"
check "all three files still exist" bash -c '[[ $(find "$1" -type f -printf x | wc -c) == 3 ]]' _ "$FIX/files"

begin delete-files-replay-confirm
replay 1 0 "[{\"Name\":\"a b.txt\",\"Size (KiB)\":1,\"Modified\":\"2026-11-16 09:00\",\"Path\":\"$FIX/files/a b.txt\"},{\"Name\":\"new\\\\nline.txt\",\"Size (KiB)\":1,\"Modified\":\"2026-11-16 09:00\",\"Path\":\"$FIX/files/new\\\\nline.txt\"}]\n"
replay 2 0 'Yes, delete 2 file(s)\n'
go 0 "124@3x4 124@2x1" ./delete-files.sh "$FIX/files"
check "exactly the two chosen files were deleted" bash -c '[[ $(find "$1" -type f -printf x | wc -c) == 1 && -f "$1/it'"'"'s \"quoted\".log" ]]' _ "$FIX/files"

make_files
begin delete-files-replay-keep
replay 1 0 "[{\"Name\":\"a b.txt\",\"Size (KiB)\":1,\"Modified\":\"2026-11-16 09:00\",\"Path\":\"$FIX/files/a b.txt\"}]\n"
replay 2 0 'No, keep them\n'
go 0 "124@3x4 124@2x1" ./delete-files.sh "$FIX/files"
check "nothing deleted" bash -c '[[ $(find "$1" -type f -printf x | wc -c) == 3 ]]' _ "$FIX/files"

begin delete-files-replay-cancel-confirm
replay 1 0 "[{\"Name\":\"a b.txt\",\"Size (KiB)\":1,\"Modified\":\"2026-11-16 09:00\",\"Path\":\"$FIX/files/a b.txt\"}]\n"
replay 2 2 ''
go 2 "124@3x4 124@2x1" ./delete-files.sh "$FIX/files"
check "nothing deleted" bash -c '[[ $(find "$1" -type f -printf x | wc -c) == 3 ]]' _ "$FIX/files"

begin delete-files-nothing-matches
go 0 "" ./delete-files.sh "$FIX/files" '*.none'

if command -v ps >/dev/null && ps -eo pid=,args= >/dev/null 2>&1; then
  bash -c 'exec -a nhk-example-sleeper sleep 300' &
  SLEEPER=$!
  sleep 0.3
  begin kill-process-headless
  go 124 "124@1x6" ./kill-process.sh nhk-example-sleeper
  check "process still running" kill -0 "$SLEEPER"
  begin kill-process-replay-term
  replay 1 0 "[{\"PID\":\"$SLEEPER\",\"User\":\"$(id -un)\",\"CPU %\":\"0.0\",\"Mem %\":\"0.0\",\"Running\":\"00:01\",\"Command\":\"nhk-example-sleeper 300\"}]\n"
  replay 2 0 'TERM  - ask the process to exit\n'
  go 0 "124@1x6 124@3x1" ./kill-process.sh nhk-example-sleeper
  check "process was terminated" bash -c 'sleep 0.3; ! kill -0 "$1"' _ "$SLEEPER"
  kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
else
  begin kill-process; skip "procps ps not available"
fi

export PATH="$WORK/fakebin:$PATH"
begin container-headless
go 124 "124@2x6" ./pick-container.sh
check "docker was only asked to list" bash -c '[[ $(cat "$1") == "ps --all --format {{json .}}" ]]' _ "$CDIR/docker.log"
begin container-replay-restart
replay 1 0 '[{"Name":"web","Image":"nginx:1.27","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp","ID":"3f2a9c1d7b44"}]\n'
replay 2 0 'restart\n'
go 0 "124@2x6 124@4x1" ./pick-container.sh
check "docker restart got the chosen id" grep -qx 'restart 3f2a9c1d7b44' "$CDIR/docker.log"
begin container-replay-logs-view
replay 1 0 '[{"Name":"db <primary>","Image":"postgres:17","State":"exited","Status":"Exited (0) 3 minutes ago","Ports":"5432/tcp","ID":"9b8e7d6c5a43"}]\n'
replay 2 0 'logs\n'
go 124 "124@2x6 124@4x1 124@2x1" ./pick-container.sh
check "logs were read for the chosen id" grep -q '^logs --tail 1000 --timestamps 9b8e7d6c5a43$' "$CDIR/docker.log"
export PATH="${PATH#"$WORK/fakebin:"}"

begin api-headless
go 124 "124@3x6" ./pick-from-api.sh data/issues.json
stdout_is ''
begin api-stdin-headless
go 124 "124@3x6" bash -c './pick-from-api.sh < data/issues.json'
begin api-replay-submit
replay 1 0 '[{"#":42,"Title":"Window opens off-screen on a second monitor","Author":"ada","Labels":"bug, windows","Updated":"2026-11-12","url":"https://example.invalid/issues/42"},{"#":39,"Title":"x","Author":"zo\\u00eb","Labels":"i18n","Updated":"2026-11-01","url":"https://example.invalid/issues/39"}]\n'
go 0 "124@3x6" ./pick-from-api.sh data/issues.json
stdout_is 'https://example.invalid/issues/42\nhttps://example.invalid/issues/39\n'

begin csv-report-view
go 124 "124@7x7" ./csv-report.sh data/servers.csv
begin csv-report-export-headless
go 124 "124@7x7" ./csv-report.sh data/servers.csv "$FIX/subset.csv"
check "no output file and no temporary file left" bash -c '! ls "$1"* >/dev/null 2>&1' _ "$FIX/subset.csv"
begin csv-report-export-replay
replay 1 0 'host,role,region,cpu_cores,memory_gib,status,notes\nweb-02,frontend,eu-west,4,8,degraded,"disk 91% full, cleanup scheduled"\n'
go 0 "124@7x7" ./csv-report.sh data/servers.csv "$FIX/subset.csv"
check "output file holds the header and the chosen row" bash -c '[[ $(wc -l <"$1") == 2 ]] && grep -q "^web-02," "$1"' _ "$FIX/subset.csv"

begin grep-selected-headless
go 124 "124@2x1" ./grep-selected.sh TODO "$FIX/grep"
begin grep-selected-replay
replay 1 0 "$FIX/grep/one.txt\n$FIX/grep/two.txt\n"
go 0 "124@2x1" ./grep-selected.sh TODO "$FIX/grep"
stdout_is "$FIX/grep/one.txt:1:alpha TODO\n"
begin grep-selected-replay-no-match
replay 1 0 "$FIX/grep/two.txt\n"
go 1 "124@2x1" ./grep-selected.sh TODO "$FIX/grep"
begin grep-selected-replay-cancel
replay 1 2 ''
go 2 "124@2x1" ./grep-selected.sh TODO "$FIX/grep"

begin view-logs-text
go 124 "124@5x1" ./view-logs.sh data/app.log
begin view-logs-ndjson
go 124 "124@3x7" ./view-logs.sh data/app.ndjson
begin view-logs-stdin-long-lines
go 124 "124@1000x1" bash -c 'for i in $(seq 2000); do printf "%0700d ž\n" "$i"; done | ./view-logs.sh -'
begin view-logs-replay-closed
replay 1 0 ''
go 0 "124@5x1" ./view-logs.sh data/app.log

begin deploy-form-headless
go 124 "124@0x1" ./deploy-form.sh api web
begin deploy-form-hostile-service-names
go 124 "124@0x1" ./deploy-form.sh '<script>x</script>' 'a"b' "it's&more"
begin deploy-form-replay-staging
replay 1 0 '{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"staging"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":""},{"kind":"text","name":"dry_run","value":"yes"}]}\n'
go 0 "124@0x1" ./deploy-form.sh api web
stdout_is '{\n  "service": "api",\n  "environment": "staging",\n  "version": "v1.4.2",\n  "replicas": 3,\n  "notify": null,\n  "notes": "",\n  "dry_run": true\n}\n'
begin deploy-form-replay-production-needs-notes
replay 1 0 '{"entries":[{"kind":"text","name":"service","value":"api"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"v1.4.2"},{"kind":"text","name":"replicas","value":"3"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":"  "}]}\n'
go 1 "124@0x1" ./deploy-form.sh api
begin deploy-form-replay-production-confirmed
replay 1 0 '{"entries":[{"kind":"text","name":"service","value":"web"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"2.0.0"},{"kind":"text","name":"replicas","value":"4"},{"kind":"text","name":"notify","value":"ops@example.com"},{"kind":"text","name":"notes","value":"Rollout of the new login"}]}\n'
replay 2 0 'Yes, deploy web 2.0.0 to production\n'
go 0 "124@0x1 124@2x1" ./deploy-form.sh web
check "parameters printed with dry_run false" bash -c 'jq -e ".dry_run == false and .replicas == 4 and .notify == \"ops@example.com\"" "$1"' _ "$CDIR/stdout"
begin deploy-form-replay-production-declined
replay 1 0 '{"entries":[{"kind":"text","name":"service","value":"web"},{"kind":"text","name":"environment","value":"production"},{"kind":"text","name":"version","value":"2.0.0"},{"kind":"text","name":"replicas","value":"4"},{"kind":"text","name":"notify","value":""},{"kind":"text","name":"notes","value":"x"}]}\n'
replay 2 0 'No, stop here\n'
go 2 "124@0x1 124@2x1" ./deploy-form.sh web
stdout_is ''

if timedatectl list-timezones >/dev/null 2>&1 || [[ -d /usr/share/zoneinfo ]]; then
  begin timezone-light-css
  ZONES=$( (timedatectl list-timezones 2>/dev/null || (cd /usr/share/zoneinfo && find . -type f -name '[A-Z]*' | sed 's|^\./||' | grep '/' | grep -v '^right/\|^posix/')) | head -n 2000 | wc -l)
  go 124 "124@${ZONES}x1" ./pick-timezone.sh
else
  begin timezone-light-css; skip "no time zone list on this system"
fi

begin sample-form
go 124 "124@0x1" nativehtmlkit form --html sample-form.html

# ---- tutorial ----------------------------------------------------------------------------
export PROJ_FILE=$FIX/store/projects.ndjson
begin tutorial-step1-lines
go 124 "124@3x1" bash -c 'printf "%s\n" ~/src/website ~/src/cli ~/notes | nativehtmlkit select --title "Open project"'
begin tutorial-pick-empty-store
go 1 "" ./tutorial/proj.sh pick
begin tutorial-add-headless
go 124 "124@0x1" ./tutorial/proj.sh add "$FIX/repo"
check "store unchanged" test ! -s "$PROJ_FILE"
begin tutorial-add-replay
replay 1 0 "{\"entries\":[{\"kind\":\"text\",\"name\":\"name\",\"value\":\"repo\"},{\"kind\":\"text\",\"name\":\"path\",\"value\":\"$FIX/repo\"},{\"kind\":\"text\",\"name\":\"tags\",\"value\":\"git, demo\"}]}\n"
go 0 "124@0x1" ./tutorial/proj.sh add "$FIX/repo"
check "one record stored" bash -c 'jq -e --arg p "$2" "select(.name == \"repo\" and .path == \$p and .tags == \"git, demo\" and (.added | length) == 10)" "$1"' _ "$PROJ_FILE" "$FIX/repo"
begin tutorial-add-second-replay
replay 1 0 "{\"entries\":[{\"kind\":\"text\",\"name\":\"name\",\"value\":\"files <tmp>\"},{\"kind\":\"text\",\"name\":\"path\",\"value\":\"$FIX/files\"},{\"kind\":\"text\",\"name\":\"tags\",\"value\":\"\"}]}\n"
go 0 "124@0x1" ./tutorial/proj.sh add "$FIX/files"
begin tutorial-add-duplicate
replay 1 0 "{\"entries\":[{\"kind\":\"text\",\"name\":\"name\",\"value\":\"again\"},{\"kind\":\"text\",\"name\":\"path\",\"value\":\"$FIX/repo\"},{\"kind\":\"text\",\"name\":\"tags\",\"value\":\"\"}]}\n"
go 1 "124@0x1" ./tutorial/proj.sh add "$FIX/repo"
check "still two records" bash -c '[[ $(wc -l <"$1") == 2 ]]' _ "$PROJ_FILE"
begin tutorial-pick-headless
go 124 "124@2x4" ./tutorial/proj.sh pick
begin tutorial-pick-replay
replay 1 0 "[$(head -n 1 "$PROJ_FILE" 2>/dev/null)]\n"
go 0 "124@2x4" ./tutorial/proj.sh pick
stdout_is "$FIX/repo\n"
begin tutorial-list
go 124 "124@2x4" ./tutorial/proj.sh list
begin tutorial-remove-replay
replay 1 0 "$(head -n 1 "$PROJ_FILE" 2>/dev/null)\n"
replay 2 0 'Remove 1 project(s)\n'
go 0 "124@2x4 124@2x1" ./tutorial/proj.sh remove
check "only the other record is left" bash -c '[[ $(wc -l <"$1") == 1 ]] && jq -e "select(.name == \"files <tmp>\")" "$1"' _ "$PROJ_FILE"
begin tutorial-remove-cancel
replay 1 2 ''
go 2 "124@1x4" ./tutorial/proj.sh remove
check "store unchanged" bash -c '[[ $(wc -l <"$1") == 1 ]]' _ "$PROJ_FILE"

# ---- branch picker tutorial (examples/tutorial-branch-picker) -----------------------------
BP=$FIX/bprepo
git init -q -b main "$BP"
GIT_COMMITTER_DATE=2026-11-10T09:00:00Z git -C "$BP" commit -q --allow-empty -m 'initial commit'
git -C "$BP" branch feature/login
git -C "$BP" switch -q -c fix/typo
GIT_COMMITTER_DATE=2026-11-12T09:00:00Z git -C "$BP" commit -q --allow-empty -m 'Fix the "quick start" typo'
git -C "$BP" switch -q main
GIT_COMMITTER_DATE=2026-11-14T09:00:00Z git -C "$BP" merge -q --no-ff -m 'Merge fix/typo' fix/typo
begin branch-picker-step1-headless
go 124 "124@3x1" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/step1-pick.sh' --timeout 30"
begin branch-picker-step1-replay
replay 1 0 'fix/typo\n'
go 0 "124@3x1" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/step1-pick.sh'"
stdout_is 'You chose: fix/typo\n'
begin branch-picker-print
go 0 "" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/git-pick.sh' --print"
check "header and three branches, newest first" bash -c '[[ $(cut -f1 "$1" | paste -sd,) == "branch,main,fix/typo,feature/login" ]]' _ "$CDIR/stdout"
begin branch-picker-switch-headless
go 124 "124@3x3" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/git-pick.sh' --timeout 20"
check "still on main" test "$(git -C "$BP" branch --show-current)" = main
begin branch-picker-switch-replay
replay 1 0 'feature/login\t4 days ago\tinitial commit\n'
go 0 "124@3x3" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/git-pick.sh'"
check "switched to feature/login" test "$(git -C "$BP" branch --show-current)" = feature/login
git -C "$BP" switch -q main
begin branch-picker-delete-replay
replay 1 0 'fix/typo\t2 days ago\tFix the '"'"'quick start'"'"' typo\n'
go 0 "124@2x3" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/git-pick.sh' --delete-merged"
check "fix/typo deleted, feature/login kept" bash -c '! git -C "$1" rev-parse -q --verify refs/heads/fix/typo >/dev/null && git -C "$1" rev-parse -q --verify refs/heads/feature/login >/dev/null' _ "$BP"
begin branch-picker-delete-cancel
replay 1 2 ''
go 2 "124@1x3" bash -c "cd '$BP' && bash '$EX/tutorial-branch-picker/git-pick.sh' --delete-merged"

# ---- documentation snippets (README.md, the reference, earlier guides) ---------------------------------------------
# Each runs as written in the documents, in a directory holding the files they name.
SNIP=$FIX/snip
mkdir -p "$SNIP"
cp "$EX/data/servers.csv" "$SNIP/servers.csv"; cp "$EX/data/servers.csv" "$SNIP/report.csv"
cp "$EX/data/app.log" "$SNIP/app.log"; cp "$EX/data/app.ndjson" "$SNIP/app.ndjson"
cp "$EX/sample-form.html" "$SNIP/deploy.html"; cp -r "$EX/css" "$SNIP/css"
mkdir -p "$SNIP/examples"; cp -r "$EX/sample-form.html" "$EX/data" "$EX/css" "$SNIP/examples/"
printf 'one\ntwo\nthree\n' >"$SNIP/items.txt"; printf 'build ok\n' >"$SNIP/build.log"
printf 'x\n' >"$SNIP/a.txt"; printf 'y\n' >"$SNIP/b.txt"
printf 'first\n' >"$SNIP/one.log"; printf 'second\n' >"$SNIP/two.log"
cat >"$WORK/fakebin/ssh" <<'SSH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER_LOG"
SSH
chmod +x "$WORK/fakebin/ssh"
doc() {  # doc NAME WANT-STATUS "CALLS" SNIPPET
  begin "doc-$1"; go "$2" "$3" bash -c "cd '$SNIP' && PATH='$WORK/fakebin':\$PATH && $4"
}
doc readme-multi 124 "124@3x1" "printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi"
doc readme-git-branch 124 "124@3x1" "cd '$FIX/repo' && git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch'"
doc readme-docker-ndjson 124 "124@2x14" "docker ps --format '{{json .}}' | nativehtmlkit select --input-format ndjson --output-format json"
doc readme-csv-hosts 0 "124@7x7" "nativehtmlkit select --input-format csv --output-format json --multi < servers.csv | jq -r '.[].host'"
doc readme-ps-view 124 "124@*x1" "ps aux | nativehtmlkit view --title 'Processes'"
doc readme-form 124 "124@0x1" "nativehtmlkit form --html examples/sample-form.html --timeout 600"
doc readme-doctor 0 "0@none" "nativehtmlkit doctor"
doc reference-csv-json 124 "124@2x2" "printf 'name,status\na,up\nb,down\n' | nativehtmlkit select --input-format csv --output-format json"
doc reference-form-sample 124 "124@0x1" "nativehtmlkit form --html examples/sample-form.html --timeout 300"
doc select-xargs-gzip 0 "124@4x1" "ls *.log | nativehtmlkit select --multi | xargs -r -d '\n' gzip --"
check "no log was compressed" bash -c '[[ -f $1/one.log && -f $1/two.log && -z $(ls "$1"/*.gz 2>/dev/null) ]]' _ "$SNIP"
doc select-allow-empty 124 "124@2x1" "printf 'cache\nlogs\n' | nativehtmlkit select --multi --allow-empty --title 'Also clear' || exit"
doc view-csv 124 "124@7x7" "nativehtmlkit view --input-format csv --title 'Servers' < examples/data/servers.csv"
doc view-ndjson 124 "124@3x7" "nativehtmlkit view --input-format ndjson < examples/data/app.ndjson"
if command -v journalctl >/dev/null && journalctl -n 1 --no-pager >/dev/null 2>&1; then
  doc guide-journal-view-logs 124 "124@*x1" "journalctl -n 500 --no-pager | '$EX/view-logs.sh' -"
else
  begin doc-guide-journal-view-logs; skip "journalctl not readable here"
fi
doc form-read-result 124 "124@0x1" "result=\$(nativehtmlkit form --html deploy.html) || exit; echo unreachable"
stdout_is ''
doc exit-status-case 0 "124@2x1" "status=0
out=\$(printf 'a\nb\n' | nativehtmlkit select) || status=\$?
case \$status in
  0)   echo \"chose: \$out\" ;;
  2)   echo \"cancelled\" >&2 ;;
  124) echo \"no answer in time\" >&2 ;;
  *)   echo \"failed (\$status)\" >&2; exit 1 ;;
esac"
check "the 124 branch ran" grep -q 'no answer in time' "$CDIR/stderr"
doc diagnostics-timeline 0 "124@3x1" "nativehtmlkit --diagnostics debug select < items.txt > choice.txt 2> session.log
jq -cR 'fromjson? | select(.component == \"nativehtmlkit-cli\") | {event, operation, duration_ms, error_code}' session.log"
check "the timeline shows window.ready and deadline.expired" bash -c 'grep -q "\"event\":\"window.ready\"" "$1" && grep -q "\"event\":\"deadline.expired\"" "$1"' _ "$CDIR/stdout"
doc diagnostics-session-id 124 "124@0x1" "NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID=\"deploy-\$(date +%s)\" nativehtmlkit form --html deploy.html"
check "records carry the given session id" grep -q '"session_id":"deploy-' "$CDIR/1.err"
doc troubleshooting-session-id 0 "124@1x1" "NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID=\"nightly-42\" nativehtmlkit --diagnostics debug view < build.log 2>> all.log || [[ \$? -eq 124 ]]"
check "host records carry the id too" grep -q '"diagnostic_session_id":"nightly-42"' "$SNIP/all.log"
doc guide-size-case 124 "124@3x1" "status=0
choice=\$(printf 'small\nmedium\nlarge\n' | nativehtmlkit select --title 'Size' --timeout 60) || status=\$?
case \$status in
  0)   echo \"size: \$choice\" ;;
  2)   echo \"cancelled\" >&2; exit 2 ;;
  124) echo \"no answer within 60 s\" >&2; exit 124 ;;
  *)   exit \"\$status\" ;;
esac"
doc guide-choose-helper 124 "124@2x1" "set -euo pipefail
choose() {
  local status=0 out
  out=\$(nativehtmlkit select \"\$@\") || status=\$?
  [[ \$status -eq 0 ]] || { echo \"\${0##*/}: nothing chosen\" >&2; exit \"\$status\"; }
  printf '%s' \"\$out\"
}
color=\$(printf 'red\ngreen\n' | choose --title 'Colour')
echo unreachable"
stdout_is ''
doc guide-pipestatus 0 "124@2x1" "printf 'a.txt\nb.txt\n' | nativehtmlkit select --multi | xargs -r -d '\n' wc -l
status=(\"\${PIPESTATUS[@]}\")
case \${status[1]} in
  0)   ;;
  2)   echo \"cancelled\" >&2 ;;
  124) echo \"timed out\" >&2 ;;
  *)   echo \"selection failed\" >&2; exit 1 ;;
esac"
check "the 124 branch ran and wc did not" bash -c 'grep -q "timed out" "$1" && [[ ! -s $2 ]]' _ "$CDIR/stderr" "$CDIR/stdout"
doc guide-temp-file 124 "124@7x7" "tmp=\$(mktemp out.csv.XXXXXX)
if nativehtmlkit select --multi --input-format csv --output-format csv < report.csv > \"\$tmp\"; then
  mv -- \"\$tmp\" out.csv
else
  status=\$?; rm -f -- \"\$tmp\"; exit \"\$status\"
fi"
check "neither out.csv nor a temporary file exists" bash -c '! ls "$1"/out.csv* >/dev/null 2>&1' _ "$SNIP"
doc guide-git-quick 128 "124@3x1" "cd '$FIX/repo' && git switch \"\$(git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch')\""
check "branch unchanged" test "$(git -C "$FIX/repo" branch --show-current)" = main
doc guide-confirm-form 124 "124@0x1" "picked='[{\"Path\":\"/tmp/a <b>.txt\"},{\"Path\":\"/tmp/it'\\''s & more\"}]'
esc() { jq -rn --arg s \"\$1\" '\$s | @html'; }
{
  echo '<form id=\"nhk-form\"><p>These files will be deleted:</p><ul>'
  jq -r '.[].Path' <<<\"\$picked\" | while IFS= read -r p; do echo \"<li>\$(esc \"\$p\")</li>\"; done
  echo '</ul><label><input type=\"checkbox\" name=\"sure\" value=\"yes\" required> I understand</label></form>'
} > confirm.html
nativehtmlkit form --html confirm.html --title 'Confirm deletion' >/dev/null || exit"
check "the generated form escaped the names" grep -qF '<li>/tmp/a &lt;b&gt;.txt</li>' "$SNIP/confirm.html"
doc guide-ndjson-loop 0 "124@7x7" "nativehtmlkit select --multi --input-format csv --output-format ndjson < servers.csv |
  while IFS= read -r row; do
    host=\$(jq -r .host <<<\"\$row\"); role=\$(jq -r .role <<<\"\$row\")
    echo \"would restart \$role on \$host\"
  done"
doc guide-xargs-ssh 0 "124@7x7" "nativehtmlkit select --multi --input-format csv --output-format json < servers.csv | jq -r '.[].host' |
  xargs -r -d '\n' -I{} ssh -o BatchMode=yes {} uptime"
check "ssh was never run" test ! -e "$CDIR/docker.log"
doc guide-view-logs-text 124 "124@5x1" "tail -n 1000 app.log | perl -CSD -pe 's/^(.{400}).+/\$1.../' | nativehtmlkit view --title 'app.log'"
doc guide-view-logs-ndjson 124 "124@3x7" "tail -n 1000 app.ndjson | nativehtmlkit view --input-format ndjson --title 'app.ndjson'"
doc guide-view-keep-going 0 "124@1x1" "nativehtmlkit view --timeout 300 --title 'Build log' < build.log || [[ \$? -eq 124 ]] || exit 1"
doc guide-api-pipeline 0 "124@3x6" "cat examples/data/issues.json |
  jq -c '[.[] | select(has(\"pull_request\") | not) | {
           \"#\": .number, Title: .title, Author: .user.login,
           Labels: ([.labels[].name] | join(\", \")), Updated: .updated_at[:10], url: .html_url
         }]' |
  nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues' |
  jq -r '.[].url'"
doc guide-css-light 124 "124@2x1" "printf 'a\nb\n' | nativehtmlkit select --css examples/css/light.css"
doc guide-headless-echo 0 "124@2x1" "printf 'a\nb\n' | nativehtmlkit select --timeout 0.5; echo \"exit \$?\""
stdout_is 'exit 124\n'
doc guide-headless-shape 0 "124@2x2" "printf 'a,b\n1,2\n3,4\n' | nativehtmlkit select --input-format csv --timeout 0.5 --diagnostics debug 2>&1 |
  grep -o '\"event\":\"session.started\".*'"
check "shows rows 2, columns 2" grep -qF '"rows":2,"columns":2' "$CDIR/stdout"
doc skill-form-escaped 124 "124@0x1" "version='v1.2.3 <rc> & \"x\"'
esc() { jq -rn --arg s \"\$1\" '\$s | @html'; }
printf '<form id=\"nhk-form\"><label>Version <input name=\"version\" required value=\"%s\"></label></form>\n' \"\$(esc \"\$version\")\" > f.html
result=\$(nativehtmlkit form --html f.html) || exit
jq -r 'first(.entries[] | select(.name == \"version\") | .value)' <<<\"\$result\""
check "the value was escaped" grep -qF 'value="v1.2.3 &lt;rc&gt; &amp; &quot;x&quot;"' "$SNIP/f.html"
printf '{"name":"x","path":"/","tags":"","added":"2026-11-16"}\n' >"$SNIP/proj.ndjson"
doc tutorial-p-function 0 "124@1x4" "export PROJ_FILE='$SNIP/proj.ndjson'; proj() { '$EX/tutorial/proj.sh' \"\$@\"; }
p() { local dir; dir=\$(proj pick) && cd -- \"\$dir\"; }
cd '$SNIP'; p; pwd"
stdout_is "$SNIP\n"

# ---- reference: input formats, limits and exit statuses ----------------------------------
ref() {  # ref NAME WANT-STATUS "CALLS" SHELL-PIPELINE
  begin "ref-$1"; go "$2" "$3" bash -c "$4"
}
ref lines-blank-and-crlf 124 "124@4x1" "printf 'a\r\n\nb\nlast-without-newline' | nativehtmlkit select"
ref lines-whitespace-row 124 "124@1x1" "printf '  \n' | nativehtmlkit select"
ref csv-header-quotes-blank-line 124 "124@2x3" "printf 'name,comment,n\nx,\"has, comma\",1\n\ny,\"two\nlines\",2\n' | nativehtmlkit select --input-format csv"
ref csv-bom-ignored 124 "124@1x2" "printf '\xef\xbb\xbfa,b\n1,2\n' | nativehtmlkit select --input-format csv"
ref csv-bom-stripped-from-header 1 "1@none" "printf '\xef\xbb\xbfa,a\n1,2\n' | nativehtmlkit select --input-format csv"
stderr_has "duplicate CSV/TSV column names"
ref csv-no-headers 124 "124@2x2" "printf '1,2\n3,4\n' | nativehtmlkit select --input-format csv --no-headers"
ref csv-ragged 1 "1@none" "printf 'a,b\n1,2,3\n' | nativehtmlkit select --input-format csv"
error_code input.invalid; stderr_has "found record with 3 fields"
ref csv-duplicate-header 1 "1@none" "printf 'a,a\n1,2\n' | nativehtmlkit select --input-format csv"
stderr_has "duplicate CSV/TSV column names"
ref csv-header-only-select 1 "1@none" "printf 'a,b\n' | nativehtmlkit select --input-format csv"
stderr_has "no selectable input rows"
ref csv-header-only-view 124 "124@0x2" "printf 'a,b\n' | nativehtmlkit view --input-format csv"
ref csv-empty 1 "1@none" "printf '' | nativehtmlkit view --input-format csv"
stderr_has "expected at least one header column"
ref csv-33-columns 1 "1@none" "(seq -s, 33; seq -s, 33) | nativehtmlkit select --input-format csv"
stderr_has "too many columns"
ref csv-2001-records 1 "1@none" "(echo h; seq 2001) | nativehtmlkit select --input-format csv"
stderr_has "too many records"
ref csv-2000-records 124 "124@2000x1" "(echo h; seq 2000) | nativehtmlkit select --input-format csv"
ref tsv-basic 124 "124@1x2" "printf 'a\tb\nsay \"hi\"\ty\n' | nativehtmlkit select --input-format tsv"
ref tsv-leading-quote 1 "1@none" "printf 'a\tb\n\"x\ty\n' | nativehtmlkit select --input-format tsv"
error_code input.invalid
ref json-array-of-objects 124 "124@2x3" "echo '[{\"a\":1,\"b\":2},{\"c\":3,\"a\":4}]' | nativehtmlkit select --input-format json"
ref json-single-object 124 "124@1x2" "echo '{\"a\":1,\"b\":[1,2]}' | nativehtmlkit select --input-format json"
ref json-scalars 124 "124@4x1" "echo '[1,\"two\",null,true]' | nativehtmlkit select --input-format json"
ref json-single-scalar 124 "124@1x1" "echo 42 | nativehtmlkit select --input-format json"
ref json-empty-array 1 "1@none" "echo '[]' | nativehtmlkit select --input-format json"
stderr_has "no selectable input rows"
ref json-empty-array-view 124 "124@0x1" "echo '[]' | nativehtmlkit view --input-format json"
ref json-invalid 1 "1@none" "printf '[1,' | nativehtmlkit select --input-format json"
stderr_has "invalid JSON input"
ref json-bom 1 "1@none" "printf '\xef\xbb\xbf[1]' | nativehtmlkit select --input-format json"
stderr_has "invalid JSON input"
ref json-two-documents 1 "1@none" "echo '[1] [2]' | nativehtmlkit select --input-format json"
stderr_has "trailing characters"
ref json-33-keys 1 "1@none" "jq -nc '[range(33) | {key: \"k\\(.)\", value: 1}] | from_entries' | nativehtmlkit select --input-format json"
stderr_has "33 columns exceeds the 32-column limit"
ref json-2001 1 "1@none" "jq -nc '[range(2001)]' | nativehtmlkit select --input-format json"
stderr_has "2001 rows exceeds the 2000-row initial GUI limit"
ref ndjson-blank-lines 124 "124@2x2" "printf '{\"a\":1}\n   \n{\"b\":2}\n' | nativehtmlkit select --input-format ndjson"
ref ndjson-array-line-is-one-row 124 "124@1x1" "printf '[1,2]\n' | nativehtmlkit select --input-format ndjson"
ref ndjson-pretty-printed 1 "1@none" "printf '{\n\"a\":1}\n' | nativehtmlkit select --input-format ndjson"
stderr_has "invalid NDJSON line 1"
ref ndjson-2001 1 "1@none" "seq 2001 | nativehtmlkit select --input-format ndjson"
stderr_has "too many NDJSON rows"
ref lines-2000 124 "124@2000x1" "seq 2000 | nativehtmlkit select --multi"
ref lines-2001 1 "1@none" "nativehtmlkit select < '$FIX/rows2001.txt'"
stderr_has "2001 rows exceeds the 2000-row initial GUI limit"
ref over-8-mib 1 "1@none" "head -c 8388609 /dev/zero | tr '\\0' a | nativehtmlkit select"
stderr_has "input exceeds 8 MiB"
ref exactly-8-mib-too-big-page 1 "1@none" "head -c 8388608 /dev/zero | tr '\\0' a | nativehtmlkit view"
stderr_has "the generated page is"
ref invalid-utf8 1 "1@none" "printf '\xff\n' | nativehtmlkit select"
stderr_has "stdin must contain UTF-8"
ref empty-stdin-select 1 "1@none" "printf '' | nativehtmlkit select"
error_code input.invalid
ref empty-stdin-view 124 "124@0x1" "printf '' | nativehtmlkit view"
ref node-limit-1870x16 124 "124@1870x16" "jq -nc '[range(1870) | [range(16) | {key: \"c\\(.)\", value: \"v\"}] | from_entries]' | nativehtmlkit select --input-format json --multi"
ref node-limit-1871x16 1 "1@none" "jq -nc '[range(1871) | [range(16) | {key: \"c\\(.)\", value: \"v\"}] | from_entries]' | nativehtmlkit select --input-format json --multi"
stderr_has "at most 1870 rows fit"
ref node-limit-view-1000x32 124 "124@1000x32" "jq -nc '[range(1000) | [range(32) | {key: \"c\\(.)\", value: \"v\"}] | from_entries]' | nativehtmlkit view --input-format json"
ref page-limit-1-mib 1 "1@none" "for i in \$(seq 2000); do printf '%0600d\n' \"\$i\"; done | nativehtmlkit select"
stderr_has "the host accepts 1048576 (1 MiB)"
ref title-empty 1 "1@none" "echo a | nativehtmlkit select --title ''"
error_code usage.invalid
ref title-129 1 "1@none" "echo a | nativehtmlkit select --title \"\$(printf 'x%.0s' \$(seq 129))\""
error_code usage.invalid
ref title-128-unicode 124 "124@1x1" "echo a | nativehtmlkit select --title \"\$(printf 'ž%.0s' \$(seq 128))\""
ref title-hostile 124 "124@1x1" "echo '<img src=x onerror=1>' | nativehtmlkit select --title '<i>Title</i> & \"q\"'"
ref css-too-big 1 "1@none" "head -c 262145 /dev/zero | tr '\\0' x > big.css.tmp; echo a | nativehtmlkit select --css big.css.tmp; rc=\$?; rm -f big.css.tmp; exit \$rc"
stderr_has "custom HTML or CSS file exceeds 256 KiB"
ref css-light 124 "124@1x1" "echo a | nativehtmlkit select --css css/light.css"
ref form-without-nhk-form 1 "1@none" "printf '<form><input name=a></form>' > f.tmp.html; nativehtmlkit form --html f.tmp.html; rc=\$?; rm -f f.tmp.html; exit \$rc"
stderr_has 'must contain <form id="nhk-form">'
ref form-missing-file 1 "1@none" "nativehtmlkit form --html does-not-exist.html"
error_code input.invalid
ref form-css 124 "124@0x1" "nativehtmlkit form --html sample-form.html --css css/form.css --title 'Project'"
ref unknown-flag 1 "1@none" "echo a | nativehtmlkit select --bogus"
ref unknown-format 1 "1@none" "echo a | nativehtmlkit select --input-format xml"
ref view-has-no-output-format 1 "1@none" "echo a | nativehtmlkit view --output-format json"
ref timeout-too-small 1 "" "echo a | \"\$NHK_REAL\" select --timeout 0.005"
ref timeout-too-large 1 "" "echo a | \"\$NHK_REAL\" select --timeout 86401"
ref liveness-zero 124 "124@1x1" "echo a | nativehtmlkit select --liveness-interval 0"
ref global-options-before-command 124 "124@1x1" "echo a | nativehtmlkit --rpc-timeout 10 --startup-timeout 20 select --multi --allow-empty"
ref host-missing 1 "1@none" "echo a | nativehtmlkit --host /nonexistent/nativehtmlkit-host select"
error_code host.not_found
ref host-env-missing 1 "1@none" "echo a | NATIVEHTMLKIT_HOST_BINARY=/nonexistent/host nativehtmlkit select"
error_code host.not_found
ref nhk-alias 124 "124@1x1" "echo a | nhk select"

begin ref-direct-help-version-doctor
if ((ACTIVE)); then
  if "$CLI" --help | grep -q 'Exit status: 0 submitted/viewed, 1 error, 2 cancelled, 124 --timeout expired' &&
     [[ $("$CLI" --version) == "nativehtmlkit $("$CLI" --version | cut -d' ' -f2)" ]] &&
     "$CLI" doctor | grep -q '^Core host: ' && "$CLI" doctor | grep -q '^nativehtmlkit-host '; then
    record PASS "$CASE" "--help, --version and doctor exit 0 with the documented text"
  else
    record FAIL "$CASE" "help/version/doctor text differs"
  fi
fi

begin ref-host-beside-symlinked-cli
if ((ACTIVE)); then
  mkdir -p "$WORK/linkbin"; ln -sf "$CLI" "$WORK/linkbin/nhk-link"
  if "$WORK/linkbin/nhk-link" doctor | grep -qxF "Core host: $(dirname -- "$CLI")/nativehtmlkit-host"; then
    record PASS "$CASE" "a symlinked CLI finds the host beside its real file"
  else record FAIL "$CASE" "doctor through a symlink did not report the host beside the CLI"; fi
fi

begin ref-signals
if ((ACTIVE)); then
  for pair in TERM:143 INT:130 HUP:129; do
    sig=${pair%%:*} want=${pair##*:}
    "$CLI" select --title "signal-$sig" <"$EX/data/app.log" >"$CDIR/$sig.out" 2>"$CDIR/$sig.err" &
    pid=$!
    sleep 1.5; kill "-$sig" "$pid"; wait "$pid"; rc=$?
    if [[ $rc == "$want" && ! -s $CDIR/$sig.out ]]; then record PASS "$CASE: SIG$sig" "exit $rc, no stdout"
    else record FAIL "$CASE: SIG$sig" "exit $rc, want $want"; fi
  done
fi

# ---- catalog coverage: every linux example of examples/catalog.toml was run ---------------
if [[ -z $FILTER ]]; then
  while IFS= read -r f; do
    if grep -qE "(^|[ /'])(\./)?$(printf '%s' "$f" | sed 's/[.]/\\./g')( |'|\$)" "$WORK/invoked"; then
      record PASS "catalog $f" "run by a case"
    else
      record FAIL "catalog $f" "no case runs it"
    fi
  done < <(python3 -I -c 'import sys,tomllib; [print(e["linux"]) for e in tomllib.load(open(sys.argv[1],"rb"))["example"] if "linux" in e]' "$EX/catalog.toml")
fi

# ---- cleanup checks ----------------------------------------------------------------------
sleep 1
HOSTBIN=$(dirname -- "$CLI")/nativehtmlkit-host
left=$(pgrep -f -- "$HOSTBIN" | wc -l)
begin zz-no-leftovers
((ACTIVE)) && if [[ $left == 0 && -z $(ls -A "$WORK/tmp") ]]; then
  record PASS "$CASE" "no host process left, every private session directory removed"
else
  record FAIL "$CASE" "host processes left: $left; session dirs: $(ls -A "$WORK/tmp" | wc -l)"
fi

echo "test-examples: $PASS PASS, $FAIL FAIL, $SKIP SKIP (CLI $("$CLI" --version | cut -d' ' -f2), work dir $WORK)"
if [[ $FAIL == 0 && $KEEP == 0 ]]; then rm -rf -- "$WORK"; fi
[[ $FAIL == 0 ]]
