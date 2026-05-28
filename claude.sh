#!/usr/bin/env bash
# Claude CLI wrapper for Autonom8
# Configures workspace and invokes claude CLI with proper context and permissions
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
CLAUDE_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false

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

# Cleanup function to kill child processes on script termination
cleanup() {
  if declare -F autonom8_wrapper_write_cleanup_event >/dev/null; then
    autonom8_wrapper_write_cleanup_event "claude" "${CLAUDE_PID:-}" "${WORK_DIR:-$(pwd)}" "wrapper_cleanup"
  fi
  if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
    autonom8_wrapper_stop_parent_monitor
  fi
  if declare -F autonom8_stop_live_monitor >/dev/null; then
    autonom8_stop_live_monitor "claude"
  fi
  if declare -F autonom8_wrapper_reap_child_tree >/dev/null; then
    autonom8_wrapper_reap_child_tree "claude" "${CLAUDE_PID:-}" "${WORK_DIR:-$(pwd)}" "wrapper_cleanup"
  elif [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$CLAUDE_PID" 2>/dev/null || true
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
CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE=""
CLAUDE_AUTH_UNSET_API_KEY_DECISION=""

claude_auth_status_without_api_key() {
  if [[ -z "${CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE:-}" ]]; then
    if [[ -n "${CLAUDE_BIN:-}" ]]; then
      CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE="$(env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" auth status 2>/dev/null || true)"
    fi
    if [[ -z "${CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE:-}" ]]; then
      CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE="{}"
    fi
  fi
  printf "%s" "$CLAUDE_AUTH_STATUS_WITHOUT_API_KEY_CACHE"
}

claude_subscription_auth_available() {
  local status_json subscription logged_in
  status_json="$(claude_auth_status_without_api_key)"
  logged_in="$(printf "%s" "$status_json" | jq -r '.loggedIn // false' 2>/dev/null || echo "false")"
  subscription="$(printf "%s" "$status_json" | jq -r '.subscriptionType // empty' 2>/dev/null || true)"
  [[ "$logged_in" == "true" && -n "$subscription" && "$subscription" != "null" ]]
}

claude_should_unset_api_key() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    return 1
  fi
  if [[ -n "${CLAUDE_AUTH_UNSET_API_KEY_DECISION:-}" ]]; then
    [[ "$CLAUDE_AUTH_UNSET_API_KEY_DECISION" == "true" ]]
    return $?
  fi

  local mode
  mode="$(printf "%s" "${CLAUDE_AUTH_MODE:-${AUTONOM8_CLAUDE_AUTH_MODE:-auto}}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
  case "$mode" in
    api_key|apikey|env|anthropic_api_key)
      CLAUDE_AUTH_UNSET_API_KEY_DECISION="false"
      ;;
    subscription|oauth|claude_ai|max|pro)
      CLAUDE_AUTH_UNSET_API_KEY_DECISION="true"
      ;;
    auto|"")
      if claude_subscription_auth_available; then
        CLAUDE_AUTH_UNSET_API_KEY_DECISION="true"
      else
        CLAUDE_AUTH_UNSET_API_KEY_DECISION="false"
      fi
      ;;
    *)
      CLAUDE_AUTH_UNSET_API_KEY_DECISION="false"
      ;;
  esac
  [[ "$CLAUDE_AUTH_UNSET_API_KEY_DECISION" == "true" ]]
}

claude_command_args() {
  if [[ -z "${CLAUDE_BIN:-}" ]]; then
    return 127
  fi
  if claude_should_unset_api_key; then
    printf "%s\0" env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" "$@"
  else
    printf "%s\0" "$CLAUDE_BIN" "$@"
  fi
}

claude() {
  if [[ -z "${CLAUDE_BIN:-}" ]]; then
    return 127
  fi
  local cmd_args=()
  while IFS= read -r -d '' arg; do
    cmd_args+=("$arg")
  done < <(claude_command_args "$@")
  "${cmd_args[@]}"
}

# Run command with timeout (preserves stdin for piped input)
run_with_timeout() {
  local timeout_secs="$1"
  shift
  local cmd_args=("$@")
  if [[ "${cmd_args[0]:-}" == "claude" ]]; then
    cmd_args=()
    while IFS= read -r -d '' arg; do
      cmd_args+=("$arg")
    done < <(claude_command_args "${@:2}")
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
    CLAUDE_PID=$pid
    if declare -F autonom8_wrapper_monitor_parent >/dev/null; then
      autonom8_wrapper_monitor_parent "$pid" "claude" "${WORK_DIR:-$(pwd)}"
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
      CLAUDE_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      if declare -F autonom8_wrapper_stop_parent_monitor >/dev/null; then
        autonom8_wrapper_stop_parent_monitor
      fi
      CLAUDE_PID=""
      return $exit_code
    fi
  fi
}

resolve_autonom8_repo_root() {
  local start_path="${1:-}"
  [[ -z "$start_path" ]] && return 1

  local candidate="$start_path"
  if [[ -f "$candidate" ]]; then
    candidate="$(dirname "$candidate")"
  fi

  while [[ -n "$candidate" && "$candidate" != "/" && "$candidate" != "." ]]; do
    if [[ -d "$candidate/go-autonom8" && -d "$candidate/tenants" ]]; then
      printf "%s\n" "$candidate"
      return 0
    fi
    candidate="$(dirname "$candidate")"
  done
  return 1
}

