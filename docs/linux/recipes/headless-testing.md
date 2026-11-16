# Test your scripts without a desktop (Linux)

A script that opens a window is hard to test in CI: nobody clicks. This repository tests its
examples and these pages headless; you can do the same for your own scripts.

> `NATIVEHTMLKIT_CLI_TEST_HEADLESS` is a **test-only switch**, not part of the user contract
> of CLI 0.1.2, and may change in a later release. Never set it for real use.

The examples were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## What headless mode proves

With `NATIVEHTMLKIT_CLI_TEST_HEADLESS=1` the CLI starts the real Core host with
`--headless`: the host runs the whole protocol (handshake, window, document, events,
shutdown) without showing anything. With no input, every session ends by `--timeout`:

<!-- test: exit=0 shim=off -->
```bash
export NATIVEHTMLKIT_CLI_TEST_HEADLESS=1
printf 'a\nb\n' | nativehtmlkit select --timeout 0.5 2> /dev/null
echo "exit $?"
```

<!-- stdout -->
```text
exit 124
```

Exit 124 with empty stdout shows that the input was parsed, the page was accepted by the
host and the exit contract held. `--diagnostics debug` shows how the input was understood:

<!-- test: exit=0 shim=off -->
```bash
export NATIVEHTMLKIT_CLI_TEST_HEADLESS=1
printf 'a,b\n1,2\n3,4\n' | nativehtmlkit select --input-format csv --timeout 0.5 --diagnostics debug 2>&1 |
  grep -o '"event":"session.started".*'
```

<!-- stdout -->
```text
"event":"session.started","context":{"mode":"select","rows":2,"columns":2}}
```

Input errors still fail at once with exit 1, so a headless run also proves your data is
acceptable (UTF-8, valid JSON, row, column and page limits):

<!-- test: exit=0 shim=off -->
```bash
export NATIVEHTMLKIT_CLI_TEST_HEADLESS=1
printf 'a,b\n1,2,3\n' | nativehtmlkit select --input-format csv --timeout 0.5 2> /dev/null
echo "exit $?"
```

<!-- stdout -->
```text
exit 1
```

## Testing a whole script

Your script probably sets its own `--timeout` (or none). Put a small wrapper named
`nativehtmlkit` first on `PATH` that replaces the deadline with a short one and records each
call; optionally it hands the script a recorded result instead, to test what happens after
a Submit ("replay"):

<!-- test: exit=0 shim=off -->
```bash
real=$(command -v nativehtmlkit)
mkdir -p shim
cat > shim/nativehtmlkit <<SH
#!/usr/bin/env bash
args=(); skip=0
for a in "\$@"; do
  if ((skip)); then skip=0; continue; fi
  case \$a in --timeout) skip=1 ;; --timeout=*) ;; *) args+=("\$a") ;; esac
done
NATIVEHTMLKIT_CLI_TEST_HEADLESS=1 "$real" "\${args[@]}" --timeout 0.5 2>/dev/null
rc=\$?
echo "call: \${args[0]} -> \$rc" >> "$PWD/calls.log"
if [[ -n \${REPLAY:-} ]]; then printf '%s\n' "\$REPLAY"; exit 0; fi
exit \$rc
SH
chmod +x shim/nativehtmlkit
PATH=$PWD/shim:$PATH ./pick-timezone.sh; echo "headless: $?"
PATH=$PWD/shim:$PATH REPLAY=Asia/Tokyo ./pick-timezone.sh
cat calls.log
```

<!-- stdout -->
```text
headless: 124
Asia/Tokyo
call: select -> 124
call: select -> 124
```

The first run proves the script's window opened and that it passes 124 on; the second, with
a recorded result in the exact output format
([output formats](../output-formats.md)), what it does after a Submit.

This repository's harnesses do the same with more checks (rows x columns per call, document
ready, no stdout on a non-zero status, no leftover processes):

<!-- not-tested: runs the repository's own harnesses -->
```bash
scripts/test-examples.sh --cli /opt/nativehtmlkit-cli/nativehtmlkit           # the example scripts
python3 scripts/test-docs.py --cli /opt/nativehtmlkit-cli/nativehtmlkit       # every example on these pages
```

What this does **not** prove: anything that needs a person or a real screen (clicking,
keyboard focus, layout, colours). The CLI release's GUI qualification covers those.

Windows: [Test your scripts without a desktop (Windows)](../../windows/recipes/headless-testing.md).
