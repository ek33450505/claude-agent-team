#!/usr/bin/env python3
"""Tests for the 'distillate' FILE_SOURCE added to cast-ask-index.py (B2 U1).

Covers:
  (1) Indexing a temp CAST_RESUME_PROMPTS_DIR with a 2026-07-06-foo-auto.md file
      inserts a record_fts row with kind='distillate' whose body is searchable via MATCH.
  (2) Re-indexing after the file's content changes UPDATES the row (no duplicate) —
      proves stable ref_id (<path>#0) + delete-then-insert upsert logic.
  (3) Non-recursive: a .md inside a nested subdir of the temp dir is NOT indexed
      (glob_pattern='*.md' is flat).

Uses an isolated CAST_DB_PATH temp DB — never touches the real ~/.claude/cast.db.
Loads cast-ask-index.py via importlib (hyphenated module name).
"""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_INDEX_PATH = _SCRIPTS_DIR / 'cast-ask-index.py'

# ── FTS5 availability probe (skip gracefully if the build lacks it) ──────────
_fts5_ok: bool = False
try:
    _conn = sqlite3.connect(':memory:')
    _conn.execute('CREATE VIRTUAL TABLE t USING fts5(x)')
    _conn.close()
    _fts5_ok = True
except Exception:
    _fts5_ok = False

_RECORD_FTS_DDL = """
CREATE VIRTUAL TABLE IF NOT EXISTS record_fts USING fts5(
  kind,
  ref_id  UNINDEXED,
  ts      UNINDEXED,
  title,
  body,
  agent   UNINDEXED,
  project UNINDEXED,
  mtype   UNINDEXED
)
"""


def _init_test_db(db_path: str) -> None:
    """Create the minimal schema needed by cast-ask-index.py in a temp DB."""
    conn = sqlite3.connect(db_path)
    # record_fts is the only table that cast-ask-index.py writes to for file sources.
    conn.execute(_RECORD_FTS_DDL)
    conn.commit()
    conn.close()


