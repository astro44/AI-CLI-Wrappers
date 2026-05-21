#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER_DIR="$ROOT_DIR/bin"
if [[ ! -f "$WRAPPER_DIR/claude.sh" && -f "$SCRIPT_DIR/../../claude.sh" ]]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  WRAPPER_DIR="$ROOT_DIR"
fi
LIB_DIR="$WRAPPER_DIR/lib"

PROVIDERS=(codex claude gemini cursor opencode)
MODE="static"
STRICT=false
TIMEOUT=90

usage() {
  cat <<EOF
Usage: $0 [--live] [--strict] [--timeout N] [--providers LIST]

Modes:
  (default) static   Validate wrapper syntax and contract wiring only.
  --live             Execute all provider wrappers and verify JSON envelope.

Options:
  --strict           In live mode, fail if any provider call fails.
  --timeout N        Wrapper timeout seconds for live mode (default: 90).
  --providers LIST   Comma-separated provider order override.
                     Example: codex,claude,gemini,cursor,opencode
  -h, --help         Show this help.

Examples:
  $0
  $0 --live
  $0 --live --providers codex,claude,gemini,cursor,opencode
  $0 --live --strict --timeout 120
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)
      MODE="live"
      shift
      ;;
    --strict)
      STRICT=true
      shift
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    --providers)
      IFS=',' read -r -a PROVIDERS <<< "${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

validate_provider_list() {
  local valid=(claude gemini codex cursor opencode)
  local p
  for p in "${PROVIDERS[@]}"; do
    if [[ ! " ${valid[*]} " =~ " ${p} " ]]; then
      echo "Unsupported provider in --providers: $p" >&2
      exit 1
    fi
  done
}

require_cmd jq

assert_wrapper_contract_wiring() {
  local file="$1"
  local name="$2"

  bash -n "$file"
  grep -q "emit_cli_response()" "$file"
  grep -q "emit_cli_error_response()" "$file"
  grep -q "tokens_used" "$file"
  grep -q "estimated_output_tokens" "$file"
  grep -q "cache_read_input_tokens" "$file"
  grep -q "cache_creation_input_tokens" "$file"
  grep -q "reasoning_available" "$file"
  grep -q "token_usage_available" "$file"
  grep -q "reasoning_source" "$file"
  grep -q "reasoning_absent_reason" "$file"

  echo "[PASS] $name static contract wiring"
}

assert_gemini_capacity_fast_fail_wiring() {
  local file="$1"

  bash -n "$file"
  grep -q "gemini_capacity_fast_fail_pattern()" "$file"
  grep -q "AUTONOM8_WRAPPER_FAST_FAIL_FILE" "$file"
  grep -q "AUTONOM8_WRAPPER_FAST_FAIL_PATTERN" "$file"
  grep -q "wrapper_fast_fail" "$file"
  grep -q "MODEL_CAPACITY_EXHAUSTED" "$file"
  grep -q "No capacity available for model" "$file"
  grep -q "Gemini capacity exhausted after fallback" "$file"

  echo "[PASS] gemini capacity fast-fail wiring"
}

assert_wrapper_go_timeout_supervision_wiring() {
  local file="$1"
  local name="$2"

  bash -n "$file"
  grep -q "AUTONOM8_WRAPPER_TIMEOUT_SUPERVISION" "$file"
  grep -q '"${AUTONOM8_WRAPPER_TIMEOUT_SUPERVISION:-}" == "go"' "$file"

  echo "[PASS] $name Go timeout-supervision wiring"
}

assert_tool_telemetry_contract_wiring() {
  local file="$1"

  bash -n "$file"
  grep -q "autonom8_enrich_provider_payload_json()" "$file"
  grep -q "reasoning_capture_summary" "$file"
  grep -q "reasoning_capture" "$file"
  grep -q "diagnostic_only" "$file"
  grep -q "not_required_for_acceptance" "$file"
  grep -q "quality_gate_role" "$file"
  grep -q "methods_attempted" "$file"
  grep -q "operational_reasoning_summary" "$file"
  grep -q "operational_summary_available" "$file"
  grep -q "autonom8_persist_tool_activity_json" "$file"
  grep -q "commands_run_count" "$file"
  grep -q "private_reasoning_available" "$file"
  grep -q "wrapper_timeout_supervision" "$file"
  grep -q "cursor_tool_call_name" "$file"
  grep -q "editToolCall" "$file"
  grep -q "readToolCall" "$file"

  echo "[PASS] tool telemetry reasoning_capture wiring"
}

