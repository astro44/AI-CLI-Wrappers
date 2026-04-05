// Author: Robert C, oxygenchain — https://oxygenchain.earth
// Helping ensure clean water for everyone.
//
// SPDX-License-Identifier: MIT
// See LICENSE in this directory for the full MIT license text.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// --- Configuration ---

var (
	listenAddr    = envOr("PROXY_WRAPPER_PORT", ":1239")
	codexPath     = envOr("CODEX_CLI_PATH", "/Users/astrix/repos/AI-CLI-Wrappers/codex.sh")
	claudePath    = envOr("CLAUDE_CLI_PATH", "/Users/astrix/repos/AI-CLI-Wrappers/claude.sh")
	workDir       = envOr("CLI_WORK_DIR", "/Users/astrix/.openclaw/workspace")
	cliTimeout    = envOrInt("CLI_TIMEOUT_SECS", 120)
	debug         = os.Getenv("PROXY_WRAPPER_DEBUG") == "1"
	costPauseFile = envOr("COST_PAUSE_FILE", "/Users/astrix/.openclaw/scripts/.cost_paused")
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envOrInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	var n int
	if _, err := fmt.Sscanf(v, "%d", &n); err != nil {
		return fallback
	}
	return n
}

// --- Types ---

// OpenAI-compatible request
type ChatRequest struct {
	Model       string        `json:"model"`
	Messages    []ChatMessage `json:"messages"`
	MaxTokens   int           `json:"max_tokens,omitempty"`
	Temperature *float64      `json:"temperature,omitempty"`
	Stream      bool          `json:"stream,omitempty"`
}

type ChatMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"` // string or array
}

func (m *ChatMessage) Text() string {
	switch v := m.Content.(type) {
	case string:
		return v
	case []any:
		var parts []string
		for _, item := range v {
			if obj, ok := item.(map[string]any); ok {
				if t, ok := obj["text"].(string); ok {
					parts = append(parts, t)
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		return fmt.Sprintf("%v", m.Content)
	}
}

// OpenAI-compatible response
type ChatResponse struct {
	ID      string         `json:"id"`
	Object  string         `json:"object"`
	Created int64          `json:"created"`
	Model   string         `json:"model"`
	Choices []ChatChoice   `json:"choices"`
	Usage   *ChatUsage     `json:"usage,omitempty"`
}

type ChatChoice struct {
	Index        int         `json:"index"`
	Message      ChatMessage `json:"message"`
	FinishReason string      `json:"finish_reason"`
}

type ChatUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// CLI wrapper JSON envelope
type CLIResponse struct {
	Response   string          `json:"response"`
	SessionID  string          `json:"session_id"`
	Error      string          `json:"error"`
	ErrorType  string          `json:"error_type"`
	ExitCode   int             `json:"exit_code"`
	TokenUsage *CLITokenUsage  `json:"token_usage"`
}

type CLITokenUsage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
	TotalTokens  int `json:"total_tokens"`
}

// --- Stats ---

type Stats struct {
	RequestsTotal   int64
	RequestsOK      int64
	RequestsError   int64
	CodexCalls      int64
	ClaudeCalls     int64
	StartTime       time.Time
}

var stats = Stats{StartTime: time.Now()}

// --- Semaphores (concurrent CLI slots) ---

var (
	codexSem  = make(chan struct{}, 3)
	claudeSem = make(chan struct{}, 3)
)

// --- Child process tracking ---

type trackedChild struct {
	Cmd     *exec.Cmd
	Started time.Time
}

var (
	childMu    sync.Mutex
	childProcs = map[int]*trackedChild{}
)

func trackChild(cmd *exec.Cmd) {
	childMu.Lock()
	defer childMu.Unlock()
	if cmd.Process != nil {
		childProcs[cmd.Process.Pid] = &trackedChild{Cmd: cmd, Started: time.Now()}
	}
}

func untrackChild(cmd *exec.Cmd) {
	childMu.Lock()
	defer childMu.Unlock()
	if cmd.Process != nil {
		delete(childProcs, cmd.Process.Pid)
	}
}

func killAllChildren() {
	childMu.Lock()
	defer childMu.Unlock()
	for pid, tc := range childProcs {
		log.Printf("killing child pid=%d", pid)
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = tc.Cmd.Process.Kill()
	}
}

// reapOrphans periodically checks for tracked children that have been running
// longer than maxAge and kills their process group. Catches processes that
// escaped normal cleanup (e.g. handler goroutine stuck on cmd.Wait).
func reapOrphans(maxAge time.Duration) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		childMu.Lock()
		for pid, tc := range childProcs {
			// Check if process is still alive
			if err := tc.Cmd.Process.Signal(syscall.Signal(0)); err != nil {
				log.Printf("[reaper] removing dead child pid=%d", pid)
				delete(childProcs, pid)
				continue
			}
			age := time.Since(tc.Started)
			if age > maxAge {
				log.Printf("[reaper] killing orphan pid=%d age=%s (max %s)", pid, age.Round(time.Second), maxAge)
				_ = syscall.Kill(-pid, syscall.SIGTERM)
				go func(p int) {
					time.Sleep(3 * time.Second)
					_ = syscall.Kill(-p, syscall.SIGKILL)
				}(pid)
				delete(childProcs, pid)
			}
		}
		childMu.Unlock()
	}
}

