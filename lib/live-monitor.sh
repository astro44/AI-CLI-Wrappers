#!/usr/bin/env bash
# Live event monitor for Autonom8 CLI wrappers.
# Observes provider activity in real-time and writes structured heartbeats
# to .autonom8/provider_activity/<request_id>.jsonl
#
# Event classes (shared vocabulary across all providers):
#   reasoning             Model reasoning/thinking observed
#   function_call         Tool/function call initiated
#   function_call_output  Tool/function call result received
#   file_write            File write detected
#   file_read             File read detected
#   stderr_activity       Stderr output growth detected
#   stdout_activity       Stdout output growth detected
#   token_count           Token usage event
#   agent_message         Provider agent status message
#   task_started          Provider task started
#   task_complete         Task completion signal
#   monitor_start         Monitor started
#   monitor_stop          Monitor stopped
#   monitor_orphaned      Parent process gone

AUTONOM8_LIVE_MONITOR_PID=""
AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE=""
AUTONOM8_LIVE_MONITOR_START_EPOCH=""

autonom8_live_monitor_activity_dir() {
  local work_dir="${1:-${WORK_DIR:-$(pwd)}}"
  printf "%s/.autonom8/provider_activity" "$work_dir"
}

autonom8_monitor_write_event() {
  local provider="$1"
  local request_id="$2"
  local event_class="$3"
  local detail="${4:-}"
  local activity_file="${5:-${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}}"

  [[ -n "$activity_file" ]] || return 0

  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"

  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg ts "$now" \
      --arg provider "$provider" \
      --arg request_id "$request_id" \
      --arg event_class "$event_class" \
      --arg detail "$detail" \
      '{ts:$ts,provider:$provider,request_id:$request_id,event_class:$event_class,detail:$detail}' \
      >> "$activity_file" 2>/dev/null || true
  else
    printf '{"ts":"%s","provider":"%s","request_id":"%s","event_class":"%s","detail":"%s"}\n' \
      "$now" "$provider" "$request_id" "$event_class" "$detail" \
      >> "$activity_file" 2>/dev/null || true
  fi
}

# ── Start/Stop ──────────────────────────────────────────────────────────────

autonom8_start_live_monitor() {
  local provider="$1"
  local request_id="${2:-${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}}"
  local stderr_file="${3:-}"
  local work_dir="${4:-${WORK_DIR:-$(pwd)}}"
  local session_hint="${5:-}"

  [[ "${AUTONOM8_LIVE_MONITOR_ENABLED:-1}" != "0" ]] || return 0
  [[ -n "$request_id" && "$request_id" != "no-request" ]] || return 0

  local activity_dir
  activity_dir="$(autonom8_live_monitor_activity_dir "$work_dir")"
  mkdir -p "$activity_dir" 2>/dev/null || return 0

  AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE="$activity_dir/${request_id}.jsonl"
  AUTONOM8_LIVE_MONITOR_START_EPOCH="$(date +%s 2>/dev/null || echo 0)"

  autonom8_monitor_write_event "$provider" "$request_id" "monitor_start" \
    "stderr=${stderr_file:-none};session_hint=${session_hint:-none}"

  (
    _autonom8_live_monitor_loop \
      "$provider" "$request_id" "$stderr_file" \
      "$AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE" "$session_hint" \
      "$AUTONOM8_LIVE_MONITOR_START_EPOCH"
  ) >/dev/null 2>&1 &
  AUTONOM8_LIVE_MONITOR_PID=$!
}

autonom8_monitor_init() {
  autonom8_start_live_monitor "$@"
}

autonom8_stop_live_monitor() {
  local provider="${1:-unknown}"
  local request_id="${2:-${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}}"

  if [[ -n "${AUTONOM8_LIVE_MONITOR_PID:-}" ]]; then
    kill "${AUTONOM8_LIVE_MONITOR_PID}" 2>/dev/null || true
    wait "${AUTONOM8_LIVE_MONITOR_PID}" 2>/dev/null || true
    AUTONOM8_LIVE_MONITOR_PID=""
  fi

  local activity_file="${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}"
  if [[ -n "$activity_file" && -f "$activity_file" ]]; then
    autonom8_monitor_write_event "$provider" "$request_id" "monitor_stop" "" "$activity_file"
  fi
  AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE=""
}

# ── Background polling loop ─────────────────────────────────────────────────

