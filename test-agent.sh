#!/usr/bin/env bash
# Test Agent for Session Management Validation
# Minimal implementation that remembers numbers persistently

set -euo pipefail

# Storage file for remembered number
STORAGE_FILE="${HOME}/.test-agent-storage"

# Parse input JSON and extract instruction
parse_input() {
    local input="$1"
    # Extract instruction field
    local instruction
    instruction=$(echo "$input" | jq -r '.instruction // empty' 2>/dev/null || echo "")
    echo "$instruction"
}

# Store a number
store_number() {
    local number="$1"
    echo "$number" > "$STORAGE_FILE"
    echo "{\"stored_number\": $number, \"status\": \"stored\"}"
}

# Recall the stored number
recall_number() {
    if [[ -f "$STORAGE_FILE" ]]; then
        local number
        number=$(cat "$STORAGE_FILE")
        echo "{\"recalled_number\": $number, \"status\": \"recalled\"}"
    else
        echo "{\"error\": \"No number stored\", \"status\": \"error\"}"
    fi
}

# Main logic
main() {
    local input="$1"
    local instruction
    instruction=$(parse_input "$input")

    if [[ -z "$instruction" ]]; then
        echo "{\"error\": \"No instruction provided\", \"status\": \"error\"}"
        exit 1
    fi

    # Check for remember instruction
    if [[ "$instruction" =~ Remember\ this\ number\ exactly:\ ([0-9]+) ]]; then
        local number="${BASH_REMATCH[1]}"
        store_number "$number"
    # Check for recall instruction
    elif [[ "$instruction" =~ What\ was\ the\ number\ I\ asked\ you\ to\ remember ]]; then
        recall_number
    else
        echo "{\"error\": \"Unknown instruction\", \"status\": \"error\"}"
        exit 1
    fi
}

# If called with arguments, use first arg as input
if [[ $# -gt 0 ]]; then
    main "$1"
else
    # Read from stdin
    input=$(cat)
    main "$input"
fi