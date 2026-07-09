#!/usr/bin/env python3
"""
cast-otel-collector.py — CAST local OpenTelemetry receiver (stdlib only).

Sinks Claude Code native OTLP/JSON (metrics + events/logs) into cast.db
tables otel_metrics and otel_events.

BIND: 127.0.0.1 ONLY (local-first, non-negotiable).
PORT: CAST_OTEL_PORT env var (default 4318).

DB ACCESS DECISION (documented per task spec):
  Uses cast_db.db_execute() (raw parameterized SQL) rather than cast_db.db_write()
  because otel_metrics/otel_events are NOT in cast_db.ALLOWED_TABLES —
  db_write() enforces the allowlist and would raise ValueError.  cast_db.py is
  import-clean (no module-level side effects beyond defining functions), so
  importing it in a long-running daemon is safe.  Falls back to direct sqlite3
  (same parameterized-query contract) if cast_db is absent or import fails.

SESSION.ID EXTRACTION:
  OTLP attributes are [{key, value: {stringValue|intValue|...}}] lists.
  For metrics: resource-level attributes from ResourceMetrics.resource.attributes
  are merged with per-datapoint attributes; "session.id" is pulled from the merged
  dict (datapoint attrs take precedence over resource attrs).
  For logs: same pattern — ResourceLogs.resource.attributes merged with
  per-logRecord attributes; "session.id" from the merged dict.

GZIP:
  OTLP exporters commonly send Content-Encoding: gzip.  The HTTP handler
  decompresses before passing to ingest_bytes(already_decompressed=True) to
  avoid a second decompress pass (~320 MiB peak at cap).  ingest_bytes() also
  auto-detects gzip by magic bytes (\x1f\x8b) when already_decompressed=False,
  so the offline modes (--ingest-file / --ingest-stdin) handle .json.gz files
  transparently.

FAIL-OPEN:
  Any parse or DB error is logged to ~/.claude/logs/otel-collector.log and
  the handler still returns HTTP 200 {}.  The server never crashes and never
  5xx-backpressures Claude Code.

Usage:
  cast-otel-collector.py [--serve]          # default: start HTTP daemon
  cast-otel-collector.py --ingest-file PATH # offline: parse file, write DB, print counts
  cast-otel-collector.py --ingest-stdin     # offline: read from stdin
"""

import sys
import os
import json
import gzip
import sqlite3
import traceback
import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# sys.path — allow `import cast_db` when invoked from any working directory
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

try:
    import cast_db as _cast_db  # type: ignore
    _USE_CAST_DB: bool = True
except (ImportError, Exception):
    _cast_db = None  # type: ignore
    _USE_CAST_DB = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MAX_BODY_BYTES: int = 16 * 1024 * 1024       # 16 MiB compressed cap
MAX_DECOMPRESSED_BYTES: int = MAX_BODY_BYTES * 10  # 160 MiB gzip-bomb guard
DEFAULT_PORT: int = 4318
BIND_HOST: str = '127.0.0.1'                 # local-only bind, enforced at server level
REQUEST_TIMEOUT_SEC: int = 30                # socket timeout for slow/stalled senders


# ---------------------------------------------------------------------------
# Logging — fail-safe file appender, never raises
# ---------------------------------------------------------------------------
def _log(msg: str, level: str = 'INFO') -> None:
    """Append a timestamped entry to ~/.claude/logs/otel-collector.log."""
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'otel-collector.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(str(log_path), 'a') as fh:
            fh.write(f'[{ts}] {level} cast-otel-collector: {msg}\n')
    except Exception:
        pass  # Never crash — logging failure is silent


# TEMP DIAGNOSTIC — remove after root-cause
def _log_diag(msg: str) -> None:
    """Append a timestamped entry to ~/.claude/logs/otel-debug.log.

    TEMP DIAGNOSTIC — remove after root-cause. Deliberately a SEPARATE file
    from otel-collector.log so it's trivial to delete/ignore and never
    pollutes production logs permanently. Never raises.
    """
    try:
        log_path = Path.home() / '.claude' / 'logs' / 'otel-debug.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(str(log_path), 'a') as fh:
            fh.write(f'[{ts}] DIAG cast-otel-collector: {msg}\n')
    except Exception:
        pass  # Never crash — logging failure is silent