assert_cursor_tool_telemetry_fixture() {
  local fixture out edit_path multi_path read_path grep_path list_path search_path cmd1 cmd2 cmd3
  fixture="$(mktemp)"
  out="$(mktemp)"
  edit_path="/tmp/autonom8-cursor-telemetry-fixture/src/cursor-proof.js"
  multi_path="/tmp/autonom8-cursor-telemetry-fixture/src/cursor-multi.js"
  read_path="/tmp/autonom8-cursor-telemetry-fixture/src/cursor-proof.js"
  grep_path="/tmp/autonom8-cursor-telemetry-fixture/src/grep-target.js"
  list_path="/tmp/autonom8-cursor-telemetry-fixture/src/index.js"
  search_path="/tmp/autonom8-cursor-telemetry-fixture/tests/search-target.spec.js"
  cmd1="npm test -- --runInBand"
  cmd2="go test ./sprint/sprint_execution"
  cmd3="python3 -m pytest tests/unit"

  cat > "$fixture" <<JSONL
{"type":"tool_call","subtype":"completed","call_id":"tool-edit-1","tool_call":{"editToolCall":{"args":{"path":"$edit_path","streamContent":"export const ok = true;"},"result":{"success":{"path":"$edit_path","linesAdded":1}}}},"timestamp_ms":1779323717008}
{"type":"tool_call","subtype":"completed","call_id":"tool-multi-1","tool_call":{"multiEditToolCall":{"args":{"edits":[{"path":"$multi_path","oldText":"before","newText":"after"}]},"result":{"success":{"path":"$multi_path","editsApplied":1}}}},"timestamp_ms":1779323717162}
{"type":"tool_call","subtype":"completed","call_id":"tool-read-1","tool_call":{"readToolCall":{"args":{"path":"$read_path"},"result":{"success":{"path":"$read_path","content":"export const ok = true;"}}}},"timestamp_ms":1779323718524}
{"type":"tool_call","subtype":"completed","call_id":"tool-grep-1","tool_call":{"grepToolCall":{"args":{"path":"$grep_path","pattern":"cursorProof"},"result":{"success":{"path":"$grep_path","matches":1}}}},"timestamp_ms":1779323718574}
{"type":"tool_call","subtype":"completed","call_id":"tool-list-1","tool_call":{"listDirToolCall":{"args":{"path":"$list_path"},"result":{"success":{"path":"$list_path","entries":["cursor-proof.js"]}}}},"timestamp_ms":1779323718624}
{"type":"tool_call","subtype":"completed","call_id":"tool-search-1","tool_call":{"searchToolCall":{"args":{"path":"$search_path","query":"cursor proof"},"result":{"success":{"path":"$search_path","matches":1}}}},"timestamp_ms":1779323718674}
{"type":"tool_call","subtype":"completed","call_id":"tool-terminal-1","tool_call":{"terminalToolCall":{"args":{"command":"$cmd1"},"result":{"success":{"exitCode":0}}}},"timestamp_ms":1779323718724}
{"type":"tool_call","subtype":"completed","call_id":"tool-runcommand-1","tool_call":{"runCommandToolCall":{"args":{"cmd":"$cmd2"},"result":{"success":{"exitCode":0}}}},"timestamp_ms":1779323718774}
{"type":"tool_call","subtype":"completed","call_id":"tool-shell-1","tool_call":{"shellToolCall":{"args":{"shell_command":"$cmd3"},"result":{"success":{"exitCode":0}}}},"timestamp_ms":1779323718824}
JSONL

  # shellcheck disable=SC1090
  source "$LIB_DIR/tool-telemetry.sh"
  autonom8_tool_activity_json "$(cat "$fixture")" "" "fixture:cursor" > "$out"

  if ! jq -e \
    --arg edit "$edit_path" \
    --arg multi "$multi_path" \
    --arg read "$read_path" \
    --arg grep "$grep_path" \
    --arg list "$list_path" \
    --arg search "$search_path" \
    --arg cmd1 "$cmd1" \
    --arg cmd2 "$cmd2" \
    --arg cmd3 "$cmd3" '
    .call_count == 9 and
    .write_count == 2 and
    .read_count == 4 and
    .command_count == 3 and
    .tool_write_count == 2 and
    .tool_read_count == 4 and
    .commands_run_count == 3 and
    .activity_class == "write_active" and
    (.tool_names | index("editToolCall")) and
    (.tool_names | index("multiEditToolCall")) and
    (.tool_names | index("readToolCall")) and
    (.tool_names | index("grepToolCall")) and
    (.tool_names | index("listDirToolCall")) and
    (.tool_names | index("searchToolCall")) and
    (.tool_names | index("terminalToolCall")) and
    (.tool_names | index("runCommandToolCall")) and
    (.tool_names | index("shellToolCall")) and
    (.result_classes | index("write")) and
    (.result_classes | index("read")) and
    (.result_classes | index("shell")) and
    (.files_changed | index($edit)) and
    (.files_changed | index($multi)) and
    (.files_read | index($read)) and
    (.files_read | index($grep)) and
    (.files_read | index($list)) and
    (.files_read | index($search)) and
    (.commands_run | index($cmd1)) and
    (.commands_run | index($cmd2)) and
    (.commands_run | index($cmd3))
  ' "$out" >/dev/null; then
    echo "[FAIL] cursor tool telemetry fixture did not detect Cursor tool-call matrix"
    cat "$out"
    rm -f "$fixture" "$out"
    return 1
  fi

  rm -f "$fixture" "$out"
  echo "[PASS] cursor tool telemetry fixture"
}

