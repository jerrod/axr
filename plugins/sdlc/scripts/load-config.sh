#!/usr/bin/env bash
# Shared config loader for sdlc quality gates.
# Sourced by gate scripts: source "$SCRIPT_DIR/load-config.sh"
# Reads sdlc.config.json, merges with env vars and baked-in defaults.
# Exports: SDLC_MAX_FILE_LINES, SDLC_MAX_FUNCTION_LINES, SDLC_MAX_COMPLEXITY, SDLC_MIN_COVERAGE
# Functions: get_threshold <file> <key>, resolve_all_thresholds <list_file> <key>, is_allowed <gate> <field=value ...>

PROOF_DIR="${PROOF_DIR:-.quality/proof}"
mkdir -p "$PROOF_DIR"

SDLC_DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

# Find config file at git root (respect pre-set SDLC_CONFIG_FILE from env)
_rq_git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
if [ -z "${SDLC_CONFIG_FILE:-}" ]; then
  SDLC_CONFIG_FILE=""
  if [ -f "$_rq_git_root/sdlc.config.json" ]; then
    SDLC_CONFIG_FILE="$_rq_git_root/sdlc.config.json"
  fi
fi
# Export immediately — the python3 subprocess below reads it via os.environ.
export SDLC_CONFIG_FILE

# Load config and baked-in defaults via a single python3 call.
# Outputs shell variable assignments that get eval'd.
_rq_config_vars=$(python3 -c "
import json, os, shlex

# Baked-in defaults
DEFAULTS = {
    'max_file_lines': 300,
    'max_function_lines': 50,
    'max_complexity': 8,
    'min_coverage': 95,
}

EXTENSION_DEFAULTS = {
    'md':   {'max_file_lines': None},
    'mdx':  {'max_file_lines': None},
    'css':  {'max_function_lines': None},
    'scss': {'max_function_lines': None},
    'less': {'max_function_lines': None},
    'html': {'max_function_lines': None},
    'sql':  {'max_function_lines': None},
    'json': {'max_file_lines': None},
    'yaml': {'max_file_lines': None},
    'yml':  {'max_file_lines': None},
    'toml': {'max_file_lines': None},
    'xml':  {'max_file_lines': None},
    'svg':  {'max_file_lines': None},
}

# Path-based overrides — checked before extension defaults.
# Keys are glob patterns matched against the full path (using fnmatch).
# Priority: user sdlc.config.json > path overrides > extension defaults > global defaults.
PATH_OVERRIDES = {
}

config_file = os.environ.get('SDLC_CONFIG_FILE', '')
config = {}
if config_file and os.path.isfile(config_file):
    with open(config_file) as f:
        config = json.load(f)

thresholds = config.get('thresholds', {})
extensions = config.get('extensions', {})

# Merge: config > env var > baked-in default
def resolve(key, env_var):
    if key in thresholds:
        return thresholds[key]
    env_val = os.environ.get(env_var)
    if env_val is not None:
        return int(env_val)
    return DEFAULTS[key]

vals = {
    'max_file_lines': resolve('max_file_lines', 'MAX_LINES'),
    'max_function_lines': resolve('max_function_lines', 'MAX_FUNC_LINES'),
    'max_complexity': resolve('max_complexity', 'MAX_COMPLEXITY'),
    'min_coverage': resolve('min_coverage', 'MIN_COVERAGE'),
}

print(f'SDLC_MAX_FILE_LINES={vals[\"max_file_lines\"]}')
print(f'SDLC_MAX_FUNCTION_LINES={vals[\"max_function_lines\"]}')
print(f'SDLC_MAX_COMPLEXITY={vals[\"max_complexity\"]}')
print(f'SDLC_MIN_COVERAGE={vals[\"min_coverage\"]}')

# Serialize merged extension overrides for the get_threshold function
merged_ext = dict(EXTENSION_DEFAULTS)
for ext, overrides in extensions.items():
    if ext not in merged_ext:
        merged_ext[ext] = {}
    merged_ext[ext].update(overrides)
print(f'_RQ_EXT_CONFIG={shlex.quote(json.dumps(merged_ext))}')
print(f'_RQ_GLOBAL_CONFIG={shlex.quote(json.dumps(vals))}')

# Merge path overrides — user config paths take priority over baked-in
merged_paths = dict(PATH_OVERRIDES)
for pat, overrides in config.get('path_overrides', {}).items():
    merged_paths[pat] = overrides
print(f'_RQ_PATH_CONFIG={shlex.quote(json.dumps(merged_paths))}')

allow = config.get('allow', {})
print(f'_RQ_ALLOW_CONFIG={shlex.quote(json.dumps(allow))}')

# QA config
qa_config = config.get('qa', {})
qa_defaults = {'enabled': True, 'timeout_seconds': 30, 'max_flows': 20}
qa_merged = {**qa_defaults, **qa_config}
print(f'_RQ_QA_CONFIG={shlex.quote(json.dumps(qa_merged))}')

# Design audit config
da_config = config.get('design_audit', {})
da_defaults = {'enabled': True, 'min_grade': 'C', 'skip_categories': [], 'wcag_level': 'AA'}
da_merged = {**da_defaults, **da_config}
print(f'_RQ_DESIGN_AUDIT_CONFIG={shlex.quote(json.dumps(da_merged))}')

# Commands config
commands = config.get('commands', {})
print(f'_RQ_COMMANDS_CONFIG={shlex.quote(json.dumps(commands))}')
" 2>/dev/null) || {
  # If python3 fails, use env var fallbacks
  _rq_config_vars=""
}

