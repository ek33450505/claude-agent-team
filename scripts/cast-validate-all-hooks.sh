#!/usr/bin/env bash
# cast-validate-all-hooks.sh — CI-runnable hook output validator
#
# Reads settings.json (deployed ~/.claude/settings.json or repo settings.json),
# fires each wired hook with a synthetic stdin payload, pipes stdout through
# cast-validate-hook-contracts.sh, and aggregates results.
#
# Usage:
#   bash scripts/cast-validate-all-hooks.sh               # uses ~/.claude/settings.json
#   bash scripts/cast-validate-all-hooks.sh --source      # uses repo settings.json
#
# Exit: 0 = all ok, 1 = warnings, 2 = at least one hook failed contract

set -euo pipefail

# ── Subprocess guard ──────────────────────────────────────────────────────
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$SCRIPT_DIR/cast-validate-hook-contracts.sh"

if [[ ! -f "$VALIDATOR" ]]; then
  echo "[cast-validate-all-hooks] ERROR: validator not found: $VALIDATOR" >&2
  exit 2
fi

# ── Parse flags ───────────────────────────────────────────────────────────
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
  echo "[cast-validate-all-hooks] ERROR: settings not found: $SETTINGS_FILE" >&2
  exit 2
fi

# ── Synthetic stdin payloads per event type ───────────────────────────────
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
PAYLOAD_SubagentStart='{"agent_type":"test","session_id":"test"}'

# ── Enumerate hooks from settings.json ───────────────────────────────────
export CAST_VA_SETTINGS="$SETTINGS_FILE"
HOOK_LINES=$(python3 - <<'PYEOF'
import json, os

settings_file = os.environ["CAST_VA_SETTINGS"]
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
            if entry_id:
                label = entry_id
            else:
                parts = cmd.split()
                script_part = parts[-1] if parts else cmd
                label = os.path.basename(script_part)
            print(f"{event}\t{label}\t{cmd}")
PYEOF
)

if [[ -z "$HOOK_LINES" ]]; then
  echo "[cast-validate-all-hooks] No command hooks found in $SETTINGS_FILE" >&2
  exit 0
fi

# ── Per-hook validation counters ──────────────────────────────────────────
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

while IFS=$'\t' read -r event label cmd; do
  # Resolve script path
  script_path="${cmd#bash }"
  script_path="${script_path/#\~/$HOME}"
  script_path="${script_path%% *}"

  if [[ ! -f "$script_path" ]]; then
    printf "[warn] %s (%s) — script not found: %s\n" "$label" "$event" "$script_path" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi

  # Get synthetic payload for this event type
  payload_var="PAYLOAD_${event}"
  payload="${!payload_var:-{}}"

  # Run hook with synthetic stdin; timeout 5s
  hook_stdout=""
  hook_exit=0
  if command -v timeout &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 timeout 5 bash "$script_path" 2>/dev/null) || hook_exit=$?
  elif command -v perl &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 perl -e 'alarm 5; exec @ARGV' bash "$script_path" 2>/dev/null) || hook_exit=$?
  else
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 bash "$script_path" 2>/dev/null) || hook_exit=$?
  fi

  if [[ $hook_exit -eq 124 || $hook_exit -eq 142 ]]; then
    printf "[warn] %s (%s) — hook timed out\n" "$label" "$event" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi

  # Validate output via contract validator (inline python — avoids re-running the full validator per hook)
  export CAST_CV_EVENT="$event"
  export CAST_CV_LABEL="$label"
  export CAST_CV_STDOUT="$hook_stdout"

  # Capture python output + exit code via temp file (portable across bash 3.2 / 4 / 5;
  # mixing heredoc with `; echo` inside $(...) breaks on macOS bash 3.2 — see PR #29 fix).
  # The `|| validate_exit=$?` keeps set -e from killing the script when python exits
  # non-zero (warnings/fails) — we need that exit code to classify, not abort.
  _cv_tmp=$(mktemp)
  validate_exit=0
  python3 - >"$_cv_tmp" 2>&1 <<'PYEOF' || validate_exit=$?
import json, os, sys

