#!/usr/bin/env python3
"""Repository boundary rules that must hold before any build (see AGENTS.md)."""
from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
manifest = tomllib.loads((root / "Cargo.toml").read_text())
lock = tomllib.loads((root / "Cargo.lock").read_text())
version = manifest["package"]["version"]

assert manifest["package"]["name"] == "nativehtmlkit-cli"
assert manifest["package"].get("publish") is False, "the crate must not be publishable to a registry"
assert not (root / ".github/workflows").exists(), "no GitHub Actions workflows allowed"
assert not (root / "crates").exists(), "do not copy Core crate source to CLI"

# No Core source dependency, in any dependency table or form (path, git, workspace).
tables = [manifest.get(k, {}) for k in ("dependencies", "dev-dependencies", "build-dependencies")]
tables += [t.get(k, {}) for t in manifest.get("target", {}).values() for k in ("dependencies", "dev-dependencies", "build-dependencies")]
for table in tables:
    for name, spec in table.items():
        assert "nativehtmlkit" not in name and "ui4me" not in name, f"Core crate dependency: {name}"
        if isinstance(spec, dict):
            assert "path" not in spec and "git" not in spec, f"{name}: only registry dependencies are allowed"
for package in lock["package"]:
    if package["name"] == "nativehtmlkit-cli":
        assert package["version"] == version, "Cargo.lock is out of date with Cargo.toml"
        continue
    assert package.get("source", "").startswith("registry+https://github.com/rust-lang/crates.io-index"), \
        f"{package['name']}: non-registry source in Cargo.lock"
    assert "checksum" in package, f"{package['name']}: no checksum in Cargo.lock"

# The source must not reference Core's private crates or source tree.
for source in list((root / "src").rglob("*.rs")) + list((root / "tests").rglob("*.rs")):
    text = source.read_text()
    assert not re.search(r"\b(use|extern crate)\s+nativehtmlkit_(host|renderer|document|assets|engine_types)\b", text), source
    assert "nativehtmlkit-core/crates" not in text, source

for required in ("src/protocol.rs", "src/transport.rs", "src/backend.rs", "src/runner.rs", "src/diag.rs", "src/error.rs",
                 "tests/fake_host_faults.rs", "tests/launcher_e2e.rs", "scripts/qualify.py", "scripts/package-local.py"):
    assert (root / required).is_file(), required

# Documents that state the current version must state the real one.
assert f"v{version}" in (root / "docs/QUALIFICATION.md").read_text(), "docs/QUALIFICATION.md does not describe this version"
print(f"PASS: independent CLI {version}: registry-only locked dependencies, no Core source, no GitHub Actions")
