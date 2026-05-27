#!/usr/bin/env bash
# cast-tilde-write-guard.sh — PreToolUse hook: block Write/Edit to literal-tilde paths.
#
# Reason: Claude Code's plan-mode harness has a path-construction bug where
# `~/.claude/plans/<name>.md` is joined with cwd instead of being expanded
# to $HOME first. This produces paths like `<cwd>/~/.claude/plans/<name>.md`,
# which writes a literal `~` directory rather than into $HOME.
#
# Symptom: phantom `~/` subdirectories under cwd containing trapped plan files.
# Root cause: upstream Claude Code (not user-fixable). This hook is the
# downstream mitigation — fails fast so the bug surfaces rather than silently
# accumulating filesystem artifacts.
#
# Wired via matcher: Write|Edit pattern (see managed-settings.d/25-hooks-security.json
# — bare 'if' form did not fire in plan mode).
#
# Recovery dir from initial sweep: ~/.claude/plans/_recovered-tilde-bug-2026-05-26

set -euo pipefail

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# Extract file_path from tool_input
FILE_PATH="$(echo "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
' 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

# Detect literal `~` as a path segment (between two slashes, or trailing).
# This catches /Users/edkubiak/Desktop/~/.claude/plans/foo.md
# but NOT a leading ~/foo or ~ followed by anything that isn't a path sep.
if [[ "$FILE_PATH" == *"/~/"* ]] || [[ "$FILE_PATH" == */~ ]]; then
  # Compute the corrected canonical path (assume the intent was $HOME)
  if [[ "$FILE_PATH" == *"/~/"* ]]; then
    SUFFIX="${FILE_PATH#*/~/}"
    CORRECTED="$HOME/$SUFFIX"
  elif [[ "$FILE_PATH" == */~ ]]; then
    CORRECTED="$HOME"
  fi

  # Log the incident
  mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] BLOCK literal-tilde write: $FILE_PATH" \
    >> "$HOME/.claude/logs/tilde-guard.log" 2>/dev/null || true

  cat >&2 <<EOF
BLOCKED: Write attempt to literal-tilde path.

Path:      $FILE_PATH
Likely intended: $CORRECTED

The literal '~' as a directory segment is a plan-mode harness path bug —
it creates a phantom subdirectory under cwd instead of expanding to \$HOME.

Action: rewrite the path using the corrected form above ($HOME-prefixed),
then retry the Write.

Logged to: ~/.claude/logs/tilde-guard.log
EOF
  exit 2
fi

exit 0
