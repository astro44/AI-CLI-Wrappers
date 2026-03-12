#!/usr/bin/env bash
# OpenCode CLI wrapper for Autonom8
# Configures workspace and invokes opencode CLI with proper context and permissions
# Updated to support context injection (v2.2)

set -euo pipefail

# Track child process PID for cleanup on script termination
OPENCODE_PID=""
TMPFILE_OUTPUT=""
TMPFILE_ERR=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false

# OpenCode model configuration
# Note: grok-code was deprecated, openai models have quota limits
# Available: opencode/big-pickle, opencode/gpt-5-nano
OPENCODE_MODEL="opencode/big-pickle"

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$OPENCODE_PID" ]] && kill -0 "$OPENCODE_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$OPENCODE_PID" 2>/dev/null || kill "$OPENCODE_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$OPENCODE_PID" 2>/dev/null || kill -9 "$OPENCODE_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
  # Clean up temp files
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

resolve_opencode_cmd() {
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
  done < <(which -a opencode 2>/dev/null | awk '!seen[$0]++')

  return 1
}

OPENCODE_BIN="$(resolve_opencode_cmd || true)"

opencode() {
  if [[ -z "${OPENCODE_BIN:-}" ]]; then
    return 127
  fi
  "$OPENCODE_BIN" "$@"
}

# Run command with timeout (runs in background so we can track PID for cleanup)
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
    # Run timeout command in background so we can track PID for cleanup
    "$timeout_cmd" --signal=TERM --kill-after=5 "$timeout_secs" "$@" &
    local pid=$!
    OPENCODE_PID=$pid

    # Wait for completion
    wait $pid
    local exit_code=$?
    OPENCODE_PID=""
    return $exit_code
  else
    # Fallback: run in background with manual timeout
    "$@" &
    local pid=$!
    OPENCODE_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      OPENCODE_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      OPENCODE_PID=""
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

  local tokens_json='{"input_tokens":0,"output_tokens":0,"total_tokens":0,"cost_usd":0}'
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
    session_tokens="$(get_opencode_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
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
    session_reasoning="$(get_opencode_session_reasoning "$session_id" 2>/dev/null || true)"
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
  local tokens_json='{"input_tokens":0,"output_tokens":0,"total_tokens":0,"cost_usd":0}'
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
    session_tokens="$(get_opencode_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      token_usage_available=true
    fi

    local session_reasoning=""
    session_reasoning="$(get_opencode_session_reasoning "$session_id" 2>/dev/null || true)"
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
      }'
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
}

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*" >&2
    fi
}

# Get the latest OpenCode session ID from session list
# Returns: session ID (ses_xxx format) or empty string
get_latest_opencode_session() {
  local work_dir="${1:-$PWD}"
  local session_output=""
  # Use timeout to prevent hanging - opencode session list can sometimes block
  local timeout_cmd=""
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout 5"
  elif command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout 5"
  fi
  if [[ -n "$timeout_cmd" ]]; then
    session_output="$(cd "$work_dir" && $timeout_cmd opencode session list 2>/dev/null | tail -n +3 | head -1 || true)"
  else
    session_output="$(cd "$work_dir" && opencode session list 2>/dev/null | tail -n +3 | head -1 || true)"
  fi
  if [[ -n "$session_output" ]]; then
    # Extract session ID (first column, ses_xxx format)
    local session_id=""
    session_id="$(echo "$session_output" | awk '{print $1}')"
    if [[ "$session_id" == ses_* ]]; then
      printf "%s" "$session_id"
      return 0
    fi
  fi
  return 1
}

