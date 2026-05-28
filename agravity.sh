#!/usr/bin/env bash
# Antigravity CLI wrapper for Autonom8
# Wraps the `agy` CLI (Google Antigravity) under the unified AI-CLI-Wrappers interface.

set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

WRAPPER_REQ_ID="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-}}"
if [[ -n "${WRAPPER_REQ_ID}" ]]; then
  exec 3>&2
  exec 2> >(while IFS= read -r __a8_line; do
    printf '[req=%s] %s\n' "${WRAPPER_REQ_ID}" "${__a8_line}" >&3
  done)
fi

# Track child process PID for cleanup on script termination
AGRAVITY_PID=""
TMPFILE_OUTPUT=""
TMPFILE_ERR=""
CLI_TIMEOUT=""
RESPONSE_EMITTED=false
AGRAVITY_AUTH_MODE="${AUTONOM8_ANTIGRAVITY_AUTH_MODE:-${AUTONOM8_PROVIDER_AUTH_MODE:-auto}}"

TOOL_TELEMETRY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/tool-telemetry.sh"
if [[ -f "$TOOL_TELEMETRY_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$TOOL_TELEMETRY_LIB"
fi
if ! declare -F autonom8_tool_activity_json >/dev/null; then
  autonom8_tool_activity_json() { jq -cn '{call_count:0, write_count:0, error_count:0, tool_names:[], result_classes:[], activity_class:"none", source:"unavailable"}'; }
fi
if ! declare -F autonom8_merge_tool_activity >/dev/null; then
  autonom8_merge_tool_activity() { cat; }
fi
WRAPPER_LIFECYCLE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/wrapper-lifecycle.sh"
if [[ -f "$WRAPPER_LIFECYCLE_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$WRAPPER_LIFECYCLE_LIB"
fi

# Antigravity's model is configured via ~/.gemini/antigravity-cli/settings.json, not via a CLI flag.
# We accept --model from the caller for interface compatibility but only record it as informational.
AGRAVITY_MODEL=""

# Antigravity CLI state directories
AGRAVITY_HOME="${AGRAVITY_HOME:-$HOME/.gemini/antigravity-cli}"
AGRAVITY_CONVERSATIONS_DIR="$AGRAVITY_HOME/conversations"
AGRAVITY_BRAIN_DIR="$AGRAVITY_HOME/brain"
AGRAVITY_SETTINGS_FILE="$AGRAVITY_HOME/settings.json"

cleanup() {
  if declare -F autonom8_wrapper_write_cleanup_event >/dev/null; then
    autonom8_wrapper_write_cleanup_event "antigravity" "${AGRAVITY_PID:-}" "${WORK_DIR:-${WORKSPACE_DIR:-$(pwd)}}" "wrapper_cleanup"
  fi
  if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
    autonom8_wrapper_stop_parent_monitor
  fi
  if declare -F autonom8_wrapper_reap_child_tree >/dev/null; then
    autonom8_wrapper_reap_child_tree "antigravity" "${AGRAVITY_PID:-}" "${WORK_DIR:-${WORKSPACE_DIR:-$(pwd)}}" "wrapper_cleanup"
  elif [[ -n "$AGRAVITY_PID" ]] && kill -0 "$AGRAVITY_PID" 2>/dev/null; then
    kill "$AGRAVITY_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$AGRAVITY_PID" 2>/dev/null || true
  fi
  pkill -P $$ 2>/dev/null || true
  if declare -F autonom8_stop_live_monitor >/dev/null 2>&1; then
    autonom8_stop_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" 2>/dev/null || true
  fi
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

resolve_agy_cmd() {
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
  done < <(which -a agy 2>/dev/null | awk '!seen[$0]++')

  return 1
}

AGRAVITY_BIN="$(resolve_agy_cmd || true)"

agravity_api_key_env_present() {
  # Antigravity is Google's; honor the same envs that gemini.sh checks.
  [[ -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" || -n "${ANTIGRAVITY_API_KEY:-}" ]]
}

agy() {
  if [[ -z "${AGRAVITY_BIN:-}" ]]; then
    return 127
  fi
  "$AGRAVITY_BIN" "$@"
}

run_with_timeout() {
  local timeout_secs="$1"
  shift

  local timeout_cmd=""
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout"
  elif command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout"
  fi

  if [[ -n "$timeout_cmd" ]]; then
    "$timeout_cmd" --signal=TERM --kill-after=5 "$timeout_secs" "$@" &
    local pid=$!
    AGRAVITY_PID=$pid
    if declare -F autonom8_wrapper_monitor_parent >/dev/null; then
      autonom8_wrapper_monitor_parent "$pid" "antigravity" "${WORK_DIR:-${WORKSPACE_DIR:-$(pwd)}}"
    fi

    wait $pid
    local exit_code=$?
    if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
      autonom8_wrapper_stop_parent_monitor
    fi
    AGRAVITY_PID=""
    return $exit_code
  else
    local stdin_tmp=""
    if [[ ! -t 0 ]]; then
      stdin_tmp="$(mktemp)"
      cat > "$stdin_tmp"
    fi

    if [[ -n "$stdin_tmp" ]]; then
      "$@" < "$stdin_tmp" &
    else
      "$@" &
    fi
    local pid=$!
    AGRAVITY_PID=$pid
    if declare -F autonom8_wrapper_monitor_parent >/dev/null; then
      autonom8_wrapper_monitor_parent "$pid" "antigravity" "${WORK_DIR:-${WORKSPACE_DIR:-$(pwd)}}"
    fi

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
        autonom8_wrapper_stop_parent_monitor
      fi
      AGRAVITY_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
        autonom8_wrapper_stop_parent_monitor
      fi
      AGRAVITY_PID=""
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

# Return path to the transcript.jsonl for a given Antigravity conversation UUID.
agravity_transcript_path() {
  local sid="${1:-}"
  [[ -z "$sid" ]] && return 1
  local path="$AGRAVITY_BRAIN_DIR/$sid/.system_generated/logs/transcript.jsonl"
  [[ -f "$path" ]] && printf "%s" "$path" && return 0
  return 1
}

# Discover the most recently updated Antigravity conversation UUID.
get_latest_agravity_session() {
  [[ -d "$AGRAVITY_CONVERSATIONS_DIR" ]] || return 1
  local latest=""
  latest="$(ls -t "$AGRAVITY_CONVERSATIONS_DIR"/*.pb 2>/dev/null | head -1 || true)"
  [[ -z "$latest" ]] && return 1
  local base=""
  base="$(basename "$latest" .pb)"
  # Conversation IDs are UUIDs; sanity-check the shape.
  if [[ "$base" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    printf "%s" "$base"
    return 0
  fi
  return 1
}

# Antigravity does not emit usage metadata. We synthesize an estimated-only payload
# so downstream consumers still see a normalized object.
get_agravity_session_token_usage() {
  local sid="$1"
  local path=""
  path="$(agravity_transcript_path "$sid" 2>/dev/null || true)"
  [[ -z "$path" ]] && return 1

  # Estimate based on transcript byte size; rough char/4 heuristic.
  local bytes
  bytes="$(wc -c < "$path" 2>/dev/null | tr -d ' ' || echo 0)"
  [[ -z "$bytes" || "$bytes" == "0" ]] && return 1
  local estimated_total=$((bytes / 4))
  [[ $estimated_total -le 0 ]] && return 1

  jq -n \
    --argjson total "$estimated_total" \
    '{input_tokens:0,output_tokens:0,total_tokens:$total,cost_usd:0,estimated:true}'
}

# Extract the most recent assistant `thinking` block from the transcript.
get_agravity_session_reasoning() {
  local sid="$1"
  local path=""
  path="$(agravity_transcript_path "$sid" 2>/dev/null || true)"
  [[ -z "$path" ]] && return 1

  local text=""
  text="$(jq -r '
    select(.source == "MODEL" and (.thinking // "") != "")
    | .thinking
  ' "$path" 2>/dev/null | tail -n 1 || true)"

  [[ -z "$text" || "$text" == "null" ]] && return 1
  printf "%s" "$text"
}

# Stream every transcript step that mentions tool_calls as a synthetic JSON event
# the shared telemetry library can recognize via the `tool_calls[]` shape.
get_agravity_session_tool_events() {
  local sid="$1"
  local path=""
  path="$(agravity_transcript_path "$sid" 2>/dev/null || true)"
  [[ -z "$path" ]] && return 1

  jq -c '
    select((.tool_calls // []) | length > 0)
    | {time_created: .created_at, tool_calls: .tool_calls, status: .status}
  ' "$path" 2>/dev/null || true
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

  # Antigravity does not emit JSON, but if a caller piped raw JSON through
  # raw_output (skill-mode), still try to parse usage from it.
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
    session_tokens="$(get_agravity_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      # Marked estimated; flag as available only if some non-zero total surfaced.
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.total_tokens // 0) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
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
    session_reasoning="$(get_agravity_session_reasoning "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_reasoning" ]]; then
      reasoning_text="$session_reasoning"
      reasoning_source="session_assistant"
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
      grep -ivE 'shell cwd was reset|using model|timeout|loaded cached credentials|yolo mode|tokens used|tool call|session id|debug:' | \
      tail -n 20 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//' || true)"
    if [[ -n "$stream_reasoning" ]]; then
      reasoning_text="$stream_reasoning"
      reasoning_source="stream_log"
    fi
  fi

  if [[ -n "$reasoning_text" ]]; then
    reasoning_text="$(compact_reasoning_text "$reasoning_text")"
    # Cap at 600 chars (matches README contract).
    if [[ ${#reasoning_text} -gt 600 ]]; then
      reasoning_text="${reasoning_text:0:600}"
    fi
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

  local tool_activity_input="$raw_output"
  if [[ -n "$session_id" ]]; then
    local session_tool_events
    session_tool_events="$(get_agravity_session_tool_events "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tool_events" ]]; then
      tool_activity_input="${tool_activity_input}"$'\n'"${session_tool_events}"
    fi
  fi
  local tool_activity_json
  tool_activity_json="$(autonom8_tool_activity_json "$tool_activity_input" "$stream_output" "wrapper:antigravity")"

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
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
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
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
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
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
  else
    jq -n \
      --arg resp "$response_text" \
      --arg reasoning "$reasoning_text" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
  fi
}

emit_cli_error_response() {
  local error_msg="$1"
  local error_type="${2:-unknown}"
  local session_id="${3:-}"
  local exit_code="${4:-1}"
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
    local session_reasoning=""
    session_reasoning="$(get_agravity_session_reasoning "$session_id" 2>/dev/null || true)"
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
      }' \
      | autonom8_merge_tool_activity "{}"
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
      }' \
      | autonom8_merge_tool_activity "{}"
  fi
}

log_verbose() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*" >&2
    fi
}

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] WARN: $*" >&2
}

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] INFO: $*" >&2
}

# Build conversation/continue args for `agy`. SESSION_ID may be a UUID (resume)
# or a caller-managed logical id (we ignore and let agy start fresh).
build_session_args() {
  if [[ -n "$SESSION_ID" ]]; then
    if [[ "$SESSION_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      log_verbose "Resuming Antigravity conversation: $SESSION_ID"
      printf "%s" "--conversation=$SESSION_ID"
    else
      log_verbose "Managed logical session requested by caller: $SESSION_ID (starting fresh; discovering Antigravity conversation id after run)"
    fi
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

resolve_agent_markdown_path() {
  local candidate="${1:-}"
  [[ "$candidate" == *.md ]] || return 1

  local stripped_core="${candidate#Autonom8-core/}"
  local after_agents="${candidate#*agents/}"
  local paths=(
    "$candidate"
    "$CORE_DIR/$candidate"
    "$CORE_DIR/$stripped_core"
  )
  if [[ "$after_agents" != "$candidate" ]]; then
    paths+=("$CORE_DIR/agents/$after_agents")
  fi

  local path
  for path in "${paths[@]}"; do
    if [[ -f "$path" ]]; then
      printf "%s" "$path"
      return 0
    fi
  done
  return 1
}

is_agent_markdown_arg() {
  resolve_agent_markdown_path "${1:-}" >/dev/null 2>&1
}

# =============================================================================
# Prompt Utilities (Antigravity / Gemini context ~ large; conservative limits)
# =============================================================================
PROMPT_MAX_CHARS=200000
PROMPT_WARN_THRESHOLD=160000

check_prompt_size() {
    local prompt="$1"
    local provider="${2:-antigravity}"
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
    local provider="${2:-antigravity}"
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
    local provider="${3:-antigravity}"
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

if [[ -f "$SCRIPT_DIR/lib/error_utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/error_utils.sh"
fi
if [[ -f "$SCRIPT_DIR/lib/model_utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/model_utils.sh"
fi
if [[ -f "$SCRIPT_DIR/lib/live-monitor.sh" ]]; then
    source "$SCRIPT_DIR/lib/live-monitor.sh"
fi

MODEL_REQUESTED_RAW=""
MODEL_RESOLUTION_NOTE=""
MODEL_PREPARED_VALUE=""

# Antigravity has no `--model` flag; the active model is selected via the CLI's
# settings.json. We still resolve the caller's requested alias against the
# provider config so model_resolution surfaces what was asked vs what we honored.
prepare_requested_model_value() {
  local provider="${1:-}"
  local requested="${2:-}"

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

  local resolved="$MODEL_REQUESTED_RAW"
  if declare -F resolve_requested_model_for_provider >/dev/null; then
    resolved="$(resolve_requested_model_for_provider "$provider" "$MODEL_REQUESTED_RAW" 2>/dev/null || printf "%s" "$MODEL_REQUESTED_RAW")"
  fi

  if [[ "$resolved" != "$MODEL_REQUESTED_RAW" ]] && declare -F build_model_resolution_summary >/dev/null; then
    MODEL_RESOLUTION_NOTE="$(build_model_resolution_summary "$provider" "$MODEL_REQUESTED_RAW" "$resolved" "normalized")"
  fi

  MODEL_PREPARED_VALUE="$resolved"
}

validate_agent_file() {
  local file="$1"
  if ! grep -qE '^##+[[:space:]]+Persona:' "$file"; then
    emit_cli_error_response "Invalid agent file format: Missing ## Persona:/### Persona: header in $file" "invalid_input" "" 3
    exit 3
  fi
  if ! awk '/^##+[[:space:]]+Persona:/{count++} END{exit (count>=1)?0:1}' "$file"; then
    emit_cli_error_response "Invalid agent file format: No valid persona blocks detected in $file" "invalid_input" "" 3
    exit 3
  fi
}

extract_persona_block() {
  local file="$1"
  local persona_id="$2"
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      gsub(/[[:space:]]*$/, "", hdr)
      if(hdr == id){found=1; print $0; next}
      if(index(id, "(") == 0) {
        split(hdr,a," ")
        if(a[1]==id){found=1; print $0; next}
      }
    }
    found{print}
  ' "$file"
}

parse_arg_json_or_stdin() {
  if [ ! -t 0 ]; then
    cat
  else
    printf "%s" "$*"
  fi
}

append_image_prompt_context() {
  local prompt="$1"
  if [[ ${#IMAGE_PATHS[@]} -eq 0 ]]; then
    printf "%s" "$prompt"
    return 0
  fi

  printf "%s\n\n---\n\nIMAGE ATTACHMENTS:\n" "$prompt"
  local image_path
  for image_path in "${IMAGE_PATHS[@]}"; do
    printf -- "- %s\n" "$image_path"
  done
  printf "\nUse these local image file paths as the attached visual references for this task.\n"
}

# Initialize flags
PERSONA_OVERRIDE=""
YOLO_MODE=false
VERBOSE=false
CONTEXT_FILE=""
CONTEXT_DIR=""
CONTEXT_MAX=51200
SKIP_CONTEXT_FILE=false
SESSION_ID=""
ALLOW_TOOLS=false
SKILL_NAME=""
HEALTH_CHECK=false
MODEL=""
PERMISSION_MODE=""
REASONING_FALLBACK=false
DRY_RUN=false
IMAGE_PATHS=()
ADD_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona)
      PERSONA_OVERRIDE="$2"; shift 2
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
    --timeout)
      CLI_TIMEOUT="$2"; shift 2
      ;;
    --temperature)
      # Antigravity has no temperature flag; consume the value.
      shift 2
      ;;
    --allow-tools|--allowed-tools)
      ALLOW_TOOLS=true
      YOLO_MODE=true
      shift
      ;;
    --image)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--image requires a file path" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      IMAGE_PATHS+=("$2")
      shift 2
      ;;
    --add-dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--add-dir requires a directory path" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      ADD_DIRS+=("$2")
      shift 2
      ;;
    --verbose|--debug)
      VERBOSE=true; shift
      ;;
    --session-id|-s|--resume|--manage-session)
      SESSION_ID="$2"; shift 2
      ;;
    --new-session)
      SESSION_ID=""; shift
      ;;
    --skill)
      SKILL_NAME="$2"; shift 2
      ;;
    --health-check)
      HEALTH_CHECK=true; shift
      ;;
    --auth-mode|--antigravity-auth-mode)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--auth-mode requires one of: auto, subscription, api-key" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      AGRAVITY_AUTH_MODE="$2"; shift 2
      ;;
    --use-api-key|--use-apikey)
      AGRAVITY_AUTH_MODE="api-key"; shift
      ;;
    --use-subscription|--use-login|--use-oauth)
      AGRAVITY_AUTH_MODE="subscription"; shift
      ;;
    --model)
      MODEL="$2"; shift 2
      ;;
    --mode|--permission-mode)
      # Antigravity has no plan/permission mode; ignored.
      PERMISSION_MODE="$2"; shift 2
      log_verbose "Permission mode flag received: $PERMISSION_MODE (ignored - antigravity has no plan mode)"
      ;;
    --reasoning-fallback|--reasoning-fallback-only)
      REASONING_FALLBACK=true; shift
      ;;
    --dry-run)
      DRY_RUN=true; shift
      ;;
    *)
      break
      ;;
  esac
done

# Resolve model alias against shared provider config for the model_resolution note,
# but do NOT pass it to agy (no flag exists; selection lives in settings.json).
if [[ -n "$MODEL" ]]; then
  prepare_requested_model_value "antigravity" "$MODEL"
  MODEL="$MODEL_PREPARED_VALUE"
  AGRAVITY_MODEL="$MODEL"
  log_verbose "Model alias resolved (informational only): $AGRAVITY_MODEL"
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    log_info "Model resolution: $MODEL_RESOLUTION_NOTE"
  fi
elif declare -F resolve_configured_default_model_for_provider >/dev/null; then
  AGRAVITY_MODEL="$(resolve_configured_default_model_for_provider "antigravity" "${WORK_DIR:-${WORKSPACE_DIR:-$PWD}}" 2>/dev/null || true)"
  if [[ -n "$AGRAVITY_MODEL" ]]; then
    MODEL="$AGRAVITY_MODEL"
    log_verbose "Model resolved from provider config (informational only): $AGRAVITY_MODEL"
  fi
fi

# ===================
# Health Check Mode
# ===================
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing agy CLI availability"
  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  if [[ -z "$AGRAVITY_BIN" ]]; then
    jq -n --arg provider "antigravity" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "agy CLI not found in PATH",
      session_support: true
    }'
    exit 1
  fi

  HEALTH_OUTPUT="$(agy --version 2>&1 || echo "version_check_failed")"
  HEALTH_EXIT=$?
  AUTH_API_KEY_ENV_PRESENT=false
  if agravity_api_key_env_present; then
    AUTH_API_KEY_ENV_PRESENT=true
  fi

  END_TIME=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#START_TIME} -gt 10 ]]; then
    LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  else
    LATENCY_MS=$(( (END_TIME - START_TIME) * 1000 ))
  fi

  if [[ $HEALTH_EXIT -eq 0 ]]; then
    VERSION="$(echo "$HEALTH_OUTPUT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")"
    jq -n --arg provider "antigravity" \
          --arg status "ok" \
          --argjson latency "$LATENCY_MS" \
          --arg version "$VERSION" \
          --arg auth_mode "$AGRAVITY_AUTH_MODE" \
          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
          '{
            provider: $provider,
            status: $status,
            latency_ms: $latency,
            cli_available: true,
            version: $version,
            auth_mode: $auth_mode,
            auth_strategy: "antigravity_settings",
            api_key_env_present: $api_key_env_present,
            api_key_ignored_for_subscription: false,
            session_support: true
          }'
  else
    jq -n --arg provider "antigravity" \
          --arg error "$HEALTH_OUTPUT" \
          --argjson latency "$LATENCY_MS" \
          --arg auth_mode "$AGRAVITY_AUTH_MODE" \
          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
          '{
            provider: $provider,
            status: "error",
            latency_ms: $latency,
            cli_available: true,
            error: $error,
            auth_mode: $auth_mode,
            auth_strategy: "antigravity_settings",
            api_key_env_present: $api_key_env_present,
            api_key_ignored_for_subscription: false,
            session_support: true
          }'
  fi
  exit 0
