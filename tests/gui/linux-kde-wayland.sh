#!/usr/bin/env bash
# Native KDE Plasma Wayland qualification for the NativeHTMLKit CLI.
#
# Runs INSIDE the logged-in Wayland session host (e.g. the lab VM linuxDEV) as the
# desktop user. Real windows are opened, real input is injected with ydotool (uinput),
# and screenshots are taken with spectacle. Every case records exact stdout bytes,
# stderr, exit status and screenshots under $OUT/<case>/ and a PASS/FAIL line in
# $OUT/results.tsv. Nothing here is headless; a failure is never converted to PASS.
#
# Usage: linux-kde-wayland.sh BIN_DIR OUT_DIR [case ...]
#   BIN_DIR contains nativehtmlkit, nhk (alias) and nativehtmlkit-host.
# Coordinates assume a 1280x800 screen and KWin's centred placement of the
# 900x610 window (client origin 190,86). Each case screenshot shows what was clicked.
set -uo pipefail
BIN=$(cd "$1" && pwd); OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
. ~/lab/bin/gui-env
export QT_QPA_PLATFORM=wayland
unset DISPLAY
export NATIVEHTMLKIT_HOST_BINARY="$BIN/nativehtmlkit-host"
RESULTS=$OUT/results.tsv
[[ -f $RESULTS ]] || printf 'case\tresult\texpected_rc\tactual_rc\tdetail\n' > "$RESULTS"

key() { for k in "$@"; do ydotool key "$k:1" "$k:0" >/dev/null 2>&1; sleep 0.12; done; }  # linux keycodes
TAB=15; SPACE=57; ENTER=28; DOWN=108
click() { ~/lab/bin/lab-click "$1" "$2"; sleep 0.35; }
shot() { ~/lab/bin/lab-shot "$CASE_DIR/$1.png" >/dev/null || echo "screenshot $1 failed" >&2; }

# start NAME INPUT_FILE ARGS... : launch the pipeline fully detached (own session, no inherited fds)
start() {
  CASE=$1; INPUT=$2; shift 2
  CASE_DIR=$OUT/$CASE; rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR"
  { printf 'nhk'; printf ' %q' "$@"; printf ' < %s\n' "$(basename "$INPUT")"; } > "$CASE_DIR/command.txt"
  cp "$INPUT" "$CASE_DIR/stdin.bin"
  CASE_DIR="$CASE_DIR" INPUT="$INPUT" setsid bash -c \
    '"$0" "$@" < "$INPUT" > "$CASE_DIR/stdout.bin" 2> "$CASE_DIR/stderr.txt"; echo $? > "$CASE_DIR/rc"' \
    "$BIN/nhk" "$@" </dev/null >/dev/null 2>&1 &
  echo $! > "$CASE_DIR/launcher-session.pid"
  sleep "${OPEN_WAIT:-2.5}"
}
wait_rc() { local t=0; while [[ ! -s $CASE_DIR/rc && $t -lt ${1:-100} ]]; do sleep 0.1; t=$((t+1)); done; cat "$CASE_DIR/rc" 2>/dev/null || echo TIMEOUT; }
leftovers() { pgrep -u "$(id -u)" -f "$BIN/nativehtmlkit|$BIN/nhk|nativehtmlkit-host" | grep -v "^$$\$" | wc -l; }
units() { systemctl --user list-units 'nativehtmlkit-host-*' --no-legend --plain 2>/dev/null | wc -l; }
# verdict EXPECTED_RC EXPECTED_STDOUT_PRINTF_FORMAT
verdict() {
  local want_rc=$1 want_out=$2 rc detail="" ok=1
  rc=$(wait_rc 150)
  printf "$want_out" > "$CASE_DIR/expected-stdout.bin"
  [[ $rc == "$want_rc" ]] || { ok=0; detail+="rc $rc!=$want_rc; "; }
  cmp -s "$CASE_DIR/expected-stdout.bin" "$CASE_DIR/stdout.bin" || { ok=0; detail+="stdout mismatch; "; }
  sleep 0.8
  local l u; l=$(leftovers); u=$(units)
  echo "leftover_processes=$l leftover_units=$u" > "$CASE_DIR/cleanup.txt"
  [[ $l == 0 && $u == 0 ]] || { ok=0; detail+="leftovers p=$l u=$u; "; }
  od -An -c "$CASE_DIR/stdout.bin" > "$CASE_DIR/stdout.od.txt"
  local result=PASS; [[ $ok == 1 ]] || result=FAIL
  printf '%s\t%s\t%s\t%s\t%s\n' "$CASE" "$result" "$want_rc" "$rc" "${detail:-exact stdout, no leftovers}" | tee -a "$RESULTS"
}
fixture() { printf "$2" > "$OUT/$1"; echo "$OUT/$1"; }

