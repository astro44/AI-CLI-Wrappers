#!/usr/bin/env bash
# Shared best-effort tool-call telemetry extraction for Autonom8 CLI wrappers.

autonom8_tool_activity_json() {
  local raw_output="${1:-}"
  local stream_output="${2:-}"
  local source="${3:-wrapper}"
  local combined="${raw_output}"$'\n'"${stream_output}"

  if [[ -z "$(printf "%s" "$combined" | tr -d '[:space:]')" ]]; then
    jq -cn --arg source "$source" '{call_count:0, write_count:0, error_count:0, tool_names:[], result_classes:[], activity_class:"none", source:$source}'
    return 0
  fi

  jq -cn --arg raw "$combined" --arg source "$source" '
    def lname: tostring | ascii_downcase;
    def compact_name:
      tostring
      | gsub("^functions\\."; "")
      | gsub("^mcp__"; "")
      | gsub("__"; ".")
      | gsub("[^A-Za-z0-9_.:-]"; "_")
      | select(length > 0);
    def docs:
      (try ($raw | fromjson) catch null) as $whole
      | if $whole != null then
          [$whole]
        else
          ($raw | split("\n") | map((try fromjson catch null) | select(. != null)))
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
      elif (((.type? // .payload.type? // "") | lname) | test("(^tool$)|tool_use|tool_call|function_call|tool-call|tool.start|tool_start")) then
        .name // .tool // .tool_name // .toolName // .function.name // .payload.name // .payload.tool // .payload.tool_name // .payload.toolName // empty
      else
        empty
      end;
    def json_names:
      [
        docs[]
        | .. | objects
        | call_name_from_object
        | compact_name
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
    (names | unique) as $unique_names
    | ([$unique_names[] | class_for(.)] | unique) as $classes
    | (names | map(select(class_for(.) == "write")) | length) as $write_count
    | (json_error_count + ([$raw | scan("(?i)tool[^\\n]{0,80}(?:error|failed|failure)")] | length)) as $errors
    | {
        call_count: (names | length),
        write_count: $write_count,
        error_count: $errors,
        tool_names: $unique_names,
        result_classes: $classes,
        activity_class: (
          if $errors > 0 then "tool_errors"
          elif $write_count > 0 then "write_active"
          elif (names | length) > 0 then "tool_active"
          else "none"
          end
        ),
        source: $source
      }
  ' 2>/dev/null || jq -cn --arg source "$source" '{call_count:0, write_count:0, error_count:0, tool_names:[], result_classes:[], activity_class:"none", source:$source}'
}

autonom8_merge_tool_activity() {
  local tool_activity_json="${1:-}"
  if [[ -z "$tool_activity_json" || "$tool_activity_json" == "null" ]]; then
    cat
    return 0
  fi

  jq --argjson tool_activity "$tool_activity_json" '
    if (($tool_activity.call_count // 0) > 0)
      or (($tool_activity.write_count // 0) > 0)
      or (($tool_activity.error_count // 0) > 0)
      or (($tool_activity.tool_names // []) | length > 0)
    then
      .metadata = ((.metadata // {}) + {tool_activity: $tool_activity})
    else
      .
    end
  '
}