fi

# ===================
# Reasoning Fallback Mode
# ===================
if [[ "$REASONING_FALLBACK" == "true" ]]; then
  if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$(get_latest_agravity_session 2>/dev/null || true)"
  fi
  if [[ -z "$SESSION_ID" ]]; then
    emit_cli_error_response "reasoning_fallback requires --session-id (or an available latest session)" "invalid_input" "" 2
    exit 2
  fi
  emit_cli_response "" "$SESSION_ID" "" "" "" ""
  exit 0
fi

# ===================
# Dry-Run Mode
# ===================
# Validates wrapper inputs and emits a JSON validation summary without invoking agy.
if [[ "$DRY_RUN" == "true" ]]; then
  DRY_AGENT_FILE=""
  DRY_PROMPT_INPUT=""
  if is_agent_markdown_arg "${1-}"; then
    DRY_AGENT_FILE="$(resolve_agent_markdown_path "$1" 2>/dev/null || true)"
    shift || true
  fi
  DRY_PROMPT_INPUT="$(parse_arg_json_or_stdin "$@")"
  DRY_PROMPT_SIZE=${#DRY_PROMPT_INPUT}
  DRY_OVER_LIMIT="false"
  [[ $DRY_PROMPT_SIZE -gt $PROMPT_MAX_CHARS ]] && DRY_OVER_LIMIT="true"
  jq -n \
    --arg provider "antigravity" \
    --arg agent_file "${DRY_AGENT_FILE:-}" \
    --arg persona "${PERSONA_OVERRIDE:-}" \
    --arg session_id "${SESSION_ID:-}" \
    --arg model "${AGRAVITY_MODEL:-}" \
    --arg model_resolution "${MODEL_RESOLUTION_NOTE:-}" \
    --argjson prompt_size "$DRY_PROMPT_SIZE" \
    --argjson max_chars "$PROMPT_MAX_CHARS" \
    --argjson over_limit "$( [[ "$DRY_OVER_LIMIT" == "true" ]] && echo true || echo false )" \
    --argjson yolo "$( [[ "$YOLO_MODE" == "true" ]] && echo true || echo false )" \
    --argjson allow_tools "$( [[ "$ALLOW_TOOLS" == "true" ]] && echo true || echo false )" \
    --arg auth_mode "$AGRAVITY_AUTH_MODE" \
    --argjson cli_available "$( [[ -n "$AGRAVITY_BIN" ]] && echo true || echo false )" \
    '{
      provider: $provider,
      status: "validated",
      dry_run: true,
      agent_file: $agent_file,
      persona: $persona,
      session_id: $session_id,
      model: $model,
      model_resolution: $model_resolution,
      prompt_size_chars: $prompt_size,
      max_chars: $max_chars,
      over_limit: $over_limit,
      yolo: $yolo,
      allow_tools: $allow_tools,
      auth_mode: $auth_mode,
      cli_available: $cli_available
    }'
  exit 0
