#!/usr/bin/env python3
"""cast-db-rollup.py — Pre-prune rollup: aggregate raw rows into daily summary
tables so cost/model/status trends survive cast-db-prune.py's retention window.

Runs BEFORE cast-db-prune.py (wiring is a separate change — this script only
performs the rollup itself; it never deletes anything from the RAW tables).

Two steps, each aggregating from a raw table into a daily summary table:

  Step A — agent_runs -> agent_runs_daily
    Grouped by (day, agent, model, status). day = substr(started_at, 1, 10).

  Step B — routing_events (event_type='mcp_tool_call') -> mcp_calls_daily
    Grouped by (day, mcp_server, mcp_tool, outcome, is_cloud_bound), extracted
    from the JSON `data` column. day = substr(json_extract(data,'$.timestamp'),1,10).

AUTHORITATIVE-WINDOW RULE (replaces an earlier blanket monotone-upsert-only
design — fixes a proven HIGH defect):

`agent_runs.status` is mutated IN PLACE after insert (rows are written
'running'; scripts/cast-abandon-stale-runs.py later flips them to 'abandoned'
or 'failed'). Because `status` is part of agent_runs_daily's PRIMARY KEY, a
blanket monotone-guarded upsert can NEVER correct a status flip: once a run is
rolled up as (status='running', runs=1), the later flip creates a *new*
(status='abandoned', runs=1) group instead of correcting the old one — the
guard (`WHERE excluded.runs >= ...`) only stops a group from shrinking, it
cannot delete a stale group. Proven empirically (2026-08-19): insert 1 run
dated inside the window as 'running', roll up (-> running:1), UPDATE it to
'abandoned', roll up again with the old blanket-guard design (-> running:1
AND abandoned:1 both present, i.e. SUM(runs)=2 for one real run). On the live
DB's last 7 days, 18/815 runs are non-DONE (12 abandoned, 2 failed, 4
running), every one reachable only via this in-place flip — so the status
mix, exactly the trend C5 exists to preserve, would be silently corrupted.

The fix: split each table's rollup at `--authoritative-days` (default
CAST_DB_PRUNE_DAYS, i.e. cast-db-prune.py's OWN retention window — the window
that determines whether raw is still guaranteed complete for a given day):

  cutoff_day = the UTC calendar day containing `now - authoritative_days days`
               (the same instant cast-db-prune.py's `datetime('now','-N
               days')` computes; cutoff_day is its DATE part only).

  - day > cutoff_day  (strictly newer)  -> AUTHORITATIVE: raw is guaranteed
    complete (prune has not yet reached it), so DELETE any existing aggregate
    row(s) for that day and INSERT a fresh one. This is what corrects a
    mutated status — deleting the stale group is required, and no upsert can
    do that.
  - day <= cutoff_day (at OR older than the cutoff) -> INSERT-ONLY: raw may
    already be partially pruned, so this side NEVER deletes, and upserts only
    under the monotone non-shrinking guard (`WHERE excluded.<count> >=
    <table>.<count>`) as belt-and-braces.

Boundary reasoning (`>`, never `>=`): the prune cutoff is a mid-day INSTANT,
so cutoff_day itself may already be half-deleted by the time this script
runs — that is why cutoff_day is excluded from the authoritative side and
falls on the insert-only side instead. Day D gets its one complete,
authoritative aggregate written on the last night D was still strictly newer
than cutoff_day; from the next night on, D falls into the insert-only side,
so that complete aggregate is preserved rather than overwritten by a partial
recompute. Neither side of the boundary can ever overwrite a complete
aggregate with a partial one.

All four statements (delete+insert for the authoritative range, guarded
upsert for the insert-only range, for BOTH tables) run inside ONE transaction
per invocation — commit only if all four succeed.

NULL-in-PRIMARY-KEY note: SQLite treats NULL as DISTINCT from every other NULL
in a PRIMARY KEY / UNIQUE constraint, so a NULL agent/model/status (or NULL
mcp_server/mcp_tool/outcome) would defeat ON CONFLICT and insert a fresh
duplicate row on every run instead of upserting. That is why every grouped key
below is wrapped in COALESCE(..., '') and every daily-table column is declared
NOT NULL DEFAULT '' in the schema (cast-db-init.sh / migration 032).

Excluded-row visibility (MEDIUM, from security review): rows failing the
inclusion filters never enter any aggregate. A caller that later gates a
DESTRUCTIVE prune on this script's exit code must not read "exit 0" as "every
raw row was accounted for" — it only means "the rollup step itself did not
error." The JSON summary reports `excluded_agent_runs` / `excluded_mcp_calls`
counts so this gap is observable instead of silent. Measured on the live DB
(2026-08-19): all four excluded categories are currently ZERO rows — a latent
gap, not active loss today. Mechanism (sharper than "some rows might be
excluded"): a prune-shaped `DELETE ... WHERE started_at < datetime('now',
'-90 days')` never matches a NULL started_at (NULL comparisons are never TRUE
in SQL) — a NULL-started_at row is immune to pruning and can never be lost.
An EMPTY-STRING started_at row IS matched and deleted ('' < cutoff is true)
while the rollup excludes it from aggregation — empty-string is the only
genuinely losable shape.

Dry-run mode: set CAST_DB_ROLLUP_DRY_RUN=1 or pass --dry-run to report would-be
row counts without writing anything. Dry-run counts are NOT split by the
authoritative window (it reports total distinct groups across all days); the
window split only affects how a REAL run writes.

CLI flags (argparse — parsed BEFORE any work):
  --db PATH               override the DB path (else CAST_DB_PATH / ~/.claude/cast.db).
  --dry-run                report counts, write nothing (same as CAST_DB_ROLLUP_DRY_RUN=1).
  --authoritative-days N   override the authoritative/insert-only cutoff window;
                            default CAST_DB_PRUNE_DAYS (else 90). MUST match
                            cast-db-prune.py's own retention window — that window is
                            exactly what determines whether raw is still complete.
  -h/--help   print usage and exit 0 WITHOUT rolling up.
  An UNKNOWN flag (argparse default) exits 2 WITHOUT rolling up.

Exit codes (a caller gates a DESTRUCTIVE prune on this — fail closed):
  0 = success (including dry-run, including "nothing to roll up").
  1 = ANY failure: DB missing, a rollup table absent (remediation:
      `python3 scripts/cast-migrate.py --confirm`), SQL error, connect failure.
  2 = unknown CLI flag (argparse default) — never proceeds to work.

Output: a one-line JSON summary on stdout —
  {"agent_runs_daily": N, "mcp_calls_daily": M,
   "excluded_agent_runs": X, "excluded_mcp_calls": Y, "dry_run": bool}

Usage:
  python3 scripts/cast-db-rollup.py
  python3 scripts/cast-db-rollup.py --dry-run
  python3 scripts/cast-db-rollup.py --authoritative-days 30
  CAST_DB_ROLLUP_DRY_RUN=1 python3 scripts/cast-db-rollup.py
  CAST_DB_PATH=/tmp/test.db python3 scripts/cast-db-rollup.py
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

DB_PATH: str = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
DRY_RUN: bool = os.environ.get('CAST_DB_ROLLUP_DRY_RUN', '0') == '1'
LOG_PATH: str = os.path.expanduser('~/.claude/logs/cron-db-rollup.log')

_MIGRATE_REMEDIATION = 'python3 scripts/cast-migrate.py --confirm'

_AUTHORITATIVE_DAYS_ENV = 'CAST_DB_PRUNE_DAYS'
_AUTHORITATIVE_DAYS_FALLBACK = 90


def _default_authoritative_days() -> int:
    """Mirror cast-db-prune.py's own CAST_DB_PRUNE_DAYS (default 90) — the
    window that determines whether raw agent_runs/routing_events rows for a
    given day are still guaranteed complete. An invalid/unset env value falls
    back to 90 rather than aborting: unlike cast-db-prune.py (which deletes
    and must fail closed on a bad retention value), this script only reads,
    so a bad env var should degrade to the documented default, not crash."""
    raw = os.environ.get(_AUTHORITATIVE_DAYS_ENV, str(_AUTHORITATIVE_DAYS_FALLBACK))
    try:
        value = int(raw)
    except ValueError:
        return _AUTHORITATIVE_DAYS_FALLBACK
    return value if value >= 0 else _AUTHORITATIVE_DAYS_FALLBACK


def _cutoff_day(authoritative_days: int) -> str:
    """UTC calendar day (YYYY-MM-DD) containing `now - authoritative_days
    days` — the same instant cast-db-prune.py's `datetime('now','-N days')`
    computes inside SQLite (also UTC); this is that instant's date part only.
    """
    cutoff_instant = datetime.now(timezone.utc) - timedelta(days=authoritative_days)
    return cutoff_instant.strftime('%Y-%m-%d')


# --- Step A: agent_runs -> agent_runs_daily ---

# Authoritative side (day > cutoff_day): raw is guaranteed complete, so any
# existing aggregate row(s) for these days are cleared first, then rebuilt
# fresh from raw. This is what lets a mutated status (running -> abandoned)
# replace its stale group instead of merely being blocked from shrinking it.
_DELETE_AUTHORITATIVE_AGENT_RUNS_DAILY_SQL = "DELETE FROM agent_runs_daily WHERE day > ?"

_INSERT_AUTHORITATIVE_AGENT_RUNS_SQL = """
INSERT INTO agent_runs_daily (
    day, agent, model, status, runs, with_response,
    input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens,
    cost_usd, duration_ms, tool_uses, rolled_up_at
)
SELECT
    substr(started_at, 1, 10) AS day,
    COALESCE(agent, '') AS agent,
    COALESCE(model, '') AS model,
    COALESCE(status, '') AS status,
    COUNT(*) AS runs,
    SUM(CASE WHEN response IS NOT NULL AND response <> '' THEN 1 ELSE 0 END) AS with_response,
    COALESCE(SUM(input_tokens), 0),
    COALESCE(SUM(output_tokens), 0),
    COALESCE(SUM(cache_read_input_tokens), 0),
    COALESCE(SUM(cache_creation_input_tokens), 0),
    COALESCE(SUM(cost_usd), 0),
    COALESCE(SUM(duration_ms), 0),
    COALESCE(SUM(tool_uses), 0),
    ?
