#!/usr/bin/env python3
"""Local qualification of the CLI against one exact Core host. No GUI, no network, no CI.

  python3 scripts/qualify.py run --host PATH --host-version 1.0.2 --host-sha256 HEX --evidence DIR

runs, in order: repository boundary check, rustfmt, clippy, unit tests, fake-host round-trip,
fault-injection and launcher end-to-end suites, the release build, checks of the release
binary against the *real* host (headless: handshake, liveness, deadline, diagnostics
correlation, privacy sentinel, frozen host, killed host) and packaging with the pinned host.
Every step becomes one record in DIR/results.json with status PASS, FAIL or BLOCKED, the exact
command, platform, source tree hash, host SHA-256, duration, exit code and log path. A failed
assertion is FAIL; BLOCKED is only used when a prerequisite is missing, with the cause.

Native GUI qualification is separate (tests/gui/); its result table is added with
  python3 scripts/qualify.py add-gui --evidence DIR --tsv results.tsv --session "KDE Wayland ..."
and per-platform result files are combined with
  python3 scripts/qualify.py merge --out results.json A/results.json B/results.json
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"
EXE = ".exe" if WINDOWS else ""
CLI = ROOT / "target" / "release" / ("nativehtmlkit" + EXE)
SENTINEL = "S3NTINEL-do-not-log-7f3a"


def load_packager():
    spec = importlib.util.spec_from_file_location("package_local", ROOT / "scripts" / "package-local.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def platform_label() -> str:
    system = "windows-x64" if WINDOWS else "linux-x64"
    return f"{system} ({platform.platform()}; no desktop session used)"


class Recorder:
    def __init__(self, evidence: pathlib.Path, tree: str, host_sha: str):
        self.evidence, self.tree, self.host_sha = evidence, tree, host_sha
        self.logs = evidence / "logs"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.results: list[dict] = []

    def add(self, ident, gate, status, command, started, exit_code, log, detail=""):
        entry = {
            "id": ident, "gate": gate, "status": status, "command": command,
            "platform": platform_label(), "source_tree_sha256": self.tree, "host_sha256": self.host_sha,
            "duration_s": round(time.monotonic() - started, 2), "exit_code": exit_code,
            "log": log.relative_to(self.evidence).as_posix() if log else None,
        }
        if detail:
            entry["detail"] = detail
        self.results.append(entry)
        print(f"{status:7} {gate} {ident} ({entry['duration_s']} s){' - ' + detail if detail else ''}", flush=True)
        self.save()

    def save(self):
        (self.evidence / "results.json").write_text(json.dumps(self.results, indent=1) + "\n")

    def command(self, ident, gate, args, timeout=1800, detail_from=None, requires=None):
        """One external command = one record. PASS only on exit 0."""
        log = self.logs / f"{ident}.log"
        started = time.monotonic()
        shown = " ".join(shlex.quote(str(a)) for a in args)
        if requires and not shutil.which(requires):
            self.add(ident, gate, "BLOCKED", shown, started, None, None, f"prerequisite missing: {requires} is not installed")
            return False
        with open(log, "w", encoding="utf-8") as sink:
            sink.write(f"$ {shown}\n")
            sink.flush()
            try:
                code = subprocess.run(args, cwd=ROOT, stdout=sink, stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                code = None
            except FileNotFoundError as error:
                self.add(ident, gate, "BLOCKED", shown, started, None, log, f"prerequisite missing: {error}")
                return False
        detail = detail_from(log.read_text(encoding="utf-8", errors="replace")) if detail_from and code == 0 else ""
        if code is None:
            detail = f"timed out after {timeout} s"
        self.add(ident, gate, "PASS" if code == 0 else "FAIL", shown, started, code, log, detail)
        return code == 0


def test_counts(text: str) -> str:
    totals = [0, 0, 0]
    for passed, failed, ignored in re.findall(r"test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored", text):
        totals = [totals[0] + int(passed), totals[1] + int(failed), totals[2] + int(ignored)]
    return f"{totals[0]} passed, {totals[1]} failed, {totals[2]} ignored"


# ------------------------------------------------------------------ real host (headless)

def pid_alive(pid: int) -> bool:
    if WINDOWS:
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(handle)
        return code.value == 259
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return False
    return not stat.rsplit(")", 1)[1].lstrip().startswith("Z")


def freeze(pid: int) -> None:
    """Stop every thread of the process without ending it: a host that has hung."""
    if WINDOWS:
        handle = ctypes.windll.kernel32.OpenProcess(0x0800, False, pid)  # SUSPEND_RESUME
        if not handle or ctypes.windll.ntdll.NtSuspendProcess(handle) != 0:
            raise AssertionError(f"cannot suspend process {pid}")
        ctypes.windll.kernel32.CloseHandle(handle)
    else:
        os.kill(pid, signal.SIGSTOP)


def kill(pid: int) -> None:
    if WINDOWS:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    else:
        os.kill(pid, signal.SIGKILL)


class Session:
    """One run of the release CLI against the real host in headless mode."""

    def __init__(self, host: pathlib.Path, work: pathlib.Path, args: list[str], stdin: str, env: dict | None = None):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="tmp-", dir=work))
        self.stderr_path = self.tmp / "stderr.txt"
        environment = {k: v for k, v in os.environ.items() if not k.startswith("NATIVEHTMLKIT_")}
        environment.update({"NATIVEHTMLKIT_CLI_TEST_HEADLESS": "1", "TMPDIR": str(self.tmp), "TMP": str(self.tmp),
                            "TEMP": str(self.tmp), **(env or {})})
        self.command = [str(CLI), "--host", str(host), *args]
        self.started = time.monotonic()
        with open(self.stderr_path, "wb") as sink:
            self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=sink, env=environment, cwd=self.tmp)
        self.process.stdin.write(stdin.encode())
        self.process.stdin.close()

    def stderr(self) -> str:
        return self.stderr_path.read_text(encoding="utf-8", errors="replace")

    def records(self) -> list[dict]:
        return [json.loads(line) for line in self.stderr().splitlines() if line.startswith('{"schema_version"')]

    def host_records(self) -> list[dict]:
        found = []
        for line in self.stderr().splitlines():
            if line.startswith("{") and not line.startswith('{"schema_version"'):
                try:
                    found.append(json.loads(line))
                except ValueError:
                    pass
        return found

    def wait_event(self, event: str, limit: float = 30) -> dict:
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            for record in self.records():
                if record["event"] == event:
                    return record
            if self.process.poll() is not None:
                break
            time.sleep(0.05)
        raise AssertionError(f"no {event} record; exit={self.process.poll()} stderr:\n{self.stderr()[-3000:]}")

    def finish(self, limit: float = 60):
        try:
            self.stdout = self.process.stdout.read()
            self.code = self.process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise AssertionError(f"CLI did not exit within {limit} s; stderr:\n{self.stderr()[-3000:]}")
        self.elapsed = time.monotonic() - self.started
        left = [p.name for p in self.tmp.iterdir() if p.name.startswith("nativehtmlkit-cli-")]
        assert not left, f"session directory left behind: {left}"
        return self


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def check_doctor(host, work, version):
    out = subprocess.run([str(CLI), "--host", str(host), "doctor"], capture_output=True, text=True, timeout=60)
    expect(out.returncode == 0, f"doctor exit {out.returncode}: {out.stderr}")
    expect(f"nativehtmlkit-host {version}" in out.stdout, f"host version line missing: {out.stdout}")
    return out.stdout.strip().replace("\n", " | ")


def check_deadline(host, work, version):
    s = Session(host, work, ["--diagnostics", "debug", "--liveness-interval", "0.3", "--rpc-timeout", "2",
                             "--timeout", "2.5", "select"], "alpha\nbeta\n").finish()
    expect(s.code == 124 and s.stdout == b"", f"exit {s.code}, stdout {s.stdout!r}\n{s.stderr()[-2000:]}")
    done = [r["operation"] for r in s.records() if r["event"] == "rpc.completed"]
    expect(done[:5] == ["host.hello", "host.diagnostics", "window.create", "document.load", "app.ready"], str(done))
    probes = done.count("host.capabilities")
    expect(probes >= 5, f"only {probes} liveness probes answered in 2.5 s")
    expect("error[" not in s.stderr(), s.stderr()[-2000:])
    hello = next(r for r in s.records() if r["event"] == "handshake.completed")
    expect(hello["context"]["host_version"] == version, str(hello))
    return f"exit 124 after {s.elapsed:.1f} s; real host answered handshake, load and {probes} liveness probes"


def check_correlation(host, work, version):
    session_id = "qualify-run.1:correlation"
    s = Session(host, work, ["--diagnostics", "trace", "--liveness-interval", "0.3", "--timeout", "1.2", "select"],
                "alpha\n", {"NATIVEHTMLKIT_DIAGNOSTIC_SESSION_ID": session_id}).finish()
    expect(s.code == 124, f"exit {s.code}\n{s.stderr()[-2000:]}")
    records = s.records()
    roles = {r["role"] for r in records}
    expect(roles == {"launcher", "backend"}, f"roles {roles}")
    expect(all(r["session_id"] == session_id for r in records), "a CLI record lost the inherited session id")
    started = next(r for r in records if r["event"] == "backend.started")
    expect(started["context"]["session_id_inherited_through_host"] is True, "backend did not inherit the id via the host")
    host_records = s.host_records()
    expect(host_records, "the host wrote no records")
    tagged = [r for r in host_records if r.get("diagnostic_session_id") == session_id]
    # Core tags its records, and traces each request by id, from 1.0.2 on. An older host cannot
    # satisfy this check (prerequisite missing); a 1.0.2+ host that does not is a failure.
    if not tagged and tuple(int(x) for x in re.findall(r"\d+", version)[:3]) < (1, 0, 2):
        raise Blocked(f"host {version} does not tag its records with diagnostic_session_id (Core >= 1.0.2 does); "
                      "CLI-side propagation through the host to the backend was verified")
    expect(tagged, f"host {version} wrote {len(host_records)} records, none tagged with the session id")
    expect(len(tagged) == len(host_records), "some host records carry a different session id")
    # Every request the CLI completed must be visible on the host side under the same id.
    cli_calls = {(r["request_id"], r["operation"]) for r in records if r["event"] == "rpc.completed"}
    seen = {event: {(r["fields"].get("id"), r["fields"].get("method")) for r in tagged
                    if r.get("fields", {}).get("event") == event} for event in ("rpc.received", "rpc.completed")}
    expect(len(cli_calls) >= 7, f"only {len(cli_calls)} CLI requests recorded")
    for event, pairs in seen.items():
        missing = sorted(cli_calls - pairs)
        expect(not missing, f"host trace has no {event} for CLI requests {missing[:5]}")
    return (f"{len(records)} CLI records and {len(tagged)} host records share {session_id}; all {len(cli_calls)} "
            "CLI request ids appear host-side as rpc.received and rpc.completed with the same method")


def check_privacy(host, work, version):
    s = Session(host, work, ["--diagnostics", "trace", "--liveness-interval", "0.2", "--timeout", "1.5", "select",
                             "--title", f"title {SENTINEL}"], f"one {SENTINEL}\ntwo {SENTINEL}\n").finish()
    expect(s.code == 124 and s.stdout == b"", f"exit {s.code}")
    text = s.stderr()
    expect(len(s.records()) >= 20, "trace level did not produce records")
    expect(SENTINEL not in text, "user data on stderr")
    expect(not re.search(r"[0-9a-fA-F]{64}", text), "a 64-hex string (launch token shape) on stderr")
    return f"{len(text.splitlines())} stderr lines at trace (CLI and host): no sentinel, no 64-hex credential"


def check_frozen_host(host, work, version):
    s = Session(host, work, ["--diagnostics", "debug", "--liveness-interval", "0.5", "--rpc-timeout", "2", "select"],
                "alpha\nbeta\n")
    host_pid = s.wait_event("host.spawned")["context"]["host_launcher_pid"]
    backend_pid = s.wait_event("window.ready")["pid"]
    time.sleep(1.2)  # healthy for a while: probes answered
    freeze(host_pid)
    frozen = time.monotonic()
    s.finish(limit=30)
    waited = time.monotonic() - frozen
    text = s.stderr()
    expect(s.code == 1 and s.stdout == b"", f"exit {s.code} stdout {s.stdout!r}\n{text[-2000:]}")
    expect("nativehtmlkit: error[host.unresponsive]: " in text, text[-2000:])
    expect(2.0 <= waited <= 12, f"detected after {waited:.1f} s (probe interval 0.5 s + deadline 2 s)")
    time.sleep(0.5)
    expect(not pid_alive(host_pid), "frozen host process was left running")
    expect(not pid_alive(backend_pid), "backend process was left running")
    return f"frozen host detected and killed {waited:.1f} s after it stopped answering; exit 1, stdout empty"


def check_killed_host(host, work, version):
    s = Session(host, work, ["--diagnostics", "debug", "select"], "alpha\nbeta\n")
    host_pid = s.wait_event("host.spawned")["context"]["host_launcher_pid"]
    backend_pid = s.wait_event("window.ready")["pid"]
    kill(host_pid)
    killed = time.monotonic()
    s.finish(limit=30)
    waited = time.monotonic() - killed
    text = s.stderr()
    expect(s.code == 1 and s.stdout == b"", f"a crashed host must be an error, not Cancel: exit {s.code}")
    code = re.search(r"^nativehtmlkit: error\[([a-z_.]+)\]: ", text, re.M)
    expect(code and code.group(1) in ("transport.disconnected", "host.failed"), text[-2000:])
    expect(waited <= 5, f"took {waited:.1f} s to notice")
    time.sleep(0.5)
    expect(not pid_alive(backend_pid), "backend process was left running")
    return f"host crash reported as error[{code.group(1)}] in {waited:.1f} s; exit 1, stdout empty"


def check_backend_failure_cause(host, work, version):
    """FR-R-01: the real host kills the backend as soon as its connection closes. The cause
    of a backend-side failure must be reported every time, not only when a race is won."""
    form = work / "too-many-nodes.html"
    form.write_text('<form id="nhk-form">' + "<p>x</p>" * 32760 + '<input name="a"></form>')
    codes = []
    for _ in range(10):
        s = Session(host, work, ["--timeout", "5", "form", "--html", str(form)], "").finish()
        text = s.stderr()
        expect(s.code == 1 and s.stdout == b"", f"exit {s.code}")
        found = re.search(r"^nativehtmlkit: error\[([a-z_.]+)\]: .*host code (-?\d+)", text, re.M)
        expect(found is not None, f"no classified error line:\n{text[-1500:]}")
        codes.append((found.group(1), found.group(2)))
        expect(any(r["event"] == "backend.failed" and r["error_code"] == "rpc.rejected" for r in s.records()),
               "no backend.failed record relayed")
    expect(set(codes) == {("rpc.rejected", "-32005")}, f"cause not reported deterministically: {codes}")
    return "10 of 10 runs: error[rpc.rejected] with host code -32005 and a relayed backend.failed record"


def check_document_limits(host, work, version):
    """FR-R-02/03: what the launcher accepts the host accepts, and what the host would refuse
    is refused by the launcher with input.invalid before a host process exists."""
    def table(rows, cols):
        return json.dumps([{f"c{j}": f"v{i}_{j}" for j in range(cols)} for i in range(rows)])
    accepted = Session(host, work, ["--diagnostics", "debug", "--timeout", "1", "select", "--input-format", "json"],
                       table(1870, 16)).finish()
    expect(accepted.code == 124, f"1870 x 16 (65,532 nodes by the documented formula) was not accepted: exit "
                                 f"{accepted.code}\n{accepted.stderr()[-1500:]}")
    for label, args, data, needle in [
        ("1871 x 16 JSON", ["select", "--input-format", "json"], table(1871, 16), "at most 1870 rows fit"),
        ("2000 x 32 JSON", ["select", "--input-format", "json"], table(2000, 32), "document nodes"),
        ("2000 lines of 600 bytes", ["view"], ("x" * 600 + "\n") * 2000, "1 MiB"),
    ]:
        refused = Session(host, work, ["--diagnostics", "debug", "--timeout", "1", *args], data).finish()
        text = refused.stderr()
        expect(refused.code == 1 and "nativehtmlkit: error[input.invalid]: " in text and needle in text,
               f"{label}: exit {refused.code}\n{text[-800:]}")
        expect(not any(r["event"] == "host.spawned" for r in refused.records()), f"{label}: a host was started")
    return "1870 x 16 accepted by the real host; 1871 x 16, 2000 x 32 and a 1.2 MB page refused as input.invalid before any host start"


class Blocked(Exception):
    pass


REAL_HOST_CHECKS = [
    ("cli.realhost.doctor", "G7", check_doctor),
    ("cli.realhost.session-liveness-deadline", "G7", check_deadline),
    ("cli.realhost.diagnostic-session-correlation", "G7", check_correlation),
    ("cli.realhost.document-limits", "G7", check_document_limits),
    ("cli.realhost.backend-failure-cause-reported", "G4", check_backend_failure_cause),
    ("cli.realhost.trace-privacy-sentinel", "G4", check_privacy),
    ("cli.realhost.frozen-host-detected", "G4", check_frozen_host),
    ("cli.realhost.killed-host-is-error", "G4", check_killed_host),
]


def run(a) -> int:
    packager = load_packager()
    tree = packager.source_tree_hash()
    host = a.host.resolve()
    if not host.is_file():
        print(f"host not found: {host}", file=sys.stderr)
        return 2
    host_sha = packager.sha256(host)
    evidence = a.evidence.resolve()
    recorder = Recorder(evidence, tree, host_sha)
    started = time.monotonic()
    pinned = a.host_sha256.strip().lower()
    identity = packager.source_identity(tree)
    (evidence / "identity.json").write_text(json.dumps({
        "source_tree_sha256": tree, **identity, "host": str(host), "host_version": a.host_version,
        "host_sha256": host_sha, "host_sha256_pinned": pinned, "toolchain": packager.toolchain(),
        "platform": platform_label()}, indent=1) + "\n")
    recorder.add("cli.host-pin", "G8", "PASS" if host_sha == pinned else "FAIL",
                 f"sha256 {host}", started, 0 if host_sha == pinned else 1, None,
                 f"host is {host_sha}, pinned {pinned}")
    if host_sha != pinned:
        return 1

    python = sys.executable
    recorder.command("cli.repo-boundaries", "G0", [python, "scripts/check-repo.py"])
    # Licences, sources and known advisories of every locked dependency (all targets), offline.
    recorder.command("cli.dependency-policy", "G0",
                     ["cargo", "deny", "--offline", "check", "licenses", "bans", "sources", "advisories"],
                     requires="cargo-deny", detail_from=lambda text: text.strip().splitlines()[-1])
    recorder.command("cli.fmt", "G0", ["cargo", "fmt", "--all", "--", "--check"])
    recorder.command("cli.clippy", "G0", ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"])
    recorder.command("cli.unit-tests", "G2", ["cargo", "test", "--locked", "--bins"], detail_from=test_counts)
    recorder.command("cli.fake-host-roundtrip", "G3", ["cargo", "test", "--locked", "--test", "fake_host_roundtrip"],
                     detail_from=test_counts)
    recorder.command("cli.fake-host-faults", "G4", ["cargo", "test", "--locked", "--test", "fake_host_faults"],
                     detail_from=test_counts)
    recorder.command("cli.launcher-e2e", "G4", ["cargo", "test", "--locked", "--test", "launcher_e2e"],
                     detail_from=test_counts)
    built = recorder.command("cli.release-build", "G0", [python, "scripts/build-release.py"])

    work = evidence / "realhost"
    work.mkdir(exist_ok=True)
    for ident, gate, check in REAL_HOST_CHECKS:
        began = time.monotonic()
        log = recorder.logs / f"{ident}.log"
        command = f"{CLI} --host {host} ... (NATIVEHTMLKIT_CLI_TEST_HEADLESS=1; see scripts/qualify.py {check.__name__})"
        if not built:
            recorder.add(ident, gate, "BLOCKED", command, began, None, None, "release build failed")
            continue
        try:
            detail, status, code = check(host, work, a.host_version), "PASS", 0
        except Blocked as blocked:
            detail, status, code = str(blocked), "BLOCKED", None
        except AssertionError as failure:
            detail, status, code = str(failure), "FAIL", 1
        except Exception as error:  # an unexpected defect in the check is a failure, not a pass
            detail, status, code = f"{type(error).__name__}: {error}", "FAIL", 1
        transcript = "\n\n".join(f"== {p.parent.name}/stderr.txt\n{p.read_text(encoding='utf-8', errors='replace')}"
                                 for p in sorted(work.glob("tmp-*/stderr.txt")))
        log.write_text(f"{command}\n{status}: {detail}\n\n{transcript}", encoding="utf-8")
        for stale in work.glob("tmp-*"):
            shutil.rmtree(stale, ignore_errors=True)
        recorder.add(ident, gate, status, command, began, code, log, detail.splitlines()[0][:400])

    if built:
        recorder.command("cli.package", "G8", [python, "scripts/package-local.py", "--host", str(host), "--host-version",
                                               a.host_version, "--host-sha256", pinned],
                         detail_from=lambda text: "; ".join(line.strip() for line in text.splitlines()[1:])[:500])
    else:
        recorder.add("cli.package", "G8", "BLOCKED", "scripts/package-local.py", time.monotonic(), None, None,
                     "release build failed")
    failed = [r["id"] for r in recorder.results if r["status"] == "FAIL"]
    blocked = [r["id"] for r in recorder.results if r["status"] == "BLOCKED"]
    print(f"\n{len(recorder.results)} records: {len(failed)} FAIL, {len(blocked)} BLOCKED -> {evidence / 'results.json'}")
    return 1 if failed else 0


def add_gui(a) -> int:
    """Turn a GUI harness results.tsv into records (one per case row)."""
    evidence = a.evidence.resolve()
    target = evidence / "results.json"
    results = json.loads(target.read_text()) if target.is_file() else []
    identity = json.loads((evidence / "identity.json").read_text())
    results = [r for r in results if not r["id"].startswith("cli.gui.")]
    base = {"gate": "G6", "command": a.command, "platform": a.session,
            "source_tree_sha256": identity["source_tree_sha256"], "host_sha256": identity["host_sha256"],
            "duration_s": None}
    if a.blocked or not a.tsv or not a.tsv.is_file():
        cause = a.blocked or f"the GUI harness produced no result table ({a.tsv})"
        status = "BLOCKED" if a.blocked else "FAIL"
        results.append({"id": "cli.gui.suite", **base, "status": status, "exit_code": None, "log": None, "detail": cause})
        target.write_text(json.dumps(results, indent=1) + "\n")
        print(f"GUI suite {status}: {cause}")
        return 1
    a.tsv = a.tsv.resolve()
    rows = a.tsv.read_text(encoding="utf-8-sig").splitlines()[1:]
    preflight = [row for row in rows if row.startswith("suite-preflight\tBLOCKED")]
    if preflight:
        rows = preflight  # the suite did not start; nothing else is evidence
    elif not any(row.startswith("suite-complete\tPASS") and "full suite" in row for row in rows):
        # A harness that died half-way must not look like a short, green suite.
        rows.append("suite-complete\tFAIL\t-\t-\tthe harness did not run the full suite to its end")
    for row in rows:
        if not row.strip():
            continue
        case, status, want, got, detail = (row.split("\t") + [""] * 5)[:5]
        expect(status in ("PASS", "FAIL", "BLOCKED"), f"unexpected status in {a.tsv}: {row}")
        log_dir = a.tsv.parent / case
        results.append({
            "id": f"cli.gui.{case}", **base, "status": status,
            "exit_code": int(got) if got.lstrip("-").isdigit() else None,
            "expected_exit_code": int(want) if want.lstrip("-").isdigit() else None,
            "log": (log_dir if log_dir.is_dir() else a.tsv).relative_to(evidence).as_posix(),
            "detail": detail,
        })
    target.write_text(json.dumps(results, indent=1) + "\n")
    gui = [r for r in results if r["id"].startswith("cli.gui.")]
    failed = [r["id"] for r in gui if r["status"] == "FAIL"]
    blocked = [r["id"] for r in gui if r["status"] == "BLOCKED"]
    print(f"{len(gui)} GUI records added ({len(failed)} FAIL, {len(blocked)} BLOCKED) -> {target}")
    return 1 if failed else 0


def merge(a) -> int:
    combined = []
    for source in a.inputs:
        combined += json.loads(source.read_text())
    a.out.write_text(json.dumps(combined, indent=1) + "\n")
    counts = {s: sum(r["status"] == s for r in combined) for s in ("PASS", "FAIL", "BLOCKED")}
    print(f"{len(combined)} records -> {a.out}: {counts}")
    return 1 if counts["FAIL"] else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    r = sub.add_parser("run", help="all non-GUI gates plus packaging against one pinned host")
    r.add_argument("--host", type=pathlib.Path, required=True)
    r.add_argument("--host-version", required=True)
    r.add_argument("--host-sha256", required=True)
    r.add_argument("--evidence", type=pathlib.Path, required=True)
    r.set_defaults(func=run)
    g = sub.add_parser("add-gui", help="add a tests/gui harness results.tsv to DIR/results.json")
    g.add_argument("--evidence", type=pathlib.Path, required=True)
    g.add_argument("--tsv", type=pathlib.Path, help="results.tsv inside the evidence directory")
    g.add_argument("--blocked", default="", help="record the GUI suite as BLOCKED with this cause instead")
    g.add_argument("--session", required=True, help="desktop session the harness ran in")
    g.add_argument("--command", required=True, help="exact harness command line")
    g.set_defaults(func=add_gui)
    m = sub.add_parser("merge", help="combine per-platform results.json files")
    m.add_argument("--out", type=pathlib.Path, required=True)
    m.add_argument("inputs", type=pathlib.Path, nargs="+")
    m.set_defaults(func=merge)
    a = parser.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
