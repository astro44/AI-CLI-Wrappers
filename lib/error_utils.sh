#!/usr/bin/env bash
# Shared error handling utilities for Autonom8 CLI wrappers
# P6.1: Standardized error handling with classification

# Error classification constants
ERROR_TIMEOUT="timeout"
ERROR_RATE_LIMIT="rate_limit"
ERROR_AUTH="auth"
ERROR_NETWORK="network"
ERROR_QUOTA="quota"
ERROR_INVALID_INPUT="invalid_input"
ERROR_PROVIDER="provider_error"
ERROR_UNKNOWN="unknown"

# Patterns for error classification
# Timeout patterns
TIMEOUT_PATTERNS=(
    "timed out"
    "timeout"
    "deadline exceeded"
    "context deadline"
    "operation took too long"
    "exit status 124"  # timeout command exit code
)

# Rate limit patterns
RATE_LIMIT_PATTERNS=(
    "rate limit"
    "too many requests"
    "throttl"
    "429"
    "slow down"
)

# Auth patterns
AUTH_PATTERNS=(
    "unauthorized"
    "authentication"
    "invalid.*key"
    "invalid.*token"
    "api key"
    "401"
    "403"
    "forbidden"
    "access denied"
)

# Quota/usage limit patterns
QUOTA_PATTERNS=(
    "usage limit"
    "out of.*messages"
    "out of.*credits"
    "purchase more credits"
    "quota exceeded"
    "limit reached"
)

# Network patterns
NETWORK_PATTERNS=(
    "network"
    "connection refused"
    "connection reset"
    "no route to host"
    "dns"
    "ssl"
    "tls"
    "certificate"
)

# Classify an error message
# Args: error_message
# Returns: error classification string
classify_error() {
    local error_msg="$1"
    local error_lower=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

    # Check timeout patterns
    for pattern in "${TIMEOUT_PATTERNS[@]}"; do
        if echo "$error_lower" | grep -qiE "$pattern"; then
            echo "$ERROR_TIMEOUT"
            return 0
        fi
    done

    # Check rate limit patterns
    for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
        if echo "$error_lower" | grep -qiE "$pattern"; then
            echo "$ERROR_RATE_LIMIT"
            return 0
        fi
    done

    # Check auth patterns
    for pattern in "${AUTH_PATTERNS[@]}"; do
        if echo "$error_lower" | grep -qiE "$pattern"; then
            echo "$ERROR_AUTH"
            return 0
        fi
    done

    # Check quota patterns
    for pattern in "${QUOTA_PATTERNS[@]}"; do
        if echo "$error_lower" | grep -qiE "$pattern"; then
            echo "$ERROR_QUOTA"
            return 0
        fi
    done

    # Check network patterns
    for pattern in "${NETWORK_PATTERNS[@]}"; do
        if echo "$error_lower" | grep -qiE "$pattern"; then
            echo "$ERROR_NETWORK"
            return 0
        fi
    done

    # Default to unknown
    echo "$ERROR_UNKNOWN"
}

# Format a structured error response
# Args: provider, error_message, [exit_code], [extra_json_fields]
# Output: JSON error object
format_error_response() {
    local provider="$1"
    local error_msg="$2"
    local exit_code="${3:-1}"
    local extra_fields="${4:-}"

    local error_type
    error_type=$(classify_error "$error_msg")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build base error response
    local base_json
    base_json=$(jq -n \
        --arg provider "$provider" \
        --arg error "$error_msg" \
        --arg type "$error_type" \
        --argjson exit_code "$exit_code" \
        --arg timestamp "$timestamp" \
        '{
            error: $error,
            error_type: $type,
            provider: $provider,
            exit_code: $exit_code,
            timestamp: $timestamp,
            recoverable: (if $type == "timeout" or $type == "rate_limit" or $type == "quota" then true else false end)
        }')

    # Merge extra fields if provided
    if [[ -n "$extra_fields" && "$extra_fields" != "{}" ]]; then
        echo "$base_json" | jq --argjson extra "$extra_fields" '. + $extra'
    else
        echo "$base_json"
    fi
}

# Handle timeout errors specifically
# Args: provider, timeout_seconds, [operation]
# Output: JSON error object
handle_timeout_error() {
    local provider="$1"
    local timeout_secs="${2:-0}"
    local operation="${3:-cli_call}"

    local extra_fields
    extra_fields=$(jq -n \
        --argjson timeout "$timeout_secs" \
        --arg operation "$operation" \
        '{timeout_seconds: $timeout, operation: $operation, suggestion: "Consider increasing timeout or reducing prompt size"}')

    format_error_response "$provider" "Operation timed out after ${timeout_secs}s" 124 "$extra_fields"
}