# ---------------------------------------------------------------------------
# Database — parameterized writes, no string interpolation of user data
# ---------------------------------------------------------------------------
def _db_execute(sql: str, params: tuple) -> bool:
    """Execute a parameterized SQL statement against cast.db.

    Prefers cast_db.db_execute() (handles WAL, busy-timeout, path validation,
    retry).  Falls back to direct sqlite3 when cast_db is unavailable.
    Returns True on success, False on any failure.  Never raises.
    """
    if _USE_CAST_DB and _cast_db is not None:
        try:
            return bool(_cast_db.db_execute(sql, params))
        except Exception as e:
            _log(f'cast_db.db_execute error (falling back to sqlite3): {e}')
            # Fall through to direct sqlite3 below

    # Direct sqlite3 fallback — same parameterized contract
    db_path = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
    try:
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(db_path, timeout=5) as conn:
            conn.execute('PRAGMA journal_mode=WAL;')
            conn.execute(sql, params)
            conn.commit()
        return True
    except Exception as e:
        _log(f'sqlite3 db_execute failed: {e}')
        return False


# ---------------------------------------------------------------------------
# OTLP attribute helpers
# ---------------------------------------------------------------------------
def _attrs_to_dict(attrs: list) -> dict:
    """Convert an OTLP [{key, value: {…}}] attribute list to a Python dict.

    OTLP proto3 JSON encodes int64 values (intValue, timeUnixNano) as strings;
    we coerce to int when possible, keeping the raw value otherwise.
    """
    result: dict = {}
    for attr in attrs:
        key: str = attr.get('key', '')
        val: dict = attr.get('value', {})
        if 'stringValue' in val:
            result[key] = val['stringValue']
        elif 'intValue' in val:
            raw = val['intValue']
            try:
                result[key] = int(raw)
            except (ValueError, TypeError):
                result[key] = raw
        elif 'doubleValue' in val:
            try:
                result[key] = float(val['doubleValue'])
            except (ValueError, TypeError):
                result[key] = val['doubleValue']
        elif 'boolValue' in val:
            result[key] = bool(val['boolValue'])
        elif 'bytesValue' in val:
            result[key] = val['bytesValue']
        else:
            result[key] = None
    return result


# ---------------------------------------------------------------------------
# OTLP metric parsing
# ---------------------------------------------------------------------------
def _parse_metrics(payload: dict) -> list:
    """Parse OTLP/JSON resourceMetrics into a list of otel_metrics row dicts.

    Handles gauge and sum dataPoints.  int64 fields (asInt, timeUnixNano)
    arrive as strings in proto3 JSON — coerced defensively.
    """
    rows: list = []
    for rm in payload.get('resourceMetrics', []):
        resource_attrs: dict = _attrs_to_dict(
            rm.get('resource', {}).get('attributes', [])
        )
        for sm in rm.get('scopeMetrics', []):
            for metric in sm.get('metrics', []):
                name: str = metric.get('name', '')
                unit: str = metric.get('unit', '')
                # dataPoints from gauge or sum (prefer gauge; fall through to sum)
                data_points: list = (
                    metric.get('gauge', {}).get('dataPoints') or
                    metric.get('sum', {}).get('dataPoints') or
                    []
                )
                for dp in data_points:
                    dp_attrs: dict = _attrs_to_dict(dp.get('attributes', []))
                    # Merge: resource attrs as baseline, datapoint attrs override
                    merged: dict = {**resource_attrs, **dp_attrs}
                    # session.id: prefer datapoint attr, fall back to resource attr
                    session_id: Optional[str] = dp_attrs.get(
                        'session.id', resource_attrs.get('session.id')
                    )
                    # Value: asDouble > asInt (int64 encoded as string in proto3 JSON)
                    value: Optional[float] = None
                    if 'asDouble' in dp:
                        try:
                            value = float(dp['asDouble'])
                        except (ValueError, TypeError):
                            value = None
                    elif 'asInt' in dp:
                        try:
                            value = float(int(dp['asInt']))
                        except (ValueError, TypeError):
                            value = None
                    # timeUnixNano arrives as string in proto3 JSON
                    try:
                        time_unix_nano: int = int(dp.get('timeUnixNano') or 0)
                    except (ValueError, TypeError):
                        time_unix_nano = 0
                    rows.append({
                        'session_id': session_id,
                        'metric_name': name,
                        'value': value,
                        'unit': unit,
                        'attributes': json.dumps(merged),
                        'time_unix_nano': time_unix_nano,
                    })
    return rows