# Window geometry (client area origin 190,86 on 1280x800, 900x610 window)
ROW1=197; ROWH=39; PICK_X=233; CLOSE_X=(1076 72)
row_y() { echo $((ROW1 + ROWH * $1)); }
# The footer follows the table: y=352 for 3 rows, +39 px per row, pinned at 636 once the
# table reaches its max-height and scrolls (observed in s05 screenshots).
rows() { ROWS=$1; local y=$((352 + 39 * (ROWS - 3))); (( y > 636 )) && y=636; SUBMIT=(1000 $y); CANCEL=(882 $y); }
rows 3
fixture abc.txt 'alpha\nbeta\ngamma\n' >/dev/null   # shared by most cases

case_s02_multi() {
  start s02-multi-beta "$(fixture abc.txt 'alpha\nbeta\ngamma\n')" select --multi
  shot 01-open; click $PICK_X "$(row_y 1)"; shot 02-beta-checked; click "${SUBMIT[@]}"
  verdict 0 'beta\n'
}
case_s02_order() {
  start s02-multi-two "$OUT/abc.txt" select --multi
  click $PICK_X "$(row_y 2)"; click $PICK_X "$(row_y 0)"; shot 01-gamma-alpha; click "${SUBMIT[@]}"
  verdict 0 'alpha\ngamma\n'   # document order, independent of click order
}
case_s02_single() {
  start s02-single-radio "$OUT/abc.txt" select
  click $PICK_X "$(row_y 0)"; click $PICK_X "$(row_y 2)"; shot 01-radio-gamma; click "${SUBMIT[@]}"
  verdict 0 'gamma\n'
}
case_s03_cancel() {
  start s03-cancel "$OUT/abc.txt" select --multi
  click $PICK_X "$(row_y 1)"; click "${CANCEL[@]}"
  verdict 2 ''
}
case_s03_close() {
  start s03-titlebar-close "$OUT/abc.txt" select --multi
  click $PICK_X "$(row_y 0)"; shot 01-before-close; click "${CLOSE_X[@]}"
  verdict 2 ''
}
case_s03_empty_submit() {
  start s03-empty-submit-error "$OUT/abc.txt" select --multi
  click "${SUBMIT[@]}"; sleep 0.5; shot 01-error-shown
  click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 0 'gamma\n'
}
case_s04_invalid() {
  start s04-invalid-json "$(fixture bad.json '[1,')" select --input-format json; verdict 1 ''
  start s04-invalid-csv "$(fixture bad.csv 'a,b\n1,2,3\n')" select --input-format csv; verdict 1 ''
  start s04-empty-input "$(fixture empty.txt '')" select; verdict 1 ''
  start s04-bad-utf8 "$(fixture bad.txt '\xff\xfe\n')" select; verdict 1 ''
  start s04-usage-error "$OUT/abc.txt" select --bogus; verdict 1 ''
}
case_s05_bounds() {
  seq -f 'row %g' 1 2000 > "$OUT/rows2000.txt"; seq 1 2001 > "$OUT/rows2001.txt"
  rows 2000; OPEN_WAIT=4 start s05-2000-rows "$OUT/rows2000.txt" select
  shot 01-open; ~/lab/bin/lab-move 640 260; for _ in $(seq 1 40); do ydotool mousemove -w -x 0 -y -15 >/dev/null; done; sleep 0.5; shot 02-scrolled
  click "${CANCEL[@]}"; verdict 2 ''
  rows 3
  start s05-2001-rows "$OUT/rows2001.txt" select; verdict 1 ''
  head -c $((8*1024*1024+1)) /dev/zero | tr '\0' 'a' > "$OUT/huge.txt"
  start s05-over-8mib "$OUT/huge.txt" select; verdict 1 ''
}
case_s06_json() {
  rows 2
  start s06-json-types "$(fixture typed.json '[{"id":1,"ok":true,"name":"x","tags":["a"],"none":null},{"id":2.5,"ok":false,"name":"Příliš 😀","tags":[],"none":null}]')" select --input-format json
  shot 01-open; click $PICK_X "$(row_y 1)"; click "${SUBMIT[@]}"
  verdict 0 '[{"id":2.5,"ok":false,"name":"Příliš 😀","tags":[],"none":null}]\n'
  rows 3
  start s06-ndjson "$(fixture typed.ndjson '{"a":1}\n{"a":"two"}\n\n{"a":[3]}\n')" select --input-format ndjson --multi
  click $PICK_X "$(row_y 0)"; click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 0 '{"a":1}\n{"a":[3]}\n'
}
case_s07_csv() {
  fixture quoting.csv 'name,comment\nplain,"has, comma"\nquote,"say ""hi"""\nnl,"line1\nline2"\n' >/dev/null
  start s07-csv-quoting "$OUT/quoting.csv" select --input-format csv --multi
  shot 01-open; click $PICK_X "$(row_y 0)"; click $PICK_X "$(row_y 1)"; click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 0 'name,comment\nplain,"has, comma"\nquote,"say ""hi"""\nnl,"line1\nline2"\n'
  start s07-tsv-out "$OUT/quoting.csv" select --input-format csv --output-format tsv
  click $PICK_X "$(row_y 0)"; click "${SUBMIT[@]}"
  verdict 0 'name\tcomment\nplain\thas, comma\n'
  start s07-lines-refuses-newline "$OUT/quoting.csv" select --input-format csv --output-format lines
  click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 1 ''
}
case_s10_hostile() {
  start s10-hostile-text "$(fixture hostile.txt '<script>alert(1)</script>\n<b>bold?</b> & "q" '"'"'s\nPříliš žluťoučký kůň 漢字 😀 עברית\n')" select --multi --title '<i>Title</i> & 😀'
  shot 01-literal-text; click $PICK_X "$(row_y 0)"; click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 0 '<script>alert(1)</script>\nPříliš žluťoučký kůň 漢字 😀 עברית\n'
}
case_view() {
  start view-lines-close "$(fixture ps.txt 'PID CMD\n1 init\n42 <shell> & co\n')" view
  shot 01-open; click "${CLOSE_X[@]}"
  verdict 0 ''
}
case_s11_kill() {
  start s11-sigkill-launcher "$OUT/abc.txt" select --multi
  local cli; cli=$(pgrep -n -f "$BIN/nhk select --multi"); echo "cli_pid=$cli" > "$CASE_DIR/kill.txt"
  kill -KILL "$cli"; sleep 3
  printf '%s\t%s\t-\t-\t%s\n' "$CASE" "$([[ $(leftovers) == 0 && $(units) == 0 ]] && echo PASS || echo FAIL)" "after SIGKILL of CLI: processes=$(leftovers) units=$(units)" | tee -a "$RESULTS"
  start s11-sigint "$OUT/abc.txt" select --multi
  cli=$(pgrep -n -f "$BIN/nhk select --multi"); kill -INT -- "-$(ps -o pgid= "$cli" | tr -d ' ')"   # terminal-style Ctrl+C to the job's process group
  verdict 130 ''
}

