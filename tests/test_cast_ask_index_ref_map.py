"""Audit P-2: cast-ask-index purges resolve rowids through record_fts_ref, not a record_fts SCAN.

record_fts keeps ref_id UNINDEXED, so `DELETE ... WHERE ref_id >= ? AND ref_id < ?` scanned the
whole virtual table once per indexed file. record_fts_ref (fts_rowid -> kind, ref_id; indexed on
(kind, ref_id)) makes the purge a SEARCH. These tests pin: the query plan, the map/FTS consistency
invariant across every write path, backfill on a pre-map DB, and MATCH results.

All runs use a temp DB (CAST_DB_PATH) and temp file roots; nothing touches ~/.claude.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_INDEX_PATH = _REPO / 'scripts' / 'cast-ask-index.py'
_DB_INIT = _REPO / 'scripts' / 'cast-db-init.sh'

_fts5_ok = False
try:
    _c = sqlite3.connect(':memory:')
    _c.execute('CREATE VIRTUAL TABLE t USING fts5(x)')
    _c.close()
    _fts5_ok = True
except Exception:
    pass

_PURGE_PLAN_SQL = (
    "DELETE FROM record_fts WHERE rowid IN "
    "(SELECT fts_rowid FROM record_fts_ref WHERE kind = ? AND ref_id >= ? AND ref_id < ?)"
)


def _transcript_line(i: int) -> str:
    return json.dumps({'type': 'user', 'message': {'content': f'prompt number {i} zebra{i} ' + 'x' * 900}})


@unittest.skipUnless(_fts5_ok, 'SQLite build lacks FTS5')
class TestRecordFtsRefMap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='cast-p2-')
        self.db = os.path.join(self.tmp, 'cast.db')
        self.proj = os.path.join(self.tmp, 'projects')
        self.journal = os.path.join(self.tmp, 'journal')
        self.resume = os.path.join(self.tmp, 'resume')
        for d in (self.proj, self.journal, self.resume):
            os.makedirs(d)
        # Temp HOME + CAST_DB_PATH for every subprocess (they copy os.environ) and the
        # in-process test (S4-1 D-D). cast_db._log_error is pinned to
        # Path.home()/.claude/logs/db-write-errors.log; CAST_DB_PATH does not redirect it.
        # patch.dict also restores CAST_DB_PATH, which the in-process test used to leak.
        self.home = os.path.join(self.tmp, 'home')
        os.makedirs(self.home)
        patcher = mock.patch.dict(os.environ, {'HOME': self.home, 'CAST_DB_PATH': self.db})
        patcher.start()
        self.addCleanup(patcher.stop)
        r = subprocess.run(['bash', str(_DB_INIT), '--db', self.db], capture_output=True, text=True,
                           env=dict(os.environ, CAST_DB_PATH=self.db), timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)

    def tearDown(self):
        import shutil
        assert self.tmp.startswith(tempfile.gettempdir()) or self.tmp.startswith('/var/folders')
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ---------------------------------------------------------
    def _run(self, *args):
        env = dict(os.environ, CAST_DB_PATH=self.db, CLAUDE_PROJECTS_DIR=self.proj,
                   CAST_JOURNAL_DIR=self.journal, CAST_RESUME_PROMPTS_DIR=self.resume)
        return subprocess.run([sys.executable, str(_INDEX_PATH), '--db', self.db, *args],
                              capture_output=True, text=True, env=env, timeout=300)

    def _q(self, sql, params=()):
        con = sqlite3.connect(self.db)
        try:
            return con.execute(sql, params).fetchall()
        finally:
            con.close()

    def _transcript(self, proj, name, n_lines, mtime):
        d = os.path.join(self.proj, proj)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, 'w') as f:
            f.write('\n'.join(_transcript_line(i) for i in range(n_lines)))
        os.utime(p, (mtime, mtime))
        return os.path.realpath(p)  # the indexer realpaths its root (macOS /var -> /private/var)

    def _journal(self, day, text):
        d = os.path.join(self.journal, day[:7])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, day + '.md'), 'w') as f:
            f.write(text)

    def assertConsistent(self):
        n_fts = self._q('SELECT count(*) FROM record_fts')[0][0]
        n_map = self._q('SELECT count(*) FROM record_fts_ref')[0][0]
        self.assertEqual(n_fts, n_map, f'map drifted: record_fts={n_fts} record_fts_ref={n_map}')
        mismatch = self._q(
            'SELECT count(*) FROM record_fts f JOIN record_fts_ref m ON m.fts_rowid = f.rowid '
            'WHERE m.kind != f.kind OR m.ref_id != f.ref_id')[0][0]
        self.assertEqual(mismatch, 0, 'map rows point at the wrong (kind, ref_id)')
        orphan = self._q('SELECT count(*) FROM record_fts_ref WHERE fts_rowid NOT IN '
                         '(SELECT rowid FROM record_fts)')[0][0]
        self.assertEqual(orphan, 0)

    def _ids(self, kind):
        return {r[0] for r in self._q('SELECT ref_id FROM record_fts WHERE kind = ?', (kind,))}

    # -- plan ------------------------------------------------------------
    def test_purge_plan_searches_the_index_and_never_scans_record_fts(self):
        con = sqlite3.connect(self.db)
        plan = ' | '.join(r[3] for r in con.execute(
            'EXPLAIN QUERY PLAN ' + _PURGE_PLAN_SQL, ('transcript', 'a#', 'a#\U0010ffff')))
        con.close()
        self.assertIn('idx_record_fts_ref_kind_ref', plan, plan)
        # `SCAN record_fts VIRTUAL TABLE INDEX 0:=` is FTS5's rowid-equality lookup (one probe per
        # rowid from the subquery) - fine. A FULL scan would be `INDEX 0:` with no `=` constraint
        # (what the old ref_id range DELETE produced: no rowid constraint at all).
        self.assertNotRegex(plan, r'SCAN record_fts VIRTUAL TABLE INDEX 0:(?!=)', plan)
        self.assertIn('INDEX 0:=', plan, plan)

    def test_init_is_idempotent_and_creates_map_and_index_once(self):
        r = subprocess.run(['bash', str(_DB_INIT), '--db', self.db], capture_output=True, text=True,
                           env=dict(os.environ, CAST_DB_PATH=self.db), timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._q("SELECT count(*) FROM sqlite_master WHERE name='record_fts_ref'")[0][0], 1)
        self.assertEqual(self._q("SELECT count(*) FROM sqlite_master "
                                 "WHERE name='idx_record_fts_ref_kind_ref'")[0][0], 1)

    # -- correctness -----------------------------------------------------
    def test_reindexing_one_changed_file_replaces_only_its_chunks(self):
        now = time.time()
        a = self._transcript('p1', 'a.jsonl', 30, now - 100)   # multi-chunk (30 * ~900 chars)
        b = self._transcript('p1', 'b.jsonl', 30, now - 90)
        c = self._transcript('p2', 'c.jsonl', 30, now - 80)
        r = self._run('--kind', 'transcript')
        self.assertEqual(r.returncode, 0, r.stderr)
        before = self._ids('transcript')
        a_before = {i for i in before if i.startswith(a + '#')}
        b_before = {i for i in before if i.startswith(b + '#')}
        self.assertGreater(len(a_before), 2, 'fixture must produce multiple chunks per file')
        self.assertConsistent()

        # Shrink `a` to a single chunk and bump its mtime so the incremental pass re-indexes it.
        self._transcript('p1', 'a.jsonl', 2, now + 10)
        r = self._run('--kind', 'transcript')
        self.assertEqual(r.returncode, 0, r.stderr)
        after = self._ids('transcript')
        a_after = {i for i in after if i.startswith(a + '#')}
        self.assertEqual(a_after, {a + '#0'}, 'old chunks of the changed file survived')
        self.assertEqual({i for i in after if i.startswith(b + '#')}, b_before)
        self.assertEqual({i for i in after if i.startswith(c + '#')},
                         {i for i in before if i.startswith(c + '#')})
        self.assertConsistent()

    def test_kind_reindex_leaves_other_kinds_and_their_map_rows_intact(self):
        self._journal('2026-10-01', 'journal body alpha ' * 1000)
        self._transcript('p1', 'a.jsonl', 5, time.time())
        self.assertEqual(self._run().returncode, 0)
        j_before = self._ids('journal')
        self.assertTrue(j_before)
        r = self._run('--rebuild', '--kind', 'transcript')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._ids('journal'), j_before)
        self.assertTrue(self._ids('transcript'))
        self.assertConsistent()

    def test_full_rebuild_clears_map_with_fts(self):
        self._journal('2026-10-01', 'journal body ' * 100)
        self.assertEqual(self._run().returncode, 0)
        self.assertGreater(self._q('SELECT count(*) FROM record_fts_ref')[0][0], 0)
        self.assertEqual(self._run('--rebuild').returncode, 0)
        self.assertConsistent()
        self.assertGreater(self._q('SELECT count(*) FROM record_fts_ref')[0][0], 0)

    def test_upsert_row_dedupes_on_kind_ref_id_and_keeps_map_consistent(self):
        import importlib.util
        sys.path.insert(0, str(_REPO / 'scripts'))
        spec = importlib.util.spec_from_file_location('cast_ask_index_under_test', _INDEX_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for body in ('first body', 'second body'):
            mod._upsert_row('incident', 'inc-1', '2026-10-01', 'title', body)
        mod._upsert_row('agent_run', 'inc-1', '2026-10-01', 'title', 'other kind same id')
        mod._upsert_row('incident', 'inc-10', '2026-10-01', 'title', 'prefix-sharing id')
        rows = self._q("SELECT kind, ref_id, body FROM record_fts ORDER BY kind, ref_id")
        self.assertEqual(rows, [('agent_run', 'inc-1', 'other kind same id'),
                                ('incident', 'inc-1', 'second body'),
                                ('incident', 'inc-10', 'prefix-sharing id')])
        self.assertConsistent()

    def test_backfill_on_db_without_the_map(self):
        self._journal('2026-10-01', 'journal body ' * 1000)
        self._transcript('p1', 'a.jsonl', 20, time.time())
        self.assertEqual(self._run().returncode, 0)
        con = sqlite3.connect(self.db)
        con.execute('DROP TABLE record_fts_ref')  # simulate a pre-map DB (test temp DB only)
        con.commit()
        con.close()
        r = self._run('--kind', 'journal')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('re-derived', r.stdout)
        # The journal pass re-indexes its (tie-safe) file, so compare to record_fts AS IT IS NOW.
        want = self._q('SELECT rowid, kind, ref_id FROM record_fts ORDER BY rowid')
        self.assertTrue(any(k == 'transcript' for _, k, _ in want), 'transcript rows must be backfilled')
        got = self._q('SELECT fts_rowid, kind, ref_id FROM record_fts_ref ORDER BY fts_rowid')
        self.assertEqual(got, want)
        self.assertConsistent()
        # Re-run is a no-op for the map.
        r2 = self._run('--kind', 'journal')
        self.assertNotIn('re-derived', r2.stdout)

    def test_stale_map_is_rederived(self):
        self._journal('2026-10-01', 'journal body ' * 1000)
        self.assertEqual(self._run().returncode, 0)
        con = sqlite3.connect(self.db)
        con.execute('DELETE FROM record_fts_ref')
        con.commit()
        con.close()
        self.assertEqual(self._run('--kind', 'journal').returncode, 0)
        self.assertConsistent()

    def test_match_results_unchanged_by_reindex(self):
        now = time.time()
        self._transcript('p1', 'a.jsonl', 12, now - 50)
        self._transcript('p1', 'b.jsonl', 12, now - 40)
        self.assertEqual(self._run('--kind', 'transcript').returncode, 0)
        q = ("SELECT ref_id FROM record_fts WHERE record_fts MATCH 'zebra7' ORDER BY ref_id")
        first = self._q(q)
        self.assertTrue(first)
        self.assertEqual(self._run('--rebuild', '--kind', 'transcript').returncode, 0)
        self.assertEqual(self._q(q), first)
        self.assertConsistent()


if __name__ == '__main__':
    unittest.main()