# Extract token usage from OpenCode session parts table
# Returns JSON: {"input_tokens":N,"output_tokens":N,"total_tokens":N,"cost_usd":X}
get_opencode_session_token_usage() {
  local session_id="$1"
  local db_path="${HOME}/.local/share/opencode/opencode.db"
  [[ -z "$session_id" || ! -f "$db_path" ]] && return 1

  local row=""
  row="$(sqlite3 -cmd "PRAGMA busy_timeout=2000" "$db_path" "
    SELECT
      COALESCE(json_extract(data,'$.tokens.input'),0),
      COALESCE(json_extract(data,'$.tokens.output'),0),
      COALESCE(json_extract(data,'$.tokens.total'),0),
      COALESCE(json_extract(data,'$.cost'),0)
    FROM part
    WHERE session_id='${session_id}' AND json_extract(data,'$.type')='step-finish'
    ORDER BY time_created DESC
    LIMIT 1;
  " 2>/dev/null | tail -n 1 || true)"

  [[ -z "$row" ]] && return 1

  local input_tokens output_tokens total_tokens cost_usd
  input_tokens="$(echo "$row" | awk -F'|' '{print $1}')"
  output_tokens="$(echo "$row" | awk -F'|' '{print $2}')"
  total_tokens="$(echo "$row" | awk -F'|' '{print $3}')"
  cost_usd="$(echo "$row" | awk -F'|' '{print $4}')"

  [[ -z "$input_tokens" ]] && input_tokens=0
  [[ -z "$output_tokens" ]] && output_tokens=0
  [[ -z "$total_tokens" ]] && total_tokens=0
  [[ -z "$cost_usd" ]] && cost_usd=0

  if [[ "$total_tokens" == "0" ]]; then
    total_tokens=$((input_tokens + output_tokens))
  fi

  jq -n \
    --argjson input "$input_tokens" \
    --argjson output "$output_tokens" \
    --argjson total "$total_tokens" \
    --argjson cost "$cost_usd" \
    '{input_tokens:$input,output_tokens:$output,total_tokens:$total,cost_usd:$cost}'
}

# Extract latest reasoning text from OpenCode session parts table
get_opencode_session_reasoning() {
  local session_id="$1"
  local db_path="${HOME}/.local/share/opencode/opencode.db"
  [[ -z "$session_id" || ! -f "$db_path" ]] && return 1

  local text=""
  text="$(sqlite3 -cmd "PRAGMA busy_timeout=2000" "$db_path" "
    SELECT json_extract(data,'$.text')
    FROM part
    WHERE session_id='${session_id}' AND json_extract(data,'$.type')='reasoning'
    ORDER BY time_created DESC
    LIMIT 1;
  " 2>/dev/null | tail -n 1 || true)"

  [[ -z "$text" ]] && return 1
  # sqlite returns quoted JSON string for json_extract(text); normalize via jq
  printf "%s" "$text" | jq -r '.' 2>/dev/null || printf "%s" "$text"
}

# Build session args for opencode run command
build_session_args() {
  if [[ -n "$SESSION_ID" ]]; then
    log_verbose "Using session ID: $SESSION_ID"
    printf "%s" "-s $SESSION_ID"
  fi
}

# Determine core directory based on script location
# Script is in bin/opencode.sh, so CORE_DIR is parent of bin/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Prompt Utilities (inlined, provider-specific)
# OpenCode uses various models (Grok, etc.) with varying context windows
# =============================================================================
PROMPT_MAX_CHARS=100000        # ~25K tokens - conservative limit for OpenCode
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
    local provider="${2:-opencode}"
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
    local provider="${2:-opencode}"
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
    local provider="${3:-opencode}"
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
  local persona_id="$2"   # e.g., pm-opencode | dev-opencode (Implement) | dev-opencode (Design)
  # P1.5.1 FIX: Match full persona ID including role suffix
  # Supports both old format (pm-opencode) and new format (dev-opencode (Implement))
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
      # Full match: "dev-opencode (Implement)" == "dev-opencode (Implement)"
      # Prefix match: "pm-opencode" matches "pm-opencode (Communicator)" for legacy support
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

# Initialize flags
PERSONA_OVERRIDE=""
YOLO_MODE=false
VERBOSE=false
CONTEXT_FILE=""
CONTEXT_DIR=""
CONTEXT_MAX=51200  # 50KB default max context size
SKIP_CONTEXT_FILE=false
SESSION_ID=""
ALLOW_TOOLS=false  # OpenCode handles tool access internally
SKILL_NAME=""      # Skill to invoke (from .claude/commands/)
HEALTH_CHECK=false # P6.4: Health check mode
MODEL=""             # Model selection (overrides OPENCODE_MODEL if specified)
PERMISSION_MODE=""   # Permission mode (ignored by opencode - no plan mode support)
REASONING_FALLBACK=false # Emit fallback reasoning/tokens from session logs only

