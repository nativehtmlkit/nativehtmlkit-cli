# Verified at spec packaging time

These checks validate only the specification ZIP's machine-readable interfaces and fixture examples, **not** the Rust CLI itself.

Run:

```bash
python verification/validate_contracts.py
```

Developer requirements: Python + jsonschema + PyYAML. No runtime dependency implied for NativeHTMLKit CLI.

The script validates JSON Schema draft 2020-12 documents and example instances, the YAML command interface, and one negative cancellation receipt. Additional semantic invariants (unique form IDs, index bounds, numeric constraints, current Core API compatibility) must be tested in Rust during implementation.
