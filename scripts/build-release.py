#!/usr/bin/env python3
"""Build the release executable the way it is packaged and qualified.

Same as `cargo build --locked --release --bin nativehtmlkit`, with the local build paths
(home directory, Cargo home, this checkout) remapped so that the binary does not embed the
builder's account name or directory layout. Extra arguments are passed on to cargo.
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def remap_flags() -> list[str]:
    home = pathlib.Path.home()
    cargo_home = pathlib.Path(os.environ.get("CARGO_HOME") or home / ".cargo")
    rustup_home = pathlib.Path(os.environ.get("RUSTUP_HOME") or home / ".rustup")
    # When several prefixes match, rustc uses the last one given: most specific last.
    pairs = [(home, "/builder"), (rustup_home, "/rustup"), (cargo_home, "/cargo"), (ROOT, "/nativehtmlkit-cli")]
    return [f"--remap-path-prefix={source}={target}" for source, target in pairs]


def main() -> int:
    env = dict(os.environ)
    env["RUSTFLAGS"] = " ".join(filter(None, [env.get("RUSTFLAGS", ""), *remap_flags()]))
    command = ["cargo", "build", "--locked", "--release", "--bin", "nativehtmlkit", *sys.argv[1:]]
    return subprocess.run(command, cwd=ROOT, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
