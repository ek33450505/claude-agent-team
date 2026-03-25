#!/bin/bash
# route.sh v3.1 — CAST Active Dispatch Injection
# UserPromptSubmit hook: matches prompts against routing-table.json
# On match: injects [CAST-DISPATCH] directive into Claude's context via hookSpecificOutput
# On no match: outputs nothing, Claude handles inline normally
# Always logs to routing-log.jsonl for observability

# Skip subprocesses (subagent prompts should not trigger re-routing)
# But track nesting depth for subagents so deeply nested agents can be warned
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then
  # Depth tracking: only active when CLAUDE_SESSION_ID is set (i.e. real Claude session)
  # Without a session ID (e.g. tests), skip depth tracking to avoid stale /tmp files
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    DEPTH_FILE="/tmp/cast-depth-${PPID}.depth"
    CURRENT_DEPTH=1
    if [ -f "$DEPTH_FILE" ]; then
      CURRENT_DEPTH="$(cat "$DEPTH_FILE" 2>/dev/null || echo 1)"
    fi
    CURRENT_DEPTH=$(( CURRENT_DEPTH + 1 ))
    echo "$CURRENT_DEPTH" > "$DEPTH_FILE"

    if [ "$CURRENT_DEPTH" -ge 2 ]; then
      python3 -c "
import json
msg = '[CAST-DEPTH-WARN] Nesting depth >= 2 (orchestrator->agent->sub-agent). The Agent tool may be unavailable at this depth. If self-dispatch fails silently, the inline session is the fallback enforcer -- check agent output for missing downstream dispatch confirmation.'
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': msg}}))
" 2>/dev/null || true
    fi
  fi
  exit 0
fi

set -euo pipefail

INPUT="$(cat)"

# --- Pre-session briefing block ---
# On the first prompt of a new session, inject a structured context block:
# git status, recent routing-log entries, any stale BLOCKED agent-status files.
# Runs fast (<200ms) — git status + file reads only. No heavy computation.
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SESSIONS_LOG="/tmp/cast-sessions-seen.log"
  if ! grep -qxF "${CLAUDE_SESSION_ID}" "$SESSIONS_LOG" 2>/dev/null; then
    # Mark this session as seen BEFORE building the briefing (prevents double-fire)
    echo "${CLAUDE_SESSION_ID}" >> "$SESSIONS_LOG"

    # Detect REPO_ROOT by walking up from cwd
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

    CAST_SESSION_ID="${CLAUDE_SESSION_ID}" CAST_REPO_ROOT="${REPO_ROOT}" python3 -c "
import json, os, subprocess, datetime

session_id = os.environ.get('CAST_SESSION_ID', '')
repo_root = os.environ.get('CAST_REPO_ROOT', '')
lines = []

# 1. Git status (modified files)
if repo_root:
    try:
        result = subprocess.run(
            ['git', '-C', repo_root, 'status', '--short'],
            capture_output=True, text=True, timeout=5
        )
        git_out = result.stdout.strip()
        if git_out:
            lines.append('## Git Status\n' + git_out)
        else:
            lines.append('## Git Status\nClean working tree')
    except Exception:
        pass

# 2. Last 3 routing-log entries
routing_log = os.path.expanduser('~/.claude/routing-log.jsonl')
try:
    with open(routing_log) as f:
        entries = [l.strip() for l in f if l.strip()]
    last3 = entries[-3:] if len(entries) >= 3 else entries
    if last3:
        parsed = []
        for entry in last3:
            try:
                d = json.loads(entry)
                parsed.append(f'  {d.get(\"timestamp\",\"?\")[:19]} | {d.get(\"action\",\"?\")} | {d.get(\"matched_route\",\"none\")}')
            except Exception:
                pass
        if parsed:
            lines.append('## Last 3 Routing Events\n' + '\n'.join(parsed))
except Exception:
    pass

# 3. BLOCKED agent-status files (modified <24hr)
agent_status_dir = os.path.expanduser('~/.claude/agent-status')
if os.path.isdir(agent_status_dir):
    now = datetime.datetime.utcnow().timestamp()
    blocked = []
    try:
        for fname in os.listdir(agent_status_dir):
            fpath = os.path.join(agent_status_dir, fname)
            age = now - os.path.getmtime(fpath)
            if age < 86400:  # <24 hours
                try:
                    with open(fpath) as f:
                        content = f.read()
                    if 'BLOCKED' in content:
                        blocked.append(f'  {fname}: BLOCKED')
                except Exception:
                    pass
    except Exception:
        pass
    if blocked:
        lines.append('## Stale BLOCKED Agents (last 24hr)\n' + '\n'.join(blocked))

