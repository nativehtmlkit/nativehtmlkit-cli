# Data, format and output semantics

## Main invariants

1. Parsed input is a sequence of immutable source records, each assigned a **zero-based stable index**. All filtering, sorting, pagination and checkbox interaction target indices, never display text.
2. Default output contains exactly the selected canonical records in **original input order**. Visual search and sorting never reorder output unless a future explicit option says so.
3. Original Unicode text and typed JSON values are preserved across selection; serializations may normalize whitespace, line endings or CSV quoting. Do not promise byte-identical CSV or JSON round-trip.
4. No output before Submit. After Submit, stdout writing occurs only in the launcher after clean host termination and receipt validation.
5. Unknown output conversions fail explicitly. No silent stringification of objects for `lines` output.

## Input format table

| Input mode | Expected payload | Accepted record model | Output `same` |
|---|---|---|---|
| `lines` | UTF-8 newline-separated text | one string per line, including blank rows | selected text lines with `\n` |
| `csv` | RFC 4180-style comma-separated UTF-8 with header | each row a map header→string; reject duplicates/ambiguous headers | header plus selected rows in canonical CSV |
| `tsv` | tab-separated UTF-8 with header | map header→string; quoting policy must be explicit; forbid ambiguous embedded tabs/newlines unless supported parser handles them | canonical TSV |
| `json` | one UTF-8 JSON **array** | each array item is a record (prefer object or scalar); reject top-level non-array | one JSON array containing selected items (even one item) |
| `ndjson` | one JSON value per line | each line is an independent JSON value | selected JSON values, one per line |
| `text` | arbitrary UTF-8 text for `view` | not row structured by default | no data output |

- UTF-8 is canonical. Optional UTF-8 BOM accepted only at beginning; CRLF is accepted and normalized. Embedded NUL/control characters should be rejected or rendered visibly in labels, not inserted raw into UI.
- Strict JSON: reject duplicate object keys, nonfinite number spellings, invalid UTF-8 and trailing non-whitespace. Consider preserving raw JSON numeric lexemes for exact re-serialization later; v0.1 should at least preserve numeric values accurately using appropriate parser settings.
- NDJSON: each nonempty line is one complete JSON value; document whether blank lines are ignored (proposal: ignore them) and keep original record index after this normalization.
- CSV quoted embedded newlines are legal and must not be split as records by naive line iteration. The same applies to escaped quotes. Do not implement CSV manually.
- Lines mode: trailing final `\n` does not add an extra empty row, but explicit blank lines **do** represent selectable empty records.

## Dataset model (proposed internal Rust types)

```rust
pub struct Dataset {
    pub format: InputFormat,
    pub headers: Vec<String>,
    pub records: Vec<CanonicalRecord>,
}
pub struct CanonicalRecord {
    pub input_index: u32,
    pub value: serde_json::Value, // lines represented as JSON strings
    // Optional raw bytes/lexemes for future lossless formats.
}
pub struct SelectionState {
    pub selected_indices: std::collections::BTreeSet<u32>,
    pub filtered_indices: Vec<u32>,
    pub page_number: usize,
}
```

Core's HTML document is a **view**, not the canonical dataset. Checkbox UI state can be reconstructed after an HTML refresh; the backend's BTreeSet remains authoritative.

## Output formats

- `same`: compatible with source format as specified above; no hidden format guessing.
- `lines`: emit selected string records only. Reject object/array input unless `--value-field` explicitly chooses a scalar string field.
- `csv`, `tsv`: allowed when source is structured and columns can be represented deterministically; output canonical header and rows, escape correctly. CSV output is **for machine pipelines**, not automatically safe to open in spreadsheet software; see OWASP injection warning.
- `json`: always a JSON array of selected raw record values (`[x]` for a single selection; `[]` for allowed empty).
- `ndjson`: each selected value as compact JSON, one per line.
- `values`: only with `--value-field`, one escaped/validated scalar value per line; avoid accidental newline/NUL ambiguity.
- `result-json`: explicit typed result envelope defined by JSON Schema. Include indices and original values, type/capability metadata, but never emit status `cancelled` to normal stdout (cancel is status 10, no stdout).

## File-based form outputs

Forms do not automatically receive selected-table records. `form --spec` defines named, typed fields; the JSON result is an object keyed by field IDs. Repeated/multi-select fields produce arrays. Rejected/invalid form submission does not produce stdout. `form --html` uses input `name` attributes and Core `get_form_data` with defined mapping rules.

## Snapshot and streaming boundary

All P1/P2 snapshots finish stdin ingestion **before** opening a window. This means `journalctl -f | nhk view` waits forever in P2; only the future `--follow` contract changes this. Streaming needs bounded incremental frames and UI update coalescing, not a `read_to_end` hack with unlimited allocations.

## Conformance fixtures

Fixtures must cover strings `α`, `žluťoučký`, emoji, CRLF, blank lines, long lines, embedded commas and CSV newlines, duplicate headers, NDJSON arrays/objects/scalars, malformed JSON, Unicode normalization, duplicate labels, and chosen indices across filtered/sorted pages.
