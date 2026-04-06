#!/usr/bin/env python3
"""
cast-memory-seed-procedural.py — Seed known CAST operational patterns as procedural memories.

Inserts 5 procedural memories into cast.db with agent='shared' and type='procedural'.
Idempotent — uses INSERT OR IGNORE to skip already-present entries.

Exit: 0 on success, 1 on error (details to stderr).
"""

import os
import sys
import sqlite3


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


PROCEDURAL_MEMORIES = [
    {
        'name': 'bats-wc-whitespace',
        'description': 'When BATS test assertions on `wc -l` output fail unexpectedly',
        'content': (
            "When BATS CI tests fail on numeric comparisons using `wc -l`, the issue is usually "
            "leading whitespace in wc output on macOS. Fix: `wc -l file | tr -d ' '` or "
            "`$(wc -l < file)` (redirected form strips whitespace automatically). "
            "Common in count-assertion tests."
        ),
        'importance': 0.9,
        'decay_rate': 0.999,
    },
    {
        'name': 'push-agent-sandbox',
        'description': 'Push agent BATS gate and cast.db reads fail in sandbox environment',
        'content': (
            "The push agent runs in a sandboxed environment where BATS test invocations and "
            "cast.db reads fail silently. Use `dangerouslyDisableSandbox: true` in push agent "
            "Bash tool calls when the push step needs to run shell tests or read from cast.db. "
            "Document sandbox bypass in the agent prompt."
        ),
        'importance': 0.9,
        'decay_rate': 0.999,
    },
    {
        'name': 'orchestrator-subagent-type',
        'description': 'Custom CAST agent names are not valid subagent_type values in Agent tool',
        'content': (
            "When dispatching the orchestrator via the Agent tool, use "
            "`subagent_type: 'general-purpose'` with the orchestrator's full system prompt "
            "included. Custom CAST agent names (e.g., 'orchestrator', 'planner') are not "
            "recognized as subagent_type values — only built-in Claude Code agent types work. "
            "The orchestrator prompt should reference the plan file path."
        ),
        'importance': 0.85,
        'decay_rate': 0.999,
    },
    {
        'name': 'hook-scripts-repo-sync',
        'description': 'Scripts written to ~/.claude/scripts/ must also be committed to repo scripts/ dir',
        'content': (
            "Any new hook script written to ~/.claude/scripts/ must also be committed to the "
            "repo at scripts/. The install.sh script copies repo/scripts/ → ~/.claude/scripts/ "
            "at install time. Writing only to the runtime path leaves the repo out of sync and "
            "the script will be lost on next install. Always write to both, or write to repo "
            "and let install.sh sync."
        ),
        'importance': 0.85,
        'decay_rate': 0.999,
    },
    {
        'name': 'dashboard-qa-before-push',
        'description': 'Full researcher QA audit required before pushing dashboard commits',
        'content': (
            "Before pushing any batch of claude-code-dashboard commits, dispatch the researcher "
            "agent to run a QA audit of all changed pages. This is a hard convention established "
            "after discovering UI regressions slipped through without explicit QA. The audit "
            "should cover: page renders, API endpoints, data display, and error states."
        ),
        'importance': 0.8,
        'decay_rate': 0.998,
    },
]


def check_importance_decay_columns(conn):
    """Check if importance and decay_rate columns exist."""
    rows = conn.execute("PRAGMA table_info(agent_memories)").fetchall()
    col_names = {row[1] for row in rows}
    return 'importance' in col_names, 'decay_rate' in col_names


def main():
    db_path = get_db_path()

    if not os.path.exists(db_path):
        print(f"ERROR: cast.db not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as e:
        print(f"ERROR: Cannot connect to {db_path}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        # Check if agent_memories table exists
        table_exists = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'"
        ).fetchone()

        if not table_exists:
            print("ERROR: agent_memories table does not exist. Run cast-memory-schema-v2.py first.", file=sys.stderr)
            conn.close()
            sys.exit(1)

        # Check if importance and decay_rate columns exist
        has_importance, has_decay_rate = check_importance_decay_columns(conn)

        if not has_importance or not has_decay_rate:
            print("WARNING: importance/decay_rate columns missing. Run cast-memory-schema-v2.py first.", file=sys.stderr)
            # Attempt to run schema migration inline
            import subprocess
            script_dir = os.path.dirname(os.path.abspath(__file__))
            schema_script = os.path.join(script_dir, 'cast-memory-schema-v2.py')
            if os.path.exists(schema_script):
                result = subprocess.run([sys.executable, schema_script], capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"ERROR: Schema migration failed: {result.stderr}", file=sys.stderr)
                    conn.close()
                    sys.exit(1)
                # Reconnect after schema migration
                conn.close()
                conn = sqlite3.connect(db_path, timeout=10)
                has_importance, has_decay_rate = check_importance_decay_columns(conn)

        inserted = 0
        already_present = 0

        for mem in PROCEDURAL_MEMORIES:
            # Check if already exists (by agent + name)
            existing = conn.execute(
                "SELECT id FROM agent_memories WHERE agent = 'shared' AND name = ?",
                (mem['name'],)
            ).fetchone()

            if existing:
                already_present += 1
                continue

            # Build INSERT dynamically based on available columns
            if has_importance and has_decay_rate:
                conn.execute(
                    """INSERT OR IGNORE INTO agent_memories
                       (agent, type, name, description, content, importance, decay_rate)
                       VALUES ('shared', 'procedural', ?, ?, ?, ?, ?)""",
                    (mem['name'], mem['description'], mem['content'],
                     mem['importance'], mem['decay_rate'])
                )
            else:
                conn.execute(
                    """INSERT OR IGNORE INTO agent_memories
                       (agent, type, name, description, content)
                       VALUES ('shared', 'procedural', ?, ?, ?)""",
                    (mem['name'], mem['description'], mem['content'])
                )
            inserted += 1

        conn.commit()
        conn.close()

        print(f"Seeded {inserted} procedural memories. {already_present} already present.")
        sys.exit(0)

    except sqlite3.Error as e:
        print(f"ERROR: Seed failed: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}", file=sys.stderr)
        try:
            conn.close()
        except Exception:
            pass
        sys.exit(1)


if __name__ == '__main__':
    main()
