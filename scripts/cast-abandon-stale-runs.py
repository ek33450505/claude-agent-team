#!/usr/bin/env python3
"""cast-abandon-stale-runs.py — Flip stale agent_runs and sessions to terminal states.

Runs every 2h via launchd (com.cast.abandon-stale-runs, StartInterval 7200 —
changed from daily in v9.5.2, 2026-07-09). Because the sweep is periodic and
not continuous, a row that goes stale just after a sweep waits up to one full
interval for the next one: on a continuously-awake host the latency is the
staleness threshold PLUS the interval (~4h at the defaults), not 2h.

CAVEAT — ~4h is a FLOOR, not a bound. launchd does not replay StartInterval
firings missed while the host was asleep or powered off, so that time is never
made up. v10 I-2d set RunAtLoad=true, which bounds the post-boot case: loading
the job (boot, login, or a reinstall) fires ONE immediate catch-up sweep — one,
not one per missed interval, and it does not fire on wake-from-sleep. So do NOT
quote "2h" or "~4h" as the maximum age of a 'running' row. Measured 2026-08-24
BEFORE the RunAtLoad fix, over the retained window: 17 of 41 reaped rows (41%)
exceeded 4h, max lag 18.8h; three rows sat 'running' for 59h across a weekend
the host was powered off (last sweep 2026-08-22T01:54:01Z, next boot
2026-08-24T07:21:36-04:00). Anything judging freshness must read the row's own
timestamps, never the configured cadence.

Two symmetric steps:

  Step 1 — agent_runs: rows stuck in status='running' for more than
  CAST_ABANDON_STALE_HOURS (default 2h) are flipped to 'abandoned', with
  both abandoned_at and ended_at set (v10 I-2b: this script is the sole
  reaper — see the "sole writer" comment above no_response_marker below).
  For each reaped row, one incidents row is inserted so that API-killed agents
  and maxTurns-truncated runs (which never fire SubagentStop) become visible in
  the incident record.  Incident insertion is best-effort — a missing incidents
  table on older DBs logs a warning and does NOT interrupt the reap or the
  always-exit-0 contract.

  Step 1b — recovery backfill (C4, 2026-08-18; text-preference fix same day):
  a reaped row's `response` is initially just an explicit "[NO RESPONSE ...]"
  marker, since SubagentStop never fired on this path. But the run's
  transcript is frequently STILL on disk even though the hook never
  processed it — so this step makes a best-effort pass to recover the run's
  actual last output and replace the marker with it. PROSE IS PREFERRED OVER
  A TOOL CALL: a killed/truncated agent's terminal turn is almost always an
  ordinary tool_use (Bash, Edit, ...) — what it was mid-flight doing, not its
  work — so this walks every assistant turn backward and returns the most
  recent TEXT block found anywhere, falling back to the terminal tool_use
  only when no text exists in the whole transcript. That fallback is tagged
  "[structured-output:<name>]" ONLY for a genuine StructuredOutput call
  (matches cast_subagent_stop.py's own C2 tag+contract — its `input` IS the
  deliverable); any other terminal tool gets the distinct
  "[last-tool-call:<name>]" tag so the two cases never look alike in the
  record. See _extract_recovered_text() for the full walk. Idempotent and
  STATE-based (matches status IN ('failed','abandoned') AND response IS
  NULL/marker) — runs unconditionally every invocation, so it also backfills
  LEGACY rows: those flipped by cast-maintenance.sh or cast-session-end.sh
  BEFORE v10 I-2b removed both of those writers (both were bash, both flipped
  to 'failed' and wrote the same marker prefix), plus rows flipped before this
  backfill existed at all. Neither bash writer runs any more — this script has
  been the sole reaper since I-2b. Never overwrites a response holding real
  content.

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
  # Or via launchd plist (com.cast.abandon-stale-runs — runs every 2h).
"""

import glob
import json
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

