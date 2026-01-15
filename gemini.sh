#!/usr/bin/env bash
# Gemini CLI wrapper for Autonom8
# Configures workspace and invokes gemini CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

# Track child process PID for cleanup on script termination
GEMINI_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker

# Cleanup function to kill child processes on script termination
cleanup() {
  if [[ -n "$GEMINI_PID" ]] && kill -0 "$GEMINI_PID" 2>/dev/null; then
    # Kill process group to ensure children are terminated
    kill -- -"$GEMINI_PID" 2>/dev/null || kill "$GEMINI_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$GEMINI_PID" 2>/dev/null || kill -9 "$GEMINI_PID" 2>/dev/null || true
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
    GEMINI_PID=$pid

    # Wait for completion
    wait $pid
    local exit_code=$?
    GEMINI_PID=""
    return $exit_code
  else
    # Fallback: run in background with manual timeout
    "$@" &
    local pid=$!
    GEMINI_PID=$pid

    local elapsed=0
    while kill -0 $pid 2>/dev/null && [[ $elapsed -lt $timeout_secs ]]; do
      sleep 1
      ((elapsed++))
    done

    if kill -0 $pid 2>/dev/null; then
      kill $pid 2>/dev/null || true
      sleep 0.5
      kill -9 $pid 2>/dev/null || true
      GEMINI_PID=""
      return 124
    else
      wait $pid
      local exit_code=$?
      GEMINI_PID=""
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

get_gemini_mcp_config() {
  if [[ -f "$CORE_DIR/.gemini/.mcp.json" ]]; then
    echo "$CORE_DIR/.gemini/.mcp.json"
  elif [[ -f "$CORE_DIR/.mcp.json" ]]; then
    echo "$CORE_DIR/.mcp.json"
  fi
}

# Ensure a skill is enabled in Gemini's native skill registry
# This allows Gemini to auto-activate skills when needed
ensure_gemini_skill_enabled() {
  local skill_name="$1"
  local scope="${2:-project}"  # project or user

  # Check if skill is already enabled
  local skill_list
  skill_list="$(gemini skills list 2>/dev/null || true)"

  if echo "$skill_list" | grep -q "^$skill_name[[:space:]]"; then
    log_verbose "Skill '$skill_name' already registered"
    return 0
  fi

  # Try to enable the skill
  if gemini skills enable "$skill_name" --scope "$scope" 2>/dev/null; then
    log_verbose "Enabled skill: $skill_name (scope: $scope)"
    return 0
  else
    log_verbose "Could not enable skill '$skill_name' (may not exist in .gemini/skills/)"
    return 1
  fi
}

# Reload Gemini's skill registry to pick up new/modified skills
reload_gemini_skills() {
  gemini skills reload 2>/dev/null || true
  log_verbose "Reloaded Gemini skill registry"
}

# Filter out Gemini CLI informational output from stdout
# Gemini outputs status messages that interfere with JSON parsing:
# - "YOLO mode is enabled. All tool calls will be automatically approved."
# - "Loaded cached credentials."
# - "Tool xyz executed successfully" (tool confirmation messages)
filter_gemini_info_lines() {
  local input="$1"
  echo "$input" | grep -v \
    -e '^YOLO mode is enabled' \
    -e '^Loaded cached credentials' \
    -e '^Tool .* executed' \
    -e '^Connecting to' \
    -e '^Connected\.$' \
    -e '^Session started' \
    -e '^Using model' \
    -e '^Loading' || true
}

ensure_gemini_mcp_servers() {
  local config_path="$1"
  local server_names
  server_names=$(jq -r '.mcpServers | keys[]' "$config_path" 2>/dev/null || true)
  if [[ -z "$server_names" ]]; then
    return 0
  fi

  local current_list
  current_list="$(gemini mcp list 2>/dev/null || true)"

  while read -r server_name; do
    [[ -z "$server_name" ]] && continue
    if ! echo "$current_list" | grep -q "^${server_name}[[:space:]]"; then
      local command
      command=$(jq -r ".mcpServers.\"$server_name\".command" "$config_path" 2>/dev/null || true)
      if [[ -z "$command" || "$command" == "null" ]]; then
        continue
      fi
      mapfile -t args < <(jq -r ".mcpServers.\"$server_name\".args[]?" "$config_path" 2>/dev/null || true)
      gemini mcp add "$server_name" "$command" "${args[@]}" >/dev/null 2>&1 || true
      log_verbose "Registered MCP server for gemini: $server_name"
    fi
  done <<< "$server_names"
}

# Determine core directory based on script location
# Script is in bin/gemini.sh, so CORE_DIR is parent of bin/
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
  local persona_id="$2"   # e.g., pm-gemini | po-gemini
  # Match header "## Persona:" or "### Persona:" (allows trailing labels, e.g. "(Strategic Planner)")
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # hdr now like "pm-gemini (Quality Reviewer)" or "po-gemini (Plan)"; compare prefix to id
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

# Get the latest Gemini session index for the current project
# Returns the index number of the most recent session (highest index = newest)
get_latest_gemini_session() {
  local work_dir="${1:-$PWD}"
  local session_output=""

  # Get session list from Gemini CLI
  # Note: Gemini outputs to stderr, so we redirect stderr to stdout
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>&1 || true)"

  if [[ -n "$session_output" ]]; then
    # Gemini lists sessions oldest-first (1 = oldest, N = newest)
    # Get the LAST session line for the newest session
    # Format: "  374. INSTRUCTIONS: ... (Just now) [42dd8d44-313f-48ae-a422-87b42e1c4393]"
    # Extract the UUID from brackets, not the index number
    local latest_uuid=""
    # Use tail -1 to get the newest (last) session, then extract UUID from [brackets]
    latest_uuid="$(echo "$session_output" | grep -E '^[[:space:]]+[0-9]+\.' | tail -1 | grep -oE '\[[a-f0-9-]+\]$' | tr -d '[]')"

    if [[ -n "$latest_uuid" && ${#latest_uuid} -ge 32 ]]; then
      printf "%s" "$latest_uuid"
      return 0
    fi

    # Fallback: try to get index if UUID extraction failed
    local latest_index=""
    latest_index="$(echo "$session_output" | grep -E '^[[:space:]]+[0-9]+\.' | tail -1 | sed 's/^[[:space:]]*//' | cut -d'.' -f1)"
    if [[ -n "$latest_index" && "$latest_index" =~ ^[0-9]+$ ]]; then
      printf "%s" "$latest_index"
      return 0
    fi
  fi

  return 1
}

# Get the next session index (current count + 1)
get_next_gemini_session_index() {
  local work_dir="${1:-$PWD}"
  local session_output=""
  local session_count=0

  # Get session list and count
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>/dev/null || true)"

  if [[ -n "$session_output" ]]; then
    # Extract the session count from "Available sessions for this project (N):"
    session_count="$(echo "$session_output" | grep -oE 'Available sessions.*\([0-9]+\)' | grep -oE '[0-9]+' || echo "0")"
  fi

  # Next session index will be count + 1
  echo $((session_count + 1))
}

# Validate if a session ID exists in Gemini's session list
# Sessions can be numeric indices or UUIDs
validate_gemini_session() {
  local session_id="$1"
  local work_dir="${2:-$PWD}"
  local session_output=""

  # Get session list from Gemini CLI
  session_output="$(cd "$work_dir" && gemini --list-sessions 2>&1 || true)"

  if [[ -z "$session_output" ]]; then
    return 1
  fi

  # Check if session ID appears in output (supports both index and UUID)
  # Format: "  323. INSTRUCTIONS: ... (Just now) [uuid]"
  if echo "$session_output" | grep -qE "^[[:space:]]+${session_id}\.|\\[${session_id}\\]"; then
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
NO_CONTEXT=false
ALLOW_TOOLS=false  # Gemini handles tool access internally
MCP_SERVER_NAMES=()
SESSION_ID=""        # Existing session index to resume
MANAGE_SESSION=""    # Placeholder for new session (Gemini returns actual index)
SKILL_NAME=""        # Skill to invoke - Gemini now supports native skills (Jan 2026)

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
      # Gemini equivalent: enable tool access
      ALLOW_TOOLS=true
      YOLO_MODE=true  # Gemini uses yolo mode for unrestricted access
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
      # --session-id: From Go CLIManager for consistency with Claude
      # --resume: Native Gemini flag
      SESSION_ID="$2"; shift 2
      ;;
    --manage-session)
      MANAGE_SESSION="$2"; shift 2
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
# Gemini supports native skills via .gemini/skills/ directory (Jan 2026)
# Skills auto-activate when requests match skill descriptions
# Using direct prompt injection for controlled JSON output format
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME via prompt injection (controlled output format)"

  # Ensure skill is registered in Gemini's native skill system
  # This allows Gemini to auto-activate if the prompt matches the skill description
  ensure_gemini_skill_enabled "$SKILL_NAME" "project" || true

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  # Priority: .gemini/skills (project) > modules/Autonom8-Agents (canonical) > other providers
  SKILL_FILE=""
  SKILL_LOCATIONS=(
    "$CORE_DIR/.gemini/skills/${SKILL_NAME}/SKILL.md"
    "$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"
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

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    jq -n --arg skill "$SKILL_NAME" --arg file "$SKILL_FILE" \
      '{dry_run: true, wrapper: "gemini.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed", note: "fallback_mode"}'
    exit 0
  fi

  # Create temp files
  TMPFILE_PROMPT="$(mktemp)"
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  echo "$SKILL_PROMPT" > "$TMPFILE_PROMPT"

  # Determine tenant directory
  TENANT_DIR=""
  if [[ "$PWD" =~ .*/tenants/([^/]+)$ ]]; then
    TENANT_DIR="$PWD"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    TENANT_DIR="$CORE_DIR/tenants/oxygen"
  fi

  # Build gemini args
  GEMINI_ARGS=()
  if [[ -n "$TENANT_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$TENANT_DIR")
  fi
  GEMINI_ARGS+=("--include-directories" "$CORE_DIR")

  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi

  log_verbose "Invoking gemini CLI for skill (Tenant: ${TENANT_DIR:-none})"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    cat "$TMPFILE_PROMPT" | run_with_timeout "$CLI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    cat "$TMPFILE_PROMPT" | gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  GEMINI_EXIT=$?
  set -e

  rm -f "$TMPFILE_PROMPT"

  if [[ $GEMINI_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    jq -n --arg err "$ERROR_MSG" --arg skill "$SKILL_NAME" '{error: $err, skill: $skill}'
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  # Filter out Gemini CLI informational output before parsing
  RESPONSE_TEXT="$(filter_gemini_info_lines "$RESPONSE_TEXT")"

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
    MCP_CONFIG_PATH="$(get_gemini_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_gemini_mcp_servers "$MCP_CONFIG_PATH"
      mapfile -t MCP_SERVER_NAMES < <(jq -r '.mcpServers | keys[]' "$MCP_CONFIG_PATH" 2>/dev/null || true)
    fi
  else
    TOOL_RULES="- Do NOT use any tools or commands
- Do NOT explore the codebase or read files"
    log_verbose "Tools DISABLED (default mode)"
  fi

  # Compose final prompt with explicit instructions to prevent gemini from responding to persona
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
  \"wrapper\": \"gemini.sh\",
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

  # Change to tenant directory for correct context
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

  # Note: Gemini CLI may not expose temperature directly via CLI args
  # Temperature is accepted for API consistency but logged only
  if [[ -n "$TEMPERATURE" ]]; then
    # Gemini uses --temp notation
    GEMINI_ARGS+=("--temp" "$TEMPERATURE")
    log_verbose "Temperature specified: $TEMPERATURE (via --temp flag)"
  fi
  log_verbose "Invoking gemini CLI (Tenant: ${TENANT_DIR:-none}, YOLO: $YOLO_MODE)"

  # Build gemini args
  GEMINI_ARGS=(
    "--include-directories" "$TENANT_DIR"
    "--include-directories" "$CORE_DIR"
  )

  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi
  if [[ "$ALLOW_TOOLS" == "true" && ${#MCP_SERVER_NAMES[@]} -gt 0 ]]; then
    GEMINI_ARGS+=("--allowed-mcp-server-names" "${MCP_SERVER_NAMES[@]}")
  fi

  # Add session args for session persistence
  # --session-id: Resume existing session (Gemini uses index-based sessions)
  # --manage-session: Create new session (we'll get the actual index after running)
  GEMINI_SESSION_ID=""
  CREATING_NEW_SESSION=false

  if [[ -n "$SESSION_ID" ]]; then
    # Validate session exists before attempting to resume
    # Gemini sessions are scoped to working directory
    if validate_gemini_session "$SESSION_ID" "$PWD"; then
      GEMINI_ARGS+=("--resume" "$SESSION_ID")
      GEMINI_SESSION_ID="$SESSION_ID"
      log_verbose "Resuming session: $SESSION_ID"
    else
      log_verbose "Session $SESSION_ID not found, starting fresh session"
      # Fall through to create new session behavior
      CREATING_NEW_SESSION=true
    fi
  elif [[ -n "$MANAGE_SESSION" ]]; then
    # For new sessions, Gemini auto-creates when we don't use --resume
    # We'll get the actual session index after the call completes
    CREATING_NEW_SESSION=true
    log_verbose "Creating new session (will get index after completion)"
  fi

  # Check if gemini supports -o flag and schema (similar to claude/codex)
  # If not supported, we'll capture output differently
  # For now, assume gemini outputs to stdout
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running gemini with timeout: ${CLI_TIMEOUT}s"
    cat "$TMPFILE_PROMPT" | run_with_timeout "$CLI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    GEMINI_EXIT=$?
  else
    cat "$TMPFILE_PROMPT" | gemini "${GEMINI_ARGS[@]}" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    GEMINI_EXIT=$?
  fi
  set -e

  rm -f "$TMPFILE_PROMPT"

  # Capture session ID for fresh successful calls (always capture, not just when MANAGE_SESSION)
  if [[ -z "$GEMINI_SESSION_ID" && $GEMINI_EXIT -eq 0 ]]; then
    # Gemini sessions are scoped to the directory where gemini was invoked
    # Since we run gemini from the script's working directory (PWD), look there
    # Note: --include-directories doesn't change where sessions are stored
    WORK_DIR="$PWD"

    # Get the latest session index (the one we just created)
    GEMINI_SESSION_ID="$(get_latest_gemini_session "$WORK_DIR" || true)"
    if [[ -n "$GEMINI_SESSION_ID" ]]; then
      log_verbose "New session created with index: $GEMINI_SESSION_ID"
    else
      log_verbose "Could not determine new session index"
    fi
  fi

  if [[ $GEMINI_EXIT -ne 0 ]]; then
    # Gemini failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    log_verbose "Gemini execution failed: $ERROR_MSG"

    # Check if this is an invalid session error - fail fast, don't retry
    if echo "$ERROR_MSG" | grep -qi "Invalid session identifier"; then
      log_verbose "Invalid session detected - clearing stale session"
      rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
      jq -n --arg err "$ERROR_MSG" --arg sid "$SESSION_ID" '{error: $err, stale_session: $sid, action: "clear_session"}'
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
      MSG_FILE="$SYSTEM_MSG_DIR/$(date +%s)-gemini-usage-limit.json"

      jq -n \
        --arg ts "$TIMESTAMP" \
        --arg cli "gemini" \
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

  # Read the output which should contain the response
  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"

  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  # Filter out Gemini CLI informational output before parsing
  # Gemini outputs "YOLO mode is enabled..." and similar to stdout
  RESPONSE_TEXT="$(filter_gemini_info_lines "$RESPONSE_TEXT")"

  if [[ -n "$RESPONSE_TEXT" && "$RESPONSE_TEXT" != "null" ]]; then
    # Try to extract JSON from the response (gemini may wrap it in markdown)
    # First try to extract JSON code block
    JSON_BLOCK=$(echo "$RESPONSE_TEXT" | sed -n '/^```json/,/^```/p' | sed '1d;$d' 2>/dev/null || echo "")
    
    FINAL_RESPONSE=""
    if [[ -n "$JSON_BLOCK" ]]; then
      # Found JSON in code block
      if echo "$JSON_BLOCK" | jq empty 2>/dev/null; then
        FINAL_RESPONSE="$JSON_BLOCK"
      fi
    fi
    
    if [[ -z "$FINAL_RESPONSE" ]]; then
      # No code block or invalid, try the raw response
      # Strip any markdown fences first just in case
      CLEAN_TEXT=$(echo "$RESPONSE_TEXT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
      if echo "$CLEAN_TEXT" | jq empty 2>/dev/null; then
        FINAL_RESPONSE="$CLEAN_TEXT"
      fi
    fi
    
    if [[ -n "$FINAL_RESPONSE" ]]; then
        # Wrap in CLIResponse format for Go worker
        # Include session_id if a session was used or created
        if [[ -n "$GEMINI_SESSION_ID" ]]; then
          # Session was resumed or created - use the actual session index
          jq -n --arg resp "$FINAL_RESPONSE" --arg sid "$GEMINI_SESSION_ID" '{response: $resp, session_id: $sid}'
        else
          jq -n --arg resp "$FINAL_RESPONSE" '{response: $resp}'
        fi
    else
        # Not valid JSON - wrap raw text in error or raw_response
        jq -n --arg text "$RESPONSE_TEXT" '{error:"Response is not valid JSON", raw_response:$text}'
    fi
  else
    jq -n '{error:"No response from Gemini CLI"}'
  fi
else
  # Direct invocation with text prompt

  # Determine tenant directory for direct invocation
  TENANT_DIR=""
  if [[ "$PWD" =~ .*/tenants/([^/]+)$ ]]; then
    TENANT_DIR="$PWD"
  elif [[ -d "$CORE_DIR/tenants" ]]; then
    if [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
      TENANT_DIR="$CORE_DIR/tenants/oxygen"
    else
      TENANT_DIR=$(find "$CORE_DIR/tenants" -maxdepth 1 -type d ! -name tenants | head -1)
    fi
  fi

  # Build gemini args
  GEMINI_ARGS=()
  if [[ -n "$TENANT_DIR" ]]; then
    GEMINI_ARGS+=("--include-directories" "$TENANT_DIR")
  fi
  GEMINI_ARGS+=("--include-directories" "$CORE_DIR")

  if [[ "$YOLO_MODE" == "true" ]]; then
    GEMINI_ARGS+=("--yolo")
  fi

  log_verbose "Running in direct invocation mode"
  gemini "${GEMINI_ARGS[@]}" "$@"
fi