# ---------------------------------------------------------------------------
# OTLP log/event parsing
# ---------------------------------------------------------------------------
def _parse_logs(payload: dict) -> list:
    """Parse OTLP/JSON resourceLogs into a list of otel_events row dicts.

    Extracts event.name and prompt.id from per-record attributes.
    int64 timeUnixNano arrives as a string — coerced defensively.
    """
    rows: list = []
    for rl in payload.get('resourceLogs', []):
        resource_attrs: dict = _attrs_to_dict(
            rl.get('resource', {}).get('attributes', [])
        )
        for sl in rl.get('scopeLogs', []):
            for lr in sl.get('logRecords', []):
                lr_attrs: dict = _attrs_to_dict(lr.get('attributes', []))
                # Merge: resource attrs as baseline, logRecord attrs override
                merged: dict = {**resource_attrs, **lr_attrs}
                # session.id: prefer logRecord, fall back to resource
                session_id: Optional[str] = lr_attrs.get(
                    'session.id', resource_attrs.get('session.id')
                )
                event_name: Optional[str] = lr_attrs.get('event.name')
                prompt_id: Optional[str] = lr_attrs.get('prompt.id')
                # body: use stringValue when present, otherwise serialize struct
                body_raw = lr.get('body', {})
                if isinstance(body_raw, dict) and 'stringValue' in body_raw:
                    body_str: str = body_raw['stringValue']
                else:
                    body_str = json.dumps(body_raw)
                # Store body text + merged attributes as a JSON blob
                body_obj: dict = {'message': body_str, 'attributes': merged}
                # timeUnixNano arrives as string in proto3 JSON
                try:
                    time_unix_nano: int = int(lr.get('timeUnixNano') or 0)
                except (ValueError, TypeError):
                    time_unix_nano = 0
                rows.append({
                    'session_id': session_id,
                    'event_name': event_name,
                    'prompt_id': prompt_id,
                    'severity': lr.get('severityText'),
                    'body': json.dumps(body_obj),
                    'time_unix_nano': time_unix_nano,
                })
    return rows


# ---------------------------------------------------------------------------
# DB insertion helpers
# ---------------------------------------------------------------------------
def _insert_metrics(rows: list) -> int:
    """Insert otel_metrics rows. Returns count of successfully inserted rows."""
    count = 0
    for row in rows:
        ok = _db_execute(
            'INSERT INTO otel_metrics (session_id, metric_name, value, unit, attributes, time_unix_nano) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (
                row['session_id'], row['metric_name'], row['value'],
                row['unit'], row['attributes'], row['time_unix_nano'],
            ),
        )
        if ok:
            count += 1
    return count


def _insert_events(rows: list) -> int:
    """Insert otel_events rows. Returns count of successfully inserted rows."""
    count = 0
    for row in rows:
        ok = _db_execute(
            'INSERT INTO otel_events (session_id, event_name, prompt_id, severity, body, time_unix_nano) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (
                row['session_id'], row['event_name'], row['prompt_id'],
                row['severity'], row['body'], row['time_unix_nano'],
            ),
        )
        if ok:
            count += 1
    return count


# ---------------------------------------------------------------------------
# Signal processors (parse + insert; fail-open)
# ---------------------------------------------------------------------------
def _process_metrics(payload: dict) -> int:
    """Parse and insert OTLP metrics. Returns row count. Never raises."""
    try:
        rows = _parse_metrics(payload)
        return _insert_metrics(rows)
    except Exception as e:
        _log(f'Error processing metrics: {e}\n{traceback.format_exc()}')
        return 0


def _process_logs(payload: dict) -> int:
    """Parse and insert OTLP logs/events. Returns row count. Never raises."""
    try:
        rows = _parse_logs(payload)
        return _insert_events(rows)
    except Exception as e:
        _log(f'Error processing logs: {e}\n{traceback.format_exc()}')
        return 0


