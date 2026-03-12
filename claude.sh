#!/usr/bin/env bash
# Claude CLI wrapper for Autonom8
# Configures workspace and invokes claude CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

# Track child process PID for cleanup on script termination
CLAUDE_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$CLAUDE_PID" 2>/dev/null || kill "$CLAUDE_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$CLAUDE_PID" 2>/dev/null || kill -9 "$CLAUDE_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT TERM INT

resolve_claude_cmd() {
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
  done < <(which -a claude 2>/dev/null | awk '!seen[$0]++')

  return 1
}

CLAUDE_BIN="$(resolve_claude_cmd || true)"

claude() {
  if [[ -z "${CLAUDE_BIN:-}" ]]; then
    return 127
  fi
  "$CLAUDE_BIN" "$@"
}

# Run command with timeout (preserves stdin for piped input)
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
    # Run timeout in foreground to preserve stdin (piped input)
    # Use --foreground to allow signal handling with job control
    "$timeout_cmd" --foreground --signal=TERM --kill-after=5 "$timeout_secs" "$@"
    return $?
  else
    # Fallback: run in background with manual timeout
    "$@" &
    local pid=$!
    CLAUDE_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      CLAUDE_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      CLAUDE_PID=""
      return $exit_code
    fi
  fi
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

  if [[ -z "$reasoning_text" && -n "$session_id" ]]; then
    local session_reasoning
    session_reasoning="$(get_claude_session_reasoning "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_reasoning" ]]; then
      reasoning_text="$session_reasoning"
      reasoning_source="session_assistant"
    fi
  fi

  if [[ "$token_usage_available" != "true" && -n "$session_id" ]]; then
    local session_tokens
    session_tokens="$(get_claude_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      token_usage_available=true
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
    session_tokens="$(get_claude_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      token_usage_available=true
    fi

    local session_reasoning=""
    session_reasoning="$(get_claude_session_reasoning "$session_id" 2>/dev/null || true)"
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

# # Determine core directory from current working directory
# # Worker calls this from tenant root (/path/to/Autonom8-core/tenants/tenant_name)
# # We need to resolve paths relative to core directory
# if [[ "$PWD" =~ .*/tenants/[^/]+$ ]]; then
#   # Running from tenant root: /path/to/Autonom8-core/tenants/tenant_name
#   CORE_DIR="$(cd ../.. && pwd)"
# else
#   # Running from core directory (manual invocation)
#   CORE_DIR="$PWD"
# fi
# Determine core directory based on script location
# Script is in bin/claude.sh, so CORE_DIR is parent of bin/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Prompt Utilities (inlined, provider-specific)
# Claude has 200K token context window (~800K chars)
# =============================================================================
PROMPT_MAX_CHARS=200000        # ~50K tokens - conservative limit for Claude
PROMPT_WARN_THRESHOLD=160000   # Warn at ~40K tokens

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
    local provider="${2:-claude}"
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
    local provider="${2:-claude}"
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
    local provider="${3:-claude}"
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
  # Pattern: ^##{1,} matches ## or ### or more
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
  local persona_id="$2"   # e.g., pm-claude | dev-claudecode (Implement) | dev-claudecode (Design)
  # P1.5.1 FIX: Match full persona ID including role suffix
  # Supports both old format (pm-claude) and new format (dev-claudecode (Implement))
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
      # Full match: "dev-claudecode (Implement)" == "dev-claudecode (Implement)"
      # Prefix match: "pm-claude" matches "pm-claude (Strategic Planner)" for legacy support
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

