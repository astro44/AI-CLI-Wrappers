#!/usr/bin/env bash
# Gemini CLI wrapper for Autonom8
# Configures workspace and invokes gemini CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

WRAPPER_REQ_ID="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-}}"
if [[ -n "${WRAPPER_REQ_ID}" ]]; then
  exec 3>&2
  exec 2> >(while IFS= read -r __a8_line; do
    printf '[req=%s] %s\n' "${WRAPPER_REQ_ID}" "${__a8_line}" >&3
  done)
fi

# Track child process PID for cleanup on script termination
GEMINI_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$GEMINI_PID" ]] && kill -0 "$GEMINI_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$GEMINI_PID" 2>/dev/null || kill "$GEMINI_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$GEMINI_PID" 2>/dev/null || kill -9 "$GEMINI_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT TERM INT

resolve_gemini_cmd() {
  local wrapper_path=""
  wrapper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

  local candidate=""
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    local resolved=""
    resolved="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")"
    if [[ "$resolved" == "$wrapper_path" ]]; then
      continue
    fi
    echo "$candidate"
    return 0
  done < <(which -a gemini 2>/dev/null | awk '!seen[$0]++')

  return 1
}

GEMINI_BIN="$(resolve_gemini_cmd || true)"

gemini() {
  if [[ -z "${GEMINI_BIN:-}" ]]; then
    return 127
  fi
  "$GEMINI_BIN" "$@"
}

# Run command with timeout (preserves stdin for piped input)
run_with_timeout() {
  local timeout_secs="$1"
  shift

  if [[ "${1:-}" == "gemini" && -n "${GEMINI_BIN:-}" ]]; then
    shift
    set -- "$GEMINI_BIN" "$@"
  fi

  local timeout_cmd=""
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout"
  elif command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout"
  fi

  if [[ -n "$timeout_cmd" ]]; then
    # Run timeout in foreground to preserve stdin (piped input)
    # Use --foreground to allow signal handling with job control
    "$timeout_cmd" --foreground --signal=TERM --kill-after=5 "$timeout_secs" "$@"
    return $?
  else
    # Fallback: run in background with manual timeout
    "$@" &
    local pid=$!
    GEMINI_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      GEMINI_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      GEMINI_PID=""
      return $exit_code
    fi
  fi
}

compact_reasoning_text() {
  local text="${1:-}"
  printf "%s" "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//'
}

