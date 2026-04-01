#!/bin/bash
# cast-cost-tracker.sh — CAST PostToolUse cost tracking hook
# Reads token usage from Claude Code's tool result context and writes to cast.db.
# Upserts sessions table and inserts into agent_runs table.
# Silent on error — never blocks Claude Code.
#
# PostToolUse hook: runs after every tool call.
# Token env vars: CLAUDE_INPUT_TOKENS, CLAUDE_OUTPUT_TOKENS (set by Claude Code)
# Fallback: parse JSON from stdin if env vars are absent.

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
PRICING_JSON="${HOME}/.claude/config/model-pricing.json"

# Ensure db exists — initialize if missing
if [ ! -f "$DB_PATH" ]; then
  DB_INIT="$(dirname "$0")/cast-db-init.sh"
  # Try repo-local first, then installed location
  if [ ! -f "$DB_INIT" ]; then
    DB_INIT="${HOME}/.claude/scripts/cast-db-init.sh"
  fi
  if [ -f "$DB_INIT" ]; then
    bash "$DB_INIT" --db "$DB_PATH" 2>/dev/null || true
  fi
fi

# Read stdin (tool result JSON from Claude Code)
INPUT="$(cat 2>/dev/null || true)"

# Run core logic in Python — handles JSON parsing, pricing lookup, and DB writes
DB_PATH_VAL="$DB_PATH" \
PRICING_JSON_VAL="$PRICING_JSON" \
CLAUDE_INPUT_TOKENS_VAL="${CLAUDE_INPUT_TOKENS:-}" \
CLAUDE_OUTPUT_TOKENS_VAL="${CLAUDE_OUTPUT_TOKENS:-}" \
CLAUDE_MODEL_VAL="${CLAUDE_MODEL:-}" \
CLAUDE_SESSION_ID_VAL="${CLAUDE_SESSION_ID:-unknown}" \
CAST_INPUT="$INPUT" \
python3 - <<'PYEOF' 2>/dev/null || true

import json, os, sys, sqlite3, datetime

db_path      = os.environ.get('DB_PATH_VAL', '')
pricing_file = os.environ.get('PRICING_JSON_VAL', '')
session_id   = os.environ.get('CLAUDE_SESSION_ID_VAL', 'unknown')
raw_input    = os.environ.get('CAST_INPUT', '')

if not db_path or not os.path.exists(db_path):
    sys.exit(0)

# -----------------------------------------------------------------------
# 1. Determine token counts
# -----------------------------------------------------------------------
input_tokens  = int(os.environ.get('CLAUDE_INPUT_TOKENS_VAL', '0') or '0')
output_tokens = int(os.environ.get('CLAUDE_OUTPUT_TOKENS_VAL', '0') or '0')
model         = os.environ.get('CLAUDE_MODEL_VAL', '') or ''

# Fallback: try to parse from stdin JSON if env vars are empty
if input_tokens == 0 and output_tokens == 0 and raw_input.strip():
    try:
        data = json.loads(raw_input)
        usage = data.get('usage', data.get('tool_response', {}).get('usage', {}))
        if isinstance(usage, dict):
            input_tokens  = int(usage.get('input_tokens', 0) or 0)
            output_tokens = int(usage.get('output_tokens', 0) or 0)
        if not model:
            model = data.get('model', '') or ''
    except Exception:
        pass

# If we have no token data at all, nothing to record
if input_tokens == 0 and output_tokens == 0:
    sys.exit(0)

# -----------------------------------------------------------------------
# 2. Look up cost from model-pricing.json
# -----------------------------------------------------------------------
cost_per_m_in  = 0.0
cost_per_m_out = 0.0

if pricing_file and os.path.exists(pricing_file):
    try:
        with open(pricing_file) as f:
            pricing = json.load(f)
        models_map = pricing.get('models', {})
        # Try exact match, then prefix/suffix search
        entry = models_map.get(model) or models_map.get(f'cloud:{model}')
        if not entry:
            # Try substring match for model name variations
            for key, val in models_map.items():
                if model and (model in key or key.replace('cloud:', '') in model):
                    entry = val
                    break
        if entry:
            cost_per_m_in  = float(entry.get('cost_per_million_input', 0) or 0)
            cost_per_m_out = float(entry.get('cost_per_million_output', 0) or 0)
    except Exception:
        pass

