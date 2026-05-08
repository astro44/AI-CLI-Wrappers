#!/usr/bin/env bash
# Shared provider config lookup for standalone AI CLI wrappers.

ai_cli_find_providers_config() {
  local start_dir="${1:-}"
  local script_dir="${2:-${SCRIPT_DIR:-}}"
  local candidate=""

  for candidate in "${AI_CLI_PROVIDERS_CONFIG:-}" "${AUTONOM8_PROVIDERS_CONFIG:-}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  [[ -z "$start_dir" ]] && start_dir="${WORK_DIR:-${WORKSPACE_DIR:-$PWD}}"
  if [[ -f "$start_dir" ]]; then
    start_dir="$(dirname "$start_dir")"
  fi
  start_dir="$(cd "$start_dir" 2>/dev/null && pwd -P || printf "%s" "$start_dir")"

  local dir="$start_dir"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    for candidate in \
      "$dir/providers.yaml" \
      "$dir/go-autonom8/providers.yaml" \
      "$dir/.ai-cli-wrappers/providers.yaml" \
      "$dir/.autonom8/providers.yaml"; do
      if [[ -f "$candidate" ]]; then
        printf "%s" "$candidate"
        return 0
      fi
    done
    dir="$(dirname "$dir")"
  done

  for candidate in \
    "$script_dir/defaults/providers.yaml" \
    "$script_dir/../defaults/providers.yaml"; do
    if [[ -n "$script_dir" && -f "$candidate" ]]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  return 1
}

ai_cli_provider_default_alias() {
  local config="$1"
  local provider="$2"
  awk -v provider="$provider" '
    $0 ~ "^  " provider ":[[:space:]]*$" { in_provider=1; next }
    in_provider && $0 ~ "^  [A-Za-z0-9_-]+:[[:space:]]*$" { exit }
    in_provider && $1 == "default_model:" {
      value=$2
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^["'\''"]|["'\''"]$/, "", value)
      print value
      exit
    }
  ' "$config"
}

ai_cli_provider_model_value() {
  local config="$1"
  local provider="$2"
  local alias="$3"
  awk -v provider="$provider" -v alias="$alias" '
    $0 ~ "^  " provider ":[[:space:]]*$" { in_provider=1; next }
    in_provider && $0 ~ "^  [A-Za-z0-9_-]+:[[:space:]]*$" { exit }
    in_provider && $1 == "models:" { in_models=1; next }
    in_models && $1 ~ "^[A-Za-z0-9_.-]+:$" {
      key=$1
      sub(/:$/, "", key)
      if (key == alias) {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        sub(/[[:space:]]+#.*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        gsub(/^["'\''"]|["'\''"]$/, "", $0)
        print $0
        exit
      }
      next
    }
    in_models && $0 !~ "^[[:space:]]{4,}" { in_models=0 }
  ' "$config"
}

ai_cli_resolve_configured_default_model() {
  local provider="$1"
  local start_dir="${2:-}"
  local script_dir="${3:-${SCRIPT_DIR:-}}"
  local config=""
  local alias=""
  local value=""

  config="$(ai_cli_find_providers_config "$start_dir" "$script_dir" 2>/dev/null || true)"
  [[ -n "$config" ]] || return 1
  alias="$(ai_cli_provider_default_alias "$config" "$provider" 2>/dev/null || true)"
  [[ -n "$alias" ]] || return 1
  value="$(ai_cli_provider_model_value "$config" "$provider" "$alias" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$alias"
  fi
  printf "%s" "$value"
}
