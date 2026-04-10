#!/usr/bin/env python3
"""Render Active/Stale Exceptions markdown tables for PROOF.md.

Reads allow-tracking-*.jsonl files from $PROOF_DIR and the sdlc config
file from $SDLC_CONFIG_FILE (falling back to sdlc.config.json in cwd).
Prints markdown sections to stdout.
"""
import json
import os
import glob

from allow_entry import entry_key, entry_pattern


def _collect_active(proof_dir: str) -> tuple[list[dict], dict[str, set[str]]]:
    """Read JSONL tracking files. Returns (active_records, matched_keys_per_gate).

    Entries are identified by `entry_key` (canonical JSON of all non-reason
    fields) — matches is_allowed_check.py's key generation. This distinguishes
    multi-field entries (e.g., dead-code {file, name, type}) that share the
    same `file` but differ on `name`.
    """
    active: list[dict] = []
    matched_keys_per_gate: dict[str, set[str]] = {}
    for tf in sorted(glob.glob(os.path.join(proof_dir, "allow-tracking-*.jsonl"))):
        gate = os.path.basename(tf).replace("allow-tracking-", "").replace(".jsonl", "")
        matched_keys_per_gate[gate] = set()
        seen_keys: set[str] = set()
        try:
            with open(tf) as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    key = rec.get("entry_key", "")
                    matched_keys_per_gate[gate].add(key)
                    if key and key not in seen_keys:
                        seen_keys.add(key)
                        active.append(rec)
        except OSError:
            continue
    return active, matched_keys_per_gate


def _load_config(config_file: str) -> dict:
    """Load the sdlc config file, returning {} on any error."""
    if not config_file or not os.path.isfile(config_file):
        return {}
    try:
        with open(config_file) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _stale_for_gate(
    gate: str, entries: list[dict], matched: set[str]
) -> list[dict]:
    """Return stale entries for a single gate."""
    out: list[dict] = []
    for entry in entries:
        if entry_key(entry) in matched:
            continue
        # Canonical helper covers all schema keys (file/pattern/branch/type).
        pattern = entry_pattern(entry)
        if pattern:
            out.append(
                {"gate": gate, "pattern": pattern, "reason": entry.get("reason", "")}
            )
    return out


def _find_stale(
    config_file: str, matched_keys_per_gate: dict[str, set[str]]
) -> list[dict]:
    """Return config entries that are active but matched nothing this run."""
    cfg = _load_config(config_file)
    stale: list[dict] = []
    for gate, entries in cfg.get("allow", {}).items():
        # Gates with no tracking file matched nothing — treat as empty set
        # so every allow entry is checked for staleness.
        matched = matched_keys_per_gate.get(gate, set())
        stale.extend(_stale_for_gate(gate, entries, matched))
    return stale


def _print_table(title: str, description: str, rows: list[dict]) -> None:
    """Print a markdown section with a table of exception rows."""
    if not rows:
        return
    print()
    print(f"## {title} ({len(rows)})")
    print()
    print(description)
    print()
    print("| Gate | Pattern | Reason |")
    print("|------|---------|--------|")
    for rec in rows:
        gate = str(rec.get("gate", "unknown")).replace("|", "\\|")
        pattern = str(rec.get("pattern", "")).replace("|", "\\|")
        reason = str(rec.get("reason", "")).replace("|", "\\|")
        print(f'| {gate} | `{pattern}` | {reason} |')


def _resolve_config_file() -> str:
    """Resolve config file path from env or defaults in cwd."""
    config_file = os.environ.get("SDLC_CONFIG_FILE", "")
    if config_file:
        return config_file
    for cand in ("sdlc.config.json", ".sdlc.config.json"):
        if os.path.isfile(cand):
            return cand
    return ""


def main() -> None:
    proof_dir = os.environ.get("PROOF_DIR", ".quality/proof")
    config_file = _resolve_config_file()
    active, matched = _collect_active(proof_dir)
    stale = _find_stale(config_file, matched)
    _print_table(
        "Active Exceptions",
        "These files were exempted from quality gates during this run.",
        active,
    )
    _print_table(
        "Stale Exceptions",
        "These allow-list entries were active but matched no files during this run. Review for cleanup.",
        stale,
    )


if __name__ == "__main__":
    main()