# Parse command-line arguments
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
      # OpenCode doesn't support temperature, ignore but consume the value
      shift 2
      ;;
    --allow-tools|--allowed-tools)
      # OpenCode equivalent: enable tool access
      ALLOW_TOOLS=true
      YOLO_MODE=true  # OpenCode uses yolo mode for unrestricted access
      shift
      ;;
    --verbose|--debug)
      VERBOSE=true; shift
      ;;
    --session-id|-s|--resume)
      # OpenCode session ID for resume (ses_xxx format)
      SESSION_ID="$2"; shift 2
      ;;
    --skill)
      SKILL_NAME="$2"; shift 2
      ;;
    --health-check)
      HEALTH_CHECK=true; shift
      ;;
    --model)
      # Model selection flag - overrides OPENCODE_MODEL
      MODEL="$2"; shift 2
      ;;
    --mode|--permission-mode)
      # Permission mode flag - ignored by opencode (no plan mode support)
      PERMISSION_MODE="$2"; shift 2
      log_verbose "Permission mode flag received: $PERMISSION_MODE (ignored - opencode has no plan mode)"
      ;;
    --reasoning-fallback|--reasoning-fallback-only)
      REASONING_FALLBACK=true; shift
      ;;
    *)
      break
      ;;
  esac
done

# Override OPENCODE_MODEL if MODEL flag was provided
if [[ -n "$MODEL" ]]; then
  OPENCODE_MODEL="$MODEL"
  log_verbose "Model overridden via --model flag: $OPENCODE_MODEL"
fi

