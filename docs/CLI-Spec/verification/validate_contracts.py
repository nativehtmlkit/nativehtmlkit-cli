#!/usr/bin/env python3
"""Developer-only validation of proposal schemas, YAML IDL and examples.

Requires: pip install jsonschema pyyaml
Not a runtime dependency of nhk.
"""
from pathlib import Path
import json
from jsonschema import Draft202012Validator
import yaml

ROOT=Path(__file__).resolve().parents[1]
IDL=ROOT/'idl'
EX=ROOT/'examples'
SCHEMAS={name:json.loads((IDL/name).read_text(encoding='utf-8')) for name in (
    'invocation-v1.schema.json','form-v1.schema.json',
    'result-envelope-v1.schema.json','receipt-v1.schema.json')}
for name,schema in SCHEMAS.items():
    Draft202012Validator.check_schema(schema)
    print('SCHEMA OK',name)
cli=yaml.safe_load((IDL/'cli-interface-v1.yaml').read_text(encoding='utf-8'))
assert cli['apiVersion']=='nativehtmlkit.cli/v1'
assert set(cli['commands'])=={'select','view','form','confirm','input','doctor'}
print('CLI YAML OK')
fixtures=[('request-select-lines.json','invocation-v1.schema.json'),
          ('request-select-json.json','invocation-v1.schema.json'),
          ('request-form.json','form-v1.schema.json'),
          ('result-envelope.json','result-envelope-v1.schema.json'),
          ('receipt-submitted.json','receipt-v1.schema.json'),
          ('receipt-cancelled.json','receipt-v1.schema.json')]
for name,schema_name in fixtures:
    obj=json.loads((EX/name).read_text(encoding='utf-8'))
    Draft202012Validator(SCHEMAS[schema_name]).validate(obj)
    print('FIXTURE OK',name)
# Important negative checks: cancellation receipt may not carry row outputs.
bad=json.loads((EX/'receipt-cancelled.json').read_text())
bad['selected_indices']=[0]
assert not Draft202012Validator(SCHEMAS['receipt-v1.schema.json']).is_valid(bad)
print('NEGATIVE CASE OK')
print('ALL CONTRACT VALIDATION CHECKS PASSED')
