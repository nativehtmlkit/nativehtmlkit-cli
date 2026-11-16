# Pick a Git branch

Show local branches, newest first, with their last commit, and switch to the chosen one.

## Quick version

```bash
git switch "$(git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch')"
```

If the user cancels, `$( )` is empty and `git switch ""` fails; the full script below checks
the status first.

## With columns: [examples/pick-git-branch.sh](../../examples/pick-git-branch.sh)

`git for-each-ref` prints tab-separated fields. Do not feed that to `--input-format tsv`: a
commit subject may begin with `"`, which CSV/TSV parsing treats as a quote
([input formats](../reference/input-formats.md#csv-and-tsv)). Build JSON with `jq` instead,
which cannot be broken by any character:

```bash
rows=$(git for-each-ref --sort=-committerdate \
    --format='%(HEAD)%09%(refname:short)%09%(committerdate:relative)%09%(upstream:short)%09%(subject)' \
    refs/heads |
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {
      Current: .[0], Branch: .[1], Updated: .[2], Upstream: .[3], "Last commit": (.[4:] | join("\t"))
    })')

status=0
picked=$(nativehtmlkit select --input-format json --output-format json \
           --title "Switch branch" --timeout 120 <<<"$rows") || status=$?
case $status in
  0)   git switch "$(jq -r '.[0].Branch' <<<"$picked")" ;;
  2)   echo "cancelled" >&2; exit 2 ;;
  124) echo "no branch chosen within 120 s" >&2; exit 124 ;;
  *)   exit "$status" ;;
esac
```

The JSON result is an array with the chosen record exactly as it went in, so
`.[0].Branch` is the branch name, whatever characters it contains.

## PowerShell: [examples/pick-git-branch.ps1](../../examples/pick-git-branch.ps1)

```powershell
$rows = @(git for-each-ref --sort=-committerdate "--format=$format" refs/heads | ForEach-Object {
    $f = $_ -split "`t", 5
    [pscustomobject]@{ Current = $f[0]; Branch = $f[1]; Updated = $f[2]; Upstream = $f[3]; 'Last commit' = $f[4] }
})
$picked = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --input-format json --output-format json --title 'Switch branch' --timeout 120
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
git switch (ConvertFrom-Json -InputObject ($picked -join "`n"))[0].Branch
```

`ConvertFrom-Json -InputObject` (rather than piping into `ConvertFrom-Json`) keeps a
one-element JSON array an array in Windows PowerShell 5.1 too.

## Variations

- Remote branches: `refs/remotes` instead of `refs/heads`, then `git switch --track`.
- Delete merged branches: `git branch --merged | ... select --multi`, confirm, `git branch -d`.
  Combine with the confirmation step from [deleting files](deleting-files-safely.md).