_autonom8_live_monitor_loop() {
  local provider="$1"
  local request_id="$2"
  local stderr_file="$3"
  local activity_file="$4"
  local session_hint="$5"
  local start_epoch="${6:-0}"

  local last_stderr_bytes=0
  local last_session_bytes=0
  local session_file=""
  local sample_interval="${AUTONOM8_LIVE_MONITOR_INTERVAL_SEC:-2}"
  local discover_attempts=0
  local max_discover_attempts=15

  while true; do
    sleep "$sample_interval"

    # ── stderr polling ──
    if [[ -n "$stderr_file" && -f "$stderr_file" ]]; then
      local current_bytes
      current_bytes="$(wc -c < "$stderr_file" 2>/dev/null || echo 0)"
      current_bytes="${current_bytes// /}"
      if (( current_bytes > last_stderr_bytes )); then
        local new_content
        new_content="$(tail -c +"$((last_stderr_bytes + 1))" "$stderr_file" 2>/dev/null || true)"
        last_stderr_bytes=$current_bytes

        "_autonom8_classify_${provider}_stderr" \
          "$new_content" "$request_id" "$activity_file" 2>/dev/null || \
          _autonom8_classify_generic_stderr \
            "$new_content" "$provider" "$request_id" "$activity_file"
      fi
    fi

    # ── session file polling (providers that write live JSONL) ──
    if [[ -n "$session_hint" ]]; then
      if [[ -z "$session_file" || ! -f "$session_file" ]]; then
        if (( discover_attempts < max_discover_attempts )); then
          session_file="$("_autonom8_discover_${provider}_session" "$session_hint" "$start_epoch" 2>/dev/null || true)"
          (( discover_attempts++ )) || true
        fi
      fi

      if [[ -n "$session_file" && -f "$session_file" ]]; then
        local session_bytes
        session_bytes="$(wc -c < "$session_file" 2>/dev/null || echo 0)"
        session_bytes="${session_bytes// /}"
        if (( session_bytes > last_session_bytes )); then
          local new_events
          new_events="$(tail -c +"$((last_session_bytes + 1))" "$session_file" 2>/dev/null || true)"
          last_session_bytes=$session_bytes

          "_autonom8_classify_${provider}_session" \
            "$new_events" "$request_id" "$activity_file" 2>/dev/null || true
        fi
      fi
    fi

    # ── orphan check ──
    if ! kill -0 "$PPID" 2>/dev/null; then
      autonom8_monitor_write_event "$provider" "$request_id" "monitor_orphaned" "" "$activity_file"
      break
    fi
  done
}

# ── Codex JSONL stream monitor (foreground, for --json mode) ─────────────────
# Reads Codex --json JSONL from stdin, classifies events, writes heartbeats.
# Does NOT pass through — caller uses -o for final response capture.
#
# Real Codex --json event structure:
#   {"type":"response_item","payload":{"type":"reasoning",...},"timestamp":"..."}
#   {"type":"response_item","payload":{"type":"function_call","name":"exec_command",...},"timestamp":"..."}
#   {"type":"response_item","payload":{"type":"function_call_output",...},"timestamp":"..."}
#   {"type":"response_item","payload":{"type":"message",...},"timestamp":"..."}
#   {"type":"event_msg","payload":{"type":"token_count",...},"timestamp":"..."}
#   {"type":"event_msg","payload":{"type":"agent_message",...},"timestamp":"..."}
#   {"type":"event_msg","payload":{"type":"task_started",...},"timestamp":"..."}
#   {"type":"event_msg","payload":{"type":"task_complete",...},"timestamp":"..."}
autonom8_monitor_codex_jsonl_stream() {
  local request_id="${1:-${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}}"
  local activity_file="${2:-${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}}"

  [[ -n "$activity_file" ]] || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    local payload_type=""
    if command -v jq >/dev/null 2>&1; then
      payload_type="$(_autonom8_codex_event_type "$line")"
    fi

    case "$payload_type" in
      thread.started|turn.started)
        autonom8_monitor_write_event "codex" "$request_id" "task_started" "$payload_type" "$activity_file"
        ;;
      turn.completed)
        autonom8_monitor_write_event "codex" "$request_id" "token_count" "" "$activity_file"
        autonom8_monitor_write_event "codex" "$request_id" "task_complete" "" "$activity_file"
        ;;
      reasoning)
        autonom8_monitor_write_event "codex" "$request_id" "reasoning" "" "$activity_file"
        ;;
      function_call)
        local fn_name=""
        fn_name="$(printf "%s" "$line" | jq -r '.payload.name // .item.name // empty' 2>/dev/null || true)"
        autonom8_monitor_write_event "codex" "$request_id" "function_call" "$fn_name" "$activity_file"
        ;;
      function_call_output)
        autonom8_monitor_write_event "codex" "$request_id" "function_call_output" "" "$activity_file"
        ;;
      message)
        autonom8_monitor_write_event "codex" "$request_id" "stdout_activity" "message" "$activity_file"
        ;;
      token_count)
        autonom8_monitor_write_event "codex" "$request_id" "token_count" "" "$activity_file"
        ;;
      agent_message)
        autonom8_monitor_write_event "codex" "$request_id" "agent_message" "" "$activity_file"
        ;;
      task_started)
        autonom8_monitor_write_event "codex" "$request_id" "task_started" "" "$activity_file"
        ;;
      task_complete)
        autonom8_monitor_write_event "codex" "$request_id" "task_complete" "" "$activity_file"
        ;;
      user_message)
        ;;
      *)
        if [[ -n "$payload_type" ]]; then
          autonom8_monitor_write_event "codex" "$request_id" "stdout_activity" "$payload_type" "$activity_file"
        fi
        ;;
    esac
  done
}

