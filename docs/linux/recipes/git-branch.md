# Pick a Git branch (Linux)

Show the local branches, newest first, with their last commit, and switch to the one the
user picks. Script:
[examples/pick-git-branch.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-git-branch.sh)
(needs `git` and `jq`). For a step-by-step version with TSV and deleting merged branches,
see the [branch picker tutorial](../tutorial-branch-picker.md).

The examples run in the `examples` directory of a clone of this repository (a Git work
tree) and were run against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Quick version

<!-- test: exit=124 calls="124@4x1" -->
```bash
branch=$(git branch --format='%(refname:short)' | nativehtmlkit select --title 'Switch branch') &&
  git switch "$branch"
```

`&&` runs `git switch` only after a Submit; on Cancel (2) or a timeout (124) nothing
happens and the line ends with the CLI's status.

## With columns

<!-- test: exit=124 calls="124@4x5" -->
```bash
./pick-git-branch.sh
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

<!-- stderr -->
```text
pick-git-branch: cancelled; still on main
```

## How it works

`git for-each-ref` prints tab-separated fields. Do not feed that to `--input-format tsv`: a
commit subject may begin with `"`, which TSV parsing treats as a quote
([input formats](../input-formats.md#tsv)). `jq` builds JSON, which no character can break:

<!-- not-tested: excerpt of examples/pick-git-branch.sh, which is run above -->
```bash
rows=$(git -C "$repo" for-each-ref --sort=-committerdate \
    --format='%(HEAD)%09%(refname:short)%09%(committerdate:relative)%09%(upstream:short)%09%(subject)' \
    refs/heads |
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {
      Current: .[0], Branch: .[1], Updated: .[2], Upstream: .[3], "Last commit": (.[4:] | join("\t"))
    })')

status=0
picked=$(nativehtmlkit select --input-format json --output-format json \
           --title "Switch branch" --timeout 120 <<<"$rows") || status=$?
case $status in
  0)   ;;
  2)   echo "pick-git-branch: cancelled; still on $(git -C "$repo" branch --show-current)" >&2
       exit 2 ;;
  124) echo "pick-git-branch: no branch chosen within 120 s" >&2
       exit 124 ;;
  *)   exit "$status" ;;   # the CLI already printed "nativehtmlkit: error[...]" on stderr
esac

branch=$(jq -r '.[0].Branch' <<<"$picked")
git -C "$repo" switch "$branch"
```

`.[0].Branch` is the branch name whatever characters it contains.

## Variations

Remote branches, then track the chosen one:

<!-- test: exit=124 calls="124@4x1" -->
```bash
git for-each-ref --format='%(refname:short)' refs/heads refs/remotes |
  nativehtmlkit select --title 'Check out' --timeout 120
```

Delete merged branches: tick several with `--multi`, and `git branch -d` refuses anything
that is not merged:

<!-- test: exit=0 calls="124@3x1" -->
```bash
git branch --merged main --format='%(refname:short)' | grep -vx main |
  nativehtmlkit select --multi --title 'Delete merged branches' |
  xargs -r git branch -d --
```

Here `feature/login`, `fix/typo` and `release/1.4` are merged into `main`. Submit prints,
after ticking `fix/typo`:

<!-- submit: pick=2 -->
```text
fix/typo
```

The Windows counterpart is
[Pick a Git branch (Windows)](../../windows/recipes/git-branch.md).