FROM agent_runs
WHERE started_at IS NOT NULL AND started_at <> ''
  AND substr(started_at, 1, 10) > ?
GROUP BY 1, 2, 3, 4
"""
# No ON CONFLICT here: the matching DELETE above already cleared every row for
# day > cutoff_day, so this plain INSERT cannot collide with a survivor.

# Insert-only side (day <= cutoff_day): raw may already be partially pruned,
# so NEVER delete here; upsert only under the monotone non-shrinking guard —
# belt-and-braces once a day has left the authoritative window. See the
# module docstring's AUTHORITATIVE-WINDOW RULE for why the `<=` boundary
# (not `<`) is on this, the safe, side.
_UPSERT_INSERT_ONLY_AGENT_RUNS_SQL = """
INSERT INTO agent_runs_daily (
    day, agent, model, status, runs, with_response,
    input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens,
    cost_usd, duration_ms, tool_uses, rolled_up_at
)
SELECT
    substr(started_at, 1, 10) AS day,
    COALESCE(agent, '') AS agent,
    COALESCE(model, '') AS model,
    COALESCE(status, '') AS status,
    COUNT(*) AS runs,
    SUM(CASE WHEN response IS NOT NULL AND response <> '' THEN 1 ELSE 0 END) AS with_response,
    COALESCE(SUM(input_tokens), 0),
    COALESCE(SUM(output_tokens), 0),
    COALESCE(SUM(cache_read_input_tokens), 0),
    COALESCE(SUM(cache_creation_input_tokens), 0),
    COALESCE(SUM(cost_usd), 0),
    COALESCE(SUM(duration_ms), 0),
    COALESCE(SUM(tool_uses), 0),
    ?
