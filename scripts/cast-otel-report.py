#!/usr/bin/env python3
"""
cast-otel-report.py — READ-ONLY reporter over the otel_events table (stdlib only).

Summarises Claude Code native OTel events that cast-otel-collector.py already
stores in cast.db. Retention of otel_events is 7 days, so --days beyond 7 adds
nothing.

SECTIONS:
  tool_decision  tool_decision counts by permission_mode x classifier_verdict x decision x source
  cache          api_request token / cache split and cost per day
  hooks          hook_execution_complete stats per hook_name
  workflow       api_request cost roll-up per workflow.run_id
  safety         count of claude_code.safety_event rows (see FINDING)

FINDING (2026-11-20): zero safety_event rows have ever landed, including after
a PreToolUse hook rejected a Bash call (that rejection DID land as a
tool_decision decision=reject row). The collector stores any event.name
unfiltered, so Claude Code 2.1.311 is not exporting claude_code.safety_event on
the logs pipeline in this config (possibly traces-only). The reject count from
the tool_decision section is the available proxy.

DB ACCESS (deliberate deviation from cast_db.db_query):
  db_query swallows errors and returns [], so an error would look identical to
  "no data", and its connection sets WAL pragmas. A reporter must fail loudly
  and must not write. This script opens the DB with mode=ro and exits 1 on a
  missing file, missing otel_events table, or any sqlite3 error. The path is
  CAST_DB_PATH (default ~/.claude/cast.db), checked with
  cast_db.validate_db_path when importable.

NUMERICS: hook-event attributes are JSON strings ("4"), api_request ones are
JSON numbers; every numeric is CAST in SQL. Note: SQLite CAST(... AS REAL) turns
a non-numeric string into 0, so a garbage attribute counts as 0, not as an error.

SANITIZING: values come from an unauthenticated localhost OTLP collector, so
text-mode tables replace C0/C1 control characters (incl. ESC, BEL, newline) with '?'.

LIMITS: --days must be within 1..3650, --limit within 1..1000 (out of range is an
argument error). --limit applies to the hooks and workflow sections only.

Usage:
  cast-otel-report.py [--days N] [--section tool_decision|cache|hooks|workflow|safety|all]
                      [--limit N] [--json]
Exit: 0 ok, 1 error (argument errors too). With --json the output is always valid
JSON ({"error": ...} on error, including argument errors).
"""

import argparse
import datetime
import json
import os
import re
import sqlite3
import sys
from typing import Any, Callable, Dict, List, Optional, Sequence
from urllib.parse import quote

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

try:
    import cast_db as _cast_db  # type: ignore
except Exception:  # noqa: BLE001 - fall back to the plain path (warned in resolve_db_path)
    _cast_db = None  # type: ignore

_CTRL_RE = re.compile(r'[\x00-\x1f\x7f-\x9f]')
MAX_DAYS = 3650
MAX_LIMIT = 1000

DEFAULT_DAYS = 7
DEFAULT_LIMIT = 20
SECTION_NAMES = ('tool_decision', 'cache', 'hooks', 'workflow', 'safety')

Row = Dict[str, Any]


def _attr(key: str) -> str:
    """SQL fragment extracting a (possibly dotted) attribute; key is a fixed literal."""
    return f"json_extract(body, '$.attributes.\"{key}\"')"


def _num(key: str) -> str:
    return f"CAST({_attr(key)} AS REAL)"


def _dash(key: str) -> str:
    return f"COALESCE({_attr(key)}, '-')"


