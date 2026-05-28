# AI-CLI-Wrappers

This directory contains robust shell wrappers that provide a unified interface for various AI CLI tools (Claude, Gemini, Codex, OpenCode, Cursor, Antigravity). These wrappers are designed to be orchestrated by `go-autonom8/climanager` but can also be used independently.

## Overview

The wrappers standardize the execution of AI agents by handling:
- **Persona Extraction**: Parsing agent roles from Markdown files (`.md`).
- **Context Injection**: Automatically loading `CONTEXT.md` or other project context.
- **Session Management**: Handling session persistence, resumption, and creation across different providers.
- **Skill Execution**: Invoking specific skills with structured input.
- **Process Lifecycle**: Managing timeouts, signal handling, and cleanup of child processes.
- **Tool Access**: configuring sandbox permissions and MCP tool access (YOLO mode).
- **Tool Activity Telemetry**: extracting tool/function call counts, classes, and error signals into the response envelope.
- **JSON Output**: Ensuring responses are returned in a structured JSON format for the caller.

## Available Wrappers

| Wrapper | Provider | Key Features |
|---------|----------|--------------|
| `claude.sh` | Anthropic Claude | Project-based sessions (`~/.claude/projects/`), cold start handling. |
| `gemini.sh` | Google Gemini | Native skills registry, MCP server support, index-based sessions. |
| `codex.sh` | OpenAI/Codex | Sandbox configuration (`danger-full-access`), playright browser support. |
| `opencode.sh` | OpenCode | Catalog-backed model normalization/fallback, optimized for fast code generation. |
| `cursor.sh` | Cursor Agent | Workspace-aware, beta skills support, auto-approval for MCPs. |
| `agravity.sh` | Google Antigravity (`agy`) | `--print=` non-interactive runs, UUID conversation resume, transcript-derived reasoning/tool telemetry. |


## Unified Interface

All wrappers support a common set of arguments to ensure interchangeable usage by the `climanager`.

### Common Flags

| Flag | Description |
|------|-------------|
| `--persona <ID>` | Selects a specific persona block from the agent file (e.g., `pm-claude`). |
| `--temperature <0.0-1.0>` | Sets the LLM temperature (if supported by provider). |
| `--context <File>` | Explicit path to a context file (e.g., `CONTEXT.md`). |
| `--context-dir <Dir>` | Directory to search for `CONTEXT.md` and project context. |
| `--context-max <Bytes>` | Max context file size in bytes (default: 51200 / 50KB). Truncates with warning if exceeded. |
| `--skip-context-file` | Disables context loading (for pure logic/schema tasks). |
| `--timeout <Seconds>` | Sets a hard timeout for the execution (includes cleanup buffer). |
| `--yolo` | Enables "YOLO mode" - bypasses permission prompts (e.g., `--dangerously-skip-permissions`). |
| `--allowed-tools` | Explicitly enables MCP tools/sandboxed execution. |
| `--model <Name>` | Model selection (e.g., `opus`, `sonnet`, `haiku`, or full model name). |
| `--permission-mode <Mode>` | Permission mode (e.g., `plan`, `default`). Maps to provider-specific flags. |
| `--dry-run` | Validates arguments, agent file, and prompt size without making an API call. Returns comprehensive validation JSON. |
| `--verbose` / `--debug` | Enables debug logging to stderr. |

### Session Management

| Flag | Description |
|------|-------------|
| `--session-id <ID>` | Resumes an existing session. |
| `--resume <ID>` | Alias for `--session-id`. |
| `--new-session` | Creates a new session and captures the ID from the response (Claude). |
| `--manage-session <ID>` | Manages a named/tracked session (Gemini/Codex). |

### Skill Execution

| Flag | Description |
|------|-------------|
| `--skill <Name>` | Invokes a specific skill instead of a full agent prompt. |

### Diagnostics & Telemetry

| Flag | Description | Availability |
|------|-------------|--------------|
| `--health-check` | Returns provider CLI availability, version, and latency as JSON. No inference call made. | All wrappers |
| `--quota-status` | Checks cached usage-limit files and returns quota exhaustion status with estimated reset time. | Claude, Codex, Cursor |
| `--reasoning-fallback` | Emits reasoning and token telemetry from session logs without invoking the provider CLI. Requires `--session-id`. | All wrappers |

