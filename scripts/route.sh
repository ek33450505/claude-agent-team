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
    DEPTH_FILE="/tmp/cast-depth-${PPID}-${CLAUDE_SESSION_ID:-nosession}.depth"
    CURRENT_DEPTH=0
    if [ -f "$DEPTH_FILE" ]; then
      CURRENT_DEPTH="$(cat "$DEPTH_FILE" 2>/dev/null || echo 0)"
    fi
    CURRENT_DEPTH=$(( CURRENT_DEPTH + 1 ))
    echo "$CURRENT_DEPTH" > "$DEPTH_FILE"
    chmod 600 "$DEPTH_FILE" 2>/dev/null || true

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

# --- Stale /tmp cast-* file cleanup (older than 1 day) ---
find /tmp -maxdepth 1 -name 'cast-*' -mtime +1 -delete 2>/dev/null || true

# --- SQLite DB init guard (runs once per machine boot via flag file) ---
# Ensures cast.db exists before any routing event is logged to it.
# Uses a /tmp flag so we only invoke the init script once per session, not per prompt.
_CAST_DB_INIT_FLAG="/tmp/cast-db-initialized-${PPID}-${CLAUDE_SESSION_ID:-nosession}.flag"
if [ ! -f "$_CAST_DB_INIT_FLAG" ]; then
  _CAST_DB="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
  if [ ! -f "$_CAST_DB" ]; then
    _INIT_SCRIPT="$(dirname "$0")/cast-db-init.sh"
    [ ! -f "$_INIT_SCRIPT" ] && _INIT_SCRIPT="${HOME}/.claude/scripts/cast-db-init.sh"
    [ -f "$_INIT_SCRIPT" ] && bash "$_INIT_SCRIPT" 2>/dev/null || true
  fi
  touch "$_CAST_DB_INIT_FLAG" 2>/dev/null || true
fi

# --- Air-gap state file check ---
# If CAST_AIRGAP_ACTIVE is not set in the environment, check the persistent state file.
# cast-airgap.sh writes/deletes ~/.claude/cast/state/airgap.state to persist across processes.
if [ -z "${CAST_AIRGAP_ACTIVE:-}" ]; then
  _AIRGAP_STATE="${HOME}/.claude/cast/state/airgap.state"
  if [ -f "$_AIRGAP_STATE" ]; then
    export CAST_AIRGAP_ACTIVE=1
  else
    export CAST_AIRGAP_ACTIVE=0
  fi
fi

# --- Resolve cast-db-log.py path (dirname-first so test HOME overrides work) ---
_CAST_DB_LOG_PY="$(dirname "$0")/cast-db-log.py"
[ ! -f "$_CAST_DB_LOG_PY" ] && _CAST_DB_LOG_PY="${HOME}/.claude/scripts/cast-db-log.py"
export CAST_DB_LOG_PY="$_CAST_DB_LOG_PY"

# --- Dry-run mode ---
# Activated by CAST_DRY_RUN=1. Runs the full routing pipeline but does NOT emit
# hookSpecificOutput or write to routing-log.jsonl. Instead prints a JSON summary
# of what would have been dispatched and exits 0.
DRY_RUN="${CAST_DRY_RUN:-0}"
DRY_RUN_FILE=""
if [ "$DRY_RUN" = "1" ]; then
  DRY_RUN_FILE="$(mktemp /tmp/cast-dry-run-XXXXXX.json)"
fi

INPUT="$(cat)"

