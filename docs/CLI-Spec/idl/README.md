# Interface definition and schemas

This directory is the IDL for the proposed NativeHTMLKit CLI layer, **not** a replacement for the existing host JSON-RPC v1 protocol.

## Normative documents

- `cli-interface-v1.yaml` — machine-readable command/flag/exit/status surface.
- `invocation-v1.schema.json` — normalized request from CLI args or future local adapter. This is **proposed internal/tool-level data**, not a claim that `nhk --spec` already accepts it for all commands.
- `form-v1.schema.json` — declarative user form request for P3; this can later be publicly supported by `nhk form --spec`.
- `result-envelope-v1.schema.json` — optional explicit `--output result-json` stdout result; default stdout remains selected records.
- `receipt-v1.schema.json` — **internal** atomic child→launcher receipt, never printed directly.
- `nhk-contract-v1.d.ts` — human-friendly TypeScript declaration IDL to clarify intended shape; JSON Schemas are the executable validation authority.
- `host-protocol-bridge-v1.md` — map to actual Core host RPC methods and constraints.

`schema_version=1` scopes **CLI data contracts**, while `protocol_version=1` scopes **existing host transport**. They are unrelated counters and must not be conflated.

## Intended validation

```bash
python verification/validate_contracts.py
```

Requires `jsonschema` and `PyYAML` only on the **developer machine**, not in the compiled CLI distribution. The validation script checks all schema documents for well-formedness and checks fixture payloads. The Rust implementation should mirror these checks using an audited JSON Schema-compatible validation strategy or equivalent strict typed decoders and semantic invariants.

## Additional runtime invariants not expressible by vanilla JSON Schema

- Submitted `selected_indices` must be strictly ordered, unique, in bounds, and correspond to emitted canonical records.
- `selected` array length equals `selected_indices` length for optional JSON envelope.
- `mode=single` never selects multiple indices and `min/max` must be compatible.
- Private receipt nonce and dataset hash must match the active secure session.
- A cancelled interaction must not be emitted to stdout as a result envelope.
- Form field IDs must be unique; option values unique within field; defaults and validation rules match field types.
- Display label truncation must not alter source value emission.
