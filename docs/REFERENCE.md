# Command reference

| Command | Description | Output |
|---|---|---|
| `nativehtmlkit select [--multi]` | Choose rows supplied on stdin | Selection in requested format; cancellation exits 2 |
| `nativehtmlkit view` | Display a read-only native viewer from stdin | No stdout |
| `nativehtmlkit form --html PATH` | Display a trusted HTML `<form id="nhk-form">` | JSON object containing successful-control entries |
| `nativehtmlkit doctor` | Check host discovery and environment | Diagnostic text |

Input formats: `lines` (default), `csv`, `tsv`, `json`, `ndjson`. Selections are emitted in original input order. Input limits from the current 0.1.x source: UTF-8, up to 8 MiB, 2,000 rows and 32 columns, with stricter HTML/node limits for dense tables. Untrusted input content is escaped; passed HTML/CSS snippets are trusted developer inputs.

`--timeout` sets the user's response deadline. RPC timeout, host startup timeout and liveness probing protect the process against an unresponsive host; they do not imply a human response deadline. For full flags, consult `nativehtmlkit --help` on the installed release.