# Validate if a Claude session exists
# Claude stores sessions in ~/.claude/projects/<encoded-path>/<session-id>.jsonl
validate_claude_session() {
  local session_id="$1"
  local work_dir="${2:-$PWD}"

  # Claude session IDs are UUIDs like "4ccf4a8b-be50-4492-9dd6-e4de2805d83c"
  # Sessions are stored in ~/.claude/projects/<encoded-path>/
  # Claude CLI encodes paths by replacing BOTH / AND _ with -
  # (e.g., /Users/astro_sk/foo -> -Users-astro-sk-foo)

  # Encode the work_dir path for Claude's directory structure
  # CRITICAL: Must replace both / and _ to match Claude CLI's actual encoding
  local encoded_path
  encoded_path="$(echo "$work_dir" | sed 's|[/_]|-|g')"

  local session_dir="$HOME/.claude/projects/$encoded_path"
  local session_file="$session_dir/${session_id}.jsonl"

  # Check if session file exists
  [[ -f "$session_file" ]]
}

get_claude_session_file_by_id() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1
  find "$HOME/.claude/projects" -name "${session_id}.jsonl" -type f 2>/dev/null | head -1
}

get_claude_session_token_usage() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_claude_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  tail -n 1200 "$session_file" 2>/dev/null | jq -rc '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    select(.type == "assistant" and .message.usage != null)
    | .message.usage
    | {
        input_tokens: ((.input_tokens // 0) | as_int),
        output_tokens: ((.output_tokens // 0) | as_int),
        total_tokens: (((.input_tokens // 0) + (.output_tokens // 0)) | as_int),
        cost_usd: 0
      }
  ' | tail -1
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

  # Treat markdown/code fence markers as non-reasoning placeholders.
  if printf "%s" "$compacted" | grep -Eq '^`{3,}[[:space:]]*(json|markdown|md|yaml|yml|text|txt)?[[:space:]]*`{0,3}$'; then
    return 0
  fi
  if [[ ${#compacted} -le 6 ]] && printf "%s" "$compacted" | grep -Eq '^[`[:space:]]+$'; then
    return 0
  fi

  return 1
}

extract_reasoning_from_assistant_text() {
  local assistant_text="${1:-}"
  [[ -z "$assistant_text" ]] && return 1

  # Prefer explicit reasoning fields from fenced JSON payloads.
  local json_block reasoning_from_json
  json_block="$(printf "%s" "$assistant_text" | \
    sed -n '/```json/,/```/p' | \
    sed '1s/^```json[[:space:]]*//' | \
    sed '$s/```[[:space:]]*$//')"
  if [[ -n "$json_block" ]]; then
    reasoning_from_json="$(printf "%s" "$json_block" | jq -r '._reasoning // .reasoning // .thinking // .analysis // empty' 2>/dev/null || true)"
    reasoning_from_json="$(compact_reasoning_text "$reasoning_from_json")"
    if ! is_reasoning_placeholder "$reasoning_from_json"; then
      printf "%s" "$reasoning_from_json" | cut -c1-600
      return 0
    fi
  fi

  # If assistant text contains fenced output, keep only the explanatory prelude.
  local prelude="$assistant_text"
  local fence_marker='```'
  if [[ "$assistant_text" == *"$fence_marker"* ]]; then
    prelude="${assistant_text%%${fence_marker}*}"
  fi
  prelude="$(compact_reasoning_text "$prelude")"
  if ! is_reasoning_placeholder "$prelude"; then
    printf "%s" "$prelude" | cut -c1-600
    return 0
  fi

  # Last resort: compacted assistant text if it is not placeholder-only.
  local compacted_text
  compacted_text="$(compact_reasoning_text "$assistant_text")"
  if [[ "$compacted_text" == "$fence_marker"* ]]; then
    # Message is fenced output payload with no explanatory prelude.
    return 1
  fi
  if printf "%s" "$compacted_text" | jq -e . >/dev/null 2>&1; then
    # Structured output without explicit reasoning fields should not be treated as reasoning.
    return 1
  fi
  if ! is_reasoning_placeholder "$compacted_text"; then
    printf "%s" "$compacted_text" | cut -c1-600
    return 0
  fi

  return 1
}

get_claude_session_reasoning() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_claude_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  local assistant_entries
  assistant_entries="$(tail -n 1200 "$session_file" 2>/dev/null | jq -rc '
    select(.type == "assistant" and (.message.content | type == "array"))
    | {
        thinking: (
          [
            .message.content[]
            | select(.type == "thinking")
            | (.thinking // empty)
          ]
          | join("\n")
        ),
        text: (
          [
            .message.content[]
            | select(.type == "text")
            | (.text // empty)
          ]
          | join("\n")
        )
      }
    | select((.thinking | length) > 0 or (.text | length) > 0)
  ' | tail -n 80 | tac)"
  [[ -z "$assistant_entries" ]] && return 1

  while IFS= read -r assistant_entry; do
    [[ -z "$assistant_entry" ]] && continue

    local thinking_text
    thinking_text="$(printf "%s" "$assistant_entry" | jq -r '.thinking // empty' 2>/dev/null || true)"
    if [[ -n "$thinking_text" ]]; then
      thinking_text="$(compact_reasoning_text "$thinking_text")"
      if ! is_reasoning_placeholder "$thinking_text"; then
        printf "%s" "$thinking_text" | cut -c1-600
        return 0
      fi
    fi

    local assistant_text extracted
    assistant_text="$(printf "%s" "$assistant_entry" | jq -r '.text // empty' 2>/dev/null || true)"
    if [[ -z "$assistant_text" ]]; then
      continue
    fi
    extracted="$(extract_reasoning_from_assistant_text "$assistant_text" 2>/dev/null || true)"
    if [[ -n "$extracted" ]]; then
      printf "%s" "$extracted"
      return 0
    fi
  done <<< "$assistant_entries"

  return 1
}

# Initialize flags
PERSONA_OVERRIDE=""
YOLO_MODE=false
DRY_RUN=false
VERBOSE=false
ALLOW_TOOLS=false
TEMPERATURE=""
CONTEXT_FILE=""
CONTEXT_DIR=""
CONTEXT_MAX=51200  # 50KB default max context size
SKIP_CONTEXT_FILE=false
SESSION_ID=""        # Existing session ID to resume
NEW_SESSION=""       # Flag to create new session (capture ID from response)
SKILL_NAME=""        # Skill to invoke (from .claude/commands/)
QUOTA_STATUS=false   # Check and return quota status
HEALTH_CHECK=false   # P6.4: Health check mode
MODEL=""             # Model selection (opus, sonnet, haiku, or full name)
PERMISSION_MODE=""   # Permission mode (plan, default, etc.)
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
    --dry-run)
      DRY_RUN=true; shift
      ;;
    --verbose|--debug)
      VERBOSE=true; shift
      ;;
    --allow-tools|--allowed-tools)
      ALLOW_TOOLS=true; shift
      ;;
    --timeout)
      CLI_TIMEOUT="$2"; shift 2
      ;;
    --session-id|--resume)
      # Both flags accepted for uniform interface across all providers
      SESSION_ID="$2"; shift 2
      ;;
    --new-session)
      # Signal to create a new session and capture session_id from response
      # No value needed - just a flag to trigger session tracking
      NEW_SESSION="true"; shift
      ;;
    --skill)
      SKILL_NAME="$2"; shift 2
      ;;
    --quota-status)
      QUOTA_STATUS=true; shift
      ;;
    --health-check)
      HEALTH_CHECK=true; shift
      ;;
    --model)
      MODEL="$2"; shift 2
      ;;
    --mode|--permission-mode)
      PERMISSION_MODE="$2"; shift 2
      ;;
    --reasoning-fallback|--reasoning-fallback-only)
      REASONING_FALLBACK=true; shift
      ;;
    *)
      break
      ;;
  esac
