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
#   BIN_DIR is a clean extraction of the release archive: nativehtmlkit, nhk (alias),
#   nativehtmlkit-host and examples/sample-form.html.
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
# Only this suite's own processes and units count: the machine may run other NativeHTMLKit
# sessions (other SDK test suites, headless hosts) that are none of this suite's business.
leftovers() { pgrep -u "$(id -u)" -f "^$BIN/(nativehtmlkit|nhk|nativehtmlkit-host)( |\$)" | wc -l; }
own_units() {
  local u
  for u in $(systemctl --user list-units 'nativehtmlkit-host-*' --no-legend --plain 2>/dev/null | awk '{print $1}'); do
    systemctl --user show -p ExecStart --value "$u" 2>/dev/null | grep -qF "$BIN/" && echo "$u"
  done
}
units() { own_units | wc -l; }
foreign_windows() { echo $(( $(systemctl --user list-units 'nativehtmlkit-host-*' --no-legend --plain 2>/dev/null | wc -l) - $(units) )); }
# Remove everything this suite started. Runs after a failed case and always at exit, so no
# window of ours is left on the shared desktop once the caller releases its lock.
cleanup_own() {
  local u
  pkill -KILL -u "$(id -u)" -f "^$BIN/(nativehtmlkit|nhk|nativehtmlkit-host)( |\$)" 2>/dev/null
  for u in $(own_units); do systemctl --user kill -s KILL "$u" 2>/dev/null; done
  sleep 0.5
}
trap cleanup_own EXIT
trap 'exit 130' INT TERM HUP
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
  [[ $l == 0 && $u == 0 ]] || { ok=0; detail+="leftovers p=$l u=$u (removed); "; cleanup_own; }
  od -An -c "$CASE_DIR/stdout.bin" > "$CASE_DIR/stdout.od.txt"
  local result=PASS; [[ $ok == 1 ]] || result=FAIL
  printf '%s\t%s\t%s\t%s\t%s\n' "$CASE" "$result" "$want_rc" "$rc" "${detail:-exact stdout, no leftovers}" | tee -a "$RESULTS"
}
fixture() { printf "$2" > "$OUT/$1"; echo "$OUT/$1"; }
# check NAME DETAIL COMMAND... : an additional assertion recorded as its own PASS/FAIL row
check() {
  local name=$1 detail=$2; shift 2
  local result=FAIL; "$@" && result=PASS
  printf '%s\t%s\t-\t-\t%s\n' "$name" "$result" "$detail" | tee -a "$RESULTS"
}
SENTINEL='S3NTINEL-do-not-log-7f3a'
host_unit() { own_units | head -1; }

