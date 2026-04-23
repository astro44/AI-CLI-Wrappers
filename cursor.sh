#!/usr/bin/env bash
# Cursor CLI wrapper for Autonom8
# Configures workspace and invokes the Cursor Agent CLI with proper context and permissions.
# Resolves, in order:
#   1. AUTONOM8_CURSOR_AGENT or CURSOR_AGENT_BIN_OVERRIDE — full path to the real binary (optional)
#   2. cursor-agent — legacy / alternate install name on PATH
#   3. agent — official Cursor CLI (https://cursor.com/docs/cli/overview), verified not to be another tool named agent
# Updated to support --dry-run, --verbose, macOS keychain refresh, and
# non-interactive MCP startup approval (v2.3).
# Fix 1 (CLI): pass --approve-mcps on all headless --print invocations by default
# so workers do not block on "MCP Server Approval Required". Opt out with:
#   AUTONOM8_CURSOR_AUTO_APPROVE_MCPS=0

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

WRAPPER_REQ_ID="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-}}"
if [[ -n "${WRAPPER_REQ_ID}" ]]; then
  exec 3>&2
  exec 2> >(while IFS= read -r __a8_line; do
    printf '[req=%s] %s\n' "${WRAPPER_REQ_ID}" "${__a8_line}" >&3
  done)
fi

# Track child process PID for cleanup on script termination
CURSOR_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker
RESPONSE_EMITTED=false
CURSOR_INVALID_MODEL_RETRIED=false

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

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$CURSOR_PID" ]] && kill -0 "$CURSOR_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$CURSOR_PID" 2>/dev/null || kill "$CURSOR_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$CURSOR_PID" 2>/dev/null || kill -9 "$CURSOR_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT TERM INT

cursor_login_home() {
  local current_home="${HOME:-}"
  if [[ -n "$current_home" ]] && { [[ -f "$current_home/.env" ]] || [[ -f "$current_home/Library/Keychains/login.keychain-db" ]]; }; then
    printf "%s" "$current_home"
    return 0
  fi

  local user="${USER:-}"
  if [[ -z "$user" ]]; then
    user="$(id -un 2>/dev/null || true)"
  fi

  local resolved_home=""
  if [[ -n "$user" ]] && command -v dscl >/dev/null 2>&1; then
    resolved_home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}')"
  fi
  if [[ -z "$resolved_home" && -n "$user" ]]; then
    resolved_home="$(eval "printf '%s' ~$user" 2>/dev/null || true)"
  fi

  if [[ -n "$resolved_home" && "$resolved_home" != "~"* && -d "$resolved_home" ]]; then
    printf "%s" "$resolved_home"
    return 0
  fi

  printf "%s" "$current_home"
}

# True if this executable is Cursor's agent CLI (avoids picking an unrelated "agent" on PATH).
is_cursor_agent_executable() {
  local bin="$1"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  case "$(basename "$bin")" in
    cursor-agent) return 0 ;;
  esac
  if "$bin" --version 2>&1 | grep -qiE 'cursor'; then
    return 0
  fi
  if "$bin" about 2>&1 | grep -qiE 'cursor'; then
    return 0
  fi
  return 1
}

