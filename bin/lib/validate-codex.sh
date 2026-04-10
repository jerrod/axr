#!/usr/bin/env bash
# bin/lib/validate-codex.sh — Codex platform + marketplace validators sourced
# by bin/validate. Expects the caller to provide pass/fail/section functions,
# sanitize, has_closed_frontmatter, and the ERRORS array.

# _check_codex_staleness — verify codex/plugins/<name>/ exists, has a committed
# .build-stamp, and that no source files have been committed since that stamp.
# An uncommitted stamp is treated as stale (we can't verify freshness against
# git history, so we refuse to pass) rather than silently passing.
_check_codex_staleness() {
  local plugin_name="$1" plugin_dir="$2" codex_dist="$3" codex_status="$4"
  local build_stamp="$codex_dist/.build-stamp"
  if [ ! -d "$codex_dist" ]; then
    fail "$plugin_name: claims codex $codex_status but $codex_dist/ missing — run bin/build-codex"
    return 0
  fi
  if [ ! -f "$build_stamp" ]; then
    fail "$plugin_name: $codex_dist/ missing .build-stamp — run bin/build-codex"
    return 0
  fi
  local stamp_commit
  stamp_commit=$(git log -1 --format=%H -- "$build_stamp" 2>/dev/null || echo "")
  if [ -z "$stamp_commit" ]; then
    fail "$plugin_name: $build_stamp has not been committed — run bin/build-codex and commit the result"
    return 0
  fi
  local source_changes
  source_changes=$(git log --oneline "$stamp_commit"..HEAD -- \
    "$plugin_dir/agents" \
    "$plugin_dir/skills" \
    "$plugin_dir/commands" \
    "$plugin_dir/hooks/hooks.json" \
    "$plugin_dir/.claude-plugin/plugin.json" \
    "$plugin_dir/codex-hook-overrides.json" \
    "$plugin_dir/AGENTS.md" \
    2>/dev/null | head -1)
  if [ -n "$source_changes" ]; then
    fail "$plugin_name: $codex_dist/ is stale — source files changed since last build"
  else
    pass "$plugin_name: $codex_dist/ exists and is current"
  fi
}

# _validate_codex_manifest — structural checks for .codex-plugin/plugin.json.
_validate_codex_manifest() {
  local plugin_name="$1" codex_manifest="$2"
  if [ ! -f "$codex_manifest" ]; then
    fail "$plugin_name: $codex_manifest missing — run bin/build-codex"
    return 0
  fi
  if ! jq empty "$codex_manifest" >/dev/null 2>&1; then
    fail "$plugin_name: $codex_manifest invalid JSON"
    return 0
  fi
  local field
  for field in name version description author homepage repository license keywords interface; do
    if jq -e --arg f "$field" 'has($f)' "$codex_manifest" >/dev/null 2>&1; then
      pass "$plugin_name: codex plugin.json has .$field"
    else
      fail "$plugin_name: codex plugin.json missing .$field"
    fi
  done
  local iface
  for iface in displayName shortDescription longDescription developerName category capabilities websiteURL privacyPolicyURL termsOfServiceURL defaultPrompt brandColor screenshots; do
    if jq -e --arg f "$iface" '.interface | has($f)' "$codex_manifest" >/dev/null 2>&1; then
      pass "$plugin_name: codex plugin.json .interface.$iface present"
    else
      fail "$plugin_name: codex plugin.json .interface.$iface missing"
    fi
  done
}

