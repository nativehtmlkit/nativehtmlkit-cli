# Tutorial: a Git branch picker (Windows)

You will write **git-pick.ps1**, a PowerShell script that lists your local Git branches in a
native window, switches to the one you pick, and can delete merged branches in a
multi-select list. It shows how to use `nativehtmlkit select` safely in scripts: objects as
JSON, reading the result back, `$LASTEXITCODE` and timeouts. It works in Windows PowerShell
5.1 and PowerShell 7.

**Time:** about 20 minutes. **You need:** Git and `nativehtmlkit` on your `PATH`
([install](index.md#install)). Final code:
[examples/tutorial-branch-picker/git-pick.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial-branch-picker/git-pick.ps1). The same tutorial for
bash: [Linux](../linux/tutorial-branch-picker.md). The bash version sends TSV; PowerShell
builds objects, so this version sends JSON, which needs no clean-up of commit subjects.

The runs below were made in the `examples` folder of a clone of this repository (a Git work
tree with the branches `main`, `feature/login`, `fix/typo` and `release/1.4`) against the
released CLI 0.1.2 by `scripts/test-docs.ps1`, headless and with replayed results
([how](index.md#how-the-examples-are-verified)).

## Step 1: pick a branch

[step1-pick.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial-branch-picker/step1-pick.ps1):

<!-- not-tested: excerpt of examples/tutorial-branch-picker/step1-pick.ps1, run below -->
```powershell
<#
Branch picker tutorial, step 1: offer the local branches in a native list and report the choice.

Teaches: piping lines into `nativehtmlkit select`, capturing stdout, and the exit statuses
0 (chosen), 2 (cancelled), 124 (-Timeout expired) and anything else (error) through
$LASTEXITCODE. The PowerShell counterpart of step1-pick.sh.

Run:   .\step1-pick.ps1 [-Timeout SECONDS]     (inside a Git work tree)
Guide: docs/windows/tutorial-branch-picker.md (step 1 of 2)
#>
param([double] $Timeout = 0)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try {
    $extra = @()
    if ($Timeout -gt 0) { $extra = '--timeout', [string] $Timeout }

    $choice = git for-each-ref '--format=%(refname:short)' refs/heads/ |
        nativehtmlkit select --title 'Pick a branch' @extra
    $status = $LASTEXITCODE
    switch ($status) {
        0       { "You chose: $choice" }
        2       { Write-Warning 'Cancelled' }
        124     { Write-Warning 'No choice made in time' }
        default { Write-Warning "nativehtmlkit select failed with exit status $status" }
    }
    exit $status
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
```

- `git for-each-ref '--format=%(refname:short)' refs/heads/` prints one branch per line,
  which is the default `lines` input format.
- `nativehtmlkit select` opens the window and blocks. On success it prints the chosen line
  and `$LASTEXITCODE` is 0.
- `$LASTEXITCODE` is read once, right after the call, into `$status`.
- `-Timeout` passes `--timeout` through only when given.

Run it inside any Git work tree:

<!-- test: exit=124 calls="124@4x1" -->
```powershell
.\tutorial-branch-picker\step1-pick.ps1 -Timeout 30
```

Nobody chose within the deadline:

<!-- stdout -->
```text
WARNING: No choice made in time
```

After picking `release/1.4`:

<!-- replay: call=1 exit=0 expect=0 -->
```text
release/1.4
```

<!-- stdout -->
```text
You chose: release/1.4
```

After Cancel:

<!-- replay: call=1 exit=2 expect=2 -->
```text
```

<!-- stdout -->
```text
WARNING: Cancelled
```

## Step 2: a table, switching, and deleting merged branches

[git-pick.ps1](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/tutorial-branch-picker/git-pick.ps1):

<!-- not-tested: excerpt of examples/tutorial-branch-picker/git-pick.ps1, run below -->
```powershell
<#
git-pick.ps1: choose a local Git branch in a native window and switch to it (CLI tutorial final code).

Teaches: objects -> ConvertTo-Json -> `select --input-format json`, reading the chosen records
back, handling every exit status (0 chosen, 2 cancelled, 124 timed out, anything else an
error), multi-select with --multi, and stopping the script cleanly from a helper function.
The PowerShell counterpart of git-pick.sh.

Run:   .\git-pick.ps1 [-Timeout SECONDS]                 switch to the chosen branch
       .\git-pick.ps1 -DeleteMerged [-Timeout SECONDS]   delete chosen branches already merged
       .\git-pick.ps1 -Print                             show the table that would be offered
       (inside a Git work tree; needs `nativehtmlkit` on PATH)
Guide: docs/windows/tutorial-branch-picker.md
#>
param([double] $Timeout = 0, [switch] $DeleteMerged, [switch] $Print)
$ErrorActionPreference = 'Stop'
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# One object per branch, most recently committed first. JSON carries any character safely,
# so commit subjects need no clean-up.
function Get-BranchTable([string[]] $Filter) {
    git for-each-ref --sort=-committerdate '--format=%(refname:short)%09%(committerdate:relative)%09%(subject)' @Filter refs/heads/ |
        ForEach-Object {
            $f = $_ -split "`t", 3
            [pscustomobject]@{ branch = $f[0]; updated = $f[1]; 'last commit' = $f[2] }
        }
}

# Runs `nativehtmlkit select` on the rows and returns the chosen branch names. On anything
# but a submit it explains the status and ends the script with it.
function Select-Branch([object[]] $Rows, [string] $Title, [string[]] $More = @()) {
    $extra = @()
    if ($Timeout -gt 0) { $extra = '--timeout', [string] $Timeout }
    $json = ConvertTo-Json -InputObject $Rows -Compress |
        nativehtmlkit select --input-format json --output-format json --title $Title @extra @More
    $status = $LASTEXITCODE
    switch ($status) {
        0       { return ConvertFrom-Json -InputObject ($json -join "`n") | ForEach-Object { $_ } | ForEach-Object { $_.branch } }
        2       { Write-Warning 'git-pick: cancelled; nothing changed' }
        124     { Write-Warning 'git-pick: no choice made in time; nothing changed' }
        default { Write-Warning "git-pick: nativehtmlkit select failed with exit status $status" }
    }
    exit $status
}

try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'git-pick: not inside a Git repository'; exit 1 }
    $current = git symbolic-ref --quiet --short HEAD
    if (-not $current) { $current = '(detached HEAD)' }

    if ($Print) {
        Get-BranchTable | Format-Table -AutoSize | Out-String -Stream -Width 200
        exit 0
    }
    if (-not $DeleteMerged) {
        $branch = Select-Branch @(Get-BranchTable) "Switch branch (current: $current)"
        if ($branch -eq $current) { "Already on $branch"; exit 0 }
        git switch --quiet $branch
        if ($LASTEXITCODE -ne 0) { exit 1 }
        "Switched to $branch"
        exit 0
    }

    # Offer every merged branch except the one you are on.
    $merged = @(Get-BranchTable '--merged', 'HEAD' | Where-Object { $_.branch -ne $current })
    if ($merged.Count -eq 0) { 'No merged branches to delete'; exit 0 }
    foreach ($branch in (Select-Branch $merged 'Delete merged branches' '--multi')) {
        git branch --quiet -d $branch
        if ($LASTEXITCODE -ne 0) { exit 1 }
        "Deleted $branch"
    }
    exit 0
}
finally {
    [Console]::OutputEncoding = $previousEncoding
}
```

- `Get-BranchTable` turns each `git for-each-ref` line into an object with `branch`,
  `updated` and `last commit`; `ConvertTo-Json -InputObject $Rows` sends them as one JSON
  array (also when there is only one).
- `--output-format json` returns the chosen objects exactly as they went in; the script
  keeps their `branch` property.
- `Select-Branch` turns every exit status into a clear message and ends the script with it:
  2 when cancelled, 124 when `-Timeout` expired.
- `-DeleteMerged` offers only branches merged into `HEAD` (minus the current one) and passes
  `--multi`, so the user can tick several rows. Each is deleted with `git branch -d`, which
  refuses anything not merged.
- `-Print` shows the table without opening a window.

## Try it

The table that would be offered (no window):

<!-- test: exit=0 calls="" -->
```powershell
.\tutorial-branch-picker\git-pick.ps1 -Print | Select-String -Pattern '^(main|fix/typo|feature/login|release/1\.4) ' |
    ForEach-Object { ($_.Line -split ' ')[0] }
