#!/usr/bin/env bash
# Shared model resolution utilities for Autonom8 CLI wrappers.

MODEL_PROVIDER_DEFAULT="__provider_default__"

PROVIDER_CONFIG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/provider-config.sh"
if [[ -f "$PROVIDER_CONFIG_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PROVIDER_CONFIG_LIB"
fi

trim_model_string() {
  local value="${1:-}"
  printf "%s" "$value" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'
}

normalize_model_string() {
  local value=""
  value="$(trim_model_string "${1:-}")"
  value="$(printf "%s" "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf "%s" "$value" | sed 's/[[:space:]_]\+/-/g; s/--\+/-/g; s/^-//; s/-$//')"
  printf "%s" "$value"
}

is_invalid_model_error() {
  local error_msg="${1:-}"
  local error_lower=""
  error_lower="$(printf "%s" "$error_msg" | tr '[:upper:]' '[:lower:]')"
  printf "%s" "$error_lower" | grep -qiE 'cannot use this model|invalid model|unknown model|model.*not found|unsupported model|no such model|unrecognized model|issue with the selected model|pick a different model'
}

cursor_available_models_tsv() {
  cursor_agent_cli models 2>/dev/null | perl -ne '
    s/\x1b\[[0-9;]*[A-Za-z]//g;
    next if /^\s*$/;
    next if /^Loading models/;
    next if /^Available models/;
    next if /^Tip:/;
    my $raw = $_;
    my $current = $raw =~ /\(current\)/ ? 1 : 0;
    my $default = $raw =~ /\(default\)/ ? 1 : 0;
    $raw =~ s/\s+\(current\)\s*$//;
    $raw =~ s/\s+\(default\)\s*$//;
    if ($raw =~ /^\s*([A-Za-z0-9._-]+)\s+-\s+(.*?)\s*$/) {
      print "$1\t$2\t$current\t$default\n";
    }
  '
}

opencode_available_models() {
	opencode models 2>/dev/null | sed '/^[[:space:]]*$/d'
}

opencode_default_model() {
  opencode_available_models | head -n 1
}

resolve_configured_default_model_for_provider() {
  local provider="${1:-}"
  local start_dir="${2:-${WORK_DIR:-${WORKSPACE_DIR:-$PWD}}}"
  local resolved=""
  local catalog_resolved=""
  if declare -F ai_cli_resolve_configured_default_model >/dev/null; then
    resolved="$(ai_cli_resolve_configured_default_model "$provider" "$start_dir" "${SCRIPT_DIR:-}" 2>/dev/null || true)"
  fi
  [[ -n "$resolved" ]] || return 1

  case "$provider" in
    cursor)
      catalog_resolved="$(resolve_model_from_cursor_catalog "$resolved" 2>/dev/null || true)"
      if [[ -n "$catalog_resolved" ]]; then
        printf "%s" "$catalog_resolved"
        return 0
      fi
      if cursor_available_models_tsv >/dev/null 2>&1 && [[ -n "$(cursor_available_models_tsv 2>/dev/null)" ]]; then
        return 1
      fi
      ;;
    opencode)
      catalog_resolved="$(resolve_model_from_opencode_catalog "$resolved" 2>/dev/null || true)"
      if [[ -n "$catalog_resolved" ]]; then
        printf "%s" "$catalog_resolved"
        return 0
      fi
      if opencode_available_models >/dev/null 2>&1 && [[ -n "$(opencode_available_models 2>/dev/null)" ]]; then
        return 1
      fi
      ;;
  esac

  resolve_requested_model_for_provider "$provider" "$resolved"
}

resolve_model_from_cursor_catalog() {
  local requested="${1:-}"
  local normalized=""
  local id=""
  local label=""
  local current=""
  local def=""
  local label_norm=""

  normalized="$(normalize_model_string "$requested")"
  while IFS=$'\t' read -r id label current def; do
    [[ -z "$id" ]] && continue
    label_norm="$(normalize_model_string "$label")"
    if [[ "$requested" == "$id" || "$normalized" == "$id" || "$requested" == "$label" || "$normalized" == "$label_norm" ]]; then
      printf "%s" "$id"
      return 0
    fi
  done < <(cursor_available_models_tsv)

  return 1
}

