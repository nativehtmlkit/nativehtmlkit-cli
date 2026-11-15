#!/usr/bin/env bash
# Complete Windows qualification of the CLI against one pinned Core host, in one command,
# started from the Linux workstation that holds the source:
#
#   scripts/lab/qualify-windows.sh HOST_PATH_ON_WINDOWS HOST_VERSION HOST_SHA256 EVIDENCE_DIR
#
# 1. the source tree (no target/, dist/, .git/) is copied to the Windows build VM together
#    with SOURCE-IDENTITY.json; the copy is accepted there only if its tree hash matches
# 2. scripts\qualify.py run   (on Windows: source gates, fake-host suites over named pipes,
#                              real host headless, packaging)       -> EVIDENCE_DIR/windows
# 3. the packaged .zip is extracted cleanly and tests\gui\windows-interactive.ps1 is run
#    INSIDE an interactive desktop session (an SSH session is not GUI evidence)
#                                                                   -> EVIDENCE_DIR/windows/gui
# Lab settings (environment):
#   NHK_LAB_WINDOWS_SSH          ssh destination, cmd.exe default shell (default administrator@winDEV)
#   NHK_LAB_WINDOWS_DIR          work directory, forward slashes      (default F:/agent-workspaces/nativehtmlkit/cli-qualify)
#   NHK_LAB_WINDOWS_PYTHON       Python >= 3.11 on that machine       (default python)
#   NHK_LAB_WINDOWS_INTERACTIVE  script that runs a .ps1 in the logged-in desktop of a user:
#                                <script> -UserName U -ScriptPath P -TimeoutSeconds N   (required)
#   NHK_LAB_WINDOWS_GUI_USER     that desktop's user                   (default nhk_gui)
#   NHK_LAB_WINDOWS_EXTRA_PATH   directory prepended to PATH for the gates, e.g. where cargo-deny.exe is (optional)
#   NHK_LAB_GUI_LOCK             lock file serialising use of the shared desktop (optional)
# Nothing is published and no remote build service is used.
set -uo pipefail
[[ $# == 4 ]] || { sed -n '2,23p' "$0"; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
HOST=$1; HOST_VERSION=$2; HOST_SHA=$3; mkdir -p "$4"; EV=$(cd "$4" && pwd)/windows
SSH=${NHK_LAB_WINDOWS_SSH:-administrator@winDEV}
WDIR=${NHK_LAB_WINDOWS_DIR:-F:/agent-workspaces/nativehtmlkit/cli-qualify}
PY=${NHK_LAB_WINDOWS_PYTHON:-python}
INTERACTIVE=${NHK_LAB_WINDOWS_INTERACTIVE:?set NHK_LAB_WINDOWS_INTERACTIVE to the interactive-session launcher script}
GUI_USER=${NHK_LAB_WINDOWS_GUI_USER:-nhk_gui}
EXTRA_PATH=${NHK_LAB_WINDOWS_EXTRA_PATH:-}   # e.g. the bin directory holding cargo-deny.exe
WIN=${WDIR//\//\\}; WINTERACTIVE=${INTERACTIVE//\//\\}
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH" "$@"; }
locked() { if [[ -n ${NHK_LAB_GUI_LOCK:-} ]]; then ( flock 9; "$@" ) 9>>"$NHK_LAB_GUI_LOCK"; else "$@"; fi; }
ps_file() { # NAME : stdin is a PowerShell script; it is copied (with a BOM for PowerShell 5.1) and run
  local tmp; tmp=$(mktemp); printf '\xef\xbb\xbf' > "$tmp"; cat >> "$tmp"
  scp -q "$tmp" "$SSH:$WDIR/$1" && rm -f "$tmp" && remote "powershell -NoProfile -ExecutionPolicy Bypass -File $WIN\\$1"
}
rm -rf "$EV"; mkdir -p "$EV/logs"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
NAME=nativehtmlkit-cli-v$VERSION-windows-x64
HARNESS="powershell -File windows-interactive.ps1  (inside the interactive desktop of $GUI_USER, clean extraction of $NAME.zip)"

# 1. Source copy. target/ is kept on the VM as a build cache; everything else is replaced.
python3 scripts/package-local.py --print-source-identity > SOURCE-IDENTITY.json
if ! remote "if not exist $WIN\\src mkdir $WIN\\src" ||
   ! ps_file sync-clean.ps1 <<PS
Get-ChildItem -Force '$WIN\\src' | Where-Object Name -ne 'target' | Remove-Item -Recurse -Force
Remove-Item -Recurse -Force '$WIN\\evidence','$WIN\\gui' -ErrorAction SilentlyContinue
PS
then
  echo "BLOCKED: cannot reach the Windows build VM over ssh ($SSH)" | tee "$EV/logs/blocked.txt"
  echo '[{"id":"cli.windows.suite","gate":"G0","status":"BLOCKED","command":"scripts/lab/qualify-windows.sh","platform":"windows-x64","source_tree_sha256":null,"host_sha256":null,"duration_s":null,"exit_code":null,"log":"logs/blocked.txt","detail":"Windows build VM unreachable over ssh"}]' > "$EV/results.json"
  rm -f SOURCE-IDENTITY.json; exit 1
fi
tar --exclude=./target --exclude=./dist --exclude=./.git --exclude=__pycache__ -cf - . | remote "tar -xf - -C $WDIR/src"
rm -f SOURCE-IDENTITY.json

# 2. All non-GUI gates and packaging, on Windows.
status=0
remote "cd /d $WIN\\src && ${EXTRA_PATH:+set \"PATH=$EXTRA_PATH;%PATH%\" && }$PY scripts\\qualify.py run --host $HOST --host-version $HOST_VERSION --host-sha256 $HOST_SHA --evidence $WIN\\evidence" \
  2>&1 | tee "$EV/logs/qualify-run.console.log"
[[ ${PIPESTATUS[0]} == 0 ]] || status=1

# 3. GUI: clean extraction, checksum verification, then the harness inside the desktop session.
locked ps_file gui-run.ps1 > "$EV/logs/cli.gui.harness.log" 2>&1 <<PS
\$ErrorActionPreference = 'Stop'
\$zip = '$WIN\\src\\dist\\$NAME.zip'
if (-not (Test-Path \$zip)) { 'NO-ARCHIVE'; exit 3 }
\$g = '$WIN\\gui'
New-Item -ItemType Directory -Force \$g | Out-Null
Expand-Archive \$zip -DestinationPath "\$g\\x"
Move-Item "\$g\\x\\$NAME" "\$g\\bin"; Remove-Item "\$g\\x"
Set-Location "\$g\\bin"
\$bad = 0
foreach (\$l in Get-Content SHA256SUMS) { \$d, \$n = \$l -split '  ', 2; if ((Get-FileHash \$n -Algorithm SHA256).Hash.ToLower() -ne \$d) { "MISMATCH \$n"; \$bad++ } }
"archive checksum mismatches: \$bad"; if (\$bad) { exit 4 }
Copy-Item '$WIN\\src\\tests\\gui\\windows-interactive.ps1' \$g
icacls \$g /grant "${GUI_USER}:(OI)(CI)M" /T /Q | Out-Null
"desktop sessions: \$((query user 2>&1 | Out-String).Trim())"
& '$WINTERACTIVE' -UserName '$GUI_USER' -ScriptPath "\$g\\windows-interactive.ps1" -TimeoutSeconds 2400
PS
echo "GUI launcher exit: $?" >> "$EV/logs/cli.gui.harness.log"

# 4. Evidence back to the workstation; GUI rows become records.
remote "tar -cf - -C $WDIR/evidence ." | tar -xf - -C "$EV" || status=1
mkdir -p "$EV/gui"; remote "tar -cf - -C $WDIR/gui/evidence ." 2>/dev/null | tar -xf - -C "$EV/gui" 2>/dev/null
scp -q "$SSH:$WDIR/src/dist/$NAME.zip" "$SSH:$WDIR/src/dist/$NAME.zip.sha256" "$SSH:$WDIR/src/dist/SHA256SUMS" "$EV/" 2>/dev/null
# Keep the Windows archive beside the Linux one and list both in dist/SHA256SUMS.
mkdir -p dist && cp "$EV/$NAME.zip" "$EV/$NAME.zip.sha256" dist/ 2>/dev/null &&
  (cd dist && sha256sum $(ls nativehtmlkit-cli-v$VERSION-*.tar.gz nativehtmlkit-cli-v$VERSION-*.zip 2>/dev/null) > SHA256SUMS)
find "$EV/gui" -type f -size +1M ! -name '*.png' -delete 2>/dev/null
SESSION="Windows interactive desktop of $GUI_USER on ${SSH#*@} ($(remote 'ver' | tr -d '\r' | grep -v '^$' | head -1)), real input via SendInput; UI Automation only locates elements"
if grep -q NO-ARCHIVE "$EV/logs/cli.gui.harness.log"; then
  python3 scripts/qualify.py add-gui --evidence "$EV" --session "$SESSION" --command "$HARNESS" \
    --blocked "no verified archive: packaging did not pass in this run"; status=1
else
  python3 scripts/qualify.py add-gui --evidence "$EV" --tsv "$EV/gui/results.tsv" --session "$SESSION" --command "$HARNESS" || status=1
fi
exit $status
