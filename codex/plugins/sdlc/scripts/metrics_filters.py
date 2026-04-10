"""Filters for metric aggregation — decide which gate events count as
real code-quality escapes vs bootstrap / infrastructure problems.

The catch_rate metric divides critic_catches by (catches + misses). A
gate failure that happened because no linter was installed, or no test
runner was detected, is not something the critic could have caught. It
is a setup problem, not a code regression. Counting it as a "miss"
makes catch_rate report a false zero on days where the only failures
were bootstrap problems.
"""


def _lint_has_no_tooling(proof):
    """gate-lint.sh emits failures[*].check == "none" when no lint/format/
    typecheck tool is present."""
    for f in proof.get("failures", []) or []:
        if isinstance(f, dict) and f.get("check") == "none":
            return True
    return False


def _tests_runner_missing(proof):
    """gate-tests.sh sets tests_ran=False when no test runner was detected."""
    return proof.get("tests_ran") is False


# Registry of gate name → predicate. Add a new entry to detect a new
# infrastructure-failure pattern without modifying is_infrastructure_failure.
_INFRA_DETECTORS = {
    "lint": _lint_has_no_tooling,
    "tests": _tests_runner_missing,
}


def is_infrastructure_failure(gate_name, proof):
    """True if a gate failure is a setup problem the critic cannot catch."""
    detector = _INFRA_DETECTORS.get(gate_name)
    return detector(proof) if detector else False
