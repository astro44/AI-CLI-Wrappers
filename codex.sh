#!/usr/bin/env bash
# Codex CLI wrapper for Autonom8
# Configures workspace and invokes codex CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

# Track child process PID for cleanup on script termination
CODEX_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$CODEX_PID" ]] && kill -0 "$CODEX_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$CODEX_PID" 2>/dev/null || kill "$CODEX_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$CODEX_PID" 2>/dev/null || kill -9 "$CODEX_PID" 2>/dev/null || true
  fi
  # Also kill any orphaned child processes
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT TERM INT

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
    # Fallback: run in background with manual timeout (stdin may not work)
    "$@" &
    local pid=$!
    CODEX_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      CODEX_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      CODEX_PID=""
      return $exit_code
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
    if ! codex mcp get "$server_name" --json >/dev/null 2>&1; then
      local command
      command=$(jq -r ".mcpServers.\"$server_name\".command" "$config_path" 2>/dev/null || true)
      if [[ -z "$command" || "$command" == "null" ]]; then
        continue
      fi
      mapfile -t args < <(jq -r ".mcpServers.\"$server_name\".args[]?" "$config_path" 2>/dev/null || true)
      codex mcp add "$server_name" "$command" "${args[@]}" >/dev/null 2>&1 || true
      log_verbose "Registered MCP server for codex: $server_name"
    fi
  done <<< "$server_names"
}

# Determine core directory based on script location
# Script is in bin/codex.sh, so CORE_DIR is parent of bin/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"

# Agent invocation mode: wrapper expects agent .md file path + optional input data
# We must extract a single persona block, not pass the whole file.

validate_agent_file() {
  local file="$1"
  # Ensure at least one valid persona section exists (support both ## and ### headers)
  if ! grep -qE '^##+[[:space:]]+Persona:' "$file"; then
    jq -n --arg file "$file" \
      '{error:"Invalid agent file format", details:"Missing `## Persona:` or `### Persona:` header in \($file)"}'
    exit 3
  fi

  # Ensure each persona has at least some description or instructions
  if ! awk '/^##+[[:space:]]+Persona:/{count++} END{exit (count>=1)?0:1}' "$file"; then
    jq -n --arg file "$file" \
      '{error:"Invalid agent file format", details:"No valid persona blocks detected in \($file)"}'
    exit 3
  fi
}