### Positional Arguments & Input

- **Agent File**: The last positional argument should be the path to the agent definition file (`.md`).
- **Input Data**: JSON input data is passed via **stdin**.

**Example:**
```bash
echo '{"task": "Analyze this code"}' | ./bin/claude.sh \
  --persona pm-claude \
  --context-dir /path/to/project \
  --timeout 120 \
  --yolo \
  agents/pm-agent.md
```

## Output Format

The wrappers print JSON to **stdout** via `emit_cli_response`. All wrappers share this envelope:

### Success Response

```json
{
  "response": "The actual text response from the LLM...",
  "session_id": "uuid-or-index",
  "reasoning": "Extracted thinking/reasoning from the model...",
  "tokens_used": {
    "input_tokens": 1200,
    "output_tokens": 450,
    "estimated_output_tokens": 425,
    "total_tokens": 1650,
    "cost_usd": 0.012,
    "cache_read_input_tokens": 800,
    "cache_creation_input_tokens": 0
  },
  "metadata": {
    "token_usage_available": true,
    "reasoning_available": true,
    "reasoning_source": "session_assistant",
    "reasoning_absent_reason": "available",
    "tool_activity": {
      "call_count": 4,
      "write_count": 1,
      "error_count": 0,
      "tool_names": ["Read", "Grep", "Edit"],
      "result_classes": ["read", "write"],
      "activity_class": "write_active",
      "source": "wrapper:claude"
    }
  },
  "model_resolution": "provider model 'requested' -> 'effective' (fallback)"
}
```

Optional fields:
- `"model_resolution"` when the wrapper normalized or fell back from the requested model.
- `"skill"` for skill-oriented wrapper paths.
- `"metadata.tool_activity"` only appears when the wrapper observed one or more tool calls; omitted for pure-text responses.

Skill invocations include an extra `"skill": "<name>"` field. Markdown code fences are stripped automatically.

### Error Response

Returned via `emit_cli_error_response` when a provider call fails:

```json
{
  "response": "",
  "session_id": "uuid-if-available",
  "reasoning": "",
  "tokens_used": {
    "input_tokens": 0,
    "output_tokens": 0,
    "estimated_output_tokens": 0,
    "total_tokens": 0,
    "cost_usd": 0,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0
  },
  "metadata": {
    "token_usage_available": false,
    "reasoning_available": false,
    "reasoning_source": "none",
    "reasoning_absent_reason": "error_path"
  },
  "error": "Detailed error message...",
  "error_type": "timeout",
  "exit_code": 124,
  "recoverable": true
}
```

**Error types**: `timeout`, `quota`, `rate_limit`, `invalid_model`, `invalid_session`, `invalid_input`, `provider_error`, `unknown`. Errors marked `recoverable: true` signal to the caller that a retry or fallback is appropriate.

## Model Selection and Fallback

Wrappers now harden invalid model handling locally instead of always failing the call on first contact.

Model resolution order:
1. Explicit `--model <name>` from the caller.
2. `AI_CLI_PROVIDERS_CONFIG` or `AUTONOM8_PROVIDERS_CONFIG`, when set.
3. A nearby repo config discovered from the working directory: `providers.yaml`, `go-autonom8/providers.yaml`, `.ai-cli-wrappers/providers.yaml`, or `.autonom8/providers.yaml`.
4. Bundled wrapper defaults in `defaults/providers.yaml`.
5. Provider-native current/default model where the CLI exposes a live catalog.

Provider configs can use aliases under `models:` plus `default_model:`. Wrappers resolve the alias before execution and emit `model_resolution` whenever normalization or fallback occurs. Provider-specific CLI mechanics still live inside each wrapper; callers should not need to know whether a provider expects a family alias, full model ID, or provider-prefixed ID.

Behavior by provider:
1. `cursor.sh`
   - validates requested models against `cursor-agent models`
   - falls back to the current/default provider model when the requested or configured model does not exist
2. `opencode.sh`
   - validates requested models against `opencode models`
   - resolves common tail aliases like `gpt-5.1` to full IDs like `openai/gpt-5.1`
   - uses config-backed defaults for no-model calls
   - falls back to the live provider catalog if a configured default is stale
