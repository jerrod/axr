#!/usr/bin/env bash
# Tests for gate-test-quality.sh
# Runs against fixture files to verify detection of disguised mocks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# Helper: create a git repo with a test file and run the gate
run_gate_on_file() {
  local filename="$1"
  local content="$2"
  local repo_dir
  repo_dir=$(mktemp -d)

  cd "$repo_dir"
  git init -q
  git checkout -b main -q 2>/dev/null || true
  # Create an initial commit so the diff baseline exists
  echo "init" >init.txt
  git add init.txt
  git commit -q -m "init"

  # Create the test file on a feature branch
  git checkout -b feature -q
  mkdir -p "$(dirname "$filename")"
  echo "$content" >"$filename"
  git add "$filename"
  git commit -q -m "add test file"

  # Set the default branch for the gate
  export SDLC_DEFAULT_BRANCH="main"
  export PROOF_DIR="$repo_dir/.quality/proof"
  mkdir -p "$PROOF_DIR"

  local exit_code=0
  bash "$SCRIPT_DIR/gate-test-quality.sh" >/dev/null 2>&1 || exit_code=$?

  # Read the proof file
  local status
  status=$(PF="$PROOF_DIR/test-quality.json" python3 -c "import json, os; print(json.load(open(os.environ['PF']))['status'])" 2>/dev/null || echo "error")
  local violation_count
  violation_count=$(PF="$PROOF_DIR/test-quality.json" python3 -c "import json, os; print(len(json.load(open(os.environ['PF']))['violations']))" 2>/dev/null || echo "0")

  cd "$SCRIPT_DIR"
  rm -rf "$repo_dir"

  echo "$status:$violation_count:$exit_code"
}

assert_fails() {
  local test_name="$1"
  local result="$2"
  local status="${result%%:*}"
  if [ "$status" = "fail" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected fail, got $result)"
  fi
}

assert_passes() {
  local test_name="$1"
  local result="$2"
  local status="${result%%:*}"
  if [ "$status" = "pass" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name (expected pass, got $result)"
  fi
}

echo "=== gate-test-quality.sh tests ==="
echo ""

# --- JS/TS disguised mock patterns (should FAIL) ---
echo "Disguised mocks (should fail):"

result=$(run_gate_on_file "src/foo.test.ts" "
import { render } from '@testing-library/react';
vi.spyOn(useDealExportModule, 'useDealExport').mockImplementation(
  (...args) => mockUseDealExport(...args),
);
")
assert_fails "spyOn().mockImplementation()" "$result"

result=$(run_gate_on_file "src/bar.test.tsx" "
jest.spyOn(utils, 'calculateTotal').mockReturnValue(1000);
test('applies discount', () => {});
")
assert_fails "spyOn().mockReturnValue()" "$result"

result=$(run_gate_on_file "src/baz.test.ts" "
vi.spyOn(service, 'fetchData').mockResolvedValue({ data: [] });
test('loads data', () => {});
")
assert_fails "spyOn().mockResolvedValue()" "$result"

result=$(run_gate_on_file "src/qux.test.ts" "
vi.spyOn(service, 'save').mockRejectedValue(new Error('fail'));
test('handles error', () => {});
")
assert_fails "spyOn().mockRejectedValue()" "$result"

result=$(run_gate_on_file "src/mod.test.ts" "
jest.mock('./premium-calculator');
test('applies discount', () => {});
")
assert_fails "jest.mock() on relative import" "$result"

result=$(run_gate_on_file "src/vi-mock.test.ts" "
vi.mock('./premium-calculator');
test('applies discount', () => {});
")
assert_fails "vi.mock() on relative import" "$result"

echo ""

# --- Python disguised mock patterns (should FAIL) ---
echo "Python disguised mocks (should fail):"

result=$(run_gate_on_file "tests/test_parser.py" "
from unittest.mock import patch
@patch('parser.parse_address')
def test_parse(mock_parse):
    mock_parse.return_value = 'result'
")
assert_fails "@patch without wraps" "$result"

result=$(run_gate_on_file "tests/test_service.py" "
from unittest.mock import patch, Mock
with patch.object(processor, 'validate', return_value=True):
    result = processor.run(data)
")
assert_fails "patch.object with return_value (no wraps)" "$result"

result=$(run_gate_on_file "tests/test_mock.py" "
from unittest.mock import Mock
service.handler = Mock()
result = process(data)
")
assert_fails "Mock() assignment" "$result"

echo ""

# --- Legitimate patterns (should PASS) ---
echo "Legitimate patterns (should pass):"

result=$(run_gate_on_file "src/calc.test.ts" "
import { calculatePremium } from '../premium-calculator';
test('applies discount', () => {
  const result = calculatePremium({ amount: 1200, billing: 'annual' });
  expect(result).toBe(1080);
});
")
assert_passes "Real function call, no mocks" "$result"

result=$(run_gate_on_file "src/order.test.ts" "
const spy = jest.spyOn(paymentService, 'charge');
const result = processOrder(order);
expect(result.status).toBe('confirmed');
expect(spy).toHaveBeenCalledWith(order.id);
")
assert_passes "Real spy (no .mock* chain)" "$result"

result=$(run_gate_on_file "src/api.test.ts" "
jest.mock('axios');
test('fetches data', () => {});
")
assert_passes "jest.mock() on external package (not relative)" "$result"

result=$(run_gate_on_file "tests/test_real.py" "
from unittest.mock import patch
with patch.object(processor, 'validate', wraps=processor.validate) as spy:
    result = processor.run(data)
    spy.assert_called_once()
")
assert_passes "Python patch with wraps= (real spy)" "$result"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Passed: $PASS  Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -gt 0 ]; then
  exit 1
fi