// --- Cost Guard ---

func isCostPaused() bool {
	_, err := os.Stat(costPauseFile)
	return err == nil
}

// --- Router ---

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	log.Printf("go-proxy-wrapper starting on %s", listenAddr)
	log.Printf("  codex.sh: %s", codexPath)
	log.Printf("  claude.sh: %s", claudePath)
	log.Printf("  timeout: %ds, concurrency: %d per CLI, debug: %v", cliTimeout, cap(codexSem), debug)

	// Start orphan reaper — kills any tracked child older than 2x the CLI timeout
	go reapOrphans(time.Duration(cliTimeout*2) * time.Second)

	// Verify CLI scripts exist
	for name, path := range map[string]string{"codex.sh": codexPath, "claude.sh": claudePath} {
		if _, err := os.Stat(path); err != nil {
			log.Printf("WARNING: %s not found at %s: %v", name, path, err)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", handleChat)
	mux.HandleFunc("/v1/models", handleModels)
	mux.HandleFunc("/proxy/health", handleHealth)
	mux.HandleFunc("/proxy/stats", handleStats)
	mux.HandleFunc("/proxy/usage", handleUsage)

	server := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // disabled — CLI calls can take minutes
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
		sig := <-sigCh
		log.Printf("received %v, shutting down", sig)
		killAllChildren()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
	log.Printf("shutdown complete")
}

// --- Handlers ---

func handleChat(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&stats.RequestsTotal, 1)
	start := time.Now()

	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 10*1024*1024)) // 10MB limit
	if err != nil {
		httpError(w, http.StatusBadRequest, "failed to read body: %v", err)
		return
	}

	var req ChatRequest
	if err := json.Unmarshal(body, &req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid JSON: %v", err)
		return
	}

	// Cost guard — reject if daily budget exhausted
	if isCostPaused() {
		log.Printf("PAUSED model=%q — daily API budget exhausted (flag: %s)", req.Model, costPauseFile)
		httpError(w, http.StatusTooManyRequests, "Daily API budget exhausted. Remove %s to resume.", costPauseFile)
		return
	}

	// Route by model name
	var cliPath string
	var sem chan struct{}
	var extraArgs []string
	model := strings.ToLower(req.Model)
	switch {
	case strings.Contains(model, "claude"):
		cliPath = claudePath
		sem = claudeSem
		atomic.AddInt64(&stats.ClaudeCalls, 1)
		// Enable tools for Claude CLI (WebSearch, WebFetch, etc.)
		extraArgs = []string{"--allow-tools", "--yolo"}
	default:
		// Default to codex for gpt-*, codex, or anything else
		cliPath = codexPath
		sem = codexSem
		atomic.AddInt64(&stats.CodexCalls, 1)
		extraArgs = []string{"--yolo"}
	}

	if debug {
		log.Printf("REQUEST model=%q route=%s messages=%d", req.Model, cliPath, len(req.Messages))
	}

	// Build prompt from messages
	prompt := buildPrompt(req.Messages)

	// Acquire semaphore
	select {
	case sem <- struct{}{}:
		defer func() { <-sem }()
	case <-r.Context().Done():
		httpError(w, http.StatusGatewayTimeout, "request cancelled while queued")
		return
	}

	// Execute CLI
	cliResp, err := execCLI(r.Context(), cliPath, prompt, cliTimeout, extraArgs)
	latencyMs := time.Since(start).Milliseconds()

	if err != nil {
		atomic.AddInt64(&stats.RequestsError, 1)
		if strings.Contains(err.Error(), "context deadline exceeded") || strings.Contains(err.Error(), "signal: killed") {
			log.Printf("TIMEOUT model=%q latency=%dms err=%v", req.Model, latencyMs, err)
			httpError(w, http.StatusGatewayTimeout, "CLI timeout after %ds", cliTimeout)
		} else {
			log.Printf("ERROR model=%q latency=%dms err=%v", req.Model, latencyMs, err)
			httpError(w, http.StatusBadGateway, "CLI error: %v", err)
		}
		return
	}

	atomic.AddInt64(&stats.RequestsOK, 1)
	log.Printf("OK model=%q stream=%v latency=%dms response_len=%d", req.Model, req.Stream, latencyMs, len(cliResp.Response))

	id := fmt.Sprintf("pw-%d", time.Now().UnixNano())
	now := time.Now().Unix()

	if req.Stream {
		writeSSEResponse(w, id, now, req.Model, cliResp)
	} else {
		writeJSONResponse(w, id, now, req.Model, cliResp)
	}
}