is_reasoning_placeholder() {
  local text="${1:-}"
  local compacted=""
  compacted="$(compact_reasoning_text "$text")"

  [[ -z "$compacted" ]] && return 0
  if [[ "$compacted" == "{}" || "$compacted" == "[]" || "$compacted" == "null" ]]; then
    return 0
  fi
  if printf "%s" "$compacted" | grep -Eq '^`{3,}[[:space:]]*(json|markdown|md|yaml|yml|text|txt)?[[:space:]]*`{0,3}$'; then
    return 0
  fi
  if [[ ${#compacted} -le 6 ]] && printf "%s" "$compacted" | grep -Eq '^[`[:space:]]+$'; then
    return 0
  fi

  return 1
}

emit_cli_response() {
  local response_text="$1"
  local session_id="${2:-}"
  local raw_output="${3:-}"
  local extra_field_name="${4:-}"
  local extra_field_value="${5:-}"
  local stream_output="${6:-}"

  local tokens_json='{"input_tokens":0,"output_tokens":0,"estimated_output_tokens":0,"total_tokens":0,"cost_usd":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
  local token_usage_available=false
  local reasoning_text=""
  local reasoning_available=false
  local reasoning_source="none"
  local reasoning_absent_reason="model_not_emitted"

  if [[ -n "$raw_output" ]]; then
    local parsed_tokens
    parsed_tokens="$(printf "%s" "$raw_output" | jq -c '
      def as_int:
        if type == "number" then floor
        elif type == "string" then (tonumber? // 0)
        else 0 end;
      def as_num:
        if type == "number" then .
        elif type == "string" then (tonumber? // 0)
        else 0 end;
      {
        input_tokens: ((.usage.input_tokens // .usage.inputTokens // .input_tokens // .inputTokens // .token_usage.input_tokens // .token_usage.prompt_tokens // .prompt_tokens // 0) | as_int),
        output_tokens: ((.usage.output_tokens // .usage.outputTokens // .output_tokens // .outputTokens // .token_usage.output_tokens // .token_usage.completion_tokens // .completion_tokens // 0) | as_int),
        total_tokens: ((.usage.total_tokens // .usage.totalTokens // .total_tokens // .totalTokens // .token_usage.total_tokens // .token_usage.total // .total_tokens_used // 0) | as_int),
        cost_usd: ((.usage.cost_usd // .usage.cost // .cost_usd // .token_usage.cost_usd // .cost // 0) | as_num)
      }
      | if .total_tokens == 0 and ((.input_tokens + .output_tokens) > 0)
        then .total_tokens = (.input_tokens + .output_tokens)
        else .
        end
    ' 2>/dev/null || true)"
    if [[ -n "$parsed_tokens" && "$parsed_tokens" != "null" ]]; then
      tokens_json="$parsed_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
    fi
  fi

  if [[ "$token_usage_available" != "true" && -n "$session_id" ]]; then
    local session_tokens
    session_tokens="$(get_gemini_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
    fi
  fi

  if [[ "$token_usage_available" != "true" && -n "$stream_output" ]]; then
    local stream_total_tokens=""
    stream_total_tokens="$(printf "%s" "$stream_output" | \
      perl -pe 's/\x1b\[[0-9;]*[A-Za-z]//g' | \
      grep -ioE 'tokens used[^0-9]*[0-9]+' | \
      tail -1 | grep -oE '[0-9]+' | tail -1 || true)"
    if [[ -n "$stream_total_tokens" ]]; then
      tokens_json="$(printf "%s" "$tokens_json" | jq -c --argjson total "$stream_total_tokens" '
        .total_tokens = $total
        | if .output_tokens == 0 then .output_tokens = $total else . end
      ' 2>/dev/null || echo "$tokens_json")"
      token_usage_available=true
    fi
  fi

  if [[ -n "$raw_output" ]]; then
    local raw_reasoning
    raw_reasoning="$(printf "%s" "$raw_output" | jq -r '
      def stringify:
        if type == "string" then .
        elif type == "object" or type == "array" then tojson
        else tostring end;
      (._reasoning // .reasoning // .thinking // .thoughts // .analysis // empty)
      | stringify
    ' 2>/dev/null || true)"
    if [[ -n "$raw_reasoning" && "$raw_reasoning" != "null" ]]; then
      reasoning_text="$raw_reasoning"
      reasoning_source="raw_output"
    fi
  fi

  if [[ -z "$reasoning_text" && -n "$session_id" ]]; then
    local session_reasoning
    session_reasoning="$(get_gemini_session_reasoning "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_reasoning" ]]; then
      reasoning_text="$session_reasoning"
      reasoning_source="session_log"
    fi
  fi

  if [[ -z "$reasoning_text" && -n "$response_text" ]]; then
    local response_reasoning
    response_reasoning="$(printf "%s" "$response_text" | jq -r '
      def stringify:
        if type == "string" then .
        elif type == "object" or type == "array" then tojson
        else tostring end;
      if type == "object"
      then (._reasoning // .reasoning // .thinking // .thoughts // .analysis // empty) | stringify
      else empty
      end
    ' 2>/dev/null || true)"
    if [[ -n "$response_reasoning" && "$response_reasoning" != "null" ]]; then
      reasoning_text="$response_reasoning"
      reasoning_source="response_payload"
    fi
  fi

  if [[ -z "$reasoning_text" && -n "$stream_output" ]]; then
    local stream_reasoning
    stream_reasoning="$(printf "%s" "$stream_output" | \
      perl -pe 's/\x1b\[[0-9;]*[A-Za-z]//g' | \
      grep -iE 'thought|thinking|reasoning|analysis|plan:|step [0-9]+' | \
      grep -ivE 'using model|timeout|loaded cached credentials|yolo mode|tokens used|tool call|session id|debug:' | \
      tail -n 20 | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g' | sed 's/^ //;s/ $//' || true)"
    if [[ -n "$stream_reasoning" ]]; then
      reasoning_text="$stream_reasoning"
      reasoning_source="stream_log"
    fi
  fi

  if [[ -n "$reasoning_text" ]]; then
    reasoning_text="$(compact_reasoning_text "$reasoning_text")"
  fi

  if [[ ${#reasoning_text} -gt 2 ]] && ! is_reasoning_placeholder "$reasoning_text"; then
    reasoning_available=true
    reasoning_absent_reason="available"
  else
    reasoning_text=""
    reasoning_available=false
    reasoning_source="none"
    reasoning_absent_reason="model_not_emitted"
  fi

  local response_chars=${#response_text}
  local estimated_output_tokens=$((response_chars / 4))
  if [[ $response_chars -gt 0 && $estimated_output_tokens -le 0 ]]; then
    estimated_output_tokens=1
  fi
  tokens_json="$(printf "%s" "$tokens_json" | jq -c --argjson estimated "$estimated_output_tokens" '
    .estimated_output_tokens = $estimated
    | if .cache_read_input_tokens == null then .cache_read_input_tokens = 0 else . end
    | if .cache_creation_input_tokens == null then .cache_creation_input_tokens = 0 else . end
  ' 2>/dev/null || echo "$tokens_json")"

  RESPONSE_EMITTED=true

  if [[ -n "$session_id" && -n "$extra_field_name" ]]; then
    jq -n \
      --arg resp "$response_text" \
      --arg sid "$session_id" \
      --arg reasoning "$reasoning_text" \
      --arg extra_name "$extra_field_name" \
      --arg extra_val "$extra_field_value" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}'
  elif [[ -n "$session_id" ]]; then
    jq -n \
      --arg resp "$response_text" \
      --arg sid "$session_id" \
      --arg reasoning "$reasoning_text" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}'
  elif [[ -n "$extra_field_name" ]]; then
    jq -n \
      --arg resp "$response_text" \
      --arg reasoning "$reasoning_text" \
      --arg extra_name "$extra_field_name" \
      --arg extra_val "$extra_field_value" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}'
  else
    jq -n \
      --arg resp "$response_text" \
      --arg reasoning "$reasoning_text" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}'
  fi
}

emit_cli_error_response() {
  local error_msg="$1"
  local error_type="${2:-unknown}"
  local session_id="${3:-}"
  local exit_code="${4:-1}"
  local extra_field_name="${5:-}"
  local extra_field_value="${6:-}"
  local tokens_json='{"input_tokens":0,"output_tokens":0,"estimated_output_tokens":0,"total_tokens":0,"cost_usd":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
  local token_usage_available=false
  local reasoning_text=""
  local reasoning_available=false
  local reasoning_source="none"
  local reasoning_absent_reason="error_path"
  local recoverable=false
  case "$error_type" in
    quota|rate_limit|timeout|invalid_session)
      recoverable=true
      ;;
  esac

  if [[ -n "$session_id" ]]; then
    local session_tokens=""
    session_tokens="$(get_gemini_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
    fi

    local session_reasoning=""
    session_reasoning="$(get_gemini_session_reasoning "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_reasoning" ]]; then
      session_reasoning="$(compact_reasoning_text "$session_reasoning")"
      if [[ ${#session_reasoning} -gt 2 ]] && ! is_reasoning_placeholder "$session_reasoning"; then
        reasoning_text="$session_reasoning"
        reasoning_available=true
        reasoning_source="session_log_error_fallback"
        reasoning_absent_reason="available"
      fi
    fi
  fi

  RESPONSE_EMITTED=true
  if [[ -n "$session_id" ]]; then
    if [[ -n "$extra_field_name" ]]; then
      jq -n \
        --arg sid "$session_id" \
        --arg err "$error_msg" \
        --arg type "$error_type" \
        --argjson code "$exit_code" \
        --argjson recoverable "$recoverable" \
        --arg reasoning "$reasoning_text" \
        --arg extra_name "$extra_field_name" \
        --arg extra_val "$extra_field_value" \
        --argjson tokens "$tokens_json" \
        --argjson available "$token_usage_available" \
        --argjson reasoning_available "$reasoning_available" \
        --arg reasoning_source "$reasoning_source" \
        --arg reasoning_absent_reason "$reasoning_absent_reason" \
        '{
          response: "",
          session_id: $sid,
          reasoning: $reasoning,
          tokens_used: $tokens,
          metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason},
          error: $err,
          error_type: $type,
          exit_code: $code,
          recoverable: $recoverable
        } + {($extra_name): $extra_val}'
    else
      jq -n \
        --arg sid "$session_id" \
        --arg err "$error_msg" \
        --arg type "$error_type" \
        --argjson code "$exit_code" \
        --argjson recoverable "$recoverable" \
        --arg reasoning "$reasoning_text" \
        --argjson tokens "$tokens_json" \
        --argjson available "$token_usage_available" \
        --argjson reasoning_available "$reasoning_available" \
        --arg reasoning_source "$reasoning_source" \
        --arg reasoning_absent_reason "$reasoning_absent_reason" \
        '{
          response: "",
          session_id: $sid,
          reasoning: $reasoning,
          tokens_used: $tokens,
          metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason},
          error: $err,
          error_type: $type,
          exit_code: $code,
          recoverable: $recoverable
        }'
    fi
  else
    if [[ -n "$extra_field_name" ]]; then
      jq -n \
        --arg err "$error_msg" \
        --arg type "$error_type" \
        --argjson code "$exit_code" \
        --argjson recoverable "$recoverable" \
        --arg reasoning "$reasoning_text" \
        --arg extra_name "$extra_field_name" \
        --arg extra_val "$extra_field_value" \
        --argjson tokens "$tokens_json" \
        --argjson available "$token_usage_available" \
        --argjson reasoning_available "$reasoning_available" \
        --arg reasoning_source "$reasoning_source" \
        --arg reasoning_absent_reason "$reasoning_absent_reason" \
        '{
          response: "",
          reasoning: $reasoning,
          tokens_used: $tokens,
          metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason},
          error: $err,
          error_type: $type,
          exit_code: $code,
          recoverable: $recoverable
        } + {($extra_name): $extra_val}'
    else
      jq -n \
        --arg err "$error_msg" \
        --arg type "$error_type" \
        --argjson code "$exit_code" \
        --argjson recoverable "$recoverable" \
        --arg reasoning "$reasoning_text" \
        --argjson tokens "$tokens_json" \
        --argjson available "$token_usage_available" \
        --argjson reasoning_available "$reasoning_available" \
        --arg reasoning_source "$reasoning_source" \
        --arg reasoning_absent_reason "$reasoning_absent_reason" \
        '{
          response: "",
          reasoning: $reasoning,
          tokens_used: $tokens,
          metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason},
          error: $err,
          error_type: $type,
          exit_code: $code,
          recoverable: $recoverable
        }'
    fi
  fi
}

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*" >&2
    fi
}

get_gemini_mcp_config() {
  if [[ -f "$CORE_DIR/.gemini/.mcp.json" ]]; then
    echo "$CORE_DIR/.gemini/.mcp.json"
  elif [[ -f "$CORE_DIR/.mcp.json" ]]; then
    echo "$CORE_DIR/.mcp.json"
  fi
}

# Ensure a skill is enabled in Gemini's native skill registry
# This allows Gemini to auto-activate skills when needed
ensure_gemini_skill_enabled() {
  local skill_name="$1"
  local scope="${2:-project}"  # project or user

  # Check if skill is already enabled
  local skill_list
  skill_list="$(gemini skills list 2>/dev/null || true)"

  if echo "$skill_list" | grep -q "^$skill_name[[:space:]]"; then
    log_verbose "Skill '$skill_name' already registered"
    return 0
  fi

  # Try to enable the skill
  if gemini skills enable "$skill_name" --scope "$scope" 2>/dev/null; then
    log_verbose "Enabled skill: $skill_name (scope: $scope)"
    return 0
  else
    log_verbose "Could not enable skill '$skill_name' (may not exist in .gemini/skills/)"
    return 1
  fi
}

# Reload Gemini's skill registry to pick up new/modified skills
reload_gemini_skills() {
  gemini skills reload 2>/dev/null || true
  log_verbose "Reloaded Gemini skill registry"
}

# Filter out Gemini CLI informational output from stdout
# Gemini outputs status messages that interfere with JSON parsing:
# - "YOLO mode is enabled. All tool calls will be automatically approved."
# - "Loaded cached credentials."
# - "Tool xyz executed successfully" (tool confirmation messages)
filter_gemini_info_lines() {
  local input="$1"
  echo "$input" | grep -v \
    -e '^YOLO mode is enabled' \
    -e '^Loaded cached credentials' \
    -e '^Tool .* executed' \
    -e '^Connecting to' \
    -e '^Connected\.$' \
    -e '^Session started' \
    -e '^Using model' \
    -e '^Loading' || true
}

strip_gemini_startup_stderr_lines() {
  local input="$1"
  echo "$input" | grep -v \
    -e '^Loaded cached credentials' \
    -e '^Registering notification handlers for server' \
    -e "^Server '.*' has tools but did not declare 'listChanged' capability" \
    -e "^Server '.*' supports tool updates" \
    -e '^Scheduling MCP context refresh' \
    -e '^Executing MCP context refresh' \
    -e '^MCP context refresh complete' || true
}

is_gemini_startup_only_error() {
  local input="$1"
  local filtered=""
  filtered="$(strip_gemini_startup_stderr_lines "$input" | tr -d '[:space:]')"
  [[ -z "$filtered" ]]
}

build_gemini_no_response_error() {
  local raw_response="${1:-}"
  local stderr_text="${2:-}"
  local response_after_filter="${3:-}"
  local classified_type="provider_error"
  local detail="Gemini returned no terminal response."

  if [[ -n "$stderr_text" ]] && declare -F classify_error >/dev/null; then
    classified_type="$(classify_error "$stderr_text")"
    if [[ "$classified_type" != "unknown" && "$classified_type" != "provider_error" ]]; then
      detail="Gemini returned no terminal response; stderr classified as ${classified_type}."
    fi
  fi

  if [[ -z "$response_after_filter" && -n "$raw_response" ]]; then
    detail="Gemini returned only wrapper-filtered informational stdout and no terminal response payload."
  fi

  printf "%s\t%s" "$classified_type" "$detail"
}

ensure_gemini_mcp_servers() {
  local config_path="$1"
  local server_names
  server_names=$(jq -r '.mcpServers | keys[]' "$config_path" 2>/dev/null || true)
  if [[ -z "$server_names" ]]; then
    return 0
  fi

  local current_list
  current_list="$(gemini mcp list 2>/dev/null || true)"

  while read -r server_name; do
    [[ -z "$server_name" ]] && continue
    if ! echo "$current_list" | grep -q "^${server_name}[[:space:]]"; then
      local command
      command=$(jq -r ".mcpServers.\"$server_name\".command" "$config_path" 2>/dev/null || true)
      if [[ -z "$command" || "$command" == "null" ]]; then
        continue
      fi
      mapfile -t args < <(jq -r ".mcpServers.\"$server_name\".args[]?" "$config_path" 2>/dev/null || true)
      gemini mcp add "$server_name" "$command" "${args[@]}" >/dev/null 2>&1 || true
      log_verbose "Registered MCP server for gemini: $server_name"
    fi
  done <<< "$server_names"
}

# Determine core directory based on script location
# Script is in bin/gemini.sh, so CORE_DIR is parent of bin/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Prompt Utilities (inlined, provider-specific)
# Gemini has 1M token context window (~4M chars)
# P7.1 FIX: Use 100K limit (was 30K) - Sprint Architect prompts can be 40-50K chars
# =============================================================================
PROMPT_MAX_CHARS=100000        # ~25K tokens - conservative limit for Gemini
PROMPT_WARN_THRESHOLD=80000    # Warn at ~20K tokens

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] WARN: $*" >&2
}

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] INFO: $*" >&2
}

check_prompt_size() {
    local prompt="$1"
    local provider="${2:-gemini}"
    local prompt_size=${#prompt}
    local estimated_tokens=$((prompt_size / 4))

    if [[ $prompt_size -gt $PROMPT_MAX_CHARS ]]; then
        log_warn "[$provider] LARGE PROMPT: ${prompt_size} chars (~${estimated_tokens} tokens) exceeds limit of ${PROMPT_MAX_CHARS}"
        return 1
    elif [[ $prompt_size -gt $PROMPT_WARN_THRESHOLD ]]; then
        log_warn "[$provider] Prompt size warning: ${prompt_size} chars (~${estimated_tokens} tokens) approaching limit"
        return 0
    fi
    return 0
}

get_prompt_stats() {
    local prompt="$1"
    local provider="${2:-gemini}"
    local prompt_size=${#prompt}
    local estimated_tokens=$((prompt_size / 4))
    local over_limit="false"
    [[ $prompt_size -gt $PROMPT_MAX_CHARS ]] && over_limit="true"

    jq -n \
        --arg provider "$provider" \
        --argjson size "$prompt_size" \
        --argjson tokens "$estimated_tokens" \
        --argjson max "$PROMPT_MAX_CHARS" \
        --arg over "$over_limit" \
        '{provider: $provider, prompt_size_chars: $size, estimated_tokens: $tokens, max_chars: $max, over_limit: ($over == "true")}'
}

save_debug_prompt() {
    local prompt="$1"
    local persona_id="$2"
    local provider="${3:-gemini}"
    [[ "${DEBUG_PROMPTS:-false}" != "true" ]] && return 0

    local log_dir="${PROMPT_LOG_DIR:-/tmp/autonom8_prompts}"
    mkdir -p "$log_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local safe_persona=$(echo "$persona_id" | tr ' ()' '_')
    local filename="${timestamp}_${provider}_${safe_persona}.txt"

    {
        echo "# Prompt Debug Log"
        echo "# Provider: $provider"
        echo "# Persona: $persona_id"
        echo "# Size: ${#prompt} chars"
        echo "---"
        echo "$prompt"
    } > "$log_dir/$filename"
    log_info "Prompt saved to: $log_dir/$filename"
}
# =============================================================================

# P6.1: Source shared error handling library
if [[ -f "$SCRIPT_DIR/lib/error_utils.sh" ]]; then
    source "$SCRIPT_DIR/lib/error_utils.sh"
fi
if [[ -f "$SCRIPT_DIR/lib/model_utils.sh" ]]; then
    source "$SCRIPT_DIR/lib/model_utils.sh"
fi

MODEL_REQUESTED_RAW=""
MODEL_RESOLUTION_NOTE=""
MODEL_PREPARED_VALUE=""
GEMINI_CAPACITY_RETRIED=false

prepare_requested_model_value() {
  local provider="${1:-}"
  local requested="${2:-}"
  local resolved=""

  if [[ -z "${requested:-}" ]]; then
    MODEL_PREPARED_VALUE="$requested"
    return 0
  fi

  if ! declare -F trim_model_string >/dev/null; then
    MODEL_PREPARED_VALUE="$requested"
    return 0
  fi

  MODEL_REQUESTED_RAW="$(trim_model_string "$requested")"
  if [[ -z "$MODEL_REQUESTED_RAW" ]]; then
    MODEL_PREPARED_VALUE=""
    return 0
  fi

  resolved="$MODEL_REQUESTED_RAW"
  if declare -F resolve_requested_model_for_provider >/dev/null; then
    resolved="$(resolve_requested_model_for_provider "$provider" "$MODEL_REQUESTED_RAW" 2>/dev/null || printf "%s" "$MODEL_REQUESTED_RAW")"
  fi

  if [[ "$resolved" != "$MODEL_REQUESTED_RAW" ]] && declare -F build_model_resolution_summary >/dev/null; then
    MODEL_RESOLUTION_NOTE="$(build_model_resolution_summary "$provider" "$MODEL_REQUESTED_RAW" "$resolved" "normalized")"
  fi

  MODEL_PREPARED_VALUE="$resolved"
}

retry_with_provider_default_model() {
  local provider="${1:-}"
  local current_model="${2:-}"
  local fallback=""

  [[ -n "$MODEL_REQUESTED_RAW" ]] || return 1
  declare -F default_fallback_model_for_provider >/dev/null || return 1

  fallback="$(default_fallback_model_for_provider "$provider" "$current_model" 2>/dev/null || true)"
  [[ -n "$fallback" ]] || return 1

  if declare -F is_provider_default_model >/dev/null && is_provider_default_model "$fallback"; then
    MODEL_RESOLUTION_NOTE="$(build_model_resolution_summary "$provider" "$MODEL_REQUESTED_RAW" "provider-default" "fallback")"
    printf "%s" ""
    return 0
  fi

  if [[ "$fallback" == "$current_model" ]]; then
    return 1
  fi

  if declare -F build_model_resolution_summary >/dev/null; then
    MODEL_RESOLUTION_NOTE="$(build_model_resolution_summary "$provider" "$MODEL_REQUESTED_RAW" "$fallback" "fallback")"
  fi
  printf "%s" "$fallback"
}

append_model_resolution_note() {
  local note="${1:-}"
  [[ -n "$note" ]] || return 0
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    MODEL_RESOLUTION_NOTE="${MODEL_RESOLUTION_NOTE}; ${note}"
  else
    MODEL_RESOLUTION_NOTE="$note"
  fi
}

is_gemini_capacity_error() {
  local error_msg="${1:-}"
  local error_lower=""
  error_lower="$(printf "%s" "$error_msg" | tr '[:upper:]' '[:lower:]')"
  printf "%s" "$error_lower" | grep -qiE 'model_capacity_exhausted|resource_exhausted|no capacity available for model|ratelimitexceeded'
}

retry_with_gemini_capacity_fallback() {
  local current_model="${1:-}"
  local fallback_model="gemini-2.5-flash"
  local source_label="${current_model:-provider-default}"

  [[ "$GEMINI_CAPACITY_RETRIED" != "true" ]] || return 1
  [[ "$current_model" != "$fallback_model" ]] || return 1

  GEMINI_CAPACITY_RETRIED=true
  MODEL="$fallback_model"
  append_model_resolution_note "gemini model '$source_label' -> '$fallback_model' (capacity_fallback)"
  printf "%s" "$fallback_model"
}

# Agent invocation mode: wrapper expects agent .md file path + optional input data
# We must extract a single persona block, not pass the whole file.

validate_agent_file() {
  local file="$1"
  # Ensure at least one valid persona section exists (support both ## and ### headers)
  if ! grep -qE '^##+[[:space:]]+Persona:' "$file"; then
    emit_cli_error_response "Invalid agent file format: Missing ## Persona:/### Persona: header in $file" "invalid_input" "" 3
    exit 3
  fi

  # Ensure each persona has at least some description or instructions
  if ! awk '/^##+[[:space:]]+Persona:/{count++} END{exit (count>=1)?0:1}' "$file"; then
    emit_cli_error_response "Invalid agent file format: No valid persona blocks detected in $file" "invalid_input" "" 3
    exit 3
  fi
}

extract_persona_block() {
  local file="$1"
  local persona_id="$2"   # e.g., pm-gemini | dev-gemini (Implement) | dev-gemini (Design)
  # P1.5.1 FIX: Match full persona ID including role suffix
  # Supports both old format (pm-gemini) and new format (dev-gemini (Implement))
  # Match header "## Persona:" or "### Persona:"
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # Remove trailing whitespace
      gsub(/[[:space:]]*$/, "", hdr)
      # P1.5.1 FIX: Compare full persona ID (exact match) or prefix match for backward compat
      # Full match: "dev-gemini (Implement)" == "dev-gemini (Implement)"
      # Prefix match: "pm-gemini" matches "pm-gemini (Quality Reviewer)" for legacy support
      if(hdr == id){found=1; print $0; next}
      # Legacy prefix matching: if id has no parentheses, match prefix
      if(index(id, "(") == 0) {
        split(hdr,a," ")
        if(a[1]==id){found=1; print $0; next}
      }
    }
    found{print}
  ' "$file"
}

parse_arg_json_or_stdin() {
  # Prefer piped stdin; otherwise use remaining args as one blob
  if [ ! -t 0 ]; then
    cat
  else
    printf "%s" "$*"
  fi
}

get_gemini_session_file_by_id() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1

  local short_id="${session_id%%-*}"
  local candidate=""

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if jq -e --arg sid "$session_id" '.sessionId == $sid' "$candidate" >/dev/null 2>&1; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done < <(find "$HOME/.gemini/tmp" "$HOME/.gemini/history" -path "*/chats/session-*-${short_id}.json" -type f 2>/dev/null | sort -r)

  # Fallback for legacy or unusual file naming.
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if jq -e --arg sid "$session_id" '.sessionId == $sid' "$candidate" >/dev/null 2>&1; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done < <(rg -l --fixed-strings "\"sessionId\": \"$session_id\"" "$HOME/.gemini/tmp" "$HOME/.gemini/history" -g 'session-*.json' 2>/dev/null | head -20)

  return 1
}

get_gemini_session_token_usage() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_gemini_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  jq -rc '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    ([.messages[]? | select(.type == "gemini" and .tokens != null) | .tokens] | last) as $t
    | select($t != null)
    | {
        input_tokens: ((($t.input // $t.input_tokens // 0) + ($t.cached // 0)) | as_int),
        output_tokens: ((($t.output // $t.output_tokens // 0) + ($t.thoughts // 0) + ($t.tool // 0)) | as_int),
        total_tokens: (($t.total // (($t.input // 0) + ($t.output // 0) + ($t.thoughts // 0) + ($t.tool // 0) + ($t.cached // 0))) | as_int),
        cost_usd: 0
      }
    | if .total_tokens == 0 and ((.input_tokens + .output_tokens) > 0)
      then .total_tokens = (.input_tokens + .output_tokens)
      else .
      end
  ' "$session_file" | tail -1
}

get_gemini_session_reasoning() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_gemini_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  local reasoning
  reasoning="$(jq -r '
    [
      .messages[]?
      | select(.type == "gemini")
      | (.thoughts // [])[]?
      | (.description // empty)
    ]
    | map(select(length > 0))
    | if length > 5 then .[-5:] else . end
    | join(" ")
  ' "$session_file" 2>/dev/null || true)"

  [[ -n "$reasoning" ]] && printf "%s" "$reasoning" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//' | cut -c1-600
}

# Get the latest Gemini session index for the current project
# Returns the index number of the most recent session (highest index = newest)
get_latest_gemini_session() {
  local work_dir="${1:-$PWD}"
  local session_output=""

  # Get session list from Gemini CLI
  # Note: Gemini outputs to stderr, so we redirect stderr to stdout
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>&1 || true)"

  if [[ -n "$session_output" ]]; then
    # Gemini lists sessions oldest-first (1 = oldest, N = newest)
    # Get the LAST session line for the newest session
    # Format: "  374. INSTRUCTIONS: ... (Just now) [42dd8d44-313f-48ae-a422-87b42e1c4393]"
    # Extract the UUID from brackets, not the index number
    local latest_uuid=""
    # Use tail -1 to get the newest (last) session, then extract UUID from [brackets]
    latest_uuid="$(echo "$session_output" | grep -E '^[[:space:]]+[0-9]+\.' | tail -1 | grep -oE '\[[a-f0-9-]+\]$' | tr -d '[]')"

    if [[ -n "$latest_uuid" && ${#latest_uuid} -ge 32 ]]; then
      printf "%s" "$latest_uuid"
      return 0
    fi

    # Fallback: try to get index if UUID extraction failed
    local latest_index=""
    latest_index="$(echo "$session_output" | grep -E '^[[:space:]]+[0-9]+\.' | tail -1 | sed 's/^[[:space:]]*//' | cut -d'.' -f1)"
    if [[ -n "$latest_index" && "$latest_index" =~ ^[0-9]+$ ]]; then
      printf "%s" "$latest_index"
      return 0
    fi
  fi

  return 1
}

# Get the next session index (current count + 1)
get_next_gemini_session_index() {
  local work_dir="${1:-$PWD}"
  local session_output=""
  local session_count=0

  # Get session list and count
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>/dev/null || true)"

  if [[ -n "$session_output" ]]; then
    # Extract the session count from "Available sessions for this project (N):"
    session_count="$(echo "$session_output" | grep -oE 'Available sessions.*\([0-9]+\)' | grep -oE '[0-9]+' || echo "0")"
  fi

  # Next session index will be count + 1
  echo $((session_count + 1))
}

# Validate if a session ID exists in Gemini's session list
# Sessions can be numeric indices or UUIDs
validate_gemini_session() {
  local session_id="$1"
  local work_dir="${2:-$PWD}"
  local session_output=""

  # Get session list from Gemini CLI
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>&1 || true)"

  if [[ -z "$session_output" ]]; then
    return 1
  fi

  # Check if session ID appears in output (supports both index and UUID)
  # Format: "  323. INSTRUCTIONS: ... (Just now) [uuid]"
  if echo "$session_output" | grep -qE "^[[:space:]]+${session_id}\.|\\[${session_id}\\]"; then
    return 0
  fi

  return 1
}

# Initialize flags
PERSONA_OVERRIDE=""
YOLO_MODE=false
DRY_RUN=false
VERBOSE=false
TASK_VAL=""
TEMPERATURE=""
CONTEXT_FILE=""
CONTEXT_DIR=""
CONTEXT_MAX=51200  # 50KB default max context size
SKIP_CONTEXT_FILE=false
ALLOW_TOOLS=false  # Gemini handles tool access internally
MCP_SERVER_NAMES=()
SESSION_ID=""        # Existing session index to resume
MANAGE_SESSION=""    # Placeholder for new session (Gemini returns actual index)
SKILL_NAME=""        # Skill to invoke - Gemini now supports native skills (Jan 2026)
HEALTH_CHECK=false   # P6.4: Health check mode
MODEL=""             # Model selection (pro, flash, flash-thinking, or full model name)
PERMISSION_MODE=""   # Permission mode (ignored by gemini - no plan mode support)
REASONING_FALLBACK=false # Emit fallback reasoning/tokens from session logs only

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona)
      PERSONA_OVERRIDE="$2"; shift 2
      ;;
    --temperature)
      TEMPERATURE="$2"; shift 2
      ;;
    --context)
      CONTEXT_FILE="$2"; shift 2
      ;;
    --context-dir)
      CONTEXT_DIR="$2"; shift 2
      ;;
    --context-max)
      CONTEXT_MAX="$2"; shift 2
      ;;
    --skip-context-file)
      SKIP_CONTEXT_FILE=true; shift
      ;;
    --yolo)
      YOLO_MODE=true; shift
      ;;
    --allow-tools|--allowed-tools)
      # Gemini equivalent: enable tool access
      ALLOW_TOOLS=true
      YOLO_MODE=true  # Gemini uses yolo mode for unrestricted access
      shift
      ;;
    --dry-run)
      DRY_RUN=true; shift
      ;;
    --timeout)
      CLI_TIMEOUT="$2"; shift 2
      ;;
    --verbose|--debug)
      VERBOSE=true; shift
      ;;
    --session-id|--resume)
      # Both flags accepted for compatibility:
      # --session-id: From Go CLIManager for consistency with Claude
      # --resume: Native Gemini flag
      SESSION_ID="$2"; shift 2
      ;;
    --manage-session)
      MANAGE_SESSION="$2"; shift 2
      ;;
    --skill)
      SKILL_NAME="$2"; shift 2
      ;;
    --health-check)
      HEALTH_CHECK=true; shift
      ;;
    --model)
      MODEL="$2"; shift 2
      ;;
    --mode|--permission-mode)
      PERMISSION_MODE="$2"; shift 2
      # Note: Gemini ignores mode flag - no plan mode support
      ;;
    --reasoning-fallback|--reasoning-fallback-only)
      REASONING_FALLBACK=true; shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$MODEL" ]]; then
  prepare_requested_model_value "gemini" "$MODEL"
  MODEL="$MODEL_PREPARED_VALUE"
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    log_info "Model resolution: $MODEL_RESOLUTION_NOTE"
  fi
