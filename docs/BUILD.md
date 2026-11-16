# Local build and qualification

```bash
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
python3 scripts/qualify.py --help
```

The release packaging/qualification scripts expect an exact pinned Core host executable. They test process supervision, liveness, and output/exit contracts. Native journeys must still run on Linux KDE Wayland and Windows. Do not substitute a `cargo build` pass for a qualified GitHub release.
