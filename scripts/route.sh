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

# Check for opus: prefix
if echo "$PROMPT" | grep -qi "^opus:"; then
  python3 -c "
import json, datetime, os
log = {
  'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
  'prompt_preview': '''${PROMPT:0:80}''',
  'action': 'opus_escalation',
  'matched_route': 'opus',
  'command': None,
  'pattern': 'opus: prefix'
}
with open(os.path.expanduser('~/.claude/routing-log.jsonl'), 'a') as f:
    f.write(json.dumps(log) + '\n')
hint = json.dumps({'additionalContext': '**[Router]** Opus escalation active. Using Opus for this message.'})
print(hint)
" 2>/dev/null || true
  exit 0
fi

# Match against routing table (stdlib json + re only)
RESULT="$(python3 -c "
import json, re, sys, os

prompt = '''${PROMPT}'''

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

[ -z "$RESULT" ] && exit 0

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
  'prompt_preview': '''${PROMPT:0:80}''',
  'action': 'suggested',
  'matched_route': '$AGENT',
  'command': '$COMMAND' if '$COMMAND' else None,
  'pattern': '$PATTERN'
}
with open(os.path.expanduser('~/.claude/routing-log.jsonl'), 'a') as f:
    f.write(json.dumps(log) + '\n')
" 2>/dev/null || true

# Build and output inject hint
if [ "$AGENT" = "opus" ]; then
  python3 -c "
import json
hint = '**[Router]** Complexity signals detected. Before proceeding, ask the user: \"This looks like a complex task — would you like me to use Opus? (Prefix your next message with \`opus:\` to escalate.)\"'
print(json.dumps({'additionalContext': hint}))
" 2>/dev/null || true
elif [ -n "$COMMAND" ]; then
  python3 -c "
import json
hint = '**[Router]** This prompt matches the \`$AGENT\` agent. Before answering directly, ask the user: \"This looks like a \`$COMMAND\` task — should I route it to the \`$AGENT\` agent? (It runs on a cheaper model and keeps the main session clean.)\"'
print(json.dumps({'additionalContext': hint}))
" 2>/dev/null || true
fi

exit 0