# ---------------------------------------------------------------------------
# Bytes-level ingest (shared by HTTP handler and offline modes)
# ---------------------------------------------------------------------------
def ingest_bytes(raw: bytes, already_decompressed: bool = False) -> tuple:
    """Decompress (if gzip), parse OTLP JSON, and insert into cast.db.

    Returns (metrics_count, events_count).  Fail-open: returns (0, 0) on
    any parse or DB error — never raises.

    Args:
        raw: Raw bytes from HTTP body or file.
        already_decompressed: When True, skip magic-byte gzip auto-detect.
            Set by do_POST after header-driven (Content-Encoding: gzip)
            decompression to avoid a second decompress pass and the associated
            peak-memory doubling (~320 MiB at cap).  Offline callers
            (--ingest-file *.json.gz, --ingest-stdin) leave this False so
            the auto-detect handles .json.gz files transparently.

    Auto-detects gzip by magic bytes (\\x1f\\x8b) when already_decompressed is
    False; this handles offline .json.gz files read via --ingest-file /
    --ingest-stdin.
    """
    # Auto-detect gzip by magic bytes — skip when caller already decompressed
    if not already_decompressed and len(raw) >= 2 and raw[:2] == b'\x1f\x8b':
        try:
            decompressed = gzip.decompress(raw)
        except Exception as e:
            _log(f'gzip decompress failed: {e}')
            return (0, 0)
        if len(decompressed) > MAX_DECOMPRESSED_BYTES:
            _log(
                f'Decompressed payload ({len(decompressed)} bytes) exceeds '
                f'{MAX_DECOMPRESSED_BYTES} byte limit — rejecting'
            )
            return (0, 0)
        raw = decompressed

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        _log(f'JSON parse error: {e}')
        return (0, 0)

    if not isinstance(payload, dict):
        _log(f'Expected OTLP JSON object, got {type(payload).__name__}')
        return (0, 0)

    metrics_count = 0
    events_count = 0

    if 'resourceMetrics' in payload:
        metrics_count = _process_metrics(payload)

    if 'resourceLogs' in payload:
        events_count = _process_logs(payload)

    # resourceSpans (/v1/traces) — silently ignored (beta deferred)

    return (metrics_count, events_count)


# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------
class ChunkedBodyError(Exception):
    """Raised when a Transfer-Encoding: chunked body is malformed or oversized."""


def _read_chunked_body(rfile: Any, max_bytes: int) -> bytes:
    """De-chunk an HTTP/1.1 `Transfer-Encoding: chunked` request body.

    http.server (BaseHTTPRequestHandler) does NOT auto-dechunk request
    bodies — it only exposes the raw socket via self.rfile.  Without this,
    do_POST would hand raw chunk-framing bytes (hex chunk-size + CRLF +
    chunk-data + CRLF + ... + "0\\r\\n\\r\\n") straight to json.loads(),
    which fails immediately (root cause of the silent-telemetry-loss bug:
    "JSON parse error: Expecting value... char 0" / "Extra data... char 1-7"
    matches variable-length hex chunk-size lines being misparsed as JSON).

    Enforces max_bytes (MAX_BODY_BYTES) across the reassembled body so a
    malicious/malformed chunked sender cannot bypass the existing size cap.
    Also caps the number of chunks and the hex chunk-size line length so a
    malformed size line (missing CRLF, garbage) cannot spin an unbounded
    read loop.

    Raises ChunkedBodyError on any framing violation or size overrun.
    """
    body = bytearray()
    max_chunks = 100_000  # generous; guards against a malformed infinite stream
    for _ in range(max_chunks):
        # Read the chunk-size line (hex digits, optional ;extensions, CRLF).
        # Bound the line length so a sender that never sends CRLF can't hang
        # rfile.readline() forever accumulating memory.
        size_line: bytes = rfile.readline(64)
        if not size_line:
            raise ChunkedBodyError('unexpected EOF reading chunk size')
        if not size_line.endswith(b'\n'):
            raise ChunkedBodyError('chunk size line too long or unterminated')
        size_field = size_line.split(b';', 1)[0].strip()
        try:
            chunk_size = int(size_field, 16)
        except ValueError:
            raise ChunkedBodyError(f'invalid chunk size line: {size_field!r}')
        if chunk_size < 0:
            raise ChunkedBodyError(f'negative chunk size: {chunk_size}')
        if chunk_size == 0:
            # Final chunk — consume trailing headers (if any) up to blank line.
            while True:
                trailer = rfile.readline(1024)
                if not trailer or trailer in (b'\r\n', b'\n'):
                    break
            return bytes(body)
        if len(body) + chunk_size > max_bytes:
            raise ChunkedBodyError(
                f'chunked body exceeds {max_bytes} byte limit'
            )
        chunk_data = rfile.read(chunk_size)
        if len(chunk_data) != chunk_size:
            raise ChunkedBodyError('unexpected EOF reading chunk data')
        body.extend(chunk_data)
        trailing_crlf = rfile.read(2)
        if trailing_crlf != b'\r\n':
            raise ChunkedBodyError('missing CRLF after chunk data')
    raise ChunkedBodyError('too many chunks — possible malformed stream')


