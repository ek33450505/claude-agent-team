#!/usr/bin/env python3
"""DOC-4: `cast-ask-index.py --rebuild --kind K` wiped every OTHER kind.

main() applied the --kind filter to the list of SOURCES it would reindex, but the
`DELETE FROM record_fts` that precedes it was unscoped and ran first. So a rebuild
of one kind destroyed all of them and restored only the one named. Measured live
2026-08-27: 18,162 rows across 8 kinds (agent_run 8,867, dispatch 4,928,
transcript 2,719, memory 1,052, incident 252, distillate 209, journal 121, plan 14)
stood to be lost to rebuild any single one.

It was a known-sharp edge that became a likely one when I-3b Unit 2a added a
`kind='hatch'` source next to it, giving a routine reason to type the flag.

The same unscoped clear existed for record_embed, which is worse in kind: those
rows are Ollama embeddings that this run does NOT recompute for the other kinds,
so they would simply be gone.

Every test here runs against an isolated temp DB via --db. The obvious way to
test this bug is to trigger it, so it must never be able to reach ~/.claude/cast.db.
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_INDEX_PATH = Path(__file__).parent.parent / 'scripts' / 'cast-ask-index.py'

_fts5_ok = False
try:
    _c = sqlite3.connect(':memory:')
    _c.execute('CREATE VIRTUAL TABLE t USING fts5(x)')
    _c.close()
    _fts5_ok = True
except Exception:
    _fts5_ok = False

_DDL = """
CREATE VIRTUAL TABLE IF NOT EXISTS record_fts USING fts5(
  kind, ref_id UNINDEXED, ts UNINDEXED, title, body,
  agent UNINDEXED, project UNINDEXED, mtype UNINDEXED
);
CREATE TABLE IF NOT EXISTS record_embed (
  kind TEXT NOT NULL, ref_id TEXT NOT NULL, vec BLOB, ts TEXT,
  PRIMARY KEY (kind, ref_id)
);
CREATE TABLE IF NOT EXISTS ack_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, variable TEXT NOT NULL, value TEXT,
  script TEXT, repo TEXT, has_reason INTEGER DEFAULT 0, reason TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
"""


@unittest.skipUnless(_fts5_ok, 'SQLite build lacks FTS5')
class TestRebuildKindScope(unittest.TestCase):
    """A rebuild of one kind must leave every other kind's rows on disk."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='cast-doc4-')
        self.db = os.path.join(self.tmp, 'cast.db')
        con = sqlite3.connect(self.db)
        con.executescript(_DDL)
        # Seed one row per kind, standing in for the 18,162 real ones.
        for kind in ('agent_run', 'dispatch', 'transcript', 'memory',
                     'incident', 'distillate', 'journal', 'plan'):
            con.execute(
                "INSERT INTO record_fts(kind, ref_id, ts, title, body, agent, project, mtype) "
                "VALUES (?, ?, '2026-08-27T00:00:00Z', 'seeded', 'seeded body', '', '', '')",
                (kind, f'{kind}-1'),
            )
            con.execute("INSERT INTO record_embed(kind, ref_id, vec, ts) VALUES (?, ?, X'00', '')",
                        (kind, f'{kind}-1'))
        con.commit()
        con.close()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _rows(self, table='record_fts'):
        con = sqlite3.connect(self.db)
        n = dict(con.execute(f'SELECT kind, COUNT(*) FROM {table} GROUP BY kind').fetchall())
        con.close()
        return n

    def _seeded(self, table='record_fts'):
        """Only the rows THIS test seeded, keyed by their exact ref_id.

        Counting by kind cannot answer the question: the FILE_SOURCES read real
        files under $HOME, so after a full rebuild `transcript` is populous again
        with rows that were freshly indexed, not rows that survived. A count is
        identical either way — the ref_id is what discriminates.
        """
        con = sqlite3.connect(self.db)
        ids = {r[0] for r in con.execute(
            f'SELECT ref_id FROM {table} WHERE ref_id LIKE ?', ('%-1',)).fetchall()}
        con.close()
        return {i for i in ids if i.endswith('-1') and i.split('-')[0] in (
            'agent', 'dispatch', 'transcript', 'memory', 'incident',
            'distillate', 'journal', 'plan')} | {i for i in ids if i.startswith('agent_run-')}

    def _run(self, *args):
        env = dict(os.environ, CAST_DB_PATH=self.db)
        return subprocess.run([sys.executable, str(_INDEX_PATH), '--db', self.db, *args],
                              capture_output=True, text=True, env=env, timeout=120)

    def test_rebuild_with_kind_leaves_other_kinds_intact(self):
        before = self._seeded()
        self.assertEqual(len(before), 8, before)
        r = self._run('--rebuild', '--kind', 'hatch')
        self.assertEqual(r.returncode, 0, r.stderr)
        after = self._seeded()
        self.assertEqual(
            after, before,
            'a --kind rebuild destroyed rows belonging to other kinds: '
            f'lost={sorted(before - after)}\n{r.stdout}{r.stderr}',
        )

    def test_rebuild_with_kind_says_what_it_cleared(self):
        r = self._run('--rebuild', '--kind', 'hatch')
        self.assertIn('kind=hatch', r.stdout,
                      f'rebuild must name the scope it cleared: {r.stdout!r}')

    def test_rebuild_without_kind_still_clears_everything(self):
        """The unscoped clear is correct when every kind is being reindexed — it
        also sweeps kinds this version no longer produces. Narrowing the fix must
        not have narrowed that."""
        self.assertEqual(len(self._seeded()), 8)
        r = self._run('--rebuild')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._seeded(), set(),
                         'seeded rows survived a full unscoped rebuild')

    def test_rebuild_with_kind_leaves_other_kinds_embeddings_intact(self):
        """record_embed rows are Ollama output this run does not recompute for the
        other kinds, so an unscoped clear there loses them outright.

        _load_embed_module() is stubbed. Without the stub it returns None on a
        machine where the embed module will not import, _embed_pending returns
        before it ever reaches the delete, and this test passes whether the clear
        is scoped or not — which is exactly what it did on the first attempt, and
        the mutation run is what exposed it.
        """
        import importlib.util
        spec = importlib.util.spec_from_file_location('cast_ask_index', _INDEX_PATH)
        mod = importlib.util.module_from_spec(spec)
        os.environ['CAST_DB_PATH'] = self.db
        spec.loader.exec_module(mod)

        class _StubEmbed:
            @staticmethod
            def embed_text(_text):
                return None          # nothing to embed; only the clear is under test

            @staticmethod
            def pack_embedding(_vec):
                return b''

        mod._load_embed_module = lambda: _StubEmbed
        self.assertEqual(len(self._seeded('record_embed')), 8, 'fixture precondition')
        mod._embed_pending(rebuild=True, kind='hatch')
        after = self._seeded('record_embed')
        self.assertEqual(len(after), 8,
                         f'a --kind rebuild cleared other kinds embeddings: {after}')


if __name__ == '__main__':
    unittest.main()
