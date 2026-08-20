#!/usr/bin/env bash
# cast-validate-all-hooks.sh — CI-runnable hook output validator
#
# Reads settings.json (deployed ~/.claude/settings.json or repo settings.json),
# fires each wired hook with a synthetic stdin payload, pipes stdout through
# cast-validate-hook-contracts.sh, and aggregates results.
#
# Usage:
#   bash scripts/cast-validate-all-hooks.sh               # uses ~/.claude/settings.json (default)
#   bash scripts/cast-validate-all-hooks.sh --runtime     # uses ~/.claude/settings.json (explicit)
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
# --runtime: use ~/.claude/settings.json (default if no flag)
# --source:  use repo settings.json
MODE="runtime"
for arg in "$@"; do
  case "$arg" in
    --runtime) MODE="runtime" ;;
    --source)  MODE="source" ;;
    --help|-h)
      cat <<'HELP'
cast-validate-all-hooks.sh — validate hook contracts

Usage:
  bash scripts/cast-validate-all-hooks.sh [--runtime|--source]

Flags:
  --runtime    Validate ~/.claude/scripts/ hooks (reads ~/.claude/settings.json) [default]
  --source     Validate repo scripts/ hooks (reads repo settings.json)
  --help, -h   Show this message

Exit:
  0 = all ok
  1 = warnings (non-fatal)
  2 = at least one hook failed contract validation
HELP
      exit 0
      ;;
  esac
done

if [[ "$MODE" == "source" ]]; then
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
PAYLOAD_TeammateIdle='{"session_id":"test","agent_id":"agent_test","agent_type":"code-reviewer","teammate_name":"code-reviewer","team_name":"session-test"}'
PAYLOAD_TaskCompleted='{"session_id":"test","task_id":"task_test","task_subject":"Test task"}'
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
            has_args = "1" if "args" in hook else "0"
            if entry_id:
                label = entry_id
            else:
                parts = cmd.split()
                script_part = parts[-1] if parts else cmd
                label = os.path.basename(script_part)
            print(f"{event}\t{label}\t{has_args}\t{cmd}")
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
EXECUTED_COUNT=0
SKIPPED_COUNT=0

while IFS=$'\t' read -r event label has_args cmd; do
  # Resolve the script argument for an EXISTENCE pre-check. Scan tokens
  # and take the first one that looks like a path (contains '/', or
  # starts with '~'); fall back to token 0 if none does. This handles all
  # three shapes seen in settings.json:
  #   bash ~/.claude/scripts/foo.sh
  #   bash ~/.claude/scripts/cast-audit-hook.sh --mode post
  #   python3 ~/.claude/scripts/cast-pretool-dispatch.py
  # (the old `${cmd#bash }` decomposition only handled the first shape,
  # and only when the command literally started with "bash ").
  #
  # ⚠️ This scan is a DIAGNOSTIC HEURISTIC, not a safety boundary. It exists
  # to fail fast on a broken or typo'd hook registration; it does not parse
  # shell grammar, so an adversarially-shaped command could pass this check
  # while `sh -c` executes something else entirely. That is not a gap worth
  # closing here: anyone able to edit settings.json already gets the same
  # shell-form execution from Claude Code itself on every real hook fire.
  # Do not later mistake this for a security control.
  script_path=""
  for tok in $cmd; do
    case "$tok" in
      */* | '~'*)
        script_path="$tok"
        break
        ;;
    esac
  done
  if [[ -z "$script_path" ]]; then
    script_path="${cmd%% *}"
  fi
  script_path="${script_path/#\~/$HOME}"

  # Exec-form hooks (an `args` key) are not shell-form and are not
  # supported by this validator — fail loudly rather than mis-invoke.
  if [[ "$has_args" == "1" ]]; then
    printf "[fail] %s (%s) — hook uses exec form ('args' key); this validator only supports shell-form command hooks\n" "$label" "$event" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # An unresolvable script cannot possibly run — fail before attempting
  # execution. This MUST be a pre-check, not an exit-code inference: exit
  # 2 from a hook is a legitimate PreToolUse "block" result (see
  # cast-pretool-dispatch.py), not evidence the hook is broken, so exit
  # status alone cannot distinguish "blocked the call" from "interpreter
  # could not open the script."
  if [[ ! -f "$script_path" ]]; then
    printf "[fail] %s (%s) — script not found: %s\n" "$label" "$event" "$script_path" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Get synthetic payload for this event type
  payload_var="PAYLOAD_${event}"
  payload="${!payload_var:-{}}"

  # Run hook exactly as Claude Code does: the full command string handed
  # whole to `sh -c` (shell form — no splitting/truncation, no forced
  # interpreter; `sh` performs its own tilde expansion).
  hook_stdout=""
  hook_exit=0
  EXECUTED_COUNT=$((EXECUTED_COUNT + 1))
  if command -v timeout &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 timeout 5 sh -c "$cmd" 2>/dev/null) || hook_exit=$?
  elif command -v perl &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 perl -e 'alarm 5; exec @ARGV' sh -c "$cmd" 2>/dev/null) || hook_exit=$?
  else
    hook_stdout=$(printf '%s' "$payload" | CLAUDE_SUBPROCESS=0 sh -c "$cmd" 2>/dev/null) || hook_exit=$?
  fi

  if [[ $hook_exit -eq 124 || $hook_exit -eq 142 ]]; then
    printf "[warn] %s (%s) — hook timed out\n" "$label" "$event" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi

  # Backstop only: the pre-check above should have already caught an
  # unresolvable script. 126 = found but not executable by the shell,
  # 127 = command not found — this catches shapes the token-scan missed
  # (e.g. a bare PATH command with no '/' that isn't actually on PATH).
  # Deliberately NOT extended to other exit codes: exit 2 is a legitimate
  # PreToolUse "block" result and must not be misread as broken.
  if [[ $hook_exit -eq 126 || $hook_exit -eq 127 ]]; then
    printf "[fail] %s (%s) — hook could not be executed (exit %d; resolved path: %s)\n" "$label" "$event" "$hook_exit" "$script_path" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
# Report executed vs skipped explicitly — a hook that was never executed
# (e.g. exec-form 'args' hooks) must not be able to hide inside "validated".
TOTAL=$((OK_COUNT + WARN_COUNT + FAIL_COUNT))
printf "\nvalidated %d hooks (%d executed, %d skipped): %d ok, %d warn, %d fail\n" \
  "$TOTAL" "$EXECUTED_COUNT" "$SKIPPED_COUNT" "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

# Exit policy: fails block CI; warnings are advisory and do NOT block.
# Use --strict to also fail on warnings (e.g. when tightening contracts).
if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 2
elif [[ "${CAST_VALIDATE_STRICT:-0}" == "1" && $WARN_COUNT -gt 0 ]]; then
  exit 1
else
  exit 0
fi
