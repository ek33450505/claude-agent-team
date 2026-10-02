#!/usr/bin/env python3
"""Tests for per-model cache_read_multiplier pricing.

Covers scripts/cast-recost-agent-runs.py::_cost, the repo config/model-pricing.json
entries, parity with scripts/cast_subagent_stop.py::_compute_cost_usd (guards the two
implementations from drifting), and that a dry run never writes the DB.

All DB/HOME use is isolated to temp dirs; nothing touches the real ~/.claude.
"""
import hashlib
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_REPO = Path(__file__).parent.parent
_SCRIPTS = _REPO / 'scripts'
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import cast_subagent_stop as css  # noqa: E402

_RECOST_PATH = _SCRIPTS / 'cast-recost-agent-runs.py'
_spec = importlib.util.spec_from_file_location('cast_recost_agent_runs', _RECOST_PATH)
recost = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recost)

FIXTURE = {
    '_default': {'cost_per_million_input': 3.0, 'cost_per_million_output': 15.0},
    'claude-opus-5-5': {'cost_per_million_input': 4.0, 'cost_per_million_output': 20.0,
                        'cache_read_multiplier': 0.05},
    'claude-fable-5-1': {'cost_per_million_input': 10.0, 'cost_per_million_output': 50.0,
                         'cache_read_multiplier': 0.025},
    'claude-sonnet-5-5': {'cost_per_million_input': 2.0, 'cost_per_million_output': 10.0},
}


def _expected(rin, rout, mult, tin=0, tout=0, cc=0, cr=0):
    return round((tin * rin + tout * rout + cc * rin * 1.25 + cr * rin * mult) / 1e6, 6)


class RecostCostTests(unittest.TestCase):
    def test_opus_5_5_cache_read_005(self):
        got = recost._cost(FIXTURE, 'claude-opus-5-5', 0, 0, 0, 1_000_000)
        self.assertEqual(got, 0.2)

    def test_fable_5_1_cache_read_0025(self):
        got = recost._cost(FIXTURE, 'claude-fable-5-1', 0, 0, 0, 1_000_000)
        self.assertEqual(got, 0.25)

    def test_sonnet_5_5_default_01(self):
        got = recost._cost(FIXTURE, 'claude-sonnet-5-5', 0, 0, 0, 1_000_000)
        self.assertEqual(got, 0.2)

    def test_unknown_model_uses_default_rates_and_01(self):
        got = recost._cost(FIXTURE, 'claude-nope', 1000, 1000, 1000, 1_000_000)
        self.assertEqual(got, _expected(3.0, 15.0, 0.1, 1000, 1000, 1000, 1_000_000))

    def test_cache_write_is_125x(self):
        got = recost._cost(FIXTURE, 'claude-opus-5-5', 0, 0, 1_000_000, 0)
        self.assertEqual(got, 5.0)


class RepoConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.models = json.loads((_REPO / 'config' / 'model-pricing.json').read_text())['models']

    def test_opus_5_5(self):
        e = self.models['claude-opus-5-5']
        self.assertEqual((e['cost_per_million_input'], e['cost_per_million_output']), (4.0, 20.0))
        self.assertEqual(e['cache_read_multiplier'], 0.05)

    def test_sonnet_5_5(self):
        e = self.models['claude-sonnet-5-5']
        self.assertEqual((e['cost_per_million_input'], e['cost_per_million_output']), (2.0, 10.0))
        self.assertNotIn('cache_read_multiplier', e)

    def test_fable_and_mythos_5_1(self):
        for k in ('claude-fable-5-1', 'claude-mythos-5-1'):
            e = self.models[k]
            self.assertEqual((e['cost_per_million_input'], e['cost_per_million_output']), (10.0, 50.0))
            self.assertEqual(e['cache_read_multiplier'], 0.025)


class ParityTests(unittest.TestCase):
    def test_hook_and_recost_agree(self):
        tokens = [(0, 0, 0, 0), (1234, 567, 8901, 234567), (10**6, 10**6, 10**6, 10**6), (5, 0, 0, 999_999)]
        for model, entry in FIXTURE.items():
            for tin, tout, cc, cr in tokens:
                with self.subTest(model=model, tokens=(tin, tout, cc, cr)):
                    self.assertEqual(
                        css._compute_cost_usd(entry, tin, tout, cc, cr),
                        recost._cost(FIXTURE, model, tin, tout, cc, cr),
                    )

    def test_hook_helper_defaults_for_empty_entry(self):
        self.assertEqual(css._compute_cost_usd({}, 1000, 1000, 1000, 1_000_000),
                         _expected(3.0, 15.0, 0.1, 1000, 1000, 1000, 1_000_000))

    def test_hook_helper_per_model_multiplier(self):
        self.assertEqual(css._compute_cost_usd(FIXTURE['claude-opus-5-5'], 0, 0, 0, 1_000_000), 0.2)
        self.assertEqual(css._compute_cost_usd(FIXTURE['claude-fable-5-1'], 0, 0, 0, 1_000_000), 0.25)


class DryRunTests(unittest.TestCase):
    def test_dry_run_does_not_write_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / '.claude' / 'config'
            cfg.mkdir(parents=True)
            (cfg / 'model-pricing.json').write_text(json.dumps({'models': FIXTURE}))
            db = str(Path(tmp) / 'test.db')
            conn = sqlite3.connect(db)
            conn.execute(
                'CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, model TEXT, input_tokens INTEGER, '
                'output_tokens INTEGER, cache_creation_input_tokens INTEGER, '
                'cache_read_input_tokens INTEGER, cost_usd REAL)')
            conn.executemany('INSERT INTO agent_runs VALUES (?,?,?,?,?,?,?)', [
                (1, 'claude-opus-5-5', 1000, 500, 2000, 100000, 0.001),
                (2, 'claude-sonnet-5-5', 1000, 500, 0, 0, None),
                (3, None, 10, 10, 0, 0, None),
            ])
            conn.commit()
            conn.close()
            before = hashlib.sha256(Path(db).read_bytes()).hexdigest()
            r = subprocess.run([sys.executable, str(_RECOST_PATH)], capture_output=True, text=True,
                               env={**os.environ, 'HOME': tmp, 'CAST_DB_PATH': db}, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('claude-opus-5-5', r.stdout)
            self.assertIn('DRY RUN', r.stderr)
            self.assertEqual(hashlib.sha256(Path(db).read_bytes()).hexdigest(), before)


if __name__ == '__main__':
    unittest.main()
