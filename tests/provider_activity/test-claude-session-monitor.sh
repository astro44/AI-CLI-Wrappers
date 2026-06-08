#!/usr/bin/env bash
# Regression test: Claude live activity capture via on-disk session transcript.
#
# Why this exists: claude.sh runs `claude --print --output-format json`, which
# emits nothing incremental to stdout/stderr during a call. The provider-activity
# monitor therefore has no stderr to classify, and for a long stretch Claude only
# ever wrote monitor_start + monitor_stop to its activity JSONL — so the worker's
# no-activity watchdog SIGTERMed working calls (exit 143) and churned fallbacks.
#
# The fix tails Claude's transcript (~/.claude/projects/**/<session>.jsonl), the
# same on-disk-session pattern proven for codex/cursor. check-wrapper-parity.sh
# only diffs function bodies core-vs-wrapper; it structurally cannot detect that
# Claude under-emits activity. This behavioral test fills that gap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER_DIR="$ROOT_DIR/bin"
if [[ ! -f "$WRAPPER_DIR/lib/live-monitor.sh" && -f "$SCRIPT_DIR/../../lib/live-monitor.sh" ]]; then
  WRAPPER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
LIB="$WRAPPER_DIR/lib/live-monitor.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$LIB" ]] || fail "live-monitor.sh not found at $LIB"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

# shellcheck source=/dev/null
source "$LIB"
echo "Testing: $LIB"

# ── 1. Classifier maps Claude content blocks to activity event classes ───────
OUT="$(mktemp)"
read -r -d '' FIX <<'JSONL' || true
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"s"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
{"type":"system","content":"plain system line, no message.content array"}
{"type":"file-history-snapshot","messageId":"x"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"},{"type":"tool_use","name":"Bash","input":{}}]}}
JSONL

_autonom8_classify_claude_session "$FIX" "req-test" "$OUT"
count() { jq -r "select(.event_class==\"$1\")|.event_class" "$OUT" | wc -l | tr -d ' '; }
[[ "$(count reasoning)" == "1" ]]            || fail "reasoning: got $(count reasoning) want 1"
[[ "$(count function_call)" == "2" ]]        || fail "function_call: got $(count function_call) want 2"
[[ "$(count function_call_output)" == "1" ]] || fail "function_call_output: got $(count function_call_output) want 1"
[[ "$(count agent_message)" == "2" ]]        || fail "agent_message: got $(count agent_message) want 2"
jq -r 'select(.event_class=="function_call")|.detail' "$OUT" | grep -q 'name=Read' || fail "missing tool name Read"
jq -r 'select(.event_class=="function_call")|.detail' "$OUT" | grep -q 'name=Bash' || fail "missing tool name Bash"
# system / file-history-snapshot lines (no .message.content array) must not emit
[[ "$(jq -r '.event_class' "$OUT" | grep -c .)" == "6" ]] || fail "non-message lines were not skipped"
rm -f "$OUT"
echo "PASS: classifier maps thinking/tool_use/tool_result/text and skips non-message lines"

# ── 2. Discoverer picks fresh transcript, ignores stale ──────────────────────
T1="$(mktemp -d)"; mkdir -p "$T1/-encoded-cwd"
START="$(date +%s)"; sleep 1
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}' > "$T1/-encoded-cwd/$(date +%s)-live.jsonl"
FOUND="$(_autonom8_discover_claude_session "$T1" "$START")"
[[ -n "$FOUND" && -f "$FOUND" ]] || fail "discover did not find fresh transcript (got '$FOUND')"
T2="$(mktemp -d)"; mkdir -p "$T2/p"; touch -t 202001010000.00 "$T2/p/old.jsonl"
OLD="$(_autonom8_discover_claude_session "$T2" "$(date +%s)")"
[[ -z "$OLD" ]] || fail "discover picked stale transcript '$OLD'"
rm -rf "$T1" "$T2"
echo "PASS: discoverer selects fresh-after-start, ignores stale"

# ── 3. End-to-end: background monitor emits live activity (not start/stop-only) ─
export AUTONOM8_LIVE_MONITOR_INTERVAL_SEC=1
WORK="$(mktemp -d)"; SESS="$(mktemp -d)"; mkdir -p "$SESS/-encoded-cwd"
STDERR="$(mktemp)"   # claude --print json keeps this empty (the original bug)
REQ="int-$$"
autonom8_start_live_monitor "claude" "$REQ" "$STDERR" "$WORK" "$SESS"
ACT="$WORK/.autonom8/provider_activity/${REQ}.jsonl"
SFILE="$SESS/-encoded-cwd/$(date +%s)-live.jsonl"
sleep 1; echo '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"","signature":"s"}]}}' >> "$SFILE"
sleep 1; echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}'    >> "$SFILE"
sleep 1; echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"done"}]}}'             >> "$SFILE"
sleep 1; echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}'    >> "$SFILE"
sleep 2
autonom8_stop_live_monitor "claude" "$REQ"; sleep 1
[[ -f "$ACT" ]] || fail "no activity file written"
strong="$(jq -r 'select(.event_class|test("function_call|function_call_output|agent_message|stdout_activity"))|.event_class' "$ACT" | wc -l | tr -d ' ')"
reasoning="$(jq -r 'select(.event_class=="reasoning")|.event_class' "$ACT" | wc -l | tr -d ' ')"
nonmarker="$(jq -r 'select(.event_class|test("monitor_")|not)|.event_class' "$ACT" | wc -l | tr -d ' ')"
rm -rf "$WORK" "$SESS" "$STDERR"
(( strong >= 3 && reasoning >= 1 && nonmarker >= 4 )) || \
  fail "monitor emitted start/stop-only (strong=$strong reasoning=$reasoning nonmarker=$nonmarker)"
echo "PASS: background monitor captured live activity (strong=$strong reasoning=$reasoning)"

echo "ALL TESTS PASSED"