# --- Pre-session briefing block ---
# On the first prompt of a new session, inject a structured context block:
# git status, recent routing-log entries, any stale BLOCKED agent-status files.
# Runs fast (<200ms) — git status + file reads only. No heavy computation.
if [ "$DRY_RUN" = "0" ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
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
            stale_rollback_refs = board.get('stale_rollback_refs', [])
            if stale_rollback_refs:
                stale_ids = ', '.join(r.get('batch_id', '?') for r in stale_rollback_refs)
                board_lines.append(f'  WARNING Stale rollback refs: batches [{stale_ids}] have unresolved checkpoints — run cast-rollback.sh --batch <id> to review or clean up.')
            if board_lines:
                lines.append('## Project Board Snapshot\n' + '\n'.join(board_lines))
except Exception:
    pass

# 5. Pending route proposals
proposals_path = os.path.expanduser('~/.claude/routing-proposals.json')
try:
    if os.path.exists(proposals_path):
        with open(proposals_path) as f:
            proposals_data = json.load(f)
        pending = [p for p in proposals_data.get('proposals', []) if p.get('status') == 'pending']
        if pending:
            ids = ', '.join(p.get('id', '?') for p in pending[:3])
            more = f' (+{len(pending)-3} more)' if len(pending) > 3 else ''
            lines.append(f'## Route Proposals\n  {len(pending)} pending: {ids}{more}\n  Run `/cast route-review` or check Dashboard > Routing to approve')
except Exception:
    pass

# 6. Agent health advisory
try:
    log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
    if os.path.exists(log_path):
        from collections import defaultdict
        counts = defaultdict(lambda: defaultdict(int))
        with open(log_path) as f:
            for line in f:
                try:
                    e = json.loads(line.strip())
                    if e.get('action') == 'agent_complete' and e.get('matched_route') and e.get('status'):
                        counts[e['matched_route']][e['status']] += 1
                except Exception:
                    pass
        flagged = []
        for ag, statuses in counts.items():
            total = sum(statuses.values())
            if total >= 5:
                blocked_rate = statuses.get('BLOCKED', 0) / total
                if blocked_rate >= 0.20:
                    flagged.append(f'{ag}: {int(blocked_rate*100)}% BLOCKED ({statuses["BLOCKED"]}/{total} runs)')
        if flagged:
            lines.append('## Agent Health\n  ' + '\n  '.join(f'WARNING {item}' for item in flagged))
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
    ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null || true
  exit 0
fi

# --- Group pre-check: match against agent-groups.json before routing table ---
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" CAST_DRY_RUN="$DRY_RUN" CAST_DRY_RUN_FILE="${DRY_RUN_FILE:-}" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
dry_run = os.environ.get('CAST_DRY_RUN', '0') == '1'
dry_run_file = os.environ.get('CAST_DRY_RUN_FILE', '')
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
                post_chain = group.get('post_chain', [])
                if dry_run:
                    # Write dry-run result to temp file; do not emit hookSpecificOutput or log
                    result = {
                        'dry_run': True,
                        'prompt': original[:100],
                        'matched_agent': group['id'],
                        'match_type': 'group',
                        'match_pattern': pattern,
                        'post_chain': post_chain if post_chain else None,
                        'directive_would_be': f'[CAST-DISPATCH-GROUP: {group[\"id\"]}]'
                    }
                    if dry_run_file:
                        try:
                            with open(dry_run_file, 'w') as rf:
                                rf.write(json.dumps(result))
                        except Exception:
                            pass
                    sys.exit(0)
                directive = f\"[CAST-DISPATCH-GROUP: {group['id']}]\\n\"
                directive += 'MANDATORY: Pass the following Payload JSON to the inline session orchestrator immediately with pre_approved: true. Do NOT handle inline — dispatch agents per the manifest.\\n'
                payload = {
                    'group_id': group['id'],
                    'description': group.get('description', ''),
                    'pre_approved': True,
                    'waves': group.get('waves', []),
                    'post_chain': post_chain
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
                    ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
                    input=json.dumps(log), text=True, timeout=5
                )
                sys.exit(0)
        except re.error:
            continue
sys.exit(1)
" 2>/dev/null && { [ "$DRY_RUN" = "1" ] || exit 0; }

# Match prompt against routing table and inject dispatch directive
# Variables are passed as env prefixes to the subprocess rather than globally exported
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" CAST_DRY_RUN="$DRY_RUN" CAST_DRY_RUN_FILE="${DRY_RUN_FILE:-}" CAST_AIRGAP_ACTIVE="${CAST_AIRGAP_ACTIVE}" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
dry_run = os.environ.get('CAST_DRY_RUN', '0') == '1'
dry_run_file = os.environ.get('CAST_DRY_RUN_FILE', '')
airgap_active = os.environ.get('CAST_AIRGAP_ACTIVE', '0') == '1'
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
            ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
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
                if not dry_run:
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
                        ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
                        input=json.dumps(loop_log), text=True, timeout=5
                    )
                else:
                    result = {
                        'dry_run': True,
                        'prompt': original[:100],
                        'matched_agent': agent,
                        'match_type': 'regex',
                        'match_pattern': pattern,
                        'post_chain': None,
                        'directive_would_be': f'[CAST-LOOP-BREAK] (dispatch_count={dispatch_count})'
                    }
                    already_matched = False
                    if dry_run_file and os.path.exists(dry_run_file):
                        try:
                            already_matched = os.path.getsize(dry_run_file) > 0
                        except Exception:
                            pass
                    if not already_matched and dry_run_file:
                        try:
                            with open(dry_run_file, 'w') as rf:
                                rf.write(json.dumps(result))
                        except Exception:
                            pass
                sys.exit(0)

            # Record this dispatch in the registry (skip in dry-run — no side effects)
            if not dry_run:
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

            if dry_run:
                # Write dry-run result to temp file (first match only)
                already_matched = False
                if dry_run_file and os.path.exists(dry_run_file):
                    try:
                        already_matched = os.path.getsize(dry_run_file) > 0
                    except Exception:
                        pass
                if not already_matched and dry_run_file:
                    effective_post_chain = post_chain if (post_chain and post_chain != ['auto-dispatch-from-manifest']) else None
                    result = {
                        'dry_run': True,
                        'prompt': original[:100],
                        'matched_agent': agent,
                        'match_type': 'regex',
                        'match_pattern': pattern,
                        'post_chain': effective_post_chain,
                        'directive_would_be': f'[CAST-DISPATCH] {agent}'
                    }
                    try:
                        with open(dry_run_file, 'w') as rf:
                            rf.write(json.dumps(result))
                    except Exception:
                        pass
                sys.exit(0)

            # --- Low-success-rate performance warning ---
            # If agent has >20 runs and success rate <50%, write a warning to routing_events.
            # Wrapped in try/except — never blocks routing on failure.
            try:
                import sqlite3 as _sq_perf
                _db_perf = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
                _conn_perf = _sq_perf.connect(_db_perf)
                _perf_row = _conn_perf.execute(
                    'SELECT COUNT(*), SUM(CASE WHEN status IN ("DONE","DONE_WITH_CONCERNS") THEN 1 ELSE 0 END) FROM agent_runs WHERE agent = ?',
                    (agent,)
                ).fetchone()
                if _perf_row and _perf_row[0] > 20:
                    _total_runs = _perf_row[0]
                    _success_runs = _perf_row[1] or 0
                    _success_rate = _success_runs / _total_runs
                    if _success_rate < 0.5:
                        _conn_perf.execute(
                            'INSERT INTO routing_events (timestamp, prompt_hash, matched_agent, match_type, confidence) VALUES (datetime("now"), ?, ?, ?, ?)',
                            ('DISPATCH_WARNING', agent, 'perf_warning', round(_success_rate, 4))
                        )
                        _conn_perf.commit()
                _conn_perf.close()
            except Exception:
                pass

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
                parts = []
                for step in post_chain:
                    if isinstance(step, list):
                        parts.append('[' + ', '.join(f'\`{a}\`' for a in step) + ']')
                    else:
                        parts.append(f'\`{step}\`')
                chain_str = ' -> '.join(parts)
                directive += f'[CAST-CHAIN] After {agent} completes: dispatch {chain_str} in sequence.'

            # Output JSON hookSpecificOutput for Claude to see
            output = {
                'hookSpecificOutput': {
                    'hookEventName': 'UserPromptSubmit',
                    'additionalContext': directive
                }
            }
            print(json.dumps(output))

            # Log the match (include airgap_rewrite if applicable)
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
                ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
                input=json.dumps(log), text=True, timeout=5
            )

            # --- Mismatch signal detection ---
            # If a previous matched event for this session fired <60s ago, record a mismatch signal.
            # Wrapped entirely in try/except so any failure is silent and never blocks routing.
            try:
                import sqlite3 as _sq, datetime as _dt
                _sid = session_id
                _cur_prompt = original[:200]
                if _sid and _sid != 'unknown':
                    _db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
                    _conn = _sq.connect(_db_path)
                    _sel = ('SELECT id, prompt_preview, matched_route, timestamp'
                            ' FROM routing_events'
                            ' WHERE session_id = ? AND action = \'matched\''
                            ' ORDER BY id DESC LIMIT 1 OFFSET 1')
                    _row = _conn.execute(_sel, (_sid,)).fetchone()
                    if _row:
                        _prev_id, _prev_prompt, _prev_route, _prev_ts = _row
                        try:
                            _prev_dt = _dt.datetime.fromisoformat(_prev_ts.rstrip('Z'))
                            _now_dt = _dt.datetime.utcnow()
                            _delta = (_now_dt - _prev_dt).total_seconds()
                            if _delta < 60:
                                _ins = ('INSERT INTO mismatch_signals'
                                        ' (routing_event_id, session_id, original_prompt, follow_up_prompt,'
                                        ' timestamp, route_fired, auto_detected)'
                                        ' VALUES (?, ?, ?, ?, ?, ?, 1)')
                                _conn.execute(_ins, (_prev_id, _sid, _prev_prompt, _cur_prompt,
                                      _now_dt.isoformat() + 'Z', _prev_route))
                                _conn.commit()
                        except Exception:
                            pass
                    _conn.close()
            except Exception:
                pass

            sys.exit(0)

