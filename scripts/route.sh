#!/bin/bash
# route.sh — UserPromptSubmit hook for logging + observability
# Logs prompt routing decisions to ~/.claude/routing-log.jsonl
# Primary dispatch is via /cast command — this script only observes.
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat)"

# Extract and lowercase prompt
ORIGINAL_PROMPT="$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('prompt', data.get('message', '')).strip())
except Exception:
    print('')
" 2>/dev/null || echo "")"
PROMPT="$(printf '%s' "$ORIGINAL_PROMPT" | tr '[:upper:]' '[:lower:]')"

[ -z "$PROMPT" ] && exit 0
export CAST_PROMPT="$PROMPT"

# Skip system messages
if echo "$PROMPT" | grep -qi "^<task-\|^<system-\|<task-id>\|task-notification"; then
  exit 0
fi

# Opus escalation (prefix check)
if echo "$PROMPT" | grep -qi "^opus:"; then
  python3 -c "
import json, datetime, os
log = {'timestamp': datetime.datetime.utcnow().isoformat()+'Z', 'prompt_preview': os.environ.get('CAST_PROMPT','')[:80], 'action': 'opus_escalation', 'matched_route': 'opus', 'pattern': 'opus: prefix'}
open(os.path.expanduser('~/.claude/routing-log.jsonl'),'a').write(json.dumps(log)+'\n')
" 2>/dev/null || true
  exit 0
fi

# Match prompt against routing table — logging only, no dispatch
python3 -c "
import json, re, os, datetime

prompt = os.environ.get('CAST_PROMPT', '')
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]

try:
    with open(os.path.expanduser('~/.claude/config/routing-table.json')) as f:
        table = json.load(f)
except Exception:
    exit(0)

for route in table.get('routes', []):
    for pattern in route.get('patterns', []):
        if re.search(pattern, prompt, re.IGNORECASE):
            log = {'timestamp': ts, 'prompt_preview': preview, 'action': 'matched', 'matched_route': route['agent'], 'command': route.get('command'), 'pattern': pattern}
            open(log_path, 'a').write(json.dumps(log) + '\n')
            exit(0)

log = {'timestamp': ts, 'prompt_preview': preview, 'action': 'no_match', 'matched_route': None, 'command': None, 'pattern': None}
open(log_path, 'a').write(json.dumps(log) + '\n')
" 2>/dev/null || true

exit 0
