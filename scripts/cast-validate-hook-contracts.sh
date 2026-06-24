#!/usr/bin/env bash
# cast-validate-hook-contracts.sh — Hook contract validator
# Reads settings.json (deployed or source), runs each registered hook with
# synthetic stdin, and validates the emitted JSON shape matches the CC contract.
#
# Usage:
#   bash scripts/cast-validate-hook-contracts.sh            # deployed ~/.claude/settings.json
#   bash scripts/cast-validate-hook-contracts.sh --source   # repo settings.json
#
# Exit codes: 0 = all pass, 1 = WARN found (unknown keys), 2 = ERROR found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse flags ---
USE_SOURCE=0
for arg in "$@"; do
  [[ "$arg" == "--source" ]] && USE_SOURCE=1
done

if [[ "$USE_SOURCE" == "1" ]]; then
  SETTINGS_FILE="$REPO_DIR/settings.json"
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "[cast-validate-hook-contracts] ERROR: settings file not found: $SETTINGS_FILE" >&2
  exit 2
fi

# --- Synthetic stdin payloads per event ---
PAYLOAD_SessionStart='{}'
PAYLOAD_PreToolUse='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt"}}'
PAYLOAD_PostToolUse='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"success":true}}'
PAYLOAD_Stop='{"session_id":"test","stop_hook_active":false}'
PAYLOAD_SubagentStop='{"agent_type":"test-agent","session_id":"test","agent_id":"test","stop_reason":"end_turn"}'
PAYLOAD_SessionEnd='{"session_id":"test"}'
PAYLOAD_UserPromptSubmit='{"prompt":"test"}'
PAYLOAD_PostToolUseFailure='{"tool_name":"Write","tool_input":{},"error":"test error"}'
PAYLOAD_InstructionsLoaded='{"session_id":"test"}'
PAYLOAD_CwdChanged='{"cwd":"/tmp"}'
PAYLOAD_FileChanged='{"file":"/tmp/test"}'
PAYLOAD_PreCompact='{"session_id":"test"}'
PAYLOAD_PostCompact='{"session_id":"test"}'
PAYLOAD_StopFailure='{"session_id":"test"}'
PAYLOAD_TaskCreated='{"session_id":"test"}'
PAYLOAD_TeammateIdle='{"session_id":"test","agent_id":"agent_test","agent_type":"code-reviewer","teammate_name":"code-reviewer","team_name":"session-test"}'
PAYLOAD_TaskCompleted='{"session_id":"test","task_id":"task_test","task_subject":"Test task"}'
PAYLOAD_SubagentStart='{"agent_type":"test","session_id":"test"}'
PAYLOAD_ConfigChange='{"key":"test"}'
PAYLOAD_PermissionRequest='{"tool":"test"}'
PAYLOAD_PermissionDenied='{"tool":"test"}'
PAYLOAD_WorktreeCreate='{"path":"/tmp/worktree"}'

# --- Tracking ---
WARN_COUNT=0
ERROR_COUNT=0
OK_COUNT=0

# --- Python contract validator (single-quoted heredoc, paths via os.environ) ---
_validate_output() {
  local event_name="$1"
  local hook_label="$2"
  local hook_stdout="$3"

  export CAST_CV_EVENT="$event_name"
  export CAST_CV_LABEL="$hook_label"
  export CAST_CV_STDOUT="$hook_stdout"

  python3 - <<'PYEOF'
import json
import os
import sys

event = os.environ["CAST_CV_EVENT"]
label = os.environ["CAST_CV_LABEL"]
stdout_raw = os.environ.get("CAST_CV_STDOUT", "").strip()

# Empty stdout is valid for all logging-only events
if not stdout_raw:
    print(f"[ok] {label} ({event}) — empty stdout (logging-only, ok)")
    sys.exit(0)

# Try to parse as JSON
try:
    data = json.loads(stdout_raw)
except json.JSONDecodeError as e:
    print(f"[fail] {label} ({event}) — non-JSON output: {e}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[fail] {label} ({event}) — output is not a JSON object", file=sys.stderr)
    sys.exit(2)

# --- Contract definitions ---
KNOWN_TOP_LEVEL = {
    "SessionStart":    {"hookSpecificOutput"},
    "PostToolUse":     {"hookSpecificOutput"},
    "UserPromptSubmit": {"hookSpecificOutput"},
    "PreToolUse":      {"decision", "reason", "hookSpecificOutput", "updatedInput"},
    "Stop":            {"decision", "reason", "continue"},
    "SubagentStop":    {"hookSpecificOutput"},
    "SessionEnd":      {"hookSpecificOutput"},
    "InstructionsLoaded": {"hookSpecificOutput"},
    "PreCompact":      {"decision", "reason"},
    "StopFailure":     {"hookSpecificOutput"},
    "PostToolUseFailure": {"hookSpecificOutput"},
    # Async/logging events — empty is always ok, no strict shape required
}

REQUIRES_HOOK_SPECIFIC = {"SessionStart", "PostToolUse", "UserPromptSubmit",
                           "InstructionsLoaded", "StopFailure", "PostToolUseFailure"}

top_keys = set(data.keys())
allowed = KNOWN_TOP_LEVEL.get(event, None)

status = 0  # 0=ok, 1=warn, 2=fail

if allowed is not None:
    unknown = top_keys - allowed
    if unknown:
        for k in sorted(unknown):
            print(f"[warn] {label} ({event}) — unknown key '{k}' (harness silently ignores it)", file=sys.stderr)
        status = max(status, 1)

# Validate hookSpecificOutput shape when present
if "hookSpecificOutput" in data:
    hso = data["hookSpecificOutput"]
    if not isinstance(hso, dict):
        print(f"[fail] {label} ({event}) — hookSpecificOutput is not an object", file=sys.stderr)
        status = max(status, 2)
    else:
        emitted_name = hso.get("hookEventName", "")
        if emitted_name != event:
            print(f"[fail] {label} ({event}) — wrong hookEventName '{emitted_name}' (expected '{event}')", file=sys.stderr)
            status = max(status, 2)
        elif "additionalContext" not in hso:
            print(f"[warn] {label} ({event}) — hookSpecificOutput missing 'additionalContext'", file=sys.stderr)
            status = max(status, 1)
        else:
            if status == 0:
                print(f"[ok] {label} ({event}) — shape valid")

elif event in REQUIRES_HOOK_SPECIFIC:
    # Has output but no hookSpecificOutput — might still be valid (e.g. SessionStart can return nothing)
    # but if they emit keys that look wrong, warn
    if allowed:
        unknown = top_keys - allowed
        if unknown:
            pass  # already warned above
        elif status == 0:
            print(f"[warn] {label} ({event}) — has output but no hookSpecificOutput", file=sys.stderr)
            status = max(status, 1)
    elif status == 0:
        print(f"[ok] {label} ({event}) — shape valid")

# Validate Stop/PreToolUse decision field
if "decision" in data:
    decision = data.get("decision")
    if event == "Stop" and decision not in ("block", "continue"):
        print(f"[fail] {label} ({event}) — invalid decision value '{decision}' (expected block|continue)", file=sys.stderr)
        status = max(status, 2)
    elif event == "PreToolUse" and decision not in ("block", "allow"):
        print(f"[warn] {label} ({event}) — unexpected decision value '{decision}'", file=sys.stderr)
        status = max(status, 1)
    if status == 0:
        print(f"[ok] {label} ({event}) — shape valid (decision={decision})")

if status == 0 and not stdout_raw:
    pass  # already printed ok above

sys.exit(status)
PYEOF
}

