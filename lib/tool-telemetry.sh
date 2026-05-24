#!/usr/bin/env bash
# Shared best-effort tool-call telemetry extraction for Autonom8 CLI wrappers.

autonom8_tool_activity_json() {
  local raw_output="${1:-}"
  local stream_output="${2:-}"
  local source="${3:-wrapper}"
  local combined="${raw_output}"$'\n'"${stream_output}"

  if [[ -z "$(printf "%s" "$combined" | tr -d '[:space:]')" ]]; then
    jq -cn --arg source "$source" '{call_count:0, write_count:0, error_count:0, error_classes:[], tool_names:[], result_classes:[], first_tool_at:"", last_tool_at:"", activity_class:"none", source:$source}'
    return 0
  fi

  jq -cn --arg raw "$combined" --arg source "$source" '
    def lname: tostring | ascii_downcase;
    def now_iso: (now | strftime("%Y-%m-%dT%H:%M:%SZ"));
    def timestamp_string:
      if . == null then empty
      elif type == "string" then select(length > 0)
      elif type == "number" then
        (if . > 100000000000 then (. / 1000) else . end | strftime("%Y-%m-%dT%H:%M:%SZ"))
      else empty
      end;
    def compact_name:
      tostring
      | gsub("^functions\\."; "")
      | gsub("^mcp__"; "")
      | gsub("__"; ".")
      | gsub("[^A-Za-z0-9_.:-]"; "_")
      | select(length > 0);
    def classify_error_text:
      (tostring | ascii_downcase) as $t
      | if $t == "" then empty
        elif ($t | test("permission|denied|forbidden|unauthorized|not allowed")) then "permission"
        elif ($t | test("scope|outside allowed|out of scope|not in scope")) then "scope"
        elif ($t | test("validation|invalid|schema|malformed|parse")) then "validation"
        elif ($t | test("timeout|timed out|deadline")) then "timeout"
        elif ($t | test("not[ _-]?found|missing|no such file|does not exist")) then "not_found"
        elif ($t | test("network|fetch|dns|connection|econn|socket")) then "infra"
        elif ($t | test("provider|quota|rate limit|credit balance|api")) then "provider"
        else "other"
        end;
    def docs:
      (try ($raw | fromjson) catch null) as $whole
      | if $whole != null then
          [$whole]
        else
          ($raw | split("\n") | map((try fromjson catch null) | select(. != null)))
        end;
    def cursor_tool_call_name:
      if ((.tool_call? | type) == "object") then
        if ((.tool_call.editToolCall? | type) == "object") then "editToolCall"
        elif ((.tool_call.multiEditToolCall? | type) == "object") then "multiEditToolCall"
        elif ((.tool_call.readToolCall? | type) == "object") then "readToolCall"
        elif ((.tool_call.grepToolCall? | type) == "object") then "grepToolCall"
        elif ((.tool_call.listDirToolCall? | type) == "object") then "listDirToolCall"
        elif ((.tool_call.searchToolCall? | type) == "object") then "searchToolCall"
        elif ((.tool_call.terminalToolCall? | type) == "object") then "terminalToolCall"
        elif ((.tool_call.runCommandToolCall? | type) == "object") then "runCommandToolCall"
        elif ((.tool_call.shellToolCall? | type) == "object") then "shellToolCall"
        elif ((.tool_call? | keys | length) > 0) then (.tool_call | keys[0])
        else empty
        end
      else
        empty
      end;
    def call_name_from_object:
      if ((.toolCalls? | type) == "array") then
        .toolCalls[]? | (.name // .functionName // .function.name // .toolName // empty)
      elif ((.tool_calls? | type) == "array") then
        .tool_calls[]? | (.name // .function.name // .functionName // .toolName // empty)
      elif ((.functionCall? | type) == "object") then
        .functionCall.name // .functionCall.functionName // empty
      elif ((.function_call? | type) == "object") then
        .function_call.name // .function_call.function.name // empty
      elif ((.tool_call? | type) == "object") then
        cursor_tool_call_name
      elif (((.type? // .payload.type? // "") | lname) | test("(^tool$)|tool_use|tool_call|function_call|tool-call|tool.start|tool_start")) then
        .name // .tool // .tool_name // .toolName // .function.name // .payload.name // .payload.tool // .payload.tool_name // .payload.toolName // empty
      else
        empty
      end;
    def timestamp_from_object:
      (
        .timestamp
        // .time_created
        // .created_at
        // .createdAt
        // .started_at
        // .startedAt
        // .completed_at
        // .completedAt
        // .time.start
        // .time.end
        // .state.time_created
        // .state.created_at
        // .state.completed_at
        // .payload.timestamp
        // .payload.time_created
        // .payload.created_at
        // .payload.createdAt
        // empty
      )
      | timestamp_string;
    def json_names:
      [
        docs[]
        | .. | objects
        | call_name_from_object
        | compact_name
      ];
    def json_tool_events:
      [
        docs[]
        | .. | objects
        | . as $obj
        | ($obj | call_name_from_object | compact_name) as $name
        | select($name != null and ($name | length) > 0)
        | {name: $name, timestamp: (($obj | timestamp_from_object) // "")}
      ];
    def stream_names:
      [
        $raw
        | scan("(?i)(?:Tool|tool|function|mcp)[[:space:]]+([A-Za-z0-9_.:-]+)[[:space:]]+(?:executed|called|started|completed|failed)")
        | .[0]
        | compact_name
      ];
    def names: (json_names + stream_names);
    def class_for($name):
      ($name | lname) as $n
      | if ($n | test("apply_patch|write|edit|multi_edit|replace|create|delete|remove|move|rename|insert")) then "write"
        elif ($n | test("read|cat|open|view|list|ls|find|grep|rg|search")) then "read"
        elif ($n | test("browser|playwright|screenshot|page|dom|axe|lighthouse")) then "browser"
        elif ($n | test("web|fetch|http|url|search_query")) then "web"
        elif ($n | test("exec|bash|shell|command|terminal")) then "shell"
        else "other"
        end;
    def json_error_count:
      [
        docs[]
        | .. | objects
        | select(
            ((.is_error? // false) == true)
            or ((.ok? // true) == false)
            or (((.status? // .state.status? // .result? // "") | lname) | test("error|failed|failure"))
            or (((.error? // "") | tostring | length) > 0)
          )
      ] | length;
    def error_text_from_object:
      [
        (.error_type // empty),
        (.error.code // empty),
        (.code // empty),
        (.status // .state.status? // empty),
        (.message // empty),
        (.error // empty),
        (.payload.error // empty),
        (.payload.message // empty)
      ] | map(tostring) | map(select(length > 0)) | join(" | ");
    def json_error_classes:
      [
        docs[]
        | .. | objects
        | select(
            ((.is_error? // false) == true)
            or ((.ok? // true) == false)
            or (((.status? // .state.status? // .result? // "") | lname) | test("error|failed|failure"))
            or (((.error? // "") | tostring | length) > 0)
          )
        | (error_text_from_object | select(length > 0) | classify_error_text)
      ];
    def path_like:
      tostring
      | gsub("^file://"; "")
      | gsub("[\"`,;:]+$"; "")
      | select(length > 0)
      | select(
          test("(^|/)(src|tests?|public|app|pages|components|styles|lib|pkg|cmd|internal|go-autonom8|tenants|data|docs?)/")
          or test("\\.(go|js|jsx|mjs|cjs|ts|tsx|css|scss|html|json|md|yaml|yml|sh|py|dart|swift|kt|java|rs|tf|sol|sql)$")
        );
    def object_path_values:
      [
        .path?,
        .file?,
        .file_path?,
        .filepath?,
        .filename?,
        .relative_path?,
        .absolute_path?,
        .uri?,
        .input.path?,
        .input.file?,
        .input.file_path?,
        .input.filepath?,
        .input.filename?,
        .input.relative_path?,
        .input.absolute_path?,
        .input.uri?,
        (.tool_call? | objects | .. | objects | .path?),
        (.tool_call? | objects | .. | objects | .file?),
        (.tool_call? | objects | .. | objects | .file_path?),
        (.tool_call? | objects | .. | objects | .filepath?),
        (.tool_call? | objects | .. | objects | .filename?),
        (.tool_call? | objects | .. | objects | .relative_path?),
        (.tool_call? | objects | .. | objects | .absolute_path?),
        (.tool_call? | objects | .. | objects | .uri?),
        (.tool_call? | objects | .. | objects | .cwd?)
      ]
      | map(select(. != null) | path_like);
    def json_file_paths:
      [
        docs[]
        | .. | objects
        | object_path_values[]
      ];
    def object_command_values:
      [
        .command?,
        .cmd?,
        .input.command?,
        .input.cmd?,
        .input.shell_command?,
        .input.script?,
        .args.command?,
        .args.cmd?,
        (.tool_call? | objects | .. | objects | .command?),
        (.tool_call? | objects | .. | objects | .cmd?),
        (.tool_call? | objects | .. | objects | .shell_command?),
        (.tool_call? | objects | .. | objects | .script?)
      ]
      | map(select(. != null) | tostring | gsub("[[:space:]]+"; " ") | gsub("^\\s+|\\s+$"; "") | select(length > 0));
    def json_commands:
      [
        docs[]
        | .. | objects
        | object_command_values[]
      ];
    def stream_error_classes:
      [
        (if ($raw | test("(?i)tool[^\\n]{0,120}(permission|denied|forbidden|unauthorized|not allowed)")) then "permission" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(out of scope|outside allowed|not in scope|scope)")) then "scope" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(validation|invalid|schema|malformed|parse)")) then "validation" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(timeout|timed out|deadline)")) then "timeout" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(not found|missing|no such file|does not exist)")) then "not_found" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(network|fetch|dns|connection|econn|socket)")) then "infra" else empty end),
        (if ($raw | test("(?i)tool[^\\n]{0,120}(provider|quota|rate limit|credit balance|api)")) then "provider" else empty end)
      ];
    (names | unique) as $unique_names
    | ([$unique_names[] | class_for(.)] | unique) as $classes
    | ((json_error_classes + stream_error_classes) | map(select(length > 0)) | unique) as $error_classes
    | (names | map(select(class_for(.) == "write")) | length) as $write_count
    | (names | map(select(class_for(.) == "read")) | length) as $read_count
    | (json_commands | unique) as $commands_run
    | ($commands_run | length) as $command_count
    | (json_file_paths | unique | .[:20]) as $file_paths
    | (json_error_count + ([$raw | scan("(?i)tool[^\\n]{0,80}(?:error|failed|failure)")] | length)) as $errors
    | ([json_tool_events[]?.timestamp | select(length > 0)] | sort) as $timestamps
    | (names | length) as $call_count
    | (if ($timestamps | length) > 0 then $timestamps[0] elif $call_count > 0 then now_iso else "" end) as $first_tool_at
    | (if ($timestamps | length) > 0 then $timestamps[-1] elif $call_count > 0 then now_iso else "" end) as $last_tool_at
    | {
        call_count: $call_count,
        write_count: $write_count,
        read_count: $read_count,
        command_count: $command_count,
        tool_write_count: $write_count,
        tool_read_count: $read_count,
        commands_run_count: $command_count,
        error_count: $errors,
        error_classes: $error_classes,
        tool_errors: $error_classes,
        tool_names: $unique_names,
        result_classes: $classes,
        file_paths: $file_paths,
        files_changed: (if $write_count > 0 then $file_paths else [] end),
        files_read: (if $read_count > 0 then $file_paths else [] end),
        commands: ($commands_run | .[:10]),
        commands_run: ($commands_run | .[:10]),
        first_tool_at: $first_tool_at,
        last_tool_at: $last_tool_at,
        activity_class: (
          if $errors > 0 then "tool_errors"
          elif $write_count > 0 then "write_active"
          elif $call_count > 0 then "tool_active"
          else "none"
          end
        ),
        source: $source
      }
  ' 2>/dev/null || jq -cn --arg source "$source" '{call_count:0, write_count:0, error_count:0, error_classes:[], tool_names:[], result_classes:[], first_tool_at:"", last_tool_at:"", activity_class:"none", source:$source}'
}

autonom8_safe_filename_part() {
  printf "%s" "${1:-}" | tr -c 'A-Za-z0-9_.:-' '_' | sed 's/^_*//; s/_*$//; s/__*/_/g'
}

autonom8_persist_tool_activity_json() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 0
  [[ "${AUTONOM8_TOOL_ACTIVITY_SIDECAR:-1}" != "0" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf "%s" "$payload" | jq -e . >/dev/null 2>&1 || return 0

  local work_root="${WORK_DIR:-${WORKSPACE_DIR:-${CONTEXT_DIR:-$(pwd)}}}"
  [[ -n "$work_root" ]] || return 0
  local base_dir="${AUTONOM8_TOOL_ACTIVITY_DIR:-$work_root/.sessions/tool_activity}"
  mkdir -p "$base_dir" 2>/dev/null || return 0

  local session_id req_id provider workflow ticket file tmp
  session_id="$(printf "%s" "$payload" | jq -r '.session_id // .metadata.wrapper_context.session_id // empty' 2>/dev/null || true)"
  req_id="$(printf "%s" "$payload" | jq -r '.request_id // .metadata.wrapper_context.request_id // empty' 2>/dev/null || true)"
  provider="$(printf "%s" "$payload" | jq -r '.provider // .metadata.wrapper_context.provider // empty' 2>/dev/null || true)"
  workflow="$(printf "%s" "$payload" | jq -r '.workflow // .metadata.wrapper_context.workflow // empty' 2>/dev/null || true)"
  ticket="$(printf "%s" "$payload" | jq -r '.ticket_id // .metadata.wrapper_context.ticket_id // empty' 2>/dev/null || true)"
  [[ -n "$session_id" ]] || session_id="${req_id:-no-session}"

  file="$base_dir/$(autonom8_safe_filename_part "$session_id").json"
  tmp="${file}.$$"
  printf "%s" "$payload" | jq \
    --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)" \
    --arg session_id "$session_id" \
    --arg request_id "$req_id" \
    --arg provider "$provider" \
    --arg workflow "$workflow" \
    --arg ticket_id "$ticket" '
      (.metadata.tool_activity // {}) as $ta
      | {
          captured_at: $captured_at,
          provider: $provider,
          session_id: $session_id,
          request_id: $request_id,
          workflow: $workflow,
          ticket_id: $ticket_id,
          tool_activity: ($ta + {source: (($ta.source // "sidecar") | tostring)})
        }
    ' > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}


autonom8_provider_context_json() {
  local provider="${AUTONOM8_PROVIDER:-${A8_PROVIDER:-}}"
  if [[ -z "$provider" ]]; then
    provider="$(basename "${0:-wrapper}")"
    provider="${provider%.sh}"
  fi

  jq -cn \
    --arg provider "$provider" \
    --arg request_id "${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-}}" \
    --arg workflow "${A8_WORKFLOW:-${AUTONOM8_WORKFLOW:-}}" \
    --arg ticket_id "${A8_TICKET_ID:-${AUTONOM8_TICKET_ID:-}}" \
    --arg agent "${A8_AGENT_NAME:-${AUTONOM8_AGENT_NAME:-}}" \
    --arg wrapper "$(basename "${0:-wrapper}")" \
    --arg model_requested "${MODEL_REQUESTED_RAW:-${MODEL:-${AUTONOM8_MODEL:-${A8_MODEL:-}}}}" \
    --arg model_effective "${MODEL:-${AUTONOM8_MODEL:-${A8_MODEL:-}}}" \
    --arg model_resolution "${MODEL_RESOLUTION_NOTE:-}" \
    --arg workspace_scope "${AUTONOM8_PROVIDER_WORKSPACE_SCOPE:-}" \
    --arg process_group_mode "${AUTONOM8_PROCESS_GROUP_MODE:-${AUTONOM8_PROVIDER_PROCESS_GROUP_MODE:-}}" \
    --arg wrapper_timeout_supervision "${AUTONOM8_WRAPPER_TIMEOUT_SUPERVISION:-}" \
    '{
      provider: $provider,
      request_id: $request_id,
      workflow: $workflow,
      ticket_id: $ticket_id,
      agent: $agent,
      wrapper: $wrapper,
      model_requested: $model_requested,
      model_effective: $model_effective,
      model_resolution: $model_resolution,
      workspace_scope: $workspace_scope,
      process_group_mode: $process_group_mode,
      wrapper_timeout_supervision: $wrapper_timeout_supervision
    }'
}

autonom8_enrich_provider_payload_json() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf "%s" "$payload" | jq -e . >/dev/null 2>&1 || return 1

  local ctx_json=""
  ctx_json="$(autonom8_provider_context_json 2>/dev/null)" || return 1

  printf "%s" "$payload" | jq --argjson ctx "$ctx_json" '
    def lower: tostring | ascii_downcase;
    def compact: tostring | gsub("[[:space:]]+"; " ") | if length > 800 then .[0:800] else . end;
    def num: if type == "number" then . else (tonumber? // 0) end;
    def successful_status:
      lower as $s
      | ($s == "ok" or $s == "success" or $s == "succeeded" or $s == "complete" or $s == "completed" or $s == "implemented" or $s == "already_complete" or $s == "approved" or $s == "pass" or $s == "passed" or $s == "verified");
    def response_status:
      if ((.response? // "") | type) == "string" and ((.response? // "") | length) > 0 then
        (.response | fromjson? // {}) as $r
        | if ($r | type) == "object" then (($r.status // $r.decision // "") | tostring) else "" end
      else "" end;
    def observed_status: (.status // .decision // response_status // "");
    def failure_text:
      [
        (.error_type // empty),
        (.metadata.failure_class // empty),
        (.metadata.failure_signal.class // empty),
        (.error // empty),
        (.message // empty),
        (.stderr_tail // empty),
        (.stdout_tail // empty),
        (.model_resolution // empty)
      ] | map(tostring) | map(select(length > 0)) | join(" | ");
    def classify_failure:
	      (failure_text | lower) as $t
	      | if $t == "" and ((observed_status | successful_status) or (.ok? == true) or (.success? == true)) then "none"
	        elif ($t | test("(^|[|[:space:]])invalid_input([|[:space:]]|$)|invalid input|requires .*(file path|session-id|one of)|does not support .*auth mode")) then "invalid_input"
	        elif ($t | test("quota|rate limit|capacity exhausted|resource_exhausted|429|out of usage|increase limits|increase your limit|switch to auto")) then "quota_or_rate_limit"
	        elif ($t | test("wrapper_prompt_as_file|file not found:[[:space:]]*(instructions:|execute the following skill|.*input data|.*persona)")) then "wrapper_prompt_as_file"
	        elif ($t | test("credit balance|billing|account credit|billing account|billing profile|unauthorized|forbidden|authentication failed|invalid api key|invalid_api_key")) then "account_credit_or_profile"
        elif ($t | test("invalid model|unknown model|model.*not.*found|model_not_found")) then "invalid_model"
        elif ($t | test("exit status 143|exit_code.?143|sigterm|terminated")) then "provider_exit_143"
        elif ($t | test("no result|no response|empty response|raw_without_reasoning")) then "provider_no_result"
        elif ($t | test("timeout|timed out|deadline")) then "timeout"
        elif ($t | test("permission|denied|not allowed")) then "permission"
        elif ($t | test("tool|mcp")) then "tool_error"
        elif ((.error? // "") | tostring | length) > 0 then "provider_error"
        else "unknown"
        end;
    def action_for($class):
	      if $class == "quota_or_rate_limit" then "wait_for_quota_reset_or_route_to_available_provider"
	      elif $class == "invalid_input" then "fix_wrapper_invocation_or_provider_config"
	      elif $class == "wrapper_prompt_as_file" then "fix_wrapper_invocation_or_provider_config"
      elif $class == "account_credit_or_profile" then "restore_provider_account_or_keep_hard_unavailable"
      elif $class == "invalid_model" then "refresh_provider_model_config_or_use_cli_default"
      elif $class == "provider_exit_143" then "check_wrapper_process_group_and_workspace_scope"
      elif $class == "provider_no_result" then "fast_fail_or_harvest_productive_disk_progress"
      elif $class == "timeout" then "preserve_long_call_budget_or_harvest_if_productive"
      elif $class == "permission" then "inspect_tool_permissions_and_workspace_scope"
      elif $class == "tool_error" then "inspect_tool_environment_scope_and_mcp_health"
      else "inspect_provider_result"
      end;
    def retryable_for($class):
      ($class == "quota_or_rate_limit" or $class == "provider_no_result" or $class == "timeout" or $class == "provider_exit_143" or $class == "tool_error");
    def retry_after_seconds:
      (failure_text | (capture("(?i)(?<h>[0-9]+)h(?<m>[0-9]+)m(?<s>[0-9]+)s")? // null)) as $hms
      | (failure_text | (capture("(?i)(?<m>[0-9]+)m(?<s>[0-9]+)s")? // null)) as $ms
      | (failure_text | (capture("(?i)(?<s>[0-9]+)s")? // null)) as $s
      | if $hms != null then (($hms.h|tonumber) * 3600 + ($hms.m|tonumber) * 60 + ($hms.s|tonumber))
        elif $ms != null then (($ms.m|tonumber) * 60 + ($ms.s|tonumber))
        elif $s != null then ($s.s|tonumber)
        else 0
        end;
    def token_summary:
      (.tokens_used // {}) as $t
      | {
          input_tokens: (($t.input_tokens // 0) | num),
          output_tokens: (($t.output_tokens // 0) | num),
          total_tokens: (($t.total_tokens // 0) | num),
          cost_usd: (($t.cost_usd // 0) | num),
          estimated_output_tokens: (($t.estimated_output_tokens // 0) | num)
        }
      | if .total_tokens <= 0 then .total_tokens = (.input_tokens + .output_tokens) else . end
      | . + {output_input_ratio: (if .input_tokens > 0 then (.output_tokens / .input_tokens) else 0 end), zero_output: (.output_tokens == 0)};
    def tool_summary:
      (.metadata.tool_activity // {}) as $ta
      | {
          call_count: (($ta.call_count // 0) | num),
          write_count: (($ta.write_count // 0) | num),
          error_count: (($ta.error_count // 0) | num),
          activity_class: (($ta.activity_class // "none") | tostring),
          error_classes: (($ta.error_classes // []) | if type == "array" then . else [] end)
        };
    def bounded_array($a; $n):
      ($a // [])
      | if type == "array" then . else [] end
      | map(tostring | gsub("[[:space:]]+"; " ") | gsub("^\\s+|\\s+$"; "") | select(length > 0))
      | unique
      | .[:$n];
    def bounded_text($n):
      tostring
      | gsub("[[:space:]]+"; " ")
      | gsub("^\\s+|\\s+$"; "")
      | if length > $n then .[0:$n] else . end;
    def operational_summary:
      (.metadata.operational_reasoning_summary // {}) as $existing
      | (.metadata.tool_activity // {}) as $ta
      | {
          intent: (((if (($existing.intent // "") | tostring | length) > 0 then $existing.intent else (.response // .error // "") end) | bounded_text(480))),
          files_read: (if (($existing.files_read // []) | type) == "array" and (($existing.files_read // []) | length) > 0 then bounded_array($existing.files_read; 20) elif (($ta.result_classes // []) | index("read")) then bounded_array($ta.file_paths; 20) else [] end),
          files_changed: (if (($existing.files_changed // []) | type) == "array" and (($existing.files_changed // []) | length) > 0 then bounded_array($existing.files_changed; 20) elif (($ta.write_count // 0) | num) > 0 then bounded_array($ta.file_paths; 20) else [] end),
          commands_run: (if (($existing.commands_run // []) | type) == "array" and (($existing.commands_run // []) | length) > 0 then bounded_array($existing.commands_run; 10) else bounded_array($ta.commands; 10) end),
          tool_write_count: ((($existing.tool_write_count // $ta.write_count // 0) | num) | floor),
          errors: (
            if (($existing.errors // []) | type) == "array" and (($existing.errors // []) | length) > 0 then bounded_array($existing.errors; 10)
            else bounded_array(([.error? // empty, .metadata.failure_signal.evidence_excerpt? // empty] + (if (($ta.error_classes // []) | type) == "array" then ($ta.error_classes // []) else [] end)); 10)
            end
          ),
          verification: (
            if (($existing.verification // []) | type) == "array" and (($existing.verification // []) | length) > 0 then bounded_array($existing.verification; 10)
            else bounded_array(((if (($ta.commands // []) | type) == "array" then ($ta.commands // []) else [] end) | map(select(test("(?i)(go test|npm test|pnpm test|yarn test|pytest|playwright|lighthouse|axe|eslint|tsc|cargo test|flutter test|xcodebuild|terraform plan)")))); 10)
            end
          ),
          final_summary: (((if (($existing.final_summary // "") | tostring | length) > 0 then $existing.final_summary else (.response // .error // "") end) | bounded_text(800))),
          source: (($existing.source // $existing.operational_summary_source // "wrapper_telemetry") | tostring),
          signed_thinking_blocks: ((($existing.signed_thinking_blocks // 0) | num) | floor)
        };
    def operational_summary_available($op):
      (($op.intent // "") | length) > 0
      or (($op.final_summary // "") | length) > 0
      or (($op.files_read // []) | length) > 0
      or (($op.files_changed // []) | length) > 0
      or (($op.commands_run // []) | length) > 0
      or (($op.errors // []) | length) > 0
      or (($op.tool_write_count // 0) | num) > 0
      or (($op.signed_thinking_blocks // 0) | num) > 0;
    def reasoning_capture_summary($op; $op_available):
      (.metadata // {}) as $m
      | ((.reasoning // "") | tostring) as $reasoning
      | (($m.reasoning_available // false) == true) as $available
      | {
          schema_version: 1,
          provider: $ctx.provider,
          available: $available,
          private_reasoning_available: $available,
          source: (($m.reasoning_source // "none") | tostring),
          absent_reason: (if $available then "available" else (($m.reasoning_absent_reason // "provider_reasoning_not_emitted") | tostring) end),
          captured_chars: ($reasoning | length),
          response_chars: (((.response // "") | tostring) | length),
          signed_thinking_blocks: (($op.signed_thinking_blocks // 0) | num | floor),
          operational_summary_available: $op_available,
          operational_summary_source: (if $op_available then (($op.source // "wrapper_telemetry") | tostring) else "none" end),
          diagnostic_only: true,
          not_required_for_acceptance: true,
          quality_gate_role: "observability_only",
          methods_attempted: ["wrapper_top_level", "response_payload", "session_log", "stream_log"]
        };
    classify_failure as $class
    | (operational_summary) as $op
    | (operational_summary_available($op)) as $op_available
    | .provider = (.provider // $ctx.provider)
    | .workflow = (.workflow // $ctx.workflow)
    | .ticket_id = (.ticket_id // $ctx.ticket_id)
    | .request_id = (.request_id // $ctx.request_id)
    | .model = (.model // $ctx.model_effective)
    | .metadata = (.metadata // {})
    | .metadata.wrapper_context = ((.metadata.wrapper_context // {}) + $ctx)
    | .metadata.operational_reasoning_summary = $op
    | .metadata.reasoning_capture = ((.metadata.reasoning_capture // {}) + reasoning_capture_summary($op; $op_available))
    | .metadata.failure_signal = ((.metadata.failure_signal // {}) + {
        class: $class,
        corrective_action: action_for($class),
        retryable: retryable_for($class),
        retry_after_seconds: retry_after_seconds,
        observed_status: (observed_status | tostring),
        evidence_excerpt: (failure_text | compact)
      })
    | .metadata.economics = ((.metadata.economics // {}) + token_summary)
    | .metadata.tool_yield = ((.metadata.tool_yield // {}) + tool_summary)
  ' 2>/dev/null || printf "%s" "$payload"
}

autonom8_attach_operational_summary_json() {
  local payload="${1:-}"
  local operational_summary="${2:-${AUTONOM8_OPERATIONAL_SUMMARY_JSON:-}}"
  if [[ -z "$operational_summary" || "$operational_summary" == "null" ]]; then
    printf "%s" "$payload"
    return 0
  fi
  printf "%s" "$operational_summary" | jq -e . >/dev/null 2>&1 || {
    printf "%s" "$payload"
    return 0
  }
  printf "%s" "$payload" | jq --argjson operational_summary "$operational_summary" '
    .metadata = (.metadata // {})
    | .metadata.operational_reasoning_summary = $operational_summary
  ' 2>/dev/null || printf "%s" "$payload"
}

autonom8_persist_provider_result_json() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 0
  [[ "${AUTONOM8_PROVIDER_RESULT_SIDECAR:-1}" != "0" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf "%s" "$payload" | jq -e . >/dev/null 2>&1 || return 0
  payload="$(autonom8_enrich_provider_payload_json "$payload" 2>/dev/null || printf "%s" "$payload")"

  local base_dir="${AUTONOM8_PROVIDER_RESULT_DIR:-}"
  if [[ -z "$base_dir" ]]; then
    local work_root="${WORK_DIR:-${WORKSPACE_DIR:-${CONTEXT_DIR:-$(pwd)}}}"
    [[ -n "$work_root" ]] || return 0
    base_dir="$work_root/.autonom8/provider_results"
  fi

  mkdir -p "$base_dir" 2>/dev/null || return 0

  local provider="${AUTONOM8_PROVIDER:-${A8_PROVIDER:-}}"
  if [[ -z "$provider" ]]; then
    provider="$(basename "${0:-wrapper}")"
    provider="${provider%.sh}"
  fi

  local req_id="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}"
  local workflow="${A8_WORKFLOW:-${AUTONOM8_WORKFLOW:-unknown-workflow}}"
  local ticket="${A8_TICKET_ID:-${AUTONOM8_TICKET_ID:-unknown-ticket}}"
  local outcome="response"
  outcome="$(printf "%s" "$payload" | jq -r '
    def successful_status:
      ascii_downcase as $s
      | ($s == "ok"
        or $s == "success"
        or $s == "succeeded"
        or $s == "complete"
        or $s == "completed"
        or $s == "implemented"
        or $s == "already_complete"
        or $s == "approved"
        or $s == "pass"
        or $s == "passed"
        or $s == "verified");
    def response_success:
      if (.success? == true) or (.ok? == true) then true
      elif ((.error? // "") | tostring | length) > 0 then false
      elif ((.response? // "") | type) == "string" and ((.response? // "") | length) > 0 then
        ((.response | fromjson? // {}) | if type == "object" then ((.success? == true) or (.complete? == true) or (((.status? // .decision? // "") | tostring) | successful_status)) else false end)
      else
        ((.complete? == true) or (((.status? // .decision? // "") | tostring) | successful_status))
      end;
    if response_success then "response" else ((.metadata.failure_class // .error_type // .type // "error") | tostring) end
  ' 2>/dev/null || printf "response")"

  local stamp=""
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  local file=""
  file="$base_dir/$(autonom8_safe_filename_part "$stamp")_$(autonom8_safe_filename_part "$req_id")_$(autonom8_safe_filename_part "$provider")_$(autonom8_safe_filename_part "$workflow")_$(autonom8_safe_filename_part "$ticket")_$(autonom8_safe_filename_part "$outcome").json"
  local tmp="${file}.$$"

  printf "%s\n" "$payload" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

autonom8_merge_tool_activity() {
  local tool_activity_json="${1:-}"
  if [[ -z "$tool_activity_json" || "$tool_activity_json" == "null" ]]; then
    local passthrough=""
    passthrough="$(cat)"
    passthrough="$(autonom8_attach_operational_summary_json "$passthrough")"
    passthrough="$(autonom8_enrich_provider_payload_json "$passthrough" 2>/dev/null || printf "%s" "$passthrough")"
    autonom8_persist_tool_activity_json "$passthrough"
    autonom8_persist_provider_result_json "$passthrough"
    printf "%s\n" "$passthrough"
    return 0
  fi

  local merged=""
  merged="$(jq --argjson tool_activity "$tool_activity_json" '
    if (($tool_activity.call_count // 0) > 0)
      or (($tool_activity.write_count // 0) > 0)
      or (($tool_activity.error_count // 0) > 0)
      or (($tool_activity.tool_names // []) | length > 0)
    then
      .metadata = ((.metadata // {}) + {tool_activity: $tool_activity})
    else
      .
    end
  ')"
  local jq_status=$?
  if [[ $jq_status -ne 0 ]]; then
    return "$jq_status"
  fi
  merged="$(autonom8_attach_operational_summary_json "$merged")"
  merged="$(autonom8_enrich_provider_payload_json "$merged" 2>/dev/null || printf "%s" "$merged")"
  autonom8_persist_tool_activity_json "$merged"
  autonom8_persist_provider_result_json "$merged"
  printf "%s\n" "$merged"
}
