#!/usr/bin/env python3
"""
cast-channel-server.py — CAST lightweight channel event bus.
Listens on port 9200. Accepts events from hook scripts, stores in a ring buffer
and cast.db, and streams them via Server-Sent Events.

Endpoints:
    POST /publish          Receive a JSON event
    GET  /events           Return last N events as JSON array (?limit=10)
    GET  /events/stream    SSE stream of new events
    GET  /health           Status and event count

Usage:
    python3 cast-channel-server.py [--port 9200]
    # or via cast-channel-start.sh for background daemon mode

Environment:
    CAST_DB_PATH    Override cast.db path (default: ~/.claude/cast.db)
    CAST_CHANNEL_PORT  Override port (default: 9200)
"""

import sys
import os
import json
import signal
import sqlite3
import uuid
import datetime
import threading
import argparse
from collections import deque
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
PORT = int(os.environ.get('CAST_CHANNEL_PORT', '9200'))
RING_BUFFER_SIZE = 100

_ring_buffer = deque(maxlen=RING_BUFFER_SIZE)
_sse_clients = []
_sse_lock = threading.Lock()
_event_count = 0
_event_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def _db_connect():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_stream_tables():
    try:
        with _db_connect() as conn:
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
                CREATE INDEX IF NOT EXISTS idx_stream_events_session
                    ON stream_events(session_id);
            """)
    except Exception as e:
        print(f"[cast-channel-server] DB init warning: {e}", file=sys.stderr)


def _write_to_db(event: dict):
    try:
        with _db_connect() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO stream_events
                   (id, session_id, timestamp, event_type, tool_name, tool_input_preview, status, duration_ms, raw_json)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    event.get('id', str(uuid.uuid4())),
                    event.get('session_id', ''),
                    event.get('timestamp', datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')),
                    event.get('event_type', event.get('type', '')),
                    event.get('tool_name', ''),
                    json.dumps(event.get('data', ''))[:200],
                    event.get('status', ''),
                    event.get('duration_ms'),
                    json.dumps(event)[:2000],
                )
            )
            conn.commit()
    except Exception as e:
        print(f"[cast-channel-server] DB write error: {e}", file=sys.stderr)


# ---------------------------------------------------------------------------
# SSE helpers
# ---------------------------------------------------------------------------

def _broadcast_sse(event: dict):
    data = f"data: {json.dumps(event)}\n\n"
    with _sse_lock:
        dead = []
        for client in _sse_clients:
            try:
                client.wfile.write(data.encode())
                client.wfile.flush()
            except Exception:
                dead.append(client)
        for d in dead:
            _sse_clients.remove(d)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class ChannelHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default access log

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        global _event_count
        if self.path != '/publish':
            self._send_json({'error': 'not found'}, 404)
            return

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
            event = json.loads(body)
        except json.JSONDecodeError:
            self._send_json({'error': 'invalid JSON'}, 400)
            return

        # Stamp with id and timestamp if missing
        event.setdefault('id', str(uuid.uuid4()))
        event.setdefault('timestamp', datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))

        _ring_buffer.append(event)
        with _event_lock:
            _event_count += 1

        _write_to_db(event)
        _broadcast_sse(event)

        self._send_json({'ok': True, 'id': event['id']})

    def do_GET(self):
        if self.path == '/health':
            self._send_json({
                'status': 'ok',
                'event_count': _event_count,
                'sse_clients': len(_sse_clients),
                'port': PORT,
            })
        elif self.path.startswith('/events/stream'):
            self._handle_sse()
        elif self.path.startswith('/events'):
            limit = 10
            if '?limit=' in self.path:
                try:
                    limit = int(self.path.split('?limit=')[1])
                except ValueError:
                    pass
            events = list(_ring_buffer)[-limit:]
            self._send_json(events)
        else:
            self._send_json({'error': 'not found'}, 404)

    def _handle_sse(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        # Send last 5 events as catch-up
        for event in list(_ring_buffer)[-5:]:
            data = f"data: {json.dumps(event)}\n\n"
            self.wfile.write(data.encode())
        try:
            self.wfile.flush()
        except Exception:
            return

        with _sse_lock:
            _sse_clients.append(self)

        # Keep connection alive — it stays open until client disconnects
        try:
            while True:
                import time
                time.sleep(15)
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        except Exception:
            with _sse_lock:
                if self in _sse_clients:
                    _sse_clients.remove(self)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _shutdown(signum=None, frame=None):
    print(f"\n[cast-channel-server] Shutting down. Events served: {_event_count}", file=sys.stderr)
    sys.exit(0)


signal.signal(signal.SIGINT, _shutdown)
signal.signal(signal.SIGTERM, _shutdown)


def main():
    global PORT
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=PORT)
    args = parser.parse_args()
    PORT = args.port

    _ensure_stream_tables()

    server = HTTPServer(('127.0.0.1', PORT), ChannelHandler)
    server.daemon_threads = True
    print(f"[cast-channel-server] Listening on http://127.0.0.1:{PORT}", file=sys.stderr)

    server.serve_forever()


if __name__ == '__main__':
    main()