# No match — log and output nothing (Claude handles inline); skip log in dry-run
if not dry_run:
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
        ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
        input=json.dumps(log), text=True, timeout=5
    )
" 2>/dev/null || true

# --- Stage 2.3: Memory-assisted routing pass ---
# Only runs if no pattern match fired above. Calls cast-memory-router.py;
# if it returns an agent with confidence >= 0.7, injects [CAST-DISPATCH] and
# logs as match_type='memory'. Failures are fully swallowed — never blocks routing.
_MEMORY_ROUTER_PY="$(dirname "$0")/cast-memory-router.py"
[ ! -f "$_MEMORY_ROUTER_PY" ] && _MEMORY_ROUTER_PY="${HOME}/.claude/scripts/cast-memory-router.py"

if [ -f "$_MEMORY_ROUTER_PY" ]; then
  MEMORY_RESULT="$(CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}" \
    python3 "$_MEMORY_ROUTER_PY" --prompt "$ORIGINAL_PROMPT" 2>/dev/null || echo '{}')"
  CAST_MEMORY_AGENT="$(echo "$MEMORY_RESULT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('agent') or '')" 2>/dev/null || echo "")"

  if [ -n "$CAST_MEMORY_AGENT" ]; then
    CAST_MEMORY_RESULT="$MEMORY_RESULT" CAST_MEMORY_AGENT_VAL="$CAST_MEMORY_AGENT" \
    CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" \
    CAST_DRY_RUN="$DRY_RUN" CAST_DRY_RUN_FILE="${DRY_RUN_FILE:-}" python3 -c "
