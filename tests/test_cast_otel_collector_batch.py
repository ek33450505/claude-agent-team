"""Batch-insert tests for scripts/cast-otel-collector.py (_insert_events/_insert_metrics)."""
import importlib.util
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = """
CREATE TABLE otel_metrics (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, metric_name TEXT NOT NULL,
  value REAL, unit TEXT, attributes TEXT, time_unix_nano INTEGER, received_at TEXT);
CREATE TABLE otel_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_name TEXT,
  prompt_id TEXT, severity TEXT, body TEXT, time_unix_nano INTEGER, received_at TEXT);
"""


def _event(i):
    return {'session_id': 's', 'event_name': f'e{i}', 'prompt_id': None,
            'severity': 'INFO', 'body': '{}', 'time_unix_nano': i}


def _metric(i, name=None):
    return {'session_id': 's', 'metric_name': name if name is not None else f'm{i}',
            'value': 1.0, 'unit': 'n', 'attributes': '{}', 'time_unix_nano': i}


class BatchInsertTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = os.path.join(self.tmp.name, 'cast.db')
        conn = sqlite3.connect(self.db)
        conn.executescript(SCHEMA)
        conn.close()
        self._orig_home = os.environ.get('HOME')
        self._orig_db_path = os.environ.get('CAST_DB_PATH')
        os.environ['HOME'] = self.tmp.name  # keep _log off the live ~/.claude/logs
        os.environ['CAST_DB_PATH'] = self.db
        spec = importlib.util.spec_from_file_location(
            'cast_otel_collector', ROOT / 'scripts' / 'cast-otel-collector.py')
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def tearDown(self):
        if self._orig_home is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self._orig_home
        if self._orig_db_path is None:
            os.environ.pop('CAST_DB_PATH', None)
        else:
            os.environ['CAST_DB_PATH'] = self._orig_db_path

    def _count(self, table):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]
        finally:
            conn.close()

    def test_events_batch_all_land(self):
        self.assertEqual(self.mod._insert_events([_event(i) for i in range(250)]), 250)
        self.assertEqual(self._count('otel_events'), 250)

    def test_metrics_batch_all_land(self):
        self.assertEqual(self.mod._insert_metrics([_metric(i) for i in range(250)]), 250)
        self.assertEqual(self._count('otel_metrics'), 250)

    def test_empty_batch(self):
        self.assertEqual(self.mod._insert_events([]), 0)

    def test_batch_uses_single_connection(self):
        calls = []
        orig = self.mod._open_batch_conn
        self.mod._open_batch_conn = lambda: (calls.append(1), orig())[1]
        self.mod._insert_events([_event(i) for i in range(20)])
        self.assertEqual(len(calls), 1)

    def test_malformed_metric_row_does_not_lose_batch(self):
        rows = [_metric(1), _metric(2), _metric(3)]
        rows[1]['metric_name'] = None  # NOT NULL violation
        self.assertEqual(self.mod._insert_metrics(rows), 2)
        self.assertEqual(self._count('otel_metrics'), 2)

    def test_malformed_event_row_missing_key_does_not_lose_batch(self):
        rows = [_event(1), {'session_id': 's'}, _event(3)]
        self.assertEqual(self.mod._insert_events(rows), 2)
        self.assertEqual(self._count('otel_events'), 2)

    def _patch_conn(self, fail_times):
        """Make _open_batch_conn return a conn whose executemany raises 'locked' fail_times times."""
        orig = self.mod._open_batch_conn
        state = {'n': 0, 'opens': 0}

        class FlakyConn:
            def __init__(self, real):
                self._real = real

            def executemany(self, *a):
                if state['n'] < fail_times:
                    state['n'] += 1
                    raise sqlite3.OperationalError('database is locked')
                return self._real.executemany(*a)

            def __getattr__(self, name):
                return getattr(self._real, name)

            def __enter__(self):
                return self._real.__enter__() and self

            def __exit__(self, *a):
                return self._real.__exit__(*a)

        def opener():
            state['opens'] += 1
            return FlakyConn(orig())

        self.mod._open_batch_conn = opener
        self.addCleanup(setattr, self.mod.time, 'sleep', self.mod.time.sleep)
        self.mod.time.sleep = lambda s: None
        self.addCleanup(setattr, self.mod, '_open_batch_conn', orig)
        return state

    def test_locked_twice_no_per_row_fallback_raises_batchlocked(self):
        state = self._patch_conn(fail_times=2)
        per_row = []
        self.mod._db_execute = lambda *a, **k: per_row.append(1) or True
        logs = []
        self.mod._log = lambda msg, level='INFO': logs.append((level, msg))
        with self.assertRaises(self.mod.BatchLocked):
            self.mod._insert_events([_event(i) for i in range(5)])
        self.assertEqual(per_row, [])
        self.assertEqual(state['opens'], 2)
        self.assertTrue(any('locked twice' in m for _, m in logs))
        self.assertEqual(self._count('otel_events'), 0)

    def test_locked_once_then_succeeds_lands_all(self):
        state = self._patch_conn(fail_times=1)
        self.assertEqual(self.mod._insert_events([_event(i) for i in range(5)]), 5)
        self.assertEqual(state['opens'], 2)
        self.assertEqual(self._count('otel_events'), 5)


    def _post(self, path, body):
        import http.client
        import threading
        from http.server import HTTPServer
        srv = HTTPServer(('127.0.0.1', 0), self.mod.OTLPHandler)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        self.addCleanup(lambda: (srv.shutdown(), srv.server_close()))
        conn = http.client.HTTPConnection('127.0.0.1', srv.server_address[1], timeout=5)
        conn.request('POST', path, body=body, headers={'Content-Type': 'application/json'})
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp

    LOGS = (b'{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":"1",'
            b'"attributes":[{"key":"event.name","value":{"stringValue":"x"}}],'
            b'"body":{"stringValue":"b"}}]}]}]}')

    def test_http_normal_batch_is_200(self):
        self.assertEqual(self._post('/v1/logs', self.LOGS).status, 200)
        self.assertEqual(self._count('otel_events'), 1)

    def test_http_lock_dropped_batch_is_503_with_retry_after(self):
        self._patch_conn(fail_times=2)
        resp = self._post('/v1/logs', self.LOGS)
        self.assertEqual(resp.status, 503)
        self.assertEqual(resp.getheader('Retry-After'), '5')

    def test_http_malformed_payload_still_200(self):
        self.assertEqual(self._post('/v1/logs', b'not json').status, 200)

    def test_http_empty_batch_is_200(self):
        self.assertEqual(self._post('/v1/logs', b'{"resourceLogs":[]}').status, 200)


if __name__ == '__main__':
    unittest.main()