_autonom8_codex_event_type() {
  local line="$1"
  printf "%s" "$line" | jq -r '
    .payload.type
    // .item.type
    // .type
    // empty
  ' 2>/dev/null || true
}

# ── Generic stderr classifier (fallback) ────────────────────────────────────

autonom8_monitor_cursor_jsonl_stream() {
  local request_id="${1:-${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}}"
  local activity_file="${2:-${AUTONOM8_LIVE_MONITOR_ACTIVITY_FILE:-}}"

  [[ -n "$activity_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || {
    while IFS= read -r _; do :; done
    return 0
  }

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    local event_type subtype
    event_type="$(printf "%s" "$line" | jq -r '.type // empty' 2>/dev/null || true)"
    subtype="$(printf "%s" "$line" | jq -r '.subtype // empty' 2>/dev/null || true)"

    case "$event_type" in
      thinking)
        autonom8_monitor_write_event "cursor" "$request_id" "reasoning" "$subtype" "$activity_file"
        ;;
      tool_call|tool_use)
        local tool_name
        tool_name="$(printf "%s" "$line" | jq -r '
          .tool_call
          | if type == "object" then keys[0] // empty else empty end
        ' 2>/dev/null || true)"
        case "$subtype" in
          completed|result)
            autonom8_monitor_write_event "cursor" "$request_id" "function_call_output" "$tool_name" "$activity_file"
            ;;
          *)
            autonom8_monitor_write_event "cursor" "$request_id" "function_call" "$tool_name" "$activity_file"
            ;;
        esac
        ;;
      tool_result|function_call_output)
        autonom8_monitor_write_event "cursor" "$request_id" "function_call_output" "$subtype" "$activity_file"
        ;;
      assistant|message)
        autonom8_monitor_write_event "cursor" "$request_id" "stdout_activity" "$event_type" "$activity_file"
        ;;
      result)
        autonom8_monitor_write_event "cursor" "$request_id" "token_count" "result" "$activity_file"
        autonom8_monitor_write_event "cursor" "$request_id" "task_complete" "result" "$activity_file"
        ;;
      task_started)
        autonom8_monitor_write_event "cursor" "$request_id" "task_started" "$subtype" "$activity_file"
        ;;
      task_complete)
        autonom8_monitor_write_event "cursor" "$request_id" "task_complete" "$subtype" "$activity_file"
        ;;
      *)
        if [[ -n "$event_type" ]]; then
          autonom8_monitor_write_event "cursor" "$request_id" "stdout_activity" "$event_type" "$activity_file"
        fi
        ;;
    esac
  done
}

