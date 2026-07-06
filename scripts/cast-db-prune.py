#!/usr/bin/env python3
"""cast-db-prune.py — Delete rows older than the retention window from cast.db.

Runs nightly via launchd (com.cast.db-prune). Four symmetric steps:

  Step 1 — routing_events: rows whose `timestamp` is older than DAYS days
  are deleted. (Column name is `timestamp`, NOT `created_at`.)

  Step 2 — agent_runs: rows whose `started_at` is older than DAYS days
  are deleted.

  Step 3 — otel_events: rows whose `received_at` is older than OTEL_DAYS
  days are deleted. (OTLP feed — the largest table on the live DB.)

  Step 4 — otel_metrics: rows whose `received_at` is older than OTEL_DAYS
  days are deleted. (OTLP feed.)

Each table's delete is wrapped in an independent try/except so a missing
table or column does NOT abort the other steps or crash the script.

Fail-closed backup gate (real prune only):
  Before any destructive DELETE, cast-db-backup.py is invoked as a
  subprocess.  If the backup exits non-zero, times out, or cannot be found,
  ALL delete steps are skipped entirely and a loud ERROR is logged.  The
  script still exits 0 to preserve the cron/launchd contract.  There is NO
  escape hatch — a real prune never proceeds without a successful backup.

Dry-run mode: set CAST_DB_PRUNE_DRY_RUN=1 to report would-delete counts
without actually deleting (useful for safe verification and tests).  Dry-run
skips the backup gate because it performs no destructive operations.

Retention:
  CAST_DB_PRUNE_DAYS  (default 90) — routing_events + agent_runs (steps 1-2).
  CAST_PRUNE_OTEL_DAYS (default 30) — otel_events + otel_metrics (steps 3-4).
  The OTLP feed is high-volume and low-half-life, so it defaults to a tighter
  window. Set either lower to prune more aggressively, higher to retain more.

CLI flags (argparse — parsed BEFORE any destructive work):
  --days N    override the routing_events/agent_runs window (else CAST_DB_PRUNE_DAYS).
  --dry-run   report would-delete counts, delete nothing (same as CAST_DB_PRUNE_DRY_RUN=1).
  -h/--help   print usage and exit 0 WITHOUT pruning.
  An UNKNOWN flag (argparse default) exits 2 WITHOUT pruning — a fat-fingered flag
  (e.g. a stray `--help` typo) must never fall through and run the prune (2026-07-05
  live footgun: unparsed flags previously reached the delete path).

Exit: 0 on success, non-destructive skip (backup failure, dry-run), or --help;
  1 on invalid retention-days value (CAST_DB_PRUNE_DAYS / CAST_PRUNE_OTEL_DAYS / --days
  < 1 or non-numeric) — aborting is safer than silently reinterpreting a bad value for
  a destructive script; 2 on an unknown CLI flag (argparse) — never prune on a typo.

Usage:
  python3 ~/.claude/scripts/cast-db-prune.py
  python3 ~/.claude/scripts/cast-db-prune.py --days 30 --dry-run
  CAST_DB_PRUNE_DAYS=30 python3 ~/.claude/scripts/cast-db-prune.py
  CAST_PRUNE_OTEL_DAYS=14 python3 ~/.claude/scripts/cast-db-prune.py
  CAST_DB_PRUNE_DRY_RUN=1 python3 ~/.claude/scripts/cast-db-prune.py
  # Or via launchd plist (com.cast.db-prune — runs nightly at 03:30).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

def _parse_retention_days(env_var: str, default: int) -> int:
    """Parse a retention-days env var, aborting on invalid values.

    A value of 0 computes datetime('now','-0 days') which deletes everything
    including today; a negative value computes a FUTURE cutoff that deletes
    all rows including the freshest ones.  Both are almost certainly operator
    errors, so we abort (exit 1) rather than silently clamp — a wrong env var
    should stop the prune, not reinterpret it.
    """
    raw = os.environ.get(env_var, str(default))
    try:
        value = int(raw)
    except ValueError:
        print(
            f'ERROR: {env_var}={raw!r} is not a valid integer — aborting prune',
            file=sys.stderr,
        )
        sys.exit(1)
    if value < 1:
        print(
            f'ERROR: {env_var}={value} is < 1 (would delete all rows or compute a'
            f' future cutoff) — aborting prune',
            file=sys.stderr,
        )
        sys.exit(1)
    return value


def _parse_args(argv) -> argparse.Namespace:
    """Parse CLI flags. argparse gives -h/--help (exit 0) and rejects unknown flags
    (exit 2) FOR FREE — the fail-safe that stops a stray flag from reaching the prune.

    --days defaults to None (env CAST_DB_PRUNE_DAYS wins); --dry-run OR's with the
    CAST_DB_PRUNE_DRY_RUN env var. Neither flag weakens the fail-closed backup gate.
    """
    parser = argparse.ArgumentParser(
        prog='cast-db-prune.py',
        description='Delete rows older than the retention window from cast.db.',
    )
    parser.add_argument(
        '--days', type=int, default=None, metavar='N',
        help='Retention window (days) for routing_events + agent_runs; '
             'overrides CAST_DB_PRUNE_DAYS (default 90).',
    )
    parser.add_argument(
        '--dry-run', action='store_true', default=False,
        help='Report would-delete counts without deleting anything.',
    )
    return parser.parse_args(argv)


# --- Config ---
DB_PATH: str = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
DAYS: int = _parse_retention_days('CAST_DB_PRUNE_DAYS', 90)
# OTLP feed (otel_events/otel_metrics) is high-volume; default to a tighter window.
OTEL_DAYS: int = _parse_retention_days('CAST_PRUNE_OTEL_DAYS', 30)
DRY_RUN: bool = os.environ.get('CAST_DB_PRUNE_DRY_RUN', '0') == '1'
LOG_PATH: str = os.path.expanduser('~/.claude/logs/cron-db-prune.log')


_SQL_IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\Z')


def _safe_ident(name: str) -> str:
    """Reject any SQL identifier that isn't a bare word before f-string
    interpolation. Table/column names here are trusted (hardcoded), so this
    is defense-in-depth against a future untrusted caller — not a live fix."""
    if not _SQL_IDENT_RE.match(name):
        raise ValueError(f'unsafe SQL identifier: {name!r}')
    return name


def _log(msg: str) -> None:
    """Append a timestamped line to the log file and print to stdout. Never fails."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        line = f'[{ts}] {msg}'
        print(line)
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass


