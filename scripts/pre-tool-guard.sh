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

mkdir -p ~/.claude/cast/hook-last-fired && touch ~/.claude/cast/hook-last-fired/PreToolUse.timestamp

INPUT="$(cat)"
TOOL="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")"
CMD="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")"

# --- Policy engine: path-based guard for Write/Edit tool calls ---
# Evaluates config/policies.json rules. Blocks or warns based on severity.
# Escape hatch: set CAST_POLICY_OVERRIDE=1 in env to skip block (not warn) policies.
if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  FILE_PATH="$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ti = d.get('tool_input', {})
print(ti.get('file_path', ti.get('path', '')))" 2>/dev/null || echo "")"

  if [ -n "$FILE_PATH" ]; then
    CAST_FILE_PATH="$FILE_PATH" CAST_POLICY_OVERRIDE="${CAST_POLICY_OVERRIDE:-0}" python3 -c "
import json, os, re, sys, datetime

file_path = os.environ.get('CAST_FILE_PATH', '')
override = os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1'
session_id = os.environ.get('CLAUDE_SESSION_ID', 'default')

# Load policies config — skip gracefully if not found
repo_root = os.getcwd()
policies_path = os.path.join(repo_root, 'config', 'policies.json')
# Also check ~/.claude/config/policies.json as fallback
if not os.path.exists(policies_path):
    policies_path = os.path.expanduser('~/.claude/config/policies.json')
if not os.path.exists(policies_path):
    sys.exit(0)

try:
    with open(policies_path) as f:
        config = json.load(f)
except Exception:
    sys.exit(0)

agent_status_dir = os.path.expanduser('~/.claude/agent-status')
now = datetime.datetime.utcnow().timestamp()
SESSION_TIMEOUT = 7200  # 2 hours

def agent_completed_this_session(required_agent):
    '''Check ~/.claude/agent-status/ for a recent completion of the required agent.'''
    if not os.path.isdir(agent_status_dir):
        return False
    for fname in os.listdir(agent_status_dir):
        if required_agent in fname:
            fpath = os.path.join(agent_status_dir, fname)
            age = now - os.path.getmtime(fpath)
            if age < SESSION_TIMEOUT:
                try:
                    with open(fpath) as f:
                        content = f.read()
                    if 'DONE' in content or 'DONE_WITH_CONCERNS' in content:
                        return True
                except Exception:
                    pass
    return False

for policy in config.get('policies', []):
    pattern = policy.get('path_pattern', '')
    if not pattern:
        continue
    try:
        if not re.search(pattern, file_path, re.IGNORECASE):
            continue
    except re.error:
        continue

    policy_id = policy.get('id', 'unknown')
    required_agent = policy.get('requires_agent', '')
    severity = policy.get('severity', 'warn')
    description = policy.get('description', '')

    if not required_agent:
        continue

    if agent_completed_this_session(required_agent):
        # Agent already completed — policy satisfied
        continue

    if severity == 'block':
        if override:
            print(f'[CAST-POLICY-WARN] Policy \"{policy_id}\" bypassed via CAST_POLICY_OVERRIDE=1. Requires: {required_agent}', file=sys.stderr)
            import datetime as _dt, json as _json
            audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
            os.makedirs(os.path.dirname(audit_path), exist_ok=True)
            event = {
                'timestamp': _dt.datetime.utcnow().isoformat() + 'Z',
                'event': 'POLICY_OVERRIDE',
                'policy_id': policy_id,
                'file_path': file_path,
                'session_id': session_id,
                'override_env': 'CAST_POLICY_OVERRIDE'
            }
            try:
                with open(audit_path, 'a') as _af:
                    _af.write(_json.dumps(event) + '\n')
            except Exception:
                pass
            sys.exit(0)
        else:
            msg = (
                f'**[CAST-POLICY-BLOCK]** Policy \"{policy_id}\" blocks this edit.\\n'
                f'Reason: {description}\\n'
                f'Required: Dispatch the \`{required_agent}\` agent before editing \`{file_path}\`.\\n'
                f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
            )
            print(msg)
            sys.exit(2)
    else:
        # severity == warn
        print(f'[CAST-POLICY-WARN] Policy \"{policy_id}\": {description}. Consider dispatching \`{required_agent}\` first.', file=sys.stderr)
" 2>/dev/null
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
      exit 2
    fi
  fi
fi

# Only intercept Bash tool for git guards below
[ "$TOOL" != "Bash" ] && exit 0

# Extract only the first line of $CMD to prevent multiline escape hatch bypass.
# A multiline command with CAST_COMMIT_AGENT=1 on line 2 would otherwise pass
# the ^ anchor check while the actual git command is on line 1.
FIRST_LINE="${CMD%%$'\n'*}"

# --- git commit block ---
# Allow ONLY if escape hatch is a leading env assignment immediately before git commit
if echo "$FIRST_LINE" | grep -qE "^(cd[[:space:]]+[^[:space:]]+[[:space:]]+&&[[:space:]]+)?CAST_COMMIT_AGENT=1[[:space:]]+git[[:space:]]+commit"; then
  exit 0
fi
# Block any other git commit invocation
if echo "$FIRST_LINE" | grep -qE "(^|[[:space:]])git[[:space:]]+commit"; then
  echo "**[CAST]** Raw \`git commit\` blocked. Dispatch the \`commit\` agent instead (Agent tool, subagent_type: 'commit')."
  exit 2
fi

# --- git push block ---
# Allow ONLY if escape hatch is a leading env assignment immediately before git push
if echo "$FIRST_LINE" | grep -qE "^(cd[[:space:]]+[^[:space:]]+[[:space:]]+&&[[:space:]]+)?CAST_PUSH_OK=1[[:space:]]+git[[:space:]]+push"; then
  exit 0
fi
# Block any other git push invocation
if echo "$FIRST_LINE" | grep -qE "(^|[[:space:]])git[[:space:]]+push"; then
  echo "**[CAST]** Raw \`git push\` blocked. Ensure code-reviewer has run, then use \`CAST_PUSH_OK=1 git push\` or dispatch via the commit agent workflow."
  exit 2
fi

exit 0
