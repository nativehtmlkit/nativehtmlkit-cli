#!/usr/bin/env bash
# Frame-sequence recordings (real KWin screenshots taken during real input), assembled into
# GIFs. KWin's authorised screenshot API provides stills, so these are frame sequences, not
# screen video. Usage: linux-record.sh BIN_DIR OUT_DIR
set -uo pipefail
BIN=$(cd "$1" && pwd); OUT=$(mkdir -p "$2" && cd "$2" && pwd)
. ~/lab/bin/gui-env; export QT_QPA_PLATFORM=wayland; unset DISPLAY
export NATIVEHTMLKIT_HOST_BINARY="$BIN/nativehtmlkit-host"
frame() { spectacle -b -n -f -o "$1" >/dev/null 2>&1; }
launch() { setsid bash -c '"$0" "$@" < "$IN" > /dev/null 2>&1; echo $? > "$RC"' "$BIN/nhk" "$@" </dev/null >/dev/null 2>&1 & sleep 3; }

# 1. resize: bottom-right corner dragged in 10 steps, one frame per step
D=$OUT/resize; rm -rf "$D"; mkdir -p "$D"; printf 'alpha\nbeta\ngamma\n' > "$D/in.txt"
IN=$D/in.txt RC=$D/rc launch view --title 'Resize recording'
~/lab/bin/lab-move 1089 695; ydotool click 0x40 >/dev/null; sleep 0.2
frame "$D/f00.png"
for i in $(seq 1 10); do ydotool mousemove -x -25 -y -15 >/dev/null; sleep 0.25; frame "$(printf '%s/f%02d.png' "$D" "$i")"; done
for i in $(seq 11 20); do ydotool mousemove -x 25 -y 15 >/dev/null; sleep 0.25; frame "$(printf '%s/f%02d.png' "$D" "$i")"; done
ydotool click 0x80 >/dev/null; sleep 0.5; ~/lab/bin/lab-click 1076 72; sleep 2
magick -delay 30 -loop 0 "$D"/f*.png -resize 640x400 "$OUT/resize.gif"
echo "resize rc=$(cat "$D/rc" 2>/dev/null) frames=$(ls "$D"/f*.png | wc -l)"

# 2. scroll: 2000-row table scrolled with the mouse wheel, one frame per burst
D=$OUT/scroll; rm -rf "$D"; mkdir -p "$D"; seq -f 'row %g' 1 2000 > "$D/in.txt"
IN=$D/in.txt RC=$D/rc launch select --title 'Scroll recording'
~/lab/bin/lab-move 640 400; frame "$D/f00.png"
for i in $(seq 1 12); do for _ in 1 2 3 4 5; do ydotool mousemove -w -x 0 -y -15 >/dev/null; done; sleep 0.25; frame "$(printf '%s/f%02d.png' "$D" "$i")"; done
~/lab/bin/lab-click 882 636; sleep 2
magick -delay 35 -loop 0 "$D"/f*.png -resize 640x400 "$OUT/scroll.gif"
echo "scroll rc=$(cat "$D/rc" 2>/dev/null) frames=$(ls "$D"/f*.png | wc -l)"
