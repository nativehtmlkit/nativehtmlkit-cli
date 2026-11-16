# `nativehtmlkit doctor`

Report which Core host executable the CLI would use, and that it starts.

```text
nativehtmlkit doctor [--host <PATH>]
```

`doctor` finds the host exactly as every other command does ([host discovery](global-options.md#host-discovery)),
runs it once with `--version` (stdin closed, at most 10 seconds) and prints three lines to
stdout:

```text
NativeHTMLKit CLI 0.1.2
Core host: /opt/nativehtmlkit-cli/nativehtmlkit-host
nativehtmlkit-host 1.0.3
```

The third line is the host's own `--version` output. No window is opened and no session is
started; the other global options are accepted and ignored.

| Situation | Exit | stderr |
|---|---|---|
| host found, `--version` succeeded | 0 | |
| no host found anywhere | 1 | `nativehtmlkit: error[host.not_found]: NativeHTMLKit Core host not found. Install a qualified release beside the CLI or set NATIVEHTMLKIT_HOST_BINARY.` |
| `--host` / `NATIVEHTMLKIT_HOST_BINARY` names no regular file | 1 | `nativehtmlkit: error[host.not_found]: Core host binary does not exist: <path>` |
| the file cannot be started (e.g. not executable) | 1 | `nativehtmlkit: error[host.not_found]: cannot start the Core host (<reason>)` |
| it ran but failed or printed nothing | 1 | `nativehtmlkit: error[host.failed]: Core host version check failed with <status>` |
| it did not exit within 10 s (it is killed) | 1 | `nativehtmlkit: error[host.failed]: the Core host did not answer --version in time (after 10000 ms)` |

Use it first when a command reports `host.not_found`, and to confirm which host a pinned
installation uses. Examples: [Linux](../linux/commands/doctor.md),
[Windows](../windows/commands/doctor.md).
