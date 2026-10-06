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
# Args: event, label, path of the file holding the hook's captured stdout, timed_out (0|1).
# The output is read as BYTES from that file: a `$(...)` capture drops NUL bytes, so
# `{"a":1}\0garbage` would otherwise look valid.
_validate_output() {
  local event_name="$1"
  local hook_label="$2"
  local hook_stdout_file="$3"
  local hook_timed_out="$4"

  export CAST_CV_EVENT="$event_name"
  export CAST_CV_LABEL="$hook_label"
  export CAST_CV_STDOUT_FILE="$hook_stdout_file"
  export CAST_CV_TIMED_OUT="$hook_timed_out"

  python3 -I - <<'PYEOF'
import json
import os
import sys

event = os.environ["CAST_CV_EVENT"]
label = os.environ["CAST_CV_LABEL"]
timed_out = os.environ.get("CAST_CV_TIMED_OUT", "0") == "1"
note = " (hook also timed out; output captured before the kill)" if timed_out else ""

# Fail closed if the capture file cannot be read.
try:
    with open(os.environ["CAST_CV_STDOUT_FILE"], "rb") as f:
        raw = f.read()
except (OSError, KeyError) as e:
    print(f"[fail] {label} ({event}) — cannot read captured hook output: {e}", file=sys.stderr)
    sys.exit(2)

if b"\0" in raw:
    print(f"[fail] {label} ({event}) — output contains NUL bytes{note}", file=sys.stderr)
    sys.exit(2)

# surrogateescape: non-UTF-8 bytes survive decoding exactly as they did via the old
# environment-variable hand-off (this check is about NUL / JSON shape, not encoding).
stdout_raw = raw.decode("utf-8", errors="surrogateescape").strip()

# Empty stdout is valid for all logging-only events
if not stdout_raw:
    print(f"[ok] {label} ({event}) — empty stdout (logging-only, ok)")
    sys.exit(0)

# Try to parse as JSON
try:
    data = json.loads(stdout_raw)
except json.JSONDecodeError as e:
    print(f"[fail] {label} ({event}) — non-JSON output: {e}{note}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[fail] {label} ({event}) — output is not a JSON object{note}", file=sys.stderr)
    sys.exit(2)

# --- Contract definitions ---
# Claude Code accepts these common JSON fields from EVERY hook event.
COMMON = {"continue", "stopReason", "suppressOutput", "systemMessage"}
# Per-event allowed top-level keys = COMMON + the event's own. NOTE: PreToolUse's
# `updatedInput` belongs INSIDE hookSpecificOutput, never at top level.
# Keep in sync with the identical table in cast-validate-all-hooks.sh.
KNOWN_TOP_LEVEL = {
    "SessionStart":       COMMON | {"hookSpecificOutput"},
    "PostToolUse":        COMMON | {"hookSpecificOutput", "decision", "reason"},
    "UserPromptSubmit":   COMMON | {"hookSpecificOutput", "decision", "reason"},
    "PreToolUse":         COMMON | {"decision", "reason", "hookSpecificOutput"},
    "Stop":               COMMON | {"decision", "reason"},
    "SubagentStop":       COMMON | {"hookSpecificOutput", "decision", "reason"},
    "SessionEnd":         COMMON | {"hookSpecificOutput"},
    "InstructionsLoaded": COMMON | {"hookSpecificOutput"},
    "PreCompact":         COMMON | {"decision", "reason"},
    "StopFailure":        COMMON | {"hookSpecificOutput"},
    "PostToolUseFailure": COMMON | {"hookSpecificOutput"},
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
            print(f"[warn] {label} ({event}) — unknown key {k!r} (harness silently ignores it)", file=sys.stderr)
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
            print(f"[fail] {label} ({event}) — wrong hookEventName {emitted_name!r} (expected '{event}')", file=sys.stderr)
            status = max(status, 2)
        elif "additionalContext" not in hso:
            print(f"[warn] {label} ({event}) — hookSpecificOutput missing 'additionalContext'", file=sys.stderr)
            status = max(status, 1)
        else:
            if status == 0:
                print(f"[ok] {label} ({event}) — shape valid")

elif event in REQUIRES_HOOK_SPECIFIC:
    # No hookSpecificOutput. An EMPTY object is output that carries nothing (warn);
    # a body of valid common/decision keys (e.g. {"systemMessage": "..."}) is fine.
    # (A top-level decision prints its own [ok]/[fail] line below.)
    if not top_keys:
        if status == 0:
            print(f"[warn] {label} ({event}) — has output but no hookSpecificOutput", file=sys.stderr)
            status = max(status, 1)
    elif status == 0 and "decision" not in data:
        print(f"[ok] {label} ({event}) — shape valid")

# Validate the top-level decision field (EVERY event). Claude Code's hook-output validation accepts
# only "approve" or "block" here ("decision: Invalid option: expected one of approve|block");
# anything else (allow, continue, deny, ask, ...) is rejected at runtime. To proceed, print nothing.
# Keep in sync with the identical check in cast-validate-all-hooks.sh.
if "decision" in data:
    decision = data.get("decision")
    if decision not in ("approve", "block"):
        print(f"[fail] {label} ({event}) — invalid top-level decision value {decision!r} (Claude Code accepts only approve|block)", file=sys.stderr)
        status = max(status, 2)
    elif status == 0:
        print(f"[ok] {label} ({event}) — shape valid (decision={decision})")

sys.exit(status)
PYEOF
}

# --- Iterate hooks from settings.json ---
export CAST_CV_SETTINGS="$SETTINGS_FILE"
HOOK_LINES=$(python3 -I - <<'PYEOF'
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
            has_args = "1" if "args" in hook else "0"
            # label: prefer id, else basename of script
            if entry_id:
                label = entry_id
            else:
                # extract script basename from command
                parts = cmd.split()
                script_part = parts[-1] if parts else cmd
                label = os.path.basename(script_part)
            print(f"{event}\t{label}\t{has_args}\t{cmd}")
PYEOF
)

if [[ -z "$HOOK_LINES" ]]; then
  echo "[cast-validate-hook-contracts] No command hooks found in $SETTINGS_FILE" >&2
  exit 0
fi

# --- Hook sandbox (isolation) ---
# Hooks are fed VALID synthetic JSON, so their real logic runs (journal writes,
# memory saves, cast.db inserts, notifications, ...). They must never touch the
# caller's real HOME / ~/.claude / cast.db / repo cwd. Every hook therefore runs
# against a throwaway HOME seeded by COPY (never symlink — a hook writing into
# its ~/.claude/scripts must not reach the source) from the scripts/config this
# run is validating: the repo's under --source, the installed ones otherwise
# (read here, BEFORE any hook sees a swapped HOME).
# Keep in sync with cast-validate-all-hooks.sh (identical isolation block).
_VH_TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || {
  echo "[cast-validate-hook-contracts] ERROR: TMPDIR not usable: ${TMPDIR:-/tmp}" >&2
  exit 2
}
VALIDATE_HOME="$(mktemp -d "$_VH_TMP_ROOT/cast-validate-home.XXXXXX")"
touch "$VALIDATE_HOME/.cast-test-home" # sentinel: install.sh/launchctl guards

# Guard primitive (blast-radius lint: no bare recursive force-delete in scripts/).
# Existence-checked before `source` (Apple bash 3.2 treats a missing source as fatal).
_vh_guard_lib="$SCRIPT_DIR/cast-guard-lib.sh"
[[ -f "$_vh_guard_lib" ]] || _vh_guard_lib="$HOME/.claude/scripts/cast-guard-lib.sh"
if [[ -f "$_vh_guard_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_vh_guard_lib" 2>/dev/null || true
fi

# Remove the sandbox ONLY if it still carries the sentinel AND sits directly
# under the resolved temp root with our prefix (never a path built from input).
# Fail-closed: without the guard lib the sandbox is left in place, with a note.
# shellcheck disable=SC2329 # invoked via the EXIT trap below
_vh_cleanup() {
  local h="${VALIDATE_HOME:-}"
  [[ -n "$h" && "$h" != *..* && -f "$h/.cast-test-home" &&
    "$h" == "$_VH_TMP_ROOT"/cast-validate-home.* ]] || return 0
  if declare -f cast_safe_rm >/dev/null 2>&1; then
    cast_declare_blast_radius "$_VH_TMP_ROOT/cast-validate-home."
    cast_safe_rm "$h" || true
  else
    echo "[cast-validate-hook-contracts] WARN: guard lib unavailable; sandbox left at $h" >&2
  fi
}
trap _vh_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$VALIDATE_HOME/.claude/scripts" "$VALIDATE_HOME/.claude/logs" \
  "$VALIDATE_HOME/.claude/config" "$VALIDATE_HOME/work" "$VALIDATE_HOME/shim" \
  "$VALIDATE_HOME/tmp"
# Where hooks find their scripts: the seeded sandbox copy (see the --source rewrite).
_VH_SCRIPTS="$VALIDATE_HOME/.claude/scripts/"

# Fail closed (exit 2, before any hook runs) on ANY symlink under $1, skipping
# __pycache__. A dereferencing copy (tar -h) would pull outside trees in (e.g. a link to
# $HOME), and a preserved dangling link would let a hook write through it. Neither
# scripts/ nor config/ legitimately contains symlinks.
_vh_reject_links() {
  local links
  links="$(find "$1" -name __pycache__ -prune -o -type l -print 2>/dev/null | head -5)" || true
  if [[ -n "$links" ]]; then
    printf '[fail] seed source contains symlinks: %s\n' "$(printf '%s' "$links" | tr '\n' ' ')" >&2
    exit 2
  fi
}

# Copy src dir contents into dst, skipping __pycache__. The source is checked BEFORE the
# copy (cheap early refusal) and the private sandbox copy AFTER it: the source can change
# between the check and tar's read (TOCTOU), the sandbox copy cannot. (tar, not cp+delete:
# nothing is ever removed here.)
_vh_seed() {
  [[ -d "$1" ]] || return 0
  _vh_reject_links "$1"
  { (cd "$1" && tar -cf - --exclude=__pycache__ .) | (cd "$2" && tar -xf -); } 2>/dev/null ||
    echo "[cast-validate-hook-contracts] WARN: sandbox seed from $1 incomplete" >&2
  _vh_reject_links "$2"
}
if [[ "$USE_SOURCE" == "1" ]]; then
  _vh_seed "$REPO_DIR/scripts" "$VALIDATE_HOME/.claude/scripts"
  _vh_seed "$REPO_DIR/config" "$VALIDATE_HOME/.claude/config"
else
  _vh_seed "$HOME/.claude/scripts" "$VALIDATE_HOME/.claude/scripts"
  _vh_seed "$HOME/.claude/config" "$VALIDATE_HOME/.claude/config"
fi

# No-op GUI / daemon / spend side-effect commands, prepended to PATH for hooks.
for _vh_name in osascript terminal-notifier notify-send afplay say open launchctl claude; do
  printf '#!/bin/sh\nexit 0\n' >"$VALIDATE_HOME/shim/$_vh_name"
  chmod +x "$VALIDATE_HOME/shim/$_vh_name"
done

# Hooks run under `env -i` with an ALLOWLIST: a denylist by name pattern cannot enumerate
# every state-pointing variable (CAST_DB_URL, CAST_JOURNAL_VAULT, CAST_*_ROOT, CAST_*_CMD,
# CLAUDE_PLUGIN_ROOT, BASH_ENV, ENV, PYTHON*, GIT_*, ...). Only locale/terminal/identity
# vars pass through from the caller; everything else is the explicit sandbox set below.
_VH_ENV_ARGS=()
while IFS= read -r _vh_var; do
  case "$_vh_var" in
    LANG | LC_* | TERM | USER | LOGNAME | SHELL)
      _VH_ENV_ARGS+=("$_vh_var=${!_vh_var}")
      ;;
  esac
done < <(compgen -e)

# Run "$@" inside the sandbox. Called as a pipeline stage (own subshell), so the
# cd cannot leak into this script. TMPDIR/TMP/TEMP point at the sandbox: hooks keep
# state flags and logs in the temp dir, and must never touch the caller's real one
# (the VALIDATOR still creates the sandbox itself under the caller's TMPDIR).
# GIT_CEILING_DIRECTORIES stops git discovery climbing out of the sandbox: a caller TMPDIR
# inside a work tree (CI: TMPDIR=<repo>/tmp) would otherwise resolve the CALLER's repo.
_vh_run() {
  cd "$VALIDATE_HOME/work" || return 126
  env -i ${_VH_ENV_ARGS[@]+"${_VH_ENV_ARGS[@]}"} \
    HOME="$VALIDATE_HOME" \
    CAST_DB_PATH="$VALIDATE_HOME/.claude/cast.db" \
    CLAUDE_PROJECT_DIR="$VALIDATE_HOME/work" \
    TMPDIR="$VALIDATE_HOME/tmp" TMP="$VALIDATE_HOME/tmp" TEMP="$VALIDATE_HOME/tmp" \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="$VALIDATE_HOME/shim:$PATH" \
    GIT_CEILING_DIRECTORIES="$VALIDATE_HOME" \
    CLAUDE_SUBPROCESS=0 \
    "$@"
}

while IFS=$'\t' read -r event label has_args cmd; do
  # --source rewrite: settings.json's hook commands always point at the INSTALLED copy
  # (~/.claude/scripts/<name>, or the literal $HOME form), even under --source. Without this,
  # --source read the repo's settings.json but still EXECUTED the installed copy, so a
  # stale installed copy failed a correct tree and a working-tree fix/regression was never seen.
  # Literal prefix substitution on the two known forms only; any other shape passes through.
  # The target is the sandbox's seeded scripts dir, which under --source is a COPY of
  # <repo>/scripts: a hook's own dirname-$0 / sibling-script paths then resolve inside the
  # throwaway sandbox too, never the repo tree.
  # Keep in sync with the identical rewrite in cast-validate-all-hooks.sh.
  if [[ "$USE_SOURCE" == "1" ]]; then
    cmd="${cmd//\$HOME\/.claude\/scripts\//$_VH_SCRIPTS}"
    cmd="${cmd//~\/.claude\/scripts\//$_VH_SCRIPTS}"
  fi
  # Resolve the script argument for an EXISTENCE pre-check. Scan tokens and take the
  # first one that looks like a path (contains '/', or starts with '~'); fall back to
  # token 0 if none does. Handles `bash ~/.claude/scripts/foo.sh`, the same with extra
  # flags, and `python3 ~/.claude/scripts/cast-pretool-dispatch.py` (the old
  # `${cmd#bash }` decomposition only handled the first shape, so a python3 hook was
  # "script not found: python3" and never executed). `~` expands against the SANDBOX
  # home (not the caller's HOME) so the existence check and the execution below agree
  # on the seeded copy the hook actually runs.
  # ⚠️ DIAGNOSTIC HEURISTIC, not a safety boundary: it does not parse shell grammar, so
  # an adversarially-shaped command could pass this check while `sh -c` runs something
  # else. Anyone able to edit settings.json already gets the same shell-form execution
  # from Claude Code on every real hook fire.
  # Keep in sync with the identical scan in cast-validate-all-hooks.sh.
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
  script_path="${script_path/#\~/$VALIDATE_HOME}"
  # Diagnostics name the REPO path under --source (the sandbox copy is an
  # implementation detail of where the repo's script actually runs).
  script_shown="$script_path"
  if [[ "$USE_SOURCE" == "1" ]]; then
    script_shown="${script_path/#"$_VH_SCRIPTS"/$REPO_DIR/scripts/}"
  fi

  # Exec-form hooks (an `args` key) are not shell-form and are not supported here —
  # fail loudly rather than mis-invoke (same as cast-validate-all-hooks.sh).
  if [[ "$has_args" == "1" ]]; then
    echo "[fail] $label ($event) — hook uses exec form ('args' key); this validator only supports shell-form command hooks" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  if [[ ! -f "$script_path" ]]; then
    echo "[warn] $label ($event) — script not found: $script_shown" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    continue
  fi

  # Get payload for this event
  payload_var="PAYLOAD_${event}"
  # NOT ${!payload_var:-{}} — that expansion ends at the FIRST '}' so a set
  # variable yielded its value plus a stray '}' (every hook saw invalid JSON).
  payload="${!payload_var-}"
  [[ -n "$payload" ]] || payload='{}'

  # Run the hook exactly as Claude Code does: the full command string handed whole to
  # `sh -c` (shell form — no splitting/truncation, no forced interpreter; `sh` does its
  # own tilde expansion, against the sandbox HOME). CLAUDE_SUBPROCESS=0 is enforced by
  # _vh_run. Timeout: 5s to prevent hangs (macOS-compatible via perl).
  # stdout goes to a FILE in the sandbox tmp, never `$(...)`: command substitution
  # silently drops NUL bytes, so `{"a":1}\0garbage` would look valid. The python check
  # reads the file as BYTES. mktemp (random name) so a hook cannot pre-plant a
  # predictable path (symlink) in the sandbox tmp to redirect this write.
  # Keep in sync with the identical capture in cast-validate-all-hooks.sh.
  hook_out="$(mktemp "$VALIDATE_HOME/tmp/out.XXXXXX")"
  hook_exit=0
  if command -v timeout &>/dev/null; then
    echo "$payload" | _vh_run timeout 5 sh -c "$cmd" >"$hook_out" 2>/dev/null || hook_exit=$?
  elif command -v perl &>/dev/null; then
    echo "$payload" | _vh_run perl -e 'alarm 5; exec @ARGV' sh -c "$cmd" >"$hook_out" 2>/dev/null || hook_exit=$?
  else
    echo "$payload" | _vh_run sh -c "$cmd" >"$hook_out" 2>/dev/null || hook_exit=$?
  fi

  # A timed-out hook is NOT skipped: whatever it printed before the kill is still
  # validated below (invalid / NUL output is an error, not a warn). Only an empty or
  # valid-so-far capture stays the advisory timeout warn.
  timed_out=0
  if [[ $hook_exit -eq 124 || $hook_exit -eq 142 ]]; then
    timed_out=1
  fi

  # Backstop only: the pre-check above should have caught an unresolvable script.
  # 126 = found but not executable by the shell, 127 = command not found (catches shapes
  # the token-scan missed). Deliberately NOT extended to other exit codes: a non-zero
  # exit is ok for PreToolUse block hooks (exit 2 = block) — stdout is still validated.
  if [[ $timed_out -eq 0 && ($hook_exit -eq 126 || $hook_exit -eq 127) ]]; then
    rm -f "$hook_out"
    echo "[fail] $label ($event) — hook could not be executed (exit $hook_exit; resolved path: $script_shown)" >&2
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # Validate output shape
  # Capture exit code separately to avoid set -e triggering on non-zero exit
  result=$(_validate_output "$event" "$label" "$hook_out" "$timed_out" 2>&1; echo "CAST_EXIT:$?")
  validate_exit="${result##*CAST_EXIT:}"
  result="${result%$'\n'CAST_EXIT:*}"
  rm -f "$hook_out"

  # Print validation result to stdout/stderr as appropriate
  if [[ $timed_out -eq 1 ]]; then
    if [[ $validate_exit -ge 2 ]]; then
      echo "$result" >&2
      ERROR_COUNT=$((ERROR_COUNT + 1))
    else
      echo "[warn] $label ($event) — hook timed out after 5s" >&2
      WARN_COUNT=$((WARN_COUNT + 1))
    fi
  elif [[ $validate_exit -eq 0 ]]; then
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
