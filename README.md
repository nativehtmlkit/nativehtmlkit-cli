# NativeHTMLKit CLI

**Pipe ordinary command output into an interactive native HTML/CSS desktop window and return selections or form results to the shell.**

**Status: independent Rust repository placeholder. No CLI executable exists yet.** The `docs/CLI-Spec/` folder contains planning research, architecture and draft IDL; it does not certify functionality.

## Intended use (after implementation)

```bash
printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi
# Short equivalent:
printf 'alpha\nbeta\ngamma\n' | nhk select --multi
```

Submit should return exactly the chosen lines to launcher stdout; Cancel should emit no data and a distinct exit code, without leaving host/backend processes running.

## Ownership

- Rust CLI source, shell input parsing, data selection/forms, CLI flag/output/exit contracts and native GUI templates.
- Standalone launcher/backend and protocol client which consume **pinned, qualified native host binaries** produced by Core.
- Linux and Windows CLI release artifacts and independent test suites.

The renderer and canonical protocol belong in [NativeHTMLKit Core](https://github.com/nativehtmlkit/nativehtmlkit-core), not here. No source-tree dependency on Core and no requirement for Python or PowerShell.

Start with [CLI specification](docs/CLI-Spec/README.md), then [agent rules](AGENTS.md). Note: certain older research pages recommend initially developing the CLI as a crate inside Core; **that choice has been superseded by the agreed separate `nativehtmlkit-cli` repository**. CLI must record Core bugs in the Project bug register instead of patching Core from a consumer task.
