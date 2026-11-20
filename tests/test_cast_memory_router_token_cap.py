#!/usr/bin/env python3
"""Tests for FTS token selection in cast-memory-router.py retrieve_record_global().

UserPromptSubmit p95 was ~1.3 s because the MATCH expression OR-joined every prompt
token (no dedupe, stopwords, or cap). _select_fts_tokens() bounds it.
Uses a temp DB + temp HOME; never touches ~/.claude/cast.db.
"""
import importlib.util
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


def setUpModule():
    home = tempfile.mkdtemp(prefix='cast-router-cap-home-')
    unittest.addModuleCleanup(shutil.rmtree, home, True)
    patcher = mock.patch.dict(os.environ, {'HOME': home})
    patcher.start()
    unittest.addModuleCleanup(patcher.stop)


def _import_router():
    spec = importlib.util.spec_from_file_location(
        'cast_memory_router_cap', str(Path(_SCRIPTS_DIR) / 'cast-memory-router.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _SpyConn:
    """Wraps a sqlite3 connection, recording MATCH parameters."""

    def __init__(self, conn, seen):
        self._conn = conn
        self._seen = seen

    def execute(self, sql, params=()):
        if 'MATCH' in sql:
            self._seen.append(params[0])
        return self._conn.execute(sql, params)

    def close(self):
        self._conn.close()

    def __getattr__(self, name):
        return getattr(self._conn, name)


class SelectFtsTokensTests(unittest.TestCase):
    def setUp(self):
        self.mod = _import_router()

    def test_stopword_only_returns_empty(self):
        self.assertEqual(
            self.mod._select_fts_tokens('the and is to please can you do it'.split()), [])

    def test_short_tokens_dropped(self):
        self.assertEqual(self.mod._select_fts_tokens(['x', 'router']), ['router'])

    def test_two_letter_domain_terms_survive(self):
        out = self.mod._select_fts_tokens(['db', 'ci', 'is', 'it', 'to', 'of', 'in', 'on'])
        self.assertEqual(sorted(out), ['ci', 'db'])

    def test_make_and_done_survive(self):
        self.assertEqual(sorted(self.mod._select_fts_tokens(['make', 'DONE'])), ['DONE', 'make'])

    def test_mixed_case_stopwords_dropped(self):
        self.assertEqual(self.mod._select_fts_tokens(['The', 'AND', 'Is', 'hook']), ['hook'])

    def test_domain_term_survives_in_long_prompt(self):
        filler = 'the and is to of in on at an or be do if so we me my no up'.split()
        out = self.mod._select_fts_tokens(filler * 3 + ['hook'])
        self.assertEqual(out, ['hook'])

    def test_duplicates_collapse_case_insensitively(self):
        out = self.mod._select_fts_tokens(['Router', 'router', 'ROUTER', 'hook'])
        self.assertEqual(sorted(t.lower() for t in out), ['hook', 'router'])
        self.assertEqual(len(out), 2)

    def test_cap_twelve_prefers_longer_ties_keep_order(self):
        toks = [f'tok{i:02d}' for i in range(20)] + ['longertoken']
        out = self.mod._select_fts_tokens(toks)
        self.assertEqual(len(out), 12)
        self.assertEqual(out[0], 'longertoken')
        # equal-length ties keep original order
        self.assertEqual(out[1:], [f'tok{i:02d}' for i in range(11)])


class RetrieveMatchExpressionTests(unittest.TestCase):
    def setUp(self):
        self.mod = _import_router()
        self.tmp = tempfile.mkdtemp(prefix='cast-router-cap-db-')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.db = os.path.join(self.tmp, 'c.db')
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE agent_memories (id INTEGER PRIMARY KEY, confidence REAL,"
                     " last_validated_at TEXT)")
        conn.execute("CREATE VIRTUAL TABLE record_fts USING fts5(kind, ref_id UNINDEXED,"
                     " ts UNINDEXED, title, body, agent UNINDEXED, project UNINDEXED,"
                     " mtype UNINDEXED)")
        conn.commit()
        conn.close()
        self.seen = []
        real = self.mod._connect
        self.mod._connect = lambda: _SpyConn(real(), self.seen)

    def _run(self, prompt):
        with mock.patch.dict(os.environ, {'CAST_DB_PATH': self.db}):
            return self.mod.retrieve_record_global(prompt, 3)

    def test_stopword_only_prompt_returns_empty_without_query(self):
        self.assertEqual(self._run('what is the and of it to'), [])
        self.assertEqual(self.seen, [])

    def test_more_than_12_tokens_yield_exactly_12_in_match(self):
        prompt = ' '.join(f'alphaterm{i:02d}' for i in range(25))
        self._run(prompt)
        self.assertEqual(len(self.seen), 1)
        self.assertEqual(self.seen[0].count(' OR ') + 1, 12)

    def test_duplicates_collapse_in_match(self):
        self._run('router Router ROUTER hook')
        self.assertEqual(self.seen[0].count(' OR ') + 1, 2)


if __name__ == '__main__':
    unittest.main()
