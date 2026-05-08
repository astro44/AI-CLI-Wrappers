#!/usr/bin/env bash
# Shared provider-wrapper lifecycle diagnostics and parent-death containment.

AUTONOM8_WRAPPER_PARENT_MONITOR_PID=""
AUTONOM8_WRAPPER_LIFECYCLE_FILE=""
AUTONOM8_WRAPPER_CHILD_PGID=""
AUTONOM8_WRAPPER_PROBE_HOLD_APPLIED=""

autonom8_wrapper_safe_part() {
  printf "%s" "${1:-unknown}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]\+/-/g; s/^-//; s/-$//'
}

autonom8_wrapper_lifecycle_dir() {
  local work_dir="${1:-}"
  if [[ -n "${AUTONOM8_WRAPPER_LIFECYCLE_DIR:-}" ]]; then
    printf "%s" "${AUTONOM8_WRAPPER_LIFECYCLE_DIR}"
    return 0
  fi
  if [[ -z "${work_dir}" ]]; then
    work_dir="${WORK_DIR:-${WORKSPACE_DIR:-$(pwd)}}"
  fi
  printf "%s/.autonom8/wrapper_lifecycle" "${work_dir}"
}

autonom8_wrapper_write_event() {
  local event="${1:-event}"
  local provider="${2:-unknown}"
  local child_pid="${3:-}"
  local work_dir="${4:-}"
  local detail="${5:-}"
  local dir=""
  local req_id="${AUTONOM8_REQUEST_ID:-${A8_REQUEST_ID:-no-request}}"
  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local current_ppid=""
  local now=""

  dir="$(autonom8_wrapper_lifecycle_dir "${work_dir}")"
  mkdir -p "${dir}" 2>/dev/null || return 0
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
  current_ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "${AUTONOM8_WRAPPER_LIFECYCLE_FILE:-}" ]]; then
    AUTONOM8_WRAPPER_LIFECYCLE_FILE="${dir}/$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%s).$(autonom8_wrapper_safe_part "${req_id}").$(autonom8_wrapper_safe_part "${provider}").jsonl"
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg at "${now}" \
      --arg event "${event}" \
      --arg provider "${provider}" \
      --arg request_id "${req_id}" \
      --arg wrapper_pid "$$" \
      --arg wrapper_ppid "${current_ppid}" \
      --arg expected_parent_pid "${parent_pid}" \
      --arg child_pid "${child_pid}" \
      --arg work_dir "${work_dir}" \
      --arg detail "${detail}" \
      '{at:$at,event:$event,provider:$provider,request_id:$request_id,wrapper_pid:($wrapper_pid|tonumber? // $wrapper_pid),wrapper_ppid:($wrapper_ppid|tonumber? // $wrapper_ppid),expected_parent_pid:($expected_parent_pid|tonumber? // $expected_parent_pid),child_pid:($child_pid|tonumber? // $child_pid),work_dir:$work_dir,detail:$detail}' \
      >> "${AUTONOM8_WRAPPER_LIFECYCLE_FILE}" 2>/dev/null || true
  else
    printf '{"at":"%s","event":"%s","provider":"%s","request_id":"%s","wrapper_pid":%s,"wrapper_ppid":"%s","expected_parent_pid":"%s","child_pid":"%s","work_dir":"%s","detail":"%s"}\n' \
      "${now}" "${event}" "${provider}" "${req_id}" "$$" "${current_ppid}" "${parent_pid}" "${child_pid}" "${work_dir}" "${detail}" \
      >> "${AUTONOM8_WRAPPER_LIFECYCLE_FILE}" 2>/dev/null || true
  fi
}

autonom8_wrapper_process_pgid() {
  local pid="${1:-}"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]' || true
}

autonom8_wrapper_protected_pid_match() {
  local pid="${1:-}"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1

  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local wrapper_ppid=""
  wrapper_ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"

  [[ "${pid}" == "$$" ]] && return 0
  [[ -n "${BASHPID:-}" && "${pid}" == "${BASHPID}" ]] && return 0
  [[ -n "${parent_pid}" && "${parent_pid}" =~ ^[0-9]+$ && "${pid}" == "${parent_pid}" ]] && return 0
  [[ -n "${wrapper_ppid}" && "${wrapper_ppid}" =~ ^[0-9]+$ && "${pid}" == "${wrapper_ppid}" ]] && return 0
  return 1
}