import json, os, datetime, sys, subprocess

agent = os.environ.get('CAST_MEMORY_AGENT_VAL', '')
memory_result_raw = os.environ.get('CAST_MEMORY_RESULT', '{}')
prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
dry_run = os.environ.get('CAST_DRY_RUN', '0') == '1'
dry_run_file = os.environ.get('CAST_DRY_RUN_FILE', '')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]
session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')

try:
    mem_data = json.loads(memory_result_raw)
    confidence_val = mem_data.get('confidence', 0.0)
    reason = mem_data.get('reason', 'memory match')
except Exception:
    confidence_val = 0.0
    reason = 'memory match'

if dry_run:
    already_matched = False
    if dry_run_file and os.path.exists(dry_run_file):
        try:
            already_matched = os.path.getsize(dry_run_file) > 0
        except Exception:
            pass
    if not already_matched and dry_run_file:
        result = {
            'dry_run': True,
            'prompt': original[:100],
            'matched_agent': agent,
            'match_type': 'memory',
            'match_pattern': f'memory:{reason}',
            'post_chain': None,
            'directive_would_be': f'[CAST-DISPATCH] {agent}'
        }
        try:
            with open(dry_run_file, 'w') as rf:
                rf.write(json.dumps(result))
        except Exception:
            pass
    sys.exit(0)