FROM agent_runs
WHERE started_at IS NOT NULL AND started_at <> ''
  AND substr(started_at, 1, 10) <= ?
GROUP BY 1, 2, 3, 4
ON CONFLICT(day, agent, model, status) DO UPDATE SET
    runs = excluded.runs,
    with_response = excluded.with_response,
    input_tokens = excluded.input_tokens,
    output_tokens = excluded.output_tokens,
    cache_read_input_tokens = excluded.cache_read_input_tokens,
    cache_creation_input_tokens = excluded.cache_creation_input_tokens,
    cost_usd = excluded.cost_usd,
    duration_ms = excluded.duration_ms,
    tool_uses = excluded.tool_uses,
    rolled_up_at = excluded.rolled_up_at
WHERE excluded.runs >= agent_runs_daily.runs
"""

_COUNT_AGENT_RUNS_GROUPS_SQL = """
SELECT COUNT(*) FROM (
    SELECT 1
    FROM agent_runs
    WHERE started_at IS NOT NULL AND started_at <> ''
    GROUP BY substr(started_at, 1, 10), COALESCE(agent, ''), COALESCE(model, ''), COALESCE(status, '')
)
"""

_COUNT_EXCLUDED_AGENT_RUNS_SQL = """
SELECT COUNT(*) FROM agent_runs WHERE started_at IS NULL OR started_at = ''
"""

# --- Step B: routing_events (mcp_tool_call) -> mcp_calls_daily ---
# is_cloud_bound: json_extract() already returns SQLite INTEGER 0/1 for a JSON
# boolean (verified empirically against sqlite3 3.53.4); CAST(...AS INTEGER)
# is defense-in-depth for any payload that stored it as a JSON string
# ("true"/"false") instead of a JSON boolean.

_DELETE_AUTHORITATIVE_MCP_CALLS_DAILY_SQL = "DELETE FROM mcp_calls_daily WHERE day > ?"

_INSERT_AUTHORITATIVE_MCP_CALLS_SQL = """
INSERT INTO mcp_calls_daily (
    day, mcp_server, mcp_tool, outcome, is_cloud_bound, calls, result_bytes, rolled_up_at
)
SELECT
    substr(json_extract(data, '$.timestamp'), 1, 10) AS day,
    COALESCE(json_extract(data, '$.mcp_server'), '') AS mcp_server,
    COALESCE(json_extract(data, '$.mcp_tool'), '') AS mcp_tool,
    COALESCE(json_extract(data, '$.outcome'), '') AS outcome,
    COALESCE(CAST(json_extract(data, '$.is_cloud_bound') AS INTEGER), 0) AS is_cloud_bound,
    COUNT(*) AS calls,
    COALESCE(SUM(json_extract(data, '$.result_size')), 0) AS result_bytes,
    ?