fi

# ===================
# P6.4: Health Check Mode
# ===================
# If --health-check flag is provided, check provider health and return status
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing gemini CLI availability"

  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Check if gemini CLI is available
  if [[ -z "$GEMINI_BIN" ]]; then
    jq -n --arg provider "gemini" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "gemini CLI not found in PATH (non-wrapper binary resolution failed)",
      session_support: true
    }'
    exit 1
  fi

  # Try a minimal invocation to verify CLI works
  HEALTH_OUTPUT=$(gemini --version 2>&1 || echo "version_check_failed")
  HEALTH_EXIT=$?

  END_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Calculate latency (handle both nanosecond and second precision)
  if [[ ${#START_TIME} -gt 10 ]]; then
    LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  else
    LATENCY_MS=$(( (END_TIME - START_TIME) * 1000 ))
  fi

  if [[ $HEALTH_EXIT -eq 0 ]]; then
    # Extract version if available
    VERSION=$(echo "$HEALTH_OUTPUT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

    jq -n --arg provider "gemini" \
          --arg status "ok" \
          --argjson latency "$LATENCY_MS" \
          --arg version "$VERSION" \
          '{
            provider: $provider,
            status: $status,
            latency_ms: $latency,
            cli_available: true,
            version: $version,
            session_support: true
          }'
  else
    jq -n --arg provider "gemini" \
          --arg error "$HEALTH_OUTPUT" \
          --argjson latency "$LATENCY_MS" \
          '{
            provider: $provider,
            status: "error",
            latency_ms: $latency,
            cli_available: true,
            error: $error,
            session_support: true
          }'
  fi
  exit 0
fi

# ===================
# Reasoning Fallback Mode
# ===================
# Emit telemetry envelope from session logs without invoking provider CLI.
if [[ "$REASONING_FALLBACK" == "true" ]]; then
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$(get_latest_gemini_session "$PWD" 2>/dev/null || true)"
  fi
  if [[ -z "$SESSION_ID" ]]; then
    emit_cli_error_response "reasoning_fallback requires --session-id (or an available latest session)" "invalid_input" "" 2
    exit 2
  fi
  emit_cli_response "" "$SESSION_ID" "" "" "" ""
  exit 0
fi

# ===================
# Skill Execution Mode
# ===================
# Gemini supports native skills via .gemini/skills/ directory (Jan 2026)
# Skills auto-activate when requests match skill descriptions
# Using direct prompt injection for controlled JSON output format
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME via prompt injection (controlled output format)"

  # Ensure skill is registered in Gemini's native skill system
  # This allows Gemini to auto-activate if the prompt matches the skill description
  ensure_gemini_skill_enabled "$SKILL_NAME" "project" || true

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  # Priority: .gemini/skills (project) > modules/Autonom8-Agents (canonical) > other providers
  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/.gemini/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.codex/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.cursor/skills/${SKILL_NAME}/SKILL.md"
  )

  for loc in "${SKILL_LOCATIONS[@]}"; do
    if [[ -f "$loc" ]]; then
      SKILL_FILE="$loc"
      break
    fi
  done

  if [[ -z "$SKILL_FILE" ]]; then
    emit_cli_error_response "Skill not found: $SKILL_NAME" "invalid_input" "" 2
    exit 2
  fi

  log_verbose "Skill file: $SKILL_FILE"

  # Load skill content
  SKILL_CONTENT="$(cat "$SKILL_FILE")"

  # Build skill prompt with input data
  if [[ -n "$SKILL_INPUT" ]]; then
    SKILL_PROMPT="Execute the following skill:

---
$SKILL_CONTENT
---

Input Data:
$SKILL_INPUT

---

CRITICAL: Return ONLY valid JSON matching the skill's output schema. No markdown, no explanations."
  else
    SKILL_PROMPT="Execute the following skill:

---
$SKILL_CONTENT
---

CRITICAL: Return ONLY valid JSON matching the skill's output schema. No markdown, no explanations."
  fi

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    jq -n --arg skill "$SKILL_NAME" --arg file "$SKILL_FILE" \
      '{dry_run: true, wrapper: "gemini.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed", note: "fallback_mode"}'
    exit 0
  fi

  # Create temp files
  TMPFILE_PROMPT="$(mktemp)"
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  echo "$SKILL_PROMPT" > "$TMPFILE_PROMPT"

  # Determine tenant directory
  TENANT_DIR=""
  if [[ "$PWD" =~ .*/tenants/([^/]+)$ ]]; then
    TENANT_DIR="$PWD"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    TENANT_DIR="$CORE_DIR/tenants/oxygen"
  fi

  # Build gemini args
  GEMINI_ARGS=()
  if [[ -n "$TENANT_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$TENANT_DIR")
  fi
  GEMINI_ARGS+=("--include-directories" "$CORE_DIR")

  # Add model flag if specified
  if [[ -n "$MODEL" ]]; then
    GEMINI_ARGS+=("-m" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi

  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi

  log_verbose "Invoking gemini CLI for skill (Tenant: ${TENANT_DIR:-none}, Model: ${MODEL:-default})"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    cat "$TMPFILE_PROMPT" | run_with_timeout "$CLI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    cat "$TMPFILE_PROMPT" | gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  GEMINI_EXIT=$?
  set -e

  rm -f "$TMPFILE_PROMPT"

  if [[ $GEMINI_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if declare -F classify_error >/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "" "$GEMINI_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  # Filter out Gemini CLI informational output before parsing
  RESPONSE_TEXT="$(filter_gemini_info_lines "$RESPONSE_TEXT")"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Try to extract JSON from code block
    JSON_BLOCK=$(echo "$RESPONSE_TEXT" | sed -n '/^```json/,/^```/p' | sed '1d;$d' 2>/dev/null || echo "")

    if [[ -n "$JSON_BLOCK" ]] && echo "$JSON_BLOCK" | jq empty 2>/dev/null; then
      RESPONSE_TEXT="$JSON_BLOCK"
    else
      # Strip markdown fences if present
      if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
        RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
      elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
        RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
      fi
    fi

    # Wrap in CLIResponse format
    emit_cli_response "$RESPONSE_TEXT" "" "$RESPONSE_TEXT" "skill" "$SKILL_NAME" "$STDERR_TEXT"
  else
    emit_cli_error_response "No response from skill execution: $SKILL_NAME" "provider_error" "" 1
  fi

  exit 0
fi

if [[ -f "${1-}" && "$1" == *.md ]]; then
  AGENT_FILE="$1"; shift

  # Resolve agent file path to absolute path
  # If it's already absolute, use as-is; otherwise resolve relative to CORE_DIR
  if [[ "$AGENT_FILE" = /* ]]; then
    AGENT_FILE_ABS="$AGENT_FILE"
  else
    AGENT_FILE_ABS="$CORE_DIR/$AGENT_FILE"
  fi

  # Validate agent file format before proceeding
  validate_agent_file "$AGENT_FILE_ABS"

  # Gather input data either from stdin or remaining args
  INPUT_DATA="$(parse_arg_json_or_stdin "$@")"

  log_verbose "Processing agent file: $AGENT_FILE_ABS"
  if [[ -n "$INPUT_DATA" ]]; then
    log_verbose "Input data received (length: ${#INPUT_DATA})"
  fi

  # Load context if specified
  CONTEXT_CONTENT=""
  RESOLVED_CONTEXT_FILE=""

  if [[ "$SKIP_CONTEXT_FILE" == "true" ]]; then
    log_verbose "Context loading disabled (--skip-context-file)"
  else
    # Priority: --context > --context-dir > auto-discover from input JSON
    if [[ -n "$CONTEXT_FILE" && -f "$CONTEXT_FILE" ]]; then
      RESOLVED_CONTEXT_FILE="$CONTEXT_FILE"
      log_verbose "Using explicit context file: $CONTEXT_FILE"
    elif [[ -n "$CONTEXT_DIR" ]]; then
      # Look for CONTEXT.md in specified directory
      if [[ -f "$CONTEXT_DIR/CONTEXT.md" ]]; then
        RESOLVED_CONTEXT_FILE="$CONTEXT_DIR/CONTEXT.md"
        log_verbose "Found context in specified dir: $RESOLVED_CONTEXT_FILE"
      else
        log_verbose "No CONTEXT.md found in $CONTEXT_DIR"
      fi
    elif [[ -n "$INPUT_DATA" ]]; then
      # Try to extract project_dir from input JSON for auto-discovery
      PROJECT_DIR_VAL="$(echo "$INPUT_DATA" | jq -r '.project_dir // empty' 2>/dev/null || true)"
      if [[ -n "$PROJECT_DIR_VAL" && -f "$PROJECT_DIR_VAL/CONTEXT.md" ]]; then
        RESOLVED_CONTEXT_FILE="$PROJECT_DIR_VAL/CONTEXT.md"
        log_verbose "Auto-discovered context from project_dir: $RESOLVED_CONTEXT_FILE"
      fi
    fi
  fi

  # Load and optionally truncate context
  if [[ "$SKIP_CONTEXT_FILE" != "true" && -n "$RESOLVED_CONTEXT_FILE" && -f "$RESOLVED_CONTEXT_FILE" ]]; then
    CONTEXT_SIZE=$(wc -c < "$RESOLVED_CONTEXT_FILE")
    if [[ $CONTEXT_SIZE -gt $CONTEXT_MAX ]]; then
      log_verbose "Context file exceeds max ($CONTEXT_SIZE > $CONTEXT_MAX), truncating..."
      CONTEXT_CONTENT=$(head -c "$CONTEXT_MAX" "$RESOLVED_CONTEXT_FILE")
      CONTEXT_CONTENT="$CONTEXT_CONTENT

[... CONTEXT TRUNCATED - exceeded ${CONTEXT_MAX} bytes ...]"
    else
      CONTEXT_CONTENT=$(cat "$RESOLVED_CONTEXT_FILE")
    fi
    log_verbose "Loaded context (${#CONTEXT_CONTENT} bytes) from $RESOLVED_CONTEXT_FILE"
  fi

  # Derive persona id
  # Priority: --persona flag > persona in JSON > fallback to first persona in agent file
  PERSONA_ID="$PERSONA_OVERRIDE"

  if [[ -z "$PERSONA_ID" && -n "$INPUT_DATA" ]]; then
    # Try to read persona from JSON input (for backwards compatibility)
    PERSONA_ID="$(echo "$INPUT_DATA" | jq -r '.persona // empty' 2>/dev/null || true)"
  fi

  if [[ -z "$PERSONA_ID" ]]; then
    # Fallback: extract first persona from agent file (for direct CLI usage/testing)
    PERSONA_ID="$(grep -E '^##+[[:space:]]+Persona:[[:space:]]+' "$AGENT_FILE_ABS" | head -1 | sed 's/^##*[[:space:]]*Persona:[[:space:]]*//' | awk '{print $1}')"
    log_verbose "No persona specified, using first persona from agent file: $PERSONA_ID"
  fi

  if [[ -z "$PERSONA_ID" ]]; then
    echo "{\"error\":\"no persona found - specify via --persona flag or ensure agent file has Persona headers\"}"
    exit 2
  fi

  log_verbose "Persona selected: $PERSONA_ID"

  # Extract only the chosen persona block
  AGENT_PROMPT="$(extract_persona_block "$AGENT_FILE_ABS" "$PERSONA_ID")"

  if [[ -z "$AGENT_PROMPT" ]]; then
    emit_cli_error_response "persona '$PERSONA_ID' not found in agent file" "invalid_input" "" 2
    exit 2
  fi

  # Build conditional tool rules based on --allowed-tools flag (same pattern as claude.sh)
  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    TOOL_RULES="- You MUST actually CREATE/MODIFY files as specified in the design plan
- Use your file writing capabilities to create each file with proper content
- After creating files, respond with a JSON summary of what you implemented
- DO NOT just describe what files should contain - ACTUALLY WRITE THEM
- The working directory is the project root - create files with the correct relative paths
- You MAY use available MCP tools (file, browser, tests) to inspect and verify your work
- Use verification tools after code changes to ensure correctness"
    log_verbose "Tools ENABLED for this invocation"
    MCP_CONFIG_PATH="$(get_gemini_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_gemini_mcp_servers "$MCP_CONFIG_PATH"
      mapfile -t MCP_SERVER_NAMES < <(jq -r '.mcpServers | keys[]' "$MCP_CONFIG_PATH" 2>/dev/null || true)
    fi
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions to prevent gemini from responding to persona
  # OPTIMIZATION: When resuming a session, skip persona (already in context) to save tokens
  if [[ -n "${INPUT_DATA}" ]]; then
    if [[ -n "$SESSION_ID" ]]; then
      # RESUME MODE: Session already has persona context - send only task data
      log_verbose "Resume mode: skipping persona (already in session context)"
      if [[ -n "$CONTEXT_CONTENT" ]]; then
        BASE_PROMPT="CONTINUATION - You are resuming from a previous session. Your role and persona are already established.

PROJECT CONTEXT UPDATE:
$CONTEXT_CONTENT

---

Input Data (YOUR NEXT TASK):
$INPUT_DATA"
        CRITICAL_SUFFIX="

---

CRITICAL INSTRUCTIONS:
$TOOL_RULES
- Continue in your established role from the session
- Use the PROJECT CONTEXT above to inform your response
- Assess the task based on the input data and context provided
- Respond immediately with your assessment
- Return ONLY valid JSON matching the schema - no markdown, no explanations, no questions"
      else
        BASE_PROMPT="CONTINUATION - You are resuming from a previous session. Your role and persona are already established.

Input Data (YOUR NEXT TASK):
$INPUT_DATA"
        CRITICAL_SUFFIX="

---

CRITICAL INSTRUCTIONS:
$TOOL_RULES
- Continue in your established role from the session
- Assess the task based on the input data provided above
- Respond immediately with your assessment
- Return ONLY valid JSON matching the schema - no markdown, no explanations, no questions"
      fi
    elif [[ -n "$CONTEXT_CONTENT" ]]; then
      # NEW SESSION with context
      BASE_PROMPT="INSTRUCTIONS: The following sections contain your role definition and project context. Use the project context to understand the codebase, coding standards, and architecture. Do NOT respond to these instructions - wait for the task data.

---

$AGENT_PROMPT

---

PROJECT CONTEXT (use this to inform your work):
$CONTEXT_CONTENT

---

Input Data (YOUR ACTUAL TASK):
$INPUT_DATA"
      CRITICAL_SUFFIX="

---

CRITICAL INSTRUCTIONS:
$TOOL_RULES
- Do NOT treat file paths in the persona as files to open
- Use the PROJECT CONTEXT above to inform your response
- Assess the task based on the input data and context provided
- Respond immediately with your assessment
- Return ONLY valid JSON matching the schema - no markdown, no explanations, no questions"
    else
      # NEW SESSION without context - original behavior
      BASE_PROMPT="INSTRUCTIONS: The following section contains your role and persona definition. Acknowledge these instructions silently and wait for the task data that follows. Do NOT respond to this persona definition itself.

---

$AGENT_PROMPT

---

Input Data (YOUR ACTUAL TASK):
$INPUT_DATA"
      CRITICAL_SUFFIX="

---

CRITICAL INSTRUCTIONS:
$TOOL_RULES
- Do NOT treat file paths in the persona as files to open
- Assess the proposal based ONLY on the input data provided above
- Respond immediately with your assessment
- Return ONLY valid JSON matching the schema - no markdown, no explanations, no questions"
    fi
    FULL_PROMPT="${BASE_PROMPT}${CRITICAL_SUFFIX}"
  else
    FULL_PROMPT="$AGENT_PROMPT"
  fi

  # P2.1: Check prompt size and log warnings
  if type check_prompt_size &>/dev/null; then
    check_prompt_size "$FULL_PROMPT" "gemini"
    PROMPT_OVER_LIMIT=$?

    # Save debug prompt if enabled
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "gemini"
    fi

    # Log stats in verbose mode
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "gemini")
      log_verbose "Prompt stats: $PROMPT_STATS"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_verbose "DRY-RUN MODE: Skipping actual CLI call"

    MOCK_RESPONSE="{
  \"dry_run\": true,
  \"wrapper\": \"gemini.sh\",
  \"persona\": \"$PERSONA_ID\",
  \"agent_file\": \"$AGENT_FILE_ABS\",
  \"validation\": \"passed\",
  \"message\": \"Dry-run validation successful - no actual CLI call made\"
}"
    echo "$MOCK_RESPONSE"
    log_verbose "Dry-run completed successfully"
    exit 0
  fi

  # Create a temporary file for the prompt
  TMPFILE_PROMPT="$(mktemp)"
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Resolve tenant/workspace roots for agent mode:
  # precedence: CONTEXT_DIR > TENANT_DIR > core fallback.
  TENANT_DIR=""
  if [[ -n "$CONTEXT_DIR" && "$CONTEXT_DIR" =~ ^(.*/tenants/[^/]+)($|/) ]]; then
    TENANT_DIR="${BASH_REMATCH[1]}"
  elif [[ "$PWD" =~ ^(.*/tenants/[^/]+)($|/) ]]; then
    TENANT_DIR="${BASH_REMATCH[1]}"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    TENANT_DIR="$CORE_DIR/tenants/oxygen"
  elif [[ -d "$CORE_DIR/tenants" ]]; then
    TENANT_DIR="$(find "$CORE_DIR/tenants" -maxdepth 1 -type d ! -name tenants | head -1)"
  fi

  WORKSPACE_DIR="$CORE_DIR"
  WORKSPACE_SOURCE="core_fallback"
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORKSPACE_DIR="$CONTEXT_DIR"
    WORKSPACE_SOURCE="context_dir"
  elif [[ -n "$TENANT_DIR" && -d "$TENANT_DIR" ]]; then
    WORKSPACE_DIR="$TENANT_DIR"
    WORKSPACE_SOURCE="tenant_dir"
  fi
  log_verbose "Resolved workspace: ${WORKSPACE_DIR} (source: ${WORKSPACE_SOURCE})"

  # O-6: Set up agent stream logging for per-ticket LLM output capture
  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "${WORKSPACE_DIR:-}" ]]; then
    AGENT_LOG_DIR="${WORKSPACE_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: $A8_TICKET_ID | Workflow: $A8_WORKFLOW | Provider: gemini" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "O-6: Agent stream logging to $AGENT_LOG"
  fi

  echo "$FULL_PROMPT" > "$TMPFILE_PROMPT"

  # Use JSON schema to enforce structured output
  SCHEMA_ARG=""
  # For PO stories task, use stories schema; for PM tasks, use PM schema
  if [[ "${TASK_VAL:-}" == "stories" || "${TASK_VAL:-}" == "story" || "${AGENT_TYPE:-}" == "po" ]]; then
    SCHEMA_PATH="$CORE_DIR/bin/po-stories-schema.json"
    if [[ -f "$SCHEMA_PATH" ]]; then
      SCHEMA_ARG="--output-schema $SCHEMA_PATH"
    fi
  elif [[ "${TASK_VAL:-}" == "plan" || "${TASK_VAL:-}" == "proposal" || "${TASK_VAL:-}" == "review" ]]; then
    SCHEMA_PATH="$CORE_DIR/bin/pm-assessment-schema.json"
    if [[ -f "$SCHEMA_PATH" ]]; then
      SCHEMA_ARG="--output-schema $SCHEMA_PATH"
    fi
  fi

  # Ensure agent-mode execution occurs from resolved workspace root.
  if [[ -n "$WORKSPACE_DIR" && -d "$WORKSPACE_DIR" ]]; then
    cd "$WORKSPACE_DIR"
  fi

  # Add session args for session persistence
  # --session-id: Resume existing session (Gemini uses index-based sessions)
  # --manage-session: Create new session (we'll get the actual index after running)
  GEMINI_SESSION_ID=""
  CREATING_NEW_SESSION=false

  if [[ -n "$SESSION_ID" ]]; then
    # Validate session exists before attempting to resume
    # Gemini sessions are scoped to working directory
    if validate_gemini_session "$SESSION_ID" "$PWD"; then
      GEMINI_ARGS+=("--resume" "$SESSION_ID")
      GEMINI_SESSION_ID="$SESSION_ID"
      log_verbose "Resuming session: $SESSION_ID"
    else
      log_verbose "Session $SESSION_ID not found, starting fresh session"
      # Fall through to create new session behavior
      CREATING_NEW_SESSION=true
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    # For new sessions, Gemini auto-creates when we don't use --resume.
    # Track the caller-provided managed session ID deterministically so
    # parallel lanes don't race on "latest session" lookup.
    CREATING_NEW_SESSION=true
    GEMINI_SESSION_ID="$MANAGE_SESSION"
    log_verbose "Creating new managed session (tracking ID: $GEMINI_SESSION_ID)"
  fi

  # Check if gemini supports -o flag and schema (similar to claude/codex)
  # If not supported, we'll capture output differently
  # For now, assume gemini outputs to stdout
  GEMINI_INVALID_MODEL_RETRIED=false
  GEMINI_CAPACITY_RETRIED=false
  while true; do
  GEMINI_ARGS=()
  if [[ -n "$WORKSPACE_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$WORKSPACE_DIR")
  fi
  if [[ -n "$TENANT_DIR" && "$TENANT_DIR" != "$WORKSPACE_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$TENANT_DIR")
  fi
  if [[ -n "$CORE_DIR" && "$CORE_DIR" != "$WORKSPACE_DIR" && "$CORE_DIR" != "$TENANT_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$CORE_DIR")
  fi
  if [[ -n "$TEMPERATURE" ]]; then
    GEMINI_ARGS+=("--temp" "$TEMPERATURE")
    log_verbose "Temperature specified: $TEMPERATURE (via --temp flag)"
  fi
  if [[ -n "$MODEL" ]]; then
    GEMINI_ARGS+=("-m" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi
  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi
  if [[ "$ALLOW_TOOLS" == "true" && ${#MCP_SERVER_NAMES[@]} -gt 0 ]]; then
    GEMINI_ARGS+=("--allowed-mcp-server-names" "${MCP_SERVER_NAMES[@]}")
  fi
  log_verbose "Invoking gemini CLI (Workspace: ${WORKSPACE_DIR:-none}, Tenant: ${TENANT_DIR:-none}, YOLO: $YOLO_MODE, Model: ${MODEL:-default})"
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running gemini with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$AGENT_LOG" ]]; then
      cat "$TMPFILE_PROMPT" | run_with_timeout "$CLI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      cat "$TMPFILE_PROMPT" | run_with_timeout "$CLI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
    GEMINI_EXIT=$?
  else
    if [[ -n "$AGENT_LOG" ]]; then
      cat "$TMPFILE_PROMPT" | gemini "${GEMINI_ARGS[@]}" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      cat "$TMPFILE_PROMPT" | gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
    GEMINI_EXIT=$?
  fi
  set -e

  # O-9: Append stdout response to agent log (stderr tee only captures progress/errors,
  # gemini sends the actual response to stdout which may be missing from logs)
  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  # Capture session ID for fresh successful calls when no managed session ID
  # has already been assigned by caller context.
  if [[ -z "$GEMINI_SESSION_ID" && $GEMINI_EXIT -eq 0 ]]; then
    # Gemini sessions are scoped to the directory where gemini was invoked
    # Since we run gemini from the script's working directory (PWD), look there
    # Note: --include-directories doesn't change where sessions are stored
    WORK_DIR="$PWD"

    # Get the latest session index (the one we just created)
    GEMINI_SESSION_ID="$(get_latest_gemini_session "$WORK_DIR" || true)"
    if [[ -n "$GEMINI_SESSION_ID" ]]; then
      log_verbose "New session created with index: $GEMINI_SESSION_ID"
    else
      log_verbose "Could not determine new session index"
    fi
  fi

  if [[ $GEMINI_EXIT -ne 0 ]]; then
    # Gemini failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    log_verbose "Gemini execution failed: $ERROR_MSG"

    if [[ "$GEMINI_INVALID_MODEL_RETRIED" != "true" ]] && declare -F is_invalid_model_error >/dev/null && is_invalid_model_error "$ERROR_MSG"; then
      REQUESTED_MODEL_LABEL="${MODEL_REQUESTED_RAW:-$MODEL}"
      GEMINI_INVALID_MODEL_RETRIED=true
      MODEL=""
      MODEL_RESOLUTION_NOTE="gemini model '$REQUESTED_MODEL_LABEL' -> 'provider-default' (fallback)"
      log_info "Invalid model '$REQUESTED_MODEL_LABEL' for gemini; retrying with provider default"
      : > "$TMPFILE_OUTPUT"
      : > "$TMPFILE_ERR"
      continue
    fi

    if is_gemini_capacity_error "$ERROR_MSG"; then
      CURRENT_MODEL_LABEL="${MODEL:-provider-default}"
      if retry_with_gemini_capacity_fallback "$CURRENT_MODEL_LABEL" >/dev/null; then
        log_info "Gemini model '$CURRENT_MODEL_LABEL' hit capacity; retrying with gemini-2.5-flash"
        : > "$TMPFILE_OUTPUT"
        : > "$TMPFILE_ERR"
        continue
      fi
    fi

    # Check if this is an invalid session error - fail fast, don't retry
    if echo "$ERROR_MSG" | grep -qi "Invalid session identifier"; then
      log_verbose "Invalid session detected - clearing stale session"
      rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
      emit_cli_error_response "$ERROR_MSG" "invalid_session" "$SESSION_ID" "$GEMINI_EXIT"
      exit 1
    fi

    # Check if this is a usage limit error
    if echo "$ERROR_MSG" | grep -qi "usage limit\|out of.*messages\|out of.*credits\|purchase more credits\|quota.*exceeded"; then
      # Extract retry time if available (e.g., "try again at 6:13 PM")
      RETRY_TIME=$(echo "$ERROR_MSG" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")

      # Create system message for usage limit
      SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
      mkdir -p "$SYSTEM_MSG_DIR"

      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      MSG_FILE="$SYSTEM_MSG_DIR/$(date +%s)-gemini-usage-limit.json"

      jq -n \
        --arg ts "$TIMESTAMP" \
        --arg cli "gemini" \
        --arg error "$ERROR_MSG" \
        --arg retry "$RETRY_TIME" \
        '{
          timestamp: $ts,
          type: "usage_limit",
          cli: $cli,
          error: $error,
          retry_time: $retry,
          severity: "warning",
          action_required: "Purchase more credits or wait for quota reset"
        }' > "$MSG_FILE"
    fi

    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    CLASSIFIED_ERROR_TYPE=""
    if [[ -z "$GEMINI_SESSION_ID" ]]; then
      GEMINI_SESSION_ID="$(get_latest_gemini_session "$PWD" 2>/dev/null || true)"
    fi
    if declare -F classify_error >/dev/null; then
      CLASSIFIED_ERROR_TYPE="$(classify_error "$ERROR_MSG")"
    fi
    if [[ "$GEMINI_EXIT" -eq 124 ]]; then
      if [[ -n "$CLASSIFIED_ERROR_TYPE" && "$CLASSIFIED_ERROR_TYPE" != "unknown" && "$CLASSIFIED_ERROR_TYPE" != "timeout" ]]; then
        ERROR_TYPE="$CLASSIFIED_ERROR_TYPE"
      else
      ERROR_TYPE="timeout"
      fi
    elif [[ -n "$CLASSIFIED_ERROR_TYPE" ]]; then
      ERROR_TYPE="$CLASSIFIED_ERROR_TYPE"
    fi
    ERROR_EMIT_MSG="$ERROR_MSG"
    if [[ "$ERROR_TYPE" == "timeout" ]] && is_gemini_startup_only_error "$ERROR_MSG"; then
      ERROR_EMIT_MSG="Gemini timed out without terminal output after startup."
    fi
    if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
      emit_cli_error_response "$ERROR_EMIT_MSG" "$ERROR_TYPE" "$GEMINI_SESSION_ID" "$GEMINI_EXIT" "model_resolution" "$MODEL_RESOLUTION_NOTE"
    else
      emit_cli_error_response "$ERROR_EMIT_MSG" "$ERROR_TYPE" "$GEMINI_SESSION_ID" "$GEMINI_EXIT"
    fi
    exit 1
  fi
  break
  done
  rm -f "$TMPFILE_PROMPT"

  # Read the output which should contain the response
  RAW_RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"

  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  # Filter out Gemini CLI informational output before parsing
  # Gemini outputs "YOLO mode is enabled..." and similar to stdout
  RESPONSE_TEXT="$(filter_gemini_info_lines "$RAW_RESPONSE_TEXT")"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Try to extract JSON from the response (gemini may wrap it in markdown)
    # First try to extract JSON code block
    JSON_BLOCK=$(echo "$RESPONSE_TEXT" | sed -n '/^```json/,/^```/p' | sed '1d;$d' 2>/dev/null || echo "")
    
    FINAL_RESPONSE=""
    if [[ -n "$JSON_BLOCK" ]]; then
      # Found JSON in code block
      if echo "$JSON_BLOCK" | jq empty 2>/dev/null; then
        FINAL_RESPONSE="$JSON_BLOCK"
      fi
    fi
    
    if [[ -z "$FINAL_RESPONSE" ]]; then
      # No code block or invalid, try the raw response
      # Strip any markdown fences first just in case
      CLEAN_TEXT=$(echo "$RESPONSE_TEXT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
      if echo "$CLEAN_TEXT" | jq empty 2>/dev/null; then
        FINAL_RESPONSE="$CLEAN_TEXT"
      fi
    fi
    
    if [[ -n "$FINAL_RESPONSE" ]]; then
        # Wrap in CLIResponse format for Go worker
        # Include session_id if a session was used or created
        if [[ -n "$GEMINI_SESSION_ID" ]]; then
          # Session was resumed or created - use the actual session index
          if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
            emit_cli_response "$FINAL_RESPONSE" "$GEMINI_SESSION_ID" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
          else
            emit_cli_response "$FINAL_RESPONSE" "$GEMINI_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
          fi
        else
          if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
            emit_cli_response "$FINAL_RESPONSE" "" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
          else
            emit_cli_response "$FINAL_RESPONSE" "" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
          fi
        fi
    else
        # Not valid JSON - wrap raw text in response, include session_id if available
        if [[ -n "$GEMINI_SESSION_ID" ]]; then
          if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
            emit_cli_response "$RESPONSE_TEXT" "$GEMINI_SESSION_ID" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
          else
            emit_cli_response "$RESPONSE_TEXT" "$GEMINI_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
          fi
        else
          if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
            emit_cli_response "$RESPONSE_TEXT" "" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
          else
            emit_cli_response "$RESPONSE_TEXT" "" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
          fi
        fi
    fi
  else
    NO_RESPONSE_INFO="$(build_gemini_no_response_error "$RAW_RESPONSE_TEXT" "$STDERR_TEXT" "$RESPONSE_TEXT")"
    NO_RESPONSE_TYPE="${NO_RESPONSE_INFO%%$'\t'*}"
    NO_RESPONSE_MSG="${NO_RESPONSE_INFO#*$'\t'}"
    if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
      emit_cli_error_response "$NO_RESPONSE_MSG" "$NO_RESPONSE_TYPE" "$GEMINI_SESSION_ID" 1 "model_resolution" "$MODEL_RESOLUTION_NOTE"
    else
      emit_cli_error_response "$NO_RESPONSE_MSG" "$NO_RESPONSE_TYPE" "$GEMINI_SESSION_ID" 1
    fi
  fi
else
  # Direct invocation with text prompt

  # Determine tenant directory for direct invocation
  TENANT_DIR=""
  if [[ "$PWD" =~ .*/tenants/([^/]+)$ ]]; then
    TENANT_DIR="$PWD"
  elif [[ -d "$CORE_DIR/tenants" ]]; then
    if [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
      TENANT_DIR="$CORE_DIR/tenants/oxygen"
    else
      TENANT_DIR=$(find "$CORE_DIR/tenants" -maxdepth 1 -type d ! -name tenants | head -1)
    fi
  fi

  # Build gemini args
  GEMINI_ARGS=()
  if [[ -n "$TENANT_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$TENANT_DIR")
  fi
  GEMINI_ARGS+=("--include-directories" "$CORE_DIR")

  # Add model flag if specified
  if [[ -n "$MODEL" ]]; then
    GEMINI_ARGS+=("-m" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi

  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi

  log_verbose "Running in direct invocation mode (Model: ${MODEL:-default})"
  gemini "${GEMINI_ARGS[@]}" "$@"
fi