_autonom8_classify_generic_stderr() {
  local content="$1"
  local provider="$2"
  local request_id="$3"
  local activity_file="$4"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"

  if printf "%s" "$content" | grep -qiE 'writ(e|ing|ten) |creat(e|ing|ed) '; then
    autonom8_monitor_write_event "$provider" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
  elif printf "%s" "$content" | grep -qiE 'read(ing)? |open(ing|ed) '; then
    autonom8_monitor_write_event "$provider" "$request_id" "file_read" \
      "bytes=$byte_count" "$activity_file"
  else
    autonom8_monitor_write_event "$provider" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

# ── Codex classifiers ───────────────────────────────────────────────────────

_autonom8_classify_codex_stderr() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"
  local wrote_event=false

  if printf "%s" "$content" | grep -qiE 'writ(e|ing|ten)|creat(e|ing|ed).*file|saved'; then
    autonom8_monitor_write_event "codex" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'function.call|tool.call|executing|running.*command'; then
    autonom8_monitor_write_event "codex" "$request_id" "function_call" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'thinking|reasoning'; then
    autonom8_monitor_write_event "codex" "$request_id" "reasoning" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if [[ "$wrote_event" != "true" ]]; then
    autonom8_monitor_write_event "codex" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

# Codex session JSONL classifier — uses .payload.type (not .item.type).
_autonom8_classify_codex_session() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  command -v jq >/dev/null 2>&1 || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local payload_type
    payload_type="$(_autonom8_codex_event_type "$line")"

    case "$payload_type" in
      thread.started|turn.started)
        autonom8_monitor_write_event "codex" "$request_id" "task_started" \
          "source=session_jsonl" "$activity_file"
        ;;
      turn.completed)
        autonom8_monitor_write_event "codex" "$request_id" "token_count" \
          "source=session_jsonl" "$activity_file"
        autonom8_monitor_write_event "codex" "$request_id" "task_complete" \
          "source=session_jsonl" "$activity_file"
        ;;
      reasoning)
        autonom8_monitor_write_event "codex" "$request_id" "reasoning" \
          "source=session_jsonl" "$activity_file"
        ;;
      function_call)
        local fn_name
        fn_name="$(printf "%s" "$line" | jq -r '.payload.name // .item.name // empty' 2>/dev/null || true)"
        autonom8_monitor_write_event "codex" "$request_id" "function_call" \
          "name=$fn_name;source=session_jsonl" "$activity_file"
        ;;
      agent_message)
        autonom8_monitor_write_event "codex" "$request_id" "agent_message" \
          "source=session_jsonl" "$activity_file"
        ;;
      function_call_output)
        autonom8_monitor_write_event "codex" "$request_id" "function_call_output" \
          "source=session_jsonl" "$activity_file"
        ;;
      token_count)
        autonom8_monitor_write_event "codex" "$request_id" "token_count" \
          "source=session_jsonl" "$activity_file"
        ;;
      agent_message)
        autonom8_monitor_write_event "codex" "$request_id" "agent_message" \
          "source=session_jsonl" "$activity_file"
        ;;
      task_started)
        autonom8_monitor_write_event "codex" "$request_id" "task_started" \
          "source=session_jsonl" "$activity_file"
        ;;
      task_complete)
        autonom8_monitor_write_event "codex" "$request_id" "task_complete" \
          "source=session_jsonl" "$activity_file"
        ;;
    esac
  done <<< "$content"
}

# Session discovery: only consider files created after monitor start_epoch.
# Codex sessions live at ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
_autonom8_discover_codex_session() {
  local session_dir="$1"
  local start_epoch="${2:-0}"
  [[ -d "$session_dir" ]] || return 0

  local candidates latest
  if (( start_epoch > 0 )); then
    local ref_file="/tmp/.autonom8_monitor_ref_$$"
    touch -t "$(date -r "$start_epoch" +"%Y%m%d%H%M.%S" 2>/dev/null || date -d "@$start_epoch" +"%Y%m%d%H%M.%S" 2>/dev/null)" "$ref_file" 2>/dev/null || touch "$ref_file"
    candidates="$(find "$session_dir" -name "*.jsonl" -type f -newer "$ref_file" 2>/dev/null)"
    rm -f "$ref_file" 2>/dev/null
  else
    candidates="$(find "$session_dir" -name "*.jsonl" -type f -mmin -2 2>/dev/null)"
  fi

  [[ -n "$candidates" ]] || return 0
  latest="$(printf "%s" "$candidates" | xargs ls -t 2>/dev/null | head -1)"
  [[ -n "$latest" ]] && printf "%s" "$latest"
}

# ── Claude classifiers ──────────────────────────────────────────────────────

_autonom8_classify_claude_stderr() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"
  local wrote_event=false

  if printf "%s" "$content" | grep -qiE 'Wrote |Created |Updated '; then
    autonom8_monitor_write_event "claude" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'Read |Searching |Grep'; then
    autonom8_monitor_write_event "claude" "$request_id" "file_read" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'tool_use|Tool:|Bash|Edit|Write'; then
    autonom8_monitor_write_event "claude" "$request_id" "function_call" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if [[ "$wrote_event" != "true" ]]; then
    autonom8_monitor_write_event "claude" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

_autonom8_classify_claude_session() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"
}

