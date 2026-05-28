#!/usr/bin/env bash
# Codex CLI wrapper for Autonom8
# Configures workspace and invokes codex CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

WRAPPER_REQ_ID="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-}}"
exec 3>&2
if [[ -n "${WRAPPER_REQ_ID}" ]]; then
  exec 2> >(while IFS= read -r __a8_line; do
    printf '[req=%s] %s\n' "${WRAPPER_REQ_ID}" "${__a8_line}" >&3
  done)
fi

# Track child process PID for cleanup on script termination
CODEX_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false
CODEX_AUTH_MODE="${AUTONOM8_CODEX_AUTH_MODE:-${AUTONOM8_PROVIDER_AUTH_MODE:-auto}}"

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

LIVE_MONITOR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/live-monitor.sh"
if [[ -f "$LIVE_MONITOR_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$LIVE_MONITOR_LIB"
fi
codex_json_stream_sink() {
  if [[ -n "${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}" ]] && declare -F autonom8_monitor_codex_jsonl_stream >/dev/null; then
    autonom8_monitor_codex_jsonl_stream "${WRAPPER_REQ_ID:-}" "${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}"
  else
    cat >/dev/null
  fi
}

# Cleanup function to kill child processes on script termination
cleanup() {
  if declare -F autonom8_wrapper_write_cleanup_event >/dev/null; then
    autonom8_wrapper_write_cleanup_event "codex" "${CODEX_PID:-}" "${WORK_DIR:-$(pwd)}" "wrapper_cleanup"
  fi
  if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
    autonom8_wrapper_stop_parent_monitor
  fi
  if declare -F autonom8_stop_live_monitor >/dev/null; then
    autonom8_stop_live_monitor "codex"
  fi
  if declare -F autonom8_wrapper_reap_child_tree >/dev/null; then
    autonom8_wrapper_reap_child_tree "codex" "${CODEX_PID:-}" "${WORK_DIR:-$(pwd)}" "wrapper_cleanup"
  elif [[ -n "$CODEX_PID" ]] && kill -0 "$CODEX_PID" 2>/dev/null; then
    kill "$CODEX_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$CODEX_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT TERM INT

resolve_codex_cmd() {
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
  done < <(which -a codex 2>/dev/null | awk '!seen[$0]++')

	return 1
}

codex_normalized_auth_mode() {
  printf "%s" "${CODEX_AUTH_MODE:-auto}" | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

codex_should_unset_api_key() {
  [[ -n "${OPENAI_API_KEY:-}" ]] || return 1
  case "$(codex_normalized_auth_mode)" in
    subscription|oauth|login|chatgpt|chatgpt_login|pro|plus)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_command_args() {
  if [[ -z "${CODEX_CMD:-}" ]]; then
    return 127
  fi
  if codex_should_unset_api_key; then
    printf "%s\0" env -u OPENAI_API_KEY "$CODEX_CMD" "$@"
  else
    printf "%s\0" "$CODEX_CMD" "$@"
  fi
}

# Run command with timeout (preserves stdin for piped input)
run_with_timeout() {
  local timeout_secs="$1"
  shift
  local cmd_args=("$@")
  if [[ -n "${CODEX_CMD:-}" && "${cmd_args[0]:-}" == "$CODEX_CMD" ]]; then
    cmd_args=()
    while IFS= read -r -d '' arg; do
      cmd_args+=("$arg")
    done < <(codex_command_args "${@:2}")
  fi

  if [[ "${AUTONOM8_WRAPPER_TIMEOUT_SUPERVISION:-}" == "go" ]]; then
    "${cmd_args[@]}"
    return $?
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
    "$timeout_cmd" --foreground --signal=TERM --kill-after=5 "$timeout_secs" "${cmd_args[@]}"
    return $?
  else
    # Fallback: preserve piped stdin by buffering it before backgrounding the command.
    local stdin_tmp=""
    if [[ ! -t 0 ]]; then
      stdin_tmp="$(mktemp)"
      cat > "$stdin_tmp"
    fi

    if [[ -n "$stdin_tmp" ]]; then
      "${cmd_args[@]}" < "$stdin_tmp" &
    else
      "${cmd_args[@]}" &
    fi
    local pid=$!
    CODEX_PID=$pid
    if declare -F autonom8_wrapper_monitor_parent >/dev/null; then
      autonom8_wrapper_monitor_parent "$pid" "codex" "${WORK_DIR:-$(pwd)}"
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
      CODEX_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
        autonom8_wrapper_stop_parent_monitor
      fi
      CODEX_PID=""
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
    session_tokens="$(get_codex_session_token_usage "$session_id" 2>/dev/null || true)"
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
    session_reasoning="$(get_codex_session_reasoning "$session_id" 2>/dev/null || true)"
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

  local tool_activity_input="$raw_output"
  if [[ -n "$session_id" ]]; then
    local session_tool_events
    session_tool_events="$(get_codex_session_tool_events "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tool_events" ]]; then
      tool_activity_input="${tool_activity_input}"$'\n'"${session_tool_events}"
    fi
  fi

  local tool_activity_json
  tool_activity_json="$(autonom8_tool_activity_json "$tool_activity_input" "$stream_output" "wrapper:codex")"

  RESPONSE_EMITTED=true
  local response_file=""
  local reasoning_file=""
  response_file="$(mktemp "${TMPDIR:-/tmp}/codex-response.XXXXXX")" || return 1
  reasoning_file="$(mktemp "${TMPDIR:-/tmp}/codex-reasoning.XXXXXX")" || {
    rm -f "$response_file"
    return 1
  }

  printf "%s" "$response_text" > "$response_file"
  printf "%s" "$reasoning_text" > "$reasoning_file"

  local jq_status=0
  if [[ -n "$session_id" && -n "$extra_field_name" ]]; then
    jq -n \
      --rawfile resp "$response_file" \
      --arg sid "$session_id" \
      --rawfile reasoning "$reasoning_file" \
      --arg extra_name "$extra_field_name" \
      --arg extra_val "$extra_field_value" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
    jq_status=$?
  elif [[ -n "$session_id" ]]; then
    jq -n \
      --rawfile resp "$response_file" \
      --arg sid "$session_id" \
      --rawfile reasoning "$reasoning_file" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, session_id: $sid, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
    jq_status=$?
  elif [[ -n "$extra_field_name" ]]; then
    jq -n \
      --rawfile resp "$response_file" \
      --rawfile reasoning "$reasoning_file" \
      --arg extra_name "$extra_field_name" \
      --arg extra_val "$extra_field_value" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}} + {($extra_name): $extra_val}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
    jq_status=$?
  else
    jq -n \
      --rawfile resp "$response_file" \
      --rawfile reasoning "$reasoning_file" \
      --argjson tokens "$tokens_json" \
      --argjson available "$token_usage_available" \
      --argjson reasoning_available "$reasoning_available" \
      --arg reasoning_source "$reasoning_source" \
      --arg reasoning_absent_reason "$reasoning_absent_reason" \
      '{response: $resp, reasoning: $reasoning, tokens_used: $tokens, metadata: {token_usage_available: $available, reasoning_available: $reasoning_available, reasoning_source: $reasoning_source, reasoning_absent_reason: $reasoning_absent_reason}}' \
      | autonom8_merge_tool_activity "$tool_activity_json"
    jq_status=$?
  fi

  rm -f "$response_file" "$reasoning_file"
  return $jq_status
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
    local session_tokens=""
    session_tokens="$(get_codex_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
    fi

    local session_reasoning=""
    session_reasoning="$(get_codex_session_reasoning "$session_id" 2>/dev/null || true)"
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

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*" >&2
    fi
}

get_codex_mcp_config() {
  if [[ -f "$CORE_DIR/.codex/.mcp.json" ]]; then
    echo "$CORE_DIR/.codex/.mcp.json"
  elif [[ -f "$CORE_DIR/.mcp.json" ]]; then
    echo "$CORE_DIR/.mcp.json"
  fi
}

ensure_codex_mcp_servers() {
  local config_path="$1"
  local server_names
  server_names=$(jq -r '.mcpServers | keys[]' "$config_path" 2>/dev/null || true)
  if [[ -z "$server_names" ]]; then
    return 0
  fi

  while read -r server_name; do
    [[ -z "$server_name" ]] && continue
    if ! "$CODEX_CMD" mcp get "$server_name" --json >/dev/null 2>&1; then
      local command
      local args=()
      local args_count=0
      local arg=""
      command=$(jq -r ".mcpServers.\"$server_name\".command" "$config_path" 2>/dev/null || true)
      if [[ -z "$command" || "$command" == "null" ]]; then
        continue
      fi
      while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        args+=("$arg")
        args_count=$((args_count + 1))
      done < <(jq -r ".mcpServers.\"$server_name\".args[]?" "$config_path" 2>/dev/null || true)
      if (( args_count > 0 )); then
        "$CODEX_CMD" mcp add "$server_name" "$command" "${args[@]}" >/dev/null 2>&1 || true
      else
        "$CODEX_CMD" mcp add "$server_name" "$command" >/dev/null 2>&1 || true
      fi
      log_verbose "Registered MCP server for codex: $server_name"
    fi
  done <<< "$server_names"
}

# Determine core directory based on script location
# Resolve repo root whether the wrapper is installed in <repo>/bin or checked out at repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "bin" ]]; then
  CORE_DIR="$(dirname "$SCRIPT_DIR")"
else
  CORE_DIR="$SCRIPT_DIR"
fi

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
# Prompt Utilities (inlined, provider-specific)
# Codex (GPT-5.2) has 128K token context window (~512K chars)
# =============================================================================
PROMPT_MAX_CHARS=150000        # ~37K tokens - conservative limit for Codex
PROMPT_WARN_THRESHOLD=120000   # Warn at ~30K tokens

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
    local provider="${2:-codex}"
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
    local provider="${2:-codex}"
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
    local provider="${3:-codex}"
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
  local persona_id="$2"   # e.g., pm-codex | dev-codex (Implement) | dev-claudecode (Design)
  # P1.5.1 FIX: Match full persona ID including role suffix
  # Supports both old format (pm-codex) and new format (dev-codex (Implement))
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
      # Full match: "dev-codex (Implement)" == "dev-codex (Implement)"
      # Prefix match: "pm-codex" matches "pm-codex (Strategic Planner)" for legacy support
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

# Codex session helpers - sessions stored in ~/.codex/sessions/
get_codex_sessions() {
  # List available session IDs (directory names)
  if [[ -d "$HOME/.codex/sessions" ]]; then
    ls -t "$HOME/.codex/sessions" 2>/dev/null | head -20
  fi
}

get_codex_session_file_by_id() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1
  find "$HOME/.codex/sessions" -name "*-${session_id}.jsonl" -type f 2>/dev/null | head -1
}

get_codex_session_token_usage() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_codex_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  # Primary: extract from token_count events
  local result=""
  result="$(tail -n 4000 "$session_file" 2>/dev/null | jq -rc '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    select(.type == "event_msg" and .payload.type == "token_count")
    | .payload.info.last_token_usage
    | {
        input_tokens: ((.input_tokens // 0) | as_int),
        output_tokens: (((.output_tokens // 0) + (.reasoning_output_tokens // 0)) | as_int),
        total_tokens: ((.total_tokens // ((.input_tokens // 0) + (.output_tokens // 0) + (.reasoning_output_tokens // 0))) | as_int),
        cost_usd: 0
      }
  ' | tail -1 2>/dev/null || true)"

  if [[ -n "$result" ]]; then
    printf "%s" "$result"
    return 0
  fi

  # Fallback: extract usage from any event carrying .usage or .payload.usage fields
  result="$(tail -n 4000 "$session_file" 2>/dev/null | jq -rc '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    (.usage // .payload.usage // .payload.info.usage // .message.usage // empty) as $u
    | select($u != null)
    | select(($u.input_tokens // $u.prompt_tokens // 0) > 0 or ($u.output_tokens // $u.completion_tokens // 0) > 0)
    | {
        input_tokens: (($u.input_tokens // $u.prompt_tokens // 0) | as_int),
        output_tokens: ((($u.output_tokens // $u.completion_tokens // 0) + ($u.reasoning_output_tokens // 0)) | as_int),
        total_tokens: (($u.total_tokens // (($u.input_tokens // $u.prompt_tokens // 0) + ($u.output_tokens // $u.completion_tokens // 0) + ($u.reasoning_output_tokens // 0))) | as_int),
        cost_usd: 0
      }
  ' | tail -1 2>/dev/null || true)"

  if [[ -n "$result" ]]; then
    printf "%s" "$result"
    return 0
  fi

  return 1
}

get_codex_session_reasoning() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_codex_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  local reasoning
  reasoning="$(tail -n 4000 "$session_file" 2>/dev/null | jq -r '
    select(.type == "event_msg" and .payload.type == "agent_reasoning")
    | (.payload.text // empty)
  ' | tail -n 5 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')"
  [[ -n "$reasoning" ]] && printf "%s" "$reasoning"
}

get_codex_session_tool_events() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_codex_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  tail -n 4000 "$session_file" 2>/dev/null | jq -rc '
    select(.type == "response_item")
    | select((.payload.type // "") as $t | $t == "function_call" or $t == "web_search_call")
    | (.payload + {timestamp: (.timestamp // empty)})
  ' 2>/dev/null || true
}

get_latest_codex_session() {
  # Get the most recent session ID from rollout files
  # Files are: ~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-<session-id>.jsonl
  # Session ID is the UUID at the end of the filename (36 chars: 8-4-4-4-12)
  if [[ -d "$HOME/.codex/sessions" ]]; then
    local latest_file
    latest_file="$(
      find "$HOME/.codex/sessions" -name "rollout-*.jsonl" -type f -print0 2>/dev/null | \
      while IFS= read -r -d '' file; do
        local mtime=""
        if mtime="$(stat -f '%m' "$file" 2>/dev/null)"; then
          :
        else
          mtime="$(stat -c '%Y' "$file" 2>/dev/null || true)"
        fi
        [[ -n "$mtime" ]] && printf '%s\t%s\n' "$mtime" "$file"
      done | sort -nr | head -1 | cut -f2-
    )"
    if [[ -n "$latest_file" ]]; then
      # Extract session ID (last 36 chars before .jsonl)
      local basename="${latest_file##*/}"
      basename="${basename%.jsonl}"
      # Session ID is everything after the timestamp (YYYY-MM-DDTHH-MM-SS-)
      # Format: rollout-YYYY-MM-DDTHH-MM-SS-<session-id>
      echo "${basename: -36}"
    fi
  fi
}

validate_codex_session() {
  local session_id="$1"
  # Check if a session file exists with this ID
  # Files are: ~/.codex/sessions/YYYY/MM/DD/rollout-*-<session-id>.jsonl
  [[ -n "$session_id" ]] && find "$HOME/.codex/sessions" -name "*-${session_id}.jsonl" -type f 2>/dev/null | grep -q .
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
ALLOW_TOOLS=false  # Codex handles tool access via --dangerously-bypass-approvals-and-sandbox
SESSION_ID=""        # Existing session ID to resume
MANAGE_SESSION=""    # Placeholder for new session tracking
SKILL_NAME=""        # Skill to invoke (from .claude/commands/)
QUOTA_STATUS=false   # Check and return quota status
HEALTH_CHECK=false   # P6.4: Health check mode
MODEL=""             # Model selection (gpt4o, o3, o4-mini, or full model name)
PERMISSION_MODE=""   # Permission mode (ignored by codex - no plan mode support)
REASONING_FALLBACK=false # Emit fallback reasoning/tokens from session logs only
IMAGE_ARGS=()        # Optional image attachment(s) for native codex multimodal prompts

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
      # Codex equivalent: enable tool access via bypass flag
      # This flag is consumed here and translates to enabling YOLO mode
      ALLOW_TOOLS=true
      YOLO_MODE=true  # Codex uses bypass mode for tool access
      shift
      ;;
    --image)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--image requires a file path" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      IMAGE_ARGS+=("--image" "$2"); shift 2
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
      # Codex supports sessions via ~/.codex/sessions/ directory
      # Resume with: "$CODEX_CMD" exec resume "$SESSION_ID"
      SESSION_ID="$2"; shift 2
      ;;
    --manage-session)
      # Signal to create/track a new session (Codex auto-creates sessions)
      MANAGE_SESSION="$2"; shift 2
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
    --auth-mode|--codex-auth-mode)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--auth-mode requires one of: auto, subscription, api-key" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      CODEX_AUTH_MODE="$2"; shift 2
      ;;
    --use-api-key|--use-apikey)
      CODEX_AUTH_MODE="api-key"; shift
      ;;
    --use-subscription|--use-login|--use-oauth|--use-chatgpt)
      CODEX_AUTH_MODE="subscription"; shift
      ;;
	--model)
	  MODEL="$2"; shift 2
	  ;;
    --mode|--permission-mode)
      PERMISSION_MODE="$2"; shift 2
      # Note: Codex ignores mode flag - no plan mode support
      ;;
    --reasoning-fallback|--reasoning-fallback-only)
      REASONING_FALLBACK=true; shift
      ;;
    *)
      break
      ;;
  esac
done

CODEX_CMD="${AUTONOM8_CODEX_CMD:-}"
if [[ -z "$CODEX_CMD" ]]; then
  CODEX_CMD="$(resolve_codex_cmd || true)"
fi

if [[ -n "$MODEL" ]]; then
  prepare_requested_model_value "codex" "$MODEL"
  MODEL="$MODEL_PREPARED_VALUE"
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    log_info "Model resolution: $MODEL_RESOLUTION_NOTE"
  fi
fi

# ===================
# Quota Status Mode
# ===================
# If --quota-status flag is provided, return quota status JSON
if [[ "$QUOTA_STATUS" == "true" ]]; then
  # Check for cached usage limit messages
  SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
  LATEST_LIMIT_FILE=""

  if [[ -d "$SYSTEM_MSG_DIR" ]]; then
    # Find most recent codex usage limit file (use find to avoid glob expansion issues)
    LATEST_LIMIT_FILE=$(find "$SYSTEM_MSG_DIR" -name "*-codex-usage-limit.json" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1 || true)
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
        jq -n --arg provider "codex" \
          '{provider: $provider, quota_exhausted: false, source: "estimated", message: "Quota likely reset (>1h since last limit)"}'
      else
        # Still exhausted
        REMAINING=$((RESET_SECONDS - ELAPSED))
        RESET_AT=$(date -j -v+${REMAINING}S "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        jq -n --arg provider "codex" \
              --argjson exhausted true \
              --arg reset_at "$RESET_AT" \
              --argjson reset_in_seconds "$REMAINING" \
              --arg retry_time "$RETRY_TIME" \
              --arg source "cached" \
          '{provider: $provider, quota_exhausted: $exhausted, reset_at: $reset_at, reset_in_seconds: $reset_in_seconds, retry_time: $retry_time, source: $source}'
      fi
    else
      jq -n --arg provider "codex" \
        '{provider: $provider, quota_exhausted: false, source: "unknown", message: "No valid timestamp in limit file"}'
    fi
  else
    # No cached limit file - quota is likely available
    jq -n --arg provider "codex" \
      '{provider: $provider, quota_exhausted: false, source: "no_cache", message: "No recent quota limit detected"}'
  fi
  exit 0
fi

# ===================
# P6.4: Health Check Mode
# ===================
# If --health-check flag is provided, check provider health and return status
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing codex CLI availability"

  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Check if codex CLI is available
  if [[ -z "$CODEX_CMD" ]]; then
    jq -n --arg provider "codex" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "codex CLI not found in PATH or resolved to wrapper recursion",
      session_support: true
    }'
    exit 1
  fi

  # Try a minimal invocation to verify CLI works
  CODEX_HEALTH_CMD=()
  while IFS= read -r -d '' arg; do
    CODEX_HEALTH_CMD+=("$arg")
  done < <(codex_command_args --version)
  HEALTH_OUTPUT=$("${CODEX_HEALTH_CMD[@]}" 2>&1 || echo "version_check_failed")
  HEALTH_EXIT=$?
  AUTH_API_KEY_ENV_PRESENT=false
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    AUTH_API_KEY_ENV_PRESENT=true
  fi
  AUTH_API_KEY_IGNORED=false
  if codex_should_unset_api_key; then
    AUTH_API_KEY_IGNORED=true
  fi

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

	    jq -n --arg provider "codex" \
	          --arg status "ok" \
	          --argjson latency "$LATENCY_MS" \
	          --arg version "$VERSION" \
	          --arg auth_mode "$CODEX_AUTH_MODE" \
	          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
	          --argjson api_key_ignored "$AUTH_API_KEY_IGNORED" \
	          '{
	            provider: $provider,
	            status: $status,
	            latency_ms: $latency,
	            cli_available: true,
	            version: $version,
	            auth_mode: $auth_mode,
	            api_key_env_present: $api_key_env_present,
	            api_key_ignored_for_subscription: $api_key_ignored,
	            session_support: true
	          }'
  else
	    jq -n --arg provider "codex" \
	          --arg error "$HEALTH_OUTPUT" \
	          --argjson latency "$LATENCY_MS" \
	          --arg auth_mode "$CODEX_AUTH_MODE" \
	          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
	          --argjson api_key_ignored "$AUTH_API_KEY_IGNORED" \
	          '{
	            provider: $provider,
	            status: "error",
	            latency_ms: $latency,
	            cli_available: true,
	            error: $error,
	            auth_mode: $auth_mode,
	            api_key_env_present: $api_key_env_present,
	            api_key_ignored_for_subscription: $api_key_ignored,
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
    emit_cli_error_response "reasoning_fallback requires explicit --session-id" "invalid_input" "" 2
    exit 2
  fi
  emit_cli_response "" "$SESSION_ID" "" "" "" ""
  exit 0
fi

# ===================
# Skill Execution Mode
# ===================
# If --skill flag is provided, invoke skill directly via Codex
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME"

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path using a shared lookup order.
  # Shared canonical skills stay first; provider-local copies are fallbacks.
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
      '{dry_run: true, wrapper: "codex.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed"}'
    exit 0
  fi

  # Invoke Codex with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Sandbox and approval bypass for skill execution
  # --dangerously-bypass-approvals-and-sandbox only sets approval:never
  # Must add --sandbox danger-full-access for network/port access
  BYPASS_ARG=""
  SANDBOX_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-bypass-approvals-and-sandbox"
    SANDBOX_ARG="--sandbox danger-full-access"
  fi

  # Determine working directory
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    WORK_DIR="$CORE_DIR/tenants/oxygen"
  fi

  # Session handling for skills (same as agent mode)
  # SESSION_ID comes from --resume flag if resuming previous session
  RESUME_SESSION_ID=""
  CODEX_SESSION_ID=""
  EPHEMERAL_ARG=""
  ALLOW_SESSION_DISCOVERY="true"
  if [[ -n "$SESSION_ID" ]]; then
    if validate_codex_session "$SESSION_ID"; then
      RESUME_SESSION_ID="$SESSION_ID"
      CODEX_SESSION_ID="$SESSION_ID"
      log_verbose "Skill resuming session: $SESSION_ID"
    else
      log_verbose "Skill session $SESSION_ID not found, starting fresh"
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    # codex exec does not accept a caller-supplied session UUID for fresh skill
    # runs. When a managed fresh session is requested, force an ephemeral exec so
    # the wrapper cannot silently reattach ambient global state or claim a
    # provider-backed session ID it cannot prove.
    EPHEMERAL_ARG="--ephemeral"
    ALLOW_SESSION_DISCOVERY="false"
    log_verbose "Skill creating managed logical session requested by caller: $MANAGE_SESSION (running codex exec ephemerally)"
  fi

  # Build model argument if specified
  MODEL_ARG=""
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="-m $MODEL"
    log_verbose "Using model: $MODEL"
  fi

  log_verbose "Invoking codex CLI for skill (WorkDir: ${WORK_DIR:-none}, Resume: ${RESUME_SESSION_ID:-none}, Model: ${MODEL_ARG:-default})"

  # Export CODEX_SANDBOX so Playwright skips WebKit and Firefox (crashes in sandbox)
  export CODEX_SANDBOX=1
  export SKIP_WEBKIT=1
  export SKIP_FIREFOX=1
  if declare -F autonom8_monitor_init >/dev/null; then
    autonom8_monitor_init "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  elif declare -F autonom8_start_live_monitor >/dev/null; then
    autonom8_start_live_monitor "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
      else
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $EPHEMERAL_ARG $SANDBOX_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
      fi
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
      else
        echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $EPHEMERAL_ARG $SANDBOX_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
      fi
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
      else
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $EPHEMERAL_ARG $SANDBOX_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
      fi
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        echo "$SKILL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
      else
        echo "$SKILL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $EPHEMERAL_ARG $SANDBOX_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
      fi
    fi
  fi
  CODEX_EXIT=$?
  set -e
  if declare -F autonom8_stop_live_monitor >/dev/null; then
    autonom8_stop_live_monitor "codex" "${WRAPPER_REQ_ID:-}"
  fi

  if [[ $CODEX_EXIT -eq 0 && -z "$CODEX_SESSION_ID" && "$ALLOW_SESSION_DISCOVERY" == "true" ]]; then
    CODEX_SESSION_ID="$(get_latest_codex_session)"
    if [[ -n "$CODEX_SESSION_ID" ]]; then
      log_verbose "Skill session created: $CODEX_SESSION_ID"
    fi
  fi

  if [[ $CODEX_EXIT -ne 0 ]]; then
    # P58: Filter out Codex session banner from stderr to get actual error
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' | \
      grep -v "^Reading prompt" | \
      grep -v "^OpenAI Codex" | \
      grep -v "^--------" | \
      grep -v "^workdir:" | \
      grep -v "^model:" | \
      grep -v "^provider:" | \
      grep -v "^$" || echo "Unknown error")
    # If filtering removed everything, provide a generic message with exit code
    if [[ -z "$ERROR_MSG" || "$ERROR_MSG" == "Unknown error" ]]; then
      ERROR_MSG="Codex exited with status $CODEX_EXIT (no error details captured)"
    fi
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CODEX_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
      if [[ $CODEX_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CODEX_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    # Truncate error to avoid "argument list too long"
    emit_cli_error_response "$(echo "$ERROR_MSG" | head -c 4000)" "$ERROR_TYPE" "$CODEX_SESSION_ID" "$CODEX_EXIT"
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

    # Wrap in CLIResponse format with session_id if captured
    emit_cli_response "$RESPONSE_TEXT" "$CODEX_SESSION_ID" "$RESPONSE_TEXT" "skill" "$SKILL_NAME" "$STDERR_TEXT"
  else
    emit_cli_error_response "No response from skill execution: $SKILL_NAME" "provider_error" "$CODEX_SESSION_ID" 1
  fi

  exit 0
fi

if [[ -z "$CODEX_CMD" ]]; then
  emit_cli_error_response "codex CLI not found in PATH or resolved to wrapper recursion" "provider_error" "$SESSION_ID" 127
  exit 1
fi

if is_agent_markdown_arg "${1-}"; then
  AGENT_FILE="$1"; shift

  # Resolve agent file path to absolute path
  AGENT_FILE_ABS="$(resolve_agent_markdown_path "$AGENT_FILE")"

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

  MATERIALIZATION_ONLY_MODE=false
  if printf '%s\n%s\n' "${INPUT_DATA:-}" "${AGENT_PROMPT:-}" | grep -Eiq 'bookend-start|bookend_start_contract_scope|BOOKEND-START MATERIALIZATION BOUNDARY|materialization[- ]only'; then
    MATERIALIZATION_ONLY_MODE=true
  fi

  # Build conditional tool rules based on --allowed-tools flag (same pattern as claude.sh)
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
- You MAY use available MCP tools (file, browser, tests) to inspect and verify your work
- Use verification tools after code changes to ensure correctness"
      log_verbose "Tools ENABLED for this invocation"
    fi
    MCP_CONFIG_PATH="$(get_codex_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_codex_mcp_servers "$MCP_CONFIG_PATH"
    fi
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions to prevent codex from responding to persona
  # OPTIMIZATION: When resuming a session, skip persona (already in context) to save tokens
  if [[ -n "${INPUT_DATA}" ]]; then
    if [[ -n "$SESSION_ID" ]]; then
      # RESUME MODE: Session already has persona context - send only task data
      # Fix 5 (RCA-TIMEOUT-JAN12): Send context SUMMARY instead of full content
      # Session already has the full context from previous calls
      log_verbose "Resume mode: skipping persona (already in session context)"
      if [[ -n "$CONTEXT_CONTENT" ]]; then
        # Create a summary of context (first 1KB + note to reference CONTEXT.md)
        CONTEXT_SUMMARY_SIZE=1024
        if [[ ${#CONTEXT_CONTENT} -gt $CONTEXT_SUMMARY_SIZE ]]; then
          CONTEXT_SUMMARY="${CONTEXT_CONTENT:0:$CONTEXT_SUMMARY_SIZE}

[... Context summary - full details in CONTEXT.md ...]"
          log_verbose "Resume mode: using context summary (${CONTEXT_SUMMARY_SIZE} chars) instead of full (${#CONTEXT_CONTENT} chars)"
        else
          CONTEXT_SUMMARY="$CONTEXT_CONTENT"
        fi

        BASE_PROMPT="CONTINUATION - You are resuming from a previous session. Your role and persona are already established.

CONTEXT REMINDER (summary only - you have full context from prior turns):
$CONTEXT_SUMMARY

---

Input Data (YOUR NEXT TASK):
$INPUT_DATA"
        CRITICAL_SUFFIX="

---

CRITICAL INSTRUCTIONS:
$TOOL_RULES
- Continue in your established role from the session
- You already have full project context from previous turns - this is just a reminder
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
    check_prompt_size "$FULL_PROMPT" "codex"
    PROMPT_OVER_LIMIT=$?

    # Save debug prompt if enabled
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "codex"
    fi

    # Log stats in verbose mode
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "codex")
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
      --arg wrapper "codex.sh" \
      --arg provider "codex" \
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

  # Invoke codex and extract final assistant message
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Use JSON schema to enforce structured output for PM assessments
  SCHEMA_ARG=""
  if [[ "${TASK_VAL:-}" == "plan" || "${TASK_VAL:-}" == "proposal" ]]; then
    SCHEMA_PATH="$CORE_DIR/bin/pm-assessment-schema.json"
    if [[ -f "$SCHEMA_PATH" ]]; then
      SCHEMA_ARG="--output-schema $SCHEMA_PATH"
    fi
  fi

  # Use -o flag to write last message directly to file for cleaner output
  # Only use --dangerously-bypass-approvals-and-sandbox if --yolo flag was passed
  # Also add --sandbox danger-full-access for network/port access
  BYPASS_ARG=""
  SANDBOX_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-bypass-approvals-and-sandbox"
    SANDBOX_ARG="--sandbox danger-full-access"
  fi

  # Change to tenant directory for correct context if needed
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

  # Codex uses -c config override for temperature (not --temperature flag)
  # Syntax: "$CODEX_CMD" exec -c temperature=0.4 ...
  TEMP_ARG=""
  if [[ -n "$TEMPERATURE" ]]; then
    TEMP_ARG="-c temperature=$TEMPERATURE"
    log_verbose "Temperature: $TEMPERATURE (via -c config override)"
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

  # Session handling for Codex
  # Sessions stored in ~/.codex/sessions/<session_id>/
  # Resume with: "$CODEX_CMD" exec resume "$SESSION_ID" or codex resume "$SESSION_ID"
  RESUME_SESSION_ID=""
  CODEX_SESSION_ID=""
  DISCOVER_MANAGED_CODEX_SESSION=false
  PREEXEC_CODEX_SESSION_ID=""
  PREEXEC_CODEX_SESSION_ID="$(get_latest_codex_session 2>/dev/null || true)"

  if [[ -n "$SESSION_ID" ]]; then
    # Validate session exists
    if validate_codex_session "$SESSION_ID"; then
      RESUME_SESSION_ID="$SESSION_ID"
      CODEX_SESSION_ID="$SESSION_ID"
      log_verbose "Resuming session: $SESSION_ID"
    else
      log_verbose "Session $SESSION_ID not found in ~/.codex/sessions/, starting fresh"
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    # New session requested by caller. Discover the provider-real rollout session
    # after a successful run instead of persisting the caller-managed logical ID.
    DISCOVER_MANAGED_CODEX_SESSION=true
    log_verbose "Creating new session requested by caller: $MANAGE_SESSION (discovering provider-real Codex session after successful run)"
  fi

  # Fresh Codex calls stream --json stdout into the live monitor while -o still
  # captures the final assistant message. Resume calls intentionally keep the
  # legacy stdout path until resume-streaming behavior is proven separately.

  # Execute in working dir if possible
  # Export CODEX_SANDBOX so Playwright skips WebKit and Firefox (crashes in sandbox)
  export CODEX_SANDBOX=1
  export SKIP_WEBKIT=1
  export SKIP_FIREFOX=1

  # O-6: Set up agent stream logging for per-ticket LLM output capture
  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "$WORK_DIR" ]]; then
    AGENT_LOG_DIR="${WORK_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: $A8_TICKET_ID | Workflow: $A8_WORKFLOW | Provider: codex" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "O-6: Agent stream logging to $AGENT_LOG"
  fi

  # Helper: stderr redirect with optional tee for O-6 logging
  STDERR_REDIR="$TMPFILE_ERR"

  CODEX_INVALID_MODEL_RETRIED=false
  while true; do
  MODEL_ARG=""
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="-m $MODEL"
    log_verbose "Using model: $MODEL"
  fi

  # Start live event monitor for provider observability
  if declare -F autonom8_monitor_init >/dev/null; then
    autonom8_monitor_init "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  elif declare -F autonom8_start_live_monitor >/dev/null; then
    autonom8_start_live_monitor "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  fi

  log_verbose "Invoking codex CLI (WorkDir: ${WORK_DIR:-none}, Bypass: ${BYPASS_ARG:-none}, Temp: ${TEMPERATURE:-default}, Resume: ${RESUME_SESSION_ID:-none}, Model: ${MODEL_ARG:-default})"
  # Temporarily disable set -e to capture exit code properly
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running codex with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
        fi
      else
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
        fi
      fi
      CODEX_EXIT=$?
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3)
        else
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
        fi
      else
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
        else
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
        fi
      fi
      CODEX_EXIT=$?
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
        fi
      else
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
        fi
      fi
      CODEX_EXIT=$?
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3)
        else
          echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
        fi
      else
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
        else
          echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
        fi
      fi
      CODEX_EXIT=$?
    fi
  fi
  set -e

  # Stop live event monitor
  if declare -F autonom8_stop_live_monitor >/dev/null; then
    autonom8_stop_live_monitor "codex" "${WRAPPER_REQ_ID:-}"
  fi

  # O-9: Append stdout response to agent log (stderr tee captures tool calls/thinking,
  # but the final JSON response goes to stdout via -o flag and may be missed)
  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  # Emit the provider-real session ID only when this invocation produced a new
  # rollout file. This avoids inheriting an older global Codex session while
  # still letting unmanaged agent-run calls surface session-backed telemetry.
  if [[ $CODEX_EXIT -eq 0 && -z "$CODEX_SESSION_ID" ]]; then
    DISCOVERED_CODEX_SESSION_ID="$(get_latest_codex_session 2>/dev/null || true)"
    if [[ -n "$DISCOVERED_CODEX_SESSION_ID" && ( -z "$PREEXEC_CODEX_SESSION_ID" || "$DISCOVERED_CODEX_SESSION_ID" != "$PREEXEC_CODEX_SESSION_ID" ) ]]; then
      CODEX_SESSION_ID="$DISCOVERED_CODEX_SESSION_ID"
      log_verbose "Discovered provider-real Codex session: $CODEX_SESSION_ID"
    elif [[ "$DISCOVER_MANAGED_CODEX_SESSION" == "true" ]]; then
      log_verbose "Could not determine new provider-real Codex session id after successful fresh run"
    fi
  fi

  if [[ $CODEX_EXIT -ne 0 ]]; then
    # P6.1: Standardized error handling
    # P58: Filter out Codex session banner from stderr to get actual error
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' | \
      grep -v "^Reading prompt" | \
      grep -v "^OpenAI Codex" | \
      grep -v "^--------" | \
      grep -v "^workdir:" | \
      grep -v "^model:" | \
      grep -v "^provider:" | \
      grep -v "^$" || echo "Unknown error")
    # If filtering removed everything, provide a generic message with exit code
    if [[ -z "$ERROR_MSG" || "$ERROR_MSG" == "Unknown error" ]]; then
      ERROR_MSG="Codex exited with status $CODEX_EXIT (no error details captured)"
    fi
    log_verbose "Codex execution failed: $ERROR_MSG"

    if [[ "$CODEX_INVALID_MODEL_RETRIED" != "true" ]] && declare -F is_invalid_model_error >/dev/null && is_invalid_model_error "$ERROR_MSG"; then
      REQUESTED_MODEL_LABEL="${MODEL_REQUESTED_RAW:-$MODEL}"
      CODEX_INVALID_MODEL_RETRIED=true
      MODEL=""
      MODEL_RESOLUTION_NOTE="codex model '$REQUESTED_MODEL_LABEL' -> 'provider-default' (fallback)"
      log_info "Invalid model '$REQUESTED_MODEL_LABEL' for codex; retrying with provider default"
      : > "$TMPFILE_OUTPUT"
      : > "$TMPFILE_ERR"
      continue
    fi

    # Classify the error type
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CODEX_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE=$(classify_error "$ERROR_MSG")
      if [[ $CODEX_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CODEX_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi

    # Check if this is an invalid session error - fail fast
    if echo "$ERROR_MSG" | grep -qi "session.*not found\|invalid session\|session.*expired\|no such session"; then
      log_verbose "Invalid session detected - clearing stale session"
      rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
      # Use heredoc to avoid "argument list too long" for large error messages
      emit_cli_error_response "$(echo "$ERROR_MSG" | head -c 4000)" "invalid_session" "${CODEX_SESSION_ID:-$SESSION_ID}" "$CODEX_EXIT"
      exit 1
    fi

    # Create system message for recoverable errors (quota, rate_limit)
    if type create_system_message &>/dev/null; then
      create_system_message "codex" "$ERROR_TYPE" "$ERROR_MSG" "$CORE_DIR"
    elif [[ "$ERROR_TYPE" == "quota" ]]; then
      # Fallback: create system message manually for quota errors
      RETRY_TIME=$(echo "$ERROR_MSG" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")
      SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
      mkdir -p "$SYSTEM_MSG_DIR"
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      MSG_FILE="$SYSTEM_MSG_DIR/$(date +%s)-codex-usage-limit.json"
      jq -n \
        --arg ts "$TIMESTAMP" \
        --arg cli "codex" \
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
    emit_cli_error_response "$(echo "$ERROR_MSG" | head -c 4000)" "$ERROR_TYPE" "${CODEX_SESSION_ID:-$SESSION_ID}" "$CODEX_EXIT"
    exit 1
  fi
  break
  done

  # Read the output file which should contain the last message
  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Strip markdown code fences if present (```json ... ```)
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi

    # Wrap in CLIResponse format for Go worker
    # Include session_id if session was used or created
    if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
      emit_cli_response "$RESPONSE_TEXT" "$CODEX_SESSION_ID" "$RESPONSE_TEXT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
    else
      emit_cli_response "$RESPONSE_TEXT" "$CODEX_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
    fi
  else
    # P31.5: Codex exits 0 but output is empty when API returns errors (HTTP 400/401/403).
    # Scan stderr for the actual error detail so Go code gets a meaningful message.
    STDERR_CONTENT=""
    if [[ -f "$TMPFILE_ERR" ]]; then
      STDERR_CONTENT=$(cat "$TMPFILE_ERR" 2>/dev/null | \
        grep -iE "ERROR:|error=|http [45][0-9][0-9]|not supported|unauthorized|forbidden|rate.limit|quota" | \
        head -3 | tr '\n' ' ' || true)
    fi
    if [[ -n "$STDERR_CONTENT" ]]; then
      emit_cli_error_response "Codex API error: $(echo "$STDERR_CONTENT" | head -c 2000)" "provider_error" "${CODEX_SESSION_ID:-$SESSION_ID}" 1
    else
      emit_cli_error_response "No response from Codex CLI" "provider_error" "${CODEX_SESSION_ID:-$SESSION_ID}" 0
    fi
  fi
  # Cleanup temp files (moved after response check so stderr is available for error capture)
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
else
  # Direct prompt mode without an agent file.
  # This path is used by OpenClaw/go_op_supervisor and still needs to honor
  # session reuse, context dir, timeout, and wrapper JSON/error envelopes.
  INPUT_DATA="$(parse_arg_json_or_stdin "$@")"

  BYPASS_ARG=""
  SANDBOX_ARG=""
  MODEL_ARG=""
  TEMP_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-bypass-approvals-and-sandbox"
    SANDBOX_ARG="--sandbox danger-full-access"
  fi
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="-m $MODEL"
  fi
  if [[ -n "$TEMPERATURE" ]]; then
    TEMP_ARG="-c temperature=$TEMPERATURE"
  fi

  if [[ -z "$INPUT_DATA" ]]; then
    log_verbose "Running in direct invocation mode (Model: ${MODEL:-default})"
    "$CODEX_CMD" exec $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$@"
    exit $?
  fi

  FULL_PROMPT="$INPUT_DATA"
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
    log_verbose "Using CONTEXT_DIR as working directory: $WORK_DIR"
  fi

  RESUME_SESSION_ID=""
  CODEX_SESSION_ID=""
  DISCOVER_MANAGED_CODEX_SESSION=false
  PREEXEC_CODEX_SESSION_ID=""
  PREEXEC_CODEX_SESSION_ID="$(get_latest_codex_session 2>/dev/null || true)"

  if [[ -n "$SESSION_ID" ]]; then
    if validate_codex_session "$SESSION_ID"; then
      RESUME_SESSION_ID="$SESSION_ID"
      CODEX_SESSION_ID="$SESSION_ID"
      log_verbose "Resuming session in direct prompt mode: $SESSION_ID"
    else
      log_verbose "Session $SESSION_ID not found in ~/.codex/sessions/, starting fresh"
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    DISCOVER_MANAGED_CODEX_SESSION=true
    log_verbose "Creating new managed session in direct prompt mode: $MANAGE_SESSION"
  fi

  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  log_verbose "Running in direct prompt mode (WorkDir: ${WORK_DIR:-none}, Resume: ${RESUME_SESSION_ID:-none}, Model: ${MODEL_ARG:-default})"
  if declare -F autonom8_monitor_init >/dev/null; then
    autonom8_monitor_init "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  elif declare -F autonom8_start_live_monitor >/dev/null; then
    autonom8_start_live_monitor "codex" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}" "${HOME}/.codex/sessions"
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
      fi
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
      else
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
      fi
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3))
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink))
      fi
    else
      if [[ -n "$RESUME_SESSION_ID" ]]; then
        echo "$FULL_PROMPT" | "$CODEX_CMD" exec resume $MODEL_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} "$RESUME_SESSION_ID" - > "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3)
      else
        echo "$FULL_PROMPT" | "$CODEX_CMD" exec --json $MODEL_ARG $SANDBOX_ARG $BYPASS_ARG $TEMP_ARG ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} -o "$TMPFILE_OUTPUT" 2> >(tee "$TMPFILE_ERR" >&3) > >(codex_json_stream_sink)
      fi
    fi
  fi
  CODEX_EXIT=$?
  set -e
  if declare -F autonom8_stop_live_monitor >/dev/null; then
    autonom8_stop_live_monitor "codex" "${WRAPPER_REQ_ID:-}"
  fi

  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null || true)"

  if [[ $CODEX_EXIT -eq 0 && -z "$CODEX_SESSION_ID" ]]; then
    DISCOVERED_CODEX_SESSION_ID="$(get_latest_codex_session 2>/dev/null || true)"
    if [[ -n "$DISCOVERED_CODEX_SESSION_ID" && ( -z "$PREEXEC_CODEX_SESSION_ID" || "$DISCOVERED_CODEX_SESSION_ID" != "$PREEXEC_CODEX_SESSION_ID" ) ]]; then
      CODEX_SESSION_ID="$DISCOVERED_CODEX_SESSION_ID"
      log_verbose "Discovered provider-real Codex session in direct prompt mode: $CODEX_SESSION_ID"
    elif [[ "$DISCOVER_MANAGED_CODEX_SESSION" == "true" ]]; then
      log_verbose "Could not determine new provider-real Codex session id after successful fresh direct prompt run"
    fi
  fi

  if [[ -z "$CODEX_SESSION_ID" ]]; then
    CODEX_SESSION_ID="$(printf '%s\n' "$STDERR_TEXT" | sed -n 's/^[Ss]ession [Ii][Dd]:[[:space:]]*//p' | head -1)"
  fi

  if [[ $CODEX_EXIT -ne 0 ]]; then
    ERROR_MSG="$(printf '%s\n' "$STDERR_TEXT" | tr -d '\0' | \
      grep -v '^Reading prompt' | \
      grep -v '^OpenAI Codex' | \
      grep -v '^--------' | \
      grep -v '^workdir:' | \
      grep -v '^model:' | \
      grep -v '^provider:' | \
      grep -v '^approval:' | \
      grep -v '^sandbox:' | \
      grep -v '^reasoning effort:' | \
      grep -v '^reasoning summaries:' | \
      grep -v '^session id:' | \
      grep -v '^$' || true)"
    if [[ -z "$ERROR_MSG" ]]; then
      ERROR_MSG="Codex exited with status $CODEX_EXIT (no error details captured)"
    fi
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CODEX_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
      if [[ $CODEX_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CODEX_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    emit_cli_error_response "$(echo "$ERROR_MSG" | head -c 4000)" "$ERROR_TYPE" "${CODEX_SESSION_ID:-$SESSION_ID}" "$CODEX_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
  emit_cli_response "$RESPONSE_TEXT" "$CODEX_SESSION_ID" "$RESPONSE_TEXT" "" "" "$STDERR_TEXT"
fi
