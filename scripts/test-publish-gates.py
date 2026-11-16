#!/usr/bin/env python3
"""Exercise every publish gate of scripts/package-local.py without publishing anything.

A throw-away Git repository stands in for this one and a fake `gh` on PATH stands in for the
GitHub CLI: it records how it was called and answers `release view` as each case needs. The
real `gh` is never reachable (PATH holds only the fake's directory and Git's), and the fake
has no network code. Run: python3 scripts/test-publish-gates.py
"""
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("package_local", HERE / "package-local.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

FAKE_GH = '''import json, os, sys
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["release", "view"]:
    sys.exit(0 if os.environ.get("FAKE_GH_RELEASE_EXISTS") == "1" else 1)
sys.exit(0)
'''


def git(repo, *args):
    done = subprocess.run(["git", "-c", "user.name=gate-test", "-c", "user.email=gate-test@localhost",
                           "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                          cwd=repo, capture_output=True, text=True)
    assert done.returncode == 0, (args, done.stderr)
    return done.stdout.strip()


def main() -> int:
    checks = []

    def check(name, got, want):
        ok = (want in got) if isinstance(want, str) and got is not None else got == want
        checks.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {got!r}")

    with tempfile.TemporaryDirectory(prefix="nhk-publish-gates-") as tmp:
        tmp = pathlib.Path(tmp)
        repo, tools, log = tmp / "repo", tmp / "tools", tmp / "gh.log"
        repo.mkdir(); tools.mkdir(); log.write_text("")
        (tools / "fake_gh.py").write_text(FAKE_GH)
        if os.name == "nt":
            (tools / "gh.cmd").write_text(f'@"{sys.executable}" "{tools / "fake_gh.py"}" %*\r\n')
        else:
            gh = tools / "gh"
            gh.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{tools / "fake_gh.py"}" "$@"\n')
            gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        git_dir = str(pathlib.Path(shutil.which("git")).parent)
        real_path = os.environ["PATH"]
        os.environ["FAKE_GH_LOG"] = str(log)
        packager.ROOT = repo            # every git/gh call of the gates now runs in the stand-in
        version = "9.9.9"

        git(repo, "init", "-q", "-b", "main")
        (repo / "file.txt").write_text("one\n")
        git(repo, "add", "."); git(repo, "commit", "-q", "-m", "first")
        first = git(repo, "rev-parse", "HEAD")
        (repo / "file.txt").write_text("two\n")
        git(repo, "commit", "-q", "-am", "second")
        identity = lambda: packager.source_identity("unused")

        os.environ["PATH"] = str(tools) + os.pathsep + git_dir
        (repo / "file.txt").write_text("uncommitted\n")
        check("dirty tree is refused", packager.publish_refusal(version, identity()), "Clean Git commit required")
        git(repo, "checkout", "-q", "--", "file.txt")
        check("missing tag is refused", packager.publish_refusal(version, identity()), "does not exist")
        git(repo, "tag", "v" + version, first)
        check("tag on another commit is refused", packager.publish_refusal(version, identity()), "does not point at HEAD")
        git(repo, "tag", "-f", "v" + version, "HEAD")
        os.environ["PATH"] = git_dir if not shutil.which("gh", path=git_dir) else str(tmp / "empty")
        (tmp / "empty").mkdir(exist_ok=True)
        if os.environ["PATH"] == str(tmp / "empty"):
            # Git shares its directory with a real gh: make only git reachable through a link/copy.
            link = tmp / "empty" / pathlib.Path(shutil.which("git", path=git_dir)).name
            try:
                link.symlink_to(shutil.which("git", path=git_dir))
            except OSError:
                shutil.copy2(shutil.which("git", path=git_dir), link)
        check("absent gh is refused", packager.publish_refusal(version, identity()), "gh CLI is required")
        os.environ["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        os.environ["FAKE_GH_RELEASE_EXISTS"] = "1"
        check("existing release is refused", packager.publish_refusal(version, identity()), "already exists")
        os.environ["FAKE_GH_RELEASE_EXISTS"] = "0"
        check("all gates pass on a clean tagged HEAD", packager.publish_refusal(version, identity()), None)

        archive = tmp / "archive.tar.gz"
        archive.write_bytes(b"not a real archive")
        head = git(repo, "rev-parse", "HEAD")
        check("stale staged manifest is refused at upload time",
              packager.publish(archive, version, {"source_commit": first, "source_dirty": False}), "not from a clean HEAD")
        check("dirty staged manifest is refused at upload time",
              packager.publish(archive, version, {"source_commit": head, "source_dirty": True}), "not from a clean HEAD")
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        check("no upload was attempted by any refused case", [c for c in calls if c[:2] == ["release", "create"]], [])
        check("upload step runs once for a clean staged manifest (against the fake)",
              packager.publish(archive, version, {"source_commit": head, "source_dirty": False}), None)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        creates = [c for c in calls if c[:2] == ["release", "create"]]
        check("exactly one `release create`, for the tag, with --verify-tag",
              len(creates) == 1 and creates[0][2] == "v" + version and "--verify-tag" in creates[0]
              and str(archive) in creates[0], True)
        sidecar = json.loads((tmp / "archive.tar.gz.published.json").read_text())
        check("sidecar records the upload", sidecar["published"] is True and sidecar["source_commit"] == head, True)
        os.environ["PATH"] = real_path
    print(f"{sum(checks)} of {len(checks)} publish-gate checks passed; nothing was published (fake gh only)")
    return 0 if all(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
