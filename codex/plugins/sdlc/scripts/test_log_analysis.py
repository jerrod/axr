"""Tests for log_analysis module — pure functions, no mocking."""
from log_analysis import (
    classify_tier,
    extract_failure_snippet,
    extract_tier_context,
    find_failure_index,
    is_failing,
    is_log_pending,
    is_zip_payload,
    normalize,
    parse_available_fields,
    select_fallback_fields,
)


class TestNormalize:
    def test_lowercases_and_strips(self):
        assert normalize("  FAILURE  ") == "failure"

    def test_none_returns_empty(self):
        assert normalize(None) == ""

    def test_integer_converted(self):
        assert normalize(42) == "42"

    def test_empty_string(self):
        assert normalize("") == ""


class TestIsFailingCheck:
    def test_failure_conclusion(self):
        assert is_failing({"conclusion": "failure"}) is True

    def test_cancelled_conclusion(self):
        assert is_failing({"conclusion": "cancelled"}) is True

    def test_timed_out_conclusion(self):
        assert is_failing({"conclusion": "timed_out"}) is True

    def test_action_required_conclusion(self):
        assert is_failing({"conclusion": "action_required"}) is True

    def test_success_conclusion(self):
        assert is_failing({"conclusion": "success"}) is False

    def test_error_state(self):
        assert is_failing({"state": "error"}) is True

    def test_failure_state(self):
        assert is_failing({"state": "failure"}) is True

    def test_fail_bucket(self):
        assert is_failing({"bucket": "fail"}) is True

    def test_pass_bucket(self):
        assert is_failing({"bucket": "pass"}) is False

    def test_case_insensitive_conclusion(self):
        assert is_failing({"conclusion": "FAILURE"}) is True

    def test_case_insensitive_state(self):
        assert is_failing({"state": "ERROR"}) is True

    def test_empty_check(self):
        assert is_failing({}) is False

    def test_none_conclusion(self):
        assert is_failing({"conclusion": None}) is False

    def test_status_fallback_for_state(self):
        assert is_failing({"status": "error"}) is True


class TestParseAvailableFields:
    def test_parses_field_list(self):
        message = (
            "some error\n"
            "Available fields:\n"
            "  name\n"
            "  state\n"
            "  conclusion\n"
        )
        result = parse_available_fields(message)
        assert result == ["name", "state", "conclusion"]

    def test_no_marker_returns_empty(self):
        assert parse_available_fields("just an error message") == []

    def test_empty_message(self):
        assert parse_available_fields("") == []

    def test_skips_blank_lines(self):
        message = "Available fields:\n  name\n\n  state\n"
        result = parse_available_fields(message)
        assert result == ["name", "state"]


class TestSelectFallbackFields:
    def test_selects_known_fields(self):
        message = (
            "Available fields:\n"
            "  name\n"
            "  state\n"
            "  bucket\n"
            "  link\n"
            "  unknownField\n"
        )
        result = select_fallback_fields(message)
        assert set(result) == {"name", "state", "bucket", "link"}

    def test_no_available_returns_empty(self):
        assert select_fallback_fields("some error") == []

    def test_preserves_order(self):
        message = (
            "Available fields:\n"
            "  workflow\n"
            "  name\n"
            "  completedAt\n"
        )
        result = select_fallback_fields(message)
        for field in result:
            assert field in [
                "name", "state", "bucket", "link",
                "startedAt", "completedAt", "workflow",
            ]


class TestIsLogPending:
    def test_still_in_progress(self):
        assert is_log_pending("Run still in progress") is True

    def test_will_be_available(self):
        msg = "log will be available when it is complete"
        assert is_log_pending(msg) is True

    def test_normal_error(self):
        assert is_log_pending("permission denied") is False

    def test_case_insensitive(self):
        assert is_log_pending("STILL IN PROGRESS") is True


class TestIsZipPayload:
    def test_pk_header(self):
        assert is_zip_payload(b"PK\x03\x04rest") is True

    def test_non_zip(self):
        assert is_zip_payload(b"plain text log") is False

    def test_empty(self):
        assert is_zip_payload(b"") is False


