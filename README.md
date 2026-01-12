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
| `--no-context` | Disables context loading (for pure logic/schema tasks). |
| `--timeout <Seconds>` | Sets a hard timeout for the execution (includes cleanup buffer). |
| `--yolo` | Enables "YOLO mode" - bypasses permission prompts (e.g., `--dangerously-skip-permissions`). |
| `--allowed-tools` | Explicitly enables MCP tools/sandboxed execution (implies `--yolo`). |
| `--dry-run` | Validates arguments and agent file without making an API call. |
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

The wrappers print JSON to **stdout**. The output typically follows this structure:

```json
{
  "response": "The actual text response from the LLM...",
  "session_id": "uuid-or-index",
  "provider_used": "claude",
  "tokens_used": {
    "input_tokens": 100,
    "output_tokens": 50
  }
}
```

*Note: Wrappers attempt to strip Markdown code fences (```json ... ```) from the output to ensure valid JSON.*

## Provider-Specific Details

### Claude (`claude.sh`)
- Sessions are stored in `~/.claude/projects/<encoded-path>/`.
- Supports `try again at ...` parsing for rate limit handling.

### Gemini (`gemini.sh`)
- Supports **Native Skills**: Checks `.gemini/skills/` and registers them.
- Filters out informational logs ("YOLO mode enabled") to preserve JSON output.
- Maps UUID session IDs to Gemini's internal numeric indices.

### Codex (`codex.sh`)
- Sessions stored in `~/.codex/sessions/`.
- Uses `--sandbox danger-full-access` when `--yolo` or `--allowed-tools` is set.
- Exports `SKIP_WEBKIT=1` and `SKIP_FIREFOX=1` for stability.

### OpenCode (`opencode.sh`)
- Defaults to `opencode/grok-code` model.
- Does not support detailed session management or sandbox bypass flags (warns on `--yolo`).

### Cursor (`cursor.sh`)
- Uses `cursor-agent` CLI.
- Supports workspace configuration for context awareness.
- Auto-approves MCP tool usage when `--allowed-tools` is set.

## Integration with CLIManager

The `go-autonom8/climanager` package relies on these wrappers to:
1.  **Orchestrate Calls**: It builds the command line arguments based on the `CLIRequest`.
2.  **Handle Fallbacks**: If one wrapper fails (exit code != 0), it tries the next in the chain.
3.  **Manage Resources**: It tracks PIDs and process groups to ensure clean termination on timeouts.
4.  **Parse Output**: It decodes the JSON output and normalizes it for the application.