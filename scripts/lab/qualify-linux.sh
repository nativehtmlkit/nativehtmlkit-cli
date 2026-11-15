#!/usr/bin/env bash
# Complete Linux qualification of the CLI against one pinned Core host, in one command:
#
#   scripts/lab/qualify-linux.sh HOST_PATH HOST_VERSION HOST_SHA256 EVIDENCE_DIR
#
# 1. scripts/qualify.py run   (this machine: source gates, fake-host suites, real host
#                              headless, packaging)                 -> EVIDENCE_DIR/linux
# 2. the packaged archive is copied to a machine with a real KDE Plasma Wayland session,
#    extracted cleanly and driven by tests/gui/linux-kde-wayland.sh  -> EVIDENCE_DIR/linux/gui
#
# Lab settings (environment):
#   NHK_LAB_LINUX_SSH   ssh destination of the Wayland session machine   (default linuxDEV)
#   NHK_LAB_LINUX_DIR   work directory there            (default ~/projects/nhk-cli-qualify)
#   NHK_LAB_GUI_LOCK    lock file serialising use of the shared desktop  (optional)
# Nothing is published and no remote build service is used.
set -uo pipefail
[[ $# == 4 ]] || { sed -n '2,16p' "$0"; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
HOST=$1; HOST_VERSION=$2; HOST_SHA=$3; mkdir -p "$4"; EV=$(cd "$4" && pwd)/linux
SSH=${NHK_LAB_LINUX_SSH:-linuxDEV}; REMOTE=${NHK_LAB_LINUX_DIR:-projects/nhk-cli-qualify}
locked() { if [[ -n ${NHK_LAB_GUI_LOCK:-} ]]; then ( flock 9; "$@" ) 9>>"$NHK_LAB_GUI_LOCK"; else "$@"; fi; }
rm -rf "$EV"; mkdir -p "$EV"
status=0
python3 scripts/qualify.py run --host "$HOST" --host-version "$HOST_VERSION" --host-sha256 "$HOST_SHA" --evidence "$EV" || status=1

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
NAME=nativehtmlkit-cli-v$VERSION-linux-x64
HARNESS="bash linux-kde-wayland.sh run/$NAME run/evidence"
if ! python3 - "$EV/results.json" <<'PY'
import json, sys
sys.exit(0 if any(r["id"] == "cli.package" and r["status"] == "PASS" for r in json.load(open(sys.argv[1]))) else 1)
PY
then
  python3 scripts/qualify.py add-gui --evidence "$EV" --session "KDE Wayland ($SSH)" --command "$HARNESS" \
    --blocked "no verified archive: packaging did not pass in this run"
  exit 1
fi
cp "dist/$NAME.tar.gz" "dist/$NAME.tar.gz.sha256" "$EV/"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH" "mkdir -p $REMOTE && rm -rf $REMOTE/run" ||
   ! rsync -a "dist/$NAME.tar.gz" tests/gui/linux-kde-wayland.sh "$SSH:$REMOTE/"; then
  python3 scripts/qualify.py add-gui --evidence "$EV" --session "KDE Wayland ($SSH)" --command "$HARNESS" \
    --blocked "cannot reach the Wayland session machine over ssh ($SSH)"
  exit 1
fi
# The harness itself refuses to start while another NativeHTMLKit window is open and removes
# everything it started before it returns, i.e. before the lock is released.
gui_stage() {
  # -tt: if this side dies, the remote harness gets SIGHUP and its exit trap still cleans up.
  ssh -tt -o BatchMode=yes "$SSH" "cd $REMOTE && mkdir run && tar xzf $NAME.tar.gz -C run &&
    (cd run/$NAME && sha256sum --quiet -c SHA256SUMS) && $HARNESS; echo own-processes-after-suite: \$(pgrep -f '^'\$PWD/run/ | wc -l); echo host-units-at-end: \$(systemctl --user list-units 'nativehtmlkit-host-*' --no-legend --plain | wc -l)"
}
# Clean extraction, checksum verification of every packaged file, then real input.
locked gui_stage > "$EV/logs/cli.gui.harness.log" 2>&1
echo "GUI harness exit: $?" >> "$EV/logs/cli.gui.harness.log"
SESSION=$(ssh -o BatchMode=yes "$SSH" '. ~/lab/bin/gui-env 2>/dev/null; echo "KDE Plasma $(plasmashell --version 2>/dev/null | awk "{print \$2}") $XDG_SESSION_TYPE, $(. /etc/os-release; echo $PRETTY_NAME), $(hostname), real input via ydotool/uinput"')
rsync -a "$SSH:$REMOTE/run/evidence/" "$EV/gui/" 2>/dev/null
find "$EV/gui" -type f -size +1M ! -name '*.png' -delete 2>/dev/null   # generated bulk fixtures (8 MiB input)
python3 scripts/qualify.py add-gui --evidence "$EV" --tsv "$EV/gui/results.tsv" --session "$SESSION" \
  --command "$HARNESS  (in a clean extraction of $NAME.tar.gz on $SSH)" || status=1
exit $status
