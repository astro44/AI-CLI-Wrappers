#!/usr/bin/env bash
# Cursor CLI wrapper for Autonom8
# Configures workspace and invokes cursor-agent CLI with proper context and permissions
# Updated to support --dry-run and --verbose (v2.1)

set -euo pipefail

# Track child process PID for cleanup on script termination
CURSOR_PID=""
CLI_TIMEOUT=""  # Timeout in seconds, passed from Go worker

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
    CURSOR_PID=$pid

    # Wait for completion
    wait $pid
    local exit_code=$?
    CURSOR_PID=""
    return $exit_code
  else
    # Fallback: run in background with manual timeout
    "$@" &
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

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] DEBUG: $*" >&2
    fi
}

get_cursor_mcp_config() {
  if [[ -f "$CORE_DIR/.cursor/mcp.json" ]]; then
    echo "$CORE_DIR/.cursor/mcp.json"
  elif [[ -f "$CORE_DIR/.mcp.json" ]]; then
    echo "$CORE_DIR/.mcp.json"
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

  mkdir -p "$cursor_dir"

  if [[ -f "$cursor_config" ]]; then
    local tmpfile
    tmpfile="$(mktemp)"
    if jq -s '.[0] as $existing | .[1] as $incoming | ($existing + $incoming) | .mcpServers = (($existing.mcpServers // {}) + ($incoming.mcpServers // {}))' \
      "$cursor_config" "$config_path" > "$tmpfile" 2>/dev/null; then
      mv "$tmpfile" "$cursor_config"
    else
      rm -f "$tmpfile"
    fi
  else
    cp "$config_path" "$cursor_config"
  fi
}

# Determine core directory based on script location
# Script is in bin/cursor.sh, so CORE_DIR is parent of bin/
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
  local persona_id="$2"   # e.g., pm-cursor | po-cursor
  # Match header "## Persona:" or "### Persona:" (allows trailing labels, e.g. "(Strategic Planner)")
  awk -v id="$persona_id" '
    BEGIN{found=0}
    /^##+[[:space:]]+Persona:[[:space:]]+/{
      if(found){exit}
      hdr=$0
      sub(/^##+[[:space:]]+Persona:[[:space:]]+/, "", hdr)
      # hdr now like "pm-cursor (Quality Reviewer)" or "po-cursor (Plan)"; compare prefix to id
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

create_cursor_session() {
  local raw_output=""
  local session_id=""

  raw_output="$(cursor-agent create-chat 2>/dev/null || true)"
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
  sessions_output="$(cursor-agent list-chats 2>/dev/null || true)"

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
NO_CONTEXT=false
ALLOW_TOOLS=false  # Cursor uses --force/--approve-mcps for tool access
SESSION_ID=""        # Existing session ID to resume
MANAGE_SESSION=""    # Request to create a new session (Cursor returns ID)
SKILL_NAME=""        # Skill to invoke (from .claude/commands/) - beta support

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
    --no-context)
      NO_CONTEXT=true; shift
      ;;
    --yolo)
      YOLO_MODE=true; shift
      ;;
    --allowed-tools)
      # Cursor equivalent: enable tool access and auto-approve MCPs
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
    *)
      break
      ;;
  esac
done

