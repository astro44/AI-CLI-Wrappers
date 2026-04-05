# CLI Wrappers

Shell script wrappers around Claude Code and OpenAI Codex CLIs, used by OpenClaw agents for cloud inference, web search, and tool execution.

Source repo: `~/repos/AI-CLI-Wrappers/` (git-managed, symlinked into `~/.openclaw/workspace/bin`).

## claude.sh

Wraps the Claude Code CLI (`/opt/homebrew/bin/claude`).

**Auth:** OAuth via macOS Keychain. LaunchAgent sessions have Keychain access; SSH sessions do not. A daily LaunchAgent (`ai.openclaw.sync-claude-auth`) verifies the token is valid and sends a Telegram alert on expiry.

**Invocation:**
```bash
# Piped prompt (used by proxy-wrapper subprocess calls)
echo "What is the current BTC price?" | ~/repos/AI-CLI-Wrappers/claude.sh \
    --context-dir ~/.openclaw/workspace \
    --timeout 90 \
    --allow-tools \
    --yolo

# Inline prompt (used by agent exec tool calls)
~/repos/AI-CLI-Wrappers/claude.sh --yolo --timeout 90 "search query here"
```

**Flags:**

| Flag | Purpose |
|------|---------|
| `--context-dir <dir>` | Workspace directory for file ops |
| `--timeout <secs>` | Max execution time |
| `--allow-tools` | Enable web search, file ops, bash execution |
| `--yolo` | Non-interactive mode, auto-approve all tool calls |
| `--model <name>` | Model selection (e.g., opus, sonnet, haiku, or full model name). |

**Response format** (JSON on stdout):
```json
{
  "response": "BTC is currently at $66,800...",
  "session_id": "abc123",
  "token_usage": { "prompt_tokens": 150, "completion_tokens": 200, "total_tokens": 350 },
  "reasoning": "Searched CoinGecko API..."
}
```

**Capabilities:** Web search, file read/write, bash execution, multi-step reasoning. Claude has its own tool use pipeline internally — `--allow-tools` unlocks it.

## codex.sh

Wraps the OpenAI Codex CLI.

**Auth:** OAuth token stored in `~/.codex/auth.json` (ChatGPT Pro subscription). Run `codex auth login` to generate.

**Invocation:**
```bash
# Piped prompt
echo "Generate a social media post about..." | ~/repos/AI-CLI-Wrappers/codex.sh --yolo

# Inline prompt
~/repos/AI-CLI-Wrappers/codex.sh --full-auto "content generation task"
```

**Flags:**

| Flag | Purpose |
|------|---------|
| `--yolo` | Non-interactive mode |
| `--full-auto` | Auto-approve all actions (codex equivalent of --yolo) |
| `--context-dir <dir>` | Workspace directory |
| `--model <name>` | Model selection (e.g., opus, sonnet, haiku, or full model name). |


Note: codex.sh does **not** support `--timeout` — the proxy-wrapper handles timeout enforcement externally via process group kill.

**Response format** (JSON on stdout):
```json
{
  "response": "Here's the generated content...",
  "session_id": "def456",
  "token_usage": { "prompt_tokens": 100, "completion_tokens": 300, "total_tokens": 400 }
}
```

## How OpenClaw Uses Them

The wrappers are invoked in two ways:

**1. Via go-proxy-wrapper (port 1239)** — for agents whose configured model is a cloud provider. The proxy-wrapper receives an OpenAI-compatible `/v1/chat/completions` request, routes by model name (`"claude"` in name → claude.sh, else → codex.sh), spawns the wrapper as a subprocess, pipes the prompt to stdin, and translates the JSON response back to OpenAI format.

**2. Via exec tool call** — for other agents that decide to delegate. The agent reads a `SKILL.md` in its workspace (e.g., the `claude-code` skill) that describes when and how to call the wrapper. Agent generates an exec tool call, the gateway runs the subprocess directly, and feeds the result back into the conversation.

## Setup

1. Clone `AI-CLI-Wrappers` to `~/repos/AI-CLI-Wrappers/`
2. Symlink into workspace: `ln -s ~/repos/AI-CLI-Wrappers ~/.openclaw/workspace/bin`
3. **Claude auth:** Run `claude` once interactively in a LaunchAgent context to seed the Keychain
4. **Codex auth:** Run `codex auth login` to generate `~/.codex/auth.json`
5. Verify wrappers work standalone:
```bash
echo "Hello" | ~/repos/AI-CLI-Wrappers/claude.sh --yolo --timeout 30
echo "Hello" | ~/repos/AI-CLI-Wrappers/codex.sh --yolo
```

## Models (*args allowed --model <Name>*)

| Wrapper | Model | Subscription |
|---------|-------|-------------|
| claude.sh | Claude OPUS 4.6 (`claude-opus-4-6-20250929`) | Anthropic Max |
| codex.sh | GPT-5.4 | ChatGPT Pro |