assert_generic_tool_telemetry_fixture() {
  local fixture out file_path cmd
  fixture="$(mktemp)"
  out="$(mktemp)"
  file_path="src/generic-tool-proof.go"
  cmd="go test ./..."

  cat > "$fixture" <<JSONL
{"type":"tool_call","name":"apply_patch","input":{"file_path":"$file_path"},"timestamp":"2026-05-21T00:00:00Z"}
{"type":"function_call","function":{"name":"Read"},"input":{"path":"$file_path"},"timestamp":"2026-05-21T00:00:01Z"}
{"toolCalls":[{"name":"Bash","input":{"command":"$cmd"}}],"timestamp":"2026-05-21T00:00:02Z"}
JSONL

  # shellcheck disable=SC1090
  source "$LIB_DIR/tool-telemetry.sh"
  autonom8_tool_activity_json "$(cat "$fixture")" "" "fixture:generic" > "$out"

  if ! jq -e --arg file "$file_path" --arg cmd "$cmd" '
    .call_count == 3 and
    .write_count == 1 and
    .read_count == 1 and
    .command_count == 1 and
    .activity_class == "write_active" and
    (.tool_names | index("apply_patch")) and
    (.tool_names | index("Read")) and
    (.tool_names | index("Bash")) and
    (.result_classes | index("write")) and
    (.result_classes | index("read")) and
    (.result_classes | index("shell")) and
    (.files_changed | index($file)) and
    (.files_read | index($file)) and
    (.commands_run | index($cmd))
  ' "$out" >/dev/null; then
    echo "[FAIL] generic tool telemetry fixture did not detect common tool-call shapes"
    cat "$out"
    rm -f "$fixture" "$out"
    return 1
  fi

  rm -f "$fixture" "$out"
  echo "[PASS] generic tool telemetry fixture"
}

