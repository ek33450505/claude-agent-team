#!/bin/bash
# cast-ci-watch.sh — CI watch status helper for /ci-watch loop
#
# Subcommands:
#   start <pr>   — register a 90-min watch window for PR; refuses duplicate
#   status <pr>  — emit JSON verdict: MERGE|WAIT|FAIL|EXPIRED|NO_PR
#   stop <pr>    — remove state file (idempotent)
#
# Overridable gh seam for tests:
#   CAST_CI_WATCH_GH_CMD=<path>  (default: gh)
#
# State dir: ~/.claude/cast/ci-watch/<pr>.json
# All exit codes: 0 (never crashes)

# ── Subprocess guard ──────────────────────────────────────────────────────────
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${SCRIPT_DIR}/cast-ci-watch.py"

GH="${CAST_CI_WATCH_GH_CMD:-gh}"
STATE_DIR="${HOME}/.claude/cast/ci-watch"
DEADLINE_SECS=5400  # 90 minutes

# ── Helpers ───────────────────────────────────────────────────────────────────

_state_file() {
  echo "${STATE_DIR}/${1}.json"
}

_now() {
  date +%s
}

_ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

_log_error() {
  local msg="$1"
  mkdir -p "${HOME}/.claude/logs"
  echo "[cast-ci-watch] $(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: $msg" >> "${HOME}/.claude/logs/hook-errors.log" || true
}

# ── Subcommand: start ─────────────────────────────────────────────────────────

_cmd_start() {
  local pr="$1"
  _ensure_state_dir

  local state_file
  state_file="$(_state_file "$pr")"
  local now
  now="$(_now)"

  # If a live state file exists and its deadline is still in the future, refuse
  if [[ -f "$state_file" ]]; then
    local existing_deadline
    existing_deadline="$(python3 "$PY" state-read "$state_file")"
    if [[ "$existing_deadline" -gt "$now" ]]; then
      echo '{"started":false,"reason":"loop already running"}'
      exit 0
    fi
  fi

  local deadline=$(( now + DEADLINE_SECS ))
  python3 "$PY" state-write "$state_file" "$pr" "$now" "$deadline"
  echo "{\"started\":true,\"pr\":${pr},\"deadline_epoch\":${deadline}}"
}

# ── Subcommand: status ────────────────────────────────────────────────────────