```

<!-- stdout -->
```text
main
fix/typo
feature/login
release/1.4
```

Switch branch, giving up after 20 seconds (exit 124):

<!-- test: exit=124 calls="124@4x3" -->
```powershell
.\tutorial-branch-picker\git-pick.ps1 -Timeout 20
```

<!-- stdout -->
```text
WARNING: git-pick: no choice made in time; nothing changed
```

With `feature/login` picked, the CLI returns that object and the script switches:

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"branch":"feature/login","updated":"6 days ago","last commit":"Add the example scripts"}]
```

<!-- stdout -->
```text
Switched to feature/login
```

Tidy up merged branches (`-DeleteMerged`, `--multi`):

<!-- test: exit=124 calls="124@3x3" -->
```powershell
.\tutorial-branch-picker\git-pick.ps1 -DeleteMerged
```

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"branch":"fix/typo","updated":"4 days ago","last commit":"Fix the \"quick start\" typo"},{"branch":"release/1.4","updated":"6 days ago","last commit":"Add the example scripts"}]
```

<!-- stdout -->
```text
Deleted fix/typo
Deleted release/1.4
```

Save it as `git-pick.ps1` in a folder on your `PATH` to run it from any repository.

## What you learned

- Send objects as JSON and read the chosen objects back with
  `ConvertFrom-Json -InputObject`.
- Check `$LASTEXITCODE` right after the call and hand it on with `exit`.
- Use `--multi` and `--timeout`.

## Where next

- [form](commands/form.md) collects several values at once from trusted HTML; the
  [project picker tutorial](tutorial.md) uses `select`, `form` and `view` together.
- [Recipes](recipes/index.md), and every option on [select](commands/select.md).
- For anything more interactive than one decision, use the PowerShell or Python SDK
  (see [nativehtmlkit.github.io](https://nativehtmlkit.github.io/)).