# 4. Cross-session project board snapshot (if <24hr old and has notable state)
board_path = os.path.expanduser('~/.claude/cast/project-board.json')
try:
    if os.path.exists(board_path):
        board_age = datetime.datetime.utcnow().timestamp() - os.path.getmtime(board_path)
        if board_age < 86400:  # <24 hours
            with open(board_path) as f:
                board = json.load(f)
            board_lines = []
            blocked_tasks = board.get('blocked_tasks', [])
            in_flight_tasks = board.get('in_flight_tasks', [])
            if blocked_tasks:
                board_lines.append('  Blocked tasks:')
                for t in blocked_tasks[:3]:
                    board_lines.append(f'    [{t.get(\"agent\",\"?\")}] {t.get(\"task_id\",\"?\")} — blocked {t.get(\"age_hours\",0):.1f}h ago')
            if in_flight_tasks:
                board_lines.append('  In-flight tasks:')
                for t in in_flight_tasks[:3]:
                    board_lines.append(f'    [{t.get(\"agent\",\"?\")}] {t.get(\"task_id\",\"?\")} — started {t.get(\"age_hours\",0):.1f}h ago')
            if board_lines:
                lines.append('## Project Board Snapshot\n' + '\n'.join(board_lines))
except Exception:
    pass

if not lines:
    import sys; sys.exit(0)

briefing = '[CAST-SESSION-BRIEFING] First prompt of new session. Context:\n\n'
briefing += '\n\n'.join(lines)

output = {
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': briefing
    }
}
print(json.dumps(output))
" 2>/dev/null && exit 0 || true
  fi
fi

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

# Skip system messages
if echo "$PROMPT" | grep -qi "^<task-\|^<system-\|<task-id>\|task-notification"; then
  exit 0
fi

# Opus escalation (prefix check) — log and continue
if echo "$PROMPT" | grep -qi "^opus:"; then
  # Scope variables to subprocess invocation only (not exported globally)
  CAST_PROMPT_VAL="$PROMPT" python3 -c "
import json, datetime, os, subprocess
log = {'timestamp': datetime.datetime.utcnow().isoformat()+'Z', 'session_id': os.environ.get('CLAUDE_SESSION_ID','unknown'), 'prompt_preview': os.environ.get('CAST_PROMPT_VAL','')[:80], 'action': 'opus_escalation', 'matched_route': 'opus', 'pattern': 'opus: prefix'}
subprocess.run(
    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null || true
  exit 0
fi

# --- Group pre-check: match against agent-groups.json before routing table ---
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]
session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')

groups_path = os.path.expanduser('~/.claude/config/agent-groups.json')
try:
    with open(groups_path) as f:
        groups_data = json.load(f)
except Exception:
    sys.exit(0)

for group in groups_data.get('groups', []):
    for pattern in group.get('patterns', []):
        if len(pattern) > 200:
            continue
        try:
            if re.search(pattern, prompt, re.IGNORECASE):
                print(f\"[CAST] Group matched: {group['id']} ({len(group['waves'])} waves)\", file=sys.stderr)
                directive = f\"[CAST-DISPATCH-GROUP: {group['id']}]\\n\"
                directive += 'MANDATORY: Pass the following Payload JSON to the orchestrator agent immediately with pre_approved: true. Do NOT handle inline.\\n'
                payload = {
                    'group_id': group['id'],
                    'description': group.get('description', ''),
                    'pre_approved': True,
                    'waves': group.get('waves', []),
                    'post_chain': group.get('post_chain', [])
                }
                directive += json.dumps(payload)
                output = {
                    'hookSpecificOutput': {
                        'hookEventName': 'UserPromptSubmit',
                        'additionalContext': directive
                    }
                }
                print(json.dumps(output))
                log = {'timestamp': ts, 'session_id': session_id, 'prompt_preview': preview, 'action': 'group_dispatched', 'matched_route': group['id'], 'pattern': pattern, 'confidence': group.get('confidence', 'soft')}
                import subprocess
                subprocess.run(
                    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
                    input=json.dumps(log), text=True, timeout=5
                )
                sys.exit(0)
        except re.error:
            continue
sys.exit(1)
" 2>/dev/null && exit 0

# Match prompt against routing table and inject dispatch directive
# Variables are passed as env prefixes to the subprocess rather than globally exported
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]
session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')

try:
    with open(os.path.expanduser('~/.claude/config/routing-table.json')) as f:
        table = json.load(f)
except Exception as e:
    # Log config read failure for observability
    try:
        import subprocess as _sp
        log = {'timestamp': ts, 'session_id': session_id, 'prompt_preview': preview, 'action': 'config_error', 'error': str(e)}
        _sp.run(
            ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
            input=json.dumps(log), text=True, timeout=5
        )
    except Exception:
        pass
    sys.exit(0)