call_cost = (input_tokens / 1_000_000 * cost_per_m_in) + \
            (output_tokens / 1_000_000 * cost_per_m_out)

# -----------------------------------------------------------------------
# 3. Parse tool info for agent_runs context
# -----------------------------------------------------------------------
tool_name = ''
agent_name = ''
agent_id = ''
task_summary = ''

if raw_input.strip():
    try:
        data = json.loads(raw_input)
        tool_name = data.get('tool_name', '')
        if tool_name == 'Agent':
            ti = data.get('tool_input', {})
            agent_name   = ti.get('subagent_type', ti.get('agent_type', 'unknown'))
            agent_id     = ti.get('agent_id', '')       # v2.1.69+: unique per-invocation ID
            task_summary = str(ti.get('prompt', ti.get('task', '')))[:200]
    except Exception:
        pass

now = datetime.datetime.utcnow().isoformat() + 'Z'

# -----------------------------------------------------------------------
# 4. Detect project from git (best-effort)
# -----------------------------------------------------------------------
project_name = ''
project_root = ''
try:
    import subprocess
    result = subprocess.run(
        ['git', 'rev-parse', '--show-toplevel'],
        capture_output=True, text=True, timeout=3
    )
    if result.returncode == 0:
        project_root = result.stdout.strip()
        project_name = os.path.basename(project_root)
except Exception:
    pass

# -----------------------------------------------------------------------
# 5. Write to cast.db
# -----------------------------------------------------------------------
try:
    conn = sqlite3.connect(db_path)
    cur  = conn.cursor()

    # Upsert session row — accumulate token and cost totals
    cur.execute('''
        INSERT INTO sessions (id, project, project_root, started_at,
                              total_input_tokens, total_output_tokens, total_cost_usd, model)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          total_input_tokens  = total_input_tokens  + excluded.total_input_tokens,
          total_output_tokens = total_output_tokens + excluded.total_output_tokens,
          total_cost_usd      = total_cost_usd      + excluded.total_cost_usd,
          model               = CASE WHEN excluded.model != '' THEN excluded.model ELSE model END
    ''', (session_id, project_name, project_root, now,
          input_tokens, output_tokens, call_cost, model))

    # Insert agent_runs row only for Agent tool calls (we know which agent ran)
    # status='running' allows SubagentStop to UPDATE the row when the agent finishes
    # agent_id (v2.1.69+) enables cross-event correlation between start and completion
    if tool_name == 'Agent' and agent_name:
        cur.execute('''
            INSERT INTO agent_runs
              (session_id, agent, model, started_at, ended_at,
               input_tokens, output_tokens, cost_usd, task_summary, project, status, agent_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (session_id, agent_name, model, now, now,
              input_tokens, output_tokens, call_cost, task_summary, project_name, 'running',
              agent_id or None))

        # Also log to dispatch_decisions if the table exists (v3.2 schema)
        try:
            tbl_check = cur.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='dispatch_decisions'"
            ).fetchone()
            if tbl_check:
                # Attempt to read effort level from agent frontmatter
                effort_val = None
                try:
                    import re as _re
                    agent_md_paths = [
                        os.path.expanduser(f'~/.claude/agents/{agent_name}.md'),
                        os.path.join(os.path.dirname(__file__) if '__file__' in dir() else '',
                                     '..', 'agents', 'core', f'{agent_name}.md'),
                    ]
                    for md_path in agent_md_paths:
                        if os.path.exists(md_path):
                            with open(md_path) as mf:
                                content = mf.read(512)
                            m = _re.search(r'^effort:\s*(\S+)', content, _re.MULTILINE)
                            if m:
                                effort_val = m.group(1).strip()
                            break
                except Exception:
                    pass

                prompt_snippet = task_summary[:200] if task_summary else None
                cur.execute('''
                    INSERT INTO dispatch_decisions
                      (session_id, prompt_snippet, chosen_agent, model, effort, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (session_id, prompt_snippet, agent_name, model or None,
                      effort_val, now))
        except Exception:
            pass

    conn.commit()
    conn.close()
except Exception:
    pass

PYEOF

exit 0
