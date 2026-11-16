#!/usr/bin/env python3
"""Run every tested code block of docs/linux/ against a real nativehtmlkit CLI, headless.

    python3 scripts/test-docs.py --cli PATH [--section linux] [--filter TEXT] [--keep]
    python3 scripts/test-docs.py --check-submit-cases FILE      (cases written by test-docs.ps1)

A code block is tested when an HTML comment directly above it says so. The comment is
invisible on the rendered page:

    <!-- test: exit=124 calls="124@3x1" -->
    ```bash
    printf 'a\\nb\\nc\\n' | nativehtmlkit select
    ```

Keys of `test:`:
  exit=N         exit status the whole block must end with (required)
  calls="..."    one STATUS@ROWSxCOLUMNS per CLI call, in order ("124@3x1 124@2x1"); `*` is a
                 wildcard; a call that never reached the host has shape `none`
  shim=off       run the block against the real executable (for usage errors and blocks that
                 give their own small --timeout); no calls are recorded then
  cli-timeout=S  deadline the shim gives each window (default 0.5)
  requires=X     skip unless X is available: git, journalctl, docker-real, windows, timedatectl

Blocks that follow a tested block (each preceded by its own comment) refine it:
  <!-- replay: call=N exit=S expect=E [keep=1] -->   run the block again, but hand it this
        block's content as the stdout of CLI call N (exit S) after the real call was
        accepted; the run must end with E. keep=1 also keeps the replays of the replay
        blocks before it (several windows in one script). Proves what a script does with a
        submitted result.
  <!-- stdout -->    the stdout of the previous run, exactly (trailing newlines ignored)
  <!-- stderr -->    every non-blank line must occur in the stderr of the previous run
  <!-- submit: call=N pick=2,3 -->   what CLI call N prints when the user ticks those rows
        (1-based, input order; empty = nothing ticked). Checked by feeding the call's real
        stdin and options to the released formatter (src/input.rs, src/output.rs and the
        selection rules of src/backend.rs at tag v0.1.2), compiled into a test binary.
        `rejected=empty` instead of a block: Submit is refused and the window stays open;
        `error=TEXT`: the CLI fails with that message (the block shows the error line).
  <!-- not-tested: REASON -->   a block that runs nativehtmlkit but is deliberately not run
        (installation, sudo, network); every other block that calls the CLI must be tested.
        REASON "excerpt of examples/FILE ..." marks a quoted part of an example script: every
        line of the block must occur in that file (the script itself is run elsewhere).

How a block runs: in a fresh copy of examples/ inside a fresh Git repository (branches main,
feature/login, release/1.4), with a `nativehtmlkit` shim first on PATH. The shim replaces
any --timeout with a short one, sets NATIVEHTMLKIT_CLI_TEST_HEADLESS=1 (the real host runs
without a window), runs the real CLI with debug diagnostics and records exit status, stdout
size and rows x columns per call; `docker` and `ssh` are harmless stand-ins. Nobody can click,
so every window ends with 124: a case proves that the input and options were accepted, the
document rendered and became ready, and that the block handles the outcome as documented.

Coverage (fails the run when missing): every option in `--help` of each command has a tested
block on commands/<command>.md that uses it with that command; every input and output format,
diagnostics level, environment variable and exit status has one on its page; every example
file named in examples/catalog.toml for this OS is run by a tested block of this section.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARK = re.compile(r"^<!--\s*(test|replay|stdout|stderr|submit|not-tested)\s*:?\s*(.*?)\s*-->\s*$")
FENCE = re.compile(r"^(```+|~~~+)\s*([A-Za-z0-9_-]*)")
KV = re.compile(r'([a-z-]+)=("(?:[^"\\]|\\.)*"|\S*)')
CLI_CALL = re.compile(r"(?<![\w/.-])(nativehtmlkit|nhk)(?![\w.-])")


def parse_kv(text: str) -> dict[str, str]:
    out = {}
    for k, v in KV.findall(text):
        out[k] = json.loads(v) if v.startswith('"') else v
    return out


def blocks_of(path: Path):
    """Yield (line, marker, attrs, lang, content) for every fenced block."""
    lines = path.read_text(encoding="utf-8").splitlines()
    i, pending = 0, None
    while i < len(lines):
        m = MARK.match(lines[i].strip())
        if m:
            pending = (m.group(1), m.group(2), i + 1)
            if m.group(1) == "submit" and ("rejected=" in m.group(2)):
                yield (i + 1, "submit", parse_kv(m.group(2)), "", None)
                pending = None
            i += 1
            continue
        f = FENCE.match(lines[i])
        if f:
            fence, lang, start = f.group(1), f.group(2), i + 1
            j = i + 1
            while j < len(lines) and not lines[j].startswith(fence):
                j += 1
            content = "\n".join(lines[i + 1 : j])
            if pending:
                yield (start, pending[0], parse_kv(pending[1]) if pending[0] != "not-tested" else {"reason": pending[1]}, lang, content)
            else:
                yield (start, None, {}, lang, content)
            pending = None
            i = j + 1
            continue
        if lines[i].strip():
            pending = None
        i += 1


SHIM = r'''#!/usr/bin/env bash
args=() skip=0 window=0
for a in "$@"; do
  if ((skip)); then skip=0; continue; fi
  case $a in
    --timeout) skip=1; continue ;;
    --timeout=*) continue ;;
    select|view|form) window=1 ;;
  esac
  args+=("$a")
done
d=$NHK_SHIM_DIR
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/count"
printf '%s\0' "${args[@]}" >"$d/$n.args"
extra=()
((window)) && extra=(--timeout "$NHK_T")
if [[ -n ${NHK_CAPTURE:-} ]]; then
  tee "$d/$n.in" <&0 | NATIVEHTMLKIT_DIAGNOSTICS=${NATIVEHTMLKIT_DIAGNOSTICS:-debug} "$NHK_REAL" "${args[@]}" "${extra[@]}" >"$d/$n.out" 2>"$d/$n.err" &
else
  NATIVEHTMLKIT_DIAGNOSTICS=${NATIVEHTMLKIT_DIAGNOSTICS:-debug} "$NHK_REAL" "${args[@]}" "${extra[@]}" <&0 >"$d/$n.out" 2>"$d/$n.err" &
fi
child=$!
for s in TERM INT HUP; do trap "kill -$s $child 2>/dev/null" "$s"; done
wait "$child"; rc=$?
while kill -0 "$child" 2>/dev/null; do wait "$child"; rc=$?; done
cat "$d/$n.err" >&2
shape=$(grep -o '"event":"session.started","context":{[^}]*}' "$d/$n.err" | sed -E 's/.*"rows":([0-9]+),"columns":([0-9]+).*/\1x\2/')
ready=notready; grep -q '"event":"window.ready"' "$d/$n.err" && ready=ready
[[ -z $shape ]] && ready=unknown   # --diagnostics off/normal given: no lifecycle records
err=clean; grep -q 'error\[' "$d/$n.err" && err=error
echo "$rc@${shape:-none} $(wc -c <"$d/$n.out") $ready $err" >>"$d/calls"
if [[ -f $d/replay/$n.rc ]]; then
  cat "$d/replay/$n.out"
  exit "$(cat "$d/replay/$n.rc")"
fi
cat "$d/$n.out"
exit "$rc"
'''

FAKE_DOCKER = r'''#!/usr/bin/env bash
echo "$*" >>"$NHK_SHIM_DIR/docker.log"
case $1 in
  ps)
    printf '%s\n' \
      '{"Command":"\"/docker-entrypoint.sh nginx\"","CreatedAt":"2026-11-16 09:00:00 +0000 UTC","ID":"3f2a9c1d7b44","Image":"nginx:1.27","Labels":"","LocalVolumes":"0","Mounts":"","Names":"web","Networks":"bridge","Ports":"0.0.0.0:8080->80/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}' \
      '{"Command":"\"docker-entrypoint.sh postgres\"","CreatedAt":"2026-11-15 18:00:00 +0000 UTC","ID":"9b8e7d6c5a43","Image":"postgres:17","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"db <primary>","Networks":"bridge","Ports":"5432/tcp","RunningFor":"17 hours ago","Size":"0B","State":"exited","Status":"Exited (0) 3 minutes ago"}' ;;
  logs) printf '2026-11-16T09:00:00Z ready\n2026-11-16T09:00:01Z <b>not markup</b> & more\n' ;;
esac
'''
FAKE_SSH = '#!/usr/bin/env bash\necho "ssh $*" >>"$NHK_SHIM_DIR/docker.log"\n'


class Harness:
    def __init__(self, cli: Path, section: str, keep: bool, flt: str):
        self.cli, self.section, self.keep, self.filter = cli, section, keep, flt
        self.work = Path(tempfile.mkdtemp(prefix="nhk-docs."))
        self.results: list[tuple[str, str, str]] = []
        self.submit_cases: list[dict] = []
        self.covered_text: dict[str, list[str]] = {}   # page -> tested block texts
        self.exit_seen: dict[str, set[int]] = {}
        (self.work / "bin").mkdir()
        (self.work / "fakebin").mkdir()
        (self.work / "tmp").mkdir()
        (self.work / "realbin").mkdir()
        shim = self.work / "bin/nativehtmlkit"
        shim.write_text(SHIM)
        shim.chmod(0o755)
        (self.work / "bin/nhk").symlink_to("nativehtmlkit")
        for name, text in (("docker", FAKE_DOCKER), ("ssh", FAKE_SSH)):
            p = self.work / "fakebin" / name
            p.write_text(text)
            p.chmod(0o755)
        (self.work / "realbin/nativehtmlkit").symlink_to(cli)
        (self.work / "realbin/nhk").symlink_to(cli)
        self.template = self.work / "template"
        self.make_template()

    def make_template(self):
        repo = self.template / "repo"
        shutil.copytree(ROOT / "examples", repo / "examples")
        env = dict(os.environ, GIT_AUTHOR_NAME="example", GIT_AUTHOR_EMAIL="example@example.invalid",
                   GIT_COMMITTER_NAME="example", GIT_COMMITTER_EMAIL="example@example.invalid")
        def git(*a, date=None):
            e = dict(env, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date) if date else env
            subprocess.run(["git", "-C", str(repo), *a], check=True, env=e, capture_output=True)
        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("commit", "-q", "-m", "Add the example scripts", date="2026-11-10T09:00:00Z")
        git("branch", "feature/login")
        git("branch", "release/1.4")
        git("switch", "-q", "-c", "fix/typo")
        (repo / "examples/TYPO.txt").write_text("fixed\n")
        git("add", "-A")
        git("commit", "-q", "-m", 'Fix the "quick start" typo', date="2026-11-12T09:00:00Z")
        git("switch", "-q", "main")
        git("merge", "-q", "--no-ff", "-m", "Merge fix/typo", "fix/typo", date="2026-11-14T09:00:00Z")

    def record(self, status: str, name: str, detail: str):
        self.results.append((status, name, detail))
        print(f"{status}\t{name}\t{detail}", flush=True)

    # -- running ---------------------------------------------------------------------------
    def run_block(self, name: str, code: str, attrs: dict, replay: tuple | None = None, capture=False):
        case = self.work / "cases" / re.sub(r"[^A-Za-z0-9_.-]", "_", name)
        if case.exists():
            shutil.rmtree(case)
        (case / "replay").mkdir(parents=True)
        fx = case / "fx"
        shutil.copytree(self.template, fx, symlinks=True)
        for n, rc, text in replay or ():
            (case / f"replay/{n}.rc").write_text(str(rc))
            (case / f"replay/{n}.out").write_text(text)
        script = case / "block.sh"
        script.write_text(code + "\n")
        shim_on = attrs.get("shim") != "off"
        first = self.work / ("bin" if shim_on else "realbin")
        env = {k: v for k, v in os.environ.items() if not k.startswith("NATIVEHTMLKIT")}
        env.update(PATH=f"{first}:{self.work / 'fakebin'}:{env['PATH']}", NHK_SHIM_DIR=str(case),
                   NHK_REAL=str(self.cli), NHK_T=attrs.get("cli-timeout", "0.5"),
                   NATIVEHTMLKIT_CLI_TEST_HEADLESS="1", TMPDIR=str(self.work / "tmp"),
                   HOME=str(fx / "home"), XDG_CONFIG_HOME=str(fx / "home/.config"))
        (fx / "home").mkdir()
        if capture:
            env["NHK_CAPTURE"] = "1"
        p = subprocess.run(["bash", str(script)], cwd=fx / "repo/examples", env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=180)
        calls = (case / "calls").read_text().splitlines() if (case / "calls").exists() else []
        return p, calls, case

    def check_run(self, name, p, calls, case, want, calls_want, replayed=()):
        problems = []
        if p.returncode != want:
            problems.append(f"exit {p.returncode}, want {want}")
        got = " ".join(c.split()[0] for c in calls)
        if calls_want is not None and not glob_match(calls_want, got):
            problems.append(f"calls '{got}', want '{calls_want}'")
        for i, c in enumerate(calls, 1):
            status_shape, size, ready, err = c.split()
            status = status_shape.split("@")[0]
            if i not in replayed and status != "0" and size != "0":
                problems.append(f"call {i} wrote stdout with exit {status}")
            if status == "124" and ready == "notready":
                problems.append(f"call {i}: document never became ready")
            if status == "124" and err != "clean":
                problems.append(f"call {i}: error line despite 124")
        if problems:
            self.record("FAIL", name, "; ".join(problems) + f" | stderr tail: {p.stderr.decode(errors='replace')[-400:]!r}")
        else:
            self.record("PASS", name, f"exit {p.returncode}; calls: {got or 'none'}")
        return not problems

    def page(self, path: Path):
        rel = path.relative_to(ROOT / "docs" / self.section).as_posix()
        blocks = list(blocks_of(path))
        k = 0
        while k < len(blocks):
            line, marker, attrs, lang, code = blocks[k]
            k += 1
            if marker == "not-tested":
                m = re.match(r"excerpt of (examples/[^\s,;]+)", attrs.get("reason", ""))
                if m and (not self.filter or self.filter in rel):
                    src = ROOT / m.group(1)
                    have = {l.strip() for l in src.read_text(encoding="utf-8").splitlines()} if src.is_file() else set()
                    missing = [l for l in (code or "").splitlines() if l.strip() and l.strip() not in have]
                    if missing:
                        self.record("FAIL", f"{rel}:{line}", f"excerpt differs from {m.group(1)}: {missing[:3]!r}")
                    else:
                        self.record("PASS", f"{rel}:{line}", f"excerpt matches {m.group(1)}")
                continue
            if marker is None:
                if marker is None and code and lang in ("bash", "sh", "shell", "console") and CLI_CALL.search(code):
                    self.record("FAIL", f"{rel}:{line}", "block calls the CLI but has no test: or not-tested: marker")
                continue
            if marker != "test":
                self.record("FAIL", f"{rel}:{line}", f"'{marker}' marker without a test block before it")
                continue
            name = f"{rel}:{line}" + (f" {attrs['name']}" if "name" in attrs else "")
            follow = []
            while k < len(blocks) and blocks[k][1] in ("replay", "stdout", "stderr", "submit"):
                follow.append(blocks[k])
                k += 1
            if self.filter and self.filter not in name:
                continue
            req = attrs.get("requires")
            if req and not available(req):
                self.record("SKIP", name, f"requires {req}")
                continue
            self.covered_text.setdefault(rel, []).append(code)
            want = int(attrs["exit"])
            capture = any(f[1] == "submit" for f in follow)
            p, calls, case = self.run_block(name, code, attrs, capture=capture)
            self.check_run(name, p, calls, case, want, attrs.get("calls"))
            self.note_exits(rel, want, calls)
            last = (p, case, calls)
            replays = []
            for fl, fm, fa, flang, fcode in follow:
                fname = f"{name} > {fm}@{fl}"
                if fm == "replay":
                    n, rc, expect = int(fa.get("call", 1)), int(fa.get("exit", 0)), int(fa["expect"])
                    text = fcode + "\n" if fcode else ""
                    replays = (replays if fa.get("keep") else []) + [(n, rc, text)]
                    rp, rcalls, rcase = self.run_block(fname, code, attrs, replay=replays)
                    self.check_run(fname, rp, rcalls, rcase, expect, None, replayed={r[0] for r in replays})
                    self.note_exits(rel, expect, [])
                    self.exit_seen.setdefault(rel, set()).add(rc)
                    last = (rp, rcase, rcalls)
                elif fm == "stdout":
                    got = last[0].stdout.decode("utf-8", "replace").replace("\r\n", "\n").rstrip("\n")
                    want_text = (fcode or "").rstrip("\n")
                    if got == want_text:
                        self.record("PASS", fname, "stdout as documented")
                    else:
                        self.record("FAIL", fname, f"stdout {got!r}, documented {want_text!r}")
                elif fm == "stderr":
                    err = last[0].stderr.decode("utf-8", "replace")
                    missing = [l for l in (fcode or "").splitlines() if l.strip() and l.strip() not in err]
                    if missing:
                        self.record("FAIL", fname, f"not in stderr: {missing!r}")
                    else:
                        self.record("PASS", fname, "stderr lines as documented")
                elif fm == "submit":
                    n = int(fa.get("call", 1))
                    argf, inf = case / f"{n}.args", case / f"{n}.in"
                    if not argf.exists():
                        self.record("FAIL", fname, f"call {n} did not happen")
                        continue
                    argv = [a for a in argf.read_bytes().decode().split("\0") if a]
                    stdin = inf.read_bytes().decode("utf-8", "replace") if inf.exists() else ""
                    self.submit_cases.append(submit_case(fname, argv, stdin, fa, fcode))
                    self.note_exits(rel, 1 if "error" in fa else 0, [])

    def note_exits(self, rel, want, calls):
        s = self.exit_seen.setdefault(rel, set())
        s.add(want)
        for c in calls:
            s.add(int(c.split("@")[0]))

    # -- coverage --------------------------------------------------------------------------
    def coverage(self):
        def has(page, *needles):
            return any(all(n in t for n in needles) for t in self.covered_text.get(page, []))
        def help_options(*cmd):
            text = subprocess.run([str(self.cli), *cmd, "--help"], capture_output=True, text=True).stdout
            return sorted(set(re.findall(r"^\s+(?:-\w, )?(--[a-z-]+)", text, re.M)))
        for cmd in ("select", "view", "form", "doctor"):
            page = f"commands/{cmd}.md"
            for opt in help_options(cmd):
                ok = has(page, cmd, opt)
                self.record("PASS" if ok else "FAIL", f"coverage {page} {opt}", "tested example" if ok else "no tested example uses it")
        for opt in help_options():   # options of the program itself (--version, --help)
            ok = any(has(f"commands/{c}.md", opt) for c in ("select", "view", "form", "doctor"))
            self.record("PASS" if ok else "FAIL", f"coverage nativehtmlkit {opt}", "tested example" if ok else "missing")
        for short in ("-h", "-V"):
            ok = any(re.search(r"(?<![\w-])" + short + r"(?![\w-])", x) for x in self.covered_text.get("commands/doctor.md", []))
            self.record("PASS" if ok else "FAIL", f"coverage nativehtmlkit {short}", "tested example" if ok else "missing")
        ok = has("commands/doctor.md", "help select")
        self.record("PASS" if ok else "FAIL", "coverage nativehtmlkit help COMMAND", "tested example" if ok else "missing")
        checks = [("input-formats.md", f"--input-format {f}") for f in ("lines", "csv", "tsv", "json", "ndjson")]
        checks += [("input-formats.md", "--no-headers")]
        checks += [("output-formats.md", f"--output-format {f}") for f in ("same", "lines", "csv", "tsv", "json", "ndjson")]
        checks += [("environment-and-diagnostics.md", f"--diagnostics {lvl}") for lvl in ("off", "normal", "debug", "trace")]
        checks += [("environment-and-diagnostics.md", v) for v in ("NATIVEHTMLKIT_HOST_BINARY", "NATIVEHTMLKIT_DIAGNOSTICS", "NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID")]
        checks += [("css-and-forms.md", "--css"), ("css-and-forms.md", "--html")]
        for page, needle in checks:
            ok = has(page, needle)
            self.record("PASS" if ok else "FAIL", f"coverage {page} {needle}", "tested example" if ok else "missing")
        subs = [c for c in self.submit_cases if "/output-formats.md" in "/" + c["name"]]
        for f in ("same", "lines", "csv", "tsv", "json", "ndjson"):
            ok = any(c["output_format"] == f and c["explicit_output"] for c in subs) or (f == "same" and any(not c["explicit_output"] for c in subs))
            self.record("PASS" if ok else "FAIL", f"coverage output-formats.md submit output {f}", "verified output" if ok else "missing")
        exits = [0, 1, 2, 124, 129, 130, 143] if self.section == "linux" else [0, 1, 2, 124, 130]
        seen = self.exit_seen.get("exit-codes-and-scripting.md", set())
        for e in exits:
            self.record("PASS" if e in seen else "FAIL", f"coverage exit-codes-and-scripting.md exit {e}", "tested" if e in seen else "missing")
        cat = tomllib.loads((ROOT / "examples/catalog.toml").read_text())
        key = "linux" if self.section == "linux" else "windows"
        for ex in cat["example"]:
            f = ex.get(key)
            if not f:
                continue
            ok = any(re.search(r"(?<![\w/.-])(\./)?" + re.escape(f) + r"(?![\w.-])", text)
                     for texts in self.covered_text.values() for text in texts)
            self.record("PASS" if ok else "FAIL", f"coverage catalog {ex['id']} {f}", "run by a tested block" if ok else "no tested block runs it")

    def finish(self, extra_cases: Path | None):
        cases = self.submit_cases
        if extra_cases:
            cases = cases + json.loads(extra_cases.read_text())
        if cases:
            check_submit(cases, self.work, self.record)
        p = sum(1 for r in self.results if r[0] == "PASS")
        f = sum(1 for r in self.results if r[0] == "FAIL")
        s = sum(1 for r in self.results if r[0] == "SKIP")
        left = subprocess.run(["pgrep", "-f", str(self.cli.parent / "nativehtmlkit-host")], capture_output=True, text=True).stdout.split()
        dirs = list((self.work / "tmp").iterdir())
        if left or dirs:
            f += 1
            print(f"FAIL\tzz-no-leftovers\thost processes {len(left)}, session dirs {len(dirs)}")
        else:
            p += 1
            print("PASS\tzz-no-leftovers\tno host process left, every private session directory removed")
        version = subprocess.run([str(self.cli), "--version"], capture_output=True, text=True).stdout.strip()
        print(f"test-docs ({self.section}): {p} PASS, {f} FAIL, {s} SKIP ({version}, work dir {self.work})")
        if f == 0 and not self.keep:
            shutil.rmtree(self.work, ignore_errors=True)
        return f == 0


def glob_match(pattern: str, text: str) -> bool:
    rx = "^" + ".*".join(re.escape(x) for x in pattern.split("*")) + "$"
    return re.match(rx, text) is not None


def available(req: str) -> bool:
    if req == "windows":
        return os.name == "nt"
    if req == "journalctl":
        return shutil.which("journalctl") is not None and subprocess.run(["journalctl", "-n", "1", "--no-pager"], capture_output=True).returncode == 0
    if req == "timedatectl":
        return shutil.which("timedatectl") is not None and subprocess.run(["timedatectl", "list-timezones"], capture_output=True).returncode == 0
    return shutil.which(req) is not None


def submit_case(name, argv, stdin, attrs, code) -> dict:
    def opt(flag, default):
        for i, a in enumerate(argv):
            if a == flag and i + 1 < len(argv):
                return argv[i + 1]
            if a.startswith(flag + "="):
                return a.split("=", 1)[1]
        return default
    out_fmt = opt("--output-format", None)
    pick = attrs.get("pick", "")
    return {
        "name": name,
        "command": next((a for a in argv if a in ("select", "view", "form")), ""),
        "stdin": stdin,
        "input_format": opt("--input-format", "lines"),
        "output_format": out_fmt or "same",
        "explicit_output": out_fmt is not None,
        "no_headers": "--no-headers" in argv,
        "multi": "--multi" in argv,
        "allow_empty": "--allow-empty" in argv,
        "picks": [int(x) for x in pick.split(",") if x.strip()],
        "expect": None if ("error" in attrs or "rejected" in attrs) else ((code + "\n") if code else ""),
        "expect_error": attrs.get("error"),
        "expect_rejected": attrs.get("rejected"),
    }


def check_submit(cases: list[dict], work: Path, record) -> None:
    """Compile the released formatter with a test that replays every submit case."""
    src = work / "formatter"
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    tag = "v0.1.2"
    archive = subprocess.run(["git", "-C", str(ROOT), "archive", tag, "src", "tests", "Cargo.toml", "Cargo.lock"], capture_output=True)
    if archive.returncode != 0:
        record("FAIL", "submit-outputs", f"git archive {tag} failed: {archive.stderr.decode()[:200]}")
        return
    subprocess.run(["tar", "-x", "-C", str(src)], input=archive.stdout, check=True)
    shutil.copy(ROOT / "scripts/doc-outputs/doc_outputs.rs", src / "src/doc_outputs.rs")
    with open(src / "src/backend.rs", "a") as f:
        f.write('\n#[cfg(test)]\n#[path = "doc_outputs.rs"]\nmod doc_outputs;\n')
    for c in cases:
        if c.get("command") != "select":
            record("FAIL", c["name"], "submit: is only defined for select")
    cases = [c for c in cases if c.get("command") == "select"]
    (work / "submit-cases.json").write_text(json.dumps(cases, ensure_ascii=False, indent=1))
    env = dict(os.environ, NHK_DOC_OUTPUT_CASES=str(work / "submit-cases.json"),
               CARGO_TARGET_DIR=str(ROOT / "target/doc-outputs"))
    p = subprocess.run(["cargo", "test", "--offline", "--quiet", "--bin", "nativehtmlkit", "doc_outputs", "--", "--nocapture"],
                       cwd=src, env=env, capture_output=True, text=True)
    seen = set()
    for line in p.stdout.splitlines():
        m = re.match(r"^DOC-OUTPUT (PASS|FAIL)\t(.*?)\t(.*)$", line)
        if m:
            seen.add(m.group(2))
            record(m.group(1), m.group(2), m.group(3))
    for c in cases:
        if c["name"] not in seen:
            record("FAIL", c["name"], "formatter check did not report this case: " + (p.stderr[-600:] or p.stdout[-600:]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cli", default=os.environ.get("NATIVEHTMLKIT_CLI") or shutil.which("nativehtmlkit"))
    ap.add_argument("--section", default="linux")
    ap.add_argument("--filter", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--check-submit-cases", type=Path, help="also verify submit cases recorded by test-docs.ps1")
    ap.add_argument("--only-submit-cases", action="store_true", help="verify --check-submit-cases and nothing else")
    a = ap.parse_args()
    if a.only_submit_cases:
        work = Path(tempfile.mkdtemp(prefix="nhk-docs-submit."))
        res = []
        def rec(s, n, d):
            res.append(s)
            print(f"{s}\t{n}\t{d}", flush=True)
        check_submit(json.loads(a.check_submit_cases.read_text(encoding="utf-8-sig")), work, rec)
        print(f"submit cases: {res.count('PASS')} PASS, {res.count('FAIL')} FAIL")
        return 0 if res and "FAIL" not in res else 1
    if not a.cli or not os.access(a.cli, os.X_OK):
        print("test-docs: no nativehtmlkit executable (use --cli PATH)", file=sys.stderr)
        return 1
    cli = Path(os.path.realpath(a.cli))
    h = Harness(cli, a.section, a.keep, a.filter)
    for page in sorted((ROOT / "docs" / a.section).rglob("*.md")):
        h.page(page)
    if not a.filter:
        h.coverage()
    return 0 if h.finish(a.check_submit_cases) else 1


if __name__ == "__main__":
    sys.exit(main())
