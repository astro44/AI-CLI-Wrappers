#!/usr/bin/env bash
# check-wrapper-parity.sh — Detects function-level drift between Autonom8-core/bin/ and AI-CLI-Wrappers/
#
# Usage: check-wrapper-parity.sh [--strict] [--fix-hint]
#   --strict    Exit 1 on any non-excepted drift
#   --fix-hint  Print which direction to sync
#
# Place in either repo root. Reads .parity-exceptions for allowed drift.

set -euo pipefail

CORE_DIR="${CORE_DIR:-/Users/astrix/repos/Autonom8-core/bin}"
WRAP_DIR="${WRAP_DIR:-/Users/astrix/repos/AI-CLI-Wrappers}"
EXCEPTIONS_FILE="${WRAP_DIR}/.parity-exceptions"

STRICT=false
FIX_HINT=false
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --fix-hint) FIX_HINT=true ;;
  esac
done

PARITY_WRAPPERS=(claude.sh codex.sh cursor.sh gemini.sh opencode.sh agravity.sh)
PARITY_LIBS=(lib/live-monitor.sh)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

drift_count=0
excepted_count=0
checked_count=0

is_excepted() {
  local file="$1" func="$2"
  [[ -f "$EXCEPTIONS_FILE" ]] || return 1
  grep -qE "^${file}\\s+${func}$" "$EXCEPTIONS_FILE" 2>/dev/null
}

extract_functions() {
  local file="$1"
  grep -n '^\([a-zA-Z_][a-zA-Z0-9_]*\)()' "$file" 2>/dev/null | sed 's/().*$//' | sed 's/^[0-9]*://' | sort -u
}

extract_function_body() {
  local file="$1" func="$2"
  awk -v fn="${func}()" '
    $0 ~ fn { found=1; depth=0 }
    found {
      depth += gsub(/{/, "{")
      depth -= gsub(/}/, "}")
      print
      if (found && depth <= 0 && NR > 1) exit
    }
  ' "$file" 2>/dev/null
}

compare_function() {
  local file_label="$1" core_file="$2" wrap_file="$3" func="$4"
  checked_count=$((checked_count + 1))

  local core_body wrap_body
  core_body="$(extract_function_body "$core_file" "$func")"
  wrap_body="$(extract_function_body "$wrap_file" "$func")"

  if [[ -z "$core_body" && -z "$wrap_body" ]]; then
    return 0
  fi

  if [[ -z "$core_body" ]]; then
    if is_excepted "$file_label" "$func"; then
      excepted_count=$((excepted_count + 1))
      return 0
    fi
    printf "${YELLOW}DRIFT${NC} %s::%s — exists in AI-CLI-Wrappers only\n" "$file_label" "$func"
    drift_count=$((drift_count + 1))
    return 0
  fi

  if [[ -z "$wrap_body" ]]; then
    if is_excepted "$file_label" "$func"; then
      excepted_count=$((excepted_count + 1))
      return 0
    fi
    printf "${YELLOW}DRIFT${NC} %s::%s — exists in core only\n" "$file_label" "$func"
    $FIX_HINT && printf "  → sync core→wrappers\n"
    drift_count=$((drift_count + 1))
    return 0
  fi

  local core_hash wrap_hash
  core_hash="$(printf "%s" "$core_body" | shasum -a 256 | cut -d' ' -f1)"
  wrap_hash="$(printf "%s" "$wrap_body" | shasum -a 256 | cut -d' ' -f1)"

  if [[ "$core_hash" != "$wrap_hash" ]]; then
    if is_excepted "$file_label" "$func"; then
      excepted_count=$((excepted_count + 1))
      return 0
    fi
    local core_lines wrap_lines
    core_lines="$(printf "%s" "$core_body" | wc -l | tr -d ' ')"
    wrap_lines="$(printf "%s" "$wrap_body" | wc -l | tr -d ' ')"
    printf "${RED}DRIFT${NC} %s::%s — body differs (core=%s lines, wrap=%s lines)\n" "$file_label" "$func" "$core_lines" "$wrap_lines"
    if $FIX_HINT; then
      if [[ "$core_lines" -gt "$wrap_lines" ]]; then
        printf "  → core is larger, likely sync core→wrappers\n"
      elif [[ "$wrap_lines" -gt "$core_lines" ]]; then
        printf "  → wrappers is larger, check which is canonical\n"
      else
        printf "  → same line count but different content, diff manually\n"
      fi
    fi
    drift_count=$((drift_count + 1))
  fi
}

