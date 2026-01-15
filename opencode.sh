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

# OpenCode model configuration - use Grok for fast responses
OPENCODE_MODEL="opencode/grok-code"

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
  session_output="$(cd "$work_dir" && opencode session list 2>/dev/null | tail -n +3 | head -1 || true)"
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
  local persona_id="$2"   # e.g., pm-opencode | po-opencode
  # Match header "## Persona:" or "### Persona:" (allows trailing labels, e.g. "(Strategic Planner)")
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # hdr now like "pm-opencode (Communicator)" or "po-opencode (Communicate)"; compare prefix to id
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

# Initialize flags
PERSONA_OVERRIDE=""
YOLO_MODE=false
VERBOSE=false
CONTEXT_FILE=""
CONTEXT_DIR=""
CONTEXT_MAX=51200  # 50KB default max context size
NO_CONTEXT=false
SESSION_ID=""
ALLOW_TOOLS=false  # OpenCode handles tool access internally
SKILL_NAME=""      # Skill to invoke (from .claude/commands/)

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
    --no-context)
      NO_CONTEXT=true; shift
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
    --allowed-tools)
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
    *)
      break
      ;;
  esac
done

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

  # Invoke OpenCode with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

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
    if [[ "$NO_CONTEXT" == "true" || -n "$SESSION_ID" ]]; then
      FULL_PROMPT="$BASE_PROMPT"
    else
      FULL_PROMPT="${BASE_PROMPT}${CRITICAL_SUFFIX}"
    fi
  else
    FULL_PROMPT="$AGENT_PROMPT"
  fi

  # Note: OpenCode CLI doesn't have a sandbox bypass flag like Claude/Codex
  # YOLO_MODE triggers stderr warning - recommend using Claude for YOLO operations
  if [[ "$YOLO_MODE" == "true" ]]; then
    echo "⚠️  [OpenCode] YOLO mode requested but OpenCode lacks --dangerously-skip-permissions" >&2
    echo "⚠️  [OpenCode] For headless file operations, consider using Claude or Codex provider" >&2
    log_verbose "YOLO mode requested but OpenCode doesn't support sandbox bypass"
  fi

  # Invoke opencode CLI with the agent prompt
  # OpenCode uses 'run' subcommand for agent execution
  # Pass the full prompt directly as the message argument (OpenCode doesn't handle -f file attachments well as instructions)
  # Capture output and wrap in CLIResponse format for Go worker
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  set +e
  # Pass the entire prompt as the message to opencode run
  # Get session ID from `opencode session list` after run completes
  # Always use Grok model for fast responses

  # Build session args if session resume requested
  SESSION_ARGS="$(build_session_args)"

  echo "🤖 [OpenCode] Using model: $OPENCODE_MODEL" >&2
  if [[ -n "$SESSION_ARGS" ]]; then
    echo "🤖 [OpenCode] Session: $SESSION_ARGS" >&2
  fi
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running opencode with timeout: ${CLI_TIMEOUT}s, model: $OPENCODE_MODEL, session: $SESSION_ARGS"
    echo "🤖 [OpenCode] Timeout: ${CLI_TIMEOUT}s" >&2
    # shellcheck disable=SC2086
    run_with_timeout "$CLI_TIMEOUT" opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    # shellcheck disable=SC2086
    opencode run -m "$OPENCODE_MODEL" $SESSION_ARGS "$FULL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  OPENCODE_EXIT=$?
  set -e

  if [[ $OPENCODE_EXIT -ne 0 ]]; then
    # OpenCode failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    jq -n --arg err "$ERROR_MSG" '{error: $err}'
    exit 1
  fi

  # Read the output file
  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
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
    if [[ -n "$OPENCODE_SESSION_ID" ]]; then
      jq -n --arg resp "$RESPONSE_TEXT" --arg sid "$OPENCODE_SESSION_ID" '{response: $resp, session_id: $sid}'
    else
      jq -n --arg resp "$RESPONSE_TEXT" '{response: $resp}'
    fi
  else
    jq -n '{error:"No response from OpenCode CLI"}'
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