for route in table.get('routes', []):
    for pattern in route.get('patterns', []):
        # Skip patterns >200 chars — prevents ReDoS via catastrophic backtracking
        if len(pattern) > 200:
            continue
        try:
            matched = re.search(pattern, prompt, re.IGNORECASE)
        except re.error:
            continue  # Skip malformed patterns silently
        if matched:
            agent = route['agent']
            # --- Dispatch loop detection ---
            dispatch_log = f'/tmp/cast-dispatch-{session_id}.log'
            dispatch_count = 0
            try:
                if os.path.exists(dispatch_log):
                    with open(dispatch_log) as dl:
                        for dline in dl:
                            parts = dline.strip().split('\t')
                            if len(parts) >= 2:
                                if parts[1] == 'commit':
                                    dispatch_count = 0  # reset on commit
                                elif parts[1] == agent:
                                    dispatch_count += 1
            except Exception:
                pass

            if dispatch_count >= 3:
                # Circuit-break: inject loop-break instead of dispatch
                loop_directive = f'[CAST-LOOP-BREAK] Agent \`{agent}\` dispatched {dispatch_count} times this session without a commit. Possible dispatch loop detected. Handle inline or break the cycle.'
                loop_output = {
                    'hookSpecificOutput': {
                        'hookEventName': 'UserPromptSubmit',
                        'additionalContext': loop_directive
                    }
                }
                print(json.dumps(loop_output))
                loop_log = {'timestamp': ts, 'session_id': session_id, 'prompt_preview': preview, 'action': 'loop_break', 'matched_route': agent, 'pattern': pattern, 'dispatch_count': dispatch_count}
                import subprocess as _sp2
                _sp2.run(
                    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
                    input=json.dumps(loop_log), text=True, timeout=5
                )
                sys.exit(0)

            # Record this dispatch in the registry
            try:
                with open(dispatch_log, 'a') as dl:
                    dl.write(f'{ts}\t{agent}\n')
            except Exception:
                pass

            confidence = route.get('confidence', 'hard')
            command = route.get('command', '')
            post_chain = route.get('post_chain', [])
            model = route.get('model', 'sonnet')
            print(f'[CAST] Route matched: {agent}', file=sys.stderr)

            # Build dispatch directive
            if confidence == 'hard':
                strength = 'MANDATORY'
                verb = 'Dispatch'
            else:
                strength = 'RECOMMENDED'
                verb = 'Consider dispatching'

            directive = f'[CAST-DISPATCH] Route: {agent} (confidence: {confidence})\n'
            directive += f'{strength}: {verb} the \`{agent}\` agent via the Agent tool (model: {model}).\n'
            directive += f'Pass the user\'s full prompt as the agent task. Do NOT handle this inline.\n'

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
                'session_id': session_id,
                'prompt_preview': preview,
                'action': 'matched',
                'matched_route': agent,
                'command': command,
                'pattern': pattern,
                'confidence': confidence
            }
            import subprocess as _sp3
            _sp3.run(
                ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
                input=json.dumps(log), text=True, timeout=5
            )
            sys.exit(0)

# No match — log and output nothing (Claude handles inline)
log = {
    'timestamp': ts,
    'session_id': session_id,
    'prompt_preview': preview,
    'action': 'no_match',
    'matched_route': None,
    'command': None,
    'pattern': None
}
import subprocess as _sp4
_sp4.run(
    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null || true

# --- Catch-all: route ambiguous implementation prompts to router agent ---
# Fires when: 5+ words, not a question, not conversational filler, contains action verb signals
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]
session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')

# Must be 5+ words (not conversational)
words = prompt.split()
if len(words) < 5:
    sys.exit(0)

# Exclude pure questions
question_starters = r'^(what|why|how|is|are|can|could|would|will|should|do|does|did|where|when|who|which)'
if re.match(question_starters, prompt.strip(), re.IGNORECASE):
    sys.exit(0)

# Exclude conversational filler
filler = r'^(yes|no|ok|okay|sure|thanks|thank you|got it|sounds good|great|perfect|looks good|agreed)'
if re.match(filler, prompt.strip(), re.IGNORECASE):
    sys.exit(0)

# Must contain action verb signals
action_verbs = r'\b(improve|enhance|make|update|fix|add|rework|better|cleaner|refactor|change|modify|rewrite|convert|migrate|move|rename|delete|remove|build|create|implement|write|generate|replace|extend|integrate|connect|deploy|configure|setup|install|enable|disable)\b'
if not re.search(action_verbs, prompt, re.IGNORECASE):
    sys.exit(0)

# Inject soft [CAST-DISPATCH] recommending router agent
directive = '[CAST-DISPATCH] Route: router (confidence: soft)\n'
directive += 'RECOMMENDED: Consider dispatching the \`router\` agent (haiku) to classify this prompt and determine the best agent. Pass the full prompt as the task. If confidence < 0.7, router returns \"main\" — handle inline in that case.'

output = {
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': directive
    }
}
print(json.dumps(output))

log = {
    'timestamp': ts,
    'session_id': session_id,
    'prompt_preview': preview,
    'action': 'catchall_dispatched',
    'matched_route': 'router',
    'command': None,
    'pattern': 'catchall:action_verb_heuristic',
    'confidence': 'soft'
}
import subprocess as _sp5
_sp5.run(
    ['python3', os.path.expanduser('~/.claude/scripts/cast-log-append.py')],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null || true

exit 0
