# NativeHTMLKit CLI — Agent instructions

1. This is an independent Rust CLI repo. Do NOT depend on `../nativehtmlkit-core/crates/*`, embed the renderer, launch a Python/PowerShell SDK or rebuild Core as an implicit packaging step.
2. Read `README.md` and `docs/QUALIFICATION.md` first. The Core protocol v1 candidate is located in the sibling Core repository when present; standalone clones must use a released Core protocol artifact.
3. CLI public executable is `nativehtmlkit` and short alias `nhk`. The binary's hidden `__backend` subcommand is for the Core-supervised process; users invoke `select`, `view`, `form`, `doctor`.
4. The input source is stdin, output bytes go only to stdout after Submit; any logs must go to stderr. Exit code 2 means Cancel; errors fail closed.
5. Complete/verify local integration with Core v1 before declaring a stable release. Maintain source-derived protocol compatibility, not optimistic assumptions.
6. Run `cargo fmt`, `cargo clippy`, `cargo test`, then real native Wayland/Windows qualification, including actual screenshots/traces and process cleanup. Never fabricate PASS status.
7. No GitHub Actions, remote CI or registry publication; local builds and local verification only. `gh release create` is permitted only when explicitly requested.
8. Report Core defects in project `docs/bugs/bug_list.md` when available; don't secretly edit Core from within the CLI task.
9. Preserve this repository as independently cloneable/buildable. Local host override can be set through `NATIVEHTMLKIT_HOST_BINARY` for development; distributions consume pinned qualified Core artifacts.
10. See `../..` project shared instructions when available, otherwise use these instructions without assuming another checkout exists.