resolve_cursor_agent_cmd() {
  local wrapper_path=""
  wrapper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

  local override=""
  for override in "${AUTONOM8_CURSOR_AGENT:-}" "${CURSOR_AGENT_BIN_OVERRIDE:-}"; do
    if [[ -n "$override" && -x "$override" ]]; then
      echo "$override"
      return 0
    fi
  done

  local candidate=""
  local resolved=""
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    resolved="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")"
    if [[ "$resolved" == "$wrapper_path" ]]; then
      continue
    fi
    echo "$candidate"
    return 0
  done < <(which -a cursor-agent 2>/dev/null | awk '!seen[$0]++')

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    resolved="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")"
    if [[ "$resolved" == "$wrapper_path" ]]; then
      continue
    fi
    if is_cursor_agent_executable "$resolved"; then
      echo "$candidate"
      return 0
    fi
  done < <(which -a agent 2>/dev/null | awk '!seen[$0]++')

  # Official installer often places the binary here before ~/.local/bin is on PATH.
  # Use the login home, not necessarily process HOME, because Go/SSH workers may
  # sanitize HOME while Cursor is still installed under the login user's home.
  local login_home=""
  login_home="$(cursor_login_home)"
  for candidate in "${login_home}/.local/bin/cursor-agent" "${login_home}/.local/bin/agent"; do
    [[ -z "$login_home" || ! -x "$candidate" ]] && continue
    resolved="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
    if [[ "$resolved" == "$wrapper_path" ]]; then
      continue
    fi
    if is_cursor_agent_executable "$resolved" || [[ "$(basename "$candidate")" == "cursor-agent" ]] || [[ "$candidate" == *"/.local/bin/agent" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

CURSOR_AGENT_BIN="$(resolve_cursor_agent_cmd || true)"

# macOS keychain bootstrap
#
# Cursor stores CLI credentials in the macOS login keychain. Workers launched
# over SSH do not reliably inherit an unlocked GUI keychain, and new Cursor
# sessions can fail immediately with "Your macOS login keychain is locked" even
# when the long-running worker was started after a manual unlock.
#
# This wrapper refreshes keychain access immediately before each Cursor CLI
# process. It is intentionally narrow:
#   - Darwin only; Linux and CI paths are no-ops.
#   - No secret is logged.
#   - Existing Cursor auth is still required; this does not log in to Cursor.
#   - Set AUTONOM8_CURSOR_UNLOCK_KEYCHAIN=0 to disable.
#
# Configuration:
#   AUTONOM8_KEYCHAIN_PASSWORD                 explicit password value
#   AUTONOM8_KEYCHAIN_PASSWORD_ENV=mini        env var name to read from env/.env
#   AUTONOM8_KEYCHAIN_ENV_FILE=<login-home>/.env
#   AUTONOM8_KEYCHAIN_PATH=<login-home>/Library/Keychains/login.keychain-db
#   AUTONOM8_KEYCHAIN_UNLOCK_TIMEOUT_SECONDS   keychain auto-lock timeout
#   AUTONOM8_KEYCHAIN_SET_TIMEOUT=0            skip timeout refresh
#   AUTONOM8_CURSOR_NORMALIZE_HOME=0           keep process HOME unchanged

cursor_default_keychain_env_file() {
  local home=""
  home="$(cursor_login_home)"
  [[ -n "$home" ]] && printf "%s/.env" "$home"
}

cursor_default_login_keychain() {
  local home=""
  home="$(cursor_login_home)"
  [[ -n "$home" ]] && printf "%s/Library/Keychains/login.keychain-db" "$home"
}

read_cursor_keychain_password_from_env_file() {
  local default_env_file=""
  default_env_file="$(cursor_default_keychain_env_file)"
  local env_file="${AUTONOM8_KEYCHAIN_ENV_FILE:-$default_env_file}"
  local env_name="${AUTONOM8_KEYCHAIN_PASSWORD_ENV:-mini}"
  [[ -n "$env_name" ]] || return 0

  local value=""
  if [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    value="${!env_name:-}"
    if [[ -n "$value" ]]; then
      printf "%s" "$value"
      return 0
    fi
  fi

  [[ -n "$env_file" && -f "$env_file" ]] || return 0

  # Prefer shell-compatible .env loading so quoted or escaped passwords match
  # the operator's manual `set -a; . "$HOME/.env"` unlock command exactly.
  if [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    value="$(AUTONOM8_KEYCHAIN_ENV_FILE="$env_file" AUTONOM8_KEYCHAIN_PASSWORD_ENV="$env_name" bash -c '
      set -a
      # shellcheck disable=SC1090
      . "$AUTONOM8_KEYCHAIN_ENV_FILE" >/dev/null 2>&1 || exit 0
      key="$AUTONOM8_KEYCHAIN_PASSWORD_ENV"
      printf "%s" "${!key-}"
    ' 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf "%s" "$value"
      return 0
    fi
  fi

  # Fallback parser for simple KEY=value files when sourcing is not viable.
  value="$(awk -v key="$env_name" '
    {
      line=$0
      sub(/^[ \t]*export[ \t]+/, "", line)
      eq=index(line, "=")
      if (eq <= 0) next
      k=substr(line, 1, eq-1)
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k == key) {
        print substr(line, eq+1)
      }
    }
  ' "$env_file" 2>/dev/null | tail -n 1)"
  value="${value%$'\r'}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf "%s" "$value"
}

refresh_cursor_keychain_search_list() {
  local keychain="${1:-}"
  [[ -n "$keychain" && -f "$keychain" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0

  # SSH-launched workers can unlock the keychain file yet still leave Cursor's
  # child process with an incomplete user keychain search context. Make the
  # login keychain explicit for this user session without logging secrets.
  security default-keychain -d user -s "$keychain" >/dev/null 2>&1 || true

  local existing=()
  local item=""
  while IFS= read -r item; do
    item="${item#\"}"
    item="${item%\"}"
    [[ -z "$item" || "$item" == "$keychain" ]] && continue
    existing+=("$item")
  done < <(security list-keychains -d user 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ ${#existing[@]} -gt 0 ]]; then
    security list-keychains -d user -s "$keychain" "${existing[@]}" >/dev/null 2>&1 || true
  else
    security list-keychains -d user -s "$keychain" >/dev/null 2>&1 || true
  fi
}

ensure_cursor_keychain_ready() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || return 0
  [[ "${AUTONOM8_CURSOR_UNLOCK_KEYCHAIN:-${AUTONOM8_UNLOCK_KEYCHAIN:-1}}" != "0" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0

  if [[ "${AUTONOM8_CURSOR_NORMALIZE_HOME:-1}" != "0" ]]; then
    local login_home=""
    login_home="$(cursor_login_home)"
    if [[ -n "$login_home" && -d "$login_home" && "${HOME:-}" != "$login_home" && -f "$login_home/Library/Keychains/login.keychain-db" ]]; then
      export HOME="$login_home"
      log_verbose "Cursor HOME normalized to login home for macOS keychain access"
    fi
  fi

  local default_keychain=""
  default_keychain="$(cursor_default_login_keychain)"
  local keychain="${AUTONOM8_KEYCHAIN_PATH:-$default_keychain}"
  [[ -n "$keychain" && -f "$keychain" ]] || return 0

  local password="${AUTONOM8_KEYCHAIN_PASSWORD:-}"
  if [[ -z "$password" ]]; then
    password="$(read_cursor_keychain_password_from_env_file)"
  fi
  if [[ -z "$password" ]]; then
    log_verbose "Cursor keychain unlock skipped: no AUTONOM8_KEYCHAIN_PASSWORD or configured env-file value"
    return 0
  fi

  if security unlock-keychain -p "$password" "$keychain" >/dev/null 2>&1; then
    refresh_cursor_keychain_search_list "$keychain"
    if [[ "${AUTONOM8_KEYCHAIN_SET_TIMEOUT:-1}" != "0" ]]; then
      security set-keychain-settings -lut "${AUTONOM8_KEYCHAIN_UNLOCK_TIMEOUT_SECONDS:-21600}" "$keychain" >/dev/null 2>&1 || true
    fi
    log_verbose "Cursor keychain readiness refreshed"
  else
    log_warn "Cursor keychain unlock failed; provider call may return credential_unavailable"
  fi
}

is_cursor_keychain_locked_error() {
  local text="${1:-}"
  printf "%s" "$text" | grep -qiE 'login keychain is locked|macos login keychain is locked|security unlock-keychain'
}

should_retry_cursor_keychain_unlock() {
  local text="${1:-}"
  [[ "${AUTONOM8_CURSOR_KEYCHAIN_ERROR_RETRY:-1}" != "0" ]] || return 1
  [[ "${CURSOR_KEYCHAIN_ERROR_RETRIED:-false}" != "true" ]] || return 1
  is_cursor_keychain_locked_error "$text"
}

cursor_agent_cli() {
  if [[ -z "${CURSOR_AGENT_BIN:-}" ]]; then
    return 127
  fi
  ensure_cursor_keychain_ready
  "$CURSOR_AGENT_BIN" "$@"
}

# True when we should pass --approve-mcps (always except AUTONOM8_CURSOR_AUTO_APPROVE_MCPS=0).
# --allow-tools implies MCP may run; auto-approve also covers review-only runs that still
# load workspace MCP config (Cursor prompts before the model starts).
cursor_agent_want_approve_mcps() {
  [[ "${ALLOW_TOOLS:-false}" == "true" ]] || [[ "${AUTONOM8_CURSOR_AUTO_APPROVE_MCPS:-1}" != "0" ]]
}

# Run command with timeout (runs in background so we can track PID for cleanup)
run_with_timeout() {
  local timeout_secs="$1"
  shift
  ensure_cursor_keychain_ready

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
    CURSOR_PID=$pid

    # Wait for completion
    wait $pid
    local exit_code=$?
    CURSOR_PID=""
    return $exit_code
  else
    # Fallback: preserve piped stdin by buffering it before backgrounding the command.
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
    CURSOR_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      CURSOR_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      CURSOR_PID=""
      return $exit_code
    fi
  fi
}

compact_reasoning_text() {
  local text="${1:-}"
  printf "%s" "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//'
}

cursor_main_output_format() {
  local requested="${AUTONOM8_CURSOR_OUTPUT_FORMAT:-stream-json}"
  case "$requested" in
    json|stream-json|text)
      printf "%s" "$requested"
      ;;
    *)
      log_warn "Unsupported AUTONOM8_CURSOR_OUTPUT_FORMAT '$requested'; using stream-json"
      printf "%s" "stream-json"
      ;;
  esac
}

cursor_stream_partial_output_enabled() {
  [[ "${AUTONOM8_CURSOR_STREAM_PARTIAL_OUTPUT:-1}" != "0" ]]
}

extract_cursor_result_json() {
  local raw_output="${1:-}"
  local result_json=""

  result_json="$(printf "%s\n" "$raw_output" | jq -c 'select(type == "object" and .type == "result")' 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$result_json" ]]; then
    printf "%s" "$result_json"
    return 0
  fi

  if printf "%s" "$raw_output" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf "%s" "$raw_output"
    return 0
  fi

  return 1
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
    session_tokens="$(get_cursor_session_token_usage "$session_id" 2>/dev/null || true)"
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

  if [[ -z "$reasoning_text" && -n "$session_id" ]]; then
    local session_reasoning
    session_reasoning="$(get_cursor_session_reasoning "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_reasoning" ]]; then
      reasoning_text="$session_reasoning"
      reasoning_source="session_log"
    fi
  fi

  if [[ -z "$reasoning_text" && -n "$response_text" ]]; then
    local pre_json_reasoning=""
    pre_json_reasoning="$(printf "%s" "$response_text" | awk '
      BEGIN { in_json=0 }
      /^```json/ { in_json=1; next }
      in_json == 0 { print }
    ' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')"
    if [[ -n "$pre_json_reasoning" ]] && ! printf "%s" "$pre_json_reasoning" | jq -e . >/dev/null 2>&1; then
      reasoning_text="$pre_json_reasoning"
      reasoning_source="derived_excerpt"
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

  local tool_activity_json
  tool_activity_json="$(autonom8_tool_activity_json "$raw_output" "$stream_output" "wrapper:cursor")"

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
    quota|rate_limit|timeout|invalid_session|invalid_model|credential_unavailable)
      recoverable=true
      ;;
  esac

  if [[ -n "$session_id" ]]; then
    local session_tokens=""
    session_tokens="$(get_cursor_session_token_usage "$session_id" 2>/dev/null || true)"
    if [[ -n "$session_tokens" ]]; then
      tokens_json="$session_tokens"
      if [[ "$(printf "%s" "$tokens_json" | jq -r '((.input_tokens + .output_tokens + .total_tokens) > 0)' 2>/dev/null || echo false)" == "true" ]]; then
        token_usage_available=true
      fi
    fi

    local session_reasoning=""
    session_reasoning="$(get_cursor_session_reasoning "$session_id" 2>/dev/null || true)"
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

log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] WARN: $*" >&2
}

get_cursor_mcp_config() {
  if [[ -f "$CORE_DIR/.cursor/mcp.json" ]]; then
    echo "$CORE_DIR/.cursor/mcp.json"
  elif [[ -f "$CORE_DIR/.mcp.json" ]]; then
    echo "$CORE_DIR/.mcp.json"
  fi
}

normalize_cursor_mcp_path() {
  local config_path="$1"
  local raw_path="$2"

  if [[ -z "$raw_path" ]]; then
    return 1
  fi

  if [[ "$raw_path" == /* ]]; then
    printf "%s" "$raw_path"
    return 0
  fi

  if [[ "$raw_path" == -* || "$raw_path" =~ ^https?:// || "$raw_path" =~ ^wss?:// ]]; then
    printf "%s" "$raw_path"
    return 0
  fi

  if [[ "$raw_path" == *"mcp-servers/"* ]]; then
    local suffix="${raw_path#*mcp-servers/}"
    printf "%s" "$CORE_DIR/mcp-servers/$suffix"
    return 0
  fi

  local config_dir=""
  config_dir="$(cd "$(dirname "$config_path")" && pwd -P)"
  printf "%s" "$config_dir/$raw_path"
}

normalize_cursor_mcp_config() {
  local config_path="$1"
  local tmpfile=""
  local nextfile=""
  local server_name=""

  [[ -f "$config_path" ]] || return 1

  tmpfile="$(mktemp)"
  cp "$config_path" "$tmpfile"

  while IFS= read -r server_name; do
    [[ -z "$server_name" ]] && continue

    local arg_count=0
    arg_count="$(jq -r --arg name "$server_name" '(.mcpServers[$name].args // []) | length' "$tmpfile" 2>/dev/null || echo 0)"
    if [[ ! "$arg_count" =~ ^[0-9]+$ ]]; then
      continue
    fi

    local i=0
    while [[ $i -lt $arg_count ]]; do
      local current_arg=""
      current_arg="$(jq -r --arg name "$server_name" --argjson idx "$i" '.mcpServers[$name].args[$idx] // empty' "$tmpfile" 2>/dev/null || true)"
      if [[ -n "$current_arg" ]]; then
        local normalized_arg=""
        normalized_arg="$(normalize_cursor_mcp_path "$config_path" "$current_arg" 2>/dev/null || true)"
        if [[ -n "$normalized_arg" && "$normalized_arg" != "$current_arg" ]]; then
          nextfile="$(mktemp)"
          if jq --arg name "$server_name" --argjson idx "$i" --arg value "$normalized_arg" \
            '.mcpServers[$name].args[$idx] = $value' "$tmpfile" > "$nextfile" 2>/dev/null; then
            mv "$nextfile" "$tmpfile"
          else
            rm -f "$nextfile"
          fi
        fi
      fi
      i=$((i + 1))
    done
  done < <(jq -r '.mcpServers | keys[]?' "$tmpfile" 2>/dev/null || true)

  printf "%s" "$tmpfile"
}

validate_cursor_mcp_config() {
  local config_path="$1"
  local had_invalid=0
  local name=""
  local command=""
  local first_arg=""

  [[ -f "$config_path" ]] || return 0

  while IFS=$'\t' read -r name command first_arg; do
    [[ -z "$name" ]] && continue
    if [[ "$command" == "node" && -n "$first_arg" && "$first_arg" == /* && ! -f "$first_arg" ]]; then
      log_warn "Cursor MCP server '$name' unavailable: script not found at $first_arg"
      had_invalid=1
    fi
  done < <(jq -r '.mcpServers | to_entries[]? | [.key, (.value.command // ""), (.value.args[0] // "")] | @tsv' "$config_path" 2>/dev/null || true)

  if [[ "$had_invalid" -eq 1 ]]; then
    log_warn "Cursor will continue without one or more configured MCP servers. Browser verification tasks may fail or degrade."
  fi
}

ensure_cursor_mcp_config() {
  local workspace_dir="$1"
  local config_path="$2"

  if [[ -z "$workspace_dir" || -z "$config_path" ]]; then
    return 0
  fi

  local cursor_dir="${workspace_dir}/.cursor"
  local cursor_config="${cursor_dir}/mcp.json"
  local normalized_config=""

  mkdir -p "$cursor_dir"

  normalized_config="$(normalize_cursor_mcp_config "$config_path" 2>/dev/null || true)"
  if [[ -z "$normalized_config" ]]; then
    normalized_config="$config_path"
  fi

  if [[ -f "$cursor_config" ]]; then
    local tmpfile
    tmpfile="$(mktemp)"
    if jq -s '.[0] as $existing | .[1] as $incoming | ($existing + $incoming) | .mcpServers = (($existing.mcpServers // {}) + ($incoming.mcpServers // {}))' \
      "$cursor_config" "$normalized_config" > "$tmpfile" 2>/dev/null; then
      mv "$tmpfile" "$cursor_config"
    else
      rm -f "$tmpfile"
    fi
  else
    cp "$normalized_config" "$cursor_config"
  fi

  if [[ "$normalized_config" != "$config_path" ]]; then
    rm -f "$normalized_config"
  fi

  validate_cursor_mcp_config "$cursor_config" || true
}

# Determine core directory based on script location
# Script is in bin/cursor.sh, so CORE_DIR is parent of bin/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

is_agent_markdown_arg() {
  local candidate="${1:-}"
  [[ "$candidate" == *.md ]] || return 1
  [[ -f "$candidate" || -f "$CORE_DIR/$candidate" ]]
}

extract_tenant_root() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    return 1
  fi
  if [[ "$path" =~ ^(.*/tenants/[^/]+)(/.*)?$ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

resolve_tenant_root() {
  local candidate=""

  if [[ -n "${CONTEXT_DIR:-}" ]]; then
    candidate="$(extract_tenant_root "$CONTEXT_DIR" 2>/dev/null || true)"
  fi
  if [[ -z "$candidate" ]]; then
    candidate="$(extract_tenant_root "$PWD" 2>/dev/null || true)"
  fi
  if [[ -z "$candidate" && -d "$CORE_DIR/tenants" ]]; then
    candidate="$(find "$CORE_DIR/tenants" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
  fi

  printf "%s" "$candidate"
}

# =============================================================================
# Prompt Utilities (inlined, provider-specific)
# Cursor uses Claude/GPT models with ~128K token context
# =============================================================================
PROMPT_MAX_CHARS=150000        # ~37K tokens - conservative limit for Cursor
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
    local provider="${2:-cursor}"
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
    local provider="${2:-cursor}"
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
    local provider="${3:-cursor}"
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
  if [[ "$provider" == "cursor" ]]; then
    if declare -F resolve_model_from_cursor_catalog >/dev/null; then
      resolved="$(resolve_model_from_cursor_catalog "$MODEL_REQUESTED_RAW" 2>/dev/null || true)"
    fi
    if [[ -z "$resolved" ]]; then
      resolved="$(default_fallback_model_for_provider "$provider" "" 2>/dev/null || true)"
      if [[ -n "$resolved" ]] && declare -F build_model_resolution_summary >/dev/null; then
        MODEL_RESOLUTION_NOTE="$(build_model_resolution_summary "$provider" "$MODEL_REQUESTED_RAW" "$resolved" "fallback")"
      fi
    fi
  elif declare -F resolve_requested_model_for_provider >/dev/null; then
    resolved="$(resolve_requested_model_for_provider "$provider" "$MODEL_REQUESTED_RAW" 2>/dev/null || printf "%s" "$MODEL_REQUESTED_RAW")"
  fi

  if [[ -z "$MODEL_RESOLUTION_NOTE" && "$resolved" != "$MODEL_REQUESTED_RAW" ]] && declare -F build_model_resolution_summary >/dev/null; then
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
  local persona_id="$2"   # e.g., pm-cursor | dev-cursor (Implement) | dev-cursor (Design)
  # P1.5.1 FIX: Match full persona ID including role suffix
  # Supports both old format (pm-cursor) and new format (dev-cursor (Implement))
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
      # Full match: "dev-cursor (Implement)" == "dev-cursor (Implement)"
      # Prefix match: "pm-cursor" matches "pm-cursor (Quality Reviewer)" for legacy support
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

get_cursor_session_file_by_id() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 1
  find "$HOME/.cursor/projects" -path "*/agent-transcripts/${session_id}.jsonl" -type f 2>/dev/null | head -1
}

get_cursor_session_token_usage() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_cursor_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  jq -src '
    def as_int:
      if type == "number" then floor
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    def as_num:
      if type == "number" then .
      elif type == "string" then (tonumber? // 0)
      else 0 end;
    [
      .[] | (.usage // .message.usage // empty)
    ] as $u
    | select(($u | length) > 0)
    | ($u[-1]) as $x
    | {
        input_tokens: (($x.input_tokens // $x.input // $x.prompt_tokens // 0) | as_int),
        output_tokens: (($x.output_tokens // $x.output // $x.completion_tokens // 0) | as_int),
        total_tokens: (($x.total_tokens // $x.total // (($x.input_tokens // $x.input // 0) + ($x.output_tokens // $x.output // 0))) | as_int),
        cost_usd: (($x.cost_usd // $x.cost // 0) | as_num)
      }
  ' "$session_file" | tail -1
}

get_cursor_session_reasoning() {
  local session_id="$1"
  local session_file=""
  session_file="$(get_cursor_session_file_by_id "$session_id" 2>/dev/null || true)"
  [[ -z "$session_file" || ! -f "$session_file" ]] && return 1

  local reasoning=""
  reasoning="$(jq -src '
    [
      .[]
      | select(.role == "assistant")
      | (.message.content // [])[]
      | select(.type == "text")
      | (.text // "")
      | gsub("\\r";"")
      | gsub("^\\s+|\\s+$";"")
      | select(length > 0)
      | select((startswith("```json") | not) and (startswith("{") | not))
    ]
    | if length > 8 then .[-8:] else . end
    | join(" ")
  ' "$session_file" 2>/dev/null || true)"

  [[ -n "$reasoning" ]] && printf "%s" "$reasoning" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//' | cut -c1-600
}

create_cursor_session() {
  local raw_output=""
  local session_id=""

  raw_output="$(cursor_agent_cli create-chat 2>/dev/null || true)"
  raw_output="${raw_output//$'\r'/}"

  if [[ -n "$raw_output" ]]; then
    session_id="$(printf "%s" "$raw_output" | jq -r '.id // .chat_id // .session_id // .data.id // empty' 2>/dev/null || true)"
    if [[ -z "$session_id" ]]; then
      session_id="$(printf "%s" "$raw_output" | grep -oE '[0-9a-fA-F-]{8,}' | head -n1)"
    fi
    if [[ -z "$session_id" ]]; then
      session_id="$(printf "%s" "$raw_output" | tail -n1 | tr -d '[:space:]')"
    fi
  fi

  if [[ -n "$session_id" ]]; then
    printf "%s" "$session_id"
    return 0
  fi
  return 1
}

# Validate if a Cursor session exists
# Tries to check session existence via cursor-agent list-chats or file check
validate_cursor_session() {
  local session_id="$1"

  # Try to list sessions and check if our ID is present
  local sessions_output=""
  sessions_output="$(cursor_agent_cli list-chats 2>/dev/null || true)"

  if [[ -n "$sessions_output" ]]; then
    # Check if session ID appears in the output
    if echo "$sessions_output" | grep -qF "$session_id"; then
      return 0
    fi
  fi

  # Also check .cursor/sessions/ directory if it exists
  if [[ -d "$HOME/.cursor/sessions" && -f "$HOME/.cursor/sessions/$session_id" ]]; then
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
ALLOW_TOOLS=false  # Cursor uses --force for tool access; MCP approval is separate
SESSION_ID=""        # Existing session ID to resume
MANAGE_SESSION=""    # Request to create a new session (Cursor returns ID)
SKILL_NAME=""        # Skill to invoke (from .cursor/skills/)
QUOTA_STATUS=false   # Check and return quota status
HEALTH_CHECK=false   # P6.4: Health check mode
MODEL=""             # Model selection (cursor passes via --model flag)
PERMISSION_MODE=""   # Permission mode (cursor supports --mode=plan)
REASONING_FALLBACK=false # Emit fallback reasoning/tokens from session logs only

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona)
      PERSONA_OVERRIDE="$2"; shift 2
      ;;
    --temperature)
      # Cursor CLI doesn't accept temperature directly; consume for interface parity
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
      # Cursor equivalent: enable tool access. MCP startup approval is handled
      # independently below because even read-only/review calls can encounter
      # Cursor's "MCP Server Approval Required" prompt before the model starts.
      ALLOW_TOOLS=true
      YOLO_MODE=true  # Cursor uses --force for command approvals
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
      # --session-id: Alternative flag name
      # --resume: Native Cursor flag (from sessionmgr)
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
    --quota-status)
      QUOTA_STATUS=true; shift
      ;;
    --model)
      MODEL="$2"; shift 2
      ;;
    --mode|--permission-mode)
      PERMISSION_MODE="$2"; shift 2
      # Cursor supports --mode=plan for exploration mode
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
  prepare_requested_model_value "cursor" "$MODEL"
  MODEL="$MODEL_PREPARED_VALUE"
  if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
    log_info "Model resolution: $MODEL_RESOLUTION_NOTE"
  fi
