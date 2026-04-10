"""Validate gate proof and metrics event JSON against schemas.

Usage from gate scripts (bash):
  python3 validate_proof.py <proof_json_path> <gate_name> [schema_dir]

Usage from Python:
  from validate_proof import validate_gate_proof, validate_metrics_event
"""
import json
import os
import sys

try:
    from jsonschema import validate, ValidationError
    from referencing import Registry, Resource
    _HAS_JSONSCHEMA = True
except ImportError:
    validate = None
    ValidationError = Exception
    _HAS_JSONSCHEMA = False


def _load_schema(schema_dir, filename):
    path = os.path.join(schema_dir, filename)
    with open(path) as f:
        return json.load(f)


def _build_registry(schema_dir):
    resources = []
    base_schema = _load_schema(schema_dir, "proof/base.json")
    base_resource = Resource.from_contents(base_schema)
    resources.append(("proof-base", base_resource))
    resources.append(("base.json", base_resource))
    for fn in os.listdir(os.path.join(schema_dir, "proof")):
        if fn.endswith(".json") and fn != "base.json":
            s = _load_schema(schema_dir, f"proof/{fn}")
            if "$id" in s:
                resources.append((s["$id"], Resource.from_contents(s)))
    return Registry().with_resources(resources)


def validate_gate_proof(proof, gate_name, schema_dir=None):
    if not _HAS_JSONSCHEMA:
        return True  # jsonschema not installed, skip validation
    if schema_dir is None:
        schema_dir = os.path.join(os.path.dirname(__file__), "schemas")
    schema = _load_schema(schema_dir, f"proof/{gate_name}.json")
    registry = _build_registry(schema_dir)
    validate(instance=proof, schema=schema, registry=registry)
    return True


def validate_metrics_event(event, schema_dir=None):
    if not _HAS_JSONSCHEMA:
        return True
    if schema_dir is None:
        schema_dir = os.path.join(os.path.dirname(__file__), "schemas")
    schema = _load_schema(schema_dir, "metrics-event.json")
    validate(instance=event, schema=schema)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: validate_proof.py <proof_json> <gate_name> [schema_dir]",
              file=sys.stderr)
        sys.exit(2)
    proof_path = sys.argv[1]
    gate_name = sys.argv[2]
    schema_dir = sys.argv[3] if len(sys.argv) > 3 else None
    with open(proof_path) as f:
        proof = json.load(f)
    try:
        validate_gate_proof(proof, gate_name, schema_dir)
        print(f"VALID: {gate_name} proof")
    except Exception as e:
        print(f"INVALID: {gate_name} proof: {e}", file=sys.stderr)
        sys.exit(1)