func writeJSONResponse(w http.ResponseWriter, id string, created int64, model string, cliResp *CLIResponse) {
	resp := ChatResponse{
		ID:      id,
		Object:  "chat.completion",
		Created: created,
		Model:   model,
		Choices: []ChatChoice{
			{
				Index: 0,
				Message: ChatMessage{
					Role:    "assistant",
					Content: cliResp.Response,
				},
				FinishReason: "stop",
			},
		},
	}

	if cliResp.TokenUsage != nil {
		resp.Usage = &ChatUsage{
			PromptTokens:     cliResp.TokenUsage.InputTokens,
			CompletionTokens: cliResp.TokenUsage.OutputTokens,
			TotalTokens:      cliResp.TokenUsage.TotalTokens,
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func writeSSEResponse(w http.ResponseWriter, id string, created int64, model string, cliResp *CLIResponse) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	flusher, _ := w.(http.Flusher)

	// Chunk 1: role delta
	roleChunk := map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": created,
		"model":   model,
		"choices": []map[string]any{
			{
				"index":         0,
				"delta":         map[string]any{"role": "assistant", "content": ""},
				"finish_reason": nil,
			},
		},
	}
	writeSSEChunk(w, roleChunk)
	if flusher != nil {
		flusher.Flush()
	}

	// Chunk 2: content delta (entire response in one chunk)
	contentChunk := map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": created,
		"model":   model,
		"choices": []map[string]any{
			{
				"index":         0,
				"delta":         map[string]any{"content": cliResp.Response},
				"finish_reason": nil,
			},
		},
	}
	writeSSEChunk(w, contentChunk)
	if flusher != nil {
		flusher.Flush()
	}

	// Chunk 3: finish
	finishChunk := map[string]any{
		"id":      id,
		"object":  "chat.completion.chunk",
		"created": created,
		"model":   model,
		"choices": []map[string]any{
			{
				"index":         0,
				"delta":         map[string]any{},
				"finish_reason": "stop",
			},
		},
	}
	if cliResp.TokenUsage != nil {
		finishChunk["usage"] = map[string]any{
			"prompt_tokens":     cliResp.TokenUsage.InputTokens,
			"completion_tokens": cliResp.TokenUsage.OutputTokens,
			"total_tokens":      cliResp.TokenUsage.TotalTokens,
		}
	}
	writeSSEChunk(w, finishChunk)
	fmt.Fprintf(w, "data: [DONE]\n\n")
	if flusher != nil {
		flusher.Flush()
	}
}

