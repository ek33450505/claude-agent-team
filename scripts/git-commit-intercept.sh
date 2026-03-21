#!/bin/bash
# CAST PreToolUse hook — blocks raw git commit and redirects to commit agent
# Claude Code passes tool JSON on stdin; exit 2 = block the tool call

INPUT="$(cat)"
TOOL="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)"
CMD="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)"

# Only intercept Bash tool
[ "$TOOL" != "Bash" ] && exit 0

# Skip if escape hatch is inline in the command (commit agent uses: CAST_COMMIT_AGENT=1 git commit ...)
if echo "$CMD" | grep -q "CAST_COMMIT_AGENT=1"; then
  exit 0
fi

# Block raw git commit
if echo "$CMD" | grep -qE "(^| )git commit"; then
  echo "**[CAST PreToolUse]** Raw git commit blocked. Use the commit agent instead (Agent tool, subagent_type: 'commit'). Stage files with git add first, then delegate to the commit agent."
  exit 2
fi

exit 0