def _load_index_module(db_path: str, resume_dir: str):
    """Load cast-ask-index.py with isolated env vars, return the module."""
    os.environ['CAST_DB_PATH'] = db_path
    os.environ['CAST_RESUME_PROMPTS_DIR'] = resume_dir
    # Ensure scripts/ is in sys.path so cast_db import succeeds inside the module.
    scripts_dir = str(_SCRIPTS_DIR)
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    spec = importlib.util.spec_from_file_location('cast_ask_index', str(_INDEX_PATH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _count_distillate_rows(db_path: str) -> int:
    conn = sqlite3.connect(db_path)
    row = conn.execute("SELECT COUNT(*) FROM record_fts WHERE kind='distillate'").fetchone()
    conn.close()
    return row[0] if row else 0


def _query_distillate_body_match(db_path: str, term: str) -> list:
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT body FROM record_fts WHERE kind='distillate' AND record_fts MATCH ?",
        (term,),
    ).fetchall()
    conn.close()
    return rows


@unittest.skipUnless(_fts5_ok, 'FTS5 not available in this sqlite3 build')
class TestDistillateFileSource(unittest.TestCase):

    def setUp(self):
        # Save pre-existing env so tearDown restores rather than clobbers it
        # for whichever test module runs next alphabetically.
        self._orig_db_path = os.environ.get('CAST_DB_PATH')
        self._orig_resume_dir = os.environ.get('CAST_RESUME_PROMPTS_DIR')

        # Isolated temp DB
        self._db_fd, self._db_path = tempfile.mkstemp(suffix='.db')
        os.close(self._db_fd)
        _init_test_db(self._db_path)

        # Isolated temp resume-prompts dir (flat — no subdirs for the main tests)
        self._resume_dir = tempfile.mkdtemp()

        # Load module under isolated env
        self._mod = _load_index_module(self._db_path, self._resume_dir)

        # Pull the distillate source config out of FILE_SOURCES
        self._distillate_src = next(
            s for s in self._mod.FILE_SOURCES if s['kind'] == 'distillate'
        )

    def tearDown(self):
        # Restore in `finally` so a raise from os.unlink (e.g. file already
        # gone) can never skip the env restore and clobber the next module —
        # that would reintroduce the isolation bug through a different door.
        try:
            os.unlink(self._db_path)
            # Clean up resume dir (and any nested dirs from test 3)
            import shutil
            shutil.rmtree(self._resume_dir, ignore_errors=True)
        finally:
            # Restore env: put back the original value rather than unconditionally
            # popping, which would clobber isolation for tests that run after this
            # module alphabetically (see tests/test_zz_db_isolation_guard.py).
            if self._orig_db_path is None:
                os.environ.pop('CAST_DB_PATH', None)
            else:
                os.environ['CAST_DB_PATH'] = self._orig_db_path
            if self._orig_resume_dir is None:
                os.environ.pop('CAST_RESUME_PROMPTS_DIR', None)
            else:
                os.environ['CAST_RESUME_PROMPTS_DIR'] = self._orig_resume_dir

    # ── Test 1: indexing inserts a searchable distillate row ─────────────────

    def test_index_inserts_distillate_row_searchable_via_match(self):
        distillate_file = os.path.join(self._resume_dir, '2026-07-06-foo-auto.md')
        with open(distillate_file, 'w') as f:
            f.write('# Resume\n\nSpecialist in grizzlybear orchestration workflows.\n')

        count = self._mod._index_file_source(self._distillate_src, rebuild=True)

        self.assertGreater(count, 0, 'Expected at least one chunk row inserted')
        self.assertGreater(_count_distillate_rows(self._db_path), 0)

        # The body must be searchable via FTS MATCH
        hits = _query_distillate_body_match(self._db_path, 'grizzlybear')
        self.assertTrue(len(hits) > 0, 'Expected FTS MATCH on "grizzlybear" to return rows')
        self.assertIn('grizzlybear', hits[0][0])

    # ── Test 2: re-indexing after content change UPDATES (no duplicate) ──────

    def test_reindex_upserts_no_duplicate(self):
        distillate_file = os.path.join(self._resume_dir, '2026-07-06-bar-auto.md')
        with open(distillate_file, 'w') as f:
            f.write('# Resume v1\n\nExpert in platypus engineering.\n')

        self._mod._index_file_source(self._distillate_src, rebuild=True)

        row_count_after_first = _count_distillate_rows(self._db_path)
        self.assertGreater(row_count_after_first, 0)

        # Overwrite file with new content (simulating session-end regeneration)
        with open(distillate_file, 'w') as f:
            f.write('# Resume v2\n\nExpert in walrusbadger systems.\n')

        # Re-index; ref_id is path-based so the upsert must DELETE old + INSERT new
        self._mod._index_file_source(self._distillate_src, rebuild=True)

        row_count_after_second = _count_distillate_rows(self._db_path)
        # Count must NOT grow (delete-then-insert upsert)
        self.assertEqual(
            row_count_after_second, row_count_after_first,
            'Row count grew after re-index — upsert did not deduplicate',
        )

        # New content must be present; old content must be gone
        hits_new = _query_distillate_body_match(self._db_path, 'walrusbadger')
        self.assertTrue(len(hits_new) > 0, 'New content not found after re-index')

        hits_old = _query_distillate_body_match(self._db_path, 'platypus')
        self.assertEqual(len(hits_old), 0, 'Old content still present after upsert — duplicate detected')

    # ── Test 3: nested subdir files are NOT indexed (flat glob only) ─────────

    def test_nested_subdir_md_not_indexed(self):
        # File directly in resume_dir — SHOULD be indexed
        flat_file = os.path.join(self._resume_dir, '2026-07-06-baz-auto.md')
        with open(flat_file, 'w') as f:
            f.write('Top-level distillate. Keyword: rhinoceros.\n')

        # File inside a nested subdir — must NOT be indexed (glob='*.md', not '**/*.md')
        nested_dir = os.path.join(self._resume_dir, '.claude')
        os.makedirs(nested_dir)
        nested_file = os.path.join(nested_dir, 'should-not-index.md')
        with open(nested_file, 'w') as f:
            f.write('Nested file. Keyword: aardvark.\n')

        self._mod._index_file_source(self._distillate_src, rebuild=True)

        # Flat file is indexed
        hits_flat = _query_distillate_body_match(self._db_path, 'rhinoceros')
        self.assertTrue(len(hits_flat) > 0, 'Top-level distillate file was not indexed')

        # Nested file is NOT indexed
        hits_nested = _query_distillate_body_match(self._db_path, 'aardvark')
        self.assertEqual(
            len(hits_nested), 0,
            'Nested subdir .md was indexed — glob_pattern should be flat (*.md, not **/*.md)',
        )


if __name__ == '__main__':
    unittest.main()
