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

  echo "[PASS] tool telemetry reasoning_capture wiring"
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
    (.metadata.reasoning_capture | has("schema_version") and has("available") and has("source") and has("absent_reason") and has("captured_chars") and has("response_chars") and has("diagnostic_only") and has("not_required_for_acceptance") and has("quality_gate_role") and has("methods_attempted")) and
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
  assert_wrapper_contract_wiring "$WRAPPER_DIR/claude.sh" "claude"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/cursor.sh" "cursor"
  assert_wrapper_contract_wiring "$WRAPPER_DIR/opencode.sh" "opencode"
  assert_wrapper_session_wiring "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_session_wiring "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/claude.sh" "claude"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/gemini.sh" "gemini"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/codex.sh" "codex"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/cursor.sh" "cursor"
  assert_wrapper_skill_lookup_order "$WRAPPER_DIR/opencode.sh" "opencode"
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
