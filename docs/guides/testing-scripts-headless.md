# Test scripts without a desktop

A script that opens a window is hard to test in CI: nobody clicks. This repository tests its
own examples this way; you can do the same for your scripts.

> `NATIVEHTMLKIT_CLI_TEST_HEADLESS` is a **test-only switch**, not part of the user
> contract of 0.1.2. It may change in a later release. Never set it for real use.

## What headless mode proves

With `NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` the CLI starts the real Core host with `--headless`:
the host runs the whole protocol (handshake, window, document load, events, shutdown) without
showing anything. Since there is no input, every session ends by `--timeout`:

```bash
export NATIVEHTMLKIT_CLI_TEST_HEADLESS=1
printf 'a\nb\n' | nativehtmlkit select --timeout 0.5; echo "exit $?"
# nativehtmlkit: no decision before the --timeout deadline; the window was closed
# exit 124
```

Exit 124 with empty stdout shows that the input was parsed, the page was accepted by the
host and the exit contract held. Add `--diagnostics debug` to see how the input was parsed:

```bash
printf 'a,b\n1,2\n3,4\n' | nativehtmlkit select --input-format csv --timeout 0.5 --diagnostics debug 2>&1 |
  grep -o '"event":"session.started".*'
# "event":"session.started","context":{"mode":"select","rows":2,"columns":2}}
```

Input errors still fail immediately with exit 1, so headless runs also check that your data
is acceptable (row/column/page limits, UTF-8, valid JSON).

## Testing a whole script

Your script probably sets its own `--timeout` (or none). `scripts/test-examples.sh` puts a
small shim called `nativehtmlkit` first on `PATH` that:

1. removes any `--timeout` from the arguments and appends a short one;
2. runs the real CLI at `--diagnostics debug`, recording exit status, stdout size and the
   `rows x columns` of each call;
3. optionally replaces the (empty) result with a recorded one, so the rest of the script can
   be tested too ("replay").

A case then asserts, for example, that `delete-files.sh` exits 124 after one call that showed
3 rows x 4 columns, and that all files still exist; and in replay, that with a recorded
selection and a "Yes" confirmation exactly the chosen files are gone. Replayed results must
use the exact output formats ([output formats](../reference/output-formats.md)).

```bash
scripts/test-examples.sh --cli /opt/nativehtmlkit-cli/nativehtmlkit           # all cases
scripts/test-examples.sh --cli /opt/nativehtmlkit-cli/nativehtmlkit delete     # cases matching "delete"
```

PowerShell scripts use the same approach with a function named `nativehtmlkit` (PowerShell
resolves functions before executables):

```powershell
powershell.exe -NoProfile -File scripts\test-examples.ps1 -Cli C:\Tools\nativehtmlkit-cli-v0.1.2-windows-x64\nativehtmlkit.exe -Shell powershell.exe
pwsh -File scripts/test-examples.ps1 -Cli /opt/nativehtmlkit-cli/nativehtmlkit
```

What this does **not** prove: anything that needs a person or a real screen (clicking,
keyboard focus, layout, colours). The release's GUI qualification covers those for the CLI
itself.