3. `claude.sh`, `codex.sh`, `gemini.sh`
   - attempt the requested model first
   - if the provider returns an invalid-model class error, retry once with provider default
   - `gemini.sh` additionally retries `gemini-2.5-flash` when provider-default routing hits Gemini capacity exhaustion

If all config/default discovery fails and the provider CLI requires an explicit model, the wrapper fails fast with `invalid_input` instead of silently embedding a task-model choice in shell code.

### Health Check Response

```json
{
  "provider": "claude",
  "status": "ok",
  "latency_ms": 142,
  "cli_available": true,
  "version": "1.0.18",
  "session_support": true
}
```

### Quota Status Response

```json
{
  "provider": "claude",
  "quota_exhausted": true,
  "reset_at": "2026-03-12T15:30:00Z",
  "reset_in_seconds": 1800,
  "retry_time": "try again at 3:30 PM",
  "source": "cached"
}
```

## Reasoning Extraction

All wrappers attempt to extract model reasoning/thinking from multiple sources, in priority order:

1. **Raw output** — `_reasoning`, `reasoning`, `thinking`, `thoughts`, `analysis` fields from the JSON response.
2. **Session logs** — `thinking` content blocks from assistant messages in the session file (Claude format: `.message.content[].type == "thinking"`).
3. **Response payload** — Reasoning fields embedded inside fenced JSON blocks in the assistant text.
4. **Stream output** — Lines matching `thought|thinking|reasoning|analysis|plan:|step [0-9]+` from stderr (last resort).

Extracted reasoning is compacted (newlines collapsed, whitespace normalized) and capped at 600 characters. Placeholder values (`{}`, `[]`, `null`, bare code fences) are filtered out.

The `reasoning_source` metadata field indicates which source yielded the reasoning: `raw_output`, `session_assistant`, `response_payload`, `stream_log`, or `none`.

## Token Usage Tracking

Token usage is extracted from multiple sources, in priority order:

1. **Raw JSON output** — Parses `usage.input_tokens`, `usage.output_tokens`, `usage.cost_usd` and variants (`inputTokens`, `prompt_tokens`, `token_usage.*`, etc.).
2. **Session file** — Reads the last assistant message's `.message.usage` from the session JSONL file.
3. **Stream output** — Regex extraction of `tokens used [N]` from stderr progress output.

All sources are normalized to the same schema: `{input_tokens, output_tokens, total_tokens, cost_usd}`. If `total_tokens` is zero but input + output are available, the total is computed automatically.

## Tool Activity Telemetry

All wrappers source `lib/tool-telemetry.sh` to emit a best-effort summary of tool/function calls observed during the run. When any calls are detected, the summary is merged into `metadata.tool_activity` on the success envelope; when none are detected, the field is omitted.

Two functions drive this:

- `autonom8_tool_activity_json <raw_output> <stream_output> <source>` — parses JSON payloads and stream text to produce the telemetry object.
- `autonom8_merge_tool_activity <tool_activity_json>` — piped after the final `jq` stage to fold the object into `metadata.tool_activity` only when activity was observed.

### Extraction Sources

The library inspects both the raw CLI output and the streamed stderr for tool-call evidence:

1. **Structured JSON** — recognizes `toolCalls[]`, `tool_calls[]`, `functionCall`, `function_call`, and events whose `type` matches `tool`, `tool_use`, `tool_call`, `function_call`, `tool-call`, `tool.start`, or `tool_start`.
2. **Stream text** — scans for patterns like `Tool <name> executed|called|started|completed|failed` (also matches `function` and `mcp` prefixes).
3. **Provider-native stores** — `opencode.sh` additionally reads tool events from the OpenCode session SQLite (`~/.local/share/opencode/opencode.db`, `part` table) so tool activity is captured even when the CLI did not stream it.

Tool names are compacted: `functions.<name>` is stripped, `mcp__ns__tool` is normalized to `ns.tool`, and non-alphanumeric noise is collapsed to `_`.

### Schema

```json
{
  "call_count": 4,
  "write_count": 1,
  "error_count": 0,
  "tool_names": ["Read", "Grep", "Edit"],
  "result_classes": ["read", "write"],
  "activity_class": "write_active",
  "source": "wrapper:claude"
}
```

