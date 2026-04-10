"""Pure log analysis functions — no I/O, no subprocess calls."""
from __future__ import annotations

import re
from collections.abc import Sequence

FAILURE_CONCLUSIONS = {
    "failure", "cancelled", "timed_out", "action_required",
}
FAILURE_STATES = {
    "failure", "error", "cancelled", "timed_out", "action_required",
}
FAILURE_BUCKETS = {"fail"}

FAILURE_MARKERS = (
    "error", "fail", "failed", "traceback", "exception",
    "assert", "panic", "fatal", "timeout", "segmentation fault",
)
PENDING_LOG_MARKERS = (
    "still in progress",
    "log will be available when it is complete",
)

PRIMARY_CHECK_FIELDS = [
    "name", "state", "conclusion",
    "detailsUrl", "startedAt", "completedAt",
]
FALLBACK_CHECK_FIELDS = [
    "name", "state", "bucket", "link",
    "startedAt", "completedAt", "workflow",
]

COMPILE_PATTERN = r"([\w./]+):(\d+):"
TEST_MARKERS = ("assert", "assertionerror", "failed", "expected")


def normalize(value: object) -> str:
    """Lowercase strip, handle None."""
    if value is None:
        return ""
    return str(value).strip().lower()


def is_failing(check: dict) -> bool:
    """Check conclusion/state/bucket against failure signal sets."""
    conclusion = normalize(check.get("conclusion"))
    if conclusion in FAILURE_CONCLUSIONS:
        return True
    state = normalize(check.get("state") or check.get("status"))
    if state in FAILURE_STATES:
        return True
    bucket = normalize(check.get("bucket"))
    return bucket in FAILURE_BUCKETS


def parse_available_fields(message: str) -> list[str]:
    """Parse 'Available fields:' block from gh error output."""
    if "Available fields:" not in message:
        return []
    fields: list[str] = []
    collecting = False
    for line in message.splitlines():
        if "Available fields:" in line:
            collecting = True
            continue
        if not collecting:
            continue
        field = line.strip()
        if field:
            fields.append(field)
    return fields


def select_fallback_fields(error_message: str) -> list[str]:
    """Intersect parsed fields with FALLBACK_CHECK_FIELDS."""
    available = parse_available_fields(error_message)
    allowed = set(FALLBACK_CHECK_FIELDS)
    return [f for f in available if f in allowed]


def is_log_pending(message: str) -> bool:
    """Check for pending log markers (case-insensitive)."""
    lowered = message.lower()
    return any(marker in lowered for marker in PENDING_LOG_MARKERS)


def is_zip_payload(payload: bytes) -> bool:
    """Check for PK zip header."""
    return payload.startswith(b"PK")


def find_failure_index(lines: Sequence[str]) -> int | None:
    """Scan backwards for failure markers."""
    for idx in range(len(lines) - 1, -1, -1):
        lowered = lines[idx].lower()
        if any(marker in lowered for marker in FAILURE_MARKERS):
            return idx
    return None


def extract_failure_snippet(
    log_text: str,
    max_lines: int = 160,
    context: int = 30,
) -> str:
    """Extract around failure marker or tail."""
    lines = log_text.splitlines()
    if not lines:
        return ""
    marker_index = find_failure_index(lines)
    if marker_index is None:
        return "\n".join(lines[-max_lines:])
    start = max(0, marker_index - context)
    end = min(len(lines), marker_index + context)
    window = lines[start:end]
    if len(window) > max_lines:
        window = window[-max_lines:]
    return "\n".join(window)


def classify_tier(snippet: str) -> str:
    """Classify failure as compile, test, or infra."""
    lowered = snippet.lower()
    has_compile = bool(re.search(COMPILE_PATTERN, snippet))
    has_test = any(marker in lowered for marker in TEST_MARKERS)
    if has_test:
        return "test"
    if has_compile:
        return "compile"
    return "infra"


def extract_tier_context(snippet: str, tier: str) -> dict:
    """Extract tier-appropriate fields from snippet."""
    if tier == "compile":
        return _extract_compile_context(snippet)
    if tier == "test":
        return _extract_test_context(snippet)
    return _extract_infra_context(snippet)


def _extract_compile_context(snippet: str) -> dict:
    """Extract file, line, and message from compile error."""
    match = re.search(COMPILE_PATTERN, snippet)
    if not match:
        return {"file": "", "line": "", "message": ""}
    file_path = match.group(1)
    line_num = match.group(2)
    rest = snippet[match.end():].split("\n", 1)[0].strip()
    return {"file": file_path, "line": line_num, "message": rest}


def _extract_test_context(snippet: str) -> dict:
    """Extract assertion line and diff snippet from test failure."""
    lines = snippet.splitlines()
    assertion = ""
    diff_lines: list[str] = []
    for line in lines:
        lowered = line.lower()
        if "assert" in lowered and not assertion:
            assertion = line.strip()
        if any(kw in lowered for kw in ("expected", "got", "assert")):
            diff_lines.append(line.strip())
    return {"assertion": assertion, "diff_snippet": diff_lines}


def _extract_infra_context(snippet: str) -> dict:
    """Extract last 10 lines as tail."""
    lines = snippet.splitlines()
    return {"tail_lines": lines[-10:]}
