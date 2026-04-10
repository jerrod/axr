#!/usr/bin/env bash
# Gate: Lint — format + lint + typecheck, zero warnings policy
# Produces: .quality/proof/lint.json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/sdlc/scripts/load-config.sh
source "$SCRIPT_DIR/load-config.sh"

# Clear tracking file from prior runs (defense in depth — run-gates.sh also clears at phase start)
mkdir -p "${PROOF_DIR:-.quality/proof}" && : >"${PROOF_DIR:-.quality/proof}/allow-tracking-lint.jsonl"

# Trap: always produce proof JSON, even on unexpected crash
_write_crash_proof() {
  local exit_code=$?
  cat >"$PROOF_DIR/lint.json" <<CRASHJSON
{
  "gate": "lint",
  "sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "status": "fail",
  "error": "script crashed with exit code $exit_code",
  "failures": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
CRASHJSON
  cat "$PROOF_DIR/lint.json"
  echo "GATE FAILED: script crashed (exit $exit_code) — run with bash -x to debug" >&2
}
trap _write_crash_proof ERR

RESULTS=()
GATE_STATUS="pass"
CHECKS_RAN=0

run_check() {
  local name="$1"
  local cmd="$2"
  local output=""
  local exit_code=0
  CHECKS_RAN=$((CHECKS_RAN + 1))

  output=$(eval "$cmd" 2>&1) || exit_code=$?

  # Only record failures — passing checks are noise
  if [ $exit_code -ne 0 ]; then
    local escaped_output
    escaped_output=$(echo "$output" | tail -50 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    GATE_STATUS="fail"
    RESULTS+=("{\"check\":\"$name\",\"exit_code\":$exit_code,\"output\":$escaped_output}")
  fi
}

# run_check_files <name> <cmd> <file1> [file2 ...]
# Same as run_check but invokes <cmd> directly with a bash array of file
# arguments, avoiding `eval` and the single-quote injection risk in
# filenames like `it's.css`.
run_check_files() {
  local name="$1"
  local cmd="$2"
  shift 2
  local output=""
  local exit_code=0
  CHECKS_RAN=$((CHECKS_RAN + 1))
  output=$("$cmd" "$@" 2>&1) || exit_code=$?
  if [ $exit_code -ne 0 ]; then
    local escaped_output
    escaped_output=$(echo "$output" | tail -50 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    GATE_STATUS="fail"
    RESULTS+=("{\"check\":\"$name\",\"exit_code\":$exit_code,\"output\":$escaped_output}")
  fi
}

# ─── Prefer in-repo bin/ scripts over running tools directly ────
# bin/ scripts handle credentials, service startup, and cache management.
BIN_HANDLED_LINT=0
BIN_HANDLED_FORMAT=0
BIN_HANDLED_TYPECHECK=0

if [ -x "bin/lint" ]; then
  run_check "bin-lint" "bin/lint"
  BIN_HANDLED_LINT=1
fi
if [ -x "bin/format" ]; then
  # Apply formatting fixes first, then check for remaining issues
  bin/format 2>/dev/null || true
  run_check "bin-format" "bin/format --check 2>&1"
  BIN_HANDLED_FORMAT=1
fi
if [ -x "bin/typecheck" ]; then
  run_check "bin-typecheck" "bin/typecheck"
  BIN_HANDLED_TYPECHECK=1
fi

# Fall back to tool-specific detection only for what bin/ didn't cover
if [ -f "package.json" ]; then
  if [ $BIN_HANDLED_LINT -eq 0 ] && grep -q '"lint"' package.json 2>/dev/null; then
    run_check "lint" "npm run lint -- --max-warnings=0"
  fi
  if [ $BIN_HANDLED_FORMAT -eq 0 ]; then
    # Apply formatting fixes first, then verify
    if grep -q '"format"' package.json 2>/dev/null; then
      npm run format 2>/dev/null || true
    elif grep -q '"prettier"' package.json 2>/dev/null; then
      npx prettier --write . 2>/dev/null || true
    fi
    if grep -q '"format:check"' package.json 2>/dev/null; then
      run_check "format" "npm run format:check"
    elif grep -q '"prettier"' package.json 2>/dev/null; then
      run_check "format" "npx prettier --check ."
    fi
  fi
  if [ $BIN_HANDLED_TYPECHECK -eq 0 ]; then
    if grep -q '"typecheck"' package.json 2>/dev/null; then
      run_check "typecheck" "npm run typecheck"
    elif grep -q '"typescript"' package.json 2>/dev/null || [ -f "tsconfig.json" ]; then
      run_check "typecheck" "npx tsc --noEmit"
    fi
  fi
  if [ $BIN_HANDLED_LINT -eq 0 ] && grep -q '"biome"' package.json 2>/dev/null; then
    run_check "biome" "npx biome check ."
  fi
fi

if [ $BIN_HANDLED_LINT -eq 0 ]; then
  if [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
    if command -v ruff &>/dev/null; then
      ruff check --fix . 2>/dev/null || true
      ruff format . 2>/dev/null || true
      run_check "ruff-lint" "ruff check ."
      run_check "ruff-format" "ruff format --check ."
    elif command -v flake8 &>/dev/null; then
      run_check "flake8" "flake8 ."
    fi
    if [ $BIN_HANDLED_TYPECHECK -eq 0 ] && command -v mypy &>/dev/null; then
      run_check "mypy" "mypy ."
    fi
  fi

  if [ -f "Cargo.toml" ]; then
    cargo fmt 2>/dev/null || true
    run_check "clippy" "cargo clippy -- -D warnings"
    run_check "rustfmt" "cargo fmt -- --check"
  fi

  if [ -f "go.mod" ]; then
    gofmt -w . 2>/dev/null || true
    run_check "go-vet" "go vet ./..."
    run_check "go-fmt" "test -z \"\$(gofmt -l . 2>/dev/null)\""
    if command -v golangci-lint &>/dev/null; then
      run_check "golangci-lint" "golangci-lint run"
    fi
  fi

  # Ruby: prefer bundle exec rubocop, fall back to system rubocop
  if [ -f "Gemfile" ] && bundle exec rubocop --version &>/dev/null 2>&1; then
    bundle exec rubocop --autocorrect 2>/dev/null || true
    run_check "rubocop" "bundle exec rubocop --format simple"
  elif command -v rubocop &>/dev/null; then
    rubocop --autocorrect 2>/dev/null || true
    run_check "rubocop" "rubocop --format simple"
  fi

  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    if [ -f "gradlew" ]; then
      run_check "gradle-check" "./gradlew check 2>&1"
    fi
    if command -v ktlint &>/dev/null; then
      run_check "ktlint" "ktlint"
    fi
    if command -v detekt &>/dev/null; then
      run_check "detekt" "detekt"
    fi
  elif [ -f "pom.xml" ]; then
    if command -v checkstyle &>/dev/null; then
      run_check "checkstyle" "mvn checkstyle:check"
    fi
  fi

  # HTML/CSS linters
  if command -v stylelint &>/dev/null; then
    CHANGED_CSS=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.css' '*.scss' '*.less' 2>/dev/null || true)
    if [ -n "$CHANGED_CSS" ]; then
      # Build a bash array so filenames with single quotes or shell
      # metacharacters cannot inject commands through eval.
      CSS_FILES=()
      while IFS= read -r _f; do [ -n "$_f" ] && CSS_FILES+=("$_f"); done <<<"$CHANGED_CSS"
      run_check_files "stylelint" "stylelint" "${CSS_FILES[@]}"
    fi
  fi
  if command -v htmlhint &>/dev/null; then
    CHANGED_HTML=$(git diff --name-only --diff-filter=ACMR "$SDLC_DEFAULT_BRANCH"...HEAD -- '*.html' 2>/dev/null || true)
    if [ -n "$CHANGED_HTML" ]; then
      HTML_FILES=()
      while IFS= read -r _f; do [ -n "$_f" ] && HTML_FILES+=("$_f"); done <<<"$CHANGED_HTML"
      run_check_files "htmlhint" "htmlhint" "${HTML_FILES[@]}"
    fi
  fi
fi

# ─── Monorepo: discover subdirectory project roots with changed files ─────
# If bin/ scripts handled everything, skip subdirectory discovery (bin/ should cover it)
if [ $BIN_HANDLED_LINT -eq 0 ] || [ $BIN_HANDLED_TYPECHECK -eq 0 ]; then
  # shellcheck source=plugins/sdlc/scripts/find-project-roots.sh
  source "$SCRIPT_DIR/find-project-roots.sh"
  discover_subproject_roots "$SDLC_DEFAULT_BRANCH"

  # Run lint/typecheck in each discovered subdirectory (guarded for set -u)
  for sub_root in "${DISCOVERED_ROOTS[@]:-}"; do
    [ -n "$sub_root" ] || continue
    sub_name=$(basename "$sub_root")
    pushd "$sub_root" >/dev/null 2>&1 || continue

    if [ $BIN_HANDLED_TYPECHECK -eq 0 ]; then
      if [ -f "tsconfig.json" ]; then
        run_check "typecheck:$sub_name" "cd '$sub_root' && npx tsc --noEmit 2>&1"
      fi
    fi

    if [ $BIN_HANDLED_LINT -eq 0 ]; then
      if [ -f "package.json" ]; then
        if grep -q '"lint"' package.json 2>/dev/null; then
          run_check "lint:$sub_name" "cd '$sub_root' && npm run lint -- --max-warnings=0 2>&1"
        fi
        if grep -q '"biome"' package.json 2>/dev/null; then
          run_check "biome:$sub_name" "cd '$sub_root' && npx biome check . 2>&1"
        fi
      fi
      if [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
        if command -v ruff &>/dev/null; then
          ruff check --fix . 2>/dev/null || true
          ruff format . 2>/dev/null || true
          run_check "ruff-lint:$sub_name" "cd '$sub_root' && ruff check . 2>&1"
        fi
      fi
      if [ -f "Gemfile" ] && bundle exec rubocop --version &>/dev/null 2>&1; then
        bundle exec rubocop --autocorrect 2>/dev/null || true
        run_check "rubocop:$sub_name" "cd '$sub_root' && bundle exec rubocop --format simple 2>&1"
      elif ls ./*.rb &>/dev/null 2>&1 && command -v rubocop &>/dev/null; then
        rubocop --autocorrect 2>/dev/null || true
        run_check "rubocop:$sub_name" "cd '$sub_root' && rubocop --format simple 2>&1"
      fi
    fi

    popd >/dev/null 2>&1 || true
  done
fi

# Check for lint suppressions in changed files, respecting allow-list
FILTERED_SUPPRESSIONS=""
CURRENT_FILE=""
while IFS= read -r line; do
  if [[ "$line" =~ ^\+\+\+\ b/(.*) ]]; then
    CURRENT_FILE="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^\+.*(@Suppress\(|@SuppressWarnings\(|eslint-disable|@ts-ignore|@ts-expect-error|@ts-nocheck|noqa|nolint|\#nosec|rubocop:disable|NOLINT) ]]; then
    if ! is_allowed "lint" "file=$CURRENT_FILE"; then
      FILTERED_SUPPRESSIONS+="$line"$'\n'
    fi
  fi
done < <(git diff "$SDLC_DEFAULT_BRANCH"...HEAD 2>/dev/null || true)

if [ -n "$FILTERED_SUPPRESSIONS" ]; then
  SUPPRESSION_ESCAPED=$(echo "$FILTERED_SUPPRESSIONS" | head -20 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  GATE_STATUS="fail"
  RESULTS+=("{\"check\":\"lint-suppressions\",\"output\":$SUPPRESSION_ESCAPED}")
fi

# Clear crash trap — we made it past analysis, write proof normally
trap - ERR

# If no checks ran at all, nothing was verified — that's a failure
if [ $CHECKS_RAN -eq 0 ]; then
  GATE_STATUS="fail"
  RESULTS+=("{\"check\":\"none\",\"output\":\"\\\"FATAL: No linters, formatters, or typecheckers detected. Set up bin/lint, bin/format, bin/typecheck or install detectable tooling.\\\"\"}")
fi

RESULTS_JSON=""
if [ ${#RESULTS[@]} -gt 0 ]; then
  RESULTS_JSON=$(printf '%s,' "${RESULTS[@]}" | sed 's/,$//')
fi

cat >"$PROOF_DIR/lint.json" <<ENDJSON
{
  "gate": "lint",
  "sha": "$(git rev-parse HEAD)",
  "status": "$GATE_STATUS",
  "error": null,
  "failures": [${RESULTS_JSON}],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

cat "$PROOF_DIR/lint.json"

report_unused_allow_entries lint

if [ "$GATE_STATUS" = "fail" ]; then
  print_allow_hint lint
  echo "GATE FAILED: Lint/format/typecheck issues found" >&2
  exit 1
fi
