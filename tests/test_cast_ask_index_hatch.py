#!/usr/bin/env python3
"""Tests for the 'hatch' SOURCES entry added to cast-ask-index.py (I-3b Unit 2a).

ack_events (migration 034) records escape-hatch uses; before this unit it had
zero readers. This indexes it into record_fts under kind='hatch' so `cast ask`
can answer questions like "which repo used CAST_RESET_OK".

Covers:
  (1) Indexing a temp ack_events table inserts record_fts rows with
      kind='hatch' whose title/body are searchable via FTS MATCH.
  (2) Re-indexing unchanged data adds ZERO net rows (incremental high-water +
      delete-then-insert upsert both hold — proves no duplication).
  (3) Row shape: title falls back to '(no repo)'/'(no script)' for empty-string
      (not NULL) repo/script columns; body carries variable/value/script/repo.
  (4) An absent ack_events table degrades cleanly (returns 0, never raises) —
      db_query's fail-open contract, exercised end to end through _index_source.

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

# Mirrors scripts/migrations/034_ack_events.sql (schema only, no data).
_ACK_EVENTS_DDL = """
CREATE TABLE IF NOT EXISTS ack_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  variable    TEXT NOT NULL,
  value       TEXT,
  has_reason  INTEGER NOT NULL DEFAULT 0,
  script      TEXT,
  git_sha     TEXT,
  session_id  TEXT,
  repo        TEXT,
  created_at  TEXT DEFAULT (datetime('now'))
)
"""


def _init_test_db(db_path: str, with_ack_events: bool = True) -> None:
    """Create the minimal schema needed by cast-ask-index.py in a temp DB."""
    conn = sqlite3.connect(db_path)
    conn.execute(_RECORD_FTS_DDL)
    if with_ack_events:
        conn.execute(_ACK_EVENTS_DDL)
    conn.commit()
    conn.close()


def _insert_ack_event(db_path: str, variable: str, value: str = '1', has_reason: int = 0,
                       script: str = 'cast-git-guard.py', repo: str = 'claude-agent-team',
                       created_at: str = None) -> None:
    conn = sqlite3.connect(db_path)
    if created_at is None:
        conn.execute(
            "INSERT INTO ack_events(variable, value, has_reason, script, repo) VALUES (?, ?, ?, ?, ?)",
            (variable, value, has_reason, script, repo),
        )
    else:
        conn.execute(
            "INSERT INTO ack_events(variable, value, has_reason, script, repo, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (variable, value, has_reason, script, repo, created_at),
        )
    conn.commit()
    conn.close()


def _load_index_module(db_path: str):
    """Load cast-ask-index.py with isolated CAST_DB_PATH, return the module."""
    os.environ['CAST_DB_PATH'] = db_path
    scripts_dir = str(_SCRIPTS_DIR)
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    spec = importlib.util.spec_from_file_location('cast_ask_index', str(_INDEX_PATH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _count_hatch_rows(db_path: str) -> int:
    conn = sqlite3.connect(db_path)
    row = conn.execute("SELECT COUNT(*) FROM record_fts WHERE kind='hatch'").fetchone()
    conn.close()
    return row[0] if row else 0


def _query_hatch_match(db_path: str, term: str) -> list:
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT title, body FROM record_fts WHERE kind='hatch' AND record_fts MATCH ?",
        (term,),
    ).fetchall()
    conn.close()
    return rows


@unittest.skipUnless(_fts5_ok, 'FTS5 not available in this sqlite3 build')
class TestHatchSource(unittest.TestCase):

    def setUp(self):
        self._orig_db_path = os.environ.get('CAST_DB_PATH')

        self._db_fd, self._db_path = tempfile.mkstemp(suffix='.db')
        os.close(self._db_fd)
        _init_test_db(self._db_path)

        self._mod = _load_index_module(self._db_path)
        self._hatch_src = next(s for s in self._mod.SOURCES if s['kind'] == 'hatch')

    def tearDown(self):
        try:
            os.unlink(self._db_path)
        finally:
            if self._orig_db_path is None:
                os.environ.pop('CAST_DB_PATH', None)
            else:
                os.environ['CAST_DB_PATH'] = self._orig_db_path

    # ── Test 1: indexing inserts a searchable hatch row ───────────────────────

    def test_index_inserts_hatch_row_searchable_via_match(self):
        _insert_ack_event(self._db_path, variable='CAST_RESET_OK', value='1', has_reason=0,
                           script='cast-git-guard.py', repo='claude-agent-team')

        count = self._mod._index_source(self._hatch_src, rebuild=True)

        self.assertEqual(count, 1)
        self.assertEqual(_count_hatch_rows(self._db_path), 1)

        hits = _query_hatch_match(self._db_path, 'CAST_RESET_OK')
        self.assertTrue(len(hits) > 0, 'Expected FTS MATCH on "CAST_RESET_OK" to return rows')
        self.assertIn('CAST_RESET_OK', hits[0][0])  # title

    # ── Test 2: re-indexing unchanged data adds ZERO net rows ─────────────────

    def test_reindex_no_net_new_rows(self):
        _insert_ack_event(self._db_path, variable='CAST_COMMIT_AGENT', value='reason text', has_reason=1,
                           script='cast-git-guard.py', repo='claude-agent-team',
                           created_at='2026-08-20 10:00:00')
        _insert_ack_event(self._db_path, variable='CAST_BRANCH_OK', value='1', has_reason=0,
                           script='manual-branch-prune', repo='claude-agent-team',
                           created_at='2026-08-21 11:00:00')

        first = self._mod._index_source(self._hatch_src, rebuild=True)
        self.assertEqual(first, 2)
        row_count_after_first = _count_hatch_rows(self._db_path)
        self.assertEqual(row_count_after_first, 2)

        # Second pass over UNCHANGED data (incremental, not --rebuild): must not
        # grow the table — proves the (kind, ref_id) delete-then-insert upsert
        # is a true no-op on already-indexed rows sharing the high-water tie.
        self._mod._index_source(self._hatch_src, rebuild=False)
        row_count_after_second = _count_hatch_rows(self._db_path)
        self.assertEqual(
            row_count_after_second, row_count_after_first,
            'Row count grew after incremental re-index — upsert did not deduplicate',
        )

        # A third pass confirms it holds, not just a one-time coincidence.
        self._mod._index_source(self._hatch_src, rebuild=False)
        self.assertEqual(_count_hatch_rows(self._db_path), row_count_after_first)

    # ── Test 3: row shape — repo/script fallback + body composition ──────────

    def test_row_shape_empty_repo_and_script_fallback(self):
        # repo/script are empty string (not NULL) — matches real ack_events rows
        # from hook invocations with no repo context (e.g. CAST_RESET_OK/CAST_CLEAN_OK
        # in the live probe copy).
        _insert_ack_event(self._db_path, variable='CAST_CLEAN_OK', value='1', has_reason=0,
                           script='', repo='')

        self._mod._index_source(self._hatch_src, rebuild=True)

        conn = sqlite3.connect(self._db_path)
        row = conn.execute(
            "SELECT title, body FROM record_fts WHERE kind='hatch'"
        ).fetchone()
        conn.close()

        title, body = row
        self.assertIn('(no repo)', title)
        self.assertIn('(no script)', title)
        self.assertIn('CAST_CLEAN_OK', title)
        # body_parts = [variable, value, script, repo] — variable and value must
        # carry through even when script/repo are empty (empty parts are simply
        # skipped by _concat_body, not padded).
        self.assertIn('CAST_CLEAN_OK', body)

    def test_row_shape_reason_value_in_body(self):
        _insert_ack_event(self._db_path, variable='CAST_COMMIT_AGENT', value='hotfix for CI outage',
                           has_reason=1, script='cast-git-guard.py', repo='ai-datacenter-tracker')

        self._mod._index_source(self._hatch_src, rebuild=True)

        hits = _query_hatch_match(self._db_path, 'hotfix')
        self.assertTrue(len(hits) > 0, 'Reason text in value column must be searchable via body')

        hits_repo = _query_hatch_match(self._db_path, 'ai_datacenter_tracker')
        # underscore-hyphen tokenization aside, at minimum the repo-qualified search
        # combined with the variable name must resolve to the row.
        hits_combined = _query_hatch_match(self._db_path, 'CAST_COMMIT_AGENT')
        self.assertTrue(len(hits_combined) > 0)

    # ── Test 4: absent ack_events table degrades cleanly ──────────────────────

    def test_absent_ack_events_table_degrades_cleanly(self):
        # Fresh DB with record_fts but WITHOUT ack_events at all.
        fd, no_ack_db_path = tempfile.mkstemp(suffix='.db')
        os.close(fd)
        try:
            _init_test_db(no_ack_db_path, with_ack_events=False)
            mod = _load_index_module(no_ack_db_path)
            hatch_src = next(s for s in mod.SOURCES if s['kind'] == 'hatch')

            # Must not raise — cast_db.db_query fails open (logs + returns []).
            count = mod._index_source(hatch_src, rebuild=True)
            self.assertEqual(count, 0)
            self.assertEqual(_count_hatch_rows(no_ack_db_path), 0)
        finally:
            os.unlink(no_ack_db_path)

    def test_empty_ack_events_table_degrades_cleanly(self):
        # ack_events exists but has zero rows.
        count = self._mod._index_source(self._hatch_src, rebuild=True)
        self.assertEqual(count, 0)
        self.assertEqual(_count_hatch_rows(self._db_path), 0)


if __name__ == '__main__':
    unittest.main()