# --- Iterate hooks from settings.json ---
export CAST_CV_SETTINGS="$SETTINGS_FILE"
HOOK_LINES=$(python3 - <<'PYEOF'
import json
import os

settings_file = os.environ["CAST_CV_SETTINGS"]
with open(settings_file) as f:
    data = json.load(f)

hooks = data.get("hooks", {})
for event, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id", "")
        for hook in entry.get("hooks", []):
            if hook.get("type") != "command":
                continue
            cmd = hook.get("command", "")
            # label: prefer id, else basename of script
            if entry_id:
                label = entry_id
            else:
                # extract script basename from command
                parts = cmd.split()
                script_part = parts[-1] if parts else cmd
                label = os.path.basename(script_part)
            print(f"{event}\t{label}\t{cmd}")
PYEOF
)

if [[ -z "$HOOK_LINES" ]]; then
  echo "[cast-validate-hook-contracts] No command hooks found in $SETTINGS_FILE" >&2
  exit 0
fi

while IFS=$'\t' read -r event label cmd; do
  # Resolve script path: strip 'bash ' prefix, expand ~
  script_path="${cmd#bash }"
  script_path="${script_path/#\~/$HOME}"
  # Strip extra flags/args (take first word as script)
  script_path="${script_path%% *}"

  if [[ ! -f "$script_path" ]]; then
    echo "[warn] $label ($event) — script not found: $script_path" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi

  # Get payload for this event
  payload_var="PAYLOAD_${event}"
  payload="${!payload_var:-{}}"

  # Run hook with synthetic stdin and CLAUDE_SUBPROCESS=0 enforced
  # Timeout: 5s to prevent hangs (macOS-compatible via perl)
  stdout_out=""
  hook_exit=0
  if command -v timeout &>/dev/null; then
    stdout_out=$(echo "$payload" | CLAUDE_SUBPROCESS=0 timeout 5 bash "$script_path" 2>/dev/null) || hook_exit=$?
  elif command -v perl &>/dev/null; then
    stdout_out=$(echo "$payload" | CLAUDE_SUBPROCESS=0 perl -e 'alarm 5; exec @ARGV' bash "$script_path" 2>/dev/null) || hook_exit=$?
  else
    stdout_out=$(echo "$payload" | CLAUDE_SUBPROCESS=0 bash "$script_path" 2>/dev/null) || hook_exit=$?
  fi
  if [[ $hook_exit -eq 124 || $hook_exit -eq 142 ]]; then
    echo "[warn] $label ($event) — hook timed out after 5s" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi
  # Non-zero exit is ok for PreToolUse block hooks — still validate stdout

  # Validate output shape
  # Capture exit code separately to avoid set -e triggering on non-zero exit
  result=$(_validate_output "$event" "$label" "$stdout_out" 2>&1; echo "CAST_EXIT:$?")
  validate_exit="${result##*CAST_EXIT:}"
  result="${result%$'\n'CAST_EXIT:*}"

  # Print validation result to stdout/stderr as appropriate
  if [[ $validate_exit -eq 0 ]]; then
    echo "$result"
    OK_COUNT=$((OK_COUNT + 1))
  elif [[ $validate_exit -eq 1 ]]; then
    echo "$result" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
  else
    echo "$result" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi

done <<< "$HOOK_LINES"

# --- Summary ---
TOTAL=$((OK_COUNT + WARN_COUNT + ERROR_COUNT))
echo ""
echo "--- Hook contract validation: $TOTAL hooks checked, $OK_COUNT ok, $WARN_COUNT warn, $ERROR_COUNT error ---"

if [[ $ERROR_COUNT -gt 0 ]]; then
  exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
  exit 1
else
  exit 0
fi