done

# ===================
# Quota Status Mode
# ===================
# If --quota-status flag is provided, return quota status JSON
if [[ "$QUOTA_STATUS" == "true" ]]; then
  # Check for cached usage limit messages
  SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
  LATEST_LIMIT_FILE=""

  if [[ -d "$SYSTEM_MSG_DIR" ]]; then
    # Find most recent claude usage limit file (use find to avoid glob expansion issues)
    LATEST_LIMIT_FILE=$(find "$SYSTEM_MSG_DIR" -name "*-claude-usage-limit.json" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1 || true)
  fi

  if [[ -n "$LATEST_LIMIT_FILE" && -f "$LATEST_LIMIT_FILE" ]]; then
    # Parse the cached limit file
    TIMESTAMP=$(jq -r '.timestamp // empty' "$LATEST_LIMIT_FILE" 2>/dev/null)
    RETRY_TIME=$(jq -r '.retry_time // empty' "$LATEST_LIMIT_FILE" 2>/dev/null)

    # Calculate if quota has likely reset (default: 1 hour from last error)
    if [[ -n "$TIMESTAMP" ]]; then
      LIMIT_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$TIMESTAMP" "+%s" 2>/dev/null || echo "0")
      NOW_EPOCH=$(date "+%s")
      ELAPSED=$((NOW_EPOCH - LIMIT_EPOCH))

      # Assume quota resets after 1 hour (3600 seconds) if no retry_time specified
      RESET_SECONDS=3600
      if [[ $ELAPSED -ge $RESET_SECONDS ]]; then
        # Quota likely reset
        jq -n --arg provider "claude" \
          '{provider: $provider, quota_exhausted: false, source: "estimated", message: "Quota likely reset (>1h since last limit)"}'
      else
        # Still exhausted
        REMAINING=$((RESET_SECONDS - ELAPSED))
        RESET_AT=$(date -j -v+${REMAINING}S "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        jq -n --arg provider "claude" \
              --argjson exhausted true \
              --arg reset_at "$RESET_AT" \
              --argjson reset_in_seconds "$REMAINING" \
              --arg retry_time "$RETRY_TIME" \
              --arg source "cached" \
          '{provider: $provider, quota_exhausted: $exhausted, reset_at: $reset_at, reset_in_seconds: $reset_in_seconds, retry_time: $retry_time, source: $source}'
      fi
    else
      jq -n --arg provider "claude" \
        '{provider: $provider, quota_exhausted: false, source: "unknown", message: "No valid timestamp in limit file"}'
    fi
  else
    # No cached limit file - quota is likely available
    jq -n --arg provider "claude" \
      '{provider: $provider, quota_exhausted: false, source: "no_cache", message: "No recent quota limit detected"}'
  fi
  exit 0
fi

# ===================
# P6.4: Health Check Mode
# ===================
# If --health-check flag is provided, check provider health and return status
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing claude CLI availability"

  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Check if claude CLI is available
  if [[ -z "$CLAUDE_BIN" ]]; then
    jq -n --arg provider "claude" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "claude CLI not found in PATH (non-wrapper binary resolution failed)",
      session_support: true
    }'
    exit 1
  fi

  # Try a minimal invocation to verify CLI works
  HEALTH_OUTPUT=$(claude --version 2>&1 || echo "version_check_failed")
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

    jq -n --arg provider "claude" \
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
    jq -n --arg provider "claude" \
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
    emit_cli_error_response "reasoning_fallback requires --session-id" "invalid_input" "" 2
    exit 2
  fi
  emit_cli_response "" "$SESSION_ID" "" "" "" ""
  exit 0
