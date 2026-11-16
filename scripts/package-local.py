#!/usr/bin/env python3
"""Stage the CLI with an exact, qualified Core host and verify the archive from a clean extraction.

The Core host is never built here. It is an input: the executable inside an unpacked Core
release directory (with release-manifest.json, LICENSE, THIRD_PARTY_NOTICES.md, licenses/),
identified by path AND by the SHA-256 the Core release recorded for it; a mismatch stops
packaging. Output for the current platform:

  dist/nativehtmlkit-cli-v<version>-<platform>/          staged tree (manifest.json, SHA256SUMS,
                                                         licenses/cli full texts, licenses/core
                                                         copied from the pinned Core release)
  dist/nativehtmlkit-cli-v<version>-<platform>.tar.gz    (.zip on Windows) + .sha256
  dist/SHA256SUMS                                        one line per archive in dist/

Linux archives are .tar.gz (keeps executable bits and the `nhk` symlink); Windows archives are
.zip with `nhk.exe` as a byte-identical copy. Publishing is a separate explicit act
(--publish --confirm publish-VERSION) and is never needed for local qualification.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"
PROTOCOL_VERSION = 1


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=60, **kw)


# Mirrors .gitignore. A plain walk (not `git ls-files`) so that a source copy without Git
# metadata, e.g. the tree synced to the Windows build VM, hashes identically.
IGNORED_DIRS = {"target", "dist", "verification", ".git"}
IGNORED_NAMES = {".DS_Store", "SOURCE-IDENTITY.json"}
# The results document is written after a qualification run and names the tree hash that was
# qualified; including it would change that hash by recording it.
IGNORED_PATHS = {"docs/QUALIFICATION.md"}


def source_files() -> list[str]:
    found = []
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if rel.parts[0] in IGNORED_DIRS or path.name in IGNORED_NAMES or path.suffix == ".log":
            continue
        if "__pycache__" in rel.parts or rel.as_posix() in IGNORED_PATHS or not path.is_file():
            continue
        found.append(rel.as_posix())
    return sorted(found)


def source_tree_hash() -> str:
    """Content hash of the source tree, independent of commit state, timestamps and
    line-ending checkout settings (CR LF is hashed as LF so Linux and Windows agree)."""
    digest = hashlib.sha256()
    for name in source_files():
        data = (ROOT / name).read_bytes()
        if b"\0" not in data:
            data = data.replace(b"\r\n", b"\n")
        digest.update(name.encode() + b"\0" + hashlib.sha256(data).digest())
    return digest.hexdigest()


def source_identity(tree: str) -> dict:
    """Commit and dirty state. From Git when this is a checkout; otherwise from the
    SOURCE-IDENTITY.json a sync step wrote on the origin machine, accepted only if the tree
    hash recorded there equals the hash of the files actually present here."""
    head = run(["git", "rev-parse", "HEAD"], cwd=ROOT)
    inside = run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT)
    if head.returncode == 0 and inside.returncode == 0 and pathlib.Path(inside.stdout.strip()).resolve() == ROOT:
        dirty = bool(run(["git", "status", "--porcelain"], cwd=ROOT).stdout.strip())
        return {"source_commit": head.stdout.strip(), "source_dirty": dirty, "source_identity": "git"}
    record = ROOT / "SOURCE-IDENTITY.json"
    if record.is_file():
        data = json.loads(record.read_text())
        if data.get("source_tree_sha256") != tree:
            raise SystemExit("SOURCE-IDENTITY.json does not describe the files present (tree hash differs)")
        return {"source_commit": data["source_commit"], "source_dirty": data["source_dirty"],
                "source_identity": "SOURCE-IDENTITY.json (tree hash verified)"}
    return {"source_commit": "unknown", "source_dirty": None, "source_identity": "none (no Git metadata)"}


def toolchain() -> dict:
    rustc = run(["rustc", "-vV"]).stdout
    fields = dict(line.split(": ", 1) for line in rustc.splitlines() if ": " in line)
    return {
        "rustc": rustc.splitlines()[0] if rustc else "unknown",
        "cargo": run(["cargo", "-V"]).stdout.strip() or "unknown",
        "target": fields.get("host", "unknown"),
        "profile": "release (lto=thin, codegen-units=1, strip=debuginfo), --locked",
    }


LICENCE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|COPYRIGHT|UNLICENSE|AUTHORS)([-._].*)?$", re.IGNORECASE)


def third_party_licences() -> tuple[str, dict]:
    """Full licence texts of every crate linked into the CLI for this build target.

    Same method as Core's scripts/release-local.py: the exact normal-dependency set for the
    target comes from `cargo tree` (cargo metadata over-approximates across targets), the
    details and source directories from `cargo metadata`. A crate with neither a licence
    file nor a declared licence stops packaging.
    """
    target = toolchain()["target"]
    meta = run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1", "--filter-platform", target], cwd=ROOT)
    tree = run(["cargo", "tree", "--locked", "--offline", "-e", "normal", "--target", target,
                "--prefix", "none", "--format", "{p}"], cwd=ROOT)
    if meta.returncode != 0 or tree.returncode != 0:
        raise SystemExit("cargo metadata/tree failed: " + (meta.stderr or tree.stderr).strip())
    data = json.loads(meta.stdout)
    workspace = set(data["workspace_members"])
    by_key = {(p["name"], p["version"]): p for p in data["packages"] if p["id"] not in workspace}
    own = {p["name"] for p in data["packages"] if p["id"] in workspace}
    keys = set()
    for line in tree.stdout.splitlines():
        match = re.match(r"^(\S+) v(\S+)", line.strip())
        if match and match.group(1) not in own:
            keys.add((match.group(1), match.group(2)))
    unknown = sorted(f"{n} {v}" for n, v in keys - by_key.keys())
    if unknown or not keys:
        raise SystemExit(f"cargo tree and cargo metadata disagree: {unknown or 'empty tree'}")
    sections, missing, declared_only = [], [], []
    for name, version in sorted(keys):
        pkg = by_key[(name, version)]
        if not (pkg.get("source") or "").startswith("registry+"):
            raise SystemExit(f"{name} {version}: non-registry dependency cannot be attributed")
        directory = pathlib.Path(pkg["manifest_path"]).parent
        found = {e.name: e for e in directory.iterdir() if e.is_file() and LICENCE_FILE.match(e.name)}
        if pkg.get("license_file") and (directory / pkg["license_file"]).is_file():
            found.setdefault(pkg["license_file"], directory / pkg["license_file"])
        licence = pkg.get("license") or ""
        if not found and not licence:
            missing.append(f"{name} {version}")
            continue
        lines = ["=" * 78, f"{name} {version}", f"Declared licence: {licence or '(none; see licence text below)'}",
                 f"Repository: {pkg.get('repository') or '(not declared)'}",
                 f"Source: crates.io package {name} {version}: https://crates.io/crates/{name}/{version}"]
        if found:
            for file_name in sorted(found):
                text = found[file_name].read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
                lines += ["", f"--- {file_name} ---", text.rstrip("\n")]
        else:
            declared_only.append(f"{name} {version}")
            lines += ["", "(The package ships no licence or notice file; its declared SPDX licence applies.)"]
        sections.append("\n".join(lines))
    if missing:
        raise SystemExit("crates without licence text or declared licence: " + ", ".join(missing))
    header = ["Third-party software in nativehtmlkit / nhk (the CLI executable)",
              f"Build target: {target}. Generated by scripts/package-local.py: crate set from",
              f"`cargo tree --locked -e normal --target {target}`, details from `cargo metadata --locked`.",
              f"Crates: {len(keys)}; with licence/notice files: {len(keys) - len(declared_only)};",
              f"declared licence only (no file in the package): {len(declared_only)}.",
              "The CLI's own code is covered by ../../LICENSE. The bundled nativehtmlkit-host is a separate",
              "NativeHTMLKit Core release; its licence and notices are in ../core/.", ""]
    summary = {"crates": len(keys), "with_licence_files": len(keys) - len(declared_only), "declared_only": declared_only}
    return "\n".join(header) + "\n" + "\n\n".join(sections) + "\n", summary


def core_release(host: pathlib.Path, pinned: str, version: str) -> tuple[pathlib.Path, dict]:
    """The host must come from an unpacked Core release: its manifest and notices ship with us."""
    directory = host.resolve().parent
    manifest_path = directory / "release-manifest.json"
    required = [manifest_path, directory / "LICENSE", directory / "THIRD_PARTY_NOTICES.md",
                directory / "licenses" / "THIRD-PARTY-LICENSES.txt"]
    absent = [str(p.relative_to(directory)) for p in required if not p.is_file()]
    if absent:
        raise SystemExit(f"{directory} is not an unpacked Core release (missing {', '.join(absent)}); "
                         "the archive must carry the bundled host's licence and notices")
    # The release is trusted as a whole only if every file matches the release's own
    # checksum list; the licence files copied from it are part of what we ship.
    sums = directory / "SHA256SUMS"
    if not sums.is_file():
        raise SystemExit(f"{directory} has no SHA256SUMS; cannot verify the Core release")
    listed = {}
    for line in sums.read_text().splitlines():
        if line.strip():
            digest, name = line.split(None, 1)
            listed[name.strip().lstrip("*")] = digest.lower()
    corrupt = sorted(n for n, d in listed.items() if not (directory / n).is_file() or sha256(directory / n) != d)
    if corrupt:
        raise SystemExit("Core release files do not match its SHA256SUMS: " + ", ".join(corrupt[:8]))
    needed = [host.name, "LICENSE", "THIRD_PARTY_NOTICES.md", "release-manifest.json"]
    needed += [f.relative_to(directory).as_posix() for f in (directory / "licenses").rglob("*") if f.is_file()]
    unlisted = sorted(n for n in needed if n not in listed)
    if unlisted:
        raise SystemExit("Core release SHA256SUMS does not cover: " + ", ".join(unlisted[:8]))
    manifest = json.loads(manifest_path.read_text())
    problems = []
    if manifest.get("host_sha256") != pinned:
        problems.append(f"release-manifest.json records host {manifest.get('host_sha256')}")
    if manifest.get("version") != version:
        problems.append(f"release-manifest.json is Core {manifest.get('version')}")
    if manifest.get("protocol_version") != PROTOCOL_VERSION:
        problems.append(f"protocol version {manifest.get('protocol_version')}")
    if manifest.get("platform") != ("windows-x64" if WINDOWS else "linux-x64"):
        problems.append(f"platform {manifest.get('platform')}")
    # Since Core 1.0.3 the host carries its own source identity (`--version --verbose`).
    # What the binary says about itself must agree with the release manifest beside it.
    if tuple(int(x) for x in re.findall(r"\d+", version)[:3]) >= (1, 0, 3):
        told = run([str(host), "--version", "--verbose"])
        try:
            embedded = json.loads(told.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise SystemExit(f"{host.name} --version --verbose did not print a JSON identity: {told.stdout!r} {told.stderr!r}")
        for key in ("version", "source_commit", "source_dirty", "source_tree"):
            if embedded.get(key) != manifest.get(key):
                problems.append(f"host embeds {key}={embedded.get(key)!r}, release manifest says {manifest.get(key)!r}")
    if problems:
        raise SystemExit("Core release does not match the pin: " + "; ".join(problems))
    return directory, manifest


REPO = "nativehtmlkit/nativehtmlkit-cli"
# Fixed timestamp for archive members (2000-01-01T00:00:00Z) unless SOURCE_DATE_EPOCH is set.
ARCHIVE_EPOCH = int(os.environ.get("SOURCE_DATE_EPOCH", "946684800"))


def publish_refusal(version: str, identity: dict) -> str | None:
    """Why this tree must not be published, or None. Same gates as Core's release script:
    a clean Git commit, the tag v<version> existing and pointing at HEAD, the gh CLI, and
    no existing release for that tag (release versions are immutable)."""
    if identity["source_identity"] != "git" or identity["source_dirty"] is not False:
        return "Clean Git commit required before publication"
    tag = "v" + version
    if run(["git", "tag", "--list", tag], cwd=ROOT).stdout.strip() != tag:
        return f"Tag {tag} does not exist; tag the release commit first"
    tagged = run(["git", "rev-parse", "--verify", tag + "^{commit}"], cwd=ROOT).stdout.strip()
    if tagged != identity["source_commit"]:
        return f"Tag {tag} does not point at HEAD {identity['source_commit']}"
    gh = shutil.which("gh")
    if gh is None:
        return "gh CLI is required for --publish"
    if subprocess.run([gh, "release", "view", tag, "--repo", REPO], cwd=ROOT, capture_output=True).returncode == 0:
        return f"GitHub release {tag} already exists; release versions are immutable"
    return None


def publish(archive: pathlib.Path, version: str, staged: dict) -> str | None:
    """Upload an already built and verified archive. Returns a refusal text, or None after a
    successful upload (the sidecar next to the archive is then the local record)."""
    head = run(["git", "rev-parse", "--verify", "HEAD^{commit}"], cwd=ROOT).stdout.strip()
    if staged["source_commit"] != head or staged["source_dirty"] is not False:
        return "staged manifest is not from a clean HEAD; refusing to publish"
    # No GitHub Actions exist in this repository; this only uploads the archive built before.
    subprocess.run([shutil.which("gh") or "gh", "release", "create", "v" + version, str(archive), "--repo", REPO,
                    "--verify-tag", "--title", "NativeHTMLKit CLI v" + version, "--notes", "Locally built and qualified."],
                   cwd=ROOT, check=True)
    (archive.parent / (archive.name + ".published.json")).write_text(json.dumps(
        {"published": True, "tag": "v" + version, "repository": REPO, "archive_sha256": sha256(archive),
         "source_commit": staged["source_commit"]}, indent=2) + "\n")
    return None


def leaked_paths(binary: pathlib.Path) -> list[str]:
    """Local build paths embedded in a binary (the account name must not ship)."""
    data = binary.read_bytes()
    found = set()
    for needle in {str(pathlib.Path.home()), os.environ.get("CARGO_HOME", ""), str(ROOT)}:
        for variant in {needle, needle.replace("\\", "/"), needle.replace("/", "\\")}:
            if len(variant) > 3 and variant.encode() in data:
                found.add(variant)
    return sorted(found)


def write_tar_gz(archive: pathlib.Path, stage: pathlib.Path, name: str) -> None:
    """Deterministic archive: sorted members, numeric owner 0/0 without names, fixed
    modification time and normalised modes, no timestamp in the gzip header."""
    with open(archive, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped, \
            tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path in [stage, *sorted(stage.rglob("*"))]:
            info = tar.gettarinfo(str(path), arcname=(pathlib.PurePosixPath(name) / path.relative_to(stage).as_posix()).as_posix())
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = ARCHIVE_EPOCH
            info.pax_headers = {}
            if info.isdir():
                info.mode = 0o755
            elif info.isfile():
                info.mode = 0o755 if os.access(path, os.X_OK) else 0o644
            if info.isfile():
                with open(path, "rb") as stream:
                    tar.addfile(info, stream)
            else:
                tar.addfile(info)


def write_zip(archive: pathlib.Path, stage: pathlib.Path, name: str) -> None:
    """Deterministic archive: sorted members with a fixed timestamp."""
    stamp = time.gmtime(max(ARCHIVE_EPOCH, 315532800))[:6]  # zip cannot represent dates before 1980
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(f"{name}/{path.relative_to(stage).as_posix()}", date_time=stamp)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                z.writestr(info, path.read_bytes())


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", type=pathlib.Path, help="Qualified Core host executable for this platform")
    p.add_argument("--host-version", help="Core release version of that host, e.g. 1.0.2")
    p.add_argument("--host-sha256", help="SHA-256 recorded for that host by the Core release (64 hex)")
    p.add_argument("--version", default=tomllib.loads((ROOT / "Cargo.toml").read_text())["package"]["version"])
    p.add_argument("--print-source-identity", action="store_true",
                   help="Print the JSON a sync step stores as SOURCE-IDENTITY.json, then exit")
    p.add_argument("--publish", action="store_true")
    p.add_argument("--confirm", default="")
    a = p.parse_args()
    if a.print_source_identity:
        tree = source_tree_hash()
        print(json.dumps({"source_tree_sha256": tree, **source_identity(tree)}))
        return 0
    if not (a.host and a.host_version and a.host_sha256):
        p.error("--host, --host-version and --host-sha256 are all required: the Core host is pinned explicitly")
    if a.publish and a.confirm != "publish-" + a.version:
        p.error("Explicit --confirm publish-" + a.version + " required")
    pinned = a.host_sha256.strip().lower()
    if len(pinned) != 64 or any(c not in "0123456789abcdef" for c in pinned):
        p.error("--host-sha256 must be the 64-hex-digit SHA-256 from the Core release")
    cli = ROOT / "target" / "release" / ("nativehtmlkit.exe" if WINDOWS else "nativehtmlkit")
    if not cli.is_file():
        p.error("Compile the CLI locally first (cargo build --locked --release): " + str(cli))
    if not a.host.is_file():
        p.error("Missing qualified Core host binary: " + str(a.host))
    host_sha = sha256(a.host)
    if host_sha != pinned:
        p.error(f"Core host SHA-256 mismatch: pinned {pinned}, file is {host_sha}")
    # A binary older than the sources it claims to be built from would make the manifest lie.
    sources = [ROOT / n for n in source_files() if n.startswith("src/") or n in ("Cargo.toml", "Cargo.lock")]
    newest = max(sources, key=lambda f: f.stat().st_mtime)
    if cli.stat().st_mtime < newest.stat().st_mtime:
        p.error(f"{cli} is older than {newest.relative_to(ROOT)}; rebuild with cargo build --locked --release")
    host_version = a.host_version.removeprefix("v")
    core_dir, core_manifest = core_release(a.host, pinned, host_version)
    leaked = leaked_paths(cli)
    if leaked:
        p.error(f"{cli.name} embeds local build paths {leaked}; build it with scripts/build-release.py")
    expected = {cli: f"nativehtmlkit {a.version}", a.host: f"nativehtmlkit-host {host_version}"}
    for exe, want in expected.items():
        magic = exe.read_bytes()[:4]
        if WINDOWS and not magic.startswith(b"MZ") or not WINDOWS and magic != b"\x7fELF":
            p.error(f"{exe} is not a native executable for this platform")
        got = run([str(exe), "--version"]).stdout.strip()
        if got != want:
            p.error(f"{exe.name} --version is {got!r}, expected {want!r}")
    tree = source_tree_hash()
    identity = source_identity(tree)
    if a.publish:
        refusal = publish_refusal(a.version, identity)
        if refusal:
            p.error(refusal)

    label = "windows-x64" if WINDOWS else "linux-x64"
    name = f"nativehtmlkit-cli-v{a.version}-{label}"
    dist = ROOT / "dist"
    stage = dist / name
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
    (stage / "examples").mkdir()
    shutil.copy2(ROOT / "examples" / "sample-form.html", stage / "examples" / "sample-form.html")
    # Licences: the CLI's crate tree in full text, and the bundled host's own release notices.
    licence_text, licence_summary = third_party_licences()
    (stage / "licenses" / "cli").mkdir(parents=True)
    (stage / "licenses" / "cli" / "THIRD-PARTY-LICENSES.txt").write_text(licence_text, encoding="utf-8", newline="\n")
    core_out = stage / "licenses" / "core"
    shutil.copytree(core_dir / "licenses", core_out)
    for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md", "release-manifest.json"):
        shutil.copy2(core_dir / notice, core_out / notice)
    manifest = {
        "schema": 2,
        "component": "nativehtmlkit-cli",
        "version": a.version,
        "platform": label,
        "cli_sha256": sha256(cli),
        "host_version": host_version,
        "host_sha256": host_sha,
        "host_sha256_pinned": True,
        "host_source_tree": core_manifest.get("source_tree"),
        "host_source_commit": core_manifest.get("source_commit"),
        "host_source_dirty": core_manifest.get("source_dirty"),
        "protocol_version": PROTOCOL_VERSION,
        "third_party_licences": {"cli": licence_summary, "core": "licenses/core/ (copied from the pinned Core release)"},
        "source_tree_sha256": tree,
        **identity,
        "cargo_lock_sha256": sha256(ROOT / "Cargo.lock"),
        "toolchain": toolchain(),
        # Written before any upload. A locally staged archive is not published by this run;
        # with --publish the record of publication is the GitHub release and the sidecar
        # written after a successful upload, so the archive does not claim either state.
        "published": None if a.publish else False,
        **({"publication": {"tag": "v" + a.version, "repository": REPO, "state": "prepared; tag verified == HEAD"}} if a.publish else {}),
    }
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    files = sorted(x for x in stage.rglob("*") if x.is_file() and not x.is_symlink())
    (stage / "SHA256SUMS").write_text(
        "".join(f"{sha256(f)}  {f.relative_to(stage).as_posix()}\n" for f in files), newline="\n")

    if WINDOWS:
        archive = dist / (name + ".zip")
        write_zip(archive, stage, name)
    else:
        archive = dist / (name + ".tar.gz")
        write_tar_gz(archive, stage, name)
    archive_sha = sha256(archive)
    (dist / (archive.name + ".sha256")).write_text(f"{archive_sha}  {archive.name}\n", newline="\n")
    # dist/SHA256SUMS covers every archive present (both platforms once both were packaged here).
    sums = {}
    for other in sorted(dist.glob(f"nativehtmlkit-cli-v{a.version}-*")):
        if other.is_file() and other.suffix in (".gz", ".zip"):
            sums[other.name] = sha256(other)
    (dist / "SHA256SUMS").write_text("".join(f"{d}  {n}\n" for n, d in sorted(sums.items())), newline="\n")

    # Verify from a clean extraction in an unrelated directory, running the extracted files.
    with tempfile.TemporaryDirectory(prefix="nhk-cli-verify-") as tmp:
        if WINDOWS:
            with zipfile.ZipFile(archive) as z:
                z.extractall(tmp)
        else:
            with tarfile.open(archive) as t:
                t.extractall(tmp, filter="data")
        out = pathlib.Path(tmp) / name
        listed = (out / "SHA256SUMS").read_text().splitlines()
        for line in listed:
            digest, fname = line.split("  ", 1)
            if sha256(out / fname) != digest:
                p.error(f"archive verification failed for {fname}")
        extracted = json.loads((out / "manifest.json").read_text())
        if extracted["host_sha256"] != sha256(out / host_name) or extracted["cli_sha256"] != sha256(out / cli.name):
            p.error("extracted binaries do not match the manifest")
        alias = out / ("nhk.exe" if WINDOWS else "nhk")
        env = {k: v for k, v in os.environ.items() if not k.startswith("NATIVEHTMLKIT_")}
        if run([str(alias), "--version"], env=env).stdout.strip() != f"nativehtmlkit {a.version}":
            p.error("extracted nhk alias does not run")
        doctor = run([str(alias), "doctor"], env=env, cwd=tmp)
        if doctor.returncode != 0 or f"nativehtmlkit-host {host_version}" not in doctor.stdout or str(out) not in doctor.stdout:
            p.error("extracted CLI did not find its bundled host: " + doctor.stdout + doctor.stderr)
        bad = run([str(alias), "select", "--input-format", "json"], env=env, input="[1,")
        if bad.returncode != 1 or bad.stdout:
            p.error("extracted CLI did not fail closed on invalid input")
        # A real protocol session between the extracted CLI and the bundled host, without a
        # window: handshake, document load, liveness probes, then the explicit deadline.
        session = run([str(alias), "--timeout", "1", "--liveness-interval", "0.2", "select"],
                      env={**env, "NATIVEHTMLKIT_CLI_TEST_HEADLESS": "1"}, input="alpha\nbeta\n", cwd=tmp)
        if session.returncode != 124 or session.stdout:
            p.error(f"extracted CLI and bundled host did not complete a headless session (exit {session.returncode}): {session.stderr[-2000:]}")
    print(f"staged and verified: {archive}\n  sha256 {archive_sha}\n  host   {host_sha} ({host_version})\n"
          f"  cli    {manifest['cli_sha256']}\n  source {manifest['source_tree_sha256']} (commit {manifest['source_commit'][:12]}, dirty={manifest['source_dirty']})")
    if a.publish:
        refusal = publish(archive, a.version, json.loads((stage / "manifest.json").read_text()))
        if refusal:
            p.error(refusal)
    return 0


if __name__ == "__main__":
    sys.exit(main())
