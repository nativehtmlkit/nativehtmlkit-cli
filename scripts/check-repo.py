#!/usr/bin/env python3
from pathlib import Path
import tomllib
root=Path(__file__).resolve().parents[1]
obj=tomllib.loads((root/'Cargo.toml').read_text())
assert obj['package']['name']=='nativehtmlkit-cli'
assert not (root/'.github/workflows').exists(), 'no GitHub Actions workflows allowed'
assert not (root/'crates').exists(), 'do not copy Core crate source to CLI'
assert 'nativehtmlkit-core' not in str(obj.get('dependencies')), 'no Core source-tree dependency allowed'
assert (root/'src/protocol.rs').is_file()
assert (root/'src/backend.rs').is_file()
print('PASS: independent CLI boundaries, no GitHub Actions')
