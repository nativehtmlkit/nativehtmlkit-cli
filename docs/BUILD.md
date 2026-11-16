# Local build and qualification

```bash
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
python3 scripts/qualify.py --help
```

The release packaging/qualification scripts expect an exact pinned Core host executable. They test process supervision, liveness, and output/exit contracts. Native journeys must still run on Linux KDE Wayland and Windows. Do not substitute a `cargo build` pass for a qualified GitHub release.

## Documentation examples

`examples/` and the documented contract are verified against a CLI release, not against a
`cargo build`:

```bash
scripts/test-examples.sh --cli /path/to/nativehtmlkit-cli-v0.1.2-linux-x64/nativehtmlkit
pwsh -File scripts/test-examples.ps1 -Cli /path/to/nativehtmlkit-cli-v0.1.2-linux-x64/nativehtmlkit
powershell.exe -File scripts\test-examples.ps1 -Cli C:\path\nativehtmlkit.exe -Shell powershell.exe
python3 scripts/test-docs.py --cli /path/to/nativehtmlkit-cli-v0.1.2-linux-x64/nativehtmlkit      # docs/linux
pwsh -File scripts/test-docs.ps1 -Cli /path/to/nativehtmlkit-cli-v0.1.2-linux-x64/nativehtmlkit    # docs/windows, PowerShell 7
powershell.exe -File scripts\test-docs.ps1 -Cli C:\path\nativehtmlkit.exe -Shell powershell.exe  # docs/windows, 5.1
```

All of them run the real host headless (`NATIVEHTMLKIT_CLI_TEST_HEADLESS=1`) and exit non-zero on
any failure; see testing scripts without a desktop ([Linux](linux/recipes/headless-testing.md), [Windows](windows/recipes/headless-testing.md)).
