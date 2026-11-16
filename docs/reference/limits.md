# Limits

All limits are checked **before a host process or a window exists**; exceeding one exits 1
with `error[input.invalid]` (or `usage.invalid` for the title) and empty stdout.

| Limit | Value | Applies to | Message |
|---|---|---|---|
| stdin size | 8 MiB (8,388,608 bytes) | `select`, `view` | `input exceeds 8 MiB; use a prefiltered pipeline or smaller selection` |
| rows | 2,000 | `select`, `view` | `2001 rows exceeds the 2000-row initial GUI limit` (`lines`, `json`); `too many records` (`csv`/`tsv`); `too many NDJSON rows` |
| columns | 32 | `select`, `view` | `too many columns` (`csv`/`tsv`); `33 columns exceeds the 32-column limit` (`json`/`ndjson`) |
| `--html` / `--css` file | 256 KiB (262,144 bytes), UTF-8 | `form`, every `--css` | `custom HTML or CSS file exceeds 256 KiB` |
| `--title` | 1-128 characters, no control characters (tab, newline, ...) | all | `error[usage.invalid]: --title must be nonempty, at most 128 characters, with no control characters` |
| generated page | 1 MiB (1,048,576 bytes) of HTML | all | `input is too large to display: the generated page is N bytes, the host accepts 1048576 (1 MiB); prefilter the input` |
| document nodes | 65,536 | `select`, `view` tables | `input is too large to display: R rows x C columns need about N document nodes, the host accepts 65536; at this width at most M rows fit (prefilter the input or select fewer columns)` |

## Document nodes

The host refuses documents with more than 65,536 nodes (elements and text nodes). The CLI
counts the nodes of its generated page the way the page is built:

```text
select table:  48 + 2 x (columns + 1) + rows x (3 + 2 x columns)
view table:    48 + 2 x columns       + rows x (1 + 2 x columns)
```

(an empty cell needs one node less). Some sizes that fit and do not fit:

| Rows x columns | `select` | `view` (table) |
|---|---|---|
| 2,000 x 14 | fits | fits |
| 1,870 x 16 | fits | fits |
| 1,871 x 16 | refused ("at most 1870 rows fit") | fits |
| 976 x 32 | fits | fits |
| 1,000 x 32 | refused | fits |
| 2,000 x 32 | refused | refused |

`view` of `lines` input is one text block, not a table: only the 1 MiB page limit applies.
A `form` page is not counted; the host's own limits apply to your fragment.

## The 1 MiB page

The page contains the built-in style sheet (about 1.3 KB), your `--css`, the escaped title
and every escaped cell. Escaping grows `&`, `<`, `>`, `"`, `'` to 4-5 bytes each. In
practice 2,000 lines of 500 characters still fit in a `view`; 2,000 lines of 600 do not.
Shorten long lines before piping them in (see [viewing logs](../guides/viewing-logs.md)).

## No limit

- How long a person may take: unlimited unless `--timeout` is given.
- Cell length: only the page limit.
- The number of concurrent CLI windows: each invocation is its own host session.