directive = f'[CAST-DISPATCH] Route: {agent} (confidence: memory)\n'
directive += f'RECOMMENDED: Consider dispatching the \`{agent}\` agent via the Agent tool.\n'
directive += f'Pass the user full prompt as the agent task. Do NOT handle this inline.\n'
directive += f'(Matched via agent memory keyword similarity — reason: {reason})'

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
    'action': 'matched',
    'matched_route': agent,
    'command': None,
    'pattern': f'memory:{reason}',
    'confidence': 'memory',
    'match_type': 'memory'
}
subprocess.run(
    ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null && { [ "$DRY_RUN" = "1" ] || exit 0; } || true
  fi
fi

# --- Catch-all: route ambiguous implementation prompts to router agent ---
# Fires when: 5+ words, not a question, not conversational filler, contains action verb signals
CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" CAST_DRY_RUN="$DRY_RUN" CAST_DRY_RUN_FILE="${DRY_RUN_FILE:-}" python3 -c "
import json, re, os, datetime, sys

prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
dry_run = os.environ.get('CAST_DRY_RUN', '0') == '1'
dry_run_file = os.environ.get('CAST_DRY_RUN_FILE', '')
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

if dry_run:
    # Write dry-run result to temp file (first match only)
    already_matched = False
    if dry_run_file and os.path.exists(dry_run_file):
        try:
            already_matched = os.path.getsize(dry_run_file) > 0
        except Exception:
            pass
    if not already_matched and dry_run_file:
        result = {
            'dry_run': True,
            'prompt': original[:100],
            'matched_agent': 'router',
            'match_type': 'no_match',
            'match_pattern': 'catchall:action_verb_heuristic',
            'post_chain': None,
            'directive_would_be': '[CAST-CATCHALL]'
        }
        try:
            with open(dry_run_file, 'w') as rf:
                rf.write(json.dumps(result))
        except Exception:
            pass
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
    ['python3', os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))],
    input=json.dumps(log), text=True, timeout=5
)
" 2>/dev/null || true

