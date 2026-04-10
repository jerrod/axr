"""Build metrics JSON payload from gate proof files.

Called inline by collect-metrics.sh:
  python3 -c "$(cat collect_metrics_payload.py)" \
    <proof_dir> <critic_verdict> <critic_count> \
    <repo> <branch> <sha> <user> <timestamp> \
    <phase> [gate_name] [metrics_data_dir] [user_email]
"""

import json
import glob
import os
import re
import sys
from datetime import datetime

from metrics_filters import is_infrastructure_failure
from payload_context import PayloadContext

# Files that aren't gate proofs
SKIP_NAMES = {"critic", "metrics", "PROOF", ".init"}

# Proof keys that are always scalar — copy directly
SCALAR_KEYS = {
    "files_checked",
    "scanned_files",
    "coverage_tool",
    "test_runner",
    "fingerprint",
    "message",
    "overall_grade",
    "flows_tested",
    "flows_passed",
    "flows_failed",
}

# Proof keys whose values are lists — store their length
LIST_COUNT_KEYS = {
    "violations",
    "failures",
    "test_failures",
    "missing_tests",
    "below_threshold",
    "failed_subprojects",
    "issues",
    "findings",
    "recordings",
    "screenshots",
}

# Proof keys whose values are dicts — copy the whole dict
DICT_KEYS = {"summary", "categories"}


def resolve_critic(proof_dir, verdict_arg, count_arg):
    """Resolve critic verdict and findings from args or proof file."""
    if verdict_arg:
        return verdict_arg, count_arg, []
    cp = os.path.join(proof_dir, "critic.json")
    if os.path.isfile(cp):
        with open(cp) as f:
            cd = json.load(f)
        findings = cd.get("findings", [])
        return cd.get("verdict", "unknown"), len(findings), findings
    return "unknown", 0, []


def normalize_list_value(val):
    """Return list length for lists, pass through other values."""
    return len(val) if isinstance(val, list) else val


def _copy_matching_keys(proof, keys, gate, transform=None):
    """Copy keys from proof into gate, applying optional transform."""
    for key in keys:
        if key in proof:
            gate[key] = transform(proof[key]) if transform else proof[key]


def _copy_list_details(proof, keys, gate):
    """Copy raw list values as <key>_details for list-type keys."""
    for key in keys:
        if key in proof and isinstance(proof[key], list):
            gate[f"{key}_details"] = proof[key]


def extract_gate_details(proof):
    """Extract per-gate metrics from a single proof JSON."""
    gate = {"status": proof.get("status", "unknown")}
    if "timestamp" in proof:
        gate["gate_timestamp"] = proof["timestamp"]
    _copy_matching_keys(proof, SCALAR_KEYS, gate)
    _copy_matching_keys(proof, LIST_COUNT_KEYS, gate, normalize_list_value)
    _copy_list_details(proof, LIST_COUNT_KEYS, gate)
    _copy_matching_keys(proof, DICT_KEYS, gate)
    return gate


TIMESTAMP_FORMATS = ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S")


def _parse_timestamp(ts):
    """Parse a timestamp string using known formats. Returns None on failure."""
    for fmt in TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(ts, fmt)
        except ValueError:
            continue
    return None


_STALE_THRESHOLD_S = 600  # 10 minutes — older timestamps are stale proofs


def compute_per_gate_duration(gates):
    """Compute duration_ms per gate from adjacent timestamps.

    Gates are sorted by timestamp.  Each gate's duration is the delta
    between its timestamp and the previous gate's timestamp.  The first
    gate in the current run gets zero.

    Stale proof files (timestamps >10 min before the newest gate) are
    excluded so they don't pollute the timing of the current run.
    """
    timed = []
    for name, data in gates.items():
        ts = _parse_timestamp(data.get("gate_timestamp", ""))
        if ts is not None:
            timed.append((ts, name))
    if not timed:
        return
    timed.sort()
    newest = timed[-1][0]
    # Filter out stale proof files
    timed = [
        (ts, name) for ts, name in timed
        if (newest - ts).total_seconds() <= _STALE_THRESHOLD_S
    ]
    for i, (ts, name) in enumerate(timed):
        if i == 0:
            gates[name]["duration_ms"] = 0
        else:
            delta_ms = (ts - timed[i - 1][0]).total_seconds() * 1000
            gates[name]["duration_ms"] = round(delta_ms)


