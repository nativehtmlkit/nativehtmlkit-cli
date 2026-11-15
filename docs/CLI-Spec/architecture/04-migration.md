# Core → CLI → Python → PowerShell: migration and packaging

## Phase M0 — preserve evidence

- Freeze/label the existing UI4ME Core 1.0.1 source state and published artifacts. Retain source manifests and release qualification reports.
- Take an audit inventory of installed wheel and PowerShell Gallery consumers; no destructive rename or force overwrite.
- The `nativehtmlkit` namespace is a **personal GitHub account**. PyPI, PowerShell Gallery and domain names require separate registration verification. No ownership or name availability is asserted by this ZIP.

## Phase M1 — Rust Core ownership

- Create `nativehtmlkit-core` repository as Rust workspace with `crates/nativehtmlkit-host`, renderer, document, assets and engine types. Preserve git attribution/history and third-party licenses.
- Keep old protocol-v1 environment names and `host.hello` behavior initially. Expose a machine-readable `core-capabilities.json` / `host-release.json` in release artifacts.
- Remove **SDK runtime code** (`python/ui4me_core`, `powershell/UI4ME.Core`) from new Core after extracting history into their future homes. Keep temporary cross-language test fixtures only when they are contract tests, not package owners.
- Build independent signed/attested if possible Linux/Windows native host release artifacts from a canonical source commit. Linux wheel binary repair is no longer the canonical host distributor; use packaging suitable for independent host binaries and compare linked library requirements.

## Phase M2 — CLI as first independent downstream consumer

- Develop the CLI immediately inside its independent `nativehtmlkit-cli` repository. A local Core binary override allows rapid cross-repo development, but release builds use qualified published host artifacts; do not depend on Core private crate source paths.
- CLI must pass local `nhk --version`, `nhk select` and cross-OS conformance against a pinned release host artifact with no Rust source tree at runtime.
- If a Core defect blocks CLI, reproduce it and record the bug and a workaround (or lack of one) in Project `docs/bugs/bug_list.md`. A separate Core-owned task implements and regression-tests the fix; the CLI agent does not silently patch Core.
- The CLI remains its own repository throughout. Core and CLI can be built and tested together using a coordinated local workspace, without unpublished Rust path dependencies.

## Phase M3 — migrate Python

- Copy current Python client into `nativehtmlkit-python`, retaining existing functionality and tests.
- New Python wheel consumes pinned qualified `nativehtmlkit-host` executable bytes, rather than compiling Core from wheel build by default. Define explicit source-build flow for sdists and offline/reproducible builds; do not download unspecified native binaries in `setup.py` during pip install.
- Provide transitional import shim or migration instructions for `ui4me_core`; version and rename packages intentionally.
- Python and CLI both run protocol-v1 conformance against the **same** host build in CI.

## Phase M4 — migrate PowerShell

- Move module and C# transport into `nativehtmlkit-powershell`, ensuring Windows PowerShell 5.1 and pwsh 7.2+ qualification still passes.
- **Stop extracting host binaries from Python wheels**. Instead use the Core's immutable Linux/Windows artifacts with checksums/provenance.
- Keep no Python runtime dependency in installed PowerShell module. Produce native staged module and verify across shells/platforms.
- Provide transitional `UI4ME.Core` compatibility guidance separately from the new `NativeHTMLKit.Core` package.

## Artifact contract (proposed)

```json
{
  "manifest_version": 1,
  "core_version": "X.Y.Z",
  "host_build_id": "<source_commit+build_identity>",
  "protocol_versions": [1],
  "platform": "linux-x64-wayland",
  "architecture": "x86_64",
  "sha256": "<sha256-hex>",
  "host_binary": "nativehtmlkit-host",
  "minimum_glibc": "2.34",
  "core_source_commit": "<sha>"
}
```

This JSON is illustrative release metadata; select actual field names and cryptographic authenticity mechanism before publication. Lock compatibility based on `protocol_version`, required capabilities, OS and host artifact hashes, not marketing package versions alone.

## CI responsibility after separation

- Core CI: Rust unit/property tests, fuzz/host protocol, Linux/Windows host acceptance, release artifact provenance.
- CLI CI: parsing, lifecycle, stdout conformance, host-version matrix, actual GUI interactions on Linux KDE and Windows Desktop.
- Python CI: Python transport/client and package installation, host matrix.
- PowerShell CI: Pester, 5.1/7.x, UIA/AT-SPI/native tests, Gallery package verification.
- Orchestrated nightly/release matrix: all three clients against qualified Core host(s), no redundant source trees when unnecessary.

## Important repo hygiene

Keep public docs versioned per project and keep one canonical protocol reference and test fixture repository/source in Core. Consumer packages pin a released contract artifact, not a mutable GitHub `main`. Cross-repo changes should use staged PRs and CI compatibility tests rather than simultaneous unreviewed pushes.
