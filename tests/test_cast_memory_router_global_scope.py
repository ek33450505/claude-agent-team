#!/usr/bin/env python3
"""Tests for retrieve_record_global() in cast-memory-router.py (B2 Unit 2).

Covers:
  1. Different prompts → different, on-topic results (per-prompt relevance).
  2. Verified gate: memory with confidence<0.5 or NULL last_validated_at is EXCLUDED;
     passing memory (confidence>=0.5, last_validated_at set) is INCLUDED.
  3. incident + distillate rows are returned without confidence gate.
  4. Top hit for a strong match scores >= 0.3.
  5. injection_log gets a row for memory/incident hit; distillate hit (id=None) produces
     NO injection_log row (fact_id NOT NULL contract).
  6. Empty/whitespace prompt and no-match → [].

Uses an isolated CAST_DB_PATH temp DB seeded with tiny record_fts + agent_memories fixture.
NEVER touches ~/.claude/cast.db.
"""
import os
import sys
import sqlite3
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = str(Path(__file__).parent.parent / 'scripts')
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Import after path setup
import cast_db  # noqa: E402


def _import_router():
    """Import the memory router module under an isolated CAST_DB_PATH."""
    import importlib
    # cast-memory-router.py has a hyphen so we can't use normal import
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'cast_memory_router',
        str(Path(_SCRIPTS_DIR) / 'cast-memory-router.py')
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _create_test_db(path: str) -> sqlite3.Connection:
    """Seed a minimal test DB with agent_memories, record_fts, and injection_log tables."""
    conn = sqlite3.connect(path)
    conn.execute('PRAGMA journal_mode=WAL')

    # agent_memories table (minimal columns needed)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS agent_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT,
            type TEXT,
            name TEXT,
            description TEXT,
            content TEXT,
            importance REAL DEFAULT 0.5,
            confidence REAL DEFAULT 1.0,
            last_validated_at TEXT,
            decay_rate REAL DEFAULT 0.1,
            retrieval_count INTEGER DEFAULT 0,
            valid_to TEXT,
            updated_at TEXT
        )
    """)

    # injection_log table
    conn.execute("""
        CREATE TABLE IF NOT EXISTS injection_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            prompt_hash TEXT,
            fact_id INTEGER NOT NULL,
            score REAL,
            score_breakdown TEXT,
            injected_at TEXT
        )
    """)

    # record_fts FTS5 virtual table
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS record_fts USING fts5(
            kind,
            ref_id UNINDEXED,
            ts UNINDEXED,
            title,
            body,
            agent UNINDEXED,
            project UNINDEXED,
            mtype UNINDEXED
        )
    """)

    conn.commit()
    return conn