cursor_default_model() {
  local id=""
  local label=""
  local current=""
  local def=""

  while IFS=$'\t' read -r id label current def; do
    [[ -z "$id" ]] && continue
    if [[ "$current" == "1" ]]; then
      printf "%s" "$id"
      return 0
    fi
  done < <(cursor_available_models_tsv)

  while IFS=$'\t' read -r id label current def; do
    [[ -z "$id" ]] && continue
    if [[ "$def" == "1" ]]; then
      printf "%s" "$id"
      return 0
    fi
  done < <(cursor_available_models_tsv)

  return 1
}

resolve_model_from_opencode_catalog() {
  local requested="${1:-}"
  local normalized=""
  local id=""
  local tail=""

  normalized="$(normalize_model_string "$requested")"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    tail="${id#*/}"
    if [[ "$requested" == "$id" || "$normalized" == "$id" || "$requested" == "$tail" || "$normalized" == "$(normalize_model_string "$tail")" ]]; then
      printf "%s" "$id"
      return 0
    fi
  done < <(opencode_available_models)

  return 1
}

normalize_alias_for_provider() {
  local provider="${1:-}"
  local requested="${2:-}"
  local normalized=""

  normalized="$(normalize_model_string "$requested")"
  [[ -z "$normalized" ]] && return 1

  case "$provider" in
    claude)
      case "$normalized" in
        sonnet|opus|haiku)
          printf "%s" "$normalized"
          return 0
          ;;
      esac
      ;;
    codex|gemini)
      if [[ "$normalized" != "$(trim_model_string "$requested")" ]]; then
        printf "%s" "$normalized"
        return 0
      fi
      ;;
    cursor)
      resolve_model_from_cursor_catalog "$requested" && return 0
      ;;
    opencode)
      resolve_model_from_opencode_catalog "$requested" && return 0
      ;;
  esac

  return 1
}

resolve_requested_model_for_provider() {
  local provider="${1:-}"
  local requested="${2:-}"
  local resolved=""

  requested="$(trim_model_string "$requested")"
  [[ -z "$requested" ]] && return 1

  resolved="$(normalize_alias_for_provider "$provider" "$requested" 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    printf "%s" "$resolved"
    return 0
  fi

  printf "%s" "$requested"
}

default_fallback_model_for_provider() {
  local provider="${1:-}"
  local current_model="${2:-}"
  local live_default=""

	case "$provider" in
	    claude|codex|gemini)
	      resolve_configured_default_model_for_provider "$provider" 2>/dev/null || printf "%s" "$MODEL_PROVIDER_DEFAULT"
	      ;;
	    cursor)
	      cursor_default_model 2>/dev/null || resolve_configured_default_model_for_provider "$provider" 2>/dev/null || printf "%s" "$MODEL_PROVIDER_DEFAULT"
	      ;;
	    opencode)
	      live_default="$(opencode_default_model 2>/dev/null || true)"
	      if [[ -n "$live_default" ]]; then
	        printf "%s" "$live_default"
	      elif [[ -n "${OPENCODE_MODEL:-}" && "${OPENCODE_MODEL:-}" != "$current_model" ]]; then
	        printf "%s" "$OPENCODE_MODEL"
	      else
	        resolve_configured_default_model_for_provider "$provider" 2>/dev/null || printf "%s" "$MODEL_PROVIDER_DEFAULT"
	      fi
      ;;
    *)
      printf "%s" ""
      ;;
  esac
}

is_provider_default_model() {
  [[ "${1:-}" == "$MODEL_PROVIDER_DEFAULT" ]]
}

build_model_resolution_summary() {
  local provider="${1:-}"
  local requested="${2:-}"
  local effective="${3:-}"
  local reason="${4:-normalized}"

  if [[ -z "$requested" || -z "$effective" || "$requested" == "$effective" ]]; then
    return 1
  fi

  printf "%s" "$provider model '$requested' -> '$effective' ($reason)"
}
