#!/usr/bin/env python3
"""Tests for scripts/cast-otel-report.py — read-only otel_events reporter.

Temp DB via CAST_DB_PATH under a tempfile dir (accepted by cast_db's temp-root
allowlist); never the real ~/.claude/cast.db. CLI tests run the script as a subprocess.
"""
import datetime
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).parent.parent / 'scripts' / 'cast-otel-report.py'
_spec = importlib.util.spec_from_file_location('cast_otel_report', _SCRIPT)
rep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rep)

_SCHEMA = (
    'CREATE TABLE otel_events(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, '
    'event_name TEXT, prompt_id TEXT, severity TEXT, body TEXT, '
    'time_unix_nano INTEGER, received_at TEXT)'
)


def _ts(days_ago: float = 0.0) -> str:
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_ago)
    return t.strftime('%Y-%m-%dT%H:%M:%S.000Z')


class _Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.db = os.path.join(self._tmp.name, 'cast.db')
        self.conn = sqlite3.connect(self.db)
        self.conn.execute(_SCHEMA)
        self.addCleanup(self.conn.close)

    def add(self, name, attrs, received_at=None):
        body = json.dumps({'message': f'claude_code.{name}', 'attributes': attrs})
        self.conn.execute(
            'INSERT INTO otel_events(session_id,event_name,body,received_at) VALUES(?,?,?,?)',
            ('s1', name, body, received_at or _ts()))
        self.conn.commit()

    def cutoff(self, days=7):
        return rep.cutoff_iso(days)

    def run_cli(self, *args, db=None):
        env = dict(os.environ, CAST_DB_PATH=db or self.db)
        return subprocess.run([sys.executable, '-I', str(_SCRIPT), *args],
                              capture_output=True, text=True, env=env)


class SectionTests(_Base):
    def test_tool_decision_counts(self):
        a = {'decision': 'accept', 'source': 'config', 'classifier_verdict': 'allow',
             'permission_mode': 'auto'}
        self.add('tool_decision', a)
        self.add('tool_decision', a)
        self.add('tool_decision', {'decision': 'reject', 'source': 'hook', 'permission_mode': 'auto'})
        rows = rep.tool_decision(self.conn, self.cutoff())
        by = {(r['classifier_verdict'], r['decision']): r['n'] for r in rows}
        self.assertEqual(by, {('allow', 'accept'): 2, ('-', 'reject'): 1})
        self.assertEqual(rep.reject_count(rows), 1)

    def test_cache_split_per_day(self):
        d1, d2 = _ts(1), _ts(0)
        base = {'input_tokens': 2, 'output_tokens': 10, 'cache_read_tokens': 100,
                'cache_creation_5m_tokens': 0, 'cache_creation_1h_tokens': 5, 'cost_usd': 0.5}
        self.add('api_request', base, d1)
        self.add('api_request', base, d1)
        self.add('api_request', dict(base, cost_usd=0.25), d2)
        rows = rep.cache(self.conn, self.cutoff())
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['day'], d1[:10])
        self.assertEqual((rows[0]['requests'], rows[0]['input_tokens'], rows[0]['cache_read_tokens'],
                          rows[0]['cache_1h_tokens'], rows[0]['cost_usd']), (2, 4, 200, 10, 1.0))
        self.assertEqual((rows[1]['requests'], rows[1]['cost_usd']), (1, 0.25))

    def test_hooks_string_numerics(self):
        h = {'hook_name': 'PostToolUse:Bash', 'total_duration_ms': '10', 'stdout_chars': '4',
             'additional_context_chars': '3', 'num_outputs_persisted': '0', 'num_blocking': '0'}
        self.add('hook_execution_complete', h)
        self.add('hook_execution_complete', dict(h, total_duration_ms='30', stdout_chars='6',
                 num_outputs_persisted='1', num_blocking='2'))
        self.add('hook_execution_complete', dict(h, hook_name='Stop'))
        rows = rep.hooks(self.conn, self.cutoff(), 20)
        top = rows[0]
        self.assertEqual(top['hook_name'], 'PostToolUse:Bash')
        self.assertEqual((top['executions'], top['avg_ms'], top['stdout_chars'], top['max_stdout_chars'],
                          top['context_chars'], top['persisted'], top['blocking']),
                         (2, 20.0, 10, 6, 6, 1, 2))
        self.assertEqual(len(rep.hooks(self.conn, self.cutoff(), 1)), 1)

    def test_workflow_rollup(self):
        w = {'workflow.run_id': 'wf_1', 'workflow.name': 'custom', 'model': 'm-a', 'cost_usd': 0.1}
        self.add('api_request', w)
        self.add('api_request', dict(w, model='m-b', cost_usd=0.2))
        self.add('api_request', {'model': 'm-a', 'cost_usd': 9})
        rows = rep.workflow(self.conn, self.cutoff())
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r['run_id'], r['name'], r['requests'], r['cost_usd']), ('wf_1', 'custom', 2, 0.3))
        self.assertEqual(set(r['models'].split(',')), {'m-a', 'm-b'})

    def test_days_window_excludes_old(self):
        a = {'decision': 'accept', 'permission_mode': 'auto'}
        self.add('tool_decision', a)
        self.add('tool_decision', a, _ts(10))
        rows = rep.tool_decision(self.conn, self.cutoff(7))
        self.assertEqual(sum(r['n'] for r in rows), 1)

    def test_safety_count(self):
        self.assertEqual(rep.safety(self.conn, self.cutoff())[0]['safety_events'], 0)
        self.add('safety_event', {})
        self.assertEqual(rep.safety(self.conn, self.cutoff())[0]['safety_events'], 1)