extract_persona_block() {
  local file="$1"
  local persona_id="$2"   # e.g., pm-codex | pm-gemini | pm-claude | po-codex
  # Match header "## Persona:" or "### Persona:" (allows trailing labels, e.g. "(Strategic Planner)")
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # hdr now like "pm-codex (Strategic Planner)" or "po-codex (Stories)"; compare prefix to id
      split(hdr,a," ")
      if(a[1]==id){found=1; print $0; next}
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

get_latest_codex_session() {
  # Get the most recent session ID from rollout files
  # Files are: ~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-<session-id>.jsonl
  # Session ID is the UUID at the end of the filename (36 chars: 8-4-4-4-12)
  if [[ -d "$HOME/.codex/sessions" ]]; then
    local latest_file
    latest_file=$(find "$HOME/.codex/sessions" -name "rollout-*.jsonl" -type f -print0 2>/dev/null | \
      xargs -0 ls -t 2>/dev/null | head -1)
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
NO_CONTEXT=false
ALLOW_TOOLS=false  # Codex handles tool access via --dangerously-bypass-approvals-and-sandbox
SESSION_ID=""        # Existing session ID to resume
MANAGE_SESSION=""    # Placeholder for new session tracking
SKILL_NAME=""        # Skill to invoke (from .claude/commands/)
QUOTA_STATUS=false   # Check and return quota status

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
    --no-context)
      NO_CONTEXT=true; shift
      ;;
    --yolo)
      YOLO_MODE=true; shift
      ;;
    --allowed-tools)
      # Codex equivalent: enable tool access via bypass flag
      # This flag is consumed here and translates to enabling YOLO mode
      ALLOW_TOOLS=true
      YOLO_MODE=true  # Codex uses bypass mode for tool access
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
      # Codex supports sessions via ~/.codex/sessions/ directory
      # Resume with: codex exec resume "$SESSION_ID"
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
# Skill Execution Mode
# ===================
# If --skill flag is provided, invoke skill directly via Codex
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME"

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.codex/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/.claude/commands/${SKILL_NAME}.md"
  )

  for loc in "${SKILL_LOCATIONS[@]}"; do
    if [[ -f "$loc" ]]; then
      SKILL_FILE="$loc"
      break
    fi
  done

  if [[ -z "$SKILL_FILE" ]]; then
    jq -n --arg skill "$SKILL_NAME" '{error: "Skill not found", skill: $skill, searched: ["/.claude/commands/"]}'
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
  RESUME_ARG=""
  if [[ -n "$SESSION_ID" ]]; then
    if validate_codex_session "$SESSION_ID"; then
      RESUME_ARG="resume $SESSION_ID"
      log_verbose "Skill resuming session: $SESSION_ID"
    else
      log_verbose "Skill session $SESSION_ID not found, starting fresh"
    fi
  fi

  log_verbose "Invoking codex CLI for skill (WorkDir: ${WORK_DIR:-none}, Resume: ${RESUME_ARG:-none})"

  # Export CODEX_SANDBOX so Playwright skips WebKit and Firefox (crashes in sandbox)
  export CODEX_SANDBOX=1
  export SKIP_WEBKIT=1
  export SKIP_FIREFOX=1

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_ARG" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR")
      else
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $SANDBOX_ARG $BYPASS_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null)
      fi
    else
      if [[ -n "$RESUME_ARG" ]]; then
        echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR"
      else
        echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $SANDBOX_ARG $BYPASS_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null
      fi
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_ARG" ]]; then
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR")
      else
        (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | codex exec $SANDBOX_ARG $BYPASS_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null)
      fi
    else
      if [[ -n "$RESUME_ARG" ]]; then
        echo "$SKILL_PROMPT" | codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR"
      else
        echo "$SKILL_PROMPT" | codex exec $SANDBOX_ARG $BYPASS_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null
      fi
    fi
  fi
  CODEX_EXIT=$?
  set -e

  # Capture session ID created by codex (for session continuity)
  CODEX_SESSION_ID=""
  if [[ $CODEX_EXIT -eq 0 ]]; then
    CODEX_SESSION_ID="$(get_latest_codex_session)"
    if [[ -n "$CODEX_SESSION_ID" ]]; then
      log_verbose "Skill session created: $CODEX_SESSION_ID"
    fi
  fi

  if [[ $CODEX_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    # Truncate error to avoid "argument list too long"
    jq -n --arg err "$(echo "$ERROR_MSG" | head -c 4000)" --arg skill "$SKILL_NAME" '{error: $err, skill: $skill}'
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Strip markdown code fences if present
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi

    # Wrap in CLIResponse format with session_id if captured
    if [[ -n "$CODEX_SESSION_ID" ]]; then
      jq -n --arg resp "$RESPONSE_TEXT" --arg skill "$SKILL_NAME" --arg sid "$CODEX_SESSION_ID" \
        '{response: $resp, skill: $skill, session_id: $sid}'
    else
      jq -n --arg resp "$RESPONSE_TEXT" --arg skill "$SKILL_NAME" '{response: $resp, skill: $skill}'
    fi
  else
    jq -n --arg skill "$SKILL_NAME" '{error: "No response from skill execution", skill: $skill}'
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

  if [[ "$NO_CONTEXT" == "true" ]]; then
    log_verbose "Context loading disabled (--no-context)"
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
  if [[ "$NO_CONTEXT" != "true" && -n "$RESOLVED_CONTEXT_FILE" && -f "$RESOLVED_CONTEXT_FILE" ]]; then
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
    echo "{\"error\":\"persona '$PERSONA_ID' not found in agent file\"}"
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
    if [[ "$NO_CONTEXT" == "true" || -n "$SESSION_ID" ]]; then
      FULL_PROMPT="$BASE_PROMPT"
    else
      FULL_PROMPT="${BASE_PROMPT}${CRITICAL_SUFFIX}"
    fi
  else
    FULL_PROMPT="$AGENT_PROMPT"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_verbose "DRY-RUN MODE: Skipping actual CLI call"
    
    MOCK_RESPONSE="{
  \"dry_run\": true,
  \"wrapper\": \"codex.sh\",
  \"persona\": \"$PERSONA_ID\",
  \"agent_file\": \"$AGENT_FILE_ABS\",
  \"validation\": \"passed\",
  \"message\": \"Dry-run validation successful - no actual CLI call made\"
}"
    echo "$MOCK_RESPONSE"
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
  # Syntax: codex exec -c temperature=0.4 ...
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
  # Resume with: codex exec resume "$SESSION_ID" or codex resume "$SESSION_ID"
  RESUME_ARG=""
  CODEX_SESSION_ID=""

  if [[ -n "$SESSION_ID" ]]; then
    # Validate session exists
    if validate_codex_session "$SESSION_ID"; then
      RESUME_ARG="resume $SESSION_ID"
      CODEX_SESSION_ID="$SESSION_ID"
      log_verbose "Resuming session: $SESSION_ID"
    else
      log_verbose "Session $SESSION_ID not found in ~/.codex/sessions/, starting fresh"
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    # New session will be created; we'll capture the ID after execution
    log_verbose "Creating new session (will capture ID after execution)"
  fi

  log_verbose "Invoking codex CLI (WorkDir: ${WORK_DIR:-none}, Bypass: ${BYPASS_ARG:-none}, Temp: ${TEMPERATURE:-default}, Resume: ${RESUME_ARG:-none})"

  # Note: Removed --json flag because it causes streaming JSONL output which conflicts with -o flag
  # The -o flag already writes only the last message, and --output-schema enforces JSON structure
  # Redirect stdout to /dev/null to prevent duplicate output (codex writes to both file and stdout)

  # Execute in working dir if possible
  # Export CODEX_SANDBOX so Playwright skips WebKit and Firefox (crashes in sandbox)
  export CODEX_SANDBOX=1
  export SKIP_WEBKIT=1
  export SKIP_FIREFOX=1

  # Temporarily disable set -e to capture exit code properly
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running codex with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_ARG" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR")
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null)
      fi
      CODEX_EXIT=$?
    else
      if [[ -n "$RESUME_ARG" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR"
      else
        echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" codex exec $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null
      fi
      CODEX_EXIT=$?
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      if [[ -n "$RESUME_ARG" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR")
      else
        (cd "$WORK_DIR" && echo "$FULL_PROMPT" | codex exec $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null)
      fi
      CODEX_EXIT=$?
    else
      if [[ -n "$RESUME_ARG" ]]; then
        # Resume mode: --sandbox/-o not supported, capture stdout directly with '-' for stdin prompt
        echo "$FULL_PROMPT" | codex exec $RESUME_ARG $BYPASS_ARG - > "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR"
      else
        echo "$FULL_PROMPT" | codex exec $SANDBOX_ARG $BYPASS_ARG $SCHEMA_ARG $TEMP_ARG -o "$TMPFILE_OUTPUT" 2> "$TMPFILE_ERR" > /dev/null
      fi
      CODEX_EXIT=$?
    fi
  fi
  set -e

  # Capture session ID if new session was created (always capture for fresh calls)
  if [[ -z "$CODEX_SESSION_ID" && $CODEX_EXIT -eq 0 ]]; then
    CODEX_SESSION_ID="$(get_latest_codex_session)"
    if [[ -n "$CODEX_SESSION_ID" ]]; then
      log_verbose "New session created: $CODEX_SESSION_ID"
    fi
  fi

  if [[ $CODEX_EXIT -ne 0 ]]; then
    # Codex failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    log_verbose "Codex execution failed: $ERROR_MSG"

    # Check if this is an invalid session error - fail fast
    if echo "$ERROR_MSG" | grep -qi "session.*not found\|invalid session\|session.*expired\|no such session"; then
      log_verbose "Invalid session detected - clearing stale session"
      rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
      # Use heredoc to avoid "argument list too long" for large error messages
      jq -n --arg sid "$SESSION_ID" --arg err "$(echo "$ERROR_MSG" | head -c 4000)" '{error: $err, stale_session: $sid, action: "clear_session"}'
      exit 1
    fi

    # Check if this is a usage limit error
    if echo "$ERROR_MSG" | grep -qi "usage limit\|out of.*messages\|out of.*credits\|purchase more credits"; then
      # Extract retry time if available (e.g., "try again at 6:13 PM")
      RETRY_TIME=$(echo "$ERROR_MSG" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")

      # Create system message for usage limit
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
    # Truncate error to avoid "argument list too long"
    jq -n --arg err "$(echo "$ERROR_MSG" | head -c 4000)" '{error: $err}'
    exit 1
  fi

  # Read the output file which should contain the last message
  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"

  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Strip markdown code fences if present (```json ... ```)
    if [[ "$RESPONSE_TEXT" =~ ^\`\`\`json[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```json[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    elif [[ "$RESPONSE_TEXT" =~ ^\`\`\`[[:space:]]* ]]; then
      RESPONSE_TEXT="$(echo "$RESPONSE_TEXT" | sed -e 's/^```[[:space:]]*//' -e 's/```[[:space:]]*$//')"
    fi

    # Wrap in CLIResponse format for Go worker
    # Include session_id if session was used or created
    if [[ -n "$CODEX_SESSION_ID" ]]; then
      jq -n --arg resp "$RESPONSE_TEXT" --arg sid "$CODEX_SESSION_ID" '{response: $resp, session_id: $sid}'
    else
      jq -n --arg resp "$RESPONSE_TEXT" '{response: $resp}'
    fi
  else
    jq -n '{error:"No response from Codex CLI"}'
  fi
else
  # Direct invocation with text prompt
  BYPASS_ARG=""
  SANDBOX_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-bypass-approvals-and-sandbox"
    SANDBOX_ARG="--sandbox danger-full-access"
  fi

  log_verbose "Running in direct invocation mode"
  codex exec $SANDBOX_ARG $BYPASS_ARG "$@"
fi