# --- Stage 2.4: Haiku NLU fallback ---
# Only runs if no earlier stage fired a match (DRY_RUN_FILE is empty or missing).
# Calls Claude Haiku with a structured routing prompt and parses agent + confidence.
# If confidence >= 0.6, injects [CAST-DISPATCH]. Otherwise logs UNMATCHED_INTENT.
# Entire block is wrapped in graceful fallback — never crashes or hangs routing.
if [ "${CAST_AIRGAP_ACTIVE:-0}" != "1" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # Check if an earlier stage already matched (dry-run file has content, or we already exited)
  _NLU_ALREADY_MATCHED=0
  if [ "$DRY_RUN" = "1" ] && [ -n "${DRY_RUN_FILE:-}" ] && [ -f "$DRY_RUN_FILE" ]; then
    _NLU_FILE_SIZE="$(wc -c < "$DRY_RUN_FILE" 2>/dev/null || echo 0)"
    [ "$_NLU_FILE_SIZE" -gt 0 ] && _NLU_ALREADY_MATCHED=1
  fi

  if [ "$_NLU_ALREADY_MATCHED" = "0" ]; then
    # Build agent list from routing-table.json using python3 (no jq dependency)
    _ROUTING_TABLE_PATH="${HOME}/.claude/config/routing-table.json"
    _NLU_AGENT_LIST="$(CAST_RT_PATH="$_ROUTING_TABLE_PATH" python3 -c "
import json, os, sys
try:
    with open(os.environ.get('CAST_RT_PATH', '')) as f:
        table = json.load(f)
    routes = table.get('routes', [])
    lines = []
    for r in routes:
        agent = r.get('agent', '')
        desc = r.get('description', '')
        if not desc:
            # derive a minimal description from agent name
            desc = agent.replace('-', ' ')
        if agent:
            lines.append(agent + ': ' + desc)
    print('\n'.join(lines))
except Exception as e:
    sys.exit(1)
" 2>/dev/null || echo "")"

    if [ -n "$_NLU_AGENT_LIST" ]; then
      # Build JSON payload safely via python3 json.dumps (avoids shell injection)
      _NLU_PAYLOAD="$(CAST_NLU_PROMPT="$ORIGINAL_PROMPT" CAST_NLU_AGENTS="$_NLU_AGENT_LIST" python3 -c "
import json, os
prompt = os.environ.get('CAST_NLU_PROMPT', '')
agents = os.environ.get('CAST_NLU_AGENTS', '')
system_msg = 'You are a routing classifier for the CAST agent system. Given a user prompt and a list of available agents with descriptions, return ONLY a JSON object with two fields: \"agent\" (the best matching agent name as a string) and \"confidence\" (a float from 0.0 to 1.0). Return {\"agent\": null, \"confidence\": 0.0} if no agent fits well.'
user_msg = 'Available agents:\n' + agents + '\n\nUser prompt: ' + prompt + '\n\nRespond with JSON only.'
payload = {
    'model': 'claude-haiku-4-5',
    'max_tokens': 64,
    'system': system_msg,
    'messages': [{'role': 'user', 'content': user_msg}]
}
print(json.dumps(payload))
" 2>/dev/null || echo "")"

      if [ -n "$_NLU_PAYLOAD" ]; then
        # Call Haiku API — timeout via curl's --max-time; failures are swallowed
        _HAIKU_RESPONSE="$(curl -sf --max-time 8 -X POST https://api.anthropic.com/v1/messages \
          -H "x-api-key: $ANTHROPIC_API_KEY" \
          -H "anthropic-version: 2023-06-01" \
          -H "content-type: application/json" \
          -d "$_NLU_PAYLOAD" 2>/dev/null || echo "")"

        if [ -n "$_HAIKU_RESPONSE" ]; then
          # Parse agent and confidence from Haiku response
          _NLU_PARSED="$(CAST_NLU_RAW="$_HAIKU_RESPONSE" python3 -c "
import json, os, sys, re
raw = os.environ.get('CAST_NLU_RAW', '')
try:
    resp = json.loads(raw)
    content_text = resp['content'][0]['text'].strip()
    # Strip markdown code fences if present
    content_text = re.sub(r'^[\x60]{1,3}(?:json)?\s*', '', content_text)
    content_text = re.sub(r'\s*[\x60]{1,3}$', '', content_text)
    parsed = json.loads(content_text)
    agent = parsed.get('agent') or ''
    confidence = float(parsed.get('confidence', 0.0))
    print(json.dumps({'agent': agent, 'confidence': confidence}))
except Exception:
    print(json.dumps({'agent': '', 'confidence': 0.0}))
" 2>/dev/null || echo '{"agent":"","confidence":0.0}')"

          _NLU_AGENT="$(echo "$_NLU_PARSED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('agent') or '')" 2>/dev/null || echo "")"
          _NLU_CONF="$(echo "$_NLU_PARSED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('confidence',0.0))" 2>/dev/null || echo "0.0")"

          # Check threshold and dispatch or log UNMATCHED_INTENT
          CAST_NLU_AGENT="$_NLU_AGENT" CAST_NLU_CONF="$_NLU_CONF" \
          CAST_PROMPT="$PROMPT" CAST_ORIGINAL="$ORIGINAL_PROMPT" \
          CAST_DRY_RUN="$DRY_RUN" CAST_DRY_RUN_FILE="${DRY_RUN_FILE:-}" python3 -c "
import json, os, datetime, sys, subprocess

agent = os.environ.get('CAST_NLU_AGENT', '')
conf_str = os.environ.get('CAST_NLU_CONF', '0.0')
prompt = os.environ.get('CAST_PROMPT', '')
original = os.environ.get('CAST_ORIGINAL', '')
dry_run = os.environ.get('CAST_DRY_RUN', '0') == '1'
dry_run_file = os.environ.get('CAST_DRY_RUN_FILE', '')
ts = datetime.datetime.utcnow().isoformat() + 'Z'
preview = prompt[:80]
session_id = os.environ.get('CLAUDE_SESSION_ID', 'unknown')
db_log_py = os.environ.get('CAST_DB_LOG_PY', os.path.expanduser('~/.claude/scripts/cast-db-log.py'))

try:
    confidence = float(conf_str)
except ValueError:
    confidence = 0.0