echo "Wrapper Parity Check"
echo "  core: $CORE_DIR"
echo "  wrap: $WRAP_DIR"
echo ""

for wrapper in "${PARITY_WRAPPERS[@]}"; do
  core_path="${CORE_DIR}/${wrapper}"
  wrap_path="${WRAP_DIR}/${wrapper}"

  if [[ ! -f "$core_path" ]]; then
    printf "${YELLOW}SKIP${NC} %s — not in core\n" "$wrapper"
    continue
  fi
  if [[ ! -f "$wrap_path" ]]; then
    printf "${YELLOW}SKIP${NC} %s — not in AI-CLI-Wrappers\n" "$wrapper"
    continue
  fi

  funcs="$(comm -12 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"
  core_only="$(comm -23 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"
  wrap_only="$(comm -13 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    compare_function "$wrapper" "$core_path" "$wrap_path" "$func"
  done <<< "$funcs"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    if is_excepted "$wrapper" "$func"; then
      excepted_count=$((excepted_count + 1))
    else
      printf "${YELLOW}DRIFT${NC} %s::%s — exists in core only\n" "$wrapper" "$func"
      $FIX_HINT && printf "  → sync core→wrappers\n"
      drift_count=$((drift_count + 1))
    fi
  done <<< "$core_only"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    if is_excepted "$wrapper" "$func"; then
      excepted_count=$((excepted_count + 1))
    else
      printf "${YELLOW}DRIFT${NC} %s::%s — exists in AI-CLI-Wrappers only\n" "$wrapper" "$func"
      drift_count=$((drift_count + 1))
    fi
  done <<< "$wrap_only"
done

for lib in "${PARITY_LIBS[@]}"; do
  core_path="${CORE_DIR}/${lib}"
  wrap_path="${WRAP_DIR}/${lib}"

  [[ -f "$core_path" && -f "$wrap_path" ]] || continue

  funcs="$(comm -12 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"
  core_only="$(comm -23 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"
  wrap_only="$(comm -13 <(extract_functions "$core_path") <(extract_functions "$wrap_path"))"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    compare_function "$lib" "$core_path" "$wrap_path" "$func"
  done <<< "$funcs"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    if is_excepted "$lib" "$func"; then
      excepted_count=$((excepted_count + 1))
    else
      printf "${YELLOW}DRIFT${NC} %s::%s — exists in core only\n" "$lib" "$func"
      drift_count=$((drift_count + 1))
    fi
  done <<< "$core_only"

  while IFS= read -r func; do
    [[ -n "$func" ]] || continue
    if is_excepted "$lib" "$func"; then
      excepted_count=$((excepted_count + 1))
    else
      printf "${YELLOW}DRIFT${NC} %s::%s — exists in AI-CLI-Wrappers only\n" "$lib" "$func"
      drift_count=$((drift_count + 1))
    fi
  done <<< "$wrap_only"
done

echo ""
printf "Checked %d functions across %d files\n" "$checked_count" "$(( ${#PARITY_WRAPPERS[@]} + ${#PARITY_LIBS[@]} ))"
if [[ $drift_count -eq 0 ]]; then
  printf "${GREEN}✓ No drift detected${NC}"
  [[ $excepted_count -gt 0 ]] && printf " (%d excepted)" "$excepted_count"
  printf "\n"
  exit 0
else
  printf "${RED}✗ %d drift(s) detected${NC}" "$drift_count"
  [[ $excepted_count -gt 0 ]] && printf " (%d excepted)" "$excepted_count"
  printf "\n"
  $STRICT && exit 1
  exit 0
fi
