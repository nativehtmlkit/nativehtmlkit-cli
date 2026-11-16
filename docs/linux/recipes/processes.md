# Choose processes to signal (Linux)

Pick processes in a table, then pick the signal to send them. Script:
[examples/kill-process.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/kill-process.sh)
(needs procps `ps`, `awk`, `jq`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Run it

Start a harmless process to practise on, then offer only the processes whose command line
contains `sleep 300`:

<!-- test: exit=124 calls="124@1x6" -->
```bash
sleep 300 & sleeper=$!
./kill-process.sh 'sleep 300'
status=$?
kill "$sleeper"
exit "$status"
```

The table shows `PID`, `User`, `CPU %`, `Mem %`, `Running` and `Command`. After Submit a
second window offers `TERM`, `INT` and `KILL`; only then is the signal sent. On Cancel or a
timeout nothing is signalled:

<!-- stderr -->
```text
kill-process: nothing signalled
```

No match: the script exits 0 without a window:

<!-- test: exit=0 calls="" -->
```bash
./kill-process.sh 'no-such-process-name-42'
```

<!-- stderr -->
```text
kill-process: no process matches 'no-such-process-name-42'
```

## How it works

`ps` output is aligned by spaces and the command line contains spaces, so the script turns
it into CSV, quoting the free-text field and doubling any `"` in it as CSV requires. It takes
the snapshot first and filters afterwards, so the filter does not list itself:

<!-- not-tested: excerpt of examples/kill-process.sh, which is run above -->
```bash
listing=$(ps -eo pid=,user=,pcpu=,pmem=,etime=,args= --sort=-pcpu)
rows=$(awk -v filter="$filter" -v self=$$ '
    BEGIN { print "PID,User,CPU %,Mem %,Running,Command" }
    $1 == self || n >= 500 { next }
    {
      cmd = $6; for (i = 7; i <= NF; i++) cmd = cmd " " $i
      if (filter != "" && index(cmd, filter) == 0) next
      if (length(cmd) > 160) cmd = substr(cmd, 1, 157) "..."
      gsub(/"/, "\"\"", cmd)
      printf "%s,%s,%s,%s,%s,\"%s\"\n", $1, $2, $3, $4, $5, cmd; n++
    }' <<<"$listing")

status=0
picked=$(nativehtmlkit select --multi --input-format csv --output-format json \
           --title "Processes to signal" <<<"$rows") || status=$?
[[ $status -eq 0 ]] || { echo "kill-process: nothing signalled" >&2; exit "$status"; }
mapfile -t pids < <(jq -r '.[].PID' <<<"$picked")
```

`--output-format json` turns each chosen CSV row into an object keyed by the header, so
`.[].PID` reads the column by name. The signal is a second, single-choice `select` whose
first word is the signal name:

<!-- test: exit=124 calls="124@3x1" -->
```bash
printf 'TERM  - ask the process to exit\nINT   - like Ctrl+C\nKILL  - force, cannot be caught\n' |
  nativehtmlkit select --title 'Signal for 2 process(es)'
```

<!-- submit: pick=1 -->
```text
TERM  - ask the process to exit
```

The script keeps `${signal%% *}` (`TERM`) and runs `kill -s TERM -- PID...`.

## A quick one-liner

`pgrep -a` already prints `PID command`; `cut` keeps the PID of each chosen line:

<!-- test: exit=124 calls="124@1x1" -->
```bash
sleep 301 & sleeper=$!
pgrep -a -f 'sleep 301' | nativehtmlkit select --multi --title 'Stop' | cut -d' ' -f1 | xargs -r kill
status=${PIPESTATUS[1]}
kill "$sleeper"
exit "$status"
```

Windows: [Choose processes to stop (Windows)](../../windows/recipes/processes.md).
