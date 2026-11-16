# Choose from JSON API output (Linux)

Reshape a REST response with `jq`, let the user pick records, and use fields of the chosen
records. Script:
[examples/pick-from-api.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-from-api.sh)
with the sample response
[examples/data/issues.json](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/data/issues.json)
(GitHub's issue list format; needs `jq`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Run it

With the saved response, or with a live one piped in
(`curl -fsS 'https://api.github.com/repos/OWNER/REPO/issues?per_page=100' | ./pick-from-api.sh`):

<!-- test: exit=124 calls="124@3x6" -->
```bash
./pick-from-api.sh data/issues.json
```

The response has four entries; one is a pull request, so three issues are offered. The
script prints the URLs of the chosen issues:

<!-- replay: call=1 exit=0 expect=0 -->
```json
[{"#":42,"Title":"Window opens off-screen on a second monitor","Author":"ada","Labels":"bug, windows","Updated":"2026-11-12","url":"https://example.invalid/issues/42"},{"#":39,"Title":"Příliš žluťoučký kůň: Unicode in titles & \"quotes\"","Author":"zoë","Labels":"i18n","Updated":"2026-11-01","url":"https://example.invalid/issues/39"}]
```

<!-- stdout -->
```text
https://example.invalid/issues/42
https://example.invalid/issues/39
```

## How it works

The CLI shows one column per top-level key and nested values as compact JSON, so flatten
first, and keep the field you need afterwards (`url`) even if it is dull to look at:

<!-- test: exit=0 calls="124@3x6" -->
```bash
jq -c '[.[] | select(has("pull_request") | not) | {
         "#": .number, Title: .title, Author: .user.login,
         Labels: ([.labels[].name] | join(", ")), Updated: .updated_at[:10], url: .html_url
       }]' data/issues.json |
  nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues' |
  jq -r '.[].url'
```

In this one-line form a Cancel just produces no output; the script checks the status and
exits 2 or 124 instead. What comes back is the array of the chosen records **exactly as
they went in**: key order, numbers (`42`, not `42.0`) and Unicode are kept:

<!-- test: exit=124 calls="124@3x6" -->
```bash
jq -c '[.[] | select(has("pull_request") | not) | {
         "#": .number, Title: .title, Author: .user.login,
         Labels: ([.labels[].name] | join(", ")), Updated: .updated_at[:10], url: .html_url
       }]' data/issues.json |
  nativehtmlkit select --multi --input-format json --output-format json --title 'Open issues'
```

<!-- submit: pick=2 -->
```json
[{"#":41,"Title":"Document the <form> limits","Author":"grace","Labels":"docs","Updated":"2026-11-10","url":"https://example.invalid/issues/41"}]
```

## Variations

A one-column list of strings and `lines` output, for example to open the chosen URLs:

<!-- test: exit=0 calls="124@4x1" -->
```bash
jq -c '[.[].html_url]' data/issues.json |
  nativehtmlkit select --multi --input-format json --output-format lines |
  xargs -r -n1 echo open
```

Large responses: the CLI refuses more than 2,000 rows or 32 columns rather than cutting
them, so page or filter in `jq` (`.[:2000]`, a smaller object).

Windows: [Choose from JSON API output (Windows)](../../windows/recipes/json-api.md).