FROM routing_events
WHERE event_type = 'mcp_tool_call'
  AND data IS NOT NULL AND data <> ''
  AND json_valid(data)
  AND json_extract(data, '$.timestamp') IS NOT NULL
  AND substr(json_extract(data, '$.timestamp'), 1, 10) > ?
GROUP BY 1, 2, 3, 4, 5
"""

_UPSERT_INSERT_ONLY_MCP_CALLS_SQL = """
INSERT INTO mcp_calls_daily (
    day, mcp_server, mcp_tool, outcome, is_cloud_bound, calls, result_bytes, rolled_up_at
)
SELECT
    substr(json_extract(data, '$.timestamp'), 1, 10) AS day,
    COALESCE(json_extract(data, '$.mcp_server'), '') AS mcp_server,
    COALESCE(json_extract(data, '$.mcp_tool'), '') AS mcp_tool,
    COALESCE(json_extract(data, '$.outcome'), '') AS outcome,
    COALESCE(CAST(json_extract(data, '$.is_cloud_bound') AS INTEGER), 0) AS is_cloud_bound,
    COUNT(*) AS calls,
    COALESCE(SUM(json_extract(data, '$.result_size')), 0) AS result_bytes,
    ?
FROM routing_events
WHERE event_type = 'mcp_tool_call'
  AND data IS NOT NULL AND data <> ''
  AND json_valid(data)
  AND json_extract(data, '$.timestamp') IS NOT NULL
  AND substr(json_extract(data, '$.timestamp'), 1, 10) <= ?
