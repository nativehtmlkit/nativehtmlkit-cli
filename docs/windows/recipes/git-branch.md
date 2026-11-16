# Pick a Git branch (Windows)

Show the local branches, newest first, with their last commit, and switch to the one the
user picks. Script:
[examples/pick-git-branch.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-git-branch.ps1)
(needs `git`). For a step-by-step version that can also delete merged branches, see the
[branch picker tutorial](../tutorial-branch-picker.md).

The examples run in the `examples` folder of a clone of this repository (a Git work tree)
and were run against the released CLI 0.1.2 in Windows PowerShell 5.1 and PowerShell 7 by
`scripts/test-docs.ps1` ([how](../index.md#how-the-examples-are-verified)).

## Quick version

<!-- test: exit=124 calls="124@4x1" -->
```powershell
$branch = git branch '--format=%(refname:short)' | nativehtmlkit select --title 'Switch branch'
if ($LASTEXITCODE -eq 0) { git switch $branch }
```

`git switch` runs only after a Submit; on Cancel (2) or a timeout (124) nothing happens.
(`'--format=...'` in quotes keeps PowerShell from interpreting the parentheses.)

## With columns

<!-- test: exit=124 calls="124@4x5" -->
```powershell
.\pick-git-branch.ps1
```

The window shows `Current`, `Branch`, `Updated`, `Upstream` and `Last commit`. When the
user picks `feature/login`, the CLI returns that record as a JSON array (the record exactly
as it went in) and the script switches:

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"Current":" ","Branch":"feature/login","Updated":"2 minutes ago","Upstream":"","Last commit":"Add the example scripts"}]
```

<!-- stderr -->
```text
Switched to branch 'feature/login'
```

After Cancel nothing changes and the script exits 2:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: Cancelled; staying on the current branch.
```

## How it works

`git for-each-ref` prints tab-separated fields; the script turns each line into an object
and sends the objects as JSON, which no character in a commit subject can break:

<!-- not-tested: excerpt of examples/pick-git-branch.ps1, which is run above -->
```powershell
$format = '%(HEAD)%09%(refname:short)%09%(committerdate:relative)%09%(upstream:short)%09%(subject)'
$rows = @(git -C $Repository for-each-ref --sort=-committerdate "--format=$format" refs/heads |
    ForEach-Object {
        $f = $_ -split "`t", 5
        [pscustomobject]@{ Current = $f[0]; Branch = $f[1]; Updated = $f[2]; Upstream = $f[3]; 'Last commit' = $f[4] }
    })
$picked = $rows | ConvertTo-Json -Compress |
    nativehtmlkit select --input-format json --output-format json --title 'Switch branch' --timeout 120
```

After checking `$LASTEXITCODE`, the branch is read back with
`(ConvertFrom-Json -InputObject ($picked -join "`n"))[0].Branch`. `[0]` is the first record
in both editions: Windows PowerShell 5.1 returns the JSON array as one object, PowerShell 7
enumerates it (and `[0]` of a single object is that object).

## Variations

Remote branches as well:

<!-- test: exit=124 calls="124@4x1" -->
```powershell
git for-each-ref '--format=%(refname:short)' refs/heads refs/remotes |
    nativehtmlkit select --title 'Check out' --timeout 120
```

Delete merged branches: tick several with `--multi`; `git branch -d` refuses anything that
is not merged:

<!-- test: exit=124 calls="124@3x1" -->
```powershell
$merged = git branch --merged main '--format=%(refname:short)' | Where-Object { $_ -ne 'main' }
$chosen = $merged | nativehtmlkit select --multi --title 'Delete merged branches'
if ($LASTEXITCODE -eq 0) { $chosen | ForEach-Object { git branch -d $_ } }
```

Here `feature/login`, `fix/typo` and `release/1.4` are merged into `main`. Submit prints,
after ticking `fix/typo`:

<!-- submit: pick=2 -->
```text
fix/typo
```

Linux: [Pick a Git branch (Linux)](../../linux/recipes/git-branch.md).
