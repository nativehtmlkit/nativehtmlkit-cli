# Choose a Docker container (Linux)

Pick a container, then an action: show its logs, restart, stop, or open a shell. Script:
[examples/pick-container.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-container.sh)
(needs `docker`, `jq`, `perl`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)) with a stand-in `docker` that lists two
containers (`web`, and `db <primary>`), so no real Docker daemon was touched.

## Run it

<!-- test: exit=124 calls="124@2x6" -->
```bash
./pick-container.sh
```

The first window lists the containers (`Name`, `Image`, `State`, `Status`, `Ports`, `ID`).
After the user picks `web`:

<!-- replay: call=1 exit=0 expect=124 -->
```json
[{"Name":"web","Image":"nginx:1.27","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp","ID":"3f2a9c1d7b44"}]
```

a second window asks for the action; nobody answers here, so nothing is done:

<!-- stderr -->
```text
pick-container: no action taken
```

With `restart` chosen, the script runs `docker restart 3f2a9c1d7b44` and exits 0:

<!-- replay: call=2 exit=0 expect=0 keep=1 -->
```text
restart
```

With `logs` chosen, a third window shows the container's last 1,000 log lines:

<!-- replay: call=2 exit=0 expect=124 keep=1 -->
```text
logs
```

## How it works

`docker ps --format '{{json .}}'` prints one JSON object per container per line: exactly
the `ndjson` input format. The objects have many keys; project the useful ones with `jq` so
the table stays narrow:

<!-- test: exit=124 calls="124@2x6" -->
```bash
docker ps --all --format '{{json .}}' | jq -c '{Name: .Names, Image, State, Status, Ports, ID}' |
  nativehtmlkit select --input-format ndjson --output-format json --title 'Containers'
```

<!-- submit: pick=2 -->
```json
[{"Name":"db <primary>","Image":"postgres:17","State":"exited","Status":"Exited (0) 3 minutes ago","Ports":"5432/tcp","ID":"9b8e7d6c5a43"}]
```

The name `db <primary>` is shown as text, never as markup. `jq -r '.[0].ID'` then gives the
id. Logs are shown with `view`, each line cut to 400 characters (by character, with
`perl -CSD`, so UTF-8 stays valid) to stay inside the 1 MiB page limit:

<!-- test: exit=124 calls="124@2x1" -->
```bash
docker logs --tail 1000 --timestamps 3f2a9c1d7b44 2>&1 | perl -CSD -pe 's/^(.{400}).+/$1.../' |
  nativehtmlkit view --title 'Logs: web'
```

`--title` allows 128 characters, so the script cuts container names to 80
(`${name:0:80}`). The same pattern works for any tool that prints JSON: `kubectl get pods -o
json | jq -c '.items[] | {name: .metadata.name, phase: .status.phase}'` is `ndjson` too.

Windows: [Choose a Docker container (Windows)](../../windows/recipes/docker.md).