fi

# Resolve agy bin lazily for invocation paths.
if [[ -z "$AGRAVITY_BIN" ]]; then
  emit_cli_error_response "agy CLI not found in PATH" "invalid_input" "$SESSION_ID" 127
  exit 127
fi

# Build the agy argv that does NOT include the prompt itself (we use --print=PROMPT).
build_agy_args() {
  local args=("--print-timeout=${CLI_TIMEOUT:-300}s")
  if [[ "$YOLO_MODE" == "true" || "$ALLOW_TOOLS" == "true" ]]; then
    args+=("--dangerously-skip-permissions")
  fi
  local d
  for d in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do
    args+=("--add-dir=$d")
  done
  # Workspace dir: prefer CONTEXT_DIR > WORKSPACE_DIR (set below) so agy sees the project tree.
  if [[ -n "${AGY_WORKSPACE_DIR:-}" ]]; then
    args+=("--add-dir=$AGY_WORKSPACE_DIR")
  fi
  local sess
  sess="$(build_session_args)"
  if [[ -n "$sess" ]]; then
    args+=("$sess")
  fi
  printf '%s\n' "${args[@]}"
}

# ===================
# Skill Execution Mode
# ===================
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME"

  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.codex/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.cursor/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.gemini/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/modules/Autonom8-Agents/.opencode/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/commands/${SKILL_NAME}.md"
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
  SKILL_CONTENT="$(cat "$SKILL_FILE")"

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
  SKILL_PROMPT="$(append_image_prompt_context "$SKILL_PROMPT")"

  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  AGY_ARGS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && AGY_ARGS+=("$line")
  done < <(build_agy_args)

  log_verbose "Invoking agy CLI for skill (session args: ${AGY_ARGS[*]})"

  if declare -F autonom8_start_live_monitor >/dev/null 2>&1; then
    autonom8_start_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.gemini/antigravity-cli/conversations"
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    run_with_timeout "$CLI_TIMEOUT" "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  AGRAVITY_EXIT=$?
  set -e

  if declare -F autonom8_stop_live_monitor >/dev/null 2>&1; then
    autonom8_stop_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" 2>/dev/null || true
  fi

  AGRAVITY_SESSION_ID="$(get_latest_agravity_session 2>/dev/null || true)"

  if [[ $AGRAVITY_EXIT -ne 0 ]]; then
    ERROR_MSG="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")"
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if declare -F classify_wrapper_error >/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$AGRAVITY_EXIT" "provider_error")"
    elif declare -F classify_error >/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
      if [[ $AGRAVITY_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $AGRAVITY_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "$AGRAVITY_SESSION_ID" "$AGRAVITY_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi
    emit_cli_response "$RESPONSE_TEXT" "$AGRAVITY_SESSION_ID" "$RESPONSE_TEXT" "skill" "$SKILL_NAME" "$STDERR_TEXT"
  else
    emit_cli_error_response "No response from skill execution: $SKILL_NAME" "provider_error" "$AGRAVITY_SESSION_ID" 1
  fi

  exit 0
fi

# ===================
# Agent Invocation Mode
# ===================
if is_agent_markdown_arg "${1-}"; then
  AGENT_FILE="$1"; shift
  AGENT_FILE_ABS="$(resolve_agent_markdown_path "$AGENT_FILE")"
  validate_agent_file "$AGENT_FILE_ABS"

  INPUT_DATA="$(parse_arg_json_or_stdin "$@")"
  log_verbose "Processing agent file: $AGENT_FILE_ABS"
  if [[ -n "$INPUT_DATA" ]]; then
    log_verbose "Input data received (length: ${#INPUT_DATA})"
  fi

  CONTEXT_CONTENT=""
  RESOLVED_CONTEXT_FILE=""
  if [[ "$SKIP_CONTEXT_FILE" == "true" ]]; then
    log_verbose "Context loading disabled (--skip-context-file)"
  else
    if [[ -n "$CONTEXT_FILE" && -f "$CONTEXT_FILE" ]]; then
      RESOLVED_CONTEXT_FILE="$CONTEXT_FILE"
      log_verbose "Using explicit context file: $CONTEXT_FILE"
    elif [[ -n "$CONTEXT_DIR" ]]; then
      if [[ -f "$CONTEXT_DIR/CONTEXT.md" ]]; then
        RESOLVED_CONTEXT_FILE="$CONTEXT_DIR/CONTEXT.md"
        log_verbose "Found context in specified dir: $RESOLVED_CONTEXT_FILE"
      fi
    elif [[ -n "$INPUT_DATA" ]]; then
      PROJECT_DIR_VAL="$(echo "$INPUT_DATA" | jq -r '.project_dir // empty' 2>/dev/null || true)"
      if [[ -n "$PROJECT_DIR_VAL" && -f "$PROJECT_DIR_VAL/CONTEXT.md" ]]; then
        RESOLVED_CONTEXT_FILE="$PROJECT_DIR_VAL/CONTEXT.md"
        log_verbose "Auto-discovered context from project_dir: $RESOLVED_CONTEXT_FILE"
      fi
    fi
  fi

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

  PERSONA_ID="$PERSONA_OVERRIDE"
  if [[ -z "$PERSONA_ID" && -n "$INPUT_DATA" ]]; then
    PERSONA_ID="$(echo "$INPUT_DATA" | jq -r '.persona // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$PERSONA_ID" ]]; then
    PERSONA_ID="$(grep -E '^##+[[:space:]]+Persona:[[:space:]]+' "$AGENT_FILE_ABS" | head -1 | sed 's/^##*[[:space:]]*Persona:[[:space:]]*//' | awk '{print $1}')"
    log_verbose "No persona specified, using first persona from agent file: $PERSONA_ID"
  fi
  if [[ -z "$PERSONA_ID" ]]; then
    emit_cli_error_response "no persona found - specify via --persona flag or ensure agent file has Persona headers" "invalid_input" "" 2
    exit 2
  fi

  AGENT_PROMPT="$(extract_persona_block "$AGENT_FILE_ABS" "$PERSONA_ID")"
  if [[ -z "$AGENT_PROMPT" ]]; then
    emit_cli_error_response "persona '$PERSONA_ID' not found in agent file" "invalid_input" "" 2
    exit 2
  fi

  MATERIALIZATION_ONLY_MODE=false
  if printf '%s\n%s\n' "${INPUT_DATA:-}" "${AGENT_PROMPT:-}" | grep -Eiq 'bookend-start|bookend_start_contract_scope|BOOKEND-START MATERIALIZATION BOUNDARY|materialization[- ]only'; then
    MATERIALIZATION_ONLY_MODE=true
  fi

  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    if [[ "$MATERIALIZATION_ONLY_MODE" == "true" ]]; then
      TOOL_RULES="- You MUST actually CREATE/MODIFY only the explicitly scoped files in the design plan