assert_claude_operational_summary_fixture() {
  local tmp_home session_id session_dir session_file out_file abs_file secret_cmd
  tmp_home="$(mktemp -d)"
  session_id="00000000-0000-4000-8000-000000000001"
  session_dir="$tmp_home/.claude/projects/-tmp-autonom8-operational-summary"
  session_file="$session_dir/${session_id}.jsonl"
  out_file="$(mktemp)"
  abs_file="$PWD/src/components/impact/map.js"
  secret_cmd='ANTHROPIC_API_KEY=sk-testfixture-secret123456 go test ./runtime/climanager'

  mkdir -p "$session_dir"
  jq -cn '{type:"assistant",message:{content:[{type:"text",text:"Inspect the impact dashboard runtime contract and patch the map initialization path."}]}}' >> "$session_file"
  jq -cn --arg file "$abs_file" '{type:"assistant",message:{content:[{type:"tool_use",name:"Read",input:{file_path:$file}}]}}' >> "$session_file"
  jq -cn --arg file "$abs_file" '{type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$file}}]}}' >> "$session_file"
  jq -cn --arg command "$secret_cmd" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$command}}]}}' >> "$session_file"
  jq -cn '{type:"user",message:{content:[{type:"tool_result",is_error:true,content:"selector not found: data-favela-map-initialized"}]}}' >> "$session_file"
  jq -cn '{type:"assistant",message:{content:[{type:"thinking",signature:"signed-redacted-fixture"}]}}' >> "$session_file"
  jq -cn '{type:"assistant",message:{content:[{type:"text",text:"Patched map initialization and verified the focused runtime contract."}]}}' >> "$session_file"

  if ! HOME="$tmp_home" AUTONOM8_WRAPPER_UNIT_TEST=claude_operational_summary "$WRAPPER_DIR/claude.sh" "$session_id" > "$out_file"; then
    echo "[FAIL] claude operational summary fixture invocation failed"
    cat "$out_file" || true
    rm -rf "$tmp_home" "$out_file"
    return 1
  fi

  if ! jq -e --arg file "src/components/impact/map.js" --arg command_fragment "go test ./runtime/climanager" '
    .source == "claude_session_jsonl" and
    (.intent | contains("impact dashboard runtime contract")) and
    (.files_read | index($file)) and
    (.files_changed | index($file)) and
    (.commands_run | map(contains($command_fragment)) | any) and
    ((.commands_run | tostring | contains("sk-testfixture")) | not) and
    ((.commands_run | tostring | contains("ANTHROPIC_API_KEY")) | not) and
    (.verification | map(contains($command_fragment)) | any) and
    (.tool_write_count == 1) and
    (.signed_thinking_blocks == 1) and
    (.errors | map(contains("data-favela-map-initialized")) | any) and
    (.final_summary | contains("Patched map initialization"))
  ' "$out_file" >/dev/null; then
    echo "[FAIL] claude operational summary fixture contract invalid"
    cat "$out_file"
    rm -rf "$tmp_home" "$out_file"
    return 1
  fi

  rm -rf "$tmp_home" "$out_file"
  echo "[PASS] claude operational summary fixture"
}

assert_wrapper_session_wiring() {
  local file="$1"
  local name="$2"

  case "$name" in
    codex)
      grep -Fq 'exec resume' "$file"
      grep -Fq 'DISCOVER_MANAGED_CODEX_SESSION=true' "$file"
      if grep -Fq 'CODEX_SESSION_ID="$MANAGE_SESSION"' "$file"; then
        echo "[FAIL] codex wrapper still persists MANAGE_SESSION as provider session id"
        return 1
      fi
      ;;
    gemini)
      grep -Fq 'GEMINI_CMD=(gemini)' "$file"
      grep -Fq 'GEMINI_CMD+=("--resume" "$GEMINI_SESSION_ID")' "$file"
      grep -Fq '"${GEMINI_CMD[@]}"' "$file"
      if grep -Fq 'GEMINI_SESSION_ID="$MANAGE_SESSION"' "$file"; then
        echo "[FAIL] gemini wrapper still persists MANAGE_SESSION as provider session id"
        return 1
      fi
      ;;
  esac

  echo "[PASS] $name static session wiring"
}

assert_wrapper_skill_lookup_order() {
  local file="$1"
  local name="$2"

  local canonical claude codex cursor gemini opencode legacy
  canonical="$(grep -nF '"$CORE_DIR/modules/Autonom8-Agents/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  claude="$(grep -nF '"$CORE_DIR/.claude/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  codex="$(grep -nF '"$CORE_DIR/.codex/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  cursor="$(grep -nF '"$CORE_DIR/.cursor/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  gemini="$(grep -nF '"$CORE_DIR/.gemini/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  opencode="$(grep -nF '"$CORE_DIR/modules/Autonom8-Agents/.opencode/skills/${SKILL_NAME}/SKILL.md"' "$file" | head -1 | cut -d: -f1)"
  legacy="$(grep -nF '"$CORE_DIR/.claude/commands/${SKILL_NAME}.md"' "$file" | head -1 | cut -d: -f1)"

  if [[ -z "$canonical" || -z "$claude" || -z "$codex" || -z "$cursor" || -z "$gemini" || -z "$opencode" || -z "$legacy" ]]; then
    echo "[FAIL] $name skill lookup paths missing"
    return 1
  fi

  if ! [[ "$canonical" -lt "$claude" && "$claude" -lt "$codex" && "$codex" -lt "$cursor" && "$cursor" -lt "$gemini" && "$gemini" -lt "$opencode" && "$opencode" -lt "$legacy" ]]; then
    echo "[FAIL] $name skill lookup order drifted"
    return 1
  fi

  echo "[PASS] $name static skill lookup order"
}