if [ -n "$_rq_config_vars" ]; then
  # Strip carriage returns (CRLF platforms) and blank trailing lines before check.
  _rq_config_vars=$(echo "$_rq_config_vars" | tr -d '\r' | grep -v '^$' || true)
  # Validate every line matches VAR=<int> or VAR='single-quoted' — the only
  # two forms the Python subprocess above emits (via shlex.quote). Anchoring
  # the full line closes the defence-in-depth gap where a tampered Python
  # stdout could inject `VAR=val; cmd` past a prefix-only check.
  if echo "$_rq_config_vars" | grep -qvE "^[A-Za-z_][A-Za-z_0-9]*=([0-9]+|'.*')$"; then
    echo "WARNING: sdlc config loader produced unexpected output — using defaults" >&2
    _rq_config_vars=""
  fi
  eval "$_rq_config_vars"
else
  SDLC_MAX_FILE_LINES="${MAX_LINES:-300}"
  SDLC_MAX_FUNCTION_LINES="${MAX_FUNC_LINES:-50}"
  SDLC_MAX_COMPLEXITY="${MAX_COMPLEXITY:-8}"
  SDLC_MIN_COVERAGE="${MIN_COVERAGE:-95}"
  _RQ_EXT_CONFIG='{}'
  _RQ_GLOBAL_CONFIG='{}'
  _RQ_PATH_CONFIG='{}'
  _RQ_ALLOW_CONFIG='{}'
  read -r _RQ_QA_CONFIG <<<'{"enabled":true,"timeout_seconds":30,"max_flows":20}'
  read -r _RQ_DESIGN_AUDIT_CONFIG <<<'{"enabled":true,"min_grade":"C","skip_categories":[],"wcag_level":"AA"}'
  _RQ_COMMANDS_CONFIG='{}'
fi

# Source git helpers (get_repo_name, etc.) — lightweight, no side effects.
# shellcheck source=plugins/sdlc/scripts/git-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-helpers.sh"

# path_match lives in plugins/sdlc/scripts/path_match.py (single source of truth).
# threshold-helpers.sh consumers import it via sys.path insertion using $_RQ_SCRIPT_DIR.

# shellcheck source=plugins/sdlc/scripts/threshold-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/threshold-helpers.sh"

export SDLC_CONFIG_FILE SDLC_DEFAULT_BRANCH PROOF_DIR
export SDLC_MAX_FILE_LINES SDLC_MAX_FUNCTION_LINES SDLC_MAX_COMPLEXITY SDLC_MIN_COVERAGE
export _RQ_ALLOW_CONFIG
export _RQ_QA_CONFIG
export _RQ_DESIGN_AUDIT_CONFIG
export _RQ_COMMANDS_CONFIG

# shellcheck source=plugins/sdlc/scripts/validate-config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate-config.sh"

# Validate config on every load — an invalid config must not be silently
# accepted. Exit here (not from the sourced file) so a bad config actually
# halts the caller's script.
validate_rq_config || {
  echo "FATAL: sdlc.config.json failed schema validation — see errors above" >&2
  exit 1
}

get_qa_config() {
  local key="$1"
  echo "$_RQ_QA_CONFIG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get(sys.argv[1], ''))" "$key"
}

get_design_audit_config() {
  local key="$1"
  echo "$_RQ_DESIGN_AUDIT_CONFIG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get(sys.argv[1], ''))" "$key"
}

# Detect if project has a dev server. Returns 0 if found, 1 if not.
# Sets DEV_SERVER_TYPE to: "launch-json", "bin-dev", "package-json", or "".
detect_dev_server() {
  export DEV_SERVER_TYPE=""
  if [[ -f ".claude/launch.json" ]]; then
    DEV_SERVER_TYPE="launch-json"
    return 0
  elif [[ -x "bin/dev" ]]; then
    DEV_SERVER_TYPE="bin-dev"
    return 0
  elif [[ -f "package.json" ]]; then
    if python3 -c "
import json, sys
pkg = json.load(open('package.json'))
scripts = pkg.get('scripts', {})
sys.exit(0 if 'dev' in scripts or 'start' in scripts else 1)
" 2>/dev/null; then
      DEV_SERVER_TYPE="package-json"
      return 0
    fi
  fi
  return 1
}