- You may create directories and read/write files required for materialization
- Do NOT run browser automation, Playwright, screenshots, visual QA, golden tests, spec validation, dev servers, package managers, linters, formatters, or test commands
- Do NOT use browser/test MCP tools in this pass
- Stop immediately after materializing the scoped files and return the required JSON manifest
- The worker/harness owns downstream validation, browser testing, screenshots, and finish-bookend integration"
      log_verbose "Tools ENABLED in bookend-start materialization-only mode"
    else
      TOOL_RULES="- You MUST actually CREATE/MODIFY files as specified in the design plan
- Use your file writing capabilities to create each file with proper content
- After creating files, respond with a JSON summary of what you implemented
- DO NOT just describe what files should contain - ACTUALLY WRITE THEM
- The working directory is the project root - create files with the correct relative paths
- You MAY use available tools (file, browser, tests) to inspect and verify your work
- Use verification tools after code changes to ensure correctness"
      log_verbose "Tools ENABLED for this invocation"
    fi
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  if [[ -n "${INPUT_DATA}" ]]; then
    if [[ -n "$CONTEXT_CONTENT" ]]; then
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
- Assess based ONLY on the input data provided above
- Respond immediately with your assessment
- Return ONLY valid JSON matching the schema - no markdown, no explanations, no questions"
    fi
    FULL_PROMPT="$(append_image_prompt_context "${BASE_PROMPT}${CRITICAL_SUFFIX}")"
  else
    FULL_PROMPT="$(append_image_prompt_context "$AGENT_PROMPT")"
  fi

  if type check_prompt_size &>/dev/null; then
    check_prompt_size "$FULL_PROMPT" "antigravity"
    PROMPT_OVER_LIMIT=$?
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "antigravity"
    fi
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "antigravity")
      log_verbose "Prompt stats: $PROMPT_STATS"
    fi
  fi

  if [[ "$YOLO_MODE" == "true" ]]; then
    log_verbose "YOLO mode enabled - passing --dangerously-skip-permissions to agy"
  fi

  # Workspace resolution: prefer CONTEXT_DIR > tenant > core fallback.
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

  if [[ -n "$WORKSPACE_DIR" && -d "$WORKSPACE_DIR" ]]; then
    cd "$WORKSPACE_DIR"
    AGY_WORKSPACE_DIR="$WORKSPACE_DIR"
  fi

  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  AGY_ARGS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && AGY_ARGS+=("$line")
  done < <(build_agy_args)

  echo "🤖 [Antigravity] CLI: $AGRAVITY_BIN" >&2
  if [[ -n "$AGRAVITY_MODEL" ]]; then
    echo "🤖 [Antigravity] Model (informational; configured in settings.json): $AGRAVITY_MODEL" >&2
  fi
  if [[ ${#AGY_ARGS[@]} -gt 0 ]]; then
    echo "🤖 [Antigravity] Args: ${AGY_ARGS[*]}" >&2
  fi

  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "${WORKSPACE_DIR:-}" ]]; then
    AGENT_LOG_DIR="${WORKSPACE_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW:-}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: ${A8_TICKET_ID:-} | Workflow: ${A8_WORKFLOW:-} | Provider: antigravity" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "Agent stream logging to $AGENT_LOG"
  fi

  if declare -F autonom8_start_live_monitor >/dev/null 2>&1; then
    autonom8_start_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORKSPACE_DIR:-$(pwd)}" "${HOME}/.gemini/antigravity-cli/conversations"
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    echo "🤖 [Antigravity] Timeout: ${CLI_TIMEOUT}s" >&2
    if [[ -n "$AGENT_LOG" ]]; then
      run_with_timeout "$CLI_TIMEOUT" "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$FULL_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      run_with_timeout "$CLI_TIMEOUT" "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  else
    if [[ -n "$AGENT_LOG" ]]; then
      "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$FULL_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  fi
  AGRAVITY_EXIT=$?
  set -e

  if declare -F autonom8_stop_live_monitor >/dev/null 2>&1; then
    autonom8_stop_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" 2>/dev/null || true
  fi

  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  AGRAVITY_SESSION_ID="$(get_latest_agravity_session 2>/dev/null || true)"

  if [[ $AGRAVITY_EXIT -ne 0 ]]; then
    ERROR_MSG="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")"
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if declare -F classify_wrapper_error >/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$AGRAVITY_EXIT" "provider_error")"
    elif declare -F classify_error >/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
      if [[ $AGRAVITY_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $AGRAVITY_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "$AGRAVITY_SESSION_ID" "$AGRAVITY_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  log_verbose "Session ID after run: ${AGRAVITY_SESSION_ID:-<unknown>}"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi
    if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
      emit_cli_response "$RESPONSE_TEXT" "$AGRAVITY_SESSION_ID" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
    else
      emit_cli_response "$RESPONSE_TEXT" "$AGRAVITY_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
    fi
  else
    emit_cli_error_response "No response from Antigravity CLI" "provider_error" "$AGRAVITY_SESSION_ID" 1
  fi
else
  # Direct invocation with a free-form prompt (no agent .md).
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  AGY_ARGS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && AGY_ARGS+=("$line")
  done < <(build_agy_args)

  DIRECT_PROMPT=""
  if [[ ${#IMAGE_PATHS[@]} -gt 0 ]]; then
    DIRECT_PROMPT="$(append_image_prompt_context "$*")"
  else
    DIRECT_PROMPT="$(parse_arg_json_or_stdin "$@")"
  fi

  if [[ -z "$DIRECT_PROMPT" ]]; then
    emit_cli_error_response "No prompt provided (pipe via stdin or pass as args)" "invalid_input" "" 2
    exit 2
  fi

  echo "🤖 [Antigravity] Direct invocation" >&2

  if declare -F autonom8_start_live_monitor >/dev/null 2>&1; then
    autonom8_start_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" ""
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    run_with_timeout "$CLI_TIMEOUT" "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$DIRECT_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    "$AGRAVITY_BIN" ${AGY_ARGS[@]+"${AGY_ARGS[@]}"} "--print=$DIRECT_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  AGRAVITY_EXIT=$?
  set -e
  if declare -F autonom8_stop_live_monitor >/dev/null 2>&1; then
    autonom8_stop_live_monitor "agravity" "${WRAPPER_REQ_ID:-}" 2>/dev/null || true
  fi


  AGRAVITY_SESSION_ID="$(get_latest_agravity_session 2>/dev/null || true)"

  if [[ $AGRAVITY_EXIT -ne 0 ]]; then
    ERROR_MSG="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")"
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if declare -F classify_wrapper_error >/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$AGRAVITY_EXIT" "provider_error")"
    elif [[ $AGRAVITY_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "$AGRAVITY_SESSION_ID" "$AGRAVITY_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    emit_cli_response "$RESPONSE_TEXT" "$AGRAVITY_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
  else
    emit_cli_error_response "No response from Antigravity CLI" "provider_error" "$AGRAVITY_SESSION_ID" 1
  fi
fi