fi
case "$(printf "%s" "$PERMISSION_MODE" | tr '[:upper:]' '[:lower:]')" in
  default)
    log_info "Cursor mode 'default' requested; omitting --mode because cursor-agent only accepts plan/ask"
    PERMISSION_MODE=""
    ;;
esac

# ===================
# Quota Status Mode
# ===================
# If --quota-status flag is provided, return quota status JSON
if [[ "$QUOTA_STATUS" == "true" ]]; then
  # Check for cached usage limit messages
  SYSTEM_MSG_DIR="$CORE_DIR/context/system-messages/inbox"
  LATEST_LIMIT_FILE=""

  if [[ -d "$SYSTEM_MSG_DIR" ]]; then
    # Find most recent cursor usage limit file
    LATEST_LIMIT_FILE=$(find "$SYSTEM_MSG_DIR" -name "*-cursor-usage-limit.json" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1 || true)
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
        jq -n --arg provider "cursor" \
          '{provider: $provider, quota_exhausted: false, source: "estimated", message: "Quota likely reset (>1h since last limit)"}'
      else
        # Still exhausted
        REMAINING=$((RESET_SECONDS - ELAPSED))
        RESET_AT=$(date -j -v+${REMAINING}S "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        jq -n --arg provider "cursor" \
              --argjson exhausted true \
              --arg reset_at "$RESET_AT" \
              --argjson reset_in_seconds "$REMAINING" \
              --arg retry_time "$RETRY_TIME" \
              --arg source "cached" \
          '{provider: $provider, quota_exhausted: $exhausted, reset_at: $reset_at, reset_in_seconds: $reset_in_seconds, retry_time: $retry_time, source: $source}'
      fi
    else
      jq -n --arg provider "cursor" \
        '{provider: $provider, quota_exhausted: false, source: "unknown", message: "No valid timestamp in limit file"}'
    fi
  else
    # No cached limit file - quota is likely available
    jq -n --arg provider "cursor" \
      '{provider: $provider, quota_exhausted: false, source: "no_cache", message: "No recent quota limit detected"}'
  fi
  exit 0
fi

# ===================
# P6.4: Health Check Mode
# ===================
# If --health-check flag is provided, check provider health and return status
if [[ "$HEALTH_CHECK" == "true" ]]; then
  log_verbose "Health check mode: testing cursor CLI availability, auth, and headless response"

  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Check if Cursor CLI is available (cursor-agent or verified `agent` from Cursor install)
  if [[ -z "$CURSOR_AGENT_BIN" ]]; then
    jq -n --arg provider "cursor" '{
      provider: $provider,
      status: "unavailable",
      cli_available: false,
      error: "Cursor CLI not found: install from https://cursor.com/docs/cli/overview (PATH: cursor-agent or agent), or set AUTONOM8_CURSOR_AGENT to the binary path",
      session_support: true
    }'
    exit 1
  fi

  # Try minimal invocations to verify CLI, macOS keychain-backed auth, and a
  # headless model response. On macOS every fresh non-interactive SSH session may
  # need login.keychain-db unlocked before cursor-agent can read credentials.
  VERSION_OUTPUT=$(cursor_agent_cli --version 2>&1 || true)
  VERSION_EXIT=$?
  AUTH_OUTPUT=$(cursor_agent_cli status 2>&1 || true)
  AUTH_EXIT=$?

  PROBE_OUTPUT_FILE="$(mktemp)"
  PROBE_ERR_FILE="$(mktemp)"
  PROBE_TIMEOUT="${AUTONOM8_CURSOR_HEALTH_PROBE_TIMEOUT_SECONDS:-30}"
  PROBE_MODEL="${AUTONOM8_CURSOR_HEALTH_PROBE_MODEL:-composer-2-fast}"
  PROBE_PROMPT='Return exactly this JSON and no markdown: {"ok":true,"probe":"cursor_health"}'
  PROBE_START=$(date +%s%N 2>/dev/null || date +%s)
  set +e
  PROBE_MCP_ARGS=()
  if cursor_agent_want_approve_mcps; then
    PROBE_MCP_ARGS+=(--approve-mcps)
  fi
  run_with_timeout "$PROBE_TIMEOUT" "$CURSOR_AGENT_BIN" \
    --print \
    --output-format json \
    --model "$PROBE_MODEL" \
    --trust \
    "${PROBE_MCP_ARGS[@]}" \
    --workspace "${TMPDIR:-/tmp}" \
    "$PROBE_PROMPT" > "$PROBE_OUTPUT_FILE" 2> "$PROBE_ERR_FILE"
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

  AUTH_OK=false
  if [[ $AUTH_EXIT -eq 0 ]] && printf "%s" "$AUTH_OUTPUT" | grep -qi "logged in"; then
    AUTH_OK=true
  fi
  PROBE_OK=false
  PROBE_RESPONSE="$(printf "%s" "$PROBE_OUTPUT" | jq -r '.result // empty' 2>/dev/null || true)"
  if [[ $PROBE_EXIT -eq 0 ]] && [[ -n "$PROBE_RESPONSE" ]] && printf "%s" "$PROBE_RESPONSE" | jq -e '.ok == true and .probe == "cursor_health"' >/dev/null 2>&1; then
    PROBE_OK=true
  fi

  if [[ $VERSION_EXIT -eq 0 && "$AUTH_OK" == "true" && "$PROBE_OK" == "true" ]]; then
    # Extract version if available
    VERSION=$(echo "$VERSION_OUTPUT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

    jq -n --arg provider "cursor" \
          --arg status "ok" \
          --argjson latency "$LATENCY_MS" \
          --argjson probe_latency "$PROBE_LATENCY_MS" \
          --arg version "$VERSION" \
          --arg probe_model "$PROBE_MODEL" \
          '{
            provider: $provider,
            status: $status,
            latency_ms: $latency,
            response_probe_latency_ms: $probe_latency,
            cli_available: true,
            auth_ok: true,
            response_probe_ok: true,
            version: $version,
            probe_model: $probe_model,
            mac_keychain_unlock: true,
            session_support: true
          }'
  else
    jq -n --arg provider "cursor" \
          --arg version_output "$VERSION_OUTPUT" \
          --arg auth_output "$AUTH_OUTPUT" \
          --arg probe_error "$PROBE_ERR" \
          --arg probe_output "$PROBE_OUTPUT" \
          --argjson latency "$LATENCY_MS" \
          --argjson probe_latency "$PROBE_LATENCY_MS" \
          --argjson auth_ok "$AUTH_OK" \
          --argjson probe_ok "$PROBE_OK" \
          --arg probe_model "$PROBE_MODEL" \
          '{
            provider: $provider,
            status: "error",
            latency_ms: $latency,
            response_probe_latency_ms: $probe_latency,
            cli_available: true,
            auth_ok: $auth_ok,
            response_probe_ok: $probe_ok,
            version_output: $version_output,
            auth_output: $auth_output,
            probe_error: $probe_error,
            probe_output: $probe_output,
            probe_model: $probe_model,
            mac_keychain_unlock: true,
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
# Cursor supports shared canonical skills plus provider-local synced copies.
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
    "$HOME/.cursor/skills/${SKILL_NAME}/SKILL.md"
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
      '{dry_run: true, wrapper: "cursor.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed"}'
    exit 0
  fi

  # Invoke cursor-agent with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Determine working directory
  WORK_DIR="$CORE_DIR"
  WORK_DIR_SOURCE="core_fallback"
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
    WORK_DIR_SOURCE="context_dir"
  else
    TENANT_DIR="$(resolve_tenant_root)"
    if [[ -n "$TENANT_DIR" ]]; then
      WORK_DIR="$TENANT_DIR"
      WORK_DIR_SOURCE="tenant_resolved"
    fi
  fi

  # Build cursor-agent args (--approve-mcps: see cursor_agent_want_approve_mcps).
  CURSOR_ARGS=(
    "--print"
    "--output-format" "text"
    "--trust"
  )
  if [[ -n "$WORK_DIR" ]]; then
    CURSOR_ARGS+=("--workspace" "$WORK_DIR")
  fi
  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi
  if cursor_agent_want_approve_mcps; then
    CURSOR_ARGS+=("--approve-mcps")
  fi

  # Add model flag if specified
  if [[ -n "$MODEL" ]]; then
    CURSOR_ARGS+=("--model" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi

  log_verbose "Invoking cursor-agent CLI for skill (WorkDir: ${WORK_DIR:-none}, Source: ${WORK_DIR_SOURCE:-none}, Model: ${MODEL:-default})"

  if cursor_agent_want_approve_mcps; then
    MCP_CONFIG_PATH="$(get_cursor_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_cursor_mcp_config "$WORK_DIR" "$MCP_CONFIG_PATH"
    fi
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    run_with_timeout "$CLI_TIMEOUT" "$CURSOR_AGENT_BIN" "${CURSOR_ARGS[@]}" "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    cursor_agent_cli "${CURSOR_ARGS[@]}" "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  CURSOR_EXIT=$?
  set -e

  if [[ $CURSOR_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    ERROR_STDOUT=$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0' || true)
    ERROR_COMBINED="$ERROR_MSG"
    if [[ -n "$ERROR_STDOUT" ]]; then
      ERROR_COMBINED="${ERROR_COMBINED}"$'\n'"${ERROR_STDOUT}"
    fi
    if should_retry_cursor_keychain_unlock "$ERROR_COMBINED"; then
      CURSOR_KEYCHAIN_ERROR_RETRIED=true
      log_info "Cursor reported locked macOS keychain after pre-call refresh; unlocking and retrying once"
      ensure_cursor_keychain_ready
      : > "$TMPFILE_OUTPUT"
      : > "$TMPFILE_ERR"
      continue
    fi
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    ERROR_TYPE="provider_error"
    if [[ "$CURSOR_EXIT" -eq 124 ]]; then
      ERROR_TYPE="timeout"
    elif is_cursor_keychain_locked_error "$ERROR_COMBINED"; then
      ERROR_TYPE="credential_unavailable"
    elif echo "$ERROR_MSG" | grep -qi "Cannot use this model\|Unknown model\|Invalid model"; then
      ERROR_TYPE="invalid_model"
    elif declare -F classify_error >/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
    fi
    if [[ "$CURSOR_INVALID_MODEL_RETRIED" != "true" ]] && [[ "$ERROR_TYPE" == "invalid_model" ]]; then
      REQUESTED_MODEL_LABEL="${MODEL_REQUESTED_RAW:-$MODEL}"
      CURSOR_INVALID_MODEL_RETRIED=true
      MODEL=""
      MODEL_RESOLUTION_NOTE="cursor model '$REQUESTED_MODEL_LABEL' -> 'provider-default' (fallback)"
      log_info "Invalid model '$REQUESTED_MODEL_LABEL' for cursor; retrying with provider default"
      continue
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "" "$CURSOR_EXIT"
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0')"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

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

if is_agent_markdown_arg "${1-}"; then
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

  log_verbose "Persona selected: $PERSONA_ID"

  # Extract only the chosen persona block
  AGENT_PROMPT="$(extract_persona_block "$AGENT_FILE_ABS" "$PERSONA_ID")"

  if [[ -z "$AGENT_PROMPT" ]]; then
    emit_cli_error_response "persona '$PERSONA_ID' not found in agent file" "invalid_input" "" 2
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
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions to prevent Cursor from responding to persona
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
    check_prompt_size "$FULL_PROMPT" "cursor"
    PROMPT_OVER_LIMIT=$?

    # Save debug prompt if enabled
    if type save_debug_prompt &>/dev/null; then
      save_debug_prompt "$FULL_PROMPT" "$PERSONA_ID" "cursor"
    fi

    # Log stats in verbose mode
    if [[ "$VERBOSE" == "true" ]] && type get_prompt_stats &>/dev/null; then
      PROMPT_STATS=$(get_prompt_stats "$FULL_PROMPT" "cursor")
      log_verbose "Prompt stats: $PROMPT_STATS"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_verbose "DRY-RUN MODE: Skipping actual CLI call"

    MOCK_RESPONSE="{
  \"dry_run\": true,
  \"wrapper\": \"cursor.sh\",
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

  TENANT_DIR="$(resolve_tenant_root)"

  # Cursor CLI doesn't accept temperature directly; log for visibility
  if [[ -n "$TEMPERATURE" ]]; then
    log_verbose "Temperature specified but ignored by cursor-agent: $TEMPERATURE"
  fi

  WORKSPACE_DIR="$CORE_DIR"
  WORKSPACE_SOURCE="core_fallback"
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORKSPACE_DIR="$CONTEXT_DIR"
    WORKSPACE_SOURCE="context_dir"
  elif [[ -n "$TENANT_DIR" ]]; then
    WORKSPACE_DIR="$TENANT_DIR"
    WORKSPACE_SOURCE="tenant_fallback"
  fi
  log_verbose "Invoking cursor-agent CLI (Workspace: ${WORKSPACE_DIR}, Source: ${WORKSPACE_SOURCE}, YOLO: $YOLO_MODE)"
  if cursor_agent_want_approve_mcps; then
    MCP_CONFIG_PATH="$(get_cursor_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_cursor_mcp_config "$WORKSPACE_DIR" "$MCP_CONFIG_PATH"
    fi
  fi

  # Build cursor-agent args.
  # Default to stream-json so the worker receives progress bytes during long
  # Cursor implement calls; parse the final type=result event below to preserve
  # the existing wrapper contract.
  CURSOR_OUTPUT_FORMAT="$(cursor_main_output_format)"
  CURSOR_ARGS=(
    "--print"
    "--output-format" "$CURSOR_OUTPUT_FORMAT"
    "--workspace" "$WORKSPACE_DIR"
    "--trust"
  )
  if [[ "$CURSOR_OUTPUT_FORMAT" == "stream-json" ]] && cursor_stream_partial_output_enabled; then
    CURSOR_ARGS+=("--stream-partial-output")
  fi

  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi

  if [[ "$ALLOW_TOOLS" == "true" || "${AUTONOM8_CURSOR_AUTO_APPROVE_MCPS:-1}" != "0" ]]; then
    CURSOR_ARGS+=("--approve-mcps")
  fi

  # Add session args for session resume
  CURSOR_SESSION_ID=""
  if [[ -n "$SESSION_ID" ]]; then
    # Pass session ID directly - cursor-agent will error if invalid
    CURSOR_SESSION_ID="$SESSION_ID"
    CURSOR_ARGS+=("--resume" "$SESSION_ID")
    log_verbose "Resuming session: $SESSION_ID"
  elif [[ -n "$MANAGE_SESSION" ]]; then
    CURSOR_SESSION_ID="$MANAGE_SESSION"
    log_verbose "Tracking caller-managed session: $MANAGE_SESSION"
  fi

  # Add model flag if specified
  if [[ -n "$MODEL" ]]; then
    CURSOR_ARGS+=("--model" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi

  # Add mode arg if specified (cursor supports --mode=plan for exploration)
  if [[ -n "$PERMISSION_MODE" ]]; then
    CURSOR_ARGS+=("--mode" "$PERMISSION_MODE")
    log_verbose "Using permission mode: $PERMISSION_MODE"
  fi

  # Run cursor-agent in non-interactive mode (prompt passed as argument)
  CURSOR_PROMPT="$(cat "$TMPFILE_PROMPT")"

  # O-6: Set up agent stream logging for per-ticket LLM output capture
  AGENT_LOG=""
  if [[ -n "${A8_TICKET_ID:-}" && -n "${WORKSPACE_DIR:-}" ]]; then
    AGENT_LOG_DIR="${WORKSPACE_DIR}/.autonom8/agent_logs"
    mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true
    AGENT_LOG="${AGENT_LOG_DIR}/${A8_TICKET_ID}_${A8_WORKFLOW}_$(date +%s).log"
    echo "=== Agent Stream Log ===" > "$AGENT_LOG"
    echo "Ticket: $A8_TICKET_ID | Workflow: $A8_WORKFLOW | Provider: cursor" >> "$AGENT_LOG"
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AGENT_LOG"
    echo "===" >> "$AGENT_LOG"
    log_verbose "O-6: Agent stream logging to $AGENT_LOG"
  fi

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running cursor-agent with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$AGENT_LOG" ]]; then
      run_with_timeout "$CLI_TIMEOUT" "$CURSOR_AGENT_BIN" "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      run_with_timeout "$CLI_TIMEOUT" "$CURSOR_AGENT_BIN" "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
    CURSOR_EXIT=$?
  else
    if [[ -n "$AGENT_LOG" ]]; then
      cursor_agent_cli "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> >(tee -a "$AGENT_LOG" > "$TMPFILE_ERR") > "$TMPFILE_OUTPUT"
    else
      cursor_agent_cli "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
    CURSOR_EXIT=$?
  fi
  set -e

  # O-9: Append stdout response to agent log (stderr tee only captures progress/errors,
  # cursor sends the actual response to stdout which may be missing from logs)
  if [[ -n "$AGENT_LOG" && -f "$TMPFILE_OUTPUT" && -s "$TMPFILE_OUTPUT" ]]; then
    echo "" >> "$AGENT_LOG"
    cat "$TMPFILE_OUTPUT" >> "$AGENT_LOG" 2>/dev/null || true
    echo "" >> "$AGENT_LOG"
    echo "tokens used" >> "$AGENT_LOG"
    wc -c < "$TMPFILE_OUTPUT" | xargs -I{} echo "{}" >> "$AGENT_LOG"
  fi

  rm -f "$TMPFILE_PROMPT"

  if [[ $CURSOR_EXIT -ne 0 ]]; then
    # Cursor failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || echo "Unknown error")
    ERROR_STDOUT=$(cat "$TMPFILE_OUTPUT" 2>/dev/null | tr -d '\0' || true)
    ERROR_COMBINED="$ERROR_MSG"
    if [[ -n "$ERROR_STDOUT" ]]; then
      ERROR_COMBINED="${ERROR_COMBINED}"$'\n'"${ERROR_STDOUT}"
    fi
    log_verbose "Cursor execution failed: $ERROR_MSG"

    if should_retry_cursor_keychain_unlock "$ERROR_COMBINED"; then
      CURSOR_KEYCHAIN_ERROR_RETRIED=true
      log_info "Cursor reported locked macOS keychain after pre-call refresh; unlocking and retrying once"
      ensure_cursor_keychain_ready
      : > "$TMPFILE_OUTPUT"
      : > "$TMPFILE_ERR"
      continue
    fi

    if [[ "$CURSOR_INVALID_MODEL_RETRIED" != "true" ]] && declare -F is_invalid_model_error >/dev/null && is_invalid_model_error "$ERROR_MSG"; then
      REQUESTED_MODEL_LABEL="${MODEL_REQUESTED_RAW:-$MODEL}"
      CURSOR_INVALID_MODEL_RETRIED=true
      MODEL=""
      MODEL_RESOLUTION_NOTE="cursor model '$REQUESTED_MODEL_LABEL' -> 'provider-default' (fallback)"
      log_info "Invalid model '$REQUESTED_MODEL_LABEL' for cursor; retrying with provider default"
      : > "$TMPFILE_OUTPUT"
      : > "$TMPFILE_ERR"
      continue
    fi

    # Check if this is an invalid session error - fail fast, don't retry
    if echo "$ERROR_MSG" | grep -qi "Invalid session identifier\|session.*not found\|session.*expired"; then
      log_verbose "Invalid session detected - clearing stale session"
      rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
      emit_cli_error_response "$ERROR_MSG" "invalid_session" "$SESSION_ID" "$CURSOR_EXIT"
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
      MSG_FILE="$SYSTEM_MSG_DIR/$(date +%s)-cursor-usage-limit.json"

      jq -n \
        --arg ts "$TIMESTAMP" \
        --arg cli "cursor" \
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
    if [[ "$CURSOR_EXIT" -eq 124 ]]; then
      ERROR_TYPE="timeout"
    elif is_cursor_keychain_locked_error "$ERROR_COMBINED"; then
      ERROR_TYPE="credential_unavailable"
    elif declare -F classify_error >/dev/null; then
      ERROR_TYPE="$(classify_error "$ERROR_MSG")"
    fi
    emit_cli_error_response "$ERROR_MSG" "$ERROR_TYPE" "$CURSOR_SESSION_ID" "$CURSOR_EXIT"
    exit 1
  fi

  # Read the output (JSON format from cursor-agent)
  RAW_OUTPUT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  STDERR_TEXT="$(cat "$TMPFILE_ERR" 2>/dev/null | tr -d '\0' || true)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RAW_OUTPUT" ]]; then
    RESULT_OUTPUT="$RAW_OUTPUT"
    if [[ "${CURSOR_OUTPUT_FORMAT:-json}" == "stream-json" ]]; then
      RESULT_OUTPUT="$(extract_cursor_result_json "$RAW_OUTPUT" || true)"
    fi

    if [[ -z "$RESULT_OUTPUT" ]]; then
      emit_cli_error_response "No result event in response from cursor-agent" "provider_error" "$CURSOR_SESSION_ID" 1
      exit 1
    fi

    # JSON/stream-json format: Extract session_id and result from cursor-agent
    # response. Stream-json emits many events; RESULT_OUTPUT is only the final
    # type=result event.
    CURSOR_SESSION_ID="$(echo "$RESULT_OUTPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    RESPONSE_TEXT="$(echo "$RESULT_OUTPUT" | jq -r '.result // empty' 2>/dev/null || true)"

    # Check for error response
    IS_ERROR="$(echo "$RESULT_OUTPUT" | jq -r '.is_error // false' 2>/dev/null || true)"
    if [[ "$IS_ERROR" == "true" ]]; then
      ERROR_MSG="$(echo "$RESULT_OUTPUT" | jq -r '.result // "Unknown error"' 2>/dev/null || true)"
      emit_cli_error_response "$ERROR_MSG" "provider_error" "$CURSOR_SESSION_ID" 1
      exit 1
    fi

    log_verbose "Session from response: ${CURSOR_SESSION_ID:-none}"

    if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
      # Strip markdown code fences if present in result
      if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
        RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
      elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
        RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
      fi

      if [[ -n "$MODEL_RESOLUTION_NOTE" ]]; then
        emit_cli_response "$RESPONSE_TEXT" "$CURSOR_SESSION_ID" "$RESULT_OUTPUT" "model_resolution" "$MODEL_RESOLUTION_NOTE" "$(printf "%s\n%s" "$RAW_OUTPUT" "$STDERR_TEXT")"
      else
        emit_cli_response "$RESPONSE_TEXT" "$CURSOR_SESSION_ID" "$RESULT_OUTPUT" "" "" "$(printf "%s\n%s" "$RAW_OUTPUT" "$STDERR_TEXT")"
      fi
    else
      # No result field - try raw response as fallback
      emit_cli_error_response "No result in response from cursor-agent" "provider_error" "$CURSOR_SESSION_ID" 1
    fi
  else
    emit_cli_error_response "No response from Cursor CLI" "provider_error" "$CURSOR_SESSION_ID" 1
  fi
else
  # Direct invocation with text prompt

  TENANT_DIR="$(resolve_tenant_root)"

  WORKSPACE_DIR="$CORE_DIR"
  WORKSPACE_SOURCE="core_fallback"
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORKSPACE_DIR="$CONTEXT_DIR"
    WORKSPACE_SOURCE="context_dir"
  elif [[ -n "$TENANT_DIR" ]]; then
    WORKSPACE_DIR="$TENANT_DIR"
    WORKSPACE_SOURCE="tenant_fallback"
  fi

  # Build cursor-agent args
  CURSOR_ARGS=(
    "--print"
    "--output-format" "text"
    "--workspace" "$WORKSPACE_DIR"
    "--trust"
  )

  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi

  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    CURSOR_ARGS+=("--approve-mcps")
  fi

  # Add model flag if specified
  if [[ -n "$MODEL" ]]; then
    CURSOR_ARGS+=("--model" "$MODEL")
    log_verbose "Using model: $MODEL"
  fi

  # Add mode arg if specified (cursor supports --mode=plan for exploration)
  if [[ -n "$PERMISSION_MODE" ]]; then
    CURSOR_ARGS+=("--mode" "$PERMISSION_MODE")
    log_verbose "Using permission mode: $PERMISSION_MODE"
  fi

  log_verbose "Running in direct invocation mode (Workspace: ${WORKSPACE_DIR}, Source: ${WORKSPACE_SOURCE}, Model: ${MODEL:-default}, Mode: ${PERMISSION_MODE:-default})"
  cursor_agent_cli "${CURSOR_ARGS[@]}" "$@"
fi
