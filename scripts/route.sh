#!/bin/bash
# route.sh — UserPromptSubmit hook for agent routing
# Input: JSON on stdin from Claude Code {prompt: str}
# Output: JSON {"additionalContext": "<hint>"} if matched, nothing if no match
# Log: ~/.claude/routing-log.jsonl

set -euo pipefail

ROUTING_TABLE="$HOME/.claude/config/routing-table.json"
ROUTING_LOG="$HOME/.claude/routing-log.jsonl"

# Read full stdin
INPUT="$(cat)"

# Extract and lowercase prompt
PROMPT="$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', data.get('message', '')).lower().strip())
except Exception:
    print('')
" 2>/dev/null || echo "")"

[ -z "$PROMPT" ] && exit 0

# Export prompt for safe use in Python subshells (avoids string interpolation injection)
export CAST_PROMPT="$PROMPT"

# Skip internal Claude Code system messages (task-notifications, XML system messages)
if echo "$PROMPT" | grep -qi "^<task-\|^<system-\|<task-id>\|task-notification"; then
  exit 0
fi

# Check for opus: prefix
if echo "$PROMPT" | grep -qi "^opus:"; then
  python3 -c "
import json, datetime, os
log = {
  'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
  'prompt_preview': os.environ.get('CAST_PROMPT', '')[:80],
  'action': 'opus_escalation',
  'matched_route': 'opus',
  'command': None,
  'pattern': 'opus: prefix'
}
with open(os.path.expanduser('~/.claude/routing-log.jsonl'), 'a') as f:
    f.write(json.dumps(log) + '\n')
" 2>/dev/null || true
  echo '**[Router]** Opus escalation active. Using Opus for this message.'
  exit 0
fi

# Match against routing table (stdlib json + re only)
RESULT="$(python3 -c "
import json, re, sys, os

prompt = os.environ.get('CAST_PROMPT', '')

try:
    with open(os.path.expanduser('~/.claude/config/routing-table.json')) as f:
        table = json.load(f)
except Exception:
    sys.exit(0)

# Opus complexity signals first
for pattern in table.get('opus_signals', {}).get('complexity_patterns', []):
    if re.search(pattern, prompt, re.IGNORECASE):
        print(json.dumps({'agent': 'opus', 'command': None, 'pattern': pattern}))
        sys.exit(0)

# Agent routes
for route in table.get('routes', []):
    for pattern in route.get('patterns', []):
        if re.search(pattern, prompt, re.IGNORECASE):
            print(json.dumps({'agent': route['agent'], 'command': route['command'], 'pattern': pattern}))
            sys.exit(0)
" 2>/dev/null || echo "")"

if [ -z "$RESULT" ]; then
  # Log no-match for miss-rate visibility (dashboard uses this to track routing coverage)
  python3 -c "
import json, datetime, os
log = {
  'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
  'prompt_preview': os.environ.get('CAST_PROMPT', '')[:80],
  'action': 'no_match',
  'matched_route': None,
  'command': None,
  'pattern': None
}
with open(os.path.expanduser('~/.claude/routing-log.jsonl'), 'a') as f:
    f.write(json.dumps(log) + '\n')
" 2>/dev/null || true
  exit 0
fi

# Parse result fields
AGENT="$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agent',''))" 2>/dev/null || echo "")"
COMMAND="$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('command') or '')" 2>/dev/null || echo "")"
PATTERN="$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pattern',''))" 2>/dev/null || echo "")"

[ -z "$AGENT" ] && exit 0

# Log decision
python3 -c "
import json, datetime, os
log = {
  'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
  'prompt_preview': os.environ.get('CAST_PROMPT', '')[:80],
  'action': 'dispatched',
  'matched_route': '$AGENT',
  'command': '$COMMAND' if '$COMMAND' else None,
  'pattern': '$PATTERN'
}
with open(os.path.expanduser('~/.claude/routing-log.jsonl'), 'a') as f:
    f.write(json.dumps(log) + '\n')
" 2>/dev/null || true

# Output routing instruction as plain text (stdout is added to Claude's context)
# Phase 2: instruct Claude to dispatch directly rather than ask the user
if [ "$AGENT" = "opus" ]; then
  echo '**[Router]** Complexity signals detected. Switch to Opus for this message before answering.'
elif [ -n "$COMMAND" ]; then
  echo "**[Router]** Dispatch to \`$AGENT\` agent now using the Agent tool (subagent_type: '$AGENT'). Do NOT ask the user first — invoke the agent immediately with the user's prompt as the task."
fi

exit 0
