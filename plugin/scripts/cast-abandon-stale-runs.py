#!/usr/bin/env python3
"""cast-abandon-stale-runs.py — Flip stale agent_runs and sessions to terminal states.

Runs daily via launchd (com.cast.abandon-stale-runs). Two symmetric steps:

  Step 1 — agent_runs: rows stuck in status='running' for more than
  CAST_ABANDON_STALE_HOURS (default 2h) are flipped to 'abandoned'.
  For each reaped row, one incidents row is inserted so that API-killed agents
  and maxTurns-truncated runs (which never fire SubagentStop) become visible in
  the incident record.  Incident insertion is best-effort — a missing incidents
  table on older DBs logs a warning and does NOT interrupt the reap or the
  always-exit-0 contract.

  Step 2 — sessions: rows stuck in status='active' for more than
  CAST_SESSION_CRASH_HOURS (default 4h) are flipped to 'crashed'.
  This mirrors the former cast-session-status-cleanup.py (deleted v7.5-phase6),
  which was never wired; the logic now lives here in the already-wired reaper.
  NOTE: nothing currently reads sessions.status='crashed' — this is data-hygiene
  (keeps the sessions table honest, symmetric with agent_runs 'abandoned' marking).

Schema migrations (idempotent — performed on first run):
  ALTER TABLE agent_runs ADD COLUMN abandoned_at TIMESTAMP;

Exit: always 0 (non-blocking; cron/launchd must not be broken by this script).

One-time backfill (review before executing — DO NOT automate):
  UPDATE agent_runs
  SET status = 'abandoned', abandoned_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
  WHERE status = 'running'
    AND started_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours');
  -- Expected: ~33 rows updated. Verify count before committing.

Usage:
  python3 ~/.claude/scripts/cast-abandon-stale-runs.py
  # Or via launchd plist (com.cast.abandon-stale-runs — runs daily).
"""

import os
import sys
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

# --- Config ---
DB_PATH = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
STALE_HOURS = int(os.environ.get('CAST_ABANDON_STALE_HOURS', '2'))
SESSION_CRASH_HOURS = int(os.environ.get('CAST_SESSION_CRASH_HOURS', '4'))
LOG_PATH = os.path.expanduser('~/.claude/logs/cast-abandon-stale-runs.log')