func writeSSEChunk(w http.ResponseWriter, chunk any) {
	data, _ := json.Marshal(chunk)
	fmt.Fprintf(w, "data: %s\n\n", data)
}

func handleModels(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"object": "list",
		"data": []map[string]any{
			{
				"id":       "gpt-5.4",
				"object":   "model",
				"owned_by": "proxy-wrapper",
			},
			{
				"id":       "claude-sonnet-4-5",
				"object":   "model",
				"owned_by": "proxy-wrapper",
			},
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"status":  "ok",
		"uptime":  time.Since(stats.StartTime).String(),
		"codex":   codexPath,
		"claude":  claudePath,
		"port":    listenAddr,
		"concurrency": map[string]any{
			"codex_busy":  len(codexSem),
			"codex_max":   cap(codexSem),
			"claude_busy": len(claudeSem),
			"claude_max":  cap(claudeSem),
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	childMu.Lock()
	activeChildren := len(childProcs)
	childMu.Unlock()
	resp := map[string]any{
		"uptime_seconds":   int(time.Since(stats.StartTime).Seconds()),
		"requests_total":   atomic.LoadInt64(&stats.RequestsTotal),
		"requests_ok":      atomic.LoadInt64(&stats.RequestsOK),
		"requests_error":   atomic.LoadInt64(&stats.RequestsError),
		"codex_calls":      atomic.LoadInt64(&stats.CodexCalls),
		"claude_calls":     atomic.LoadInt64(&stats.ClaudeCalls),
		"codex_busy":       len(codexSem),
		"codex_max":        cap(codexSem),
		"claude_busy":      len(claudeSem),
		"claude_max":       cap(claudeSem),
		"active_children":  activeChildren,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleUsage(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	cutoff := now.Add(-24 * time.Hour)

	// Parse proxy-wrapper log for paid API calls (Tier 2)
	paidCalls := parseProxyWrapperLog(cutoff)

	// Parse go-contextor proxy log for Qwen calls (Tier 1 / free)
	qwenCalls := parseContextorLog(cutoff)

	resp := map[string]any{
		"period":       "24h",
		"since":        cutoff.Format(time.RFC3339),
		"cost_paused":  isCostPaused(),
		"tier1_free":   qwenCalls,
		"tier2_paid":   paidCalls,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func parseProxyWrapperLog(cutoff time.Time) map[string]any {
	logPath := envOr("PROXY_WRAPPER_LOG", "/Users/astrix/.openclaw/logs/proxy-wrapper.log")
	data, err := os.ReadFile(logPath)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}

	var codexCalls, claudeCalls int
	var codexChars, claudeChars int
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.Contains(line, " OK ") {
			continue
		}
		// Parse timestamp: "2026/03/25 12:26:06.123456"
		ts, err := parseLogTimestamp(line)
		if err != nil || ts.Before(cutoff) {
			continue
		}
		// Extract model and response_len
		model := extractField(line, "model=")
		respLen := extractFieldInt(line, "response_len=")
		if strings.Contains(model, "claude") {
			claudeCalls++
			claudeChars += respLen
		} else {
			codexCalls++
			codexChars += respLen
		}
	}

	return map[string]any{
		"codex_calls":        codexCalls,
		"codex_output_chars": codexChars,
		"claude_calls":       claudeCalls,
		"claude_output_chars": claudeChars,
		"total_calls":        codexCalls + claudeCalls,
	}
}

func parseContextorLog(cutoff time.Time) map[string]any {
	logPath := envOr("CONTEXTOR_LOG", "/Users/astrix/.openclaw/logs/proxy.log")
	data, err := os.ReadFile(logPath)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}

	var calls int
	var totalInputTokens, totalOutputTokens int
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.Contains(line, "[req] OK") {
			continue
		}
		// Parse timestamp: "2026/03/25 09:10:35"
		ts, err := parseLogTimestamp(line)
		if err != nil || ts.Before(cutoff) {
			continue
		}
		calls++
		totalInputTokens += extractFieldInt(line, "in=")
		totalOutputTokens += extractFieldInt(line, "out=")
	}

	return map[string]any{
		"model":              "qwen3-coder-30b-a3b (local)",
		"calls":             calls,
		"input_tokens":      totalInputTokens,
		"output_tokens":     totalOutputTokens,
		"total_tokens":      totalInputTokens + totalOutputTokens,
		"cost_usd":          0,
	}
}

func parseLogTimestamp(line string) (time.Time, error) {
	// Format: "2026/03/25 12:26:06" (with optional microseconds)
	if len(line) < 19 {
		return time.Time{}, fmt.Errorf("line too short")
	}
	tsStr := line[:19]
	t, err := time.ParseInLocation("2006/01/02 15:04:05", tsStr, time.Local)
	if err != nil {
		return time.Time{}, err
	}
	return t, nil
}

func extractField(line, prefix string) string {
	idx := strings.Index(line, prefix)
	if idx < 0 {
		return ""
	}
	rest := line[idx+len(prefix):]
	// Handle quoted values: model="claude-sonnet-4-5"
	if len(rest) > 0 && rest[0] == '"' {
		end := strings.IndexByte(rest[1:], '"')
		if end >= 0 {
			return rest[1 : end+1]
		}
	}
	// Unquoted: find next space
	end := strings.IndexByte(rest, ' ')
	if end < 0 {
		return rest
	}
	return rest[:end]
}

func extractFieldInt(line, prefix string) int {
	s := extractField(line, prefix)
	var n int
	fmt.Sscanf(s, "%d", &n)
	return n
}

// --- Prompt Builder ---

func buildPrompt(messages []ChatMessage) string {
	var b strings.Builder
	for _, msg := range messages {
		text := msg.Text()
		if text == "" {
			continue
		}
		switch msg.Role {
		case "system":
			b.WriteString("[system]\n")
			b.WriteString(text)
			b.WriteString("\n\n")
		case "user":
			b.WriteString("[user]\n")
			b.WriteString(text)
			b.WriteString("\n\n")
		case "assistant":
			b.WriteString("[assistant]\n")
			b.WriteString(text)
			b.WriteString("\n\n")
		default:
			b.WriteString(fmt.Sprintf("[%s]\n", msg.Role))
			b.WriteString(text)
			b.WriteString("\n\n")
		}
	}
	return strings.TrimSpace(b.String())
}

// --- CLI Executor ---

func execCLI(ctx context.Context, cliPath, prompt string, timeoutSecs int, extraArgs []string) (*CLIResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutSecs)*time.Second)
	defer cancel()

	args := []string{
		"--context-dir", workDir,
		"--timeout", fmt.Sprintf("%d", timeoutSecs-5),
	}
	args = append(args, extraArgs...)

	// Use exec.Command (not CommandContext) — we handle cancellation ourselves
	// via process group kill, which is more thorough than CommandContext's SIGKILL
	cmd := exec.Command(cliPath, args...)
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Dir = workDir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Capture stdout and stderr separately
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// Set HOME so CLI wrappers can find their auth/config
	cmd.Env = append(os.Environ(),
		"HOME=/Users/astrix",
		"PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
	)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start CLI: %w", err)
	}

	trackChild(cmd)

	// Wait for process OR context cancellation (client disconnect / timeout)
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	var err error
	select {
	case err = <-waitCh:
		// Process finished normally
	case <-ctx.Done():
		// Context cancelled — kill the entire process group
		if cmd.Process != nil {
			pgid := cmd.Process.Pid
			log.Printf("[exec] context cancelled, killing process group pgid=%d reason=%v", pgid, ctx.Err())
			_ = syscall.Kill(-pgid, syscall.SIGTERM)
			// Give it 3s to die gracefully, then SIGKILL
			select {
			case err = <-waitCh:
			case <-time.After(3 * time.Second):
				_ = syscall.Kill(-pgid, syscall.SIGKILL)
				err = <-waitCh
			}
		}
		if err == nil {
			err = ctx.Err()
		}
	}

	untrackChild(cmd)

	if debug {
		log.Printf("CLI stdout (%d bytes): %s", stdout.Len(), truncate(stdout.String(), 500))
		if stderr.Len() > 0 {
			log.Printf("CLI stderr (%d bytes): %s", stderr.Len(), truncate(stderr.String(), 500))
		}
	}

	if err != nil {
		// Check if stderr has useful info
		errMsg := strings.TrimSpace(stderr.String())
		if errMsg == "" {
			errMsg = err.Error()
		}
		// If we got stdout despite error exit code, try to parse it
		if stdout.Len() > 0 {
			resp, parseErr := parseCLIOutput(stdout.String())
			if parseErr == nil && resp.Error != "" {
				return nil, fmt.Errorf("%s: %s", resp.ErrorType, resp.Error)
			}
			if parseErr == nil && resp.Response != "" {
				// Got a valid response despite non-zero exit — use it
				return resp, nil
			}
		}
		return nil, fmt.Errorf("CLI exited with error: %s", errMsg)
	}

	return parseCLIOutput(stdout.String())
}

