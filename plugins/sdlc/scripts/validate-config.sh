#!/usr/bin/env bash
# JSON Schema validator for sdlc.config.json.
# Sourced by load-config.sh. Provides validate_rq_config function.

# validate_rq_config
# Validates sdlc.config.json against schemas/sdlc-config.json.
# Caches the result by content hash of sdlc.config.json to avoid re-validating.
# Exits the script with stderr on validation failure.
validate_rq_config() {
  # No config file = nothing to validate
  [ -n "$SDLC_CONFIG_FILE" ] || return 0
  [ -f "$SDLC_CONFIG_FILE" ] || return 0

  local schema_file
  schema_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/schemas/sdlc-config.json"
  [ -f "$schema_file" ] || return 0 # schema missing = skip (e.g., during bootstrap)

  # Cache by content hash of the config file
  local config_hash
  config_hash=$(SDLC_CFG="$SDLC_CONFIG_FILE" python3 -c "import hashlib, os; print(hashlib.sha256(open(os.environ['SDLC_CFG'],'rb').read()).hexdigest()[:12])" 2>/dev/null)
  local proof_dir="${PROOF_DIR:-.quality/proof}"
  # Empty hash = Python/hash failure — skip cache and always re-validate.
  if [ -n "$config_hash" ]; then
    local cache_marker="$proof_dir/.config-validated-$config_hash"
    [ -f "$cache_marker" ] && return 0
  fi

  SDLC_CFG="$SDLC_CONFIG_FILE" SCHEMA_FILE="$schema_file" python3 -c "
import json, os, sys

with open(os.environ['SDLC_CFG']) as f:
    data = json.load(f)
with open(os.environ['SCHEMA_FILE']) as f:
    schema = json.load(f)

def resolve_ref(ref, root_schema):
    if not ref.startswith('#/'):
        return None
    parts = ref[2:].split('/')
    node = root_schema
    for p in parts:
        node = node.get(p, {})
    return node

def validate(data, schema, path, errors, root):
    if '\$ref' in schema:
        resolved = resolve_ref(schema['\$ref'], root)
        if resolved is None:
            errors.append(f'{path}: unresolvable \$ref {schema[\"\$ref\"]!r}')
            return
        schema = resolved

    if 'oneOf' in schema:
        matches = 0
        for sub in schema['oneOf']:
            sub_errors = []
            validate(data, sub, path, sub_errors, root)
            if not sub_errors:
                matches += 1
        if matches != 1:
            errors.append(f'{path}: matches {matches} oneOf variants (expected exactly 1)')
        return

    if 'type' in schema:
        expected_types = schema['type'] if isinstance(schema['type'], list) else [schema['type']]
        type_map = {
            'object': dict, 'array': list, 'string': str, 'integer': int,
            'number': (int, float), 'boolean': bool, 'null': type(None),
        }
        # bool is subclass of int in Python — exclude for integer/number
        if 'integer' in expected_types or 'number' in expected_types:
            if isinstance(data, bool):
                errors.append(f'{path}: expected {expected_types}, got bool')
                return
        if not any(isinstance(data, type_map[t]) for t in expected_types if t in type_map):
            errors.append(f'{path}: expected {expected_types}, got {type(data).__name__}')
            return

    if isinstance(data, str):
        if 'minLength' in schema and len(data) < schema['minLength']:
            errors.append(f'{path}: string length {len(data)} < minLength {schema[\"minLength\"]}')
        if 'pattern' in schema:
            import re
            if not re.search(schema['pattern'], data):
                errors.append(f'{path}: value {data!r} does not match pattern {schema[\"pattern\"]!r}')
        if 'enum' in schema and data not in schema['enum']:
            errors.append(f'{path}: value {data!r} not in enum {schema[\"enum\"]}')
        if 'const' in schema and data != schema['const']:
            errors.append(f'{path}: value {data!r} != const {schema[\"const\"]!r}')

    if isinstance(data, dict):
        for req in schema.get('required', []):
            if req not in data:
                errors.append(f'{path}: missing required field {req!r}')
        props = schema.get('properties', {})
        add_props = schema.get('additionalProperties', True)
        for k, v in data.items():
            if k in props:
                validate(v, props[k], f'{path}.{k}', errors, root)
            elif add_props is False:
                errors.append(f'{path}: unknown field {k!r} (additionalProperties: false)')
            elif isinstance(add_props, dict):
                validate(v, add_props, f'{path}.{k}', errors, root)

    if isinstance(data, list):
        item_schema = schema.get('items')
        if item_schema:
            for i, item in enumerate(data):
                validate(item, item_schema, f'{path}[{i}]', errors, root)

errors = []
validate(data, schema, 'sdlc.config.json', errors, schema)
if errors:
    for e in errors:
        print(f'SCHEMA ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || return 1

  if [ -n "$config_hash" ]; then
    mkdir -p "$proof_dir"
    touch "$proof_dir/.config-validated-$config_hash"
  fi
  return 0
}
export -f validate_rq_config
# Caller (load-config.sh) is responsible for invoking validate_rq_config and
# deciding how to handle failure — a sourced file cannot reliably exit or
# return on behalf of its parent.
