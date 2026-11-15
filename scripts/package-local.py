#!/usr/bin/env python3
"""Stage the CLI with an exact, qualified Core host; verify from a clean extraction.

Publishing is a separate explicit act (--publish --confirm publish-VERSION) and is never
needed for local qualification. Linux archives are .tar.gz (keeps the executable bits and the
`nhk` symlink); Windows archives are .zip with `nhk.exe` as a byte-identical copy.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=30, **kw)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--host", type=pathlib.Path, required=True, help="Qualified Core host executable")
    p.add_argument("--host-version", required=True, help="Core release version of that host, e.g. 1.0.1")
    p.add_argument("--host-sha256", default="", help="Expected SHA-256 from the qualified Core release manifest")
    p.add_argument("--version", default=tomllib.loads((ROOT / "Cargo.toml").read_text())["package"]["version"])
    p.add_argument("--publish", action="store_true")
    p.add_argument("--confirm", default="")
    a = p.parse_args()
    if a.publish and a.confirm != "publish-" + a.version:
        p.error("Explicit --confirm publish-" + a.version + " required")
    cli = ROOT / "target" / "release" / ("nativehtmlkit.exe" if WINDOWS else "nativehtmlkit")
    if not cli.is_file():
        p.error("Compile the CLI locally first: " + str(cli))
    if not a.host.is_file():
        p.error("Missing qualified Core host binary")
    host_version = a.host_version.removeprefix("v")
    expected = {cli: f"nativehtmlkit {a.version}", a.host: f"nativehtmlkit-host {host_version}"}
    for exe, want in expected.items():
        magic = exe.read_bytes()[:4]
        if WINDOWS and not magic.startswith(b"MZ") or not WINDOWS and magic != b"\x7fELF":
            p.error(f"{exe} is not a native executable for this platform")
        got = run([str(exe), "--version"]).stdout.strip()
        if got != want:
            p.error(f"{exe.name} --version is {got!r}, expected {want!r}")
    host_sha = sha256(a.host)
    if a.host_sha256 and a.host_sha256.lower() != host_sha:
        p.error("Core host SHA-256 does not match the pinned release: " + host_sha)
    dirty = bool(run(["git", "status", "--porcelain"], cwd=ROOT).stdout.strip())
    if a.publish and dirty:
        p.error("Clean Git commit required before publishing")

    label = "windows-x64" if WINDOWS else "linux-x64"
    name = f"nativehtmlkit-cli-v{a.version}-{label}"
    stage = ROOT / "dist" / name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    host_name = "nativehtmlkit-host.exe" if WINDOWS else "nativehtmlkit-host"
    shutil.copy2(cli, stage / cli.name)
    shutil.copy2(a.host, stage / host_name)
    if WINDOWS:
        shutil.copy2(cli, stage / "nhk.exe")
    else:
        (stage / "nhk").symlink_to("nativehtmlkit")
    shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
    shutil.copy2(ROOT / "README.md", stage / "README.md")
    manifest = {
        "schema": 1,
        "component": "nativehtmlkit-cli",
        "version": a.version,
        "platform": label,
        "cli_sha256": sha256(cli),
        "host_version": host_version,
        "host_sha256": host_sha,
        "host_sha256_pinned": bool(a.host_sha256),
        "protocol_version": 1,
        "source_commit": run(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip() or "uncommitted",
        "source_dirty": dirty,
        "published": False,
    }
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    files = sorted(x for x in stage.iterdir() if x.is_file() and not x.is_symlink())
    (stage / "SHA256SUMS").write_text("".join(f"{sha256(f)}  {f.name}\n" for f in files))

    if WINDOWS:
        archive = stage.parent / (name + ".zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for f in sorted(stage.iterdir()):
                z.write(f, f"{name}/{f.name}")
    else:
        archive = stage.parent / (name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as t:
            t.add(stage, arcname=name)
    (stage.parent / (archive.name + ".sha256")).write_text(f"{sha256(archive)}  {archive.name}\n")

    # Verify from a clean extraction in an unrelated directory, running the extracted files.
    with tempfile.TemporaryDirectory(prefix="nhk-cli-verify-") as tmp:
        if WINDOWS:
            with zipfile.ZipFile(archive) as z:
                z.extractall(tmp)
        else:
            with tarfile.open(archive) as t:
                t.extractall(tmp, filter="data")
        out = pathlib.Path(tmp) / name
        for line in (out / "SHA256SUMS").read_text().splitlines():
            digest, fname = line.split("  ", 1)
            if sha256(out / fname) != digest:
                p.error(f"archive verification failed for {fname}")
        alias = out / ("nhk.exe" if WINDOWS else "nhk")
        env = {k: v for k, v in os.environ.items() if k != "NATIVEHTMLKIT_HOST_BINARY"}
        if run([str(alias), "--version"]).stdout.strip() != f"nativehtmlkit {a.version}":
            p.error("extracted nhk alias does not run")
        doctor = run([str(alias), "doctor"], env=env, cwd=tmp)
        if doctor.returncode != 0 or f"nativehtmlkit-host {host_version}" not in doctor.stdout or str(out) not in doctor.stdout:
            p.error("extracted CLI did not find its bundled host: " + doctor.stdout + doctor.stderr)
        bad = run([str(alias), "select", "--input-format", "json"], env=env, input="[1,")
        if bad.returncode != 1 or bad.stdout:
            p.error("extracted CLI did not fail closed on invalid input")
    print(f"staged and verified: {archive}\n  sha256 {sha256(archive)}\n  host   {host_sha} ({host_version})\n  cli    {manifest['cli_sha256']}")
    if a.publish:
        subprocess.run(["gh", "release", "create", "v" + a.version, str(archive), "--repo", "nativehtmlkit/nativehtmlkit-cli",
                        "--verify-tag", "--title", "NativeHTMLKit CLI v" + a.version, "--notes", "Locally built and qualified."], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
