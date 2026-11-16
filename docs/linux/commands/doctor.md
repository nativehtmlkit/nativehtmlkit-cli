# doctor, help and version (Linux)

`nativehtmlkit doctor` reports which Core host executable the CLI would use and checks that
it starts. `help`, `--help` and `--version` print information. None of them opens a window
or reads stdin. Exact rules: [OS-neutral reference](../../reference/doctor.md).

The examples were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## `doctor`

<!-- test: exit=0 calls="0@none" -->
```bash
nativehtmlkit doctor
```

prints three lines, for example:

```text
NativeHTMLKit CLI 0.1.2
Core host: /opt/nativehtmlkit-cli/nativehtmlkit-host
nativehtmlkit-host 1.0.3
```

The third line is the host's own `--version` output. Check it in a script:

<!-- test: exit=0 calls="0@none" -->
```bash
if nativehtmlkit doctor | grep -qx 'nativehtmlkit-host 1.0.3'; then
  echo 'qualified host found'
else
  echo 'install the release archive, or set NATIVEHTMLKIT_HOST_BINARY' >&2; exit 1
fi
```

<!-- stdout -->
```text
qualified host found
```

| Situation | Exit | stderr |
|---|---|---|
| host found and it answered `--version` | 0 | |
| no host anywhere | 1 | `error[host.not_found]: NativeHTMLKit Core host not found. ...` |
| `--host`/`NATIVEHTMLKIT_HOST_BINARY` names no file | 1 | `error[host.not_found]: Core host binary does not exist: <path>` |
| the file cannot be started | 1 | `error[host.not_found]: cannot start the Core host (<reason>)` |
| it failed, printed nothing, or took over 10 s | 1 | `error[host.failed]: ...` |

## `doctor --host PATH`

Check a specific host executable:

<!-- test: exit=1 calls="1@none" -->
```bash
nativehtmlkit doctor --host /opt/missing/nativehtmlkit-host
```

<!-- stderr -->
```text
nativehtmlkit: error[host.not_found]: Core host binary does not exist: /opt/missing/nativehtmlkit-host
```

A file that is not a working host fails the version check:

<!-- test: exit=1 calls="1@none" -->
```bash
printf '#!/bin/sh\nexit 3\n' > fake-host && chmod +x fake-host
nativehtmlkit doctor --host ./fake-host
```

<!-- stderr -->
```text
nativehtmlkit: error[host.failed]: Core host version check failed with exit status: 3
```

## `doctor --diagnostics LEVEL`

`doctor` writes no diagnostic records of its own at any level; the option is accepted so
that the same global options work for every command:

<!-- test: exit=0 calls="0@none" -->
```bash
nativehtmlkit doctor --diagnostics trace > /dev/null 2> doctor.log
wc -c < doctor.log
```

<!-- stdout -->
```text
0
```

## `doctor --timeout`, `--rpc-timeout`, `--liveness-interval`, `--startup-timeout`

Accepted and ignored by `doctor`: it never opens a window, and its version check has its own
fixed 10-second limit. They are useful when one options array is passed to every command:

<!-- test: exit=0 calls="0@none 124@2x1" -->
```bash
opts=(--timeout 120 --rpc-timeout 10 --liveness-interval 2 --startup-timeout 30)
nativehtmlkit doctor "${opts[@]}" > /dev/null && echo 'doctor ok'
printf 'a\nb\n' | nativehtmlkit select "${opts[@]}" || echo "select ended with $?"
```

<!-- stdout -->
```text
doctor ok
select ended with 124
```

## `--version`, `-V`

<!-- test: exit=0 shim=off -->
```bash
nativehtmlkit --version
nhk -V
```

<!-- stdout -->
```text
nativehtmlkit 0.1.2
nativehtmlkit 0.1.2
```

## `--help`, `-h`, `help COMMAND`

`--help` prints the full help, `-h` a summary; after a command they describe that command.
`help COMMAND` is the same as `COMMAND --help`:

<!-- test: exit=0 shim=off -->
```bash
nativehtmlkit --help | tail -n 1
```

<!-- stdout -->
```text
Exit status: 0 submitted/viewed, 1 error, 2 cancelled, 124 --timeout expired, 130 Ctrl+C/SIGINT, 143 SIGTERM, 129 SIGHUP.
```

<!-- test: exit=0 shim=off -->
```bash
nativehtmlkit doctor --help | head -n 1
nativehtmlkit -h | head -n 1
nativehtmlkit help select | head -n 1
```

<!-- stdout -->
```text
Usage: nativehtmlkit doctor [OPTIONS]
Native HTML/CSS windows for shell pipelines (alias: nhk)
Usage: nativehtmlkit select [OPTIONS]
```

`help` takes a command name, not options: `nativehtmlkit help --help` is a usage error
(exit 1).

## The `nhk` alias

The release archive contains `nhk`, a symbolic link to `nativehtmlkit`. It behaves exactly
the same, including finding the host beside the real file:

<!-- test: exit=0 calls="0@none" -->
```bash
nhk doctor | head -n 1
```

<!-- stdout -->
```text
NativeHTMLKit CLI 0.1.2
```

## Related

[Installation](../index.md), [environment and diagnostics](../environment-and-diagnostics.md),
[troubleshooting](../troubleshooting.md).
