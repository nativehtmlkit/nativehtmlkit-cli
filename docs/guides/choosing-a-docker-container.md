# Choose a Docker container

Scripts: [examples/pick-container.sh](../../examples/pick-container.sh),
[examples/pick-container.ps1](../../examples/pick-container.ps1).

`docker ps --format '{{json .}}'` prints one JSON object per container per line: exactly the
`ndjson` input format. The objects carry many keys (command, labels, mounts, networks, ...);
project the useful ones so the table stays narrow:

```bash
rows=$(docker ps --all --format '{{json .}}' | jq -c '{Name: .Names, Image, State, Status, Ports, ID}')
[[ -n $rows ]] || { echo "no containers" >&2; exit 0; }

container=$(choose --input-format ndjson --output-format json --title "Containers" <<<"$rows")
id=$(jq -r '.[0].ID' <<<"$container")
name=$(jq -r '.[0].Name' <<<"$container")

action=$(printf 'logs\nrestart\nstop\nshell\n' | choose --title "Container ${name:0:80}")
case $action in
  logs)    docker logs --tail 1000 --timestamps "$id" 2>&1 | perl -CSD -pe 's/^(.{400}).+/$1.../' |
             nativehtmlkit view --title "Logs: ${name:0:80}" ;;
  restart) docker restart "$id" ;;
  stop)    docker stop "$id" ;;
  shell)   docker exec -it "$id" sh ;;
esac
```

Notes:

- `choose` ends the script on Cancel/timeout ([handling exit statuses](handling-exit-status.md)).
- `--title` is limited to 128 characters; container names are cut to 80 to leave room.
- Log lines are shortened to 400 characters so 1,000 of them stay inside the 1 MiB page
  limit ([limits](../reference/limits.md)); `perl -CSD` cuts characters, not bytes, so the
  text stays valid UTF-8.
- The same pattern works for any tool that prints JSON: reshape it with `jq -c` into one
  small object per line and pipe that in as `ndjson`.

PowerShell reads the same NDJSON line by line:

```powershell
$rows = @(docker ps --all --format '{{json .}}' | ForEach-Object {
    $c = $_ | ConvertFrom-Json
    [pscustomobject]@{ Name = $c.Names; Image = $c.Image; State = $c.State; Status = $c.Status; Ports = $c.Ports; ID = $c.ID } |
        ConvertTo-Json -Compress
})
$container = (ConvertFrom-Json -InputObject ($rows | Invoke-Picker select --input-format ndjson --output-format json --title 'Containers'))[0]
```

The verification harness runs these scripts against a stand-in `docker` that prints two
containers, so it never touches a real Docker daemon.
