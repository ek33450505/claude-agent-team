#!/bin/bash
# route.sh v3 — CAST Active Dispatch Injection
# UserPromptSubmit hook: matches prompts against routing-table.json
# On match: injects [CAST-DISPATCH] directive into Claude's context via hookSpecificOutput
# On no match: outputs nothing, Claude handles inline normally
# Always logs to routing-log.jsonl for observability

# Skip subprocesses (subagent prompts should not trigger re-routing)
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
export CAST_ORIGINAL="$ORIGINAL_PROMPT"

# Skip system messages
if echo "$PROMPT" | grep -qi "^<task-\|^<system-\|<task-id>\|task-notification"; then
  exit 0
fi

# Opus escalation (prefix check) — log and continue
if echo "$PROMPT" | grep -qi "^opus:"; then
  python3 -c "
import json, datetime, os
log = {'timestamp': datetime.datetime.utcnow().isoformat()+'Z', 'prompt_preview': os.environ.get('CAST_PROMPT','')[:80], 'action': 'opus_escalation', 'matched_route': 'opus', 'pattern': 'opus: prefix'}
open(os.path.expanduser('~/.claude/routing-log.jsonl'),'a').write(json.dumps(log)+'\n')
" 2>/dev/null || true
  exit 0
fi

# Match prompt against routing table and inject dispatch directive
python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]

try:
    with open(os.path.expanduser('~/.claude/config/routing-table.json')) as f:
        table = json.load(f)
except Exception:
    sys.exit(0)

for route in table.get('routes', []):
    for pattern in route.get('patterns', []):
        if re.search(pattern, prompt, re.IGNORECASE):
            agent = route['agent']
            confidence = route.get('confidence', 'hard')
            command = route.get('command', '')
            post_chain = route.get('post_chain', [])
            model = route.get('model', 'sonnet')

            # Build dispatch directive
            if confidence == 'hard':
                strength = 'MANDATORY'
                verb = 'Dispatch'
            else:
                strength = 'RECOMMENDED'
                verb = 'Consider dispatching'

            directive = f'[CAST-DISPATCH] Route: {agent} (confidence: {confidence})\n'
            directive += f'{strength}: {verb} the \`{agent}\` agent via the Agent tool (model: {model}).\n'
            directive += f'Pass the user\\'s full prompt as the agent task. Do NOT handle this inline.\n'

            # Add post-chain directive if present
            if post_chain and post_chain != ['auto-dispatch-from-manifest']:
                chain_str = ' -> '.join(f'\`{a}\`' for a in post_chain)
                directive += f'[CAST-CHAIN] After {agent} completes: dispatch {chain_str} in sequence.'

            # Output JSON hookSpecificOutput for Claude to see
            output = {
                'hookSpecificOutput': {
                    'hookEventName': 'UserPromptSubmit',
                    'additionalContext': directive
                }
            }
            print(json.dumps(output))

            # Log the match
            log = {
                'timestamp': ts,
                'prompt_preview': preview,
                'action': 'dispatched',
                'matched_route': agent,
                'command': command,
                'pattern': pattern,
                'confidence': confidence
            }
            open(log_path, 'a').write(json.dumps(log) + '\n')
            sys.exit(0)

# No match — log and output nothing (Claude handles inline)
log = {
    'timestamp': ts,
    'prompt_preview': preview,
    'action': 'no_match',
    'matched_route': None,
    'command': None,
    'pattern': None
}
open(log_path, 'a').write(json.dumps(log) + '\n')
" 2>/dev/null || true

exit 0
