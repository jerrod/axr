#!/usr/bin/env bash
# Shared: Detect test runner and command for a project directory
# Usage: source this file, then call detect_test_runner [dir]
# Sets: DETECTED_RUNNER, DETECTED_CMD
set -uo pipefail

export DETECTED_RUNNER="none"
export DETECTED_CMD=""

detect_test_runner() {
  local dir="${1:-.}"
  DETECTED_RUNNER="none"
  DETECTED_CMD=""

  local safe_dir
  safe_dir=$(printf '%q' "$dir")

  if [ -x "$dir/bin/test" ]; then
    DETECTED_RUNNER="bin-test"
    DETECTED_CMD="cd $safe_dir && bin/test 2>&1"
  elif [ -x "$dir/bin/unit-tests" ]; then
    DETECTED_RUNNER="bin-unit-tests"
    DETECTED_CMD="cd $safe_dir && bin/unit-tests 2>&1"
    # Prospective warning: if integration tests exist, coverage may fail
    if [ -x "$dir/bin/integration-tests" ]; then
      echo "WARNING: Running bin/unit-tests (bin/test not found)." >&2
      echo "  bin/integration-tests was not run." >&2
      echo "  If JaCoCo is configured on the integration tier, gate-coverage will fail." >&2
      echo "  Create bin/test to control which tiers run." >&2
    fi
  elif [ -f "$dir/package.json" ]; then
    if grep -q '"vitest"' "$dir/package.json" 2>/dev/null; then
      DETECTED_RUNNER="vitest"
      DETECTED_CMD="cd $safe_dir && npx vitest run --reporter=json 2>&1"
    elif grep -q '"jest"' "$dir/package.json" 2>/dev/null; then
      DETECTED_RUNNER="jest"
      DETECTED_CMD="cd $safe_dir && npx jest --json --forceExit 2>&1"
    elif grep -q '"mocha"' "$dir/package.json" 2>/dev/null; then
      DETECTED_RUNNER="mocha"
      DETECTED_CMD="cd $safe_dir && npx mocha --reporter json 2>&1"
    elif grep -q '"test"' "$dir/package.json" 2>/dev/null; then
      DETECTED_RUNNER="npm-test"
      DETECTED_CMD="cd $safe_dir && npm test 2>&1"
    fi
  elif [ -f "$dir/pytest.ini" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.cfg" ]; then
    DETECTED_RUNNER="pytest"
    DETECTED_CMD="cd $safe_dir && python -m pytest --tb=short -q --junitxml=.quality/proof/junit.xml 2>&1"
  elif [ -f "$dir/Cargo.toml" ]; then
    DETECTED_RUNNER="cargo"
    DETECTED_CMD="cd $safe_dir && cargo test 2>&1"
  elif [ -f "$dir/go.mod" ]; then
    DETECTED_RUNNER="go"
    DETECTED_CMD="cd $safe_dir && go test -json ./... 2>&1"
  elif [ -d "$dir/spec" ] && { [ -f "$dir/Gemfile" ] || command -v rspec &>/dev/null; }; then
    DETECTED_RUNNER="rspec"
    if [ -f "$dir/Gemfile" ] && bundle exec rspec --version &>/dev/null 2>&1; then
      DETECTED_CMD="cd $safe_dir && bundle exec rspec --format json 2>&1"
    else
      DETECTED_CMD="cd $safe_dir && rspec --format json 2>&1"
    fi
  elif [ -d "$dir/test" ] && { [ -f "$dir/Gemfile" ] || [ -f "$dir/Rakefile" ] || ls "$dir"/test/*_test.rb &>/dev/null 2>&1 || ls "$dir"/test/test_*.rb &>/dev/null 2>&1; }; then
    DETECTED_RUNNER="minitest"
    if [ -f "$dir/Gemfile" ] && bundle exec rake -T test &>/dev/null 2>&1; then
      DETECTED_CMD="cd $safe_dir && bundle exec rake test 2>&1"
    elif [ -f "$dir/Rakefile" ]; then
      DETECTED_CMD="cd $safe_dir && rake test 2>&1"
    else
      DETECTED_CMD="cd $safe_dir && ruby -Ilib:test -e 'Dir.glob(\"test/**/*_test.rb\").each{|f| require \"./#{f}\"}' 2>&1"
    fi
  elif [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then
    DETECTED_RUNNER="gradle"
    if [ -f "$dir/gradlew" ]; then
      DETECTED_CMD="cd $safe_dir && ./gradlew test 2>&1"
    else
      DETECTED_CMD="cd $safe_dir && gradle test 2>&1"
    fi
  elif [ -f "$dir/pom.xml" ]; then
    DETECTED_RUNNER="maven"
    DETECTED_CMD="cd $safe_dir && mvn test 2>&1"
  fi
}

# Parse test output into structured failures array
# Always returns a JSON array — structured when possible, raw-wrapped otherwise
# Usage: parse_failures <runner> <output> <script_dir> [junit_xml_path]
parse_failures() {
  local runner="$1"
  local output="$2"
  local script_dir="$3"
  local junit_path="${4:-}"
  local parser="$script_dir/parse_test_failures.py"
  local parsed=""

  case "$runner" in
    jest | vitest | mocha | go | rspec)
      parsed=$(echo "$output" | python3 "$parser" "$runner" 2>/dev/null) || parsed=""
      ;;
    pytest)
      [ -n "$junit_path" ] && parsed=$(python3 "$parser" pytest "$junit_path" 2>/dev/null) || parsed=""
      ;;
    gradle | maven)
      parsed=$(python3 "$parser" "$runner" 2>/dev/null) || parsed=""
      ;;
  esac

  # If structured parsing succeeded, use it
  if [ -n "$parsed" ] && [ "$parsed" != "[]" ]; then
    echo "$parsed"
    return
  fi

  # Fall back: wrap last 50 lines as a single structured entry
  local raw_tail
  raw_tail=$(printf '%s' "$output" | tail -50 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  echo "[{\"test\":\"(unparsed output)\",\"message\":$raw_tail}]"
}