assert_response_contract_json() {
  local provider="$1"
  local json_file="$2"

  if ! jq -e '
    has("response") and
    has("reasoning") and
    has("tokens_used") and
    has("metadata") and
    (.tokens_used | has("input_tokens") and has("output_tokens") and has("estimated_output_tokens") and has("total_tokens") and has("cost_usd") and has("cache_read_input_tokens") and has("cache_creation_input_tokens")) and
    (.metadata | has("reasoning_available") and has("reasoning_source") and has("token_usage_available") and has("reasoning_absent_reason")) and
    (.metadata | has("reasoning_capture")) and
    (.metadata | has("operational_reasoning_summary")) and
    (.metadata.reasoning_capture | has("schema_version") and has("available") and has("private_reasoning_available") and has("source") and has("absent_reason") and has("captured_chars") and has("response_chars") and has("operational_summary_available") and has("operational_summary_source") and has("diagnostic_only") and has("not_required_for_acceptance") and has("quality_gate_role") and has("methods_attempted")) and
    (.metadata.operational_reasoning_summary | has("intent") and has("files_read") and has("files_changed") and has("commands_run") and has("tool_write_count") and has("errors") and has("verification") and has("final_summary") and has("source") and has("signed_thinking_blocks")) and
    ((.metadata.tool_activity? // {}) | ((has("commands_run_count") and has("files_changed") and has("files_read")) or (length == 0))) and
    (.metadata.reasoning_capture.diagnostic_only == true) and
    (.metadata.reasoning_capture.not_required_for_acceptance == true) and
    (.metadata.reasoning_capture.quality_gate_role == "observability_only") and
    (.metadata.reasoning_source | (. == "none" or . == "raw_output" or . == "response_payload" or . == "stream_log" or . == "session_log" or . == "session_assistant" or . == "derived_excerpt")) and
    (.metadata.reasoning_absent_reason | (. == "available" or . == "model_not_emitted" or . == "error_path")) and
    ((.metadata.reasoning_available == true and .metadata.reasoning_absent_reason == "available") or (.metadata.reasoning_available == false and .metadata.reasoning_absent_reason != "available")) and
    ((.tokens_used.input_tokens|type)=="number") and
    ((.tokens_used.output_tokens|type)=="number") and
    ((.tokens_used.estimated_output_tokens|type)=="number") and
    ((.tokens_used.total_tokens|type)=="number") and
    ((.tokens_used.cost_usd|type)=="number") and
    ((.tokens_used.cache_read_input_tokens|type)=="number") and
    ((.tokens_used.cache_creation_input_tokens|type)=="number")
  ' "$json_file" >/dev/null; then
    echo "[FAIL] $provider contract keys/types invalid"
    echo "Output:"
    cat "$json_file"
    return 1
  fi

  local reasoning_available
  local reasoning_len
  local token_usage_available
  local estimated_output_tokens
  local response_len
  local reasoning_compact
  reasoning_available="$(jq -r '.metadata.reasoning_available' "$json_file")"
  reasoning_len="$(jq -r '.reasoning | length' "$json_file")"
  token_usage_available="$(jq -r '.metadata.token_usage_available' "$json_file")"
  estimated_output_tokens="$(jq -r '.tokens_used.estimated_output_tokens' "$json_file")"
  response_len="$(jq -r '.response | length' "$json_file")"
  reasoning_compact="$(jq -r '.reasoning // ""' "$json_file" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')"

  if [[ "$reasoning_available" == "true" ]]; then
    if [[ "${reasoning_len:-0}" -le 2 ]]; then
      echo "[FAIL] $provider reasoning marked available but length <= 2"
      echo "Reasoning: $reasoning_compact"
      return 1
    fi
    if printf "%s" "$reasoning_compact" | grep -Eq '^`{3,}[[:space:]]*(json|markdown|md|yaml|yml|text|txt)?[[:space:]]*`{0,3}$'; then
      echo "[FAIL] $provider reasoning marked available but payload is fence-only placeholder"
      echo "Reasoning: $reasoning_compact"
      return 1
    fi
  fi

  if [[ "${response_len:-0}" -gt 0 && "${estimated_output_tokens:-0}" -le 0 ]]; then
    echo "[FAIL] $provider response present but estimated_output_tokens <= 0"
    cat "$json_file"
    return 1
  fi

  echo "[PASS] $provider envelope reasoning_available=$reasoning_available reasoning_len=$reasoning_len token_usage_available=$token_usage_available estimated_output_tokens=$estimated_output_tokens"
}

run_static_checks() {
  echo "== Static Wrapper Contract Checks =="
  assert_tool_telemetry_contract_wiring "$LIB_DIR/tool-telemetry.sh"
  assert_cursor_tool_telemetry_fixture
  assert_generic_tool_telemetry_fixture
  assert_wrapper_contract_wiring "$WRAPPER_DIR/claude.sh" "claude"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/cursor.sh" "cursor"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/opencode.sh" "opencode"
  assert_wrapper_go_timeout_supervision_wiring "$WRAPPER_DIR/claude.sh" "claude"
  assert_wrapper_go_timeout_supervision_wiring "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_go_timeout_supervision_wiring "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_go_timeout_supervision_wiring "$WRAPPER_DIR/cursor.sh" "cursor"
  assert_wrapper_go_timeout_supervision_wiring "$WRAPPER_DIR/opencode.sh" "opencode"
  assert_gemini_capacity_fast_fail_wiring "$WRAPPER_DIR/gemini.sh"
  assert_wrapper_session_wiring "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_session_wiring "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/claude.sh" "claude"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/cursor.sh" "cursor"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/opencode.sh" "opencode"
  assert_claude_operational_summary_fixture
}

run_live_checks() {
  echo "== Live Wrapper Contract Checks =="

  local agent_file
  local prompt_file
  agent_file="$(mktemp -t a8-wrapper-agent)"
  agent_file="${agent_file}.md"
  : > "$agent_file"
  prompt_file="$(mktemp)"

  cat > "$agent_file" <<'MD'
## Persona: reasoning-claude
Return ONLY valid JSON with keys: summary, confidence.

## Persona: reasoning-gemini
Return ONLY valid JSON with keys: summary, confidence.

## Persona: reasoning-codex
Return ONLY valid JSON with keys: summary, confidence.

## Persona: reasoning-cursor
Return ONLY valid JSON with keys: summary, confidence.

## Persona: reasoning-opencode
Return ONLY valid JSON with keys: summary, confidence.
MD

  cat > "$prompt_file" <<'JSON'
{"task":"Summarize why a sprint ticket failed and provide one fix.","context":"wrapper contract verification"}
JSON

  local failed_contract=0
  local failed_exec=0

  for provider in "${PROVIDERS[@]}"; do
    local out_file err_file rc
    out_file="$(mktemp)"
    err_file="$(mktemp)"

    set +e
    cat "$prompt_file" | "$WRAPPER_DIR/${provider}.sh" \
      --persona "reasoning-${provider}" \
      --skip-context-file \
      --timeout "$TIMEOUT" \
      "$agent_file" \
      >"$out_file" 2>"$err_file"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
      if jq -e . "$out_file" >/dev/null 2>&1 && assert_response_contract_json "$provider" "$out_file"; then
        echo "[INFO] $provider returned contract-compliant envelope with non-zero rc=$rc"
        continue
      fi
      echo "[WARN] $provider execution failed (rc=$rc)"
      head -n 8 "$err_file" || true
      failed_exec=$((failed_exec + 1))
      if [[ "$STRICT" == true ]]; then
        failed_contract=$((failed_contract + 1))
      fi
      continue
    fi

    if ! assert_response_contract_json "$provider" "$out_file"; then
      failed_contract=$((failed_contract + 1))
    fi
  done

  if [[ $failed_exec -gt 0 && "$STRICT" == false ]]; then
    echo "[INFO] $failed_exec provider(s) were skipped due to execution failure (non-strict mode)."
  fi

  if [[ $failed_contract -gt 0 ]]; then
    echo "[FAIL] Wrapper contract checks failed: $failed_contract"
    exit 1
  fi
}

main() {
  validate_provider_list
  echo "Wrapper Contract Test: mode=$MODE strict=$STRICT timeout=${TIMEOUT}s"
  echo "Provider order: ${PROVIDERS[*]}"
  run_static_checks
  if [[ "$MODE" == "live" ]]; then
    run_live_checks
  fi
  echo "[PASS] Wrapper contract test completed"
}

main "$@"