fi

# ===================
# Skill Execution Mode
# ===================
# If --skill flag is provided, invoke skill directly via Claude Code
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME"

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.codex/skills/${SKILL_NAME}/SKILL.md"
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
      '{dry_run: true, wrapper: "claude.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed"}'
    exit 0
  fi

  # Invoke Claude with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  BYPASS_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-skip-permissions"
  fi

  # Build model argument if specified
  MODEL_ARG=""
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="--model $MODEL"
  fi

  # Build permission mode argument if specified
  MODE_ARG=""
  if [[ -n "$PERMISSION_MODE" ]]; then
    MODE_ARG="--permission-mode $PERMISSION_MODE"
  fi

  # Determine working directory
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    WORK_DIR="$CORE_DIR/tenants/oxygen"
  fi

  log_verbose "Invoking claude CLI for skill (WorkDir: ${WORK_DIR:-none}, Model: ${MODEL_ARG:-default}, Mode: ${MODE_ARG:-default})"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  fi
  CLAUDE_EXIT=$?
  set -e

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    emit_cli_error_response "$ERROR_MSG" "provider_error" "" "$CLAUDE_EXIT"
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
    emit_cli_error_response "no persona found - specify via --persona flag or ensure agent file has Persona headers" "invalid_input" "$SESSION_ID" 2
    exit 2
  fi

  log_verbose "Persona selected: $PERSONA_ID"

  # Extract only the chosen persona block
  AGENT_PROMPT="$(extract_persona_block "$AGENT_FILE_ABS" "$PERSONA_ID")"

  if [[ -z "$AGENT_PROMPT" ]]; then
    emit_cli_error_response "persona '$PERSONA_ID' not found in agent file" "invalid_input" "$SESSION_ID" 2
    exit 2
  fi

  # Build conditional tool rules based on --allow-tools flag
  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    TOOL_RULES="- You MAY use available MCP tools (file, browser, tests) to inspect and verify your work
