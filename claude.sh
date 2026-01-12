#!/usr/bin/env bash
# Claude CLI wrapper for Autonom8
# Configures workspace and invokes claude CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

# Track child process PID for cleanup on script termination
CLAUDE_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker

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
    CLAUDE_PID=$pid

    # Wait for completion
    wait $pid
    local exit_code=$?
    CLAUDE_PID=""
    return $exit_code
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

# Agent invocation mode: wrapper expects agent .md file path + optional input data
# We must extract a single persona block, not pass the whole file.

validate_agent_file() {
  local file="$1"
  # Ensure at least one valid persona section exists (support both ## and ### headers)
  # Pattern: ^##{1,} matches ## or ### or more
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
  local persona_id="$2"   # e.g., pm-claude | po-claude
  # Match header "## Persona:" or "### Persona:" (allows trailing labels, e.g. "(Strategic Planner)")
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # hdr now like "pm-claude (Strategic Planner)" or "po-claude (Vision)"; compare prefix to id
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
NO_CONTEXT=false
SESSION_ID=""        # Existing session ID to resume
NEW_SESSION=""       # Flag to create new session (capture ID from response)
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
    --dry-run)
      DRY_RUN=true; shift
      ;;
    --verbose|--debug)
      VERBOSE=true; shift
      ;;
    --allow-tools)
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

  # Determine working directory
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    WORK_DIR="$CORE_DIR/tenants/oxygen"
  fi

  log_verbose "Invoking claude CLI for skill (WorkDir: ${WORK_DIR:-none})"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format text $BYPASS_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
    else
      echo "$SKILL_PROMPT" | claude --print --output-format text $BYPASS_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    fi
  fi
  CLAUDE_EXIT=$?
  set -e

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    jq -n --arg err "$ERROR_MSG" --arg skill "$SKILL_NAME" '{error: $err, skill: $skill}'
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

    # Wrap in CLIResponse format
    jq -n --arg resp "$RESPONSE_TEXT" --arg skill "$SKILL_NAME" '{response: $resp, skill: $skill}'
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
  \"wrapper\": \"claude.sh\",
  \"persona\": \"$PERSONA_ID\",
  \"agent_file\": \"$AGENT_FILE_ABS\",
  \"validation\": \"passed\",
  \"message\": \"Dry-run validation successful - no actual CLI call made\"
}"
    echo "$MOCK_RESPONSE"
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
  SESSION_ARG=""
  OUTPUT_FORMAT="text"
  CLAUDE_SESSION_ID=""  # Will be populated from response

  if [[ -n "$SESSION_ID" ]]; then
    # Resume existing session - use --resume flag directly
    # No validation needed - Claude will error if session doesn't exist
    SESSION_ARG="--resume $SESSION_ID"
    CLAUDE_SESSION_ID="$SESSION_ID"
    log_verbose "Resuming session: $SESSION_ID"
  elif [[ "$NEW_SESSION" == "true" ]]; then
    # New session requested - let Claude generate its own session ID
    # Use --output-format json to capture session_id from response
    OUTPUT_FORMAT="json"
    log_verbose "Creating new session (will capture ID from response)"
  fi

  log_verbose "Invoking claude CLI (WorkDir: ${WORK_DIR:-none}, Bypass: ${BYPASS_ARG:-none}, Session: ${SESSION_ARG:-none}, Format: $OUTPUT_FORMAT)"

  # Use --print mode for non-interactive operation
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running claude with timeout: ${CLI_TIMEOUT}s"
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
      CLAUDE_EXIT=$?
    else
      echo "$FULL_PROMPT" | run_with_timeout "$CLI_TIMEOUT" claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
      CLAUDE_EXIT=$?
    fi
  else
    if [[ -n "$WORK_DIR" ]]; then
      (cd "$WORK_DIR" && echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT")
      CLAUDE_EXIT=$?
    else
      echo "$FULL_PROMPT" | claude --print --output-format "$OUTPUT_FORMAT" $BYPASS_ARG $SESSION_ARG 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
      CLAUDE_EXIT=$?
    fi
  fi
  set -e

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    # Claude failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    log_verbose "Claude execution failed: $ERROR_MSG"

    # Check if this is a usage limit error
    if echo "$ERROR_MSG" | grep -qi "usage limit\|out of.*messages\|out of.*credits\|purchase more credits"; then
      # Extract retry time if available (e.g., "try again at 6:13 PM")
      RETRY_TIME=$(echo "$ERROR_MSG" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")

      # Create system message for usage limit
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
    jq -n --arg err "$ERROR_MSG" '{error: $err}'
    exit 1
  fi

  # Read the output file which should contain the last message
  RAW_OUTPUT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -z "$RAW_OUTPUT" || "$RAW_OUTPUT" == "null" ]]; then
    jq -n '{error:"No response from Claude CLI"}'
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
        jq -n --arg err "${ERROR_MSGS:-Unknown error}" '{error: $err}'
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
  if [[ -n "$CLAUDE_SESSION_ID" ]]; then
    jq -n --arg resp "$RESPONSE_TEXT" --arg sid "$CLAUDE_SESSION_ID" '{response: $resp, session_id: $sid}'
  else
    jq -n --arg resp "$RESPONSE_TEXT" '{response: $resp}'
  fi
else
  # Direct invocation
  BYPASS_ARG=""
  if [[ "$YOLO_MODE" == "true" ]]; then
    BYPASS_ARG="--dangerously-skip-permissions"
  fi

  log_verbose "Running in direct invocation mode"
  claude --print --output-format text $BYPASS_ARG "$@"
fi