def _write_routing_event(match_type, matched_agent, conf):
    try:
        import sqlite3
        db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
        conn = sqlite3.connect(db_path)
        conn.execute(
            'INSERT INTO routing_events (timestamp, prompt_hash, matched_agent, match_type, confidence) VALUES (datetime(\"now\"), ?, ?, ?, ?)',
            ('NLU_' + match_type.upper(), matched_agent or 'none', match_type, round(conf, 4))
        )
        conn.commit()
        conn.close()
    except Exception:
        pass

if agent and confidence >= 0.6:
    print(f'[CAST] Haiku NLU matched: {agent} (confidence: {confidence:.2f})', file=sys.stderr)

    if dry_run:
        already_matched = False
        if dry_run_file and os.path.exists(dry_run_file):
            try:
                already_matched = os.path.getsize(dry_run_file) > 0
            except Exception:
                pass
        if not already_matched and dry_run_file:
            result = {
                'dry_run': True,
                'prompt': original[:100],
                'matched_agent': agent,
                'match_type': 'haiku_nlu',
                'match_pattern': f'haiku_nlu:confidence={confidence:.2f}',
                'post_chain': None,
                'directive_would_be': f'[CAST-DISPATCH] {agent}',
                'nlu_confidence': confidence
            }
            try:
                with open(dry_run_file, 'w') as rf:
                    rf.write(json.dumps(result))
            except Exception:
                pass
        sys.exit(0)

    _write_routing_event('NLU_MATCH', agent, confidence)

    directive = f'[CAST-DISPATCH] Route: {agent} (confidence: semantic/{confidence:.2f})\n'
    directive += f'RECOMMENDED: Consider dispatching the \`{agent}\` agent via the Agent tool.\n'
    directive += f'Pass the user full prompt as the agent task. Do NOT handle this inline.\n'
    directive += f'(Matched via Haiku NLU semantic routing — confidence: {confidence:.2f})'

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
        'action': 'matched',
        'matched_route': agent,
        'command': None,
        'pattern': f'haiku_nlu:confidence={confidence:.2f}',
        'confidence': 'semantic',
        'match_type': 'haiku_nlu'
    }
    subprocess.run(['python3', db_log_py], input=json.dumps(log), text=True, timeout=5)
    sys.exit(0)

else:
    # Low confidence or empty agent — log UNMATCHED_INTENT
    print(f'[CAST] No route matched (Haiku confidence: {confidence:.2f}). Prompt unrouted.', file=sys.stderr)

    if not dry_run:
        _write_routing_event('UNMATCHED_INTENT', None, confidence)
        log = {
            'timestamp': ts,
            'session_id': session_id,
            'prompt_preview': preview,
            'action': 'unmatched_intent',
            'matched_route': None,
            'command': None,
            'pattern': None,
            'confidence': confidence
        }
        subprocess.run(['python3', db_log_py], input=json.dumps(log), text=True, timeout=5)
" 2>/dev/null && { [ "$DRY_RUN" = "1" ] || exit 0; } || true
        fi
      fi
    fi
  fi
fi

# --- Dry-run output ---
# If dry-run mode was active, print the JSON summary of what would have been dispatched.
if [ "$DRY_RUN" = "1" ]; then
  CAST_DRY_RUN_FILE_VAL="${DRY_RUN_FILE:-}" CAST_ORIGINAL_VAL="$ORIGINAL_PROMPT" python3 -c "
import json, os, sys

dry_run_file = os.environ.get('CAST_DRY_RUN_FILE_VAL', '')
original = os.environ.get('CAST_ORIGINAL_VAL', '')

result = None
if dry_run_file and os.path.exists(dry_run_file):
    try:
        content = open(dry_run_file).read().strip()
        if content:
            result = json.loads(content)
    except Exception:
        pass

if result is None:
    result = {
        'dry_run': True,
        'prompt': original[:100],
        'matched_agent': None,
        'match_type': 'no_match',
        'match_pattern': None,
        'post_chain': None,
        'directive_would_be': 'none'
    }

print(json.dumps(result, indent=2))
" 2>/dev/null || true
  # Clean up temp file
  [ -n "${DRY_RUN_FILE:-}" ] && rm -f "$DRY_RUN_FILE" 2>/dev/null || true
fi

exit 0