# ===================
# P6.4: Health Check Mode
# ===================
# If --health-check flag is provided, check provider health and return status
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing opencode CLI availability"

  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Check if opencode CLI is available
  if [[ -z "$OPENCODE_BIN" ]]; then
    jq -n --arg provider "opencode" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "opencode CLI not found in PATH (non-wrapper binary resolution failed)",
      session_support: true
    }'
    exit 1
  fi

  # Try a minimal invocation to verify CLI works
  HEALTH_OUTPUT=$(opencode --version 2>&1 || echo "version_check_failed")
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

    jq -n --arg provider "opencode" \
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
    jq -n --arg provider "opencode" \
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
    SESSION_ID="$(get_latest_opencode_session "$PWD" 2>/dev/null || true)"
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
# If --skill flag is provided, invoke skill directly via OpenCode
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME"

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.opencode/skill/${SKILL_NAME}/SKILL.md"
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

  # Invoke OpenCode with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"
  OPENCODE_SESSION_ID=""

  # Build session args if session resume requested
  SESSION_ARGS="$(build_session_args)"

  log_verbose "Invoking opencode CLI for skill (model: $OPENCODE_MODEL, session: $SESSION_ARGS)"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    # shellcheck disable=SC2086
    run_with_timeout "$CLI_TIMEOUT" opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    # shellcheck disable=SC2086
    opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  OPENCODE_EXIT=$?
  set -e

  if [[ $OPENCODE_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    emit_cli_error_response "$ERROR_MSG" "provider_error" "" "$OPENCODE_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Strip markdown code fences if present
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
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
    emit_cli_error_response "no persona found - specify via --persona flag or ensure agent file has Persona headers" "invalid_input" "" 2
    exit 2
  fi

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
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions
  # Optionally include project context if available
  if [[ -n "${INPUT_DATA}" ]]; then
    if [[ -n "$CONTEXT_CONTENT" ]]; then
      # Include context in prompt
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
      # No context - original behavior
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
    FULL_PROMPT="${BASE_PROMPT}${CRITICAL_SUFFIX}"
  else
    FULL_PROMPT="$AGENT_PROMPT"
  fi

  # P2.1: Check prompt size and log warnings
  if type check_prompt_size &>/dev/null; then
    check_prompt_size "$FULL_PROMPT" "opencode"
    PROMPT_OVER_LIMIT=$?

    # Save debug prompt if enabled
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "opencode"
    fi

    # Log stats in verbose mode
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "opencode")
      log_verbose "Prompt stats: $PROMPT_STATS"
    fi
  fi

  # Note: OpenCode CLI operates in permissionless mode by default - no sandbox bypass flag needed
  if [[ "$YOLO_MODE" == "true" ]]; then
    log_verbose "YOLO mode requested - OpenCode is already permissionless by default"
  fi

  # Invoke opencode CLI with the agent prompt
  # OpenCode uses 'run' subcommand for agent execution
  # Pass the full prompt directly as the message argument (OpenCode doesn't handle -f file attachments well as instructions)
  # Capture output and wrap in CLIResponse format for Go worker
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"
  OPENCODE_SESSION_ID=""

  set +e
  # Pass the entire prompt as the message to opencode run
  # Get session ID from `opencode session list` after run completes
  # Always use Grok model for fast responses

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

  if [[ -n "$WORKSPACE_DIR" && -d "$WORKSPACE_DIR" ]]; then
    cd "$WORKSPACE_DIR"
  fi

  # Build session args if session resume requested
  SESSION_ARGS="$(build_session_args)"

  echo "🤖 [OpenCode] Using model: $OPENCODE_MODEL" >&2
  if [[ -n "$SESSION_ARGS" ]]; then
    echo "🤖 [OpenCode] Session: $SESSION_ARGS" >&2
  fi

  # O-6: Set up agent stream logging for per-ticket LLM output capture
  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "${WORKSPACE_DIR:-}" ]]; then
    AGENT_LOG_DIR="${WORKSPACE_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: $A8_TICKET_ID | Workflow: $A8_WORKFLOW | Provider: opencode" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "O-6: Agent stream logging to $AGENT_LOG"
  fi

  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running opencode with timeout: ${CLI_TIMEOUT}s, model: $OPENCODE_MODEL, session: $SESSION_ARGS"
    echo "🤖 [OpenCode] Timeout: ${CLI_TIMEOUT}s" >&2
    # shellcheck disable=SC2086
    if [[ -n "$AGENT_LOG" ]]; then
      run_with_timeout "$CLI_TIMEOUT" opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      run_with_timeout "$CLI_TIMEOUT" opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  else
    # shellcheck disable=SC2086
    if [[ -n "$AGENT_LOG" ]]; then
      opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  fi
  OPENCODE_EXIT=$?
  set -e

  # O-9: Append stdout response to agent log (stderr tee only captures progress/errors,
  # opencode sends the actual response to stdout which may be missing from logs)
  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  if [[ $OPENCODE_EXIT -ne 0 ]]; then
    # OpenCode failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    if [[ -z "$OPENCODE_SESSION_ID" ]]; then
      OPENCODE_SESSION_ID="$(get_latest_opencode_session "$PWD" 2>/dev/null || true)"
    fi
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    emit_cli_error_response "$ERROR_MSG" "provider_error" "$OPENCODE_SESSION_ID" "$OPENCODE_EXIT"
    exit 1
  fi

  # Read the output file
  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  # Get session ID from session list (most recent session)
  OPENCODE_SESSION_ID="$(get_latest_opencode_session 2>/dev/null || true)"
  log_verbose "Session ID from list: $OPENCODE_SESSION_ID"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Strip markdown code fences if present (```json ... ```)
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi

    # Wrap in CLIResponse format for Go worker (include session_id)
    emit_cli_response "$RESPONSE_TEXT" "$OPENCODE_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
  else
    emit_cli_error_response "No response from OpenCode CLI" "provider_error" "$OPENCODE_SESSION_ID" 1
  fi
else
  # Direct invocation with text prompt
  SESSION_ARGS="$(build_session_args)"
  echo "🤖 [OpenCode] Direct invocation using model: $OPENCODE_MODEL" >&2
  if [[ -n "$SESSION_ARGS" ]]; then
    echo "🤖 [OpenCode] Session: $SESSION_ARGS" >&2
  fi
  # shellcheck disable=SC2086
  opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$@"
fi
