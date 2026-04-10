#!/usr/bin/env python3
"""
cast-stream-consumer.py — CAST stream-JSON observability consumer.
Reads newline-delimited JSON from stdin (claude --output-format stream-json)
and writes events to cast.db stream_events and stream_hook_events tables.

Usage:
    claude -p "..." --output-format stream-json --include-hook-events \
        | python3 cast-stream-consumer.py

Environment:
    CAST_DB_PATH    Override cast.db path (default: ~/.claude/cast.db)
    CLAUDE_SESSION_ID  Session ID to tag events with
"""

import sys
import json
import os
import signal
import sqlite3
import uuid
import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
SESSION_ID = os.environ.get('CLAUDE_SESSION_ID', f"stream-{datetime.datetime.utcnow().strftime('%Y%m%d%H%M%S')}")

_count_events = 0
_count_errors = 0
_conn = None


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def _connect():
    global _conn
    if _conn is not None:
        return _conn
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    _conn = sqlite3.connect(DB_PATH, timeout=5)
    _ensure_tables(_conn)
    return _conn


def _ensure_tables(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS stream_events (
            id                  TEXT PRIMARY KEY,
            session_id          TEXT,
            timestamp           TEXT,
            event_type          TEXT,
            tool_name           TEXT,
            tool_input_preview  TEXT,
            status              TEXT,
            duration_ms         INTEGER,
            raw_json            TEXT
        );

        CREATE TABLE IF NOT EXISTS stream_hook_events (
            id          TEXT PRIMARY KEY,
            session_id  TEXT,
            timestamp   TEXT,
            hook_type   TEXT,
            tool_name   TEXT,
            result      TEXT,
            duration_ms INTEGER,
            output      TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_stream_events_session
            ON stream_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_stream_events_timestamp
            ON stream_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_stream_hook_events_session
            ON stream_hook_events(session_id);
    """)
    conn.commit()


def _now_iso():
    return datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


# ---------------------------------------------------------------------------
# Event routing
# ---------------------------------------------------------------------------

def _handle_tool_use(conn, event, raw):
    """Route tool_use events to stream_events."""
    tool_input = event.get('input', {})
    tool_input_str = json.dumps(tool_input)[:200] if tool_input else ''
    conn.execute(
        """INSERT OR REPLACE INTO stream_events
           (id, session_id, timestamp, event_type, tool_name, tool_input_preview, status, duration_ms, raw_json)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            event.get('id', str(uuid.uuid4())),
            SESSION_ID,
            _now_iso(),
            'tool_use',
            event.get('name', ''),
            tool_input_str,
            None,
            None,
            raw[:2000],
        )
    )
    conn.commit()


def _handle_tool_result(conn, event, raw):
    """Route tool_result events to stream_events."""
    content = event.get('content', '')
    if isinstance(content, list):
        content = json.dumps(content)
    conn.execute(
        """INSERT OR REPLACE INTO stream_events
           (id, session_id, timestamp, event_type, tool_name, tool_input_preview, status, duration_ms, raw_json)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            str(uuid.uuid4()),
            SESSION_ID,
            _now_iso(),
            'tool_result',
            event.get('tool_use_id', ''),
            str(content)[:200],
            None,
            None,
            raw[:2000],
        )
    )
    conn.commit()


def _handle_hook_event(conn, event, raw):
    """Route hook_event entries to stream_hook_events."""
    conn.execute(
        """INSERT OR REPLACE INTO stream_hook_events
           (id, session_id, timestamp, hook_type, tool_name, result, duration_ms, output)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            str(uuid.uuid4()),
            SESSION_ID,
            _now_iso(),
            event.get('hook_type', ''),
            event.get('tool_name', ''),
            event.get('result', ''),
            event.get('duration_ms'),
            str(event.get('output', ''))[:500],
        )
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------

def _shutdown(signum=None, frame=None):
    global _conn
    if _conn:
        try:
            _conn.close()
        except Exception:
            pass
    print(
        f"\n[cast-stream-consumer] Session {SESSION_ID} complete — "
        f"{_count_events} events, {_count_errors} errors",
        file=sys.stderr,
    )
    sys.exit(0)


signal.signal(signal.SIGINT, _shutdown)
signal.signal(signal.SIGTERM, _shutdown)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    global _count_events, _count_errors

    conn = _connect()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            _count_errors += 1
            preview = line[:120] + ('...' if len(line) > 120 else '')
            print(f"[cast-stream-consumer] malformed JSON (line {_count_events + _count_errors}): {preview}", file=sys.stderr)
            continue

        event_type = event.get('type', '')
        try:
            if event_type == 'tool_use':
                _handle_tool_use(conn, event, line)
                _count_events += 1
            elif event_type == 'tool_result':
                _handle_tool_result(conn, event, line)
                _count_events += 1
            elif event_type == 'hook_event':
                _handle_hook_event(conn, event, line)
                _count_events += 1
            # other types (assistant, system, etc.) are passed through silently
        except Exception as e:
            _count_errors += 1
            print(f"[cast-stream-consumer] error on {event_type}: {e}", file=sys.stderr)

    _shutdown()


if __name__ == '__main__':
    main()
