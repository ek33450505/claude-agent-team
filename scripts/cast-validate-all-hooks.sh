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
  --runtime    Validate installed ~/.claude/scripts/ hooks (reads ~/.claude/settings.json)
               [default]
  --source     Validate this repo's working-tree scripts/ hooks (reads repo settings.json;
               hook commands pointing at ~/.claude/scripts/<name> are rewritten to
               the sandbox's seeded copy of <repo-root>/scripts/<name> before executing,
               so a fix or regression that exists only in the working tree is what
               actually runs here — inside a throwaway HOME, never the repo tree)
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
HOOK_LINES=$(python3 -I - <<'PYEOF'
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

# ── Hook sandbox (isolation) ──────────────────────────────────────────────
# Hooks are fed VALID synthetic JSON, so their real logic runs (journal writes,
# memory saves, cast.db inserts, notifications, ...). They must never touch the
# caller's real HOME / ~/.claude / cast.db / repo cwd. Every hook therefore runs
# against a throwaway HOME seeded by COPY (never symlink — a hook writing into
# its ~/.claude/scripts must not reach the source) from the scripts/config this
# run is validating: the repo's under --source, the installed ones under
# --runtime (read here, BEFORE any hook sees a swapped HOME).
# Keep in sync with cast-validate-hook-contracts.sh (identical isolation block).
_VH_TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || {
  echo "[cast-validate-all-hooks] ERROR: TMPDIR not usable: ${TMPDIR:-/tmp}" >&2
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
    echo "[cast-validate-all-hooks] WARN: guard lib unavailable; sandbox left at $h" >&2
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
    echo "[cast-validate-all-hooks] WARN: sandbox seed from $1 incomplete" >&2
  _vh_reject_links "$2"
}
if [[ "$MODE" == "source" ]]; then
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

# ── Per-hook validation counters ──────────────────────────────────────────
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
EXECUTED_COUNT=0
SKIPPED_COUNT=0

while IFS=$'\t' read -r event label has_args cmd; do
  # --source rewrite: settings.json's hook commands always point at the
  # INSTALLED copy (~/.claude/scripts/<name>, or the literal $HOME form),
  # even under --source. Without this, --source read the repo's
  # settings.json but still EXECUTED the installed ~/.claude/scripts/<name> —
  # a working-tree-only fix or regression could never be caught here, and a
  # stale installed copy could decide the verdict. Fix: a literal prefix
  # substitution on the two known forms only (NOT shell-grammar parsing — see
  # the script_path scan comment below for why that boundary matters) to the
  # sandbox's seeded scripts dir, which under --source is a COPY of
  # <repo>/scripts. Executing that copy (not the repo path itself) means a
  # hook's own dirname-$0 / sibling-script paths resolve inside the throwaway
  # sandbox too, never the repo tree. Any other shape (already absolute, or
  # pointing elsewhere) passes through unchanged. If the rewritten path
  # doesn't exist in the repo, the existing existence pre-check below
  # reports it as [fail] (shown with the repo path), not a silent skip.
  # Keep in sync with the identical rewrite in cast-validate-hook-contracts.sh.
  if [[ "$MODE" == "source" ]]; then
    cmd="${cmd//\$HOME\/.claude\/scripts\//$_VH_SCRIPTS}"
    cmd="${cmd//~\/.claude\/scripts\//$_VH_SCRIPTS}"
  fi

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
  # Diagnostics name the REPO path under --source (the sandbox copy is an
  # implementation detail of where the repo's script actually runs).
  script_shown="$script_path"
  if [[ "$MODE" == "source" ]]; then
    script_shown="${script_path/#"$_VH_SCRIPTS"/$REPO_DIR/scripts/}"
  fi

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
    printf "[fail] %s (%s) — script not found: %s\n" "$label" "$event" "$script_shown" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Get synthetic payload for this event type
  payload_var="PAYLOAD_${event}"
  # NOT ${!payload_var:-{}} — that expansion ends at the FIRST '}' so a set
  # variable yielded its value plus a stray '}' (every hook saw invalid JSON).
  payload="${!payload_var-}"
  [[ -n "$payload" ]] || payload='{}'

  # Run hook exactly as Claude Code does: the full command string handed
  # whole to `sh -c` (shell form — no splitting/truncation, no forced
  # interpreter; `sh` performs its own tilde expansion).
  hook_stdout=""
  hook_exit=0
  EXECUTED_COUNT=$((EXECUTED_COUNT + 1))
  if command -v timeout &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | _vh_run timeout 5 sh -c "$cmd" 2>/dev/null) || hook_exit=$?
  elif command -v perl &>/dev/null; then
    hook_stdout=$(printf '%s' "$payload" | _vh_run perl -e 'alarm 5; exec @ARGV' sh -c "$cmd" 2>/dev/null) || hook_exit=$?
  else
    hook_stdout=$(printf '%s' "$payload" | _vh_run sh -c "$cmd" 2>/dev/null) || hook_exit=$?
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
    printf "[fail] %s (%s) — hook could not be executed (exit %d; resolved path: %s)\n" "$label" "$event" "$hook_exit" "$script_shown" >&2
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
  python3 -I - >"$_cv_tmp" 2>&1 <<'PYEOF' || validate_exit=$?
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

# Top-level decision (EVERY event): Claude Code accepts only "approve" or "block"
# ("decision: Invalid option: expected one of approve|block"); to proceed, print nothing.
# Checked first so a failure suppresses the "[ok] shape valid" lines below.
# Keep in sync with the identical check in cast-validate-hook-contracts.sh.
if "decision" in data:
    decision = data.get("decision")
    if decision not in ("approve", "block"):
        print(f"[fail] {label} ({event}) — invalid top-level decision value {decision!r} (Claude Code accepts only approve|block)", file=sys.stderr)
        status = max(status, 2)

if allowed is not None:
    unknown = top_keys - allowed
    if unknown:
        for k in sorted(unknown):
            print(f"[warn] {label} ({event}) — unknown key {k!r}", file=sys.stderr)
        status = max(status, 1)

if "hookSpecificOutput" in data:
    hso = data["hookSpecificOutput"]
    if not isinstance(hso, dict):
        print(f"[fail] {label} ({event}) — hookSpecificOutput is not an object (got {type(hso).__name__})", file=sys.stderr)
        sys.exit(2)
    emitted_name = hso.get("hookEventName", "")
    if emitted_name != event:
        print(f"[fail] {label} ({event}) — wrong hookEventName {emitted_name!r} (expected '{event}')", file=sys.stderr)
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