def cutoff_iso(days: int, now: Optional[datetime.datetime] = None) -> str:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return (now - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%S')


def _rows(conn: sqlite3.Connection, sql: str, params: Sequence[Any]) -> List[Row]:
    cur = conn.execute(sql, tuple(params))
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def tool_decision(conn: sqlite3.Connection, cutoff: str, limit: int = DEFAULT_LIMIT) -> List[Row]:
    sql = (
        f"SELECT {_dash('permission_mode')} AS permission_mode, "
        f"{_dash('classifier_verdict')} AS classifier_verdict, "
        f"{_dash('decision')} AS decision, {_dash('source')} AS source, "
        "COUNT(*) AS n FROM otel_events "
        "WHERE event_name = 'tool_decision' AND received_at >= ? "
        "GROUP BY 1, 2, 3, 4 ORDER BY n DESC, 1, 2, 3, 4"
    )
    return _rows(conn, sql, (cutoff,))


def cache(conn: sqlite3.Connection, cutoff: str, limit: int = DEFAULT_LIMIT) -> List[Row]:
    sql = (
        "SELECT substr(received_at, 1, 10) AS day, COUNT(*) AS requests, "
        f"CAST(COALESCE(SUM({_num('input_tokens')}), 0) AS INTEGER) AS input_tokens, "
        f"CAST(COALESCE(SUM({_num('output_tokens')}), 0) AS INTEGER) AS output_tokens, "
        f"CAST(COALESCE(SUM({_num('cache_read_tokens')}), 0) AS INTEGER) AS cache_read_tokens, "
        f"CAST(COALESCE(SUM({_num('cache_creation_5m_tokens')}), 0) AS INTEGER) AS cache_5m_tokens, "
        f"CAST(COALESCE(SUM({_num('cache_creation_1h_tokens')}), 0) AS INTEGER) AS cache_1h_tokens, "
        f"ROUND(COALESCE(SUM({_num('cost_usd')}), 0), 2) AS cost_usd "
        "FROM otel_events WHERE event_name = 'api_request' AND received_at >= ? "
        "GROUP BY day ORDER BY day"
    )
    return _rows(conn, sql, (cutoff,))


def hooks(conn: sqlite3.Connection, cutoff: str, limit: int = DEFAULT_LIMIT) -> List[Row]:
    sql = (
        f"SELECT {_dash('hook_name')} AS hook_name, COUNT(*) AS executions, "
        f"ROUND(AVG({_num('total_duration_ms')}), 1) AS avg_ms, "
        f"CAST(COALESCE(SUM({_num('stdout_chars')}), 0) AS INTEGER) AS stdout_chars, "
        f"CAST(COALESCE(MAX({_num('stdout_chars')}), 0) AS INTEGER) AS max_stdout_chars, "
        f"CAST(COALESCE(SUM({_num('additional_context_chars')}), 0) AS INTEGER) AS context_chars, "
        f"SUM(CASE WHEN {_num('num_outputs_persisted')} > 0 THEN 1 ELSE 0 END) AS persisted, "
        f"CAST(COALESCE(SUM({_num('num_blocking')}), 0) AS INTEGER) AS blocking "
        "FROM otel_events WHERE event_name = 'hook_execution_complete' AND received_at >= ? "
        "GROUP BY 1 ORDER BY executions DESC, hook_name LIMIT ?"
    )
    return _rows(conn, sql, (cutoff, int(limit)))


def workflow(conn: sqlite3.Connection, cutoff: str, limit: int = DEFAULT_LIMIT) -> List[Row]:
    run = _attr('workflow.run_id')
    sql = (
        f"SELECT {run} AS run_id, "
        f"COALESCE(MAX({_attr('workflow.name')}), '-') AS name, COUNT(*) AS requests, "
        f"ROUND(COALESCE(SUM({_num('cost_usd')}), 0), 4) AS cost_usd, "
        f"group_concat(DISTINCT {_attr('model')}) AS models, "
        "MIN(received_at) AS first_seen, MAX(received_at) AS last_seen "
        "FROM otel_events "
        f"WHERE event_name = 'api_request' AND received_at >= ? AND {run} IS NOT NULL "
        "GROUP BY run_id ORDER BY cost_usd DESC, run_id LIMIT ?"
    )
    return _rows(conn, sql, (cutoff, int(limit)))


def safety(conn: sqlite3.Connection, cutoff: str, limit: int = DEFAULT_LIMIT) -> List[Row]:
    sql = (
        "SELECT COUNT(*) AS safety_events FROM otel_events "
        "WHERE event_name = 'safety_event' AND received_at >= ?"
    )
    return _rows(conn, sql, (cutoff,))


SECTIONS: Dict[str, Callable[..., List[Row]]] = {
    'tool_decision': tool_decision,
    'cache': cache,
    'hooks': hooks,
    'workflow': workflow,
    'safety': safety,
}

SAFETY_NOTE = (
    "0 safety_event rows: Claude Code 2.1.311 is not exporting claude_code.safety_event "
    "on the logs pipeline in this config (finding 2026-11-20). This does NOT mean nothing "
    "was blocked; use the decision=reject count in the tool_decision section as the proxy."
)


def reject_count(rows: List[Row]) -> int:
    return sum(r['n'] for r in rows if r.get('decision') == 'reject')


def format_table(rows: List[Row]) -> str:
    if not rows:
        return '(no rows in window)'
    cols = list(rows[0].keys())
    cells = [[_CTRL_RE.sub('?', str(r[c])) if r[c] is not None else '-' for c in cols] for r in rows]
    widths = [max(len(c), *(len(row[i]) for row in cells)) for i, c in enumerate(cols)]
    lines = ['  '.join(c.ljust(widths[i]) for i, c in enumerate(cols)),
             '  '.join('-' * w for w in widths)]
    lines += ['  '.join(v.ljust(widths[i]) for i, v in enumerate(row)) for row in cells]
    return '\n'.join(lines)


def resolve_db_path() -> str:
    raw = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
    if _cast_db is not None and hasattr(_cast_db, 'validate_db_path'):
        return _cast_db.validate_db_path(raw, 'CAST_DB_PATH')
    print('cast-otel-report: cast_db unavailable; CAST_DB_PATH not allowlist-checked',
          file=sys.stderr)
    return raw


def open_ro(path: str) -> sqlite3.Connection:
    if not os.path.isfile(path):
        raise FileNotFoundError(f'database not found: {path}')
    conn = sqlite3.connect(f'file:{quote(path)}?mode=ro', uri=True, timeout=5)
    has = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='otel_events'"
    ).fetchone()
    if not has:
        conn.close()
        raise LookupError(f'table otel_events not found in {path}')
    return conn