GROUP BY 1, 2, 3, 4, 5
ON CONFLICT(day, mcp_server, mcp_tool, outcome, is_cloud_bound) DO UPDATE SET
    calls = excluded.calls,
    result_bytes = excluded.result_bytes,
    rolled_up_at = excluded.rolled_up_at
WHERE excluded.calls >= mcp_calls_daily.calls
"""

_COUNT_MCP_CALLS_GROUPS_SQL = """
SELECT COUNT(*) FROM (
    SELECT 1
    FROM routing_events
    WHERE event_type = 'mcp_tool_call'
      AND data IS NOT NULL AND data <> ''
      AND json_valid(data)
      AND json_extract(data, '$.timestamp') IS NOT NULL
    GROUP BY
        substr(json_extract(data, '$.timestamp'), 1, 10),
        COALESCE(json_extract(data, '$.mcp_server'), ''),
        COALESCE(json_extract(data, '$.mcp_tool'), ''),
        COALESCE(json_extract(data, '$.outcome'), ''),
        COALESCE(CAST(json_extract(data, '$.is_cloud_bound') AS INTEGER), 0)
)
"""

_COUNT_EXCLUDED_MCP_CALLS_SQL = """
SELECT COUNT(*) FROM routing_events
WHERE event_type = 'mcp_tool_call'
  AND (
    data IS NULL OR data = ''
    OR NOT json_valid(data)
    OR json_extract(data, '$.timestamp') IS NULL
  )
"""

_REQUIRED_TABLES = ('agent_runs_daily', 'mcp_calls_daily')


def _log(msg: str) -> None:
    """Append a timestamped line to the log file. Never raises."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        line = f'[{ts}] {msg}'
        print(line, file=sys.stderr)
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