def compute_duration(gates):
    """Compute duration in seconds from gate timestamps."""
    raw = [g.get("gate_timestamp", "") for g in gates.values()]
    parsed = [_parse_timestamp(ts) for ts in raw if ts]
    parsed = [p for p in parsed if p is not None]
    if len(parsed) < 2:
        return None
    return (max(parsed) - min(parsed)).total_seconds()


def count_run_number(data_dir, sha):
    """Count existing summary metric files for this SHA to determine run number.

    Only counts summary files (sha-timestamp.json), not per-gate files
    (sha-gatename-timestamp.json) to avoid inflating the run number.
    """
    if not data_dir or not os.path.isdir(data_dir):
        return 1
    summary_pattern = re.compile(
        rf"^{re.escape(sha)}-\d{{14}}\.json$"
    )
    existing = [
        f for f in os.listdir(data_dir)
        if summary_pattern.match(f)
    ]
    return len(existing) + 1


def collect_gates(proof_dir, critic_verdict):
    """Read all proof files and build the gates dict."""
    gates = {}
    is_first_pass = True
    failures_after_critic = 0
    missed = []
    for fp in sorted(glob.glob(os.path.join(proof_dir, "*.json"))):
        name = os.path.splitext(os.path.basename(fp))[0]
        if name in SKIP_NAMES:
            continue
        try:
            with open(fp) as f:
                proof = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        gate = extract_gate_details(proof)
        gates[name] = gate
        if gate["status"] == "fail":
            is_first_pass = False
            # Infra failures (no tooling, no test runner) cannot be caught
            # by the critic — excluded from catch_rate denominator.
            if (
                critic_verdict == "approved"
                and not is_infrastructure_failure(name, proof)
            ):
                failures_after_critic += 1
                missed.append(name)
    # No gates found means proof files are missing — not a pass
    if not gates:
        is_first_pass = False
    return gates, is_first_pass, failures_after_critic, missed


def collect_single_gate(proof_dir, gate_name):
    """Read a single gate's proof file and return its details."""
    candidates = [
        os.path.join(proof_dir, f"{gate_name}.json"),
        os.path.join(proof_dir, f"{gate_name.replace('-', '_')}.json"),
    ]
    for fp in candidates:
        if os.path.isfile(fp):
            with open(fp) as f:
                proof = json.load(f)
            return {gate_name: extract_gate_details(proof)}
    return {}


def build_payload(ctx):
    """Assemble the full metrics payload from an immutable PayloadContext."""
    critic_verdict, critic_count, critic_findings = resolve_critic(
        ctx.proof_dir, ctx.critic_verdict_arg, ctx.critic_count_arg
    )
    if ctx.gate_name:
        gates = collect_single_gate(ctx.proof_dir, ctx.gate_name)
        if not gates:
            is_first_pass = False
        else:
            is_first_pass = all(
                g["status"] != "fail" for g in gates.values()
            )
        fail_after = 0
        missed = []
    else:
        gates, is_first_pass, fail_after, missed = collect_gates(
            ctx.proof_dir, critic_verdict
        )
    compute_per_gate_duration(gates)
    duration = compute_duration(gates)
    run_number = count_run_number(ctx.metrics_data_dir, ctx.sha)
    findings_by_rule = {}
    for f in critic_findings:
        rule = f.get("rule", "unknown")
        findings_by_rule[rule] = findings_by_rule.get(rule, 0) + 1
    return {
        "schema_version": 2,
        "repo": ctx.repo,
        "branch": ctx.branch,
        "sha": ctx.sha,
        "user": ctx.user,
        "user_email": ctx.user_email or None,
        "timestamp": ctx.timestamp,
        "phase": ctx.phase,
        "run_number": run_number,
        "gate_name": ctx.gate_name if ctx.gate_name else None,
        "critic_verdict": critic_verdict,
        "critic_findings_count": critic_count,
        "critic_findings_by_rule": findings_by_rule,
        "critic_findings": critic_findings,
        "gates_first_pass": is_first_pass,
        "gate_failures_after_critic": fail_after,
        "missed_gates": missed,
        "gates_run": list(gates.keys()),
        "gates": gates,
        "duration_seconds": duration,
    }


if __name__ == "__main__":
    print(json.dumps(build_payload(PayloadContext.from_argv(sys.argv)), indent=2))