autonom8_wrapper_process_group_has_protected_pid() {
  local pgid="${1:-}"
  [[ -n "${pgid}" && "${pgid}" =~ ^[0-9]+$ ]] || return 1

  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local parent_pgid=""
  if [[ -n "${parent_pid}" && "${parent_pid}" =~ ^[0-9]+$ ]]; then
    parent_pgid="$(autonom8_wrapper_process_pgid "${parent_pid}")"
    [[ -n "${parent_pgid}" && "${parent_pgid}" == "${pgid}" ]] && return 0
  fi

  local wrapper_ppid=""
  wrapper_ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "${wrapper_ppid}" && "${wrapper_ppid}" =~ ^[0-9]+$ ]]; then
    local wrapper_parent_pgid=""
    wrapper_parent_pgid="$(autonom8_wrapper_process_pgid "${wrapper_ppid}")"
    [[ -n "${wrapper_parent_pgid}" && "${wrapper_parent_pgid}" == "${pgid}" ]] && return 0
  fi

  return 1
}

autonom8_wrapper_remember_child_group() {
  local child_pid="${1:-}"
  local child_pgid=""
  local wrapper_pgid=""
  local attempts=1
  local idx=0

  if [[ "${AUTONOM8_WRAPPER_CHILD_SESSION:-0}" == "1" ]]; then
    attempts=20
    wrapper_pgid="$(autonom8_wrapper_process_pgid "$$")"
  fi

  while (( idx < attempts )); do
    child_pgid="$(autonom8_wrapper_process_pgid "${child_pid}")"
    if [[ -z "${child_pgid}" || "${AUTONOM8_WRAPPER_CHILD_SESSION:-0}" != "1" || -z "${wrapper_pgid}" || "${child_pgid}" != "${wrapper_pgid}" ]]; then
      break
    fi
    sleep 0.1
    idx=$((idx + 1))
  done

  if [[ -n "${child_pgid}" && "${child_pgid}" =~ ^[0-9]+$ ]]; then
    AUTONOM8_WRAPPER_CHILD_PGID="${child_pgid}"
  fi
}

autonom8_wrapper_write_cleanup_event() {
  local provider="${1:-unknown}"
  local child_pid="${2:-}"
  local work_dir="${3:-}"
  local base_detail="${4:-wrapper_cleanup}"
  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local parent_alive="unknown"
  local child_alive="false"
  local child_pgid=""
  local wrapper_ppid=""
  local detail=""

  if [[ -n "${parent_pid}" && "${parent_pid}" =~ ^[0-9]+$ ]]; then
    if kill -0 "${parent_pid}" 2>/dev/null; then
      parent_alive="true"
    else
      parent_alive="false"
    fi
  fi
  if [[ -n "${child_pid}" && "${child_pid}" =~ ^[0-9]+$ ]]; then
    if kill -0 "${child_pid}" 2>/dev/null; then
      child_alive="true"
    fi
    child_pgid="$(autonom8_wrapper_process_pgid "${child_pid}")"
  fi
  if [[ -z "${child_pgid}" && -n "${AUTONOM8_WRAPPER_CHILD_PGID:-}" ]]; then
    child_pgid="${AUTONOM8_WRAPPER_CHILD_PGID}"
  fi
  wrapper_ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"

  detail="${base_detail};parent_alive=${parent_alive};child_alive=${child_alive}"
  [[ -n "${wrapper_ppid}" ]] && detail="${detail};wrapper_ppid=${wrapper_ppid}"
  [[ -n "${child_pgid}" ]] && detail="${detail};child_pgid=${child_pgid}"
  autonom8_wrapper_write_event "cleanup" "${provider}" "${child_pid}" "${work_dir}" "${detail}"
}

autonom8_wrapper_parent_gone_policy() {
  local raw="${AUTONOM8_WRAPPER_PARENT_GONE_POLICY:-reap_child}"
  raw="$(printf "%s" "${raw}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
  case "${raw}" in
    preserve_child|preserve|continue_child|continue|sidecar|sidecar_only)
      printf "preserve_child"
      ;;
    *)
      printf "reap_child"
      ;;
  esac
}

