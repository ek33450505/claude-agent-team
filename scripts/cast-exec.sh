#!/usr/bin/env bash
# cast-exec.sh — CAST External Plan Executor
#
# Purpose:
#   Standalone plan executor that replaces the orchestrator agent.
#   Reads a plan file containing a `json dispatch` fenced block, dispatches
#   agents via `claude --print`, verifies output files, and maintains a
#   persistent checkpoint so execution can be resumed after interruption.
#
# Usage:
#   cast-exec.sh <plan-file>
#   cast-exec.sh --resume <plan-file>
#   cast-exec.sh --status <plan-file>
#
# Checkpoint: ~/.claude/cast/exec-state/{plan_id}.json
# Agent logs:  ${TMPDIR:-/tmp}/cast-exec-{plan_id}-batch-{id}-{agent}.log
#
# Exit codes:
#   0 — all batches completed and verified
#   1 — verification failure or runtime error (checkpoint written as 'blocked')
#   2 — usage / argument error

# ── Subprocess guard: do not run recursively inside CAST subagent chains ──────
if [ "${CAST_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
EXEC_STATE_DIR="${HOME}/.claude/cast/exec-state"

# ── Colors (only when attached to a tty) ─────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  C_BOLD='\033[1m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RED='\033[0;31m'
  C_CYAN='\033[0;36m'
  C_DIM='\033[2m'
  C_RESET='\033[0m'
else
  C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_DIM='' C_RESET=''
fi

# ── Logging helpers ───────────────────────────────────────────────────────────
_info()    { printf "${C_CYAN}[cast-exec]${C_RESET} %s\n" "$*"; }
_success() { printf "${C_GREEN}[cast-exec]${C_RESET} %s\n" "$*"; }
_warn()    { printf "${C_YELLOW}[cast-exec] WARN:${C_RESET} %s\n" "$*" >&2; }
_error()   { printf "${C_RED}[cast-exec] ERROR:${C_RESET} %s\n" "$*" >&2; }
_header()  { printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }
_dim()     { printf "${C_DIM}%s${C_RESET}\n" "$*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="run"       # run | resume | status
PLAN_FILE=""

_usage() {
  cat <<USAGE
Usage: cast-exec.sh [--resume | --status] <plan-file>

  <plan-file>            Execute all batches in order
  --resume <plan-file>   Skip completed batches, resume from first non-complete
  --status <plan-file>   Print checkpoint state and exit

The plan file must contain a fenced code block labelled \`json dispatch\` with
the Agent Dispatch Manifest JSON.

Examples:
  cast-exec.sh ~/.claude/plans/2026-03-27-cast-phase-9.75b.md
  cast-exec.sh --resume ~/.claude/plans/2026-03-27-cast-phase-9.75b.md
  cast-exec.sh --status ~/.claude/plans/2026-03-27-cast-phase-9.75b.md
USAGE
}

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --resume)  MODE="resume"; shift ;;
    --status)  MODE="status"; shift ;;
    --help|-h) _usage; exit 0 ;;
    -*)
      _error "Unknown flag: $1"
      _usage >&2
      exit 2
      ;;
    *)
      if [ -z "$PLAN_FILE" ]; then
        PLAN_FILE="$1"
      else
        _error "Unexpected argument: $1"
        _usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$PLAN_FILE" ]; then
  _error "Plan file is required."
  _usage >&2
  exit 2
fi

# Expand ~ in path
PLAN_FILE="${PLAN_FILE/#\~/$HOME}"

if [ ! -f "$PLAN_FILE" ]; then
  _error "Plan file not found: $PLAN_FILE"
  exit 2
fi

# ── JSON extraction: parse the `json dispatch` fenced block ──────────────────
# Uses awk to extract text between ```json dispatch and ``` markers.
_extract_dispatch_json() {
  local plan_file="$1"
  awk '
    /^```json dispatch$/ { capture=1; next }
    /^```$/ && capture   { capture=0; next }
    capture              { print }
  ' "$plan_file"
}

DISPATCH_JSON="$(_extract_dispatch_json "$PLAN_FILE")"

if [ -z "$DISPATCH_JSON" ]; then
  _error "No \`json dispatch\` fenced block found in: $PLAN_FILE"
  _error "The plan must contain a block starting with: \`\`\`json dispatch"
  exit 1
fi

# ── Parse plan_id from dispatch JSON ─────────────────────────────────────────
PLAN_ID=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('plan_id', ''))
except Exception as e:
    print('', end='')
    sys.exit(1)
" 2>/dev/null) || {
  _error "Failed to parse dispatch JSON. Check that the json dispatch block is valid JSON."
  exit 1
}

if [ -z "$PLAN_ID" ]; then
  _error "plan_id is missing from the dispatch manifest."
  exit 1
fi

# ── Checkpoint helpers ────────────────────────────────────────────────────────
CHECKPOINT_FILE="${EXEC_STATE_DIR}/${PLAN_ID}.json"

_checkpoint_init() {
  mkdir -p "$EXEC_STATE_DIR"
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    python3 - "$PLAN_ID" "$PLAN_FILE" "$CHECKPOINT_FILE" <<'PYEOF'
import sys, json, datetime
from pathlib import Path
plan_id, plan_file, checkpoint_file = sys.argv[1], sys.argv[2], sys.argv[3]
state = {
    "plan_id": plan_id,
    "plan_file": plan_file,
    "started_at": datetime.datetime.utcnow().isoformat() + "Z",
    "batches": {}
}
Path(checkpoint_file).write_text(json.dumps(state, indent=2))
PYEOF
  fi
}

_checkpoint_read() {
  # Outputs the full checkpoint JSON to stdout
  if [ -f "$CHECKPOINT_FILE" ]; then
    cat "$CHECKPOINT_FILE"
  else
    echo '{}'
  fi
}

_checkpoint_batch_status() {
  local batch_id="$1"
  python3 - "$CHECKPOINT_FILE" "$batch_id" <<'PYEOF'
import sys, json
from pathlib import Path
checkpoint_file, batch_id = sys.argv[1], sys.argv[2]
try:
    d = json.loads(Path(checkpoint_file).read_text())
    status = d.get("batches", {}).get(str(batch_id), {}).get("status", "")
    print(status)
except Exception:
    print("")
PYEOF
}

_checkpoint_write_batch() {
  local batch_id="$1"
  local status="$2"           # running | complete | blocked
  local extra_json="${3:-{}}" # optional extra fields as JSON object string
  python3 - "$CHECKPOINT_FILE" "$batch_id" "$status" "$extra_json" <<'PYEOF'
import sys, json, datetime
from pathlib import Path
checkpoint_file, batch_id, status, extra_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    d = json.loads(Path(checkpoint_file).read_text())
except Exception:
    d = {"plan_id": "", "batches": {}}
if "batches" not in d or not isinstance(d["batches"], dict):
    d["batches"] = {}
now = datetime.datetime.utcnow().isoformat() + "Z"
batch_entry = d["batches"].get(str(batch_id), {})
batch_entry["status"] = status
if status == "running":
    batch_entry["started_at"] = now
elif status in ("complete", "blocked"):
    batch_entry["completed_at"] = now
try:
    extra = json.loads(extra_json)
    batch_entry.update(extra)
except Exception:
    pass
d["batches"][str(batch_id)] = batch_entry
Path(checkpoint_file).write_text(json.dumps(d, indent=2))
PYEOF
}

# ── Status subcommand ─────────────────────────────────────────────────────────
_cmd_status() {
  _header "cast exec status — plan: ${PLAN_ID}"
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    _warn "No checkpoint found at: $CHECKPOINT_FILE"
    _dim "  Run: cast-exec.sh $PLAN_FILE  to start execution"
    exit 0
  fi
  python3 - "$CHECKPOINT_FILE" <<'PYEOF'
import sys, json
from pathlib import Path

checkpoint_file = sys.argv[1]
try:
    d = json.loads(Path(checkpoint_file).read_text())
except Exception as e:
    print(f"Error reading checkpoint: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  plan_id   : {d.get('plan_id', '?')}")
print(f"  plan_file : {d.get('plan_file', '?')}")
print(f"  started_at: {d.get('started_at', '?')}")
print()
batches = d.get("batches", {})
if not batches:
    print("  No batch records yet.")
else:
    for bid in sorted(batches.keys(), key=lambda x: int(x) if x.isdigit() else 0):
        b = batches[bid]
        status = b.get("status", "?")
        icon = {"complete": "[DONE]", "blocked": "[BLOCKED]", "running": "[RUNNING]"}.get(status, f"[{status}]")
        ts = b.get("completed_at") or b.get("started_at") or ""
        verified = b.get("verified_files", [])
        print(f"  Batch {bid:>3}: {icon:<12}  {ts}")
        if verified:
            for vf in verified:
                print(f"             verified: {vf}")
PYEOF
}

# ── File verification ─────────────────────────────────────────────────────────
_verify_files() {
  local batch_id="$1"
  shift
  local files=("$@")

  if [ "${#files[@]}" -eq 0 ]; then
    _dim "  Batch ${batch_id}: no verify_files configured, skipping verification."
    return 0
  fi

  local all_ok=1
  local verified=()

  for raw_path in "${files[@]}"; do
    # Expand ~ in path
    local expanded_path="${raw_path/#\~/$HOME}"
    if test -f "$expanded_path" && test -s "$expanded_path"; then
      verified+=("$raw_path")
      _dim "  [ok] $raw_path"
    else
      _error "VERIFY FAILED — missing or empty: $raw_path"
      all_ok=0
    fi
  done

  if [ "$all_ok" -eq 0 ]; then
    return 1
  fi
  return 0
}

# ── Agent dispatch ────────────────────────────────────────────────────────────
_dispatch_agent() {
  local plan_id="$1"
  local batch_id="$2"
  local agent_type="$3"
  local prompt="$4"

  local _tmpdir="${TMPDIR:-/tmp}"
  local log_file="${_tmpdir}/cast-exec-${plan_id}-batch-${batch_id}-${agent_type}.log"

  _info "  Dispatching ${C_BOLD}${agent_type}${C_RESET}${C_CYAN} (log: ${log_file})"

  # Run claude --print with the agent; capture stdout+stderr to log
  # The prompt is passed via env var and a python3 heredoc to avoid shell injection
  CAST_EXEC_PROMPT="$prompt" python3 -c "
import os, sys, subprocess
prompt = os.environ.get('CAST_EXEC_PROMPT', '')
log_file = sys.argv[1]
agent = sys.argv[2]
cmd = ['claude', '--agent', agent, '--print', '--dangerously-skip-permissions', '-p', prompt]
with open(log_file, 'w') as f:
    result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
sys.exit(result.returncode)
" "$log_file" "$agent_type"
}

_dispatch_agent_background() {
  local plan_id="$1"
  local batch_id="$2"
  local agent_type="$3"
  local prompt="$4"
  local pidvar="$5"   # name of variable to store PID in

  local _tmpdir="${TMPDIR:-/tmp}"
  local log_file="${_tmpdir}/cast-exec-${plan_id}-batch-${batch_id}-${agent_type}.log"

  _info "  Dispatching (parallel) ${C_BOLD}${agent_type}${C_RESET}${C_CYAN} (log: ${log_file})"

  CAST_EXEC_PROMPT="$prompt" python3 -c "
import os, sys, subprocess
prompt = os.environ.get('CAST_EXEC_PROMPT', '')
log_file = sys.argv[1]
agent = sys.argv[2]
cmd = ['claude', '--agent', agent, '--print', '--dangerously-skip-permissions', '-p', prompt]
with open(log_file, 'w') as f:
    result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
sys.exit(result.returncode)
" "$log_file" "$agent_type" &

  # Capture the PID of the background process
  eval "${pidvar}=$!"
}

# ── Batch execution ───────────────────────────────────────────────────────────
_run_batch() {
  local batch_json="$1"

  # Extract batch fields
  local batch_id parallel description
  batch_id=$(printf '%s' "$batch_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
  parallel=$(printf '%s' "$batch_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('parallel') else 'false')" 2>/dev/null || echo "false")
  description=$(printf '%s' "$batch_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null || echo "")

  _header "Batch ${batch_id}: ${description}"

  _checkpoint_write_batch "$batch_id" "running"

  # Extract verify_files as newline-separated list
  local verify_files_raw
  verify_files_raw=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('verify_files', []):
    print(f)
" 2>/dev/null || echo "")

  # Build verify_files array
  local verify_files=()
  while IFS= read -r vf; do
    [ -n "$vf" ] && verify_files+=("$vf")
  done <<< "$verify_files_raw"

  # Extract number of agents
  local agent_count
  agent_count=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('agents', [])))
" 2>/dev/null || echo "0")

  if [ "$agent_count" -eq 0 ]; then
    _warn "  Batch ${batch_id}: no agents defined, skipping."
    _checkpoint_write_batch "$batch_id" "complete" "{\"verified_files\":[]}"
    return 0
  fi

  if [ "$parallel" = "true" ]; then
    # ── Parallel dispatch ────────────────────────────────────────────────────
    _info "  Mode: parallel ($agent_count agents)"

    local pids=()
    local agents_dispatched=()

    for idx in $(seq 0 $((agent_count - 1))); do
      local agent_type agent_prompt
      agent_type=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['agents'][$idx].get('subagent_type', ''))
" 2>/dev/null || echo "")
      agent_prompt=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['agents'][$idx].get('prompt', ''))
" 2>/dev/null || echo "")

      if [ -z "$agent_type" ]; then
        _warn "  Agent at index ${idx} has no subagent_type, skipping."
        continue
      fi

      local pid_var="agent_pid_${idx}"
      _dispatch_agent_background "$PLAN_ID" "$batch_id" "$agent_type" "$agent_prompt" "$pid_var"
      local pid_val
      pid_val=$(eval echo "\$${pid_var}")
      pids+=("$pid_val")
      agents_dispatched+=("$agent_type")
    done

    # Wait for all background agents and collect exit codes
    local all_ok=1
    for i in "${!pids[@]}"; do
      local pid="${pids[$i]}"
      local agent_name="${agents_dispatched[$i]:-agent-$i}"
      local exit_code=0
      wait "$pid" || exit_code=$?
      if [ "$exit_code" -ne 0 ]; then
        _error "  Agent '${agent_name}' exited with code ${exit_code}"
        _error "  Log: ${TMPDIR:-/tmp}/cast-exec-${PLAN_ID}-batch-${batch_id}-${agent_name}.log"
        all_ok=0
      else
        _success "  Agent '${agent_name}' completed."
      fi
    done

    if [ "$all_ok" -eq 0 ]; then
      _checkpoint_write_batch "$batch_id" "blocked" "{\"reason\":\"one or more parallel agents failed\"}"
      _error "Batch ${batch_id} blocked: agent(s) exited non-zero."
      return 1
    fi

  else
    # ── Sequential dispatch ──────────────────────────────────────────────────
    _info "  Mode: sequential ($agent_count agents)"

    for idx in $(seq 0 $((agent_count - 1))); do
      local agent_type agent_prompt
      agent_type=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['agents'][$idx].get('subagent_type', ''))
" 2>/dev/null || echo "")
      agent_prompt=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['agents'][$idx].get('prompt', ''))
" 2>/dev/null || echo "")

      if [ -z "$agent_type" ]; then
        _warn "  Agent at index ${idx} has no subagent_type, skipping."
        continue
      fi

      local exit_code=0
      _dispatch_agent "$PLAN_ID" "$batch_id" "$agent_type" "$agent_prompt" || exit_code=$?

      if [ "$exit_code" -ne 0 ]; then
        _checkpoint_write_batch "$batch_id" "blocked" \
          "{\"reason\":\"agent ${agent_type} exited with code ${exit_code}\"}"
        _error "Batch ${batch_id} blocked: ${agent_type} exited with code ${exit_code}."
        _error "  Log: ${TMPDIR:-/tmp}/cast-exec-${PLAN_ID}-batch-${batch_id}-${agent_type}.log"
        return 1
      fi

      _success "  Agent '${agent_type}' completed."
    done
  fi

  # ── Verify files ─────────────────────────────────────────────────────────
  _info "Verifying output files for batch ${batch_id}..."

  local verify_ok=1
  _verify_files "$batch_id" "${verify_files[@]+"${verify_files[@]}"}" || verify_ok=0

  if [ "$verify_ok" -eq 0 ]; then
    # Build JSON array of verify_files for checkpoint
    local vf_json
    vf_json=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('verify_files', [])))
" 2>/dev/null || echo "[]")
    _checkpoint_write_batch "$batch_id" "blocked" \
      "{\"reason\":\"verify_files check failed\",\"verify_files\":${vf_json}}"
    _error "Batch ${batch_id} BLOCKED — one or more required output files are missing or empty."
    _error "Resolve the issue and re-run with: cast exec --resume $PLAN_FILE"
    return 1
  fi

  # Mark complete with verified files list
  local vf_json
  vf_json=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('verify_files', [])))
" 2>/dev/null || echo "[]")
  _checkpoint_write_batch "$batch_id" "complete" "{\"verified_files\":${vf_json}}"
  _success "Batch ${batch_id} complete."
  return 0
}

# ── Main execution ────────────────────────────────────────────────────────────
_checkpoint_init

if [ "$MODE" = "status" ]; then
  _cmd_status
  exit 0
fi

# Count batches
BATCH_COUNT=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('batches', [])))
" 2>/dev/null || echo "0")

if [ "$BATCH_COUNT" -eq 0 ]; then
  _error "No batches found in dispatch manifest."
  exit 1
fi

_header "cast exec — ${PLAN_ID} (${BATCH_COUNT} batches)"
_dim "  Plan file : $PLAN_FILE"
_dim "  Checkpoint: $CHECKPOINT_FILE"
_dim "  Mode      : ${MODE}"
echo ""

# ── Batch loop ────────────────────────────────────────────────────────────────
for idx in $(seq 0 $((BATCH_COUNT - 1))); do
  BATCH_JSON=$(printf '%s' "$DISPATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
import json as j
print(j.dumps(d['batches'][$idx]))
" 2>/dev/null || echo "")

  if [ -z "$BATCH_JSON" ]; then
    _error "Failed to extract batch at index ${idx}"
    exit 1
  fi

  BATCH_ID=$(printf '%s' "$BATCH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('id',''))
" 2>/dev/null || echo "")

  # Resume mode: skip completed batches
  if [ "$MODE" = "resume" ]; then
    STATUS="$(_checkpoint_batch_status "$BATCH_ID")"
    if [ "$STATUS" = "complete" ]; then
      _info "Batch ${BATCH_ID}: already complete — skipping."
      continue
    fi
  fi

  _run_batch "$BATCH_JSON" || {
    _error ""
    _error "Execution halted at batch ${BATCH_ID}."
    _error "Checkpoint written. Resume with:"
    _error "  cast exec --resume $PLAN_FILE"
    exit 1
  }
done

_success ""
_success "All ${BATCH_COUNT} batches complete. Plan '${PLAN_ID}' finished."
_dim "  Checkpoint: $CHECKPOINT_FILE"
