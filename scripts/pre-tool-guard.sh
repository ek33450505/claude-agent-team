#!/bin/bash
# pre-tool-guard.sh — CAST PreToolUse hook for Bash tool
# Blocks operations that must go through designated agents.
# Exit 2 = hard block (Claude cannot bypass). Exit 0 = allow.
#
# Blocked operations:
#   git commit  → use commit agent (escape hatch: CAST_COMMIT_AGENT=1 git commit ...)
#   git push    → use commit agent workflow (escape hatch: CAST_PUSH_OK=1 git push ...)
#
# SECURITY: Escape hatch MUST appear as a leading env var assignment before the git command.
# It cannot appear only inside a commit message, comment, or echo — those are blocked.
# Valid:   CAST_COMMIT_AGENT=1 git commit -m "message"
# Invalid: git commit -m "CAST_COMMIT_AGENT=1"  (message injection — blocked)
# Invalid: echo "CAST_COMMIT_AGENT=1" && git commit  (chained echo — blocked)

set -euo pipefail

INPUT="$(cat)"
TOOL="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")"
CMD="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")"

# Only intercept Bash tool
[ "$TOOL" != "Bash" ] && exit 0

# --- git commit block ---
# Allow ONLY if escape hatch is a leading env assignment immediately before git commit
if echo "$CMD" | grep -qE "^CAST_COMMIT_AGENT=1[[:space:]]+git[[:space:]]+commit"; then
  exit 0
fi
# Block any other git commit invocation
if echo "$CMD" | grep -qE "(^|[[:space:]])git[[:space:]]+commit"; then
  echo "**[CAST]** Raw \`git commit\` blocked. Dispatch the \`commit\` agent instead (Agent tool, subagent_type: 'commit')."
  exit 2
fi

# --- git push block ---
# Allow ONLY if escape hatch is a leading env assignment immediately before git push
if echo "$CMD" | grep -qE "^CAST_PUSH_OK=1[[:space:]]+git[[:space:]]+push"; then
  exit 0
fi
# Block any other git push invocation
if echo "$CMD" | grep -qE "(^|[[:space:]])git[[:space:]]+push"; then
  echo "**[CAST]** Raw \`git push\` blocked. Ensure code-reviewer has run, then use \`CAST_PUSH_OK=1 git push\` or dispatch via the commit agent workflow."
  exit 2
fi

exit 0