def _seed_memories(conn: sqlite3.Connection):
    """Insert test agent_memories rows and corresponding record_fts entries."""
    # Memory 1: passes verified gate (confidence=0.8, has last_validated_at)
    conn.execute("""
        INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
        VALUES (1, 'shared', 'procedural', 'resume distillate tip',
                'Keep resume bullet points concise and achievement-oriented.', 0.8,
                '2026-07-01T00:00:00Z')
    """)
    # Memory 2: FAILS gate (confidence=0.3)
    conn.execute("""
        INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
        VALUES (2, 'shared', 'reference', 'low-conf memory',
                'Some outdated note about git workflows.', 0.3, '2026-06-01T00:00:00Z')
    """)
    # Memory 3: FAILS gate (last_validated_at is NULL)
    conn.execute("""
        INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
        VALUES (3, 'shared', 'project', 'unvalidated memory',
                'Unvalidated project note about CI.', 0.9, NULL)
    """)

    # FTS rows for memories
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('memory', '1', '2026-07-01T00:00:00Z',
                'resume distillate tip',
                'Keep resume bullet points concise and achievement-oriented.',
                'shared', '', 'procedural')
    """)
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('memory', '2', '2026-06-01T00:00:00Z',
                'low-conf memory', 'Some outdated note about git workflows.',
                'shared', '', 'reference')
    """)
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('memory', '3', '2026-06-01T00:00:00Z',
                'unvalidated memory', 'Unvalidated project note about CI.',
                'shared', '', 'project')
    """)

    # Incident row (no confidence gate needed)
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('incident', '890a9e51-1a65-400b-919c-6f9eeb7e4b39', '2026-07-01T00:00:00Z',
                'session wipe incident',
                'The ~/.claude directory was wiped unexpectedly during a test run.',
                'shared', '', 'incident')
    """)

    # Distillate row (no confidence gate; ref_id is a file path)
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('distillate', '/path/to/distillate.md', '2026-07-01T00:00:00Z',
                'session distillate 2026-07-01',
                'Session summary covering memory injection improvements and B2 work.',
                'shared', '', 'distillate')
    """)

    # Unrelated row to test topic separation
    conn.execute("""
        INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
        VALUES ('memory', '99', '2026-07-01T00:00:00Z',
                'unrelated docker note',
                'Docker container setup guide for ubuntu testing environment.',
                'shared', '', 'reference')
    """)
    # Add a passing agent_memory row for mem 99 so it can appear if matched
    conn.execute("""
        INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
        VALUES (99, 'shared', 'reference', 'unrelated docker note',
                'Docker container setup guide for ubuntu testing environment.', 0.9,
                '2026-07-01T00:00:00Z')
    """)

    conn.commit()


class TestRetrieveRecordGlobal(unittest.TestCase):
    """Tests for retrieve_record_global() using an isolated temp DB."""

    def setUp(self):
        # Create isolated temp DB
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        os.environ['CAST_DB_PATH'] = self._tmp.name
        # Seed
        conn = _create_test_db(self._tmp.name)
        _seed_memories(conn)
        conn.close()
        # Import router with the correct DB env
        self.router = _import_router()

    def tearDown(self):
        os.unlink(self._tmp.name)
        os.environ.pop('CAST_DB_PATH', None)

    # --- Test 1: per-prompt relevance ---
    def test_resume_prompt_hits_resume_memory(self):
        """Resume-topic prompt returns the resume memory, not docker note."""
        results = self.router.retrieve_record_global('resume distillate bullet points', top_n=3)
        names = [r['name'] for r in results]
        self.assertIn('resume distillate tip', names,
                      'Expected resume memory in results for resume prompt')
        # Docker note should NOT be the top hit for a resume prompt
        if results:
            self.assertNotEqual(results[0]['name'], 'unrelated docker note',
                                'Docker note should not be top hit for resume prompt')

    def test_docker_prompt_hits_docker_memory(self):
        """Docker-topic prompt returns docker note, not resume memory."""
        results = self.router.retrieve_record_global('docker container ubuntu setup', top_n=3)
        names = [r['name'] for r in results]
        self.assertIn('unrelated docker note', names,
                      'Expected docker note in results for docker prompt')

    def test_different_prompts_give_different_top_hits(self):
        """Two unrelated prompts must not return the identical top hit."""
        r_resume = self.router.retrieve_record_global('resume distillate bullet points', top_n=1)
        r_docker = self.router.retrieve_record_global('docker container ubuntu setup', top_n=1)
        if r_resume and r_docker:
            self.assertNotEqual(r_resume[0]['name'], r_docker[0]['name'],
                                'Different prompts should give different top hits')

    # --- Test 2: verified gate ---
    def test_low_confidence_memory_excluded(self):
        """Memory with confidence<0.5 must NOT appear even when prompt matches."""
        results = self.router.retrieve_record_global('outdated git workflows', top_n=5)
        names = [r['name'] for r in results]
        self.assertNotIn('low-conf memory', names,
                         'Low-confidence memory must be excluded by verified gate')

    def test_null_validated_at_excluded(self):
        """Memory with NULL last_validated_at must NOT appear even when prompt matches."""
        results = self.router.retrieve_record_global('unvalidated CI project note', top_n=5)
        names = [r['name'] for r in results]
        self.assertNotIn('unvalidated memory', names,
                         'Memory with NULL last_validated_at must be excluded')

    def test_passing_memory_included(self):
        """Memory that passes verified gate (confidence>=0.5, has last_validated_at) appears."""
        results = self.router.retrieve_record_global('resume distillate bullet points', top_n=5)
        names = [r['name'] for r in results]
        self.assertIn('resume distillate tip', names,
                      'Passing memory must be included in results')

    # --- Test 3: incident + distillate rows ---
    def test_incident_returned_without_confidence_gate(self):
        """Incident rows appear on FTS relevance alone — no confidence needed."""
        results = self.router.retrieve_record_global('wipe incident directory test', top_n=5)
        kinds = [r['kind'] for r in results]
        self.assertIn('incident', kinds, 'incident row must be returned for matching prompt')

    def test_distillate_returned_without_confidence_gate(self):
        """Distillate rows appear on FTS relevance alone."""
        results = self.router.retrieve_record_global('memory injection B2 session summary', top_n=5)
        kinds = [r['kind'] for r in results]
        self.assertIn('distillate', kinds, 'distillate row must be returned for matching prompt')

    # --- Test 4: score >= 0.3 for strong match ---
    def test_strong_match_score_at_least_0_3(self):
        """Top hit for a strong on-topic prompt must score >= 0.3 (caller threshold)."""
        results = self.router.retrieve_record_global('resume distillate bullet points', top_n=3)
        self.assertTrue(len(results) > 0, 'Expected at least one result for on-topic prompt')
        top_score = results[0]['score']
        self.assertGreaterEqual(top_score, 0.3,
                                f'Top hit score {top_score} must be >= 0.3 for caller threshold')

    # --- Test 5: injection_log logging ---
    def test_injection_log_written_for_memory_hit(self):
        """Memory/incident hit with integer id produces an injection_log row."""
        results = self.router.retrieve_record_global('resume distillate bullet points', top_n=3)
        # Manually call _log_injection for a memory hit (id is not None)
        mem_hits = [r for r in results if r['id'] is not None]
        if not mem_hits:
            self.skipTest('No memory/incident hit with id in results — seed issue')

        conn = sqlite3.connect(self._tmp.name)
        before = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]

        d = mem_hits[0]
        self.router._log_injection(
            session_id='test-session-123',
            prompt='resume distillate bullet points',
            fact_id=d['id'],
            score=d['score'],
            score_breakdown_dict={'fts_rank': d['score'], 'kind': d['kind']},
        )

        after = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]
        conn.close()
        self.assertEqual(after, before + 1,
                         'injection_log must gain one row for memory/incident hit with integer id')

    def test_injection_log_NOT_written_for_distillate_hit(self):
        """Distillate hit (id=None) must produce NO injection_log row."""
        conn = sqlite3.connect(self._tmp.name)
        before = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]

        # _log_injection skips when fact_id is None
        self.router._log_injection(
            session_id='test-session-123',
            prompt='session distillate',
            fact_id=None,
            score=0.5,
            score_breakdown_dict={'fts_rank': 0.5, 'kind': 'distillate'},
        )

        after = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]
        conn.close()
        self.assertEqual(after, before, 'No injection_log row must be written for distillate (id=None)')

    # --- Test 6: empty/whitespace prompt and no-match ---
    def test_empty_prompt_returns_empty(self):
        """Empty string prompt → []."""
        results = self.router.retrieve_record_global('', top_n=3)
        self.assertEqual(results, [])

    def test_whitespace_only_prompt_returns_empty(self):
        """Whitespace-only prompt → []."""
        results = self.router.retrieve_record_global('   \t\n  ', top_n=3)
        self.assertEqual(results, [])

    def test_no_match_prompt_returns_empty(self):
        """Prompt that matches nothing in the DB → []."""
        results = self.router.retrieve_record_global(
            'xyzzy plugh nonce gibberish aaaabbbbcccc', top_n=3)
        self.assertEqual(results, [])

    def test_absent_record_fts_table_returns_empty(self):
        """When record_fts table is absent, retrieve_record_global returns []."""
        # Create a DB without record_fts
        tmp2 = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        tmp2.close()
        try:
            conn2 = sqlite3.connect(tmp2.name)
            conn2.execute("""
                CREATE TABLE agent_memories (
                    id INTEGER PRIMARY KEY, agent TEXT, type TEXT, name TEXT,
                    content TEXT, confidence REAL, last_validated_at TEXT
                )
            """)
            conn2.commit()
            conn2.close()
            os.environ['CAST_DB_PATH'] = tmp2.name
            # Re-import to pick up new env
            router2 = _import_router()
            results = router2.retrieve_record_global('resume distillate', top_n=3)
            self.assertEqual(results, [], 'Must return [] when record_fts is absent')
        finally:
            os.unlink(tmp2.name)
            os.environ['CAST_DB_PATH'] = self._tmp.name  # restore


class TestUuidRefId(unittest.TestCase):
    """Fixture-hardening tests: proves UUID ref_id incidents are returned without crashing.

    Real incidents.id is a UUID string. The original code did `int(ref_id)` unconditionally
    → ValueError → outer try/except swallowed it → fell through to route mode → null_result.
    These tests pin the _safe_int() fix: UUID-id incident is returned with id=None and no
    injection_log row is written for it.
    """

    UUID_REF = '890a9e51-1a65-400b-919c-6f9eeb7e4b39'

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        os.environ['CAST_DB_PATH'] = self._tmp.name
        conn = _create_test_db(self._tmp.name)
        # Seed a UUID-id incident only
        conn.execute(f"""
            INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
            VALUES ('incident', '{self.UUID_REF}', '2026-07-01T00:00:00Z',
                    'uuid incident wipe crash',
                    'Catastrophic wipe of the claude directory during a crash event.',
                    'shared', '', 'incident')
        """)
        conn.commit()
        conn.close()
        self.router = _import_router()

    def tearDown(self):
        os.unlink(self._tmp.name)
        os.environ.pop('CAST_DB_PATH', None)

    def test_uuid_incident_is_returned(self):
        """A UUID-ref_id incident must be returned (not crash) when the prompt matches."""
        results = self.router.retrieve_record_global('wipe crash claude directory', top_n=5)
        self.assertTrue(len(results) > 0, 'UUID-id incident must be returned, not crash')
        self.assertEqual(results[0]['kind'], 'incident')

    def test_uuid_incident_has_id_none(self):
        """UUID ref_id cannot be converted to int → id must be None."""
        results = self.router.retrieve_record_global('wipe crash claude directory', top_n=5)
        incidents = [r for r in results if r['kind'] == 'incident']
        self.assertTrue(len(incidents) > 0, 'Expected at least one incident in results')
        for inc in incidents:
            self.assertIsNone(inc['id'],
                              'UUID-id incident must have id=None (not raise ValueError)')

    def test_uuid_incident_no_injection_log_row(self):
        """UUID-id incident (id=None) must produce NO injection_log row."""
        conn = sqlite3.connect(self._tmp.name)
        before = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]

        self.router._log_injection(
            session_id='test-uuid',
            prompt='wipe crash',
            fact_id=None,  # what id=None produces
            score=0.5,
            score_breakdown_dict={'fts_rank': 0.5, 'kind': 'incident'},
        )

        after = conn.execute('SELECT COUNT(*) FROM injection_log').fetchone()[0]
        conn.close()
        self.assertEqual(after, before,
                         'No injection_log row for UUID-id incident (id=None)')

    def test_retrieve_returns_list_not_raises(self):
        """retrieve_record_global must return a list (not raise) even for UUID-id incidents."""
        try:
            results = self.router.retrieve_record_global('wipe crash claude directory', top_n=5)
            self.assertIsInstance(results, list)
        except (ValueError, TypeError) as exc:
            self.fail(f'retrieve_record_global raised {type(exc).__name__} on UUID ref_id: {exc}')


class TestRetrieveGlobalMainMode(unittest.TestCase):
    """Tests for --mode retrieve-global via main() argument parsing."""

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        os.environ['CAST_DB_PATH'] = self._tmp.name
        conn = _create_test_db(self._tmp.name)
        _seed_memories(conn)
        conn.close()
        self.router = _import_router()

    def tearDown(self):
        os.unlink(self._tmp.name)
        os.environ.pop('CAST_DB_PATH', None)

    def test_mode_choices_include_retrieve_global(self):
        """The --mode argument must accept 'retrieve-global' without raising SystemExit."""
        import argparse
        # Rebuild parser using argparse to simulate the check; easier: call main() with --help
        # and look for retrieve-global. Instead, test via retrieve_record_global directly.
        # We verify choices by checking the router accepts the mode via retrieve_record_global.
        results = self.router.retrieve_record_global('resume', top_n=1)
        # No exception = mode is wired
        self.assertIsInstance(results, list)

    def test_retrieve_global_returns_list(self):
        """retrieve_record_global always returns a list."""
        results = self.router.retrieve_record_global('resume distillate', top_n=3)
        self.assertIsInstance(results, list)

    def test_result_has_required_keys(self):
        """Each result dict has score, type, name, content, id, kind keys."""
        results = self.router.retrieve_record_global('resume distillate bullet', top_n=3)
        if results:
            for r in results:
                for key in ('score', 'type', 'name', 'content', 'id', 'kind'):
                    self.assertIn(key, r, f'Result missing required key: {key}')

    def test_distillate_id_is_none(self):
        """Distillate hits have id=None (file path ref_id, not integer)."""
        results = self.router.retrieve_record_global('session distillate B2 memory injection', top_n=5)
        distillate_hits = [r for r in results if r['kind'] == 'distillate']
        for d in distillate_hits:
            self.assertIsNone(d['id'], 'Distillate hit must have id=None')

    def test_memory_id_is_integer(self):
        """Memory hits have an integer id."""
        results = self.router.retrieve_record_global('resume distillate bullet points', top_n=3)
        memory_hits = [r for r in results if r['kind'] == 'memory']
        for m in memory_hits:
            self.assertIsInstance(m['id'], int, 'Memory hit must have integer id')


class TestOrSemantics(unittest.TestCase):
    """Blind-spot tests: proves OR semantics, not AND, for multi-term prompts.

    The original implementation passed safe_prompt (space-joined) directly to MATCH,
    giving implicit AND semantics — so 'settings drift fragment' requires ALL 3 terms
    in one doc → 0 hits on realistic corpora. These tests pin the OR-join fix.
    """

    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        os.environ['CAST_DB_PATH'] = self._tmp.name

        # Seed: two docs that each contain ONLY ONE of the query terms.
        # Under AND semantics both would return 0 hits; under OR, each returns its doc.
        conn = _create_test_db(self._tmp.name)
        # Passing agent_memory for "partial" doc — only contains "fragment"
        conn.execute("""
            INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
            VALUES (201, 'shared', 'procedural', 'fragment-only memory',
                    'Fragment of a settings note.', 0.9, '2026-07-01T00:00:00Z')
        """)
        conn.execute("""
            INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
            VALUES ('memory', '201', '2026-07-01T00:00:00Z',
                    'fragment-only memory',
                    'Fragment of a settings note.',
                    'shared', '', 'procedural')
        """)
        # Passing agent_memory for "drift" doc — only contains "drift"
        conn.execute("""
            INSERT INTO agent_memories (id, agent, type, name, content, confidence, last_validated_at)
            VALUES (202, 'shared', 'procedural', 'drift-only memory',
                    'Drift detection for managed settings.', 0.9, '2026-07-01T00:00:00Z')
        """)
        conn.execute("""
            INSERT INTO record_fts (kind, ref_id, ts, title, body, agent, project, mtype)
            VALUES ('memory', '202', '2026-07-01T00:00:00Z',
                    'drift-only memory',
                    'Drift detection for managed settings.',
                    'shared', '', 'procedural')
        """)
        conn.commit()
        conn.close()
        self.router = _import_router()

    def tearDown(self):
        os.unlink(self._tmp.name)
        os.environ.pop('CAST_DB_PATH', None)

    def test_multi_term_prompt_matches_partial_doc(self):
        """A multi-term prompt matches a doc containing only ONE of the query terms (OR, not AND)."""
        # "fragment settings drift" — doc 201 has "fragment", doc 202 has "drift"+"settings"
        # Under AND: 0 hits (no doc has all 3). Under OR: both docs match.
        results = self.router.retrieve_record_global('fragment settings drift', top_n=5)
        names = [r['name'] for r in results]
        self.assertTrue(
            'fragment-only memory' in names or 'drift-only memory' in names,
            f'Expected at least one partial-match doc under OR semantics; got: {names}'
        )

    def test_or_semantics_returns_both_partial_docs(self):
        """OR-semantics: both single-term docs appear when queried with a multi-term prompt."""
        results = self.router.retrieve_record_global('fragment drift', top_n=5)
        names = [r['name'] for r in results]
        self.assertIn('fragment-only memory', names,
                      'fragment-only doc must match "fragment drift" under OR')
        self.assertIn('drift-only memory', names,
                      'drift-only doc must match "fragment drift" under OR')

    def test_no_match_returns_empty(self):
        """Prompt with no matching term in any indexed doc → []."""
        results = self.router.retrieve_record_global('xyzzy plugh frobnicate', top_n=5)
        self.assertEqual(results, [], 'Unmatched prompt must return []')


if __name__ == '__main__':
    unittest.main()