# ===================
# Skill Execution Mode (Beta)
# ===================
# Cursor skills support is in beta - using prompt fallback
if [[ -n "$SKILL_NAME" ]]; then
  log_verbose "Skill mode: invoking /$SKILL_NAME (Cursor skills are in beta - using prompt fallback)"
  echo "⚠️  [Cursor] Skills support is in beta - using prompt-based execution" >&2

  # Gather input data from remaining args or stdin
  SKILL_INPUT="$(parse_arg_json_or_stdin "$@")"

  # Resolve skill file path - check multiple locations
  # Skills use Agent Skills Standard format: skills/skill-name/SKILL.md
  SKILL_FILE=""
  SKILL_LOCATIONS=(
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
      '{dry_run: true, wrapper: "cursor.sh", mode: "skill", skill: $skill, skill_file: $file, validation: "passed", note: "beta_support"}'
    exit 0
  fi

  # Invoke cursor-agent with skill prompt
  TMPFILE_OUTPUT="$(mktemp)"
  TMPFILE_ERR="$(mktemp)"

  # Determine working directory
  WORK_DIR=""
  if [[ -n "$CONTEXT_DIR" && -d "$CONTEXT_DIR" ]]; then
    WORK_DIR="$CONTEXT_DIR"
  elif [[ -d "$CORE_DIR/tenants/oxygen" ]]; then
    WORK_DIR="$CORE_DIR/tenants/oxygen"
  fi

  # Build cursor-agent args
  CURSOR_ARGS=(
    "--print"
    "--output-format" "text"
  )
  if [[ -n "$WORK_DIR" ]]; then
    CURSOR_ARGS+=("--workspace" "$WORK_DIR")
  fi
  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi

  log_verbose "Invoking cursor-agent CLI for skill (WorkDir: ${WORK_DIR:-none})"

  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    run_with_timeout "$CLI_TIMEOUT" cursor-agent "${CURSOR_ARGS[@]}" "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  else
    cursor-agent "${CURSOR_ARGS[@]}" "$SKILL_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
  fi
  CURSOR_EXIT=$?
  set -e

  if [[ $CURSOR_EXIT -ne 0 ]]; then
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"
    jq -n --arg err "$ERROR_MSG" --arg skill "$SKILL_NAME" '{error: $err, skill: $skill}'
    exit 1
  fi

  RESPONSE_TEXT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
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

  # Cursor CLI doesn't accept temperature directly; log for visibility
  if [[ -n "$TEMPERATURE" ]]; then
    log_verbose "Temperature specified but ignored by cursor-agent: $TEMPERATURE"
  fi

  WORKSPACE_DIR="$CORE_DIR"
  if [[ -n "$TENANT_DIR" ]]; then
    WORKSPACE_DIR="$TENANT_DIR"
  fi
  log_verbose "Invoking cursor-agent CLI (Workspace: ${WORKSPACE_DIR}, YOLO: $YOLO_MODE)"
  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    MCP_CONFIG_PATH="$(get_cursor_mcp_config || true)"
    if [[ -n "$MCP_CONFIG_PATH" ]]; then
      ensure_cursor_mcp_config "$WORKSPACE_DIR" "$MCP_CONFIG_PATH"
    fi
  fi

  # Build cursor-agent args
  # Use JSON format to capture session_id from response (like claude.sh)
  CURSOR_ARGS=(
    "--print"
    "--output-format" "json"
    "--workspace" "$WORKSPACE_DIR"
  )

  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi

  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    CURSOR_ARGS+=("--approve-mcps")
  fi

  # Add session args for session resume
  CURSOR_SESSION_ID=""
  if [[ -n "$SESSION_ID" ]]; then
    # Pass session ID directly - cursor-agent will error if invalid
    CURSOR_SESSION_ID="$SESSION_ID"
    CURSOR_ARGS+=("--resume" "$SESSION_ID")
    log_verbose "Resuming session: $SESSION_ID"
  fi

  # Run cursor-agent in non-interactive mode (prompt passed as argument)
  CURSOR_PROMPT="$(cat "$TMPFILE_PROMPT")"
  set +e
  if [[ -n "$CLI_TIMEOUT" && "$CLI_TIMEOUT" -gt 0 ]]; then
    log_verbose "Running cursor-agent with timeout: ${CLI_TIMEOUT}s"
    run_with_timeout "$CLI_TIMEOUT" cursor-agent "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    CURSOR_EXIT=$?
  else
    cursor-agent "${CURSOR_ARGS[@]}" "$CURSOR_PROMPT" 2> "$TMPFILE_ERR" > "$TMPFILE_OUTPUT"
    CURSOR_EXIT=$?
  fi
  set -e

  rm -f "$TMPFILE_PROMPT"

  if [[ $CURSOR_EXIT -ne 0 ]]; then
    # Cursor failed - return error with stderr
    ERROR_MSG=$(cat "$TMPFILE_ERR" 2>/dev/null || echo "Unknown error")
    log_verbose "Cursor execution failed: $ERROR_MSG"

    # Check if this is an invalid session error - fail fast, don't retry
    if echo "$ERROR_MSG" | grep -qi "Invalid session identifier\|session.*not found\|session.*expired"; then
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
    jq -n --arg err "$ERROR_MSG" '{error: $err}'
    exit 1
  fi

  # Read the output (JSON format from cursor-agent)
  RAW_OUTPUT="$(cat "$TMPFILE_OUTPUT" 2>/dev/null)"
  rm -f "$TMPFILE_OUTPUT" "$TMPFILE_ERR"

  if [[ -n "$RAW_OUTPUT" ]]; then
    # JSON format: Extract session_id and result from cursor-agent response
    # cursor-agent returns: {"type":"result","result":"...","session_id":"..."}
    CURSOR_SESSION_ID="$(echo "$RAW_OUTPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    RESPONSE_TEXT="$(echo "$RAW_OUTPUT" | jq -r '.result // empty' 2>/dev/null || true)"

    # Check for error response
    IS_ERROR="$(echo "$RAW_OUTPUT" | jq -r '.is_error // false' 2>/dev/null || true)"
    if [[ "$IS_ERROR" == "true" ]]; then
      ERROR_MSG="$(echo "$RAW_OUTPUT" | jq -r '.result // "Unknown error"' 2>/dev/null || true)"
      jq -n --arg err "$ERROR_MSG" '{error: $err}'
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

      # Wrap in CLIResponse format for Go worker (include session_id)
      if [[ -n "$CURSOR_SESSION_ID" ]]; then
        jq -n --arg resp "$RESPONSE_TEXT" --arg sid "$CURSOR_SESSION_ID" '{response: $resp, session_id: $sid}'
      else
        jq -n --arg resp "$RESPONSE_TEXT" '{response: $resp}'
      fi
    else
      # No result field - try raw response as fallback
      jq -n --arg text "$RAW_OUTPUT" '{error:"No result in response", raw_response:$text}'
    fi
  else
    jq -n '{error:"No response from Cursor CLI"}'
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

  WORKSPACE_DIR="$CORE_DIR"
  if [[ -n "$TENANT_DIR" ]]; then
    WORKSPACE_DIR="$TENANT_DIR"
  fi

  # Build cursor-agent args
  CURSOR_ARGS=(
    "--print"
    "--output-format" "text"
    "--workspace" "$WORKSPACE_DIR"
  )

  if [[ "$YOLO_MODE" == "true" ]]; then
    CURSOR_ARGS+=("--force")
  fi

  if [[ "$ALLOW_TOOLS" == "true" ]]; then
    CURSOR_ARGS+=("--approve-mcps")
  fi

  log_verbose "Running in direct invocation mode"
  cursor-agent "${CURSOR_ARGS[@]}" "$@"
fi