# _validate_codex_artifacts — TOML agents, hooks.json, generated skill frontmatter.
# Refuses symlinks for SKILL.md and TOML files so validate can't be tricked into
# reading arbitrary files outside the codex/ tree.
_validate_codex_artifacts() {
  local plugin_name="$1" codex_dist="$2"
  local toml_file
  if [ -d "$codex_dist/agents" ]; then
    for toml_file in "$codex_dist"/agents/*.toml; do
      [ -f "$toml_file" ] && [ ! -L "$toml_file" ] || continue
      if grep -q '^name[[:space:]]*=' "$toml_file" \
         && grep -q '^description[[:space:]]*=' "$toml_file"; then
        pass "$plugin_name: $toml_file has name and description"
      else
        fail "$plugin_name: $toml_file missing name or description"
      fi
    done
  fi
  if [ -f "$codex_dist/hooks/hooks.json" ]; then
    if jq empty "$codex_dist/hooks/hooks.json" >/dev/null 2>&1; then
      pass "$plugin_name: $codex_dist/hooks/hooks.json parses"
    else
      fail "$plugin_name: $codex_dist/hooks/hooks.json invalid JSON"
    fi
  fi
  if [ -d "$codex_dist/skills" ]; then
    local skill_file
    while IFS= read -r -d '' skill_file; do
      if has_closed_frontmatter "$skill_file"; then
        pass "$plugin_name: $skill_file frontmatter closed"
      else
        fail "$plugin_name: $skill_file missing or unclosed frontmatter"
      fi
    done < <(find -P "$codex_dist/skills" -type f -not -type l -name 'SKILL.md' -print0 2>/dev/null)
  fi
}

# _validate_codex_readme — hook-dependent plugins must document Codex limitations.
_validate_codex_readme() {
  local plugin_name="$1" plugin_dir="$2" codex_status="$3"
  [ "$codex_status" = "hook-dependent" ] || return 0
  local readme="$plugin_dir/README.md"
  if [ -f "$readme" ] && grep -qiE 'codex (limitations|differences)' "$readme"; then
    pass "$plugin_name: README documents Codex limitations"
  else
    fail "$plugin_name: hook-dependent tier requires 'Codex limitations' section in README"
  fi
}

# validate_codex_plugin <plugin_name> <plugin_dir>
#
# Runs every Codex-side check for a single plugin: dist tree existence,
# build-stamp staleness (via git log commit order), generated plugin.json
# structure, TOML agents, hooks.json parse, skill frontmatter, and the
# "Codex limitations" README requirement for hook-dependent plugins.
validate_codex_plugin() {
  local plugin_name="$1" plugin_dir="$2"
  local plugin_json="$plugin_dir/.claude-plugin/plugin.json"
  [ -f "$plugin_json" ] || return 0

  local codex_status
  codex_status=$(jq -r '.platforms.codex.status // "none"' "$plugin_json" 2>/dev/null)
  codex_status=$(sanitize "$codex_status")
  case "$codex_status" in
    skill-compatible|hook-dependent) : ;;
    unsupported|none) return 0 ;;
    *)
      fail "$plugin_name: unknown codex status '$codex_status' — must be skill-compatible|hook-dependent|unsupported"
      return 0
      ;;
  esac

  local codex_dist="codex/plugins/$plugin_name"
  local codex_manifest="$codex_dist/.codex-plugin/plugin.json"
  _check_codex_staleness "$plugin_name" "$plugin_dir" "$codex_dist" "$codex_status"
  _validate_codex_manifest "$plugin_name" "$codex_manifest"
  _validate_codex_artifacts "$plugin_name" "$codex_dist"
  _validate_codex_readme "$plugin_name" "$plugin_dir" "$codex_status"
}

# validate_codex_marketplace — checks for codex/.agents/plugins/marketplace.json.
validate_codex_marketplace() {
  local marketplace="codex/.agents/plugins/marketplace.json"
  if [ ! -f "$marketplace" ]; then
    fail "$marketplace missing — run bin/build-codex"
    return 0
  fi
  if ! jq empty "$marketplace" >/dev/null 2>&1; then
    fail "$marketplace invalid JSON"
    return 0
  fi
  local field
  for field in name interface plugins; do
    if jq -e --arg f "$field" 'has($f)' "$marketplace" >/dev/null 2>&1; then
      pass "codex marketplace has .$field"
    else
      fail "codex marketplace missing .$field"
    fi
  done
  if jq -e '.interface.displayName' "$marketplace" >/dev/null 2>&1; then
    pass "codex marketplace .interface.displayName present"
  else
    fail "codex marketplace .interface.displayName missing"
  fi
  if jq -e '.plugins | type == "array" and length > 0' "$marketplace" >/dev/null 2>&1; then
    pass "codex marketplace .plugins is non-empty array"
  else
    fail "codex marketplace .plugins must be a non-empty array"
  fi
  local bad
  bad=$(jq -r '[.plugins[] | select(
      (has("name")|not)
      or (has("source")|not)
      or (.source.source != "local")
      or (((.source.path // "") | startswith("./plugins/")) | not)
      or (has("policy")|not)
      or ((.policy.installation // "") == "")
      or ((.policy.authentication // "") == "")
      or (has("category")|not)
  ) | .name // "<no-name>"] | join(",")' "$marketplace")
  bad=$(sanitize "$bad")
  if [ -z "$bad" ]; then
    pass "every codex marketplace entry has name, local source, policy, category"
  else
    fail "codex marketplace entries with missing fields: $bad"
  fi
}
