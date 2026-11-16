# NativeHTMLKit CLI

**Give a shell command a native desktop window** without embedding a browser or shipping a Python runtime.

```bash
printf 'alpha\nbeta\ngamma\n' | nativehtmlkit select --multi
printf 'name,status\na,up\nb,down\n' | nativehtmlkit select --input-format csv --multi --output-format json
ps aux | nativehtmlkit view
nativehtmlkit form --html examples/sample-form.html
nativehtmlkit doctor
```

The executable may also be available as `nhk`. `select` writes only the accepted selection to stdout; cancel exits **2**, timed out user action **124**, interruption **130**, and ordinary errors **1**. `view` is read-only. Errors and diagnostics go to stderr. There is no default timeout on how long a person may decide.

The CLI is an independent Rust client of Core's local wire-v1 host. Release **0.1.2** contains Linux and Windows x64 assets on [GitHub Releases](https://github.com/nativehtmlkit/nativehtmlkit-cli/releases). This executable is not installed by the Python SDK.

| Read next | Link |
|---|---|
| Full commands, input formats and exit behavior | [CLI reference](docs/REFERENCE.md) |
| Integration with Core | [Architecture](docs/ARCHITECTURE.md) |
| Build and test | [Build](docs/BUILD.md) |
| Guided examples | [Public tutorials](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/tutorials/cli-selection.md) |

## Project navigation

- [Overview and tutorials](https://github.com/nativehtmlkit/nativehtmlkit) — public developer landing page.
- [Capability and platform matrix](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/matrix.md) — which API works where.
- [Known limitations](https://github.com/nativehtmlkit/nativehtmlkit/blob/main/docs/capabilities/limitations.md) — known defects and qualification limits.
- Active private development work is tracked in `nativehtmlkit-project`, not in this repository's documentation.
