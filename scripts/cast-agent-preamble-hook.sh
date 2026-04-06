#!/bin/bash
# cast-agent-preamble-hook.sh — CAST PreToolUse hook for agent preamble injection
# Hook event: PreToolUse (matcher: Task)
#
# Injects procedural memories into Agent tool calls by calling cast-agent-preamble.py.
#
# Stdin JSON fields (PreToolUse format):
#   tool_name  — name of the tool being called
#   tool_input — tool arguments (contains description/prompt with agent name hints)
#
# Exit codes:
#   0 — always (hook must not block agent dispatch)
#
# Wiring in ~/.claude/settings.json:
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Task",
#           "hooks": [{ "type": "command", "command": "bash /Users/edkubiak/Projects/personal/claude-agent-team/scripts/cast-agent-preamble-hook.sh" }]
#         }
#       ]
#     }
#   }

# Never fail loudly — a broken hook must not interrupt agent dispatch.
set +e

PREAMBLE_SCRIPT="/Users/edkubiak/Projects/personal/claude-agent-team/scripts/cast-agent-preamble.py"

# Read stdin once
INPUT="$(cat 2>/dev/null)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Parse tool_name — exit immediately if not Task (Agent tool)
export CAST_PREAMBLE_INPUT="$INPUT"

TOOL_NAME="$(python3 -c "import json,os; d=json.loads(os.environ.get('CAST_PREAMBLE_INPUT','{}')); print(d.get('tool_name',''))" 2>/dev/null || echo "")"

if [ "$TOOL_NAME" != "Task" ]; then
  exit 0
fi

# Extract agent name hint from tool_input
# Look for subagent_type field, or extract first word from description
AGENT_NAME="$(python3 - <<'PYEOF' 2>/dev/null
import json, os, re

raw = os.environ.get('CAST_PREAMBLE_INPUT', '{}')
try:
    data = json.loads(raw)
except Exception:
    print('unknown')
    raise SystemExit(0)

tool_input = data.get('tool_input', {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except Exception:
        tool_input = {}

# Try subagent_type first
agent = tool_input.get('subagent_type', '')
if agent:
    print(agent)
    raise SystemExit(0)

# Try extracting from description or prompt
desc = tool_input.get('description', '') or tool_input.get('prompt', '')
# Look for agent name patterns like "Run code-writer agent" or "code-writer:"
match = re.search(r'\b(code-writer|code-reviewer|test-writer|test-runner|debugger|planner|security|researcher|commit|push|devops|docs|orchestrator|bash-specialist|merge|morning-briefing|frontend-qa)\b', desc, re.IGNORECASE)
if match:
    print(match.group(1).lower())
    raise SystemExit(0)

# Fallback: first word of description
words = desc.split()
if words:
    # Clean the first word
    first = re.sub(r'[^a-zA-Z0-9_-]', '', words[0]).lower()
    if first:
        print(first)
        raise SystemExit(0)

print('unknown')
PYEOF
)" || true

if [ -z "$AGENT_NAME" ]; then
  AGENT_NAME="unknown"
fi

# Call preamble generator with timeout guard (use env vars to avoid shell injection)
export CAST_PREAMBLE_AGENT="$AGENT_NAME"
export CAST_PREAMBLE_SCRIPT_PATH="$PREAMBLE_SCRIPT"

PREAMBLE="$(python3 - <<'PYEOF' 2>/dev/null
import subprocess, sys, os
try:
    script = os.environ.get('CAST_PREAMBLE_SCRIPT_PATH', '')
    agent = os.environ.get('CAST_PREAMBLE_AGENT', 'unknown')
    result = subprocess.run(
        ['python3', script, '--agent', agent, '--top-n', '3'],
        capture_output=True, text=True, timeout=2
    )
    if result.returncode == 0 and result.stdout.strip():
        print(result.stdout.strip())
except Exception:
    pass
PYEOF
)" || true

# If preamble is non-empty, output hookSpecificOutput JSON
if [ -n "$PREAMBLE" ]; then
  export CAST_PREAMBLE_OUTPUT="$PREAMBLE"
  python3 -c "
import json, os
preamble = os.environ.get('CAST_PREAMBLE_OUTPUT', '')
if preamble:
    print(json.dumps({'hookSpecificOutput': preamble}))
" 2>/dev/null || true
fi

exit 0
