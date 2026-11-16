# Global options

These options are accepted by every command, **before or after** the command name
(`nativehtmlkit --timeout 60 select` and `nativehtmlkit select --timeout 60` are the same).
Each may be given once; a repeated option is a usage error (exit 1).

| Option | Value | Default | Meaning |
|---|---|---|---|
| `--host <PATH>` | path | discovery, below | the Core host executable to use |
| `--diagnostics <LEVEL>` | `off`, `normal`, `debug`, `trace` | `$NATIVEHTMLKIT_DIAGNOSTICS`, else `normal` | structured records on stderr for the CLI, and exported to the host ([diagnostics](diagnostics.md)) |
| `--timeout <SECONDS>` | 0.01-86400 | none: wait indefinitely | the **user's** deadline: when it passes without Submit/Cancel/Close, the window is closed, exit 124 |
| `--rpc-timeout <SECONDS>` | 0.01-86400 | 30 | longest wait for the host to answer one request, finish a frame it started, or accept a write |
| `--liveness-interval <SECONDS>` | 0-86400 | 5 | idle time between liveness probes while the window is open; `0` disables probing |
| `--startup-timeout <SECONDS>` | 0.01-86400 | 15 | longest wait from starting the host until the window is ready |
| `-h`, `--help` | | | print help (exit 0); `-h` prints a summary |
| `-V`, `--version` | | | print `nativehtmlkit 0.1.2` (exit 0) |

## Seconds

A value is a decimal number of seconds, fractions allowed (`0.5`, `90`, `1e2`), surrounding
spaces ignored. Out of range or not a number is a usage error, exit 1:

```text
error: invalid value '0' for '--timeout <SECONDS>': expected at least 0.01 seconds
error: invalid value '90000' for '--timeout <SECONDS>': expected a number of seconds between 0 and 86400
```

## `--timeout`: waiting for a person

There is **no default limit** on how long a person may look at a window. `--timeout` adds
one. It is counted from the moment the window is ready (document loaded), not from the start
of the command. When it passes:

1. the CLI asks the host to close the window,
2. writes `nativehtmlkit: no decision before the --timeout deadline; the window was closed` to stderr,
3. exits **124** with empty stdout (the convention of coreutils `timeout`).

A submit that was accepted before the deadline wins; nothing is written after the deadline.

<a id="host-watchdogs"></a>

## Host watchdogs: `--rpc-timeout`, `--liveness-interval`, `--startup-timeout`

These bound the **host**, not the person. They exist so a pipeline never hangs on a host
that has stopped working, while a slow user never trips them:

- While the window is idle, the CLI's backend asks the host `host.diagnostics` every
  `--liveness-interval` seconds. Any answer proves the host is alive. A probe may take up to
  2 x `--rpc-timeout` (a busy host, a native modal loop); with the defaults a hung host is
  therefore reported about 65 s after it stopped answering, as
  `error[host.unresponsive]` (exit 1), and the host is stopped.
- Every other request must be answered within `--rpc-timeout`, or the session fails with
  `error[rpc.timeout]` (*remote outcome unknown*).
- The host must have the window ready within `--startup-timeout` (the launcher adds a 5 s
  margin): otherwise `error[host.startup_timeout]`. The value is also given to the host as its
  own backend start-up limit; extremely small values make the host itself give up
  (`error[host.failed]`).
- With `--liveness-interval 0` there is no probing: a host that hangs while the window is idle
  is only noticed at the next request (for example when the user clicks Submit).

All waits count time actually spent waiting, so a suspended laptop is not mistaken for a hung
host. See [architecture](../ARCHITECTURE.md#lifecycle-and-watchdogs) for the full lifecycle.

## Host discovery

The first match wins:

1. `--host <PATH>`
2. `NATIVEHTMLKIT_HOST_BINARY` (ignored when set to an empty string)
3. `nativehtmlkit-host` (`nativehtmlkit-host.exe` on Windows) in the directory of the running
   CLI executable (symbolic links resolved, so the `nhk` alias finds it too)
4. the same file name in each `PATH` directory, in order

1 and 2 must name an existing regular file (`error[host.not_found]: Core host binary does not
exist: <path>`); 3 and 4 are skipped when absent. Nothing found:
`error[host.not_found]: NativeHTMLKit Core host not found. Install a qualified release beside
the CLI or set NATIVEHTMLKIT_HOST_BINARY.` Release archives contain the exact host the CLI
was qualified with next to the CLI, so step 3 finds it; the override is for development.
`nativehtmlkit doctor` shows the result.

The CLI 0.1.2 is qualified with Core host 1.0.3 only. An older 1.0.x host speaks the same
protocol version and runs, but that combination is not qualified.