class OTLPHandler(BaseHTTPRequestHandler):
    """OTLP/HTTP receiver.  Server is bound to 127.0.0.1 ONLY."""

    # Bound rfile reads to REQUEST_TIMEOUT_SEC; http.server honors handler.timeout.
    timeout = REQUEST_TIMEOUT_SEC

    def do_POST(self) -> None:
        """Handle POST /v1/metrics, /v1/logs, /v1/traces."""
        # TEMP DIAGNOSTIC — remove after root-cause.
        # Pure observation: logs headers/request-line/raw-body-prefix to a
        # SEPARATE file (otel-debug.log) before any parsing is attempted.
        # Must not alter parsing/response behavior.
        try:
            _headers_dump = '; '.join(f'{k}={v!r}' for k, v in self.headers.items())
            _log_diag(
                f'command={self.command!r} path={self.path!r} '
                f'request_version={self.request_version!r} '
                f'Transfer-Encoding={self.headers.get("Transfer-Encoding")!r} '
                f'Content-Length={self.headers.get("Content-Length")!r} '
                f'Content-Encoding={self.headers.get("Content-Encoding")!r} '
                f'Content-Type={self.headers.get("Content-Type")!r} '
                f'all_headers=[{_headers_dump}]'
            )
        except Exception as _diag_e:
            _log_diag(f'header dump failed: {_diag_e}')

        transfer_encoding: str = self.headers.get('Transfer-Encoding', '')
        is_chunked: bool = 'chunked' in transfer_encoding.lower()

        if is_chunked:
            # http.server does not auto-dechunk; de-chunk manually.
            try:
                raw_body: bytes = _read_chunked_body(self.rfile, MAX_BODY_BYTES)
            except ChunkedBodyError as e:
                _log(f'Chunked body error on {self.path}: {e}')
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{}')
                return
        else:
            content_length_str: str = self.headers.get('Content-Length', '0')
            try:
                content_length: int = int(content_length_str)
            except (ValueError, TypeError):
                content_length = 0

            # Reject oversized compressed body early
            if content_length > MAX_BODY_BYTES:
                self.send_response(413)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{}')
                return

            # Read body
            if content_length > 0:
                raw_body = self.rfile.read(content_length)
            else:
                # No Content-Length — read up to cap + 1 to detect oversized body
                raw_body = self.rfile.read(MAX_BODY_BYTES + 1)
                if len(raw_body) > MAX_BODY_BYTES:
                    self.send_response(413)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(b'{}')
                    return

        # TEMP DIAGNOSTIC — remove after root-cause.
        # Log the raw body prefix (binary-safe repr) BEFORE any decompression
        # or JSON parsing is attempted. Pure observation only.
        try:
            _log_diag(
                f'path={self.path!r} is_chunked={is_chunked} '
                f'raw_body_len={len(raw_body)} '
                f'raw_body_prefix80={raw_body[:80]!r}'
            )
        except Exception as _diag_e:
            _log_diag(f'raw body dump failed: {_diag_e}')

        # Decompress when Content-Encoding: gzip is set.
        # Track whether we decompressed here so ingest_bytes() can skip its
        # own magic-byte check — preventing a second decompress pass and the
        # associated peak-memory doubling (~320 MiB at cap).
        encoding: str = self.headers.get('Content-Encoding', '')
        header_decompressed: bool = False
        if encoding.lower() == 'gzip':
            try:
                decompressed = gzip.decompress(raw_body)
            except Exception as e:
                _log(f'gzip decompress failed on {self.path}: {e}')
                self._send_ok()
                return
            if len(decompressed) > MAX_DECOMPRESSED_BYTES:
                _log(
                    f'Decompressed body ({len(decompressed)} bytes) exceeds limit on {self.path}'
                )
                self.send_response(413)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{}')
                return
            raw_body = decompressed
            header_decompressed = True

        # Route and process (fail-open: errors handled inside ingest_bytes).
        # Pass already_decompressed=True when we header-gunzipped above so
        # ingest_bytes() skips its magic-byte re-detect.
        if self.path in ('/v1/metrics', '/v1/logs', '/v1/traces'):
            ingest_bytes(raw_body, already_decompressed=header_decompressed)
        else:
            _log(f'Unknown OTLP endpoint: {self.path}')

        self._send_ok()

    def _send_ok(self) -> None:
        """Return HTTP 200 with empty JSON object."""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')

    def log_message(self, format: str, *args: Any) -> None:
        """Suppress default HTTP access logging to stderr."""
        pass