stream_stdout_to_files() {
  local output_file="$1"
  local stream_log="${2:-}"

  if [[ -n "$stream_log" ]]; then
    tee -a "$stream_log" "$output_file" >&3
  else
    tee "$output_file" >&3
  fi
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
      def cache_read_tokens:
        (
          .usage.cache_read_input_tokens
          // .usage.cacheReadInputTokens
          // .usage.cached_input_tokens
          // .usage.cachedInputTokens
          // .usage.input_tokens_details.cache_read
          // .usage.input_tokens_details.cache_read_tokens
          // .usage.inputTokensDetails.cacheRead
          // .usageMetadata.cachedContentTokenCount
          // .usage_metadata.cached_content_token_count
          // .cache_read_input_tokens
          // .cacheReadInputTokens
          // .cached_input_tokens
          // .cachedInputTokens
          // .token_usage.cache_read_input_tokens
          // .token_usage.cached_input_tokens
          // .tokenUsage.cacheReadInputTokens
          // 0
        ) | as_int;
      def cache_creation_tokens:
        (
          .usage.cache_creation_input_tokens
          // .usage.cacheCreationInputTokens
          // .usage.cache_creation_tokens
          // .usage.cacheCreationTokens
          // .usage.input_tokens_details.cache_creation
          // .usage.input_tokens_details.cache_creation_tokens
          // .usage.inputTokensDetails.cacheCreation
          // .cache_creation_input_tokens
          // .cacheCreationInputTokens
          // .cache_creation_tokens
          // .cacheCreationTokens
          // .token_usage.cache_creation_input_tokens
          // .token_usage.cache_creation_tokens
          // .tokenUsage.cacheCreationInputTokens
          // 0
        ) | as_int;
      (cache_read_tokens) as $cache_read
      | (cache_creation_tokens) as $cache_create
      | (
          .usage.input_tokens
          // .usage.inputTokens
          // .input_tokens
          // .inputTokens
          // .token_usage.input_tokens
          // .token_usage.prompt_tokens
          // .prompt_tokens
          // 0
        ) as $base_input_raw
      | ($base_input_raw | as_int) as $base_input
      {
        input_tokens: (($base_input + $cache_read + $cache_create) | as_int),
        output_tokens: ((.usage.output_tokens // .usage.outputTokens // .output_tokens // .outputTokens // .token_usage.output_tokens // .token_usage.completion_tokens // .completion_tokens // 0) | as_int),
        total_tokens: ((.usage.total_tokens // .usage.totalTokens // .total_tokens // .totalTokens // .token_usage.total_tokens // .token_usage.total // .total_tokens_used // 0) | as_int),
        cost_usd: ((.usage.cost_usd // .usage.cost // .cost_usd // .token_usage.cost_usd // .cost // 0) | as_num),
        cache_read_input_tokens: $cache_read,
        cache_creation_input_tokens: $cache_create
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

  if [[ -n "$session_id" ]]; then
    local session_tokens
    session_tokens="$(get_claude_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      local merged_tokens
      merged_tokens="$(jq -cn --argjson primary "$tokens_json" --argjson fallback "$session_tokens" '
        def as_num(v):
          if v == null then 0
          elif (v | type) == "number" then v
          elif (v | type) == "string" then (v | tonumber? // 0)
          else 0
          end;
        {
          input_tokens: ([as_num($primary.input_tokens), as_num($fallback.input_tokens)] | max | floor),
          output_tokens: ([as_num($primary.output_tokens), as_num($fallback.output_tokens)] | max | floor),
          total_tokens: ([as_num($primary.total_tokens), as_num($fallback.total_tokens)] | max | floor),
          cost_usd: ([as_num($primary.cost_usd), as_num($fallback.cost_usd)] | max),
          cache_read_input_tokens: ([as_num($primary.cache_read_input_tokens), as_num($fallback.cache_read_input_tokens)] | max | floor),
          cache_creation_input_tokens: ([as_num($primary.cache_creation_input_tokens), as_num($fallback.cache_creation_input_tokens)] | max | floor)
        }
        | if .total_tokens < (.input_tokens + .output_tokens)
          then .total_tokens = (.input_tokens + .output_tokens)
          else .
          end
      ' 2>/dev/null || true)"
      if [[ -n "$merged_tokens" && "$merged_tokens" != "null" ]]; then
        tokens_json="$merged_tokens"
      else
        tokens_json="$session_tokens"
      fi
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
    session_tool_events="$(get_claude_session_tool_events "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tool_events" ]]; then
      tool_activity_input="${tool_activity_input}"$'\n'"${session_tool_events}"
    fi
  fi

  local tool_activity_json
  tool_activity_json="$(autonom8_tool_activity_json "$tool_activity_input" "$stream_output" "wrapper:claude")"
  AUTONOM8_OPERATIONAL_SUMMARY_JSON=""
  if [[ -n "$session_id" ]]; then
    AUTONOM8_OPERATIONAL_SUMMARY_JSON="$(get_claude_operational_summary "$session_id" 2>/dev/null || true)"
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
    local session_tokens=""
    session_tokens="$(get_claude_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
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

  AUTONOM8_OPERATIONAL_SUMMARY_JSON=""
  if [[ -n "$session_id" ]]; then
    AUTONOM8_OPERATIONAL_SUMMARY_JSON="$(get_claude_operational_summary "$session_id" 2>/dev/null || true)"
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

  tail -n 1200 "$session_file" 2>/dev/null | jq -sc '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    def usage_totals:
      . as $u
      | ((($u.input_tokens // $u.inputTokens // 0) | as_int)) as $input
      | ((($u.cache_read_input_tokens // $u.cacheReadInputTokens // $u.cached_input_tokens // 0) | as_int)) as $cache_read
      | ((($u.cache_creation_input_tokens // $u.cacheCreationInputTokens // 0) | as_int)) as $cache_create
      | ((($u.output_tokens // $u.outputTokens // 0) | as_int)) as $output
      | ((($u.reasoning_output_tokens // $u.reasoningOutputTokens // $u.output_reasoning_tokens // $u.outputReasoningTokens // $u.thinking_tokens // $u.thinkingTokens // 0) | as_int)) as $reasoning_output
      | (($input + $cache_read + $cache_create) | as_int) as $input_total
      | {
          input_tokens: $input_total,
          output_tokens: (($output + $reasoning_output) | as_int),
          total_tokens: (($input_total + $output + $reasoning_output) | as_int),
          cost_usd: 0,
          cache_read_input_tokens: $cache_read,
          cache_creation_input_tokens: $cache_create
        };
    . as $events
    | (reduce range(0; ($events | length)) as $i (-1;
        if (($events[$i].type // "") == "user") then $i else . end
      )) as $last_user_idx
    | ($events
        | to_entries
        | map(
            select(
              (.key > $last_user_idx)
              and ((.value.type // "") == "assistant")
              and (.value.message.usage != null)
            )
            | (.value.message.usage | usage_totals)
          )
      ) as $window
    | if ($window | length) > 0 then
        reduce $window[] as $u (
          {
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            cost_usd: 0,
            cache_read_input_tokens: 0,
            cache_creation_input_tokens: 0
          };
          .input_tokens += ($u.input_tokens // 0)
          | .output_tokens += ($u.output_tokens // 0)
          | .total_tokens += ($u.total_tokens // 0)
          | .cache_read_input_tokens += ($u.cache_read_input_tokens // 0)
          | .cache_creation_input_tokens += ($u.cache_creation_input_tokens // 0)
        )
      else
        ($events
          | map(
              select((.type // "") == "assistant" and .message.usage != null)
              | (.message.usage | usage_totals)
            )
          | if length > 0 then last else empty end
        )
      end
  '
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

get_claude_session_tool_events() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_claude_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  tail -n 1200 "$session_file" 2>/dev/null | jq -rc '
    select(.type == "assistant" and (.message.content | type == "array"))
    | . as $entry
    | .message.content[]?
    | select((.type // "") == "tool_use")
    | {
        type: "tool_use",
        name: (.name // .tool_name // .toolName // empty),
        id: (.id // empty),
        timestamp: ($entry.timestamp // empty),
        input: (.input // {})
      }
  ' 2>/dev/null || true
}

get_claude_operational_summary() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_claude_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  tail -n 1600 "$session_file" 2>/dev/null | jq -s -c \
    --arg home "$HOME" \
    --arg pwd "$PWD" \
    --arg context_dir "${CONTEXT_DIR:-}" '
    def clean($n):
      tostring
      | gsub("[[:space:]]+"; " ")
      | gsub("^\\s+|\\s+$"; "")
      | if length > $n then .[0:$n] else . end;
    def redact:
      tostring
      | gsub("(?i)(ANTHROPIC_API_KEY|OPENAI_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|CURSOR_API_KEY|API_KEY|ACCESS_TOKEN|TOKEN|SECRET|PASSWORD)=[^[:space:]]+"; "<redacted-env>")
      | gsub("(?i)Bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*"; "Bearer <redacted>")
      | gsub("sk-[A-Za-z0-9_-]{10,}"; "sk-<redacted>");
    def normalize_path:
      tostring
      | gsub("^file://"; "")
      | if (($context_dir | length) > 0 and startswith($context_dir + "/")) then .[($context_dir | length + 1):]
        elif (($pwd | length) > 0 and startswith($pwd + "/")) then .[($pwd | length + 1):]
        elif (($home | length) > 0 and startswith($home + "/")) then ("~/" + .[($home | length + 1):])
        else .
        end;
    def path_like:
      tostring
      | gsub("[\"`,;:]+$"; "")
      | normalize_path
      | select(length > 0)
      | select(
          test("(^|/)(src|tests?|public|app|pages|components|styles|lib|pkg|cmd|internal|go-autonom8|tenants|data|docs?)/")
          or test("\\.(go|js|jsx|mjs|cjs|ts|tsx|css|scss|html|json|md|yaml|yml|sh|py|dart|swift|kt|java|rs|tf|sol|sql)$")
        );
    def tool_events:
      [
        .[]
        | select(.type == "assistant" and (.message.content | type == "array"))
        | .message.content[]?
        | select((.type // "") == "tool_use")
        | {name: (.name // .tool_name // .toolName // ""), input: (.input // {})}
      ];
    def tool_name_class($name):
      ($name | tostring | ascii_downcase) as $n
      | if ($n | test("edit|write|multiedit|apply_patch|create|delete|remove|move|rename|replace")) then "write"
        elif ($n | test("read|open|view|grep|glob|ls|list|find")) then "read"
        elif ($n | test("bash|shell|exec|command")) then "command"
        else "other"
        end;
    def values_from($obj):
      [
        $obj.path?,
        $obj.file?,
        $obj.file_path?,
        $obj.filepath?,
        $obj.filename?,
        $obj.relative_path?,
        $obj.absolute_path?,
        $obj.uri?,
        $obj.notebook_path?
      ]
      | map(select(. != null) | path_like);
    def command_from($obj):
      ($obj.command? // $obj.cmd? // $obj.shell_command? // $obj.script? // empty)
      | tostring
      | redact
      | clean(300)
      | select(length > 0);
    def assistant_texts:
      [
        .[]
        | select(.type == "assistant" and (.message.content | type == "array"))
        | .message.content[]?
        | select((.type // "") == "text")
        | (.text // "")
        | clean(800)
        | select(length > 0)
      ];
    def tool_errors:
      [
        .[]
        | select(.type == "user" and (.message.content | type == "array"))
        | .message.content[]?
        | select((.type // "") == "tool_result")
        | select((.is_error // false) == true)
        | (.content // .text // .message // "tool_result_error")
        | redact
        | clean(280)
        | select(length > 0)
      ];
    (tool_events) as $tools
    | (assistant_texts) as $texts
    | {
        intent: (($texts[0] // "") | clean(480)),
        files_read: ([
          $tools[]
          | select(tool_name_class(.name) == "read")
          | values_from(.input)[]
        ] | unique | .[:20]),
        files_changed: ([
          $tools[]
          | select(tool_name_class(.name) == "write")
          | values_from(.input)[]
        ] | unique | .[:20]),
        commands_run: ([
          $tools[]
          | select(tool_name_class(.name) == "command")
          | command_from(.input)
        ] | unique | .[:10]),
        tool_write_count: ([$tools[] | select(tool_name_class(.name) == "write")] | length),
        errors: (tool_errors | unique | .[:10]),
        verification: ([
          $tools[]
          | select(tool_name_class(.name) == "command")
          | command_from(.input)
          | select(test("(?i)(go test|npm test|pnpm test|yarn test|pytest|playwright|lighthouse|axe|eslint|tsc|cargo test|flutter test|xcodebuild|terraform plan)"))
        ] | unique | .[:10]),
        final_summary: (($texts[-1] // "") | clean(800)),
        signed_thinking_blocks: ([
          .[]
          | select(.type == "assistant" and (.message.content | type == "array"))
          | .message.content[]?
          | select((.type // "") == "thinking")
          | select(((.signature // .thinking_signature // "") | tostring | length) > 0)
        ] | length),
        source: "claude_session_jsonl"
      }
      | select(
          ((.intent // "") | length) > 0
          or ((.final_summary // "") | length) > 0
          or ((.files_read // []) | length) > 0
          or ((.files_changed // []) | length) > 0
          or ((.commands_run // []) | length) > 0
          or ((.errors // []) | length) > 0
          or ((.signed_thinking_blocks // 0) > 0)
        )
  ' 2>/dev/null || return 1
}

if [[ "${AUTONOM8_WRAPPER_UNIT_TEST:-}" == "claude_operational_summary" ]]; then
  if [[ $# -lt 1 || -z "${1:-}" ]]; then
    jq -n '{error:"missing session id"}'
    exit 2
  fi
  if ! get_claude_operational_summary "$1"; then
    jq -n --arg session_id "$1" '{error:"operational summary unavailable", session_id:$session_id}'
    exit 1
  fi
  exit 0
fi

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
IMAGE_PATHS=()       # Optional image attachment path(s) from the uniform wrapper interface
CLAUDE_AUTH_MODE="${AUTONOM8_CLAUDE_AUTH_MODE:-auto}" # auto, subscription, or api-key

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
    --image)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--image requires a file path" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      IMAGE_PATHS+=("$2"); shift 2
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
    --auth-mode|--claude-auth-mode)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        emit_cli_error_response "--auth-mode requires one of: auto, subscription, api-key" "invalid_input" "$SESSION_ID" 3
        exit 3
      fi
      CLAUDE_AUTH_MODE="$2"; shift 2
      ;;
    --use-api-key|--use-apikey)
      CLAUDE_AUTH_MODE="api-key"; shift
      ;;
    --use-subscription|--use-claude-login|--use-login|--use-oauth)
      CLAUDE_AUTH_MODE="subscription"; shift
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

if [[ -n "$MODEL" ]]; then
  prepare_requested_model_value "claude" "$MODEL"
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
  log_verbose "Health check mode: testing claude CLI availability and headless response"

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

  # Try minimal invocations to verify CLI availability and that the account can
  # actually receive model tokens. Version-only checks can pass while billing or
  # profile state still rejects live requests.
  HEALTH_OUTPUT=$(claude --version 2>&1 || echo "version_check_failed")
  HEALTH_EXIT=$?
  AUTH_API_KEY_ENV_PRESENT=false
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    AUTH_API_KEY_ENV_PRESENT=true
  fi
  AUTH_API_KEY_IGNORED=false
  if claude_should_unset_api_key; then
    AUTH_API_KEY_IGNORED=true
    AUTH_STATUS_JSON="$(claude_auth_status_without_api_key)"
  else
    AUTH_STATUS_JSON="$("$CLAUDE_BIN" auth status 2>/dev/null || echo "{}")"
  fi
  AUTH_METHOD="$(printf "%s" "$AUTH_STATUS_JSON" | jq -r '.authMethod // ""' 2>/dev/null || true)"
  AUTH_PROVIDER="$(printf "%s" "$AUTH_STATUS_JSON" | jq -r '.apiProvider // ""' 2>/dev/null || true)"
  AUTH_API_KEY_SOURCE="$(printf "%s" "$AUTH_STATUS_JSON" | jq -r '.apiKeySource // ""' 2>/dev/null || true)"
  AUTH_SUBSCRIPTION_TYPE="$(printf "%s" "$AUTH_STATUS_JSON" | jq -r '.subscriptionType // ""' 2>/dev/null || true)"

  PROBE_OUTPUT_FILE="$(mktemp)"
  PROBE_ERR_FILE="$(mktemp)"
  PROBE_TIMEOUT="${AUTONOM8_CLAUDE_HEALTH_PROBE_TIMEOUT_SECONDS:-30}"
  PROBE_MODEL="${AUTONOM8_CLAUDE_HEALTH_PROBE_MODEL:-}"
  PROBE_PROMPT='Return exactly this JSON and no markdown: {"ok":true,"probe":"claude_health"}'
  PROBE_START=$(date +%s%N 2>/dev/null || date +%s)
  set +e
  PROBE_ARGS=(--print --output-format text)
  if [[ -n "$PROBE_MODEL" ]]; then
    PROBE_ARGS+=(--model "$PROBE_MODEL")
  fi
  run_with_timeout "$PROBE_TIMEOUT" claude "${PROBE_ARGS[@]}" "$PROBE_PROMPT" > "$PROBE_OUTPUT_FILE" 2> "$PROBE_ERR_FILE"
  PROBE_EXIT=$?
  set -e
  PROBE_END=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#PROBE_START} -gt 10 ]]; then
    PROBE_LATENCY_MS=$(( (PROBE_END - PROBE_START) / 1000000 ))
  else
    PROBE_LATENCY_MS=$(( (PROBE_END - PROBE_START) * 1000 ))
  fi
  PROBE_OUTPUT="$(cat "$PROBE_OUTPUT_FILE" 2>/dev/null || true)"
  PROBE_ERR="$(cat "$PROBE_ERR_FILE" 2>/dev/null || true)"
  rm -f "$PROBE_OUTPUT_FILE" "$PROBE_ERR_FILE"

  END_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Calculate latency (handle both nanosecond and second precision)
  if [[ ${#START_TIME} -gt 10 ]]; then
    LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  else
    LATENCY_MS=$(( (END_TIME - START_TIME) * 1000 ))
  fi

  PROBE_RESPONSE="$(printf "%s" "$PROBE_OUTPUT" | jq -r 'if type == "object" and has("result") then .result else . end' 2>/dev/null || printf "%s" "$PROBE_OUTPUT")"
  PROBE_OK=false
  if [[ $PROBE_EXIT -eq 0 ]] && [[ -n "$PROBE_RESPONSE" ]] && printf "%s" "$PROBE_RESPONSE" | jq -e '.ok == true and .probe == "claude_health"' >/dev/null 2>&1; then
    PROBE_OK=true
  fi

  if [[ $HEALTH_EXIT -eq 0 && "$PROBE_OK" == "true" ]]; then
    # Extract version if available
    VERSION=$(echo "$HEALTH_OUTPUT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

    jq -n --arg provider "claude" \
          --arg status "ok" \
          --argjson latency "$LATENCY_MS" \
          --argjson probe_latency "$PROBE_LATENCY_MS" \
          --arg version "$VERSION" \
          --arg probe_model "$PROBE_MODEL" \
          --arg auth_mode "$CLAUDE_AUTH_MODE" \
          --arg auth_method "$AUTH_METHOD" \
          --arg auth_provider "$AUTH_PROVIDER" \
          --arg api_key_source "$AUTH_API_KEY_SOURCE" \
          --arg subscription_type "$AUTH_SUBSCRIPTION_TYPE" \
          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
          --argjson api_key_ignored "$AUTH_API_KEY_IGNORED" \
          '{
            provider: $provider,
            status: $status,
            latency_ms: $latency,
            response_probe_latency_ms: $probe_latency,
            cli_available: true,
            response_probe_ok: true,
            version: $version,
            probe_model: $probe_model,
            auth_mode: $auth_mode,
            auth_method: $auth_method,
            auth_provider: $auth_provider,
            api_key_source: $api_key_source,
            subscription_type: $subscription_type,
            api_key_env_present: $api_key_env_present,
            api_key_ignored_for_subscription: $api_key_ignored,
            session_support: true
          }'
  else
    jq -n --arg provider "claude" \
          --arg error "$HEALTH_OUTPUT" \
          --arg probe_error "$PROBE_ERR" \
          --arg probe_output "$PROBE_OUTPUT" \
          --argjson latency "$LATENCY_MS" \
          --argjson probe_latency "$PROBE_LATENCY_MS" \
          --argjson probe_ok "$PROBE_OK" \
          --arg probe_model "$PROBE_MODEL" \
          --arg auth_mode "$CLAUDE_AUTH_MODE" \
          --arg auth_method "$AUTH_METHOD" \
          --arg auth_provider "$AUTH_PROVIDER" \
          --arg api_key_source "$AUTH_API_KEY_SOURCE" \
          --arg subscription_type "$AUTH_SUBSCRIPTION_TYPE" \
          --argjson api_key_env_present "$AUTH_API_KEY_ENV_PRESENT" \
          --argjson api_key_ignored "$AUTH_API_KEY_IGNORED" \
          '{
            provider: $provider,
            status: "error",
            latency_ms: $latency,
            response_probe_latency_ms: $probe_latency,
            cli_available: true,
            error: $error,
            response_probe_ok: $probe_ok,
            probe_error: $probe_error,
            probe_output: $probe_output,
            probe_model: $probe_model,
            auth_mode: $auth_mode,
            auth_method: $auth_method,
            auth_provider: $auth_provider,
            api_key_source: $api_key_source,
            subscription_type: $subscription_type,
            api_key_env_present: $api_key_env_present,
            api_key_ignored_for_subscription: $api_key_ignored,
            session_support: true
          }'
    exit 1
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
  SKILL_PROMPT="$(append_image_prompt_context "$SKILL_PROMPT")"

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
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> >(tee "$TMPFILE_ERR" >&3) > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> >(tee "$TMPFILE_ERR" >&3) > "$TMPFILE_OUTPUT"
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> >(tee "$TMPFILE_ERR" >&3) > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG $MODEL_ARG $MODE_ARG 2> >(tee "$TMPFILE_ERR" >&3) > "$TMPFILE_OUTPUT"
    fi
  fi
  CLAUDE_EXIT=$?
  set -e

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)
    if [[ -z "$ERROR_MSG" && -s "$TMPFILE_OUTPUT" ]]; then
      ERROR_MSG="$(jq -r '
        if .is_error == true
        then (.result // (.errors | join(", ")) // .error // empty)
        else (.error // empty)
        end
      ' "$TMPFILE_OUTPUT" 2>/dev/null || true)"
    fi
    if [[ -z "$ERROR_MSG" && -s "$TMPFILE_OUTPUT" ]]; then
      ERROR_MSG="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0' || true)"
    fi
    if [[ -z "$ERROR_MSG" ]]; then
      ERROR_MSG="Unknown error"
    fi
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CLAUDE_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE=$(classify_error "$ERROR_MSG")
      if [[ $CLAUDE_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CLAUDE_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "" "$CLAUDE_EXIT"
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

  # Build conditional tool rules based on --allow-tools flag
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
      TOOL_RULES="- You MAY use available MCP tools (file, browser, tests) to inspect and verify your work
- Use verification tools after code changes to ensure correctness
- You can read files and explore the codebase as needed"
      log_verbose "Tools ENABLED for this invocation"
    fi
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
    FULL_PROMPT="$(append_image_prompt_context "${BASE_PROMPT}${CRITICAL_SUFFIX}")"
  else
    FULL_PROMPT="$(append_image_prompt_context "$AGENT_PROMPT")"
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

  PROJECT_ROOT_DIR=""
  if [[ -n "$CONTEXT_DIR" ]]; then
    PROJECT_ROOT_DIR="$(resolve_autonom8_repo_root "$CONTEXT_DIR" 2>/dev/null || true)"
  fi
  if [[ -z "$PROJECT_ROOT_DIR" && -n "$TENANT_DIR" ]]; then
    PROJECT_ROOT_DIR="$(resolve_autonom8_repo_root "$TENANT_DIR" 2>/dev/null || true)"
  fi
  if [[ -z "$PROJECT_ROOT_DIR" ]]; then
    PROJECT_ROOT_DIR="$(resolve_autonom8_repo_root "$PWD" 2>/dev/null || true)"
  fi
  if [[ -n "$PROJECT_ROOT_DIR" ]]; then
    log_verbose "Resolved project root: $PROJECT_ROOT_DIR"
  fi
  PROJECT_PARENT_DIR=""
  if [[ -n "$PROJECT_ROOT_DIR" ]]; then
    PROJECT_PARENT_DIR="$(dirname "$PROJECT_ROOT_DIR")"
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

  # Build permission mode argument if specified
  MODE_ARG=""
  if [[ -n "$PERMISSION_MODE" ]]; then
    MODE_ARG="--permission-mode $PERMISSION_MODE"
    log_verbose "Using permission mode: $PERMISSION_MODE"
  fi

  ADD_DIR_ARGS=""
  if [[ -n "$PROJECT_ROOT_DIR" && "$PROJECT_ROOT_DIR" != "$WORK_DIR" ]]; then
    ADD_DIR_ARGS="--add-dir $PROJECT_ROOT_DIR"
    log_verbose "Adding Claude read scope: $PROJECT_ROOT_DIR"
  fi
  if [[ -n "$PROJECT_PARENT_DIR" && "$PROJECT_PARENT_DIR" != "$WORK_DIR" && "$PROJECT_PARENT_DIR" != "$PROJECT_ROOT_DIR" ]]; then
    ADD_DIR_ARGS="$ADD_DIR_ARGS --add-dir $PROJECT_PARENT_DIR"
    log_verbose "Adding Claude parent read scope: $PROJECT_PARENT_DIR"
  fi

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

  CLAUDE_INVALID_MODEL_RETRIED=false
  while true; do
    MODEL_ARG=""
    if [[ -n "$MODEL" ]]; then
      MODEL_ARG="--model $MODEL"
      log_verbose "Using model: $MODEL"
    fi

        # Start live event monitor for provider observability
    if declare -F autonom8_monitor_init >/dev/null; then
      autonom8_monitor_init "claude" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}"
    elif declare -F autonom8_start_live_monitor >/dev/null; then
      autonom8_start_live_monitor "claude" "${WRAPPER_REQ_ID:-}" "$TMPFILE_ERR" "${WORK_DIR:-$(pwd)}"
    fi

log_verbose "Invoking claude CLI (WorkDir: ${WORK_DIR:-none}, Bypass: ${BYPASS_ARG:-none}, Session: ${SESSION_ARG:-none}, Model: ${MODEL_ARG:-default}, Mode: ${MODE_ARG:-default}, Format: $OUTPUT_FORMAT)"

    : > "$TMPFILE_OUTPUT"
    : > "$TMPFILE_ERR"

    # Use --print mode for non-interactive operation
    set +e
    if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
      log_verbose "Running claude with timeout: ${CLI_TIMEOUT}s"
      if [[ -n "$WORK_DIR" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT" "$AGENT_LOG"))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT"))
        fi
        CLAUDE_EXIT=$?
      else
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT" "$AGENT_LOG")
        else
          echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT")
        fi
        CLAUDE_EXIT=$?
      fi
    else
      if [[ -n "$WORK_DIR" ]]; then
        if [[ -n "$AGENT_LOG" ]]; then
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT" "$AGENT_LOG"))
        else
          (cd "$WORK_DIR" && echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT"))
        fi
        CLAUDE_EXIT=$?
      else
        if [[ -n "$AGENT_LOG" ]]; then
          echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee -a "$AGENT_LOG" "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT" "$AGENT_LOG")
        else
          echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT")
        fi
        CLAUDE_EXIT=$?
      fi
    fi
    set -e

    # Stop live event monitor
    if declare -F autonom8_stop_live_monitor >/dev/null; then
      autonom8_stop_live_monitor "claude" "${WRAPPER_REQ_ID:-}"
    fi

    # O-9: stdout is streamed live above; append only a footer with the captured byte count.
    if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
      echo "" >> "$AGENT_LOG"
      echo "tokens used" >> "$AGENT_LOG"
      wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
    fi

    if [[ $CLAUDE_EXIT -eq 0 ]]; then
      break
    fi

    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)
    if [[ -z "$ERROR_MSG" && -s "$TMPFILE_OUTPUT" ]]; then
      ERROR_MSG="$(jq -r '
        if .is_error == true
        then (.result // (.errors | join(", ")) // empty)
        else empty
        end
      ' "$TMPFILE_OUTPUT" 2>/dev/null || true)"
    fi
    if [[ -z "$ERROR_MSG" && -s "$TMPFILE_OUTPUT" ]]; then
      ERROR_MSG="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0' || true)"
    fi
    if [[ -z "$ERROR_MSG" ]]; then
      ERROR_MSG="Unknown error"
    fi
    log_verbose "Claude execution failed: $ERROR_MSG"

    if [[ "$CLAUDE_INVALID_MODEL_RETRIED" != "true" ]] && declare -F is_invalid_model_error >/dev/null && is_invalid_model_error "$ERROR_MSG"; then
      REQUESTED_MODEL_LABEL="${MODEL_REQUESTED_RAW:-$MODEL}"
      CLAUDE_INVALID_MODEL_RETRIED=true
      MODEL=""
      MODEL_RESOLUTION_NOTE="claude model '$REQUESTED_MODEL_LABEL' -> 'provider-default' (fallback)"
      log_info "Invalid model '$REQUESTED_MODEL_LABEL' for claude; retrying with provider default"
      continue
    fi

    # Classify the error type
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CLAUDE_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE=$(classify_error "$ERROR_MSG")
      if [[ $CLAUDE_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CLAUDE_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi

    # Create system message for recoverable errors (quota, rate_limit)
    if type create_system_message &>/dev/null; then
      create_system_message "claude" "$ERROR_TYPE" "$ERROR_MSG" "$CORE_DIR"
    elif [[ "$ERROR_TYPE" == "quota" ]]; then
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
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "${CLAUDE_SESSION_ID:-$SESSION_ID}" "$CLAUDE_EXIT"
    exit 1
  done

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
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    emit_cli_response "$RESPONSE_TEXT" "$CLAUDE_SESSION_ID" "$RAW_OUTPUT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$STDERR_TEXT"
  else
    emit_cli_response "$RESPONSE_TEXT" "$CLAUDE_SESSION_ID" "$RAW_OUTPUT" "" "" "$STDERR_TEXT"
  fi
else
  # Direct prompt mode without an agent file.
  # This path is used by go_op_supervisor and still needs wrapper JSON,
  # session reuse, and streamed provider output.
  INPUT_DATA="$(parse_arg_json_or_stdin "$@")"

  BYPASS_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-skip-permissions"
  fi

  if [[ -z "$INPUT_DATA" ]]; then
    log_verbose "Running in direct invocation mode"
    if [[ ${#IMAGE_PATHS[@]} -gt 0 ]]; then
      DIRECT_PROMPT="$(append_image_prompt_context "$*")"
      claude --print --output-format text $BYPASS_ARG "$DIRECT_PROMPT"
    else
      claude --print --output-format text $BYPASS_ARG "$@"
    fi
    exit $?
  fi
  INPUT_DATA="$(append_image_prompt_context "$INPUT_DATA")"

  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
    log_verbose "Using CONTEXT_DIR as working directory: $WORK_DIR"
  fi

  PROJECT_ROOT_DIR=""
  if [[ -n "$CONTEXT_DIR" ]]; then
    PROJECT_ROOT_DIR="$(resolve_autonom8_repo_root "$CONTEXT_DIR" 2>/dev/null || true)"
  fi
  if [[ -z "$PROJECT_ROOT_DIR" ]]; then
    PROJECT_ROOT_DIR="$(resolve_autonom8_repo_root "$PWD" 2>/dev/null || true)"
  fi
  if [[ -n "$PROJECT_ROOT_DIR" ]]; then
    log_verbose "Resolved project root in direct prompt mode: $PROJECT_ROOT_DIR"
  fi
  PROJECT_PARENT_DIR=""
  if [[ -n "$PROJECT_ROOT_DIR" ]]; then
    PROJECT_PARENT_DIR="$(dirname "$PROJECT_ROOT_DIR")"
  fi

  MODEL_ARG=""
  if [[ -n "$MODEL" ]]; then
    MODEL_ARG="--model $MODEL"
    log_verbose "Using model: $MODEL"
  fi

  SESSION_ARG=""
  OUTPUT_FORMAT="json"
  CLAUDE_SESSION_ID=""

  if [[ -n "$SESSION_ID" ]]; then
    SESSION_ARG="--resume $SESSION_ID"
    CLAUDE_SESSION_ID="$SESSION_ID"
    log_verbose "Resuming session in direct prompt mode: $SESSION_ID"
  elif [[ -n "${MANAGE_SESSION:-}" || "${NEW_SESSION:-false}" == "true" ]]; then
    log_verbose "Creating new session in direct prompt mode"
  fi

  MODE_ARG=""
  if [[ -n "$PERMISSION_MODE" ]]; then
    MODE_ARG="--permission-mode $PERMISSION_MODE"
    log_verbose "Using permission mode: $PERMISSION_MODE"
  fi

  ADD_DIR_ARGS=""
  if [[ -n "$PROJECT_ROOT_DIR" && "$PROJECT_ROOT_DIR" != "$WORK_DIR" ]]; then
    ADD_DIR_ARGS="--add-dir $PROJECT_ROOT_DIR"
    log_verbose "Adding Claude read scope in direct prompt mode: $PROJECT_ROOT_DIR"
  fi
  if [[ -n "$PROJECT_PARENT_DIR" && "$PROJECT_PARENT_DIR" != "$WORK_DIR" && "$PROJECT_PARENT_DIR" != "$PROJECT_ROOT_DIR" ]]; then
    ADD_DIR_ARGS="$ADD_DIR_ARGS --add-dir $PROJECT_PARENT_DIR"
    log_verbose "Adding Claude parent read scope in direct prompt mode: $PROJECT_PARENT_DIR"
  fi

  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  log_verbose "Running in direct prompt mode (WorkDir: ${WORK_DIR:-none}, Session: ${SESSION_ARG:-none}, Model: ${MODEL:-default})"

  set +e
    if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$INPUT_DATA" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT"))
      CLAUDE_EXIT=$?
    else
      echo "$INPUT_DATA" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT")
      CLAUDE_EXIT=$?
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$INPUT_DATA" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT"))
      CLAUDE_EXIT=$?
    else
      echo "$INPUT_DATA" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG $MODEL_ARG $MODE_ARG $ADD_DIR_ARGS 2> >(tee "$TMPFILE_ERR" >&3) > >(stream_stdout_to_files "$TMPFILE_OUTPUT")
      CLAUDE_EXIT=$?
    fi
  fi
  set -e

  RAW_OUTPUT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    ERROR_MSG="$STDERR_TEXT"
    if [[ -z "$ERROR_MSG" && -n "$RAW_OUTPUT" ]]; then
      ERROR_MSG="$RAW_OUTPUT"
    fi
    if [[ -z "$ERROR_MSG" ]]; then
      ERROR_MSG="Unknown error"
    fi
    ERROR_TYPE="provider_error"
    if type classify_wrapper_error &>/dev/null; then
      ERROR_TYPE="$(classify_wrapper_error "$ERROR_MSG" "$CLAUDE_EXIT" "provider_error")"
    elif type classify_error &>/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
      if [[ $CLAUDE_EXIT -eq 124 && "$ERROR_TYPE" != "rate_limit" && "$ERROR_TYPE" != "quota" ]]; then
        ERROR_TYPE="timeout"
      fi
    elif [[ $CLAUDE_EXIT -eq 124 ]]; then
      ERROR_TYPE="timeout"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "${CLAUDE_SESSION_ID:-$SESSION_ID}" "$CLAUDE_EXIT"
    exit 1
  fi

  if [[ -z "$RAW_OUTPUT" || "$RAW_OUTPUT" == "null" ]]; then
    emit_cli_error_response "No response from Claude CLI" "provider_error" "${CLAUDE_SESSION_ID:-$SESSION_ID}" 0
    exit 0
  fi

  CLAUDE_SESSION_ID="$(echo "$RAW_OUTPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  RESPONSE_TEXT="$(echo "$RAW_OUTPUT" | jq -r '.result // empty' 2>/dev/null || true)"
  if [[ -z "$RESPONSE_TEXT" ]]; then
    IS_ERROR="$(echo "$RAW_OUTPUT" | jq -r '.is_error // false' 2>/dev/null || true)"
    if [[ "$IS_ERROR" == "true" ]]; then
      ERROR_MSGS="$(echo "$RAW_OUTPUT" | jq -r '.errors | join(", ")' 2>/dev/null || true)"
      emit_cli_error_response "${ERROR_MSGS:-Unknown error}" "provider_error" "${CLAUDE_SESSION_ID:-$SESSION_ID}" 1
      exit 1
    fi
    RESPONSE_TEXT="$RAW_OUTPUT"
  fi

  if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
    RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
  elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
    RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
  fi

  emit_cli_response "$RESPONSE_TEXT" "$CLAUDE_SESSION_ID" "$RAW_OUTPUT" "" "" "$STDERR_TEXT"
fi
