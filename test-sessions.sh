#!/usr/bin/env bash
# Session Integration Test for AI CLI Wrappers
# Tests session creation and resume across all providers
#
# Usage: ./test-sessions.sh [provider...]
# Examples:
#   ./test-sessions.sh              # Test all providers
#   ./test-sessions.sh gemini       # Test only gemini
#   ./test-sessions.sh claude codex # Test claude and codex

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test timeout per provider (seconds)
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# Providers to test
ALL_PROVIDERS=(claude codex gemini opencode cursor)

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Test session create and resume for a single provider
test_provider_session() {
  local provider="$1"
  local wrapper="${SCRIPT_DIR}/${provider}.sh"
  local test_agent="${SCRIPT_DIR}/test-agent.md"

  if [[ ! -x "$wrapper" ]]; then
    log_fail "$provider: wrapper not found or not executable: $wrapper"
    return 1
  fi

  if [[ ! -f "$test_agent" ]]; then
    log_fail "$provider: test agent not found: $test_agent"
    return 1
  fi

  # Generate random number for this test
  local random_num=$((RANDOM * RANDOM))
  log_info "$provider: Testing with random number: $random_num"

  # Step 1: Create session and store the number (use agent mode for session capture)
  log_info "$provider: Creating session and storing number..."
  local create_output=""
  local create_exit=0

  create_output=$("$wrapper" --timeout "$TEST_TIMEOUT" \
    "$test_agent" --persona test-agent \
    "{\"instruction\": \"Remember this number exactly: $random_num\", \"expected_response\": {\"stored_number\": $random_num, \"status\": \"stored\"}}" 2>&1) || create_exit=$?

  if [[ $create_exit -ne 0 ]]; then
    log_fail "$provider: Session creation failed (exit: $create_exit)"
    echo "Output: $create_output" | head -20
    return 1
  fi

  # Extract session_id from response
  local session_id=""
  session_id=$(echo "$create_output" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | tail -1)

  if [[ -z "$session_id" ]]; then
    # Try alternate extraction for providers that output session_id differently
    session_id=$(echo "$create_output" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi

  if [[ -z "$session_id" ]]; then
    log_fail "$provider: Could not extract session_id from response"
    echo "Response: $create_output" | head -20
    return 1
  fi

  log_info "$provider: Session created: $session_id"

  # Verify stored_number in response
  local stored_check=""
  stored_check=$(echo "$create_output" | grep -o "$random_num" | head -1 || true)
  if [[ -z "$stored_check" ]]; then
    log_warn "$provider: Number not confirmed in create response (may still work)"
  fi

  # Step 2: Resume session and ask for the number back
  log_info "$provider: Resuming session and retrieving number..."
  local resume_output=""
  local resume_exit=0

  resume_output=$("$wrapper" --timeout "$TEST_TIMEOUT" \
    --resume "$session_id" \
    "$test_agent" --persona test-agent \
    "{\"instruction\": \"What was the number I asked you to remember?\", \"expected_response\": {\"recalled_number\": \"<the number>\"}}" 2>&1) || resume_exit=$?

  if [[ $resume_exit -ne 0 ]]; then
    log_fail "$provider: Session resume failed (exit: $resume_exit)"
    echo "Output: $resume_output" | head -20
    return 1
  fi

  # Verify the session_id is the same
  local resumed_session_id=""
  resumed_session_id=$(echo "$resume_output" | jq -r '.session_id // empty' 2>/dev/null || true)
  if [[ -z "$resumed_session_id" ]]; then
    resumed_session_id=$(echo "$resume_output" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | tail -1)
  fi

  if [[ "$resumed_session_id" != "$session_id" ]]; then
    log_warn "$provider: Session ID mismatch (expected: $session_id, got: $resumed_session_id)"
  fi

  # Primary check: Session ID mechanics work (ID captured and preserved on resume)
  if [[ -n "$session_id" && -n "$resumed_session_id" && "$resumed_session_id" == "$session_id" ]]; then
    log_success "$provider: Session mechanics PASSED - ID captured and preserved: $session_id"

    # Secondary check: LLM context preservation (bonus, not required)
    if echo "$resume_output" | grep -q "$random_num"; then
      log_success "$provider: Context preservation PASSED - number $random_num correctly recalled"
    else
      log_warn "$provider: Context not preserved (LLM didn't recall number) - this is provider-dependent"
    fi
    return 0
  else
    log_fail "$provider: Session mechanics FAILED"
    echo "  Created session: $session_id"
    echo "  Resumed session: $resumed_session_id"
    echo "Response: $resume_output" | head -30
    return 1
  fi
}

# Main test runner
main() {
  local providers_to_test=()

  # Parse arguments or default to all providers
  if [[ $# -gt 0 ]]; then
    providers_to_test=("$@")
  else
    providers_to_test=("${ALL_PROVIDERS[@]}")
  fi

  echo "========================================"
  echo "AI CLI Wrappers - Session Integration Test"
  echo "========================================"
  echo "Timeout per test: ${TEST_TIMEOUT}s"
  echo "Testing providers: ${providers_to_test[*]}"
  echo "========================================"
  echo ""

  local passed=0
  local failed=0
  local skipped=0
  local results=()

  for provider in "${providers_to_test[@]}"; do
    echo "----------------------------------------"
    log_info "Testing: $provider"
    echo "----------------------------------------"

    # Check if provider CLI is available
    local cli_cmd=""
    case "$provider" in
      claude) cli_cmd="claude" ;;
      codex) cli_cmd="codex" ;;
      gemini) cli_cmd="gemini" ;;
      opencode) cli_cmd="opencode" ;;
      cursor) cli_cmd="cursor-agent" ;;
    esac

    if ! command -v "$cli_cmd" &>/dev/null; then
      log_warn "$provider: CLI '$cli_cmd' not found, skipping"
      results+=("$provider: SKIPPED (CLI not found)")
      skipped=$((skipped + 1))
      continue
    fi

    if test_provider_session "$provider"; then
      results+=("$provider: PASSED")
      passed=$((passed + 1))
    else
      results+=("$provider: FAILED")
      failed=$((failed + 1))
    fi

    echo ""
  done

  # Summary
  echo "========================================"
  echo "SUMMARY"
  echo "========================================"
  for result in "${results[@]}"; do
    if [[ "$result" == *"PASSED"* ]]; then
      echo -e "${GREEN}✓${NC} $result"
    elif [[ "$result" == *"FAILED"* ]]; then
      echo -e "${RED}✗${NC} $result"
    else
      echo -e "${YELLOW}○${NC} $result"
    fi
  done
  echo "----------------------------------------"
  echo -e "Passed: ${GREEN}$passed${NC} | Failed: ${RED}$failed${NC} | Skipped: ${YELLOW}$skipped${NC}"
  echo "========================================"

  # Exit with failure if any tests failed
  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