def _parse_args(argv) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog='cast-db-rollup.py',
        description='Aggregate raw agent_runs/routing_events into daily rollup tables before prune.',
    )
    parser.add_argument(
        '--db', type=str, default=None, metavar='PATH',
        help='DB path override; else CAST_DB_PATH / ~/.claude/cast.db.',
    )
    parser.add_argument(
        '--dry-run', action='store_true', default=False,
        help='Report would-roll-up counts without writing anything.',
    )
    parser.add_argument(
        '--authoritative-days', type=int, default=None, metavar='N',
        help='Days newer than this are treated as authoritative (delete+rebuild); '
             'else CAST_DB_PRUNE_DAYS (default 90) — must match cast-db-prune.py.',
    )
    return parser.parse_args(argv)


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    return row is not None


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def run_rollup(db_path: str, dry_run: bool, authoritative_days: int = None) -> dict:
    """Perform (or dry-run count) the rollup. Returns the JSON summary dict.

    Raises RuntimeError on any failure (missing DB, missing table, SQL error) —
    the caller is responsible for logging + exit code 1.
    """
    if authoritative_days is None:
        authoritative_days = _default_authoritative_days()
    cutoff_day = _cutoff_day(authoritative_days)

    if not os.path.exists(db_path):
        raise RuntimeError(f'cast.db not found at {db_path}')

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except Exception as e:
        raise RuntimeError(f'DB connect failed: {e}') from e

    try:
        for table in _REQUIRED_TABLES:
            if not _table_exists(conn, table):
                raise RuntimeError(
                    f"rollup table '{table}' does not exist — run "
                    f"'{_MIGRATE_REMEDIATION}' to provision it"
                )

        # Read-only visibility counts (FIX 2 / security MEDIUM) — computed
        # regardless of dry-run so both branches report the same gap.
        excluded_agent_runs = conn.execute(_COUNT_EXCLUDED_AGENT_RUNS_SQL).fetchone()[0]
        excluded_mcp_calls = conn.execute(_COUNT_EXCLUDED_MCP_CALLS_SQL).fetchone()[0]

        if dry_run:
            agent_runs_count = conn.execute(_COUNT_AGENT_RUNS_GROUPS_SQL).fetchone()[0]
            mcp_calls_count = conn.execute(_COUNT_MCP_CALLS_GROUPS_SQL).fetchone()[0]
            return {
                'agent_runs_daily': agent_runs_count,
                'mcp_calls_daily': mcp_calls_count,
                'excluded_agent_runs': excluded_agent_runs,
                'excluded_mcp_calls': excluded_mcp_calls,
                'dry_run': True,
            }

        # cursor.rowcount on an INSERT (including ON CONFLICT DO UPDATE)
        # reflects rows actually inserted OR updated (sqlite3_changes()) —
        # verified empirically: a row blocked by the monotone WHERE guard
        # reports rowcount 0. Summed across the authoritative (delete+insert)
        # and insert-only (guarded upsert) statements, this is "rows actually
        # written to the daily table this run" for that table.
        now = _now_iso()
        try:
            conn.execute('BEGIN')

            conn.execute(_DELETE_AUTHORITATIVE_AGENT_RUNS_DAILY_SQL, (cutoff_day,))
            cur = conn.execute(_INSERT_AUTHORITATIVE_AGENT_RUNS_SQL, (now, cutoff_day))
            agent_runs_written = cur.rowcount if cur.rowcount >= 0 else 0
            cur = conn.execute(_UPSERT_INSERT_ONLY_AGENT_RUNS_SQL, (now, cutoff_day))
            agent_runs_written += cur.rowcount if cur.rowcount >= 0 else 0

            conn.execute(_DELETE_AUTHORITATIVE_MCP_CALLS_DAILY_SQL, (cutoff_day,))
            cur = conn.execute(_INSERT_AUTHORITATIVE_MCP_CALLS_SQL, (now, cutoff_day))
            mcp_calls_written = cur.rowcount if cur.rowcount >= 0 else 0
            cur = conn.execute(_UPSERT_INSERT_ONLY_MCP_CALLS_SQL, (now, cutoff_day))
            mcp_calls_written += cur.rowcount if cur.rowcount >= 0 else 0

            conn.commit()
        except Exception:
            conn.rollback()
            raise

        return {
            'agent_runs_daily': agent_runs_written,
            'mcp_calls_daily': mcp_calls_written,
            'excluded_agent_runs': excluded_agent_runs,
            'excluded_mcp_calls': excluded_mcp_calls,
            'dry_run': False,
        }
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main() -> None:
    global DB_PATH, DRY_RUN
    args = _parse_args(sys.argv[1:])
    if args.db is not None:
        DB_PATH = args.db
    if args.dry_run:
        DRY_RUN = True

    mode_label = '[DRY-RUN] ' if DRY_RUN else ''
    _log(f'{mode_label}cast-db-rollup starting — db={DB_PATH}')

    try:
        summary = run_rollup(DB_PATH, DRY_RUN, args.authoritative_days)
    except RuntimeError as e:
        _log(f'ERROR: {e}')
        print(f'[cast-db-rollup] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        _log(f'ERROR: unexpected failure: {e}')
        print(f'[cast-db-rollup] ERROR: unexpected failure: {e}', file=sys.stderr)
        sys.exit(1)

    _log(
        f'{mode_label}cast-db-rollup finished — '
        f'agent_runs_daily={summary["agent_runs_daily"]} '
        f'mcp_calls_daily={summary["mcp_calls_daily"]} '
        f'excluded_agent_runs={summary["excluded_agent_runs"]} '
        f'excluded_mcp_calls={summary["excluded_mcp_calls"]}'
    )
    print(json.dumps(summary))
    sys.exit(0)


if __name__ == '__main__':
    main()
