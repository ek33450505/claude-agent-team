#!/usr/bin/env python3
"""_semantic_rerank: batched embedding lookup keeps results and order identical."""
import importlib.util
import os
import sqlite3
import sys
import unittest
from pathlib import Path

_SCRIPTS = Path(__file__).parent.parent / 'scripts'


class _Cme:
    def embed_text(self, q):
        return [1.0, 0.0]

    def unpack_embedding(self, b):
        return [float(b[0]), float(b[1])]

    def cosine_similarity(self, a, b):
        return a[0] * b[0] + a[1] * b[1]


class TestRerankBatch(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(_SCRIPTS))
        self.addCleanup(sys.path.remove, str(_SCRIPTS))
        spec = importlib.util.spec_from_file_location('cast_ask_query_t', _SCRIPTS / 'cast-ask-query.py')
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.mod._load_embed_module = lambda: _Cme()
        self.conn = sqlite3.connect(':memory:')
        self.conn.row_factory = sqlite3.Row
        self.conn.execute('CREATE TABLE record_embed (kind TEXT, ref_id TEXT, vec BLOB, ts TEXT, PRIMARY KEY(kind, ref_id))')

    def _put(self, kind, ref, a, b):
        self.conn.execute('INSERT INTO record_embed VALUES (?,?,?,NULL)', (kind, ref, bytes([a, b])))

    def test_order_by_score_with_unembedded_last_and_ties_stable(self):
        self._put('memory', 'a', 1, 0)   # score 1
        self._put('plan', 'a', 3, 0)     # score 3 (same ref_id, different kind)
        self._put('memory', 'b', 1, 0)   # score 1 (tie with memory/a, FTS order kept)
        rows = [
            {'kind': 'memory', 'ref_id': 'x'},   # no embedding -> -1
            {'kind': 'memory', 'ref_id': 'a'},
            {'kind': 'plan', 'ref_id': 'a'},
            {'kind': 'memory', 'ref_id': 'b'},
        ]
        out = self.mod._semantic_rerank(self.conn, rows, 'q', 10)
        self.assertEqual([(r['kind'], r['ref_id']) for r in out],
                         [('plan', 'a'), ('memory', 'a'), ('memory', 'b'), ('memory', 'x')])

    def test_many_hits_chunked_and_single_query_per_chunk(self):
        rows = []
        for i in range(450):
            self._put('memory', str(i), i % 7 + 1, 0)
            rows.append({'kind': 'memory', 'ref_id': str(i)})
        stmts = []
        self.conn.set_trace_callback(stmts.append)
        out = self.mod._semantic_rerank(self.conn, rows, 'q', 450)
        self.conn.set_trace_callback(None)
        self.assertEqual(len(out), 450)
        scores = [i % 7 + 1 for i in range(450)]
        expected = [rows[i] for i in sorted(range(450), key=lambda i: -scores[i])]
        self.assertEqual(out, expected)
        embed_selects = [s for s in stmts if 'FROM record_embed WHERE' in s]
        self.assertEqual(len(embed_selects), 3)  # 450 hits / 200 per chunk


if __name__ == '__main__':
    unittest.main()
