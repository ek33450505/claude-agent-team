#!/usr/bin/env python3
"""_embed_pending must page rows, reuse one connection, and trip a circuit breaker.

Previously it loaded every un-embedded record_fts row (with body) into memory and
made one connection plus one 5 s Ollama call per row with no stop condition.
Everything runs against a temp DB and temp HOME; the embed module is stubbed.
"""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPTS = Path(__file__).parent.parent / 'scripts'
_DDL = """
CREATE VIRTUAL TABLE record_fts USING fts5(
  kind, ref_id UNINDEXED, ts UNINDEXED, title, body,
  agent UNINDEXED, project UNINDEXED, mtype UNINDEXED);
CREATE TABLE record_embed (
  kind TEXT NOT NULL, ref_id TEXT NOT NULL, vec BLOB, ts TEXT,
  PRIMARY KEY (kind, ref_id));
"""


class _Embed:
    def __init__(self, ok=True):
        self.ok = ok
        self.calls = 0

    def embed_text(self, text):
        self.calls += 1
        return [0.1, 0.2] if self.ok else None

    def pack_embedding(self, vec):
        return b'\x00' * 8


class TestEmbedPaging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='cast-embed-')
        self.db = os.path.join(self.tmp, 'cast.db')
        env = mock.patch.dict(os.environ, {'HOME': self.tmp, 'CAST_DB_PATH': self.db})
        env.start()
        self.addCleanup(env.stop)
        sys.path.insert(0, str(_SCRIPTS))
        self.addCleanup(sys.path.remove, str(_SCRIPTS))
        spec = importlib.util.spec_from_file_location('cast_ask_index_t', _SCRIPTS / 'cast-ask-index.py')
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        c = sqlite3.connect(self.db)
        c.executescript(_DDL)
        c.close()

    def _seed(self, n):
        c = sqlite3.connect(self.db)
        for i in range(n):
            c.execute("INSERT INTO record_fts(kind, ref_id, ts, title, body) VALUES ('memory', ?, 't', 'title', 'body')", (str(i),))
        c.commit()
        c.close()

    def _count(self):
        c = sqlite3.connect(self.db)
        n = c.execute('SELECT count(*) FROM record_embed').fetchone()[0]
        c.close()
        return n

    def test_all_rows_processed_across_page_boundaries(self):
        self.mod.EMBED_PAGE_SIZE = 4
        self._seed(11)  # 2 full pages + a partial one
        emb = _Embed(ok=True)
        with mock.patch.object(self.mod, '_load_embed_module', return_value=emb):
            n = self.mod._embed_pending(rebuild=False)
        self.assertEqual(n, 11)
        self.assertEqual(emb.calls, 11)
        self.assertEqual(self._count(), 11)

    def test_incremental_skips_already_embedded(self):
        self.mod.EMBED_PAGE_SIZE = 3
        self._seed(7)
        emb = _Embed(ok=True)
        with mock.patch.object(self.mod, '_load_embed_module', return_value=emb):
            self.mod._embed_pending(rebuild=False)
            emb.calls = 0
            self.assertEqual(self.mod._embed_pending(rebuild=False), 0)
        self.assertEqual(emb.calls, 0)

    def test_circuit_breaker_stops_after_three_failures(self):
        self.mod.EMBED_PAGE_SIZE = 4
        self._seed(20)
        emb = _Embed(ok=False)
        with mock.patch.object(self.mod, '_load_embed_module', return_value=emb), \
                mock.patch('sys.stderr') as err:
            n = self.mod._embed_pending(rebuild=False)
        self.assertEqual(n, 0)
        self.assertEqual(emb.calls, 4)  # 3 failing rows + 1 failed probe
        written = ''.join(c.args[0] for c in err.write.call_args_list)
        self.assertEqual(written.count('stopping after 3 consecutive'), 1)

    def test_success_resets_failure_streak(self):
        self._seed(8)
        results = iter([None, None, [1.0], None, None, [1.0], None, None])

        class Flaky(_Embed):
            def embed_text(s, text):
                s.calls += 1
                return next(results)

        emb = Flaky()
        with mock.patch.object(self.mod, '_load_embed_module', return_value=emb):
            n = self.mod._embed_pending(rebuild=False)
        self.assertEqual(n, 2)
        self.assertEqual(emb.calls, 8)

    def test_poison_rows_at_head_do_not_stop_the_run(self):
        self._seed(10)

        class Poison(_Embed):
            def embed_text(s, text):
                s.calls += 1
                return None if text.startswith('bad') else [0.1, 0.2]

        c = sqlite3.connect(self.db)
        c.execute("UPDATE record_fts SET title='bad' WHERE CAST(ref_id AS INTEGER) < 3")
        c.commit()
        c.close()
        emb = Poison()
        with mock.patch.object(self.mod, '_load_embed_module', return_value=emb):
            n = self.mod._embed_pending(rebuild=False)
        self.assertEqual(n, 7)
        self.assertEqual(self._count(), 7)


if __name__ == '__main__':
    unittest.main()
