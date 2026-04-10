#!/usr/bin/env bash
# bin/lib/build-codex-manifests.sh — Codex manifest + marketplace generators
# sourced by bin/build-codex. Depends on jq and on the transform helpers for
# `first_sentence` inputs (description strings come from plugins/*/.claude-plugin/plugin.json).

# first_sentence — return everything before the first ". " (period + space),
# truncated to 120 chars. Falls back to the full input if no period.
first_sentence() {
  local text="$1"
  if printf '%s' "$text" | grep -q '\. '; then
    text=$(printf '%s' "$text" | sed 's/\. .*/./')
  fi
  printf '%s' "$text" | awk '{ if (length($0) > 120) print substr($0,1,120); else print $0 }'
}

# _build_base_manifest — emit the base jq-constructed plugin.json (no skills/hooks).
# Takes the 8 already-derived args so the caller does all the reads and this
# function stays focused on a single jq invocation.
_build_base_manifest() {
  local plugin_name="$1" version="$2" description="$3" author_name="$4"
  local keywords_json="$5" display="$6" short="$7" prompt="$8"
  jq -n \
    --arg name "$plugin_name" \
    --arg version "$version" \
    --arg description "$description" \
    --arg author "$author_name" \
    --argjson keywords "$keywords_json" \
    --arg display "$display" \
    --arg short "$short" \
    --arg prompt "$prompt" \
    '{
      name: $name,
      version: $version,
      description: $description,
      author: { name: $author },
      homepage: "https://github.com/jerrod/agent-plugins",
      repository: "https://github.com/jerrod/agent-plugins",
      license: "MIT",
      keywords: $keywords,
      interface: {
        displayName: $display,
        shortDescription: $short,
        longDescription: $description,
        developerName: $author,
        category: "Coding",
        capabilities: ["Interactive", "Write"],
        websiteURL: "https://github.com/jerrod/agent-plugins",
        privacyPolicyURL: "https://github.com/jerrod/agent-plugins",
        termsOfServiceURL: "https://github.com/jerrod/agent-plugins",
        defaultPrompt: [$prompt],
        brandColor: "#3B82F6",
        screenshots: []
      }
    }'
}

# _augment_manifest_paths — add skills/hooks keys only when the dist tree has them.
_augment_manifest_paths() {
  local manifest="$1" dist_dir="$2"
  if [[ -d "$dist_dir/skills" ]]; then
    manifest=$(printf '%s' "$manifest" | jq '. + {skills: "./skills/"}')
  fi
  if [[ -f "$dist_dir/hooks/hooks.json" ]]; then
    manifest=$(printf '%s' "$manifest" | jq '. + {hooks: "./hooks/hooks.json"}')
  fi
  printf '%s' "$manifest"
}

# generate_plugin_manifest — emit .codex-plugin/plugin.json for a built plugin.
#
# Derives name/version/description/author/keywords from the plugin's Claude
# manifest, delegates base JSON construction to _build_base_manifest, and adds
# skills/hooks paths via _augment_manifest_paths only when the dist tree has them.
generate_plugin_manifest() {
  local plugin_dir="$1" dist_dir="$2"
  local src="$plugin_dir/.claude-plugin/plugin.json"
  local plugin_name version description author_name keywords_json
  plugin_name=$(jq -r '.name' "$src")
  version=$(jq -r '.version' "$src")
  description=$(jq -r '.description' "$src")
  author_name=$(jq -r '.author.name // "jerrod"' "$src")
  keywords_json=$(jq -c '.keywords // []' "$src")

  local display_name short_desc
  display_name=$(printf '%s' "$plugin_name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  short_desc=$(first_sentence "$description")

  local manifest
  manifest=$(_build_base_manifest \
    "$plugin_name" "$version" "$description" "$author_name" \
    "$keywords_json" "$display_name" "$short_desc" "$short_desc")
  manifest=$(_augment_manifest_paths "$manifest" "$dist_dir")

  mkdir -p "$dist_dir/.codex-plugin"
  printf '%s\n' "$manifest" | jq '.' > "$dist_dir/.codex-plugin/plugin.json"
}

# generate_marketplace — emit codex/.agents/plugins/marketplace.json.
#
# Enumerates plugins/*/ and includes every plugin whose codex status is
# supported (skill-compatible or hook-dependent) as a local-source entry.
generate_marketplace() {
  local codex_root="$1"
  local out="$codex_root/.agents/plugins/marketplace.json"
  mkdir -p "$(dirname "$out")"

  local entries='[]'
  for plugin_dir in plugins/*/; do
    plugin_dir="${plugin_dir%/}"
    local pj="$plugin_dir/.claude-plugin/plugin.json"
    [[ -f "$pj" ]] || continue
    local codex_status pname
    codex_status=$(jq -r '.platforms.codex.status // "none"' "$pj")
    case "$codex_status" in
      skill-compatible|hook-dependent) : ;;
      *) continue ;;
    esac
    pname=$(jq -r '.name' "$pj")
    local entry
    entry=$(jq -n --arg name "$pname" '{
      name: $name,
      source: { source: "local", path: ("./plugins/" + $name) },
      policy: { installation: "AVAILABLE", authentication: "ON_INSTALL" },
      category: "Coding"
    }')
    entries=$(printf '%s' "$entries" | jq --argjson e "$entry" '. + [$e]')
  done

  jq -n --argjson plugins "$entries" '{
    name: "agent-plugins",
    interface: { displayName: "agent-plugins" },
    plugins: $plugins
  }' > "$out"
}
