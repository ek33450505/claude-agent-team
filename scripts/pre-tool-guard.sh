#!/bin/bash
# pre-tool-guard.sh — CAST PreToolUse hook for Bash tool
# Blocks operations that must go through designated agents.
# Exit 2 = hard block (Claude cannot bypass). Exit 0 = allow.
#
# Blocked operations:
#   git commit  → use commit agent (escape hatch: CAST_COMMIT_AGENT=1)
#   git push    → use commit agent workflow (escape hatch: CAST_PUSH_OK=1)

INPUT="$(cat)"
TOOL="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)"
CMD="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)"

# Only intercept Bash tool
[ "$TOOL" != "Bash" ] && exit 0

# --- git commit block ---
# Allow if commit agent escape hatch is inline
if echo "$CMD" | grep -q "CAST_COMMIT_AGENT=1"; then
  exit 0
fi
# Block raw git commit
if echo "$CMD" | grep -qE "(^| )git commit"; then
  echo "**[CAST]** Raw \`git commit\` blocked. Dispatch the \`commit\` agent instead (Agent tool, subagent_type: 'commit')."
  exit 2
fi

# --- git push block ---
# Allow if push escape hatch is inline
if echo "$CMD" | grep -q "CAST_PUSH_OK=1"; then
  exit 0
fi
# Block raw git push
if echo "$CMD" | grep -qE "(^| )git push"; then
  echo "**[CAST]** Raw \`git push\` blocked. Ensure code-reviewer has run, then use \`CAST_PUSH_OK=1 git push\` or dispatch via the commit agent workflow."
  exit 2
fi

exit 0