def collect(conn: sqlite3.Connection, names: Sequence[str], days: int, limit: int) -> Dict[str, List[Row]]:
    cutoff = cutoff_iso(days)
    return {n: SECTIONS[n](conn, cutoff, limit) for n in names}


def render_text(data: Dict[str, List[Row]], days: int, rejects: Optional[int] = None) -> str:
    out: List[str] = []
    for name, rows in data.items():
        out.append(f'== {name} (last {days}d) ==')
        if name == 'safety':
            n = rows[0]['safety_events'] if rows else 0
            out.append(f'safety_events: {n}')
            if n == 0:
                out.append(SAFETY_NOTE + (f' Rejects in window: {rejects}.' if rejects is not None else ''))
        else:
            out.append(format_table(rows))
        out.append('')
    return '\n'.join(out).rstrip('\n') + '\n'


class _Parser(argparse.ArgumentParser):
    """Argument errors exit 1; with --json in argv they become {"error": ...} on stdout."""

    def __init__(self, *a: Any, argv: Sequence[str] = (), **kw: Any) -> None:
        super().__init__(*a, **kw)
        self._argv = list(argv)

    def error(self, message: str) -> Any:
        if any(a == '--json' or a.startswith('--json=') for a in self._argv):
            print(json.dumps({'error': message}))
            sys.exit(1)
        self.print_usage(sys.stderr)
        print(f'{self.prog}: error: {message}', file=sys.stderr)
        sys.exit(1)


def _bounded(name: str, hi: int) -> Callable[[str], int]:
    def conv(v: str) -> int:
        try:
            n = int(v)
        except ValueError:
            raise argparse.ArgumentTypeError(f'{name} must be an integer, got {v!r}')
        if not 1 <= n <= hi:
            raise argparse.ArgumentTypeError(f'{name} must be between 1 and {hi}, got {n}')
        return n
    return conv


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    ap = _Parser(description='Read-only report over otel_events.', argv=argv, allow_abbrev=False)
    ap.add_argument('--days', type=_bounded('--days', MAX_DAYS), default=DEFAULT_DAYS,
                    help=f'window in days, 1..{MAX_DAYS} (default {DEFAULT_DAYS})')
    ap.add_argument('--section', choices=SECTION_NAMES + ('all',), default='all')
    ap.add_argument('--limit', type=_bounded('--limit', MAX_LIMIT), default=DEFAULT_LIMIT,
                    help=f'max rows, 1..{MAX_LIMIT}; applies to the hooks and workflow sections only (default {DEFAULT_LIMIT})')
    ap.add_argument('--json', action='store_true', dest='as_json')
    args = ap.parse_args(argv)

    def fail(msg: str) -> int:
        if args.as_json:
            print(json.dumps({'error': msg}))
        else:
            print(f'cast-otel-report: {msg}', file=sys.stderr)
        return 1

    try:
        path = resolve_db_path()
        conn = open_ro(path)
    except (ValueError, OSError, LookupError, sqlite3.Error) as exc:
        return fail(str(exc))
    names = list(SECTION_NAMES) if args.section == 'all' else [args.section]
    try:
        data = collect(conn, names, args.days, args.limit)
        rejects = None
        if 'safety' in names and not args.as_json:
            td = data.get('tool_decision') or tool_decision(conn, cutoff_iso(args.days))
            rejects = reject_count(td)
    except sqlite3.Error as exc:
        return fail(f'sqlite error: {exc}')
    finally:
        conn.close()

    if args.as_json:
        print(json.dumps(data))
    else:
        sys.stdout.write(render_text(data, args.days, rejects))
    return 0


if __name__ == '__main__':
    sys.exit(main())
