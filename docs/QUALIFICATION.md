# Independent CLI qualification matrix

**This file defines acceptance targets, not test results. The migration source has not been compiled/tested in the handoff environment.**

| ID | Acceptance scenario | Linux Wayland | Windows interactive |
|---|---|---|---|
| S01 | `printf 'alpha\nbeta\ngamma\n' \| nhk select --multi` opens real window | BLOCKED | BLOCKED |
| S02 | Click second checkbox, Submit, stdout exactly `beta\n` | BLOCKED | BLOCKED |
| S03 | Cancel / titlebar close => exit 2, empty stdout | BLOCKED | BLOCKED |
| S04 | Invalid JSON, invalid CSV => exit 1, empty stdout | BLOCKED | BLOCKED |
| S05 | 2,000 rows and HTML size boundary handled without crash | BLOCKED | BLOCKED |
| S06 | JSON and NDJSON selection maintains data types | BLOCKED | BLOCKED |
| S07 | TSV/CSV output quoting and newline protection | BLOCKED | BLOCKED |
| S08 | Form required field invalid then valid, output entries | BLOCKED | BLOCKED |
| S09 | Real window resizing, DPI/scale, focus and keyboard selection | BLOCKED | BLOCKED |
| S10 | Input containing `<script>`, tags, Unicode renders as text | BLOCKED | BLOCKED |
| S11 | Kill launcher and host; no orphaned GUI/backends | BLOCKED | BLOCKED |
| S12 | Core v1 handshake errors/failure and version mismatch fail closed | BLOCKED | BLOCKED |
| S13 | Parallel launch two CLIs; outputs are isolated | BLOCKED | BLOCKED |
| S14 | Test exact packaged binaries, not only Cargo target folder | BLOCKED | BLOCKED |

Capture source SHA, host binary SHA, CLI binary SHA, test environment, actions, native screenshot sequence and stdout bytes for each scenario. **Do not claim success from screenshots alone.**

## Known high-risk tasks for local agent

- Validate PowerShell, Windows named-pipe and interactive RDP behavior. Test process containment when terminating CLI parent.
- Confirm Windows stdout/stderr UTF-8 and console handling.
- Confirm Core v1 form-data notifications, control semantics and lifecycle events match the independent Rust client.
- Verify `toml::Value` rendering of paths (especially Windows spaces, Unicode and backslashes).
- Exercise NativeHTMLKit aliases for resource schemes and attributes on both platforms.
- Generate and commit `Cargo.lock` on the first local toolchain run.
- Add complete screenshot/video capture and gallery outputs using the shared project test strategy.

No GitHub Actions; use local test machines and explicit direct GitHub Releases only.