class CliTests(_Base):
    def test_safety_zero_mentions_proxy(self):
        self.add('tool_decision', {'decision': 'reject', 'permission_mode': 'auto'})
        p = self.run_cli('--section', 'safety')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('safety_events: 0', p.stdout)
        self.assertIn('proxy', p.stdout)
        self.assertIn('Rejects in window: 1', p.stdout)
        self.assertNotIn('== tool_decision', p.stdout)

    def test_safety_one(self):
        self.add('safety_event', {})
        p = self.run_cli('--section', 'safety')
        self.assertIn('safety_events: 1', p.stdout)
        self.assertNotIn('proxy', p.stdout)

    def test_empty_table(self):
        p = self.run_cli()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('(no rows in window)', p.stdout)

    def test_json_success(self):
        self.add('tool_decision', {'decision': 'accept', 'permission_mode': 'auto'})
        p = self.run_cli('--json')
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(p.stdout)
        self.assertEqual(set(data), set(rep.SECTION_NAMES))
        self.assertEqual(data['tool_decision'][0]['n'], 1)

    def test_missing_db_exit1_not_created(self):
        missing = os.path.join(self._tmp.name, 'nope.db')
        p = self.run_cli(db=missing)
        self.assertEqual(p.returncode, 1)
        self.assertFalse(os.path.exists(missing))
        self.assertIn('database not found', p.stderr)
        pj = self.run_cli('--json', db=missing)
        self.assertEqual(pj.returncode, 1)
        self.assertIn('database not found', json.loads(pj.stdout)['error'])

    def test_missing_table_exit1(self):
        other = os.path.join(self._tmp.name, 'other.db')
        c = sqlite3.connect(other)
        c.execute('CREATE TABLE x(a)')
        c.commit()
        c.close()
        p = self.run_cli(db=other)
        self.assertEqual(p.returncode, 1)
        self.assertIn('otel_events', p.stderr)
        pj = self.run_cli('--json', db=other)
        self.assertEqual(pj.returncode, 1)
        self.assertIn('otel_events', json.loads(pj.stdout)['error'])

    def test_json_arg_error_is_json(self):
        for bad in (('--days', 'x'), ('--days', '0'), ('--days', '99999'),
                    ('--limit', '0'), ('--limit', '1001'), ('--section', 'nope')):
            p = self.run_cli('--json', *bad)
            self.assertEqual(p.returncode, 1, bad)
            self.assertIn('error', json.loads(p.stdout), bad)
        p = self.run_cli('--json=x')
        self.assertEqual(p.returncode, 1)
        self.assertIn('error', json.loads(p.stdout))

    def test_text_arg_error_exit1_stderr(self):
        p = self.run_cli('--days', 'x')
        self.assertEqual(p.returncode, 1)
        self.assertEqual(p.stdout, '')
        self.assertIn('--days', p.stderr)

    def test_hostile_values_sanitized(self):
        self.add('hook_execution_complete',
                 {'hook_name': 'ev\x1b]0;x\x07il\nname\x9b', 'total_duration_ms': '1'})
        p = self.run_cli('--section', 'hooks')
        self.assertEqual(p.returncode, 0, p.stderr)
        for ch in ('\x1b', '\x07', '\x9b'):
            self.assertNotIn(ch, p.stdout)
        rows = [ln for ln in p.stdout.splitlines() if 'ev' in ln and 'name' in ln]
        self.assertEqual(len(rows), 1, p.stdout)
        self.assertIn('ev?]0;x?il?name?', rows[0])

    def test_path_with_special_chars(self):
        d = os.path.join(self._tmp.name, 'a?b#c%d e')
        os.makedirs(d)
        db = os.path.join(d, 'cast.db')
        c = sqlite3.connect(db)
        c.execute(_SCHEMA)
        c.execute('INSERT INTO otel_events(session_id,event_name,body,received_at) VALUES(?,?,?,?)',
                  ('s', 'tool_decision', json.dumps({'attributes': {'decision': 'accept'}}), _ts()))
        c.commit()
        c.close()
        p = self.run_cli('--json', '--section', 'tool_decision', db=db)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertEqual(json.loads(p.stdout)['tool_decision'][0]['n'], 1)


class BoundaryTests(_Base):
    def test_cutoff_second_is_inclusive(self):
        cut = self.cutoff(7)
        a = {'decision': 'accept', 'permission_mode': 'auto'}
        self.add('tool_decision', a, cut + '.000Z')  # exactly the cutoff second: included (>=)
        self.add('tool_decision', a, cut)            # identical string: included (>=)
        before = (datetime.datetime.strptime(cut, '%Y-%m-%dT%H:%M:%S')
                  - datetime.timedelta(seconds=1)).strftime('%Y-%m-%dT%H:%M:%S.999Z')
        self.add('tool_decision', a, before)         # one second earlier: excluded
        rows = rep.tool_decision(self.conn, cut)
        self.assertEqual(sum(r['n'] for r in rows), 2)


if __name__ == '__main__':
    unittest.main()