_cmd_status() {
  local pr="$1"
  _ensure_state_dir

  local now
  now="$(_now)"

  # Read deadline from state file (0 if absent/unreadable)
  local state_file
  state_file="$(_state_file "$pr")"
  local deadline=0
  if [[ -f "$state_file" ]]; then
    deadline="$(python3 "$PY" state-read "$state_file" 2>/dev/null || echo 0)"
  fi
  local seconds_left=$(( deadline - now ))
  if [[ "$seconds_left" -lt 0 ]]; then seconds_left=0; fi

  # ── Probe PR existence (separate from full fetch so errors are distinguishable) ──
  # Use a light probe to check if the PR exists at all.
  # If gh exits non-zero with empty stdout → NO_PR.
  # If gh exits non-zero with non-empty stderr → transient error → WAIT.
  local probe_out probe_err_file probe_stderr_content probe_rc
  probe_err_file="$(mktemp)"
  set +e
  probe_out="$("$GH" pr view "$pr" --json "number" 2>"$probe_err_file")"
  probe_rc=$?
  set -e
  probe_stderr_content="$(cat "$probe_err_file")"
  rm -f "$probe_err_file"

  if [[ $probe_rc -ne 0 ]]; then
    # Distinguish "no such PR" from transient errors:
    # gh CLI outputs "no pull requests found" or "could not find" on missing PRs
    if [[ -z "$probe_out" && ( -z "$probe_stderr_content" || "$probe_stderr_content" =~ [Nn]o\ pull\ request || "$probe_stderr_content" =~ could\ not\ find || "$probe_stderr_content" =~ not\ found ) ]]; then
      echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"NO_PR\"}"
      exit 0
    else
      _log_error "gh pr view failed for PR $pr (stderr: ${probe_stderr_content}) — degrading to WAIT"
      echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"WAIT\"}"
      exit 0
    fi
  fi

  # ── Fetch full PR info (mergeable, checks, reviewThreads in one call) ────────
  # reviewThreads included here to avoid a second gh call
  local pr_json="" full_rc
  set +e
  pr_json="$("$GH" pr view "$pr" --json "mergeable,mergeStateStatus,statusCheckRollup,reviewThreads" 2>/dev/null)"
  full_rc=$?
  set -e
  if [[ $full_rc -ne 0 ]]; then
    _log_error "gh pr view (full) failed for PR $pr — degrading to WAIT"
    echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"WAIT\"}"
    exit 0
  fi

  if [[ -z "$pr_json" ]]; then
    echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"WAIT\"}"
    exit 0
  fi

  # Parse checks, mergeable, and unresolved threads from pr_json via python backend
  local checks_result="" mergeable="" unresolved_threads=0
  local parse_out
  parse_out="$(python3 "$PY" parse-status "$pr_json" 2>/dev/null || echo "pending|UNKNOWN|0|UNKNOWN")"

  # Handle PARSE_ERROR / NO_PR from python
  if [[ "$parse_out" == "PARSE_ERROR|"* ]]; then
    _log_error "Failed to parse pr_json for PR $pr — degrading to WAIT"
    echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"merge_state\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"WAIT\"}"
    exit 0
  fi
  if [[ "$parse_out" == "NO_PR|"* ]]; then
    echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"merge_state\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"NO_PR\"}"
    exit 0
  fi

  # Split pipe-delimited parse output: checks|mergeable|unresolved|merge_state
  checks_result="${parse_out%%|*}"
  local rest="${parse_out#*|}"
  mergeable="${rest%%|*}"
  rest="${rest#*|}"
  unresolved_threads="${rest%%|*}"
  local merge_state="${rest##*|}"

  # Ensure unresolved_threads is a valid integer
  if ! [[ "$unresolved_threads" =~ ^[0-9]+$ ]]; then
    unresolved_threads=0
  fi

  # ── Compute verdict ───────────────────────────────────────────────────────
  # Order: FAIL → EXPIRED → MERGE → WAIT
  # MERGE requires: green checks + 0 unresolved threads + mergeable=MERGEABLE
  #                 + mergeStateStatus=CLEAN or HAS_HOOKS (branch protection ready)
  local verdict="WAIT"

  if [[ "$checks_result" == "failed" ]]; then
    verdict="FAIL"
  elif [[ "$now" -gt "$deadline" && "$deadline" -gt 0 ]]; then
    verdict="EXPIRED"
  elif [[ "$checks_result" == "green" && "$unresolved_threads" -eq 0 && "$mergeable" == "MERGEABLE" && ( "$merge_state" == "CLEAN" || "$merge_state" == "HAS_HOOKS" ) ]]; then
    verdict="MERGE"
  fi

  echo "{\"pr\":${pr},\"checks\":\"${checks_result}\",\"unresolved_threads\":${unresolved_threads},\"mergeable\":\"${mergeable}\",\"merge_state\":\"${merge_state}\",\"seconds_left\":${seconds_left},\"verdict\":\"${verdict}\"}"
}

# ── Subcommand: stop ──────────────────────────────────────────────────────────

_cmd_stop() {
  local pr="$1"
  local state_file
  state_file="$(_state_file "$pr")"
  rm -f "$state_file"
  echo '{"stopped":true}'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

main() {
  local subcommand="${1:-}"
  local pr="${2:-}"

  if [[ -z "$subcommand" || -z "$pr" ]]; then
    echo '{"error":"usage: cast-ci-watch.sh start|status|stop <pr>"}' >&2
    exit 0
  fi

  if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
    echo '{"error":"PR must be numeric"}' >&2
    exit 0
  fi

  case "$subcommand" in
    start)  _cmd_start  "$pr" ;;
    status) _cmd_status "$pr" ;;
    stop)   _cmd_stop   "$pr" ;;
    *)
      echo "{\"error\":\"unknown subcommand: ${subcommand}\"}" >&2
      exit 0
      ;;
  esac
}

main "$@"