# Window geometry (client area origin 190,86 on 1280x800, 900x610 window)
ROW1=197; ROWH=39; PICK_X=233; CLOSE_X=(1076 72)
row_y() { echo $((ROW1 + ROWH * $1)); }
# The footer follows the table: y=352 for 3 rows, +39 px per row, until the table fills the
# window and scrolls; the footer then stays 20 px above the bottom edge of the client area
# (y=657 at the default 610 px height, and it moves with the edge when the window is resized).
FOOTER_PINNED=657
rows() { ROWS=$1; local y=$((352 + 39 * (ROWS - 3))); (( y > FOOTER_PINNED )) && y=$FOOTER_PINNED; SUBMIT=(1000 $y); CANCEL=(882 $y); }
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
case_s09_resize_keeps_footer() {
  # A long list in a window made 150 px shorter: the table must give up the height and the
  # buttons must stay reachable. (With viewport-height units the host kept the old layout:
  # the footer left the window; see the project bug register.)
  seq -f 'row %g' 1 60 > "$OUT/rows60.txt"
  rows 60; start s09-resize-keeps-footer "$OUT/rows60.txt" select --multi
  shot 01-before; click $PICK_X "$(row_y 1)"
  ~/lab/bin/lab-drag 640 695 640 545; sleep 1; shot 02-after-vertical-shrink
  click "${SUBMIT[0]}" $((FOOTER_PINNED - 150))
  verdict 0 'row 2\n'
  rows 3
}
case_s09_resize_vh_css() {
  # The same shrink with a user stylesheet that sizes the list in viewport-height units
  # (the CLI's own layout up to 0.1.1). Core re-resolves vh on resize since 1.0.3
  # (NHK-CROSS-0005); with an older host the footer leaves the window and this case fails.
  printf '%s' 'main{display:block;height:auto;min-height:100vh}#nhk-selection-form{display:block}.scroll{max-height:calc(100vh - 170px)}' > "$OUT/vh.css"
  rows 60; start s09-resize-vh-css "$OUT/rows60.txt" select --multi --css "$OUT/vh.css"
  shot 01-before; click $PICK_X "$(row_y 1)"
  ~/lab/bin/lab-drag 640 695 640 545; sleep 1; shot 02-after-vertical-shrink
  click 1000 $((636 - 150))        # with max-height:calc(100vh - 170px) the footer sits at y=636
  verdict 0 'row 2\n'
  rows 3
}
case_s11_kill() {
  start s11-sigkill-launcher "$OUT/abc.txt" select --multi
  local cli; cli=$(pgrep -n -f "$BIN/nhk select --multi"); echo "cli_pid=$cli" > "$CASE_DIR/kill.txt"
  kill -KILL "$cli"; sleep 3
  printf '%s\t%s\t-\t-\t%s\n' "$CASE" "$([[ $(leftovers) == 0 && $(units) == 0 ]] && echo PASS || echo FAIL)" "after SIGKILL of CLI: processes=$(leftovers) units=$(units)" | tee -a "$RESULTS"
  cleanup_own
  start s11-sigint "$OUT/abc.txt" select --multi
  cli=$(pgrep -n -f "$BIN/nhk select --multi"); kill -INT -- "-$(ps -o pgid= "$cli" | tr -d ' ')"   # terminal-style Ctrl+C to the job's process group
  verdict 130 ''
}

