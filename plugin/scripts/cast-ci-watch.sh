#!/bin/bash
# cast-ci-watch.sh — CI watch status helper for /ci-watch loop
#
# Subcommands:
#   start <pr>   — register a 90-min watch window for PR; refuses duplicate
#   status <pr>  — emit JSON verdict: MERGE|WAIT|FAIL|EXPIRED|NO_PR|ERROR
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

# Emit a verdict:ERROR JSON object with a machine-safe reason code.
# Raw stderr is never interpolated here (injection/escaping risk); full detail goes to _log_error.
_emit_error() {
  local pr="$1" seconds_left="$2" reason="$3"
  echo "{\"pr\":${pr},\"checks\":\"unknown\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"merge_state\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"ERROR\",\"error\":\"${reason}\"}"
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
  # If gh exits non-zero with non-empty stderr → transient error → ERROR.
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
      _log_error "gh pr view probe failed for PR $pr (stderr: ${probe_stderr_content})"
      _emit_error "$pr" "$seconds_left" "gh_probe_failed"
      exit 0
    fi
  fi

  # ── Fetch full PR info (unresolved threads fetched separately via GraphQL) ──
  local pr_json="" full_rc
  set +e
  pr_json="$("$GH" pr view "$pr" --json "mergeable,mergeStateStatus,statusCheckRollup" 2>/dev/null)"
  full_rc=$?
  set -e
  if [[ $full_rc -ne 0 ]]; then
    _log_error "gh pr view (full) failed for PR $pr"
    _emit_error "$pr" "$seconds_left" "gh_fetch_failed"
    exit 0
  fi

  if [[ -z "$pr_json" ]]; then
    _log_error "gh pr view (full) returned empty stdout for PR $pr"
    _emit_error "$pr" "$seconds_left" "gh_fetch_failed"
    exit 0
  fi

  # Parse checks, mergeable, merge_state from pr_json via python backend
  local checks_result="" mergeable="" merge_state="" unresolved_threads=0
  local parse_out="" parse_rc
  set +e
  parse_out="$(python3 "$PY" parse-status "$pr_json" 2>/dev/null)"
  parse_rc=$?
  set -e

  if [[ $parse_rc -ne 0 || -z "$parse_out" ]]; then
    _log_error "parse-status failed (non-zero exit or empty output) for PR $pr"
    _emit_error "$pr" "$seconds_left" "parse_failed"
    exit 0
  fi

  # Handle PARSE_ERROR / NO_PR from python
  if [[ "$parse_out" == "PARSE_ERROR|"* ]]; then
    _log_error "Failed to parse pr_json for PR $pr"
    _emit_error "$pr" "$seconds_left" "parse_failed"
    exit 0
  fi
  if [[ "$parse_out" == "NO_PR|"* ]]; then
    echo "{\"pr\":${pr},\"checks\":\"pending\",\"unresolved_threads\":0,\"mergeable\":\"UNKNOWN\",\"merge_state\":\"UNKNOWN\",\"seconds_left\":${seconds_left},\"verdict\":\"NO_PR\"}"
    exit 0
  fi

  # Split pipe-delimited parse output: checks|mergeable|unresolved|merge_state
  # unresolved from parse-status is always 0 (reviewThreads not in this call);
  # the real count is fetched via GraphQL below.
  checks_result="${parse_out%%|*}"
  local rest="${parse_out#*|}"
  mergeable="${rest%%|*}"
  rest="${rest#*|}"
  rest="${rest#*|}"  # skip unresolved placeholder
  merge_state="${rest}"

  # ── Fetch unresolved review threads via GraphQL ───────────────────────────
  # First resolve repo owner+name, then query threads (first 100 is adequate for typical PRs).
  local repo_json="" repo_rc
  set +e
  repo_json="$("$GH" repo view --json "owner,name" 2>/dev/null)"
  repo_rc=$?
  set -e

  if [[ $repo_rc -ne 0 || -z "$repo_json" ]]; then
    _log_error "gh repo view failed for PR $pr"
    _emit_error "$pr" "$seconds_left" "repo_resolve_failed"
    exit 0
  fi

  local repo_info="" repo_parse_rc
  set +e
  repo_info="$(python3 "$PY" parse-repo "$repo_json" 2>/dev/null)"
  repo_parse_rc=$?
  set -e

  if [[ $repo_parse_rc -ne 0 || -z "$repo_info" || "$repo_info" == "PARSE_ERROR" ]]; then
    _log_error "Failed to parse repo info for PR $pr"
    _emit_error "$pr" "$seconds_left" "repo_resolve_failed"
    exit 0
  fi

  local repo_owner repo_name
  repo_owner="${repo_info%%|*}"
  repo_name="${repo_info#*|}"

  local graphql_json="" graphql_rc
  set +e
  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variable placeholders, not shell vars
  graphql_json="$("$GH" api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved}}}}}' \
    -f owner="$repo_owner" \
    -f name="$repo_name" \
    -F pr="$pr" 2>/dev/null)"
  graphql_rc=$?
  set -e

  if [[ $graphql_rc -ne 0 || -z "$graphql_json" ]]; then
    _log_error "gh api graphql failed for PR $pr"
    _emit_error "$pr" "$seconds_left" "graphql_failed"
    exit 0
  fi

  local threads_parse_rc
  set +e
  unresolved_threads="$(python3 "$PY" parse-threads "$graphql_json" 2>/dev/null)"
  threads_parse_rc=$?
  set -e

  if [[ $threads_parse_rc -ne 0 || -z "$unresolved_threads" || "$unresolved_threads" == "PARSE_ERROR" ]]; then
    _log_error "Failed to parse GraphQL thread response for PR $pr"
    _emit_error "$pr" "$seconds_left" "graphql_failed"
    exit 0
  fi

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