def _log(msg: str) -> None:
    """Append a timestamped line to the log file. Never fails."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(LOG_PATH, 'a') as f:
            f.write(f'[{ts}] {msg}\n')
    except Exception:
        pass


def main() -> None:
    if not os.path.exists(DB_PATH):
        _log(f'cast.db not found at {DB_PATH} — skipping')
        sys.exit(0)

    now_utc = datetime.now(timezone.utc)
    now_iso = now_utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    threshold_iso = (now_utc - timedelta(hours=STALE_HOURS)).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
    except Exception as e:
        _log(f'DB connect failed: {e}')
        sys.exit(0)

    try:
        # Schema migration: add abandoned_at column if missing (idempotent)
        try:
            conn.execute('ALTER TABLE agent_runs ADD COLUMN abandoned_at TIMESTAMP')
            conn.commit()
            _log('Schema migration: added abandoned_at column to agent_runs')
        except sqlite3.OperationalError:
            pass  # column already exists

        # Find and flip stale running rows.
        # Use a Python-computed ISO-8601 threshold so that string comparison
        # against ISO-formatted started_at values (YYYY-MM-DDTHH:MM:SSZ) is
        # lexicographically correct.  SQLite's datetime('now') produces
        # 'YYYY-MM-DD HH:MM:SS' (space separator, no Z) which does NOT sort
        # correctly against ISO-8601 strings.
        cursor = conn.execute(
            '''
            SELECT id, agent, started_at
            FROM agent_runs
            WHERE status = 'running'
              AND started_at < ?
            ''',
            (threshold_iso,)
        )
        stale_rows = cursor.fetchall()

        if not stale_rows:
            _log('No stale running rows found')
        else:
            row_ids = [row[0] for row in stale_rows]
            conn.execute(
                f'''
                UPDATE agent_runs
                SET status = 'abandoned', abandoned_at = ?
                WHERE id IN ({",".join("?" * len(row_ids))})
                ''',
                [now_iso] + row_ids
            )
            conn.commit()

            for row_id, agent, started_at in stale_rows:
                _log(f'Abandoned: id={row_id} agent={agent} started_at={started_at}')

            _log(f'Flipped {len(stale_rows)} stale running row(s) to abandoned')
            print(f'[cast-abandon-stale-runs] Abandoned {len(stale_rows)} stale run(s)', file=sys.stderr)

            # Emit one incidents row per reaped run so that API-killed agents and
            # maxTurns-truncated runs (which never fire SubagentStop) become visible
            # in the incident record (live-fire audit finding LF-4: INCIDENT-BLIND).
            # No PII concern: summaries contain only agent name + timestamps, never
            # agent output or user content.
            for row_id, agent, started_at in stale_rows:
                try:
                    incident_id = str(uuid.uuid4())
                    problem_summary = (
                        f"Stale agent_run reaped: agent={agent} run_id={row_id} "
                        f"stuck 'running' since {started_at} (threshold {STALE_HOURS}h) "
                        f"— SubagentStop never fired (likely API-killed or maxTurns truncation)"
                    )
                    fix_summary = "Auto-flipped to status='abandoned' by cast-abandon-stale-runs.py"
                    conn.execute(
                        """INSERT INTO incidents
                           (id, occurred_at, problem_summary, fix_summary, related_files,
                            related_commit, resolution_status, surfaced_by)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                        (incident_id, now_iso, problem_summary, fix_summary, '[]', '', 'open', 'stale-run-reaper')
                    )
                    conn.commit()
                    _log(f'Incident recorded: id={incident_id} for reaped run_id={row_id}')
                except Exception as inc_err:
                    # Best-effort: a missing incidents table on older DBs or any insert
                    # failure must not break the reap or the always-exit-0 contract.
                    _log(f'Incident insert skipped for run_id={row_id}: {inc_err}')

        # --- Step 2: Flip stale active sessions to 'crashed' ---
        # Symmetric with step 1. Sessions stuck in 'active' for more than
        # CAST_SESSION_CRASH_HOURS are considered crashed (process died without
        # recording an end). Best-effort: a missing sessions table or missing
        # status column on older DBs must not break the wired launchd job.
        try:
            session_threshold_iso = (now_utc - timedelta(hours=SESSION_CRASH_HOURS)).strftime('%Y-%m-%dT%H:%M:%SZ')
            session_result = conn.execute(
                '''
                UPDATE sessions
                SET status = 'crashed', ended_at = ?
                WHERE status = 'active'
                  AND started_at < ?
                ''',
                (now_iso, session_threshold_iso)
            )
            crashed_count = session_result.rowcount
            conn.commit()
            _log(f'Flipped {crashed_count} active session(s) to crashed (threshold={SESSION_CRASH_HOURS}h)')
            if crashed_count:
                print(f'[cast-abandon-stale-runs] Crashed {crashed_count} stale session(s)', file=sys.stderr)
        except Exception as e:
            # Older DBs may lack the sessions table or status column — not fatal.
            _log(f'Session crash-marking skipped (best-effort): {e}')

        # --- Step 3: Age out stale task_queue rows ---
        # No live consumer exists for task_queue (cast-queue-processor.sh was
        # removed in CAST v9 I9 — it dispatched via Anthropic cloud, violating
        # local-first, and was never wired to launchd; git history preserves it).
        # The task_queue table is kept dormant (record-is-product).
        # Rows accumulate indefinitely. Drain rows older than
        # CAST_TASK_QUEUE_ABANDON_DAYS (default 7d for pending, 1d for running).
        # NO schema change — status value 'abandoned' already exists in the table
        # (TEXT DEFAULT 'pending' with no CHECK constraint — verified 2026-06-11).
        try:
            # NOTE: created_at holds MIXED formats ('2026-06-03 17:35:42' AND
            # '2026-06-11T20:51:18Z' — live-verified 2026-06-11). Normalize via
            # replace() in SQL and use the space-form threshold, or string
            # comparison misorders same-day rows.
            tq_pending_threshold = (now_utc - timedelta(days=int(os.environ.get('CAST_TASK_QUEUE_ABANDON_DAYS', '7')))).strftime('%Y-%m-%d %H:%M:%S')
            tq_running_threshold = (now_utc - timedelta(days=1)).strftime('%Y-%m-%d %H:%M:%S')
            tq_result = conn.execute(
                '''
                UPDATE task_queue
                SET status = 'abandoned'
                WHERE (status = 'pending' AND replace(replace(created_at,'T',' '),'Z','') < ?)
                   OR (status = 'running' AND replace(replace(created_at,'T',' '),'Z','') < ?)
                ''',
                (tq_pending_threshold, tq_running_threshold)
            )
            tq_count = tq_result.rowcount
            conn.commit()
            _log(f'task_queue aged out {tq_count} stale row(s) (pending threshold={tq_pending_threshold})')
            if tq_count:
                print(f'[cast-abandon-stale-runs] Aged out {tq_count} stale task_queue row(s)', file=sys.stderr)
        except Exception as e:
            # task_queue may not exist on older DBs — not fatal.
            _log(f'task_queue age-out skipped (best-effort): {e}')

    except Exception as e:
        _log(f'Error during cleanup: {e}')
    finally:
        try:
            conn.close()
        except Exception:
            pass

    sys.exit(0)


if __name__ == '__main__':
    main()
