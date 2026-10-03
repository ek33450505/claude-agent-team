"""P-4a: unrecoverable (transcript pruned) rows leave the recovery candidate set;
the transcript tree is walked once per run. Temp HOME + temp CAST_DB_PATH only."""
import importlib.util
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, 'scripts', 'cast-abandon-stale-runs.py')
MARK = '[NO RESPONSE — SubagentStop never fired; reaped by x]'


def iso(days=0, hours=0):
    return (datetime.now(timezone.utc) - timedelta(days=days, hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')


class RetireTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._env = mock.patch.dict(os.environ, {
            'HOME': self.tmp, 'CAST_DB_PATH': os.path.join(self.tmp, 'cast.db')})
        self._env.start()
        spec = importlib.util.spec_from_file_location('reaper', SCRIPT)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.m.LOG_PATH = os.path.join(self.tmp, 'log')
        self.conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
        self.conn.execute('''CREATE TABLE agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT, started_at TEXT, ended_at TEXT, status TEXT, agent_id TEXT,
            session_id TEXT, response TEXT, abandoned_at TIMESTAMP)''')

    def tearDown(self):
        self._env.stop()
        self.conn.close()

    def row(self, aid, sid, age_days, ts_fmt=iso):
        ts = ts_fmt(days=age_days)
        self.conn.execute(
            "INSERT INTO agent_runs (agent,started_at,ended_at,abandoned_at,status,agent_id,session_id,response)"
            " VALUES ('bot',?,?,?,'abandoned',?,?,?)", (ts, ts, ts, aid, sid, MARK))
        self.conn.commit()

    def plant(self, sid, aid, text='hello'):
        d = os.path.join(self.tmp, '.claude', 'projects', 'p1', sid, 'subagents', 'nested')
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f'agent-{aid}.jsonl'), 'w') as f:
            f.write('{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' % text)

    def resp(self, aid):
        return self.conn.execute('SELECT response FROM agent_runs WHERE agent_id=?', (aid,)).fetchone()[0]

    def candidates(self):
        return self.conn.execute(
            "SELECT COUNT(*) FROM agent_runs WHERE status IN ('failed','abandoned') AND (response IS NULL OR response LIKE ?)",
            (self.m.NO_RESPONSE_MARKER_LIKE,)).fetchone()[0]

    def test_a_existing_transcript_recovered_even_when_old(self):
        self.row('a1', 's1', 90)
        self.plant('s1', 'a1', 'real work')
        self.m.recover_stale_responses(self.conn)
        self.assertEqual(self.resp('a1'), self.m.PARTIAL_PREFIX + 'real work')

    def test_b_old_row_without_transcript_retired_and_not_candidate_again(self):
        self.row('b1', 's2', 90)
        self.m.recover_stale_responses(self.conn)
        self.assertTrue(self.resp('b1').startswith('[UNRECOVERABLE'))
        self.assertEqual(self.candidates(), 0)
        with mock.patch.object(self.m, '_build_transcript_index', wraps=self.m._build_transcript_index) as w:
            self.m.recover_stale_responses(self.conn)
        self.assertEqual(w.call_count, 0)  # empty candidate set: no walk at all

    def test_b2_space_format_timestamps_also_retired(self):
        self.row('b2', 's9', 90, ts_fmt=lambda days: (datetime.now(timezone.utc) - timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S'))
        self.m.recover_stale_responses(self.conn)
        self.assertTrue(self.resp('b2').startswith('[UNRECOVERABLE'))

    def test_c_fresh_row_without_transcript_left_alone(self):
        self.row('c1', 's3', 0)
        self.row('c2', 's4', 10)  # inside the retention window
        self.m.recover_stale_responses(self.conn)
        self.assertEqual(self.resp('c1'), MARK)
        self.assertEqual(self.resp('c2'), MARK)

    def test_d_tree_walked_once_for_n_candidates(self):
        for i in range(7):
            self.row(f'd{i}', f'sd{i}', 0)
        with mock.patch.object(self.m.glob, 'glob', wraps=self.m.glob.glob) as g:
            self.m.recover_stale_responses(self.conn)
        self.assertEqual(g.call_count, 1)

    def test_limit_oldest_first(self):
        self.row('new', 'sn', 0)
        self.row('old', 'so', 90)
        with mock.patch.object(self.m, 'RECOVERY_CANDIDATE_LIMIT', 1):
            self.m.recover_stale_responses(self.conn)
        self.assertTrue(self.resp('old').startswith('[UNRECOVERABLE'))
        self.assertEqual(self.resp('new'), MARK)

    def test_retention_floor_keeps_doctor_window(self):
        with mock.patch.dict(os.environ, {'CAST_TRANSCRIPT_RETENTION_DAYS': '1'}):
            spec = importlib.util.spec_from_file_location('r2', SCRIPT)
            m2 = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m2)
        self.assertGreater(m2.TRANSCRIPT_RETENTION_DAYS, 7)


if __name__ == '__main__':
    unittest.main()