case_s08_form() {
  local form=$OUT/sample-form.html; cp "$BIN/examples/sample-form.html" "$form"
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

case_s09_keyboard_submit() {
  # Whole flow without the mouse after the first focus click: Space toggles, Tab moves
  # through row 2, row 3, Cancel to Submit, and Enter / Space activates the button.
  local keyname code
  for keyname in enter space; do
    [[ $keyname == enter ]] && code=$ENTER || code=$SPACE
    rows 3; start "s09-keyboard-submit-$keyname" "$OUT/abc.txt" select --multi
    click $PICK_X "$(row_y 0)"
    key $TAB $TAB $TAB $TAB; sleep 0.3; shot 01-submit-focused
    key $code
    verdict 0 'alpha\n'
  done
}
case_s15_slow_user() {
  # The user thinks for three per-request deadlines; a healthy host must not be mistaken
  # for a hung one, and the liveness probes must not disturb the window.
  rows 3; start s15-slow-user "$OUT/abc.txt" --diagnostics debug --liveness-interval 1 --rpc-timeout 3 select --multi
  shot 01-open; sleep 9; shot 02-still-open-after-idle
  click $PICK_X "$(row_y 1)"; click "${SUBMIT[@]}"
  verdict 0 'beta\n'
  local probes; probes=$(grep -c '"event":"rpc.completed".*"operation":"host.diagnostics"' "$CASE_DIR/stderr.txt")
  check s15-slow-user-probes "liveness probes answered while idle: $probes (need >= 6), no error line" \
    bash -c '[[ $0 -ge 6 ]] && ! grep -q "error\[" "$1"' "$probes" "$CASE_DIR/stderr.txt"
}
case_s15_resize_hold() {
  # FR-R-10: a window border held for 8 s (an interactive resize in progress), more than two
  # per-request deadlines. A healthy host must not be reported as hung.
  rows 3; start s15-resize-hold "$OUT/abc.txt" --diagnostics debug --liveness-interval 1 --rpc-timeout 3 select --multi
  ~/lab/bin/lab-move 1089 695; ydotool click 0x40 >/dev/null; sleep 0.3
  ydotool mousemove -x -60 -y -40 >/dev/null; sleep 8; shot 01-held-while-resizing
  ydotool mousemove -x 60 -y 40 >/dev/null; sleep 0.3; ydotool click 0x80 >/dev/null; sleep 0.5
  click $PICK_X "$(row_y 2)"; click "${SUBMIT[@]}"
  verdict 0 'gamma\n'
  check s15-resize-hold-alive "no error line while the border was held for 8 s" bash -c '! grep -q "error\[" "$0"' "$CASE_DIR/stderr.txt"
}
case_s15_file_dialog() {
  # FR-R-10: the file control is activated and the session is left alone for 8 s, as when a
  # native file dialog is open. On this desktop the dialog needs the XDG portal; whether one
  # appeared is visible in the screenshot. Either way the session must survive and deliver.
  printf '%s' '<form id="nhk-form"><p><label>Attachment <input type="file" name="attachment"></label></p><p><label>Note <input name="note" value="kept"></label></p></form>' > "$OUT/file-form.html"
  start s15-file-dialog "$OUT/abc.txt" --diagnostics debug --liveness-interval 1 --rpc-timeout 3 form --html "$OUT/file-form.html"
  shot 01-open; click 318 152; sleep 8; shot 02-after-8s
  key 1; sleep 0.8; shot 03-after-escape          # Escape dismisses a dialog if one is open
  click 1029 266
  local rc; rc=$(wait_rc 150)
  check s15-file-dialog "exit $rc; form delivered with the note field; no error line" \
    bash -c '[[ $0 == 0 ]] && grep -q "\"name\":\"note\",\"value\":\"kept\"" "$1" && ! grep -q "error\[" "$2"' "$rc" "$CASE_DIR/stdout.bin" "$CASE_DIR/stderr.txt"
  [[ $(leftovers) == 0 ]] || cleanup_own
}
case_s16_hung_host() {
  # Freeze the real, systemd-supervised host process while its window is open.
  # Detection takes the probe interval plus twice the per-request deadline (1 s + 2 x 2 s).
  rows 3; start s16-hung-host "$OUT/abc.txt" --liveness-interval 1 --rpc-timeout 2 select --multi --title 'Hung host'
  shot 01-open
  local unit pid t0; unit=$(host_unit); pid=$(systemctl --user show -p MainPID --value "$unit")
  echo "unit=$unit supervised_host_pid=$pid" > "$CASE_DIR/hang.txt"
  kill -STOP "$pid"; t0=$(date +%s)
  click $PICK_X "$(row_y 1)"; shot 02-frozen-window-ignores-click
  verdict 1 ''
  echo "seconds_until_cli_exit=$(( $(date +%s) - t0 ))" >> "$CASE_DIR/hang.txt"
  shot 03-window-gone
  check s16-hung-host-report "stderr names error[host.unresponsive]; exit within 15 s ($(tail -1 "$CASE_DIR/hang.txt"))" \
    bash -c 'grep -q "^nativehtmlkit: error\[host.unresponsive\]: " "$0" && [[ $1 -le 15 ]]' "$CASE_DIR/stderr.txt" "$(( $(date +%s) - t0 ))"
}
case_s16_eventloop_hang_dead_launcher() {
  # NHK-CROSS-0001: only the host's event-loop (main) thread is frozen, with ptrace, while
  # its other threads keep running; then the CLI is SIGKILLed. Core's in-process
  # launcher-loss watchdog must end the host by itself: the CLI is dead and cannot help.
  local name=s16-eventloop-hang-dead-launcher
  if ! sudo -n true 2>/dev/null || ! command -v python3 >/dev/null; then
    printf '%s\tBLOCKED\t-\t-\tneeds passwordless sudo and python3 to ptrace-freeze one thread\n' "$name" | tee -a "$RESULTS"; return
  fi
  rows 3; start "$name" "$OUT/abc.txt" --liveness-interval 0 select --multi --title 'Frozen event loop'
  shot 01-open
  local unit pid cli; unit=$(host_unit); pid=$(systemctl --user show -p MainPID --value "$unit")
  cli=$(pgrep -n -f "^$BIN/nhk --liveness-interval 0 select")
  cat > "$CASE_DIR/freeze-main-thread.py" <<'PY'
import ctypes, os, sys, time
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long
PTRACE_SEIZE, PTRACE_INTERRUPT = 0x4206, 0x4207
tid = int(sys.argv[1])                      # main thread id == process id
for request in (PTRACE_SEIZE, PTRACE_INTERRUPT):
    if libc.ptrace(request, tid, None, None) != 0:
        sys.exit(f"ptrace {request:#x} failed: errno {ctypes.get_errno()}")
os.waitpid(tid, 0x40000000)                 # __WALL: the main thread is now stopped
state = open(f"/proc/{tid}/task/{tid}/stat").read().rsplit(")", 1)[1].split()[0]
others = [open(f"/proc/{tid}/task/{t}/stat").read().rsplit(")", 1)[1].split()[0] for t in os.listdir(f"/proc/{tid}/task") if int(t) != tid]
print(f"main thread state={state} other threads={len(others)} not-stopped={sum(x not in 'tT' for x in others)}", flush=True)
# Keep it frozen, but reap it as soon as the process ends: the exit of a traced thread-group
# leader is reported to the tracer first, and its real parent only sees it afterwards.
import signal
signal.signal(signal.SIGALRM, lambda *_: sys.exit(0))   # exiting detaches
signal.alarm(int(float(sys.argv[2])))
while True:
    _, status = os.waitpid(tid, 0x40000000)
    if os.WIFEXITED(status) or os.WIFSIGNALED(status):
        print("traced process ended", flush=True)
        break
PY
  sudo -n python3 "$CASE_DIR/freeze-main-thread.py" "$pid" 40 > "$CASE_DIR/freeze.txt" 2>&1 &
  local freezer=$!; sleep 1.5
  echo "unit=$unit host_pid=$pid cli_pid=$cli $(head -1 "$CASE_DIR/freeze.txt")" > "$CASE_DIR/hang.txt"
  click $PICK_X "$(row_y 1)"; shot 02-frozen-window-ignores-click
  kill -KILL "$cli"; local t0; t0=$(date +%s)
  local gone=no i; for i in $(seq 1 60); do [[ $(leftovers) == 0 && $(units) == 0 ]] && { gone=yes; break; }; sleep 0.5; done
  local took=$(( $(date +%s) - t0 ))
  echo "host_gone_without_help=$gone seconds_after_cli_kill=$took" >> "$CASE_DIR/hang.txt"
  shot 03-after-launcher-death
  local tracer; tracer=$(pgrep -f "python3 $CASE_DIR/freeze-main-thread.py")
  [[ -n $tracer ]] && sudo -n kill -KILL $tracer 2>/dev/null
  wait "$freezer" 2>/dev/null
  local frozen=no; grep -q 'main thread state=t ' "$CASE_DIR/freeze.txt" && ! grep -q 'not-stopped=0$' "$CASE_DIR/freeze.txt" && frozen=yes
  check "$name" "only the main thread frozen: $frozen ($(head -1 "$CASE_DIR/freeze.txt")); after SIGKILL of the CLI the host and its unit ended by themselves: $gone after $took s" \
    test "$frozen$gone" = yesyes
  cleanup_own
}
case_s17_deadline() {
  rows 3; start s17-deadline "$OUT/abc.txt" --timeout 3 select
  shot 01-open; click $PICK_X "$(row_y 0)"     # a selection alone is not a decision
  verdict 124 ''
  shot 02-closed-by-deadline
}
case_s18_diagnostics() {
  # "Submit did nothing" support scenario: full trace, one session id across launcher,
  # host and backend, and none of the user's data or the launch token in it.
  rows 3; fixture secret.txt "first $SENTINEL\nsecond $SENTINEL\nthird\n" >/dev/null
  NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID=gui-s18.linux start s18-trace "$OUT/secret.txt" --diagnostics trace select --multi --title "Trace $SENTINEL"
  shot 01-open; click "${SUBMIT[@]}"; sleep 0.5; shot 02-empty-submit-rejected
  click $PICK_X "$(row_y 1)"; click "${SUBMIT[@]}"
  verdict 0 "second $SENTINEL\\n"
  local err=$CASE_DIR/stderr.txt
  check s18-trace-private "no user data and no 64-hex credential anywhere on stderr ($(wc -l < "$err") lines)" \
    bash -c '! grep -q "$0" "$1" && ! grep -Eq "[0-9a-fA-F]{64}" "$1"' "$SENTINEL" "$err"
  check s18-trace-correlated "launcher and backend records all carry session id gui-s18.linux" \
    bash -c 'grep -q "\"session_id\":\"gui-s18.linux\".*\"role\":\"launcher\"" "$0" &&
             grep -q "\"session_id\":\"gui-s18.linux\".*\"role\":\"backend\"" "$0" &&
             ! grep "^{\"schema_version\"" "$0" | grep -vq "\"session_id\":\"gui-s18.linux\""' "$err"
  # Core tags its own records with the id from 1.0.2 on; an older host cannot (BLOCKED).
  local tagged hostv; tagged=$(grep -c '^{"diagnostic_session_id":"gui-s18.linux"' "$err")
  hostv=$("$BIN/nativehtmlkit-host" --version | awk '{print $2}')
  if [[ $tagged -gt 0 ]]; then
    check s18-trace-host-correlated "host $hostv tagged $tagged of its records with the same id" true
    # Each document.command the CLI completed is visible host-side under the same request id.
    local ids missing=0 n=0 id
    ids=$(grep -o '"event":"rpc.completed","request_id":"nhk-[0-9]*","operation":"document.command"' "$err" | grep -o 'nhk-[0-9]*')
    for id in $ids; do
      n=$((n+1))
      grep -q "\"event\":\"rpc.received\",\"method\":\"document.command\",\"id\":\"$id\"" "$err" &&
        grep -q "\"event\":\"rpc.completed\",\"method\":\"document.command\",\"id\":\"$id\"" "$err" || missing=$((missing+1))
    done
    check s18-trace-host-request-ids "host trace shows rpc.received and rpc.completed for $n document.command request ids of the CLI (missing: $missing)" \
      test "$n" -ge 3 -a "$missing" = 0
  elif [[ $(printf '%s\n1.0.2\n' "$hostv" | sort -V | head -1) != 1.0.2 ]]; then
    printf 's18-trace-host-correlated\tBLOCKED\t-\t-\thost %s predates diagnostic_session_id tagging (Core 1.0.2)\n' "$hostv" | tee -a "$RESULTS"
  else check s18-trace-host-correlated "host $hostv wrote no record tagged with the session id" false; fi
  check s18-trace-explains-submit "trace shows the rejected and the accepted submit with request ids and durations" \
    bash -c 'grep -q "\"event\":\"submit.rejected\".*\"reason\":\"empty_selection\"" "$0" &&
             grep -q "\"event\":\"submit.accepted\"" "$0" &&
             grep -q "\"event\":\"rpc.completed\",\"request_id\":\"nhk-[0-9]*\",\"operation\":\"document.command\",\"duration_ms\":[0-9]" "$0"' "$err"
}

ALL=(case_s02_multi case_s02_order case_s02_single case_s03_cancel case_s03_close case_s03_empty_submit case_s04_invalid case_s05_bounds case_s06_json case_s07_csv case_s10_hostile case_view case_s08_form case_s09_keyboard case_s09_keyboard_submit case_s09_resize case_s09_resize_keeps_footer case_s09_resize_vh_css case_s11_kill case_s13_parallel case_s15_slow_user case_s15_resize_hold case_s15_file_dialog case_s16_hung_host case_s16_eventloop_hang_dead_launcher case_s17_deadline case_s18_diagnostics)
# Pre-flight: the desktop is shared. Another NativeHTMLKit window would take our clicks, so
# the suite does not start (BLOCKED, not FAIL) while one is open.
for _ in $(seq 1 6); do [[ $(foreign_windows) == 0 ]] && break; sleep 5; done
if [[ $(foreign_windows) != 0 ]]; then
  printf 'suite-preflight\tBLOCKED\t-\t-\t%s foreign NativeHTMLKit window(s) open on this desktop; suite not started\n' "$(foreign_windows)" | tee -a "$RESULTS"
  exit 3
fi
finish() { # NAME DETAIL : final hygiene check, then the completion marker
  local l u; sleep 1; l=$(leftovers); u=$(units); cleanup_own
  check suite-cleanup "own processes left at the end: $l, own units: $u (anything left was removed)" test "$l$u" = 00
  printf 'suite-complete\tPASS\t-\t-\t%s\n' "$1" | tee -a "$RESULTS"
}
if (( $# )); then
  for c in "$@"; do "case_$c"; done
  finish "partial run: $*"
else
  for c in "${ALL[@]}"; do "$c"; done
  finish "full suite: all ${#ALL[@]} case groups ran to the end"
fi
