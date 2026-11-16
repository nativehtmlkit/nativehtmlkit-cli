# Choose a Docker container (Windows)

Pick a container, then an action: show its logs, restart or stop it. Script:
[examples/pick-container.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-container.ps1) (needs `docker`).

The examples run in the `examples` folder of a clone of this repository and were run
against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)) with a stand-in
`docker` that lists two containers (`web`, and `db <primary>`), so no real Docker
engine was touched.

## Run it

<!-- test: exit=124 calls="124@2x6" -->
```powershell
.\pick-container.ps1
```

After the user picks `web`, a second window asks for the action (here nobody answers, so
nothing is done):

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"web","Image":"nginx:1.27","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp","ID":"3f2a9c1d7b44"}]
```

<!-- stdout -->
```text
WARNING: No action taken.
```

With `restart` chosen the script runs `docker restart 3f2a9c1d7b44`:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
restart
```

With `logs` chosen a third window shows the last 1,000 log lines:

<!-- replay: call=2 exit=0 expect=124 keep=1 -->
```text
logs
```

## How it works

`docker ps --format '{{json .}}'` prints one JSON object per container per line. The script
keeps six properties and sends the objects as NDJSON:

<!-- test: exit=124 calls="124@2x6" -->
```powershell
docker ps --all --format '{{json .}}' | ForEach-Object {
    $c = $_ | ConvertFrom-Json
    [pscustomobject]@{ Name = $c.Names; Image = $c.Image; State = $c.State; Status = $c.Status; Ports = $c.Ports; ID = $c.ID } |
        ConvertTo-Json -Compress
} | nativehtmlkit select --input-format ndjson --output-format json --title 'Containers'
```

<!-- submit: pick=2 -->
```json
[{"Name":"db <primary>","Image":"postgres:17","State":"exited","Status":"Exited (0) 3 minutes ago","Ports":"5432/tcp","ID":"9b8e7d6c5a43"}]
```

The name `db <primary>` is shown as text, never as markup. Logs go to `view`; `docker`
writes some of them to stderr, so the script merges the streams with `2>&1` while
`$ErrorActionPreference` is `'Continue'` (with `'Stop'`, Windows PowerShell 5.1 would end
the script at the first stderr line):

<!-- not-tested: excerpt of examples/pick-container.ps1, which is run above -->
```powershell
$ErrorActionPreference = 'Continue'
docker logs --tail 1000 --timestamps $container.ID 2>&1 | ForEach-Object { "$_" } |
    nativehtmlkit view --title "Logs: $label"
```

Linux: [Choose a Docker container (Linux)](../../linux/recipes/docker.md).
