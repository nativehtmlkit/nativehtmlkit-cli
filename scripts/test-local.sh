#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Cargo.lock ]]; then
  echo 'Generating initial Cargo.lock; commit it after review' >&2
  cargo generate-lockfile
fi
python3 scripts/check-repo.py
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
python3 scripts/build-release.py