def _pre_prune_backup() -> int:
    """Run cast-db-backup.py before deleting any rows.

    Fail-closed gate: if the backup subprocess exits non-zero, times out, or
    cannot be invoked, log a loud ERROR and return 1.  The caller MUST skip
    both delete steps — never prune without a successful backup.

    On success, log a one-line confirmation and return 0.
    """
    script_dir = Path(__file__).resolve().parent
    backup_script = script_dir / 'cast-db-backup.py'

    if not backup_script.exists():
        _log(f'ERROR: Pre-prune backup script not found: {backup_script} — skipping prune')
        return 1

    try:
        result = subprocess.run(
            [sys.executable, str(backup_script)],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        _log('ERROR: Pre-prune backup timed out after 120s — skipping prune')
        return 1
    except Exception as e:
        _log(f'ERROR: Pre-prune backup invocation failed: {e} — skipping prune')
        return 1

    if result.returncode != 0:
        raw = result.stdout.strip()
        error_detail = ''
        if raw:
            try:
                payload = json.loads(raw)
                error_detail = payload.get('error', raw)
            except json.JSONDecodeError:
                error_detail = raw
        if not error_detail and result.stderr.strip():
            error_detail = result.stderr.strip()
        _log(f'ERROR: Pre-prune backup failed: {error_detail} — skipping prune')
        return 1

    raw = result.stdout.strip()
    try:
        payload = json.loads(raw)
        backup_path = payload.get('backup_path', '(unknown)')
    except json.JSONDecodeError:
        backup_path = '(unparseable output)'

    _log(f'Pre-prune backup OK: {backup_path}')
    return 0


def _prune_table(
    conn: sqlite3.Connection,
    table: str,
    ts_col: str,
    days: int = DAYS,
) -> int:
    """Delete (or count for dry-run) rows older than `days` days. Returns row count.

    `days` defaults to the module-level DAYS (routing_events/agent_runs window);
    the OTLP steps pass OTEL_DAYS for a tighter, independent retention window.

    Uses SQLite's datetime('now', '-N days') inline so the comparison is
    evaluated inside SQLite against its own stored timestamp format.
    """
    table = _safe_ident(table)
    ts_col = _safe_ident(ts_col)
    days_expr = f"datetime('now', '-{days} days')"
    if DRY_RUN:
        cursor = conn.execute(
            f"SELECT COUNT(*) FROM {table} WHERE {ts_col} < {days_expr}",
        )
        count = cursor.fetchone()[0]
        return count
    else:
        result = conn.execute(
            f"DELETE FROM {table} WHERE {ts_col} < {days_expr}",
        )
        conn.commit()
        return result.rowcount


def main() -> None:
    # Parse CLI flags FIRST — before the backup gate or any DELETE. --help exits 0
    # and an unknown flag exits 2 here, so neither can fall through to the prune.
    global DAYS, DRY_RUN
    args = _parse_args(sys.argv[1:])
    if args.days is not None:
        if args.days < 1:
            print(
                f'ERROR: --days={args.days} is < 1 (would delete all rows or compute a'
                f' future cutoff) — aborting prune',
                file=sys.stderr,
            )
            sys.exit(1)
        DAYS = args.days
    if args.dry_run:
        DRY_RUN = True

    mode_label = '[DRY-RUN] ' if DRY_RUN else ''
    _log(f'{mode_label}cast-db-prune starting — DAYS={DAYS} db={DB_PATH}')

    if not os.path.exists(DB_PATH):
        _log(f'cast.db not found at {DB_PATH} — skipping')
        sys.exit(0)

    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
    except Exception as e:
        print(f'[cast-db-prune] DB connect failed: {e}', file=sys.stderr)
        _log(f'DB connect failed: {e}')
        sys.exit(0)

    try:
        # --- Fail-closed backup gate (real prune only; dry-run is read-only) ---
        if not DRY_RUN:
            if _pre_prune_backup() != 0:
                _log('ERROR: Skipping all delete steps — prune aborted (fail-closed)')
                sys.exit(0)

        # --- Step 1: routing_events (column: timestamp) ---
        # Pass days=DAYS explicitly: a --days override reassigns the module global,
        # but _prune_table's default param binds DAYS at def-time (stale otherwise).
        try:
            count = _prune_table(conn, 'routing_events', 'timestamp', days=DAYS)
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}routing_events: {action} {count} row(s) older than {DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] routing_events step failed: {e}', file=sys.stderr)
            _log(f'routing_events step failed (non-fatal): {e}')

        # --- Step 2: agent_runs (column: started_at) ---
        try:
            count = _prune_table(conn, 'agent_runs', 'started_at', days=DAYS)
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}agent_runs: {action} {count} row(s) older than {DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] agent_runs step failed: {e}', file=sys.stderr)
            _log(f'agent_runs step failed (non-fatal): {e}')

        # --- Step 3: otel_events (column: received_at, window: OTEL_DAYS) ---
        try:
            count = _prune_table(conn, 'otel_events', 'received_at', days=OTEL_DAYS)
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}otel_events: {action} {count} row(s) older than {OTEL_DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] otel_events step failed: {e}', file=sys.stderr)
            _log(f'otel_events step failed (non-fatal): {e}')

        # --- Step 4: otel_metrics (column: received_at, window: OTEL_DAYS) ---
        try:
            count = _prune_table(conn, 'otel_metrics', 'received_at', days=OTEL_DAYS)
            action = 'would delete' if DRY_RUN else 'deleted'
            _log(f'{mode_label}otel_metrics: {action} {count} row(s) older than {OTEL_DAYS} days')
        except Exception as e:
            print(f'[cast-db-prune] otel_metrics step failed: {e}', file=sys.stderr)
            _log(f'otel_metrics step failed (non-fatal): {e}')

    except Exception as e:
        print(f'[cast-db-prune] Unexpected error: {e}', file=sys.stderr)
        _log(f'Unexpected error: {e}')
    finally:
        try:
            conn.close()
        except Exception:
            pass

    _log(f'{mode_label}cast-db-prune finished')
    sys.exit(0)


if __name__ == '__main__':
    main()