| Field | Description |
|-------|-------------|
| `call_count` | Total tool invocations observed (duplicates counted). |
| `write_count` | Invocations classified as mutating (see below). |
| `error_count` | Tool calls reporting `is_error`, `ok: false`, or error-class status/result, plus stream matches for `tool ... error/failed/failure`. |
| `tool_names` | Deduplicated list of compacted tool names. |
| `result_classes` | Deduplicated list of behavior classes seen. |
| `activity_class` | Roll-up: `tool_errors` \| `write_active` \| `tool_active` \| `none`. |
| `source` | Origin tag, e.g. `wrapper:claude`, `wrapper:opencode`. |

### Tool Classification

Tool names are classified by regex over their lowercased form:

| Class | Matches |
|-------|---------|
| `write` | `apply_patch`, `write`, `edit`, `multi_edit`, `replace`, `create`, `delete`, `remove`, `move`, `rename`, `insert` |
| `read` | `read`, `cat`, `open`, `view`, `list`, `ls`, `find`, `grep`, `rg`, `search` |
| `browser` | `browser`, `playwright`, `screenshot`, `page`, `dom`, `axe`, `lighthouse` |
| `web` | `web`, `fetch`, `http`, `url`, `search_query` |
| `shell` | `exec`, `bash`, `shell`, `command`, `terminal` |
| `other` | anything else |

### Consumer Guidance

- Use `activity_class == "tool_errors"` as a signal to inspect logs before trusting the response.
- `write_active` indicates the agent mutated the working tree; callers may want to diff before committing.
- `tool_active` with only `read`/`browser`/`web` classes implies a review or investigation pass rather than a change pass.
- Missing `tool_activity` does not prove zero tool use — it means the wrapper could not detect any from the available signals.

## Agent Stream Logging

When the environment variable `A8_TICKET_ID` is set (typically by the Go CLIManager), wrappers create per-invocation log files:

```
<work_dir>/.autonom8/agent_logs/<ticket_id>_<workflow>_<timestamp>.log
```

These logs capture:
- Header with ticket ID, workflow name, provider, and start timestamp.
- Stderr output from the CLI (progress, warnings, tool calls) via `tee`.
- Full stdout response appended after completion.

This enables post-hoc debugging and audit trails per ticket.


## Real-Time Provider Activity Monitor

All wrappers integrate with `lib/live-monitor.sh` (656 LOC) to observe provider activity in real time. The monitor writes structured JSONL heartbeats to a per-request activity file, enabling the Go-side orchestrator to distinguish "provider is thinking" from "provider is stuck" without relying solely on stdout bytes.

### Problem

Provider sessions can produce zero observable stdout for extended periods — reasoning, tool execution, rate-limit backoff, and sandbox operations all happen silently. Without an activity signal, the orchestrator's zero-output watchdog kills healthy sessions that simply haven't produced terminal output yet.

### Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────────────────────────────────┐
│  Provider    │────▶│  Wrapper (bash)   │────▶│  .autonom8/provider_activity/<req>.jsonl  │
│  CLI process │     │  live-monitor.sh  │     │  {"ts":...,"event_class":...,"detail":..} │
└─────────────┘     └──────────────────┘     └──────────────────────────────────────────┘
                           ▲                              │
                     stderr + session                     ▼
                     file polling (5s)            Go CLIManager reads
                                                  as liveness signal