# --- Recovery config (C4: partial-response backfill) ---
# Mirrors cast_subagent_stop.py's own 20MB CAST_TRANSCRIPT_MAX_BYTES guard —
# NEVER moved or loosened; it protects this best-effort read from a multi-GB
# transcript inside an unattended launchd job. Same env var name so a single
# override tunes both the hook and this reaper consistently.
TRANSCRIPT_MAX_BYTES = int(os.environ.get('CAST_TRANSCRIPT_MAX_BYTES', '20971520') or '20971520')
RECOVERED_TEXT_MAX_CHARS = 20000
# Any `response` starting with this literal is a "no real response" marker —
# written by THIS script, cast-maintenance.sh, or cast-session-end.sh (all
# three share the same "[NO RESPONSE ..." prefix by convention, only the
# script name / hours differ). The backfill pass below treats NULL and any
# marker-prefixed response as equally eligible for recovery, so a row flipped
# by ANY of the three sweeps is recoverable regardless of which one got there
# first — recovery is keyed on the row's *state*, not on who flipped it.
NO_RESPONSE_MARKER_LIKE = '[NO RESPONSE%'
PARTIAL_PREFIX = '[PARTIAL — recovered from transcript; SubagentStop never fired] '


def _log(msg: str) -> None:
    """Append a timestamped line to the log file. Never fails."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(LOG_PATH, 'a') as f:
            f.write(f'[{ts}] {msg}\n')
    except Exception:
        pass


# --- C4 recovery: pull partial output out of the transcript at reap time ---
#
# The reap sweeps (this script, cast-maintenance.sh, cast-session-end.sh) flip
# rows stuck 'running' because SubagentStop never fired for them — so
# `response` is always NULL at flip time. That is often wrong: for agent_id +
# session_id pairs the transcript is frequently still sitting on disk with the
# agent's real (if incomplete) last turn. This section resolves that
# transcript exactly the way SubagentStop's own hook does and recovers it,
# falling back to the honest "no response" marker only when nothing is
# recoverable (missing/oversized/malformed transcript, or no agent_id).


def _resolve_transcript_path(agent_id: str, session_id: str) -> str:
    """Resolve a subagent run's transcript path.

    SAME glob idiom as cast_subagent_stop.py:534-543 (SubagentStop's own
    resolver) — reused verbatim, not reinvented, so this reaper and the hook
    agree on where a given run's transcript lives. Returns "" (never raises)
    when either id is missing or no file matches.
    """
    if not agent_id or not session_id:
        return ""
    pattern = os.path.expanduser(
        f"~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl"
    )
    try:
        matches = glob.glob(pattern, recursive=True)
        if matches:
            return max(matches, key=os.path.getmtime)
    except Exception:
        pass
    return ""


def _extract_recovered_text(transcript_path: str) -> str:
    """Read `transcript_path` (JSONL) and return the agent's recoverable last
    output, truncated to RECOVERED_TEXT_MAX_CHARS.

    Prose over tool calls, always. A killed/truncated agent's LAST assistant
    message is almost always a tool_use for an ordinary tool (Bash, Edit,
    ...) — that is what it was mid-flight doing when it died, not its work.
    The agent's actual partial report sits in an earlier assistant text
    block. So this walks assistant messages from the end and returns the
    FIRST (i.e. most recent) non-empty `type=="text"` block it finds,
    checking every turn — not just the terminal one — before ever falling
    back to a tool call:
      - text block(s) in some assistant turn (any turn, not just the last)
        -> joined with '\\n', returned immediately. This is the preferred,
        common case.
      - no text block ANYWHERE in the transcript -> fall back to the
        truly-terminal assistant turn's tool_use block (the last thing the
        agent was doing when it died), captured once from the first
        (most-recent) assistant message walked. Two distinct tags, matching
        cast_subagent_stop.py's own C2 response extraction so a reader (or
        `bash bin/cast review`) can always tell which case produced a given
        response:
          - name == "StructuredOutput" -> "[structured-output:<name>]
            <json-input>" — a GENUINE deliverable (matches
            cast_subagent_stop.py's own tag+contract: `input` IS the
            agent's output for that tool).
          - any other tool name (Bash, Edit, ...) -> "[last-tool-call:<name>]
            <json-input>" — explicitly NOT a deliverable, just what was
            in-flight. Never reuses the structured-output tag, so the two
            cases stay distinguishable in the record.

    Best-effort only: a missing, empty, oversized, or malformed transcript —
    or one with no text block and no tool_use anywhere — degrades to "" so
    the caller leaves the existing marker in place. Never raises.
    """
    try:
        if not transcript_path or not os.path.isfile(transcript_path):
            return ""
        size = os.path.getsize(transcript_path)
        if size <= 0 or size > TRANSCRIPT_MAX_BYTES:
            return ""
        with open(transcript_path, 'r', errors='replace') as f:
            lines = f.readlines()
    except Exception:
        return ""

    # Captured once, from the first (most-recent) assistant turn that has a
    # tool_use block — i.e. the true terminal state of the transcript. Only
    # used if the backward text search below never finds a text block in ANY
    # turn.
    fallback_tool_call = None

    for raw_line in reversed(lines):
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            obj = json.loads(raw_line)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        msg = obj.get('message') if isinstance(obj.get('message'), dict) else {}
        role = msg.get('role') or obj.get('type')
        if role != 'assistant':
            continue
        content = msg.get('content')
        if not isinstance(content, list) or not content:
            continue

        texts = [
            blk.get('text', '')
            for blk in content
            if isinstance(blk, dict) and blk.get('type') == 'text'
        ]
        text_joined = '\n'.join(t for t in texts if t)
        if text_joined:
            return text_joined[:RECOVERED_TEXT_MAX_CHARS]

        if fallback_tool_call is None:
            for blk in content:
                if isinstance(blk, dict) and blk.get('type') == 'tool_use':
                    tool_name = blk.get('name') or '?'
                    try:
                        tool_input = json.dumps(blk.get('input') or {}, ensure_ascii=False)
                    except Exception:
                        tool_input = '{}'
                    if tool_name == 'StructuredOutput':
                        fallback_tool_call = f"[structured-output:{tool_name}] {tool_input}"
                    else:
                        fallback_tool_call = f"[last-tool-call:{tool_name}] {tool_input}"
                    break

        # This assistant turn had content but no usable text (only tool_use,
        # or only e.g. a 'thinking' block) — keep walking backward; an
        # earlier turn may still carry real prose, which always wins.

    return (fallback_tool_call or "")[:RECOVERED_TEXT_MAX_CHARS]


def _recover_response(agent_id: str, session_id: str) -> str:
    """Best-effort wrapper: resolve + extract, collapsing every failure to "".

    Callers must treat "" as "nothing recoverable — leave the marker in
    place"; this never raises so a single bad row can never abort the reap.
    """
    try:
        transcript_path = _resolve_transcript_path(agent_id, session_id)
        if not transcript_path:
            return ""
        return _extract_recovered_text(transcript_path)
    except Exception as e:
        _log(f'Recovery: unexpected error resolving/reading transcript: {e}')
        return ""


def recover_stale_responses(conn: sqlite3.Connection) -> None:
    """Idempotent backfill pass — recovers partial output for EVERY eligible
    row, not just the ones this run's Step 1 just flipped.

    Targets rows by *state* (status IN ('failed','abandoned') AND response is
    NULL or the no-response marker), not by who flipped them or when. That
    decouples recovery from flip ordering: a row flipped first by
    cast-maintenance.sh or cast-session-end.sh (both bash, both write the same
    marker prefix) is just as eligible as one flipped by this script, and a
    row that predates this backfill entirely gets picked up the next time
    this reaper runs. Runs on every invocation — safe to run repeatedly since
    a recovered response (PARTIAL_PREFIX) never matches the eligibility
    WHERE clause again.

    Never overwrites a response holding real content: the WHERE clause below
    only ever matches NULL or a marker-prefixed value, both at selection time
    and again at UPDATE time (defends against a response having been
    populated by something else between the SELECT and the UPDATE).
    """
    try:
        candidates = conn.execute(
            '''
            SELECT id, agent_id, session_id
            FROM agent_runs
            WHERE status IN ('failed', 'abandoned')
              AND (response IS NULL OR response LIKE ?)
            ''',
            (NO_RESPONSE_MARKER_LIKE,)
        ).fetchall()
    except Exception as e:
        _log(f'Recovery backfill: candidate query failed: {e}')
        return

    if not candidates:
        _log('Recovery backfill: no eligible rows')
        return

    recovered = 0
    for row_id, agent_id, session_id in candidates:
        try:
            recovered_text = _recover_response(agent_id, session_id)
        except Exception as e:
            _log(f'Recovery backfill: id={row_id} extraction raised (ignored): {e}')
            recovered_text = ""
        if not recovered_text:
            continue
        try:
            new_response = f'{PARTIAL_PREFIX}{recovered_text}'
            result = conn.execute(
                '''
                UPDATE agent_runs
                SET response = ?
                WHERE id = ?
                  AND (response IS NULL OR response LIKE ?)
                ''',
                (new_response, row_id, NO_RESPONSE_MARKER_LIKE)
            )
            conn.commit()
            if result.rowcount:
                recovered += 1
        except Exception as e:
            _log(f'Recovery backfill: id={row_id} UPDATE failed: {e}')

    _log(f'Recovery backfill: recovered {recovered} of {len(candidates)} eligible row(s) from transcript')
    if recovered:
        print(
            f'[cast-abandon-stale-runs] Recovered {recovered} of {len(candidates)} '
            'partial response(s) from transcript',
            file=sys.stderr,
        )


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
            # C3 fix (2026-08-18): a reaped row's `response` was always left NULL —
            # indistinguishable from a DONE run whose response is legitimately empty
            # (see plans/c2-c3-response-loss-findings.md). SubagentStop never fires on
            # this path (that's WHY the row is still 'running' at the threshold), so
            # write an explicit marker here instead of silence. COALESCE guards
            # against ever clobbering a response that is (unexpectedly) already
            # populated.
            # C4 fix (2026-08-18): "no real response to recover" above turned out to
            # be wrong — the transcript is frequently still on disk even though
            # SubagentStop never fired. This marker is therefore only the immediate,
            # cheap placeholder; recover_stale_responses() below (run unconditionally,
            # every invocation) makes a best-effort pass to replace it with the run's
            # actual partial output pulled straight from the transcript.
            # v10 I-2b: this script is now the SOLE writer of this marker —
            # the cast-maintenance.sh and cast-session-end.sh reaping UPDATEs
            # were removed (they raced this one with no coordination, so the
            # same stale event landed as 'abandoned' or 'failed' depending
            # only on which fired first). Historical rows written by those
            # two removed writers still carry their own "... stale running]"
            # marker text and must keep matching the shared
            # NO_RESPONSE_MARKER_LIKE '[NO RESPONSE%' predicate — so this
            # literal's prefix must not change even though it is no longer
            # shared byte-for-byte with anything else.
            no_response_marker = (
                f"[NO RESPONSE — SubagentStop never fired; reaped by "
                f"cast-abandon-stale-runs.py after {STALE_HOURS}h stale running]"
            )
            conn.execute(
                f'''
                UPDATE agent_runs
                SET status = 'abandoned', abandoned_at = ?,
                    ended_at = COALESCE(ended_at, ?),
                    response = COALESCE(response, ?)
                WHERE id IN ({",".join("?" * len(row_ids))})
                ''',
                [now_iso, now_iso, no_response_marker] + row_ids
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

        # --- Step 1b: recover partial output from transcripts (C4 backfill) ---
        # Unconditional — NOT gated on `stale_rows` above. State-based (status IN
        # ('failed','abandoned') + still-marker response), so this also backfills
        # rows flipped by cast-maintenance.sh / cast-session-end.sh, and rows
        # flipped on a PRIOR run of this script before this backfill existed. See
        # recover_stale_responses() docstring for the full rationale.
        try:
            recover_stale_responses(conn)
        except Exception as e:
            # Belt-and-braces: recover_stale_responses already swallows its own
            # errors, but the reap must survive even if that guarantee ever breaks.
            _log(f'Recovery backfill: unexpected top-level error (ignored): {e}')

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