_autonom8_discover_claude_session() {
  return 0
}

# ── Gemini classifiers ──────────────────────────────────────────────────────

_autonom8_classify_gemini_stderr() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"
  local wrote_event=false

  if printf "%s" "$content" | grep -qiE 'writ(e|ing|ten)|creat(e|ing|ed)|updat(e|ing|ed)'; then
    autonom8_monitor_write_event "gemini" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'function.call|tool.call|executing'; then
    autonom8_monitor_write_event "gemini" "$request_id" "function_call" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'thinking|reasoning'; then
    autonom8_monitor_write_event "gemini" "$request_id" "reasoning" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if [[ "$wrote_event" != "true" ]]; then
    autonom8_monitor_write_event "gemini" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

_autonom8_classify_gemini_session() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"
}

_autonom8_discover_gemini_session() {
  return 0
}

# ── Cursor classifiers ──────────────────────────────────────────────────────

_autonom8_classify_cursor_stderr() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"
  local wrote_event=false

  if printf "%s" "$content" | grep -qiE 'writ(e|ing|ten)|creat(e|ing|ed)|saved'; then
    autonom8_monitor_write_event "cursor" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'tool.use|function.call|running'; then
    autonom8_monitor_write_event "cursor" "$request_id" "function_call" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if [[ "$wrote_event" != "true" ]]; then
    autonom8_monitor_write_event "cursor" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

_autonom8_classify_cursor_session() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  command -v jq >/dev/null 2>&1 || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local msg_type
    msg_type="$(printf "%s" "$line" | jq -r '.type // empty' 2>/dev/null || true)"
    case "$msg_type" in
      tool_use|tool_call)
        local tool_name
        tool_name="$(printf "%s" "$line" | jq -r '.name // .tool // empty' 2>/dev/null || true)"
        autonom8_monitor_write_event "cursor" "$request_id" "function_call" \
          "name=$tool_name;source=transcript" "$activity_file"
        ;;
      tool_result)
        autonom8_monitor_write_event "cursor" "$request_id" "function_call_output" \
          "source=transcript" "$activity_file"
        ;;
      result|assistant)
        autonom8_monitor_write_event "cursor" "$request_id" "task_complete" \
          "source=transcript" "$activity_file"
        ;;
    esac
  done <<< "$content"
}

_autonom8_discover_cursor_session() {
  local transcript_dir="$1"
  local start_epoch="${2:-0}"
  [[ -d "$transcript_dir" ]] || return 0

  local candidates latest
  if (( start_epoch > 0 )); then
    local ref_file="/tmp/.autonom8_monitor_ref_$$"
    touch -t "$(date -r "$start_epoch" +"%Y%m%d%H%M.%S" 2>/dev/null || date -d "@$start_epoch" +"%Y%m%d%H%M.%S" 2>/dev/null)" "$ref_file" 2>/dev/null || touch "$ref_file"
    candidates="$(find "$transcript_dir" -name "*.jsonl" -type f -newer "$ref_file" 2>/dev/null)"
    rm -f "$ref_file" 2>/dev/null
  else
    candidates="$(find "$transcript_dir" -name "*.jsonl" -type f -mmin -2 2>/dev/null)"
  fi

  [[ -n "$candidates" ]] || return 0
  latest="$(printf "%s" "$candidates" | xargs ls -t 2>/dev/null | head -1)"
  [[ -n "$latest" ]] && printf "%s" "$latest"
}

# ── OpenCode classifiers ────────────────────────────────────────────────────

_autonom8_classify_opencode_stderr() {
  local content="$1"
  local request_id="$2"
  local activity_file="$3"

  local byte_count
  byte_count="$(printf "%s" "$content" | wc -c | tr -d ' ')"
  local wrote_event=false

  if printf "%s" "$content" | grep -qiE 'writ(e|ing|ten)|creat(e|ing|ed)|saved'; then
    autonom8_monitor_write_event "opencode" "$request_id" "file_write" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if printf "%s" "$content" | grep -qiE 'tool|function|executing|running'; then
    autonom8_monitor_write_event "opencode" "$request_id" "function_call" \
      "bytes=$byte_count" "$activity_file"
    wrote_event=true
  fi
  if [[ "$wrote_event" != "true" ]]; then
    autonom8_monitor_write_event "opencode" "$request_id" "stderr_activity" \
      "bytes=$byte_count" "$activity_file"
  fi
}

_autonom8_classify_opencode_session() {
  return 0
}

_autonom8_discover_opencode_session() {
  return 0
}