case_s08_form() {
  local form=$OUT/sample-form.html; cp "$BIN/../sample-form.html" "$form"
  start s08-form "$OUT/abc.txt" form --html "$form"
  shot 01-open; click 1029 304; sleep 0.4; shot 02-required-error
  click 402 153; ydotool type -d 25 -- 'Demo App' >/dev/null; sleep 0.3
  click 220 225; shot 03-filled; click 1029 304
  verdict 0 '{"entries":[{"kind":"text","name":"project","value":"Demo App"},{"kind":"text","name":"environment","value":"development"},{"kind":"text","name":"confirm","value":"yes"}]}\n'
}
case_s09_keyboard() {
  rows 3; start s09-keyboard "$OUT/abc.txt" select --multi
  click $PICK_X "$(row_y 0)"          # focus + check row 1
  key $SPACE; key $TAB $SPACE; sleep 0.3; shot 01-keyboard-row2
  click "${SUBMIT[@]}"
  verdict 0 'beta\n'
}
case_s09_resize() {
  start s09-resize "$OUT/abc.txt" view
  shot 01-before; ~/lab/bin/lab-drag 1089 695 839 545; sleep 0.8; shot 02-after-resize
  ~/lab/bin/lab-drag 839 545 1089 695; sleep 0.8; shot 03-restored
  click "${CLOSE_X[@]}"
  verdict 0 ''
}
case_s13_parallel() {
  rows 3
  start s13-parallel-a "$OUT/abc.txt" select --title 'First window'; local A=$CASE_DIR
  start s13-parallel-b "$(fixture xyz.txt 'x-ray\nyankee\nzulu\n')" select --title 'Second window'
  shot 01-two-windows; click 261 291; click 1027 368
  local want_rc; want_rc=$(wait_rc 150); printf 'zulu\n' > "$CASE_DIR/expected-stdout.bin"
  local rb=FAIL; [[ $want_rc == 0 ]] && cmp -s "$CASE_DIR/expected-stdout.bin" "$CASE_DIR/stdout.bin" && rb=PASS
  printf '%s\t%s\t0\t%s\t%s\n' s13-parallel-b "$rb" "$want_rc" "second window, first still open" | tee -a "$RESULTS"
  CASE=s13-parallel-a; CASE_DIR=$A; click $PICK_X "$(row_y 0)"; click "${SUBMIT[@]}"
  verdict 0 'alpha\n'
}

ALL=(case_s02_multi case_s02_order case_s02_single case_s03_cancel case_s03_close case_s03_empty_submit case_s04_invalid case_s05_bounds case_s06_json case_s07_csv case_s10_hostile case_view case_s08_form case_s09_keyboard case_s09_resize case_s11_kill case_s13_parallel)
if (( $# )); then for c in "$@"; do "case_$c"; done; else for c in "${ALL[@]}"; do "$c"; done; fi