class TestFindFailureIndex:
    def test_finds_last_marker(self):
        lines = ["ok", "info", "ERROR: something broke", "cleanup"]
        assert find_failure_index(lines) == 2

    def test_no_marker(self):
        lines = ["ok", "info", "done"]
        assert find_failure_index(lines) is None

    def test_case_insensitive(self):
        lines = ["ok", "FATAL crash"]
        assert find_failure_index(lines) == 1

    def test_prefers_last_occurrence(self):
        lines = ["error: first", "ok", "error: second"]
        assert find_failure_index(lines) == 2

    def test_empty_lines(self):
        assert find_failure_index([]) is None

    def test_segmentation_fault(self):
        lines = ["running", "segmentation fault", "done"]
        assert find_failure_index(lines) == 1


class TestExtractFailureSnippet:
    def test_finds_error_marker(self):
        lines = ["line1", "line2", "ERROR: boom", "line4"]
        log = "\n".join(lines)
        snippet = extract_failure_snippet(log)
        assert "ERROR: boom" in snippet

    def test_tail_when_no_marker(self):
        lines = ["line" + str(i) for i in range(200)]
        log = "\n".join(lines)
        snippet = extract_failure_snippet(log, max_lines=10)
        result_lines = snippet.splitlines()
        assert len(result_lines) == 10
        assert result_lines[-1] == "line199"

    def test_empty_log(self):
        assert extract_failure_snippet("") == ""

    def test_respects_max_lines(self):
        lines = ["ok"] * 100 + ["ERROR: fail"] + ["ok"] * 100
        log = "\n".join(lines)
        snippet = extract_failure_snippet(log, max_lines=50)
        result_lines = snippet.splitlines()
        assert len(result_lines) <= 50

    def test_context_window(self):
        lines = ["before"] * 50 + ["ERROR: fail"] + ["after"] * 50
        log = "\n".join(lines)
        snippet = extract_failure_snippet(log, max_lines=160, context=10)
        result_lines = snippet.splitlines()
        assert len(result_lines) == 20
        assert "ERROR: fail" in snippet


class TestClassifyTier:
    def test_compile_error_with_file_line(self):
        snippet = "src/main.rs:42: error: type mismatch"
        assert classify_tier(snippet) == "compile"

    def test_test_failure_with_assertion(self):
        snippet = "AssertionError: expected 5 got 3"
        assert classify_tier(snippet) == "test"

    def test_test_failure_with_expected_got(self):
        snippet = "expected True but got False\nFAILED tests"
        assert classify_tier(snippet) == "test"

    def test_infra_default(self):
        snippet = "connection refused\nnetwork timeout"
        assert classify_tier(snippet) == "infra"

    def test_mixed_prefers_test_over_compile(self):
        snippet = "src/test.py:10: AssertionError: expected 1 got 2"
        assert classify_tier(snippet) == "test"

    def test_case_insensitive_test_markers(self):
        snippet = "FAILED test_something"
        assert classify_tier(snippet) == "test"


class TestExtractTierContext:
    def test_compile_extracts_file_line_message(self):
        snippet = "src/main.rs:42: error: type mismatch"
        result = extract_tier_context(snippet, "compile")
        assert result["file"] == "src/main.rs"
        assert result["line"] == "42"
        assert "type mismatch" in result["message"]

    def test_test_extracts_assertion_and_diff(self):
        snippet = (
            "running test\n"
            "assert x == 5\n"
            "expected 5\n"
            "got 3\n"
            "done"
        )
        result = extract_tier_context(snippet, "test")
        assert "assert" in result["assertion"].lower()
        diff = result["diff_snippet"]
        assert any("expected" in line for line in diff)

    def test_infra_extracts_tail(self):
        lines = ["line" + str(i) for i in range(20)]
        snippet = "\n".join(lines)
        result = extract_tier_context(snippet, "infra")
        assert len(result["tail_lines"]) == 10
        assert result["tail_lines"][-1] == "line19"

    def test_infra_short_snippet(self):
        snippet = "error\ntimeout"
        result = extract_tier_context(snippet, "infra")
        assert len(result["tail_lines"]) == 2

    def test_compile_no_match(self):
        result = extract_tier_context("no compile error", "compile")
        assert result["file"] == ""
        assert result["line"] == ""

    def test_test_no_assertion(self):
        result = extract_tier_context("no test markers here", "test")
        assert result["assertion"] == ""
        assert result["diff_snippet"] == []
