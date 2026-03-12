# AI-CLI-Wrappers

This directory contains robust shell wrappers that provide a unified interface for various AI CLI tools (Claude, Gemini, Codex, OpenCode, Cursor). These wrappers are designed to be orchestrated by `go-autonom8/climanager` but can also be used independently.

## Overview

The wrappers standardize the execution of AI agents by handling:
- **Persona Extraction**: Parsing agent roles from Markdown files (`.md`).
- **Context Injection**: Automatically loading `CONTEXT.md` or other project context.
- **Session Management**: Handling session persistence, resumption, and creation across different providers.
- **Skill Execution**: Invoking specific skills with structured input.
- **Process Lifecycle**: Managing timeouts, signal handling, and cleanup of child processes.
- **Tool Access**: configuring sandbox permissions and MCP tool access (YOLO mode).
- **JSON Output**: Ensuring responses are returned in a structured JSON format for the caller.

## Available Wrappers

| Wrapper | Provider | Key Features |
|---------|----------|--------------|
| `claude.sh` | Anthropic Claude | Project-based sessions (`~/.claude/projects/`), cold start handling. |
| `gemini.sh` | Google Gemini | Native skills registry, MCP server support, index-based sessions. |
| `codex.sh` | OpenAI/Codex | Sandbox configuration (`danger-full-access`), playright browser support. |
| `opencode.sh` | OpenCode | Uses `grok-code` model, optimized for fast code generation. |
| `cursor.sh` | Cursor Agent | Workspace-aware, beta skills support, auto-approval for MCPs. |

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
    "total_tokens": 1650,
    "cost_usd": 0.012
  },
  "metadata": {
    "token_usage_available": true,
    "reasoning_available": true,
    "reasoning_source": "session_assistant",
    "reasoning_absent_reason": "available"
  }
}
```

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
    "total_tokens": 0,
    "cost_usd": 0
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

**Error types**: `timeout`, `quota`, `rate_limit`, `invalid_session`, `invalid_input`, `provider_error`, `unknown`. Errors marked `recoverable: true` (quota, rate_limit, timeout, invalid_session) signal to the caller that a retry or fallback is appropriate.

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