event = os.environ["CAST_CV_EVENT"]
label = os.environ["CAST_CV_LABEL"]
stdout_raw = os.environ.get("CAST_CV_STDOUT", "").strip()

KNOWN_TOP_LEVEL = {
    "SessionStart":       {"hookSpecificOutput"},
    "PostToolUse":        {"hookSpecificOutput"},
    "UserPromptSubmit":   {"hookSpecificOutput"},
    "PreToolUse":         {"decision", "reason", "hookSpecificOutput", "updatedInput"},
    "Stop":               {"decision", "reason", "continue"},
    "SubagentStop":       {"hookSpecificOutput"},
    "SessionEnd":         {"hookSpecificOutput"},
    "InstructionsLoaded": {"hookSpecificOutput"},
    "PreCompact":         {"decision", "reason"},
    "StopFailure":        {"hookSpecificOutput"},
    "PostToolUseFailure": {"hookSpecificOutput"},
}

if not stdout_raw:
    print(f"[ok] {label} ({event}) — empty stdout (logging-only, ok)")
    sys.exit(0)

try:
    data = json.loads(stdout_raw)
except json.JSONDecodeError as e:
    print(f"[fail] {label} ({event}) — non-JSON output: {e}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[fail] {label} ({event}) — output is not a JSON object", file=sys.stderr)
    sys.exit(2)

top_keys = set(data.keys())
allowed = KNOWN_TOP_LEVEL.get(event, None)
status = 0

if allowed is not None:
    unknown = top_keys - allowed
    if unknown:
        for k in sorted(unknown):
            print(f"[warn] {label} ({event}) — unknown key '{k}'", file=sys.stderr)
        status = max(status, 1)

if "hookSpecificOutput" in data:
    hso = data["hookSpecificOutput"]
    if not isinstance(hso, dict):
        print(f"[fail] {label} ({event}) — hookSpecificOutput is not an object (got {type(hso).__name__})", file=sys.stderr)
        sys.exit(2)
    emitted_name = hso.get("hookEventName", "")
    if emitted_name != event:
        print(f"[fail] {label} ({event}) — wrong hookEventName '{emitted_name}' (expected '{event}')", file=sys.stderr)
        sys.exit(2)
    elif "additionalContext" not in hso:
        print(f"[warn] {label} ({event}) — hookSpecificOutput missing 'additionalContext'", file=sys.stderr)
        status = max(status, 1)
    else:
        if status == 0:
            print(f"[ok] {label} ({event}) — shape valid")
elif event in {"SessionStart", "PostToolUse", "UserPromptSubmit", "InstructionsLoaded",
               "StopFailure", "PostToolUseFailure", "SubagentStop"}:
    if allowed:
        unknown = top_keys - allowed
        if not unknown and status == 0:
            print(f"[warn] {label} ({event}) — has output but no hookSpecificOutput", file=sys.stderr)
            status = max(status, 1)
    elif status == 0:
        print(f"[ok] {label} ({event}) — shape valid")
elif status == 0:
    print(f"[ok] {label} ({event}) — shape valid")

sys.exit(status)
PYEOF
  result=$(cat "$_cv_tmp")
  rm -f "$_cv_tmp"

  if [[ "$validate_exit" -eq 0 ]]; then
    printf '%s\n' "$result"
    OK_COUNT=$((OK_COUNT + 1))
  elif [[ "$validate_exit" -eq 1 ]]; then
    printf '%s\n' "$result" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
  else
    printf '%s\n' "$result" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

done <<< "$HOOK_LINES"

# ── Summary ───────────────────────────────────────────────────────────────
TOTAL=$((OK_COUNT + WARN_COUNT + FAIL_COUNT))
printf "\nvalidated %d hooks: %d ok, %d warn, %d fail\n" "$TOTAL" "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

# Exit policy: fails block CI; warnings are advisory and do NOT block.
# Use --strict to also fail on warnings (e.g. when tightening contracts).
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 2
elif [[ "${CAST_VALIDATE_STRICT:-0}" == "1" && $WARN_COUNT -gt 0 ]]; then
  exit 1
else
  exit 0
fi