# Handle quota/usage limit errors
# Args: provider, error_message, [retry_time]
# Output: JSON error object
handle_quota_error() {
    local provider="$1"
    local error_msg="$2"
    local retry_time="${3:-}"

    local extra_fields
    if [[ -n "$retry_time" ]]; then
        extra_fields=$(jq -n \
            --arg retry "$retry_time" \
            '{retry_time: $retry, suggestion: "Wait for quota reset or switch provider"}')
    else
        extra_fields=$(jq -n '{suggestion: "Wait for quota reset or switch provider"}')
    fi

    format_error_response "$provider" "$error_msg" 1 "$extra_fields"
}

# Log error to standard location
# Args: provider, error_type, error_message, [log_dir]
log_error() {
    local provider="$1"
    local error_type="$2"
    local error_msg="$3"
    local log_dir="${4:-${AUTONOM8_LOG_DIR:-/tmp/autonom8_errors}}"

    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local log_file="$log_dir/${timestamp}_${provider}_${error_type}.json"

    jq -n \
        --arg provider "$provider" \
        --arg type "$error_type" \
        --arg error "$error_msg" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            timestamp: $ts,
            provider: $provider,
            error_type: $type,
            error: $error
        }' > "$log_file"

    # Also log to stderr if VERBOSE mode
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR [$provider] $error_type: $error_msg" >&2
    fi
}

# Check exit code and format appropriate error
# Args: provider, exit_code, stderr_content, [timeout_secs]
# Output: JSON error response (or empty string if no error)
check_and_format_error() {
    local provider="$1"
    local exit_code="$2"
    local stderr_content="$3"
    local timeout_secs="${4:-0}"

    # No error
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        return 0
    fi

    # Timeout (exit code 124 from timeout command)
    if [[ $exit_code -eq 124 ]]; then
        handle_timeout_error "$provider" "$timeout_secs"
        return 1
    fi

    # General error - classify and format
    local error_type
    error_type=$(classify_error "$stderr_content")

    # Log the error
    log_error "$provider" "$error_type" "$stderr_content"

    # Return formatted error
    format_error_response "$provider" "$stderr_content" "$exit_code"
    return 1
}

# Create system message for recoverable errors (quota, rate limit)
# Args: provider, error_type, error_message, [core_dir]
create_system_message() {
    local provider="$1"
    local error_type="$2"
    local error_msg="$3"
    local core_dir="${4:-${CORE_DIR:-$(pwd)}}"

    # Only create system messages for recoverable errors
    if [[ "$error_type" != "$ERROR_QUOTA" && "$error_type" != "$ERROR_RATE_LIMIT" ]]; then
        return 0
    fi

    local msg_dir="$core_dir/context/system-messages/inbox"
    mkdir -p "$msg_dir"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local msg_file="$msg_dir/$(date +%s)-${provider}-${error_type}.json"

    # Extract retry time if present
    local retry_time=""
    if [[ "$error_type" == "$ERROR_QUOTA" ]]; then
        retry_time=$(echo "$error_msg" | grep -oE "try again at [0-9]{1,2}:[0-9]{2} [AP]M" || echo "")
    fi

    jq -n \
        --arg ts "$timestamp" \
        --arg provider "$provider" \
        --arg type "$error_type" \
        --arg error "$error_msg" \
        --arg retry "$retry_time" \
        '{
            timestamp: $ts,
            type: $type,
            provider: $provider,
            error: $error,
            retry_time: $retry,
            severity: "warning",
            action_required: (if $type == "quota" then "Wait for quota reset or switch provider" else "Retry after cooldown period" end)
        }' > "$msg_file"
}

# Health check a provider
# Args: provider, [test_prompt]
# Output: JSON health status
check_provider_health() {
    local provider="$1"
    local test_prompt="${2:-echo hello}"

    local start_time
    start_time=$(date +%s%N)

    local status="ok"
    local error_msg=""
    local latency_ms=0

    # This function should be overridden by each wrapper with provider-specific logic
    # Default implementation just checks if CLI tool exists
    local cli_cmd=""
    case "$provider" in
        claude) cli_cmd="claude" ;;
        codex) cli_cmd="codex" ;;
        gemini) cli_cmd="gemini" ;;
        cursor) cli_cmd="cursor" ;;
        opencode) cli_cmd="opencode" ;;
        *) cli_cmd="$provider" ;;
    esac

    if ! command -v "$cli_cmd" &>/dev/null; then
        status="unavailable"
        error_msg="CLI tool '$cli_cmd' not found in PATH"
    else
        local end_time
        end_time=$(date +%s%N)
        latency_ms=$(( (end_time - start_time) / 1000000 ))
    fi

    jq -n \
        --arg provider "$provider" \
        --arg status "$status" \
        --argjson latency "$latency_ms" \
        --arg error "$error_msg" \
        '{
            provider: $provider,
            status: $status,
            latency_ms: $latency,
            cli_available: ($status == "ok"),
            error: (if $error == "" then null else $error end),
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }'
}