- Use verification tools after code changes to ensure correctness
- You can read files and explore the codebase as needed"
    log_verbose "Tools ENABLED for this invocation"
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions to prevent claude from responding to persona
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
    check_prompt_size "$FULL_PROMPT" "claude"
    PROMPT_OVER_LIMIT=$?

    # Save debug prompt if enabled
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "claude"
    fi

    # Log stats in verbose mode
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "claude")
      log_verbose "Prompt stats: $PROMPT_STATS"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_verbose "DRY-RUN MODE: Skipping actual CLI call"

    # P6.3: Enhanced dry-run output with comprehensive information
    PROMPT_SIZE=${#FULL_PROMPT}
    ESTIMATED_TOKENS=$((PROMPT_SIZE / 4))

    # Determine context info
    CONTEXT_INFO="none"
    if [[ -n "$RESOLVED_CONTEXT_FILE" ]]; then
      CONTEXT_INFO="$RESOLVED_CONTEXT_FILE"
    fi

    # Determine session mode
    SESSION_MODE="new"
    if [[ -n "$SESSION_ID" ]]; then
      SESSION_MODE="resume:$SESSION_ID"
    fi

    # Build comprehensive dry-run response
    jq -n \
      --arg wrapper "claude.sh" \
      --arg provider "claude" \
      --arg persona "$PERSONA_ID" \
      --arg agent_file "$AGENT_FILE_ABS" \
      --argjson prompt_size "$PROMPT_SIZE" \
      --argjson estimated_tokens "$ESTIMATED_TOKENS" \
      --argjson timeout "${CLI_TIMEOUT:-0}" \
      --arg context_file "$CONTEXT_INFO" \
      --arg session_mode "$SESSION_MODE" \
      --arg yolo_mode "$YOLO_MODE" \
      --arg allow_tools "$ALLOW_TOOLS" \
      --argjson max_prompt_chars "${PROMPT_MAX_CHARS:-30000}" \
      '{
        dry_run: true,
        validation: "passed",
        wrapper: $wrapper,
        provider: $provider,
        persona: $persona,
        agent_file: $agent_file,
        prompt: {
          size_chars: $prompt_size,
          estimated_tokens: $estimated_tokens,
          max_chars: $max_prompt_chars,
          over_limit: ($prompt_size > $max_prompt_chars)
        },
        config: {
          timeout_seconds: (if $timeout == 0 then "unlimited" else $timeout end),
          context_file: (if $context_file == "none" then null else $context_file end),
          session_mode: $session_mode,
          yolo_mode: ($yolo_mode == "true"),
          allow_tools: ($allow_tools == "true")
        },
        message: "Dry-run validation successful - no actual CLI call made"
      }'
    log_verbose "Dry-run completed successfully"
    exit 0
  fi

  # Invoke claude and extract final assistant message
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Only use --dangerously-skip-permissions if --yolo flag was passed
  BYPASS_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-skip-permissions"
  fi

  # Change to tenant directory so claude CLI picks up correct .claude/claude.md context
  # Determine tenant directory - look for first directory under tenants/
  TENANT_DIR=""
  if [[ "$PWD" =~ .*/tenants/([^/]+)$ ]]; then
    # Already in tenant directory
    TENANT_DIR="$PWD"
  elif [[ -d "$CORE_DIR/tenants" ]]; then
    # Find first tenant directory (prefer oxygen if it exists)
    if [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
      TENANT_DIR="$CORE_DIR/tenants/oxygen"
    else
      TENANT_DIR=$(find "$CORE_DIR/tenants" -maxdepth 1 -type d ! -name tenants | head -1)
    fi
  fi

  # Note: Claude CLI --print mode doesn't expose temperature directly
  # Temperature is accepted for API consistency but logged only
  if [[ -n "$TEMPERATURE" ]]; then
    log_verbose "Temperature specified: $TEMPERATURE (note: Claude --print mode uses default temperature)"
  fi

  # Determine working directory: prefer CONTEXT_DIR (from --context-dir flag) over TENANT_DIR
  # This ensures files are created in the correct project directory, not the tenant root
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
    log_verbose "Using CONTEXT_DIR as working directory: $WORK_DIR"
  elif [[ -n "$TENANT_DIR" ]]; then
    WORK_DIR="$TENANT_DIR"
    log_verbose "Using TENANT_DIR as working directory: $WORK_DIR"
  fi

  # Build session args for session persistence
  # SIMPLIFIED APPROACH (like codex.sh):
  # - For new sessions: No --session-id flag, use --output-format json to capture session_id
  # - For resume: Use --resume <stored-id> directly
  # - Parse session_id from Claude's JSON response
  # Always use JSON format to capture session_id from response
  SESSION_ARG=""
  OUTPUT_FORMAT="json"  # Always JSON to capture session_id
  CLAUDE_SESSION_ID=""  # Will be populated from response

  if [[ -n "$SESSION_ID" ]]; then
    # Resume existing session - use --resume flag directly
    # No validation needed - Claude will error if session doesn't exist
    SESSION_ARG="--resume $SESSION_ID"
    CLAUDE_SESSION_ID="$SESSION_ID"
    log_verbose "Resuming session: $SESSION_ID"
  elif [[ "$NEW_SESSION" == "true" ]]; then
    # New session explicitly requested - will be captured from response
    log_verbose "Creating new session (will capture ID from response)"
  else
    # Default: new session will be created, capture ID from response
    log_verbose "Default session handling (will capture ID from response)"
  fi

  # Build model argument if specified
  MODEL_ARG=""
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="--model $MODEL"
    log_verbose "Using model: $MODEL"
  fi

  # Build permission mode argument if specified
  MODE_ARG=""
  if [[ -n "$PERMISSION_MODE" ]]; then
    MODE_ARG="--permission-mode $PERMISSION_MODE"
    log_verbose "Using permission mode: $PERMISSION_MODE"
  fi

  log_verbose "Invoking claude CLI (WorkDir: ${WORK_DIR:-none}, Bypass: ${BYPASS_ARG:-none}, Session: ${SESSION_ARG:-none}, Model: ${MODEL_ARG:-default}, Mode: ${MODE_ARG:-default}, Format: $OUTPUT_FORMAT)"

  # O-6: Set up agent stream logging for per-ticket LLM output capture
  # A8_TICKET_ID and A8_WORKFLOW are set by Go CLIManager via environment variables
  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "$WORK_DIR" ]]; then
    AGENT_LOG_DIR="${WORK_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: $A8_TICKET_ID | Workflow: $A8_WORKFLOW | Provider: claude" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "O-6: Agent stream logging to $AGENT_LOG"
  fi

  # Use --print mode for non-interactive operation
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running claude with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$AGENT_LOG" ]]; then
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT")
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
      fi
      CLAUDE_EXIT=$?
    else
      if [[ -n "$AGENT_LOG" ]]; then
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
      else
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
      fi
      CLAUDE_EXIT=$?
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$AGENT_LOG" ]]; then
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT")
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
      fi
      CLAUDE_EXIT=$?
    else
      if [[ -n "$AGENT_LOG" ]]; then
        echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
      else
        echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
      fi
      CLAUDE_EXIT=$?
    fi
  fi
  set -e

  # O-9: Append stdout response to agent log (stderr tee only captures progress/errors,
  # claude --print sends the actual response to stdout which was missing from logs)
  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    # P6.1: Standardized error handling
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    log_verbose "Claude execution failed: $ERROR_MSG"

    # Classify the error type
    ERROR_TYPE="unknown"
    if type classify_error &>/dev/null; then
      ERROR_TYPE=$(classify_error "$ERROR_MSG")
    fi

    # Timeout classification (emit structured envelope below).
    if [[ $CLAUDE_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi

    # Create system message for recoverable errors (quota, rate_limit)
    if type create_system_message &>/dev/null; then
      create_system_message "claude" "$ERROR_TYPE" "$ERROR_MSG" "$CORE_DIR"
    elif [[ "$ERROR_TYPE" == "quota" ]]; then
      # Fallback: create system message manually for quota errors
      RETRY_TIME=$(echo "$ERROR_MSG" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")
      SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
      mkdir -p "$SYSTEM_MSG_DIR"
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      MSG_FILE="$SYSTEM_MSG_DIR/$(date +%s)-claude-usage-limit.json"
      jq -n \
        --arg ts "$TIMESTAMP" \
        --arg cli "claude" \
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

    # Return structured error response with wrapper envelope.
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "${CLAUDE_SESSION_ID:-$SESSION_ID}" "$CLAUDE_EXIT"
    exit 1
  fi

  # Read the output file which should contain the last message
  RAW_OUTPUT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -z "$RAW_OUTPUT" || "$RAW_OUTPUT" == "null" ]]; then
    emit_cli_error_response "No response from Claude CLI" "provider_error" "${CLAUDE_SESSION_ID:-$SESSION_ID}" 0
    exit 0
  fi

  # Handle response based on output format
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # JSON format: Parse session_id and result from Claude's response
    # Claude returns: {"type":"result","result":"...","session_id":"...","..."}
    CLAUDE_SESSION_ID="$(echo "$RAW_OUTPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    RESPONSE_TEXT="$(echo "$RAW_OUTPUT" | jq -r '.result // empty' 2>/dev/null || true)"

    # If no .result field, check if it's an error response
    if [[ -z "$RESPONSE_TEXT" ]]; then
      IS_ERROR="$(echo "$RAW_OUTPUT" | jq -r '.is_error // false' 2>/dev/null || true)"
      if [[ "$IS_ERROR" == "true" ]]; then
        ERROR_MSGS="$(echo "$RAW_OUTPUT" | jq -r '.errors | join(", ")' 2>/dev/null || true)"
        emit_cli_error_response "${ERROR_MSGS:-Unknown error}" "provider_error" "${CLAUDE_SESSION_ID:-$SESSION_ID}" 1
        exit 1
      fi
      # Fall back to raw output if no .result
      RESPONSE_TEXT="$RAW_OUTPUT"
    fi

    log_verbose "New session created: ${CLAUDE_SESSION_ID:-none}"
  else
    # Text format: Response is the text directly
    RESPONSE_TEXT="$RAW_OUTPUT"
  fi

  # Strip markdown code fences if present (```json ... ```)
  if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
    RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
  elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
    RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
  fi

  # Wrap in CLIResponse format for Go worker
  # Include session_id if we have one (from resume or captured from new session)
  emit_cli_response "$RESPONSE_TEXT" "$CLAUDE_SESSION_ID" "$RAW_OUTPUT" "" "" "$STDERR_TEXT"
else
  # Direct invocation
  BYPASS_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-skip-permissions"
  fi

  log_verbose "Running in direct invocation mode"
  claude --print --output-format text $BYPASS_ARG "$@"
fi