# ---------------------------------------------------------------------------
# Daemon mode
# ---------------------------------------------------------------------------
def serve() -> None:
    """Start the OTLP HTTP receiver on BIND_HOST:CAST_OTEL_PORT.  Blocks.

    Exit contract (launchd KeepAlive=true compatibility):
      - Exits 0:  clean shutdown via KeyboardInterrupt/SIGTERM.
      - Exits 1:  unrecoverable startup error (e.g. EADDRINUSE); logged
                  clearly to both otel-collector.log and stderr so launchd
                  ThrottleInterval throttles the restart loop rather than
                  spinning silently.
      - Per-request exceptions never reach this function — do_POST is
        fail-open and BaseHTTPServer routes handler errors to handle_error().
    """
    port: int = int(os.environ.get('CAST_OTEL_PORT', DEFAULT_PORT))

    # Bind — raise early with a clear message on EADDRINUSE or other OS errors
    try:
        server = HTTPServer((BIND_HOST, port), OTLPHandler)
    except OSError as e:
        msg = (
            f'Cannot bind {BIND_HOST}:{port} — {e} '
            f'(port {port} already in use?)'
        )
        _log(msg, level='ERROR')
        print(f'cast-otel-collector: {msg}', file=sys.stderr)
        sys.exit(1)

    _log(
        f'Listening on {BIND_HOST}:{port} '
        f'(db: {os.environ.get("CAST_DB_PATH", "~/.claude/cast.db")}, '
        f'cast_db={_USE_CAST_DB})'
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        # SIGINT or SIGTERM via launchd stop — clean shutdown, exit 0
        _log('Shutting down (SIGINT/SIGTERM)')
    finally:
        server.server_close()


# ---------------------------------------------------------------------------
# Offline ingest modes (for BATS tests and manual inspection)
# ---------------------------------------------------------------------------
def ingest_file(file_path: str) -> tuple:
    """Read an OTLP file (plain JSON or gzip) and ingest into cast.db.

    Returns (metrics_count, events_count).
    """
    try:
        with open(file_path, 'rb') as fh:
            raw: bytes = fh.read()
        return ingest_bytes(raw)
    except OSError as e:
        _log(f'Cannot read file {file_path}: {e}')
        return (0, 0)


def ingest_stdin() -> tuple:
    """Read OTLP JSON from stdin (binary) and ingest into cast.db.

    Returns (metrics_count, events_count).
    """
    try:
        raw: bytes = sys.stdin.buffer.read()
        return ingest_bytes(raw)
    except Exception as e:
        _log(f'Error reading stdin: {e}')
        return (0, 0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] == '--serve':
        serve()
    elif args[0] == '--ingest-file':
        if len(args) < 2:
            print('Usage: cast-otel-collector.py --ingest-file <path>', file=sys.stderr)
            sys.exit(1)
        m, e = ingest_file(args[1])
        print(f'metrics={m} events={e}')
        sys.exit(0)
    elif args[0] == '--ingest-stdin':
        m, e = ingest_stdin()
        print(f'metrics={m} events={e}')
        sys.exit(0)
    else:
        print(f'Unknown argument: {args[0]}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