autonom8_wrapper_should_preserve_child_after_parent_gone() {
  local provider="${1:-unknown}"
  local child_pid="${2:-}"
  local work_dir="${3:-}"
  local reason="${4:-parent_gone_preserve_check}"
  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local child_pgid="${AUTONOM8_WRAPPER_CHILD_PGID:-}"

  [[ "$(autonom8_wrapper_parent_gone_policy)" == "preserve_child" ]] || return 1
  [[ -n "${child_pid}" && "${child_pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${child_pid}" 2>/dev/null || return 1
  [[ -n "${parent_pid}" && "${parent_pid}" =~ ^[0-9]+$ ]] || return 1
  if kill -0 "${parent_pid}" 2>/dev/null; then
    return 1
  fi

  if [[ -z "${child_pgid}" ]]; then
    child_pgid="$(autonom8_wrapper_process_pgid "${child_pid}")"
  fi
  autonom8_wrapper_write_event "parent_gone_preserve_child" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=${child_pgid:-unknown}"
  return 0
}

autonom8_wrapper_signal_process_group_members() {
  local pgid="${1:-}"
  local sig="${2:-TERM}"
  [[ -n "${pgid}" && "${pgid}" =~ ^[0-9]+$ ]] || return 1
  if autonom8_wrapper_process_group_has_protected_pid "${pgid}"; then
    return 1
  fi

  local pids=""
  pids="$(ps -axo pid=,pgid= 2>/dev/null | awk -v pgid="${pgid}" -v self="$$" '$2 == pgid && $1 != self {print $1}' || true)"
  [[ -n "${pids}" ]] || return 1

  while IFS= read -r pid; do
    [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || continue
    if autonom8_wrapper_protected_pid_match "${pid}"; then
      continue
    fi
    kill "-${sig}" "${pid}" 2>/dev/null || true
  done <<< "${pids}"
}

autonom8_wrapper_reap_child_tree() {
  local provider="${1:-unknown}"
  local child_pid="${2:-}"
  local work_dir="${3:-}"
  local reason="${4:-wrapper_cleanup_reap}"
  local child_pgid="${AUTONOM8_WRAPPER_CHILD_PGID:-}"

  if [[ -z "${child_pgid}" && -n "${child_pid}" ]]; then
    child_pgid="$(autonom8_wrapper_process_pgid "${child_pid}")"
  fi

  if [[ -n "${child_pgid}" && "${child_pgid}" =~ ^[0-9]+$ ]]; then
    if autonom8_wrapper_process_group_has_protected_pid "${child_pgid}"; then
      autonom8_wrapper_write_event "cleanup_group_refused_protected_pgid" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=${child_pgid}"
      return 1
    fi
    autonom8_wrapper_write_event "cleanup_group_term" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=${child_pgid}"
    autonom8_wrapper_signal_process_group_members "${child_pgid}" "TERM" || true
    sleep 1
    if ps -axo pgid= 2>/dev/null | awk -v pgid="${child_pgid}" '$1 == pgid {found=1} END {exit found ? 0 : 1}'; then
      autonom8_wrapper_write_event "cleanup_group_kill" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=${child_pgid}"
      autonom8_wrapper_signal_process_group_members "${child_pgid}" "KILL" || true
      sleep 1
    fi
  elif [[ -n "${child_pid}" && "${child_pid}" =~ ^[0-9]+$ ]]; then
    autonom8_wrapper_write_event "cleanup_child_term" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=unknown"
    kill "${child_pid}" 2>/dev/null || true
    sleep 1
    if kill -0 "${child_pid}" 2>/dev/null; then
      autonom8_wrapper_write_event "cleanup_child_kill" "${provider}" "${child_pid}" "${work_dir}" "${reason};child_pgid=unknown"
      kill -9 "${child_pid}" 2>/dev/null || true
    fi
  fi
}

autonom8_wrapper_stop_parent_monitor() {
  if [[ -n "${AUTONOM8_WRAPPER_PARENT_MONITOR_PID:-}" ]]; then
    kill "${AUTONOM8_WRAPPER_PARENT_MONITOR_PID}" 2>/dev/null || true
    wait "${AUTONOM8_WRAPPER_PARENT_MONITOR_PID}" 2>/dev/null || true
    AUTONOM8_WRAPPER_PARENT_MONITOR_PID=""
  fi
}

autonom8_wrapper_probe_hold_if_requested() {
  local provider="${1:-unknown}"
  local reason="${2:-post_response_success}"
  local raw_seconds="${AUTONOM8_PROVIDER_PROBE_POST_RESPONSE_HOLD_SECONDS:-}"
  [[ -n "${raw_seconds}" ]] || return 0
  [[ -z "${AUTONOM8_WRAPPER_PROBE_HOLD_APPLIED:-}" ]] || return 0
  [[ "${raw_seconds}" =~ ^[0-9]+$ ]] || return 0
  if (( raw_seconds <= 0 || raw_seconds > 900 )); then
    autonom8_wrapper_write_event "probe_hold_skipped" "${provider}" "" "$(pwd)" "invalid_seconds=${raw_seconds};reason=${reason}"
    return 0
  fi
  AUTONOM8_WRAPPER_PROBE_HOLD_APPLIED="1"
  autonom8_wrapper_write_event "probe_hold_start" "${provider}" "" "$(pwd)" "seconds=${raw_seconds};reason=${reason}"
  sleep "${raw_seconds}"
  autonom8_wrapper_write_event "probe_hold_end" "${provider}" "" "$(pwd)" "seconds=${raw_seconds};reason=${reason}"
}

autonom8_wrapper_monitor_parent() {
  local child_pid="${1:-}"
  local provider="${2:-unknown}"
  local work_dir="${3:-}"
  local parent_pid="${AUTONOM8_WORKER_PID:-${A8_WORKER_PID:-${AUTONOM8_PARENT_PID:-}}}"
  local wrapper_pid="$$"
  local current_ppid=""

  [[ "${AUTONOM8_WRAPPER_PARENT_MONITOR:-1}" != "0" ]] || return 0
  [[ -n "${child_pid}" && "${child_pid}" =~ ^[0-9]+$ ]] || return 0
  [[ -n "${parent_pid}" && "${parent_pid}" =~ ^[0-9]+$ ]] || return 0

  autonom8_wrapper_remember_child_group "${child_pid}"
  local child_pgid="${AUTONOM8_WRAPPER_CHILD_PGID:-}"
  local parent_pgid=""
  local wrapper_pgid=""
  parent_pgid="$(autonom8_wrapper_process_pgid "${parent_pid}")"
  wrapper_pgid="$(autonom8_wrapper_process_pgid "${wrapper_pid}")"
  autonom8_wrapper_write_event "child_started" "${provider}" "${child_pid}" "${work_dir}" "parent_monitor_started;child_pgid=${child_pgid:-unknown};parent_pgid=${parent_pgid:-unknown};wrapper_pgid=${wrapper_pgid:-unknown}"

  (
    while kill -0 "${child_pid}" 2>/dev/null; do
      if ! kill -0 "${parent_pid}" 2>/dev/null; then
        if autonom8_wrapper_should_preserve_child_after_parent_gone "${provider}" "${child_pid}" "${work_dir}" "parent_monitor_expected_parent_pid_not_running"; then
          exit 0
        fi
        autonom8_wrapper_write_event "parent_gone" "${provider}" "${child_pid}" "${work_dir}" "expected_parent_pid_not_running"
        autonom8_wrapper_reap_child_tree "${provider}" "${child_pid}" "${work_dir}" "parent_gone_reap"
        exit 0
      fi
      current_ppid="$(ps -o ppid= -p "${wrapper_pid}" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "${current_ppid}" && "${current_ppid}" != "${parent_pid}" && "${current_ppid}" == "1" ]]; then
        autonom8_wrapper_write_event "wrapper_reparented" "${provider}" "${child_pid}" "${work_dir}" "wrapper_ppid_is_1"
      fi
      sleep 1
    done
  ) &
  AUTONOM8_WRAPPER_PARENT_MONITOR_PID=$!
}