```

The monitor runs as a background polling loop alongside the provider process. Every 5 seconds it:
1. Checks stderr file growth and classifies new lines (reasoning, tool_use, rate_limit, error patterns)
2. Discovers provider session files (`.jsonl`/`.log` in provider-specific directories)
3. Classifies session events using provider-specific or generic parsers
4. Writes a heartbeat event to the activity JSONL file

### Setup

Each wrapper applies a 4-point integration:

| Point | Code | Purpose |
|-------|------|---------|
| Source + init | `source lib/live-monitor.sh` + `autonom8_monitor_init "<provider>"` | Load library, create no-op stream stub |
| Cleanup trap | `autonom8_stop_live_monitor` in EXIT handler | Kill background loop on script exit |
| Start | `autonom8_start_live_monitor` before each execution path | Launch background monitor |
| Stop | `autonom8_stop_live_monitor` after each execution path | Stop monitor, write final event |

The `autonom8_monitor_init(provider)` call creates a no-op JSONL stream stub via `eval` for any provider name. Adding a new wrapper requires only these 4 integration points (~6 lines per execution path).

### Activity File Format

Path: `<work_dir>/.autonom8/provider_activity/<AUTONOM8_REQUEST_ID>.jsonl`

Each line is a JSON object:
```json
{"ts":"2026-05-28T04:15:30Z","provider":"codex","request_id":"abc123","event_class":"session_reasoning","detail":"new_lines=4"}
```

**Event classes:**
| Class | Meaning |
|-------|---------|
| `monitor_start` | Monitor background loop started |
| `monitor_stopped` | Monitor loop terminated |
| `stderr_activity` | New stderr output detected (with byte count) |
| `stderr_error` | Error pattern found in stderr |
| `stderr_rate_limit` | Rate-limit signal in stderr |
| `session_reasoning` | Provider is actively reasoning (thinking/planning) |
| `session_tool_use` | Provider is executing a tool/function call |
| `session_function_call` | Provider called a function (code execution, API call) |
| `session_task_started` | Provider started a new task or subtask |
| `session_task_complete` | Provider completed a task |
| `codex_reasoning` | Codex-specific: reasoning event from `--json` stream |
| `codex_function_call` | Codex-specific: function call from `--json` stream |
| `codex_code_write` | Codex-specific: file write from `--json` stream |

### Provider-Specific Classifiers

Each provider has specialized stderr and session classifiers that recognize provider-native patterns:

| Provider | Stderr patterns | Session discovery | Session format |
|----------|----------------|-------------------|----------------|
| **Codex** | `reasoning:`, `function_call:`, `write_file:`, `apply_patch:` | `~/.codex/sessions/` | `.payload.type` dispatch |
| **Claude** | `session:`, `tool_use:`, `cost:`, `tokens:` | `~/.claude/projects/` | Generic fallback |
| **Gemini** | `thinking`, `function_call`, `grounding`, `safety_rating` | `~/.gemini/` | Generic fallback |
| **Cursor** | `composer`, `apply`, `tool:`, `indexing` | `~/.cursor/projects/` | `.event` dispatch |
| **OpenCode** | `thinking`, `tool`, `session`, `inference` | (none) | Generic fallback |
| **Agravity** | `thinking`, `function_call`, `grounding`, `safety_rating` | `~/.gemini/antigravity-cli/conversations/` | Generic fallback |

All classifiers have generic fallbacks — `_autonom8_classify_generic_stderr`, `_autonom8_discover_generic_session`, and `_autonom8_classify_generic_session` — so new providers work out of the box with basic activity detection.

### Codex JSONL Stream Piping

Codex wrappers additionally pipe `codex exec --json` stdout through `autonom8_monitor_codex_jsonl_stream()`, which classifies each JSONL event in real time:

```bash
codex exec --json ... | autonom8_monitor_codex_jsonl_stream "$REQ_ID" "$ACTIVITY_FILE"
```

This provides per-event granularity (reasoning steps, function calls, code writes) rather than the 5-second polling resolution. Exit codes pass through correctly via `pipefail` since the stream function always exits 0.

### Future: Go-Side Integration

The Go CLIManager's progress goroutine (`manager.go`) already polls every 5 seconds for stdout bytes and disk mutations. The activity JSONL file is designed to be read as a 5th liveness signal:

```
<ContextDir>/.autonom8/provider_activity/<requestCorrelationID>.jsonl
```

The `AUTONOM8_REQUEST_ID` environment variable (set by CLIManager at line 6572) matches the shell-side `WRAPPER_REQ_ID`, ensuring the file path is deterministic. A reader function can seek to the last-read offset, parse new events, and update `lastActivity` to defer the zero-output watchdog.

## Prompt Size Management

Each wrapper defines provider-appropriate limits:

| Constant | Default | Purpose |
|----------|---------|---------|
| `PROMPT_MAX_CHARS` | 200,000 | Hard limit (~50K tokens for Claude's 200K context) |
| `PROMPT_WARN_THRESHOLD` | 160,000 | Warning threshold (~40K tokens) |

- `check_prompt_size` logs warnings to stderr when approaching or exceeding limits.
- `get_prompt_stats` returns a JSON object with `prompt_size_chars`, `estimated_tokens`, `max_chars`, `over_limit`.
- `save_debug_prompt` saves the full prompt to disk when `DEBUG_PROMPTS=true` (for offline inspection).
- `--context-max` truncates the context file before it enters the prompt, with a `[... CONTEXT TRUNCATED ...]` marker.

## Session Resume Optimization

When resuming an existing session (`--session-id` or `--resume`), wrappers skip injecting the persona block into the prompt — the persona is already in the session context from the initial invocation. Only the new task data and critical instructions are sent. This reduces token usage significantly on multi-turn workflows.

## Error Handling

Wrappers source `lib/error_utils.sh` (if available) for standardized error classification. The `classify_error` function maps stderr output to error types:

| Error Type | Trigger | Recoverable |
|------------|---------|-------------|
| `quota` | "usage limit", "rate limit exceeded", "try again at" | Yes |
| `rate_limit` | "429", "too many requests" | Yes |
| `timeout` | Exit code 124, "context deadline exceeded" | Yes |
| `invalid_session` | "session not found", "invalid session" | Yes |
| `invalid_input` | Bad persona, missing agent file, malformed JSON | No |
| `provider_error` | CLI crash, non-zero exit, empty response | No |
| `unknown` | Unclassified | No |

For quota errors, a system message file is written to `<core_dir>/context/system-messages/inbox/` with timestamp, retry time, and severity — enabling upstream orchestrators to schedule retries.

## Provider-Specific Details

### Claude (`claude.sh`)
- Sessions stored in `~/.claude/projects/<encoded-path>/`. Path encoding replaces both `/` and `_` with `-`.
- `--output-format json` captures `session_id` and `result` from Claude's response envelope.
- `--resume <ID>` for session continuation with persona-skip optimization.
- Quota status via cached system message files (`*-claude-usage-limit.json`).
- Supports `try again at ...` parsing for rate limit handling.
- Model selection: `--model opus`, `--model sonnet`, `--model haiku`.

### Gemini (`gemini.sh`)
- Supports **Native Skills**: Checks `.gemini/skills/` and registers them via `--skills` flag.
- MCP server support with auto-registration.
- Filters out informational logs ("YOLO mode enabled") to preserve JSON output.
- Maps UUID session IDs to Gemini's internal numeric indices.

### Codex (`codex.sh`)
- Sessions stored in `~/.codex/sessions/`.
- Uses `--sandbox danger-full-access` when `--yolo` or `--allowed-tools` is set.
- Exports `SKIP_WEBKIT=1` and `SKIP_FIREFOX=1` for Playwright stability.
- Quota status via cached system message files.

### OpenCode (`opencode.sh`)
- Defaults to `opencode/grok-code` model.
- Full session management, prompt size checking, and agent stream logging.
- Model selection via `--model` flag.

### Cursor (`cursor.sh`)
- Uses `cursor-agent` CLI.
- Supports workspace configuration for context awareness.
- Auto-approves MCP tool usage when `--allowed-tools` is set.
- Beta skills support via `.cursor/skills/`.
- Quota status via cached system message files.

### Antigravity (`agravity.sh`)
- Uses Google's `agy` CLI (Antigravity).
- Non-interactive runs use `--print=<prompt>`; the wrapper always sets `--print-timeout=<CLI_TIMEOUT>s` so timeouts are enforced on both sides.
- `--yolo` / `--allowed-tools` maps to `--dangerously-skip-permissions`; `--add-dir <path>` is forwarded to `agy` (and the resolved workspace is added automatically).
- Conversation state lives at `~/.gemini/antigravity-cli/conversations/<UUID>.pb`; the wrapper discovers the freshest conversation id after each run.
- `--session-id <UUID>` resumes via `--conversation=<UUID>`; non-UUID logical ids start fresh and the real provider id is captured on completion.
- Reasoning and tool telemetry are mined from `~/.gemini/antigravity-cli/brain/<UUID>/.system_generated/logs/transcript.jsonl` (assistant `thinking` blocks; `tool_calls[]` per step).
- The `agy` CLI exposes no `--model` flag — the active model is configured via `~/.gemini/antigravity-cli/settings.json`. The wrapper accepts `--model` for interface parity and records it in `model_resolution`, but does not pass it through.
- Antigravity does not emit usage metadata; `tokens_used` reports estimated output tokens and a transcript-size-based total estimate.

## AWS Lambda Integration

This repository also contains serverless implementations for AI agents, located in the `aws-lambdas/` directory. These Lambdas provide direct API access to agent capabilities without requiring a local CLI environment.

### Components
- **AI-Agent-Claude**: AWS Lambda implementation for Anthropic's Claude.
- **AI-Agent-Gemini**: AWS Lambda implementation for Google's Gemini.
- **AI-Agent-Codex**: AWS Lambda implementation for OpenAI's Codex/GPT models.
- **sync_config.py**: Utility script to sync persona and skill definitions to DynamoDB or S3.

See [aws-lambdas/README.md](aws-lambdas/README.md) for detailed deployment and usage instructions.

## Integration with CLIManager

The `go-autonom8/climanager` package relies on these wrappers to:
1.  **Orchestrate Calls**: It builds the command line arguments based on the `CLIRequest`.
2.  **Handle Fallbacks**: If one wrapper fails (exit code != 0), it tries the next in the chain.
3.  **Manage Resources**: It tracks PIDs and process groups to ensure clean termination on timeouts.
4.  **Parse Output**: It decodes the JSON output and normalizes it for the application.


### Cursor macOS Keychain Bootstrap

`cursor.sh` refreshes the macOS login keychain before each Cursor CLI process when running on Darwin. This is required for SSH-launched Mac Mini workers because Cursor stores CLI credentials in `login.keychain-db`, while a non-GUI worker process can outlive or miss a manual keychain unlock. The wrapper only unlocks the keychain so an already-authenticated Cursor CLI can read its credentials; it does not log in to Cursor or create credentials.

Configuration:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTONOM8_CURSOR_UNLOCK_KEYCHAIN` | `1` | Set to `0` to disable Cursor-specific keychain refresh. |
| `AUTONOM8_UNLOCK_KEYCHAIN` | `1` | Shared fallback opt-out when the Cursor-specific variable is unset. |
| `AUTONOM8_KEYCHAIN_PASSWORD` | unset | Explicit keychain password. Preferred for process supervisors that inject secrets directly. |
| `AUTONOM8_KEYCHAIN_PASSWORD_ENV` | `mini` | Name of the env var containing the keychain password. |
| `AUTONOM8_KEYCHAIN_ENV_FILE` | `<login-home>/.env` | File sourced or parsed when the password env var is not already exported. Falls back to the login user's home if `HOME` is sanitized by a worker. |
| `AUTONOM8_KEYCHAIN_PATH` | `<login-home>/Library/Keychains/login.keychain-db` | Keychain unlocked before invoking Cursor. Falls back to the login user's home if `HOME` is sanitized by a worker. |
| `AUTONOM8_KEYCHAIN_UNLOCK_TIMEOUT_SECONDS` | `21600` | Timeout passed to `security set-keychain-settings -lut`. |
| `AUTONOM8_KEYCHAIN_SET_TIMEOUT` | `1` | Set to `0` to unlock without refreshing the keychain timeout. |
| `AUTONOM8_CURSOR_NORMALIZE_HOME` | `1` | Set to `0` to keep process `HOME` unchanged. By default Cursor invocations on macOS use the login user's home so Cursor Agent resolves the same keychain/config as an interactive session. |

Security and operations notes:

- Do not print or commit the `mini` value or any `.env` file containing it.
- The wrapper first checks the already-exported password variable, then sources `AUTONOM8_KEYCHAIN_ENV_FILE`, then falls back to a simple `KEY=value` parser. This mirrors the operator command `set -a; . "$HOME/.env"; security unlock-keychain -p "$mini" ...` without logging the secret.
- Missing or failed unlock is intentionally non-fatal. The Cursor call continues so the caller receives the provider's real `credential_unavailable` error.
- If `credential_unavailable` only appears when multiple Cursor sessions start concurrently, treat that as a routing/concurrency issue rather than a password issue; avoid overlapping Cursor QA and implement calls or add a provider-level Cursor lock.
