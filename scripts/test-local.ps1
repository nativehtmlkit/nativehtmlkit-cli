$ErrorActionPreference='Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..'))
if (!(Test-Path Cargo.lock)) { cargo generate-lockfile; if ($LASTEXITCODE) { exit $LASTEXITCODE } }
python scripts/check-repo.py; if ($LASTEXITCODE) { exit $LASTEXITCODE }
cargo fmt --all -- --check; if ($LASTEXITCODE) { exit $LASTEXITCODE }
cargo clippy --locked --all-targets -- -D warnings; if ($LASTEXITCODE) { exit $LASTEXITCODE }
cargo test --locked --all-targets; if ($LASTEXITCODE) { exit $LASTEXITCODE }
cargo build --locked --release --bin nativehtmlkit; exit $LASTEXITCODE