func parseCLIOutput(raw string) (*CLIResponse, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("empty CLI output")
	}

	// Try to parse as JSON envelope
	var resp CLIResponse
	if err := json.Unmarshal([]byte(raw), &resp); err == nil {
		if resp.Error != "" {
			return nil, fmt.Errorf("%s: %s", resp.ErrorType, resp.Error)
		}
		if resp.Response != "" {
			return &resp, nil
		}
	}

	// Try to find JSON object in output (wrappers may emit log lines before JSON)
	if idx := strings.Index(raw, "{\"response\""); idx >= 0 {
		jsonStr := raw[idx:]
		// Find matching closing brace
		if end := findClosingBrace(jsonStr); end > 0 {
			if err := json.Unmarshal([]byte(jsonStr[:end+1]), &resp); err == nil {
				if resp.Error != "" {
					return nil, fmt.Errorf("%s: %s", resp.ErrorType, resp.Error)
				}
				if resp.Response != "" {
					return &resp, nil
				}
			}
		}
	}

	// Fallback: treat entire output as plain text response
	return &CLIResponse{Response: raw}, nil
}

func findClosingBrace(s string) int {
	depth := 0
	inString := false
	escape := false
	for i, ch := range s {
		if escape {
			escape = false
			continue
		}
		if ch == '\\' && inString {
			escape = true
			continue
		}
		if ch == '"' {
			inString = !inString
			continue
		}
		if inString {
			continue
		}
		if ch == '{' {
			depth++
		} else if ch == '}' {
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// --- Helpers ---

func httpError(w http.ResponseWriter, code int, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	atomic.AddInt64(&stats.RequestsError, 1)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message": msg,
			"type":    "proxy_wrapper_error",
			"code":    code,
		},
	})
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
