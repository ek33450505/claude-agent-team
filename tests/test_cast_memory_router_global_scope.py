#!/usr/bin/env python3
"""Tests for the global_scope retrieve mode added to cast-memory-router.py (B2.1).

Covers:
  - global_scope=True returns memories matching an FTS term, filtered to the
    validated pool (last_validated_at IS NOT NULL, valid_to IS NULL, confidence >= 0.5)
  - confidence < 0.5 is EXCLUDED in global scope
  - last_validated_at IS NULL is EXCLUDED in global scope
  - valid_to set (superseded) is EXCLUDED in global scope
  - agent-scope path (default, global_scope=False) is UNCHANGED — still filters by agent

Uses an isolated temp DB (CAST_DB_PATH env var) — never touches ~/.claude/cast.db.
"""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts'
_ROUTER_PATH = _SCRIPTS_DIR / 'cast-memory-router.py'

# Load router via importlib (hyphens in filename prevent normal import)
_spec = importlib.util.spec_from_file_location('cast_memory_router', str(_ROUTER_PATH))
_router_mod = importlib.util.module_from_spec(_spec)


def _setup_temp_db() -> str:
    """Create a minimal agent_memories table (no FTS — tests use fallback path)."""
    fd, path = tempfile.mkstemp(suffix='.db')
    os.close(fd)
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE agent_memories (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            agent             TEXT NOT NULL,
            project           TEXT,
            type              TEXT,
            name              TEXT,
            description       TEXT,
            content           TEXT,
            created_at        TEXT,
            updated_at        TEXT,
            confidence        REAL DEFAULT 1.0,
            importance        REAL DEFAULT 0.5,
            decay_rate        REAL DEFAULT 0.0,
            valid_from        TEXT,
            valid_to          TEXT,
            embedding         BLOB,
            last_validated_at TEXT,
            retrieval_count   INTEGER DEFAULT 0
        );
    """)
    conn.commit()
    conn.close()
    return path


def _insert_memory(db_path: str, **kwargs) -> int:
    """Insert a row into agent_memories, return its id."""
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    defaults = {
        'agent': 'test-agent',
        'project': 'test',
        'type': 'feedback',
        'name': 'test-memory',
        'description': 'test description',
        'content': 'test content',
        'created_at': now,
        'updated_at': now,
        'confidence': 1.0,
        'importance': 0.5,
        'decay_rate': 0.0,
        'valid_from': None,
        'valid_to': None,
        'embedding': None,
        'last_validated_at': now,
        'retrieval_count': 0,
    }
    row = {**defaults, **kwargs}
    cols = ', '.join(row.keys())
    placeholders = ', '.join(['?'] * len(row))
    conn = sqlite3.connect(db_path)
    cursor = conn.execute(
        f"INSERT INTO agent_memories ({cols}) VALUES ({placeholders})",
        list(row.values()),
    )
    mem_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return mem_id


class TestGlobalScopeRetrieve(unittest.TestCase):
    """retrieve_memories with global_scope=True uses the validated pool, not agent filter."""

    def setUp(self) -> None:
        self.db_path = _setup_temp_db()
        os.environ['CAST_DB_PATH'] = self.db_path
        # Reload module so cast_db picks up the new CAST_DB_PATH
        _spec.loader.exec_module(_router_mod)
        self.retrieve = _router_mod.retrieve_memories

    def tearDown(self) -> None:
        os.remove(self.db_path)
        if 'CAST_DB_PATH' in os.environ:
            del os.environ['CAST_DB_PATH']

    def test_global_scope_returns_validated_memory(self) -> None:
        """A validated memory with matching content is returned in global scope."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='code-writer',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.9,
            last_validated_at=now,
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='some-other-agent',
            top_n=5,
            fts_only=True,
            global_scope=True,
        )
        self.assertGreater(len(results), 0, "Expected at least one result in global scope")

    def test_global_scope_excludes_low_confidence(self) -> None:
        """confidence < 0.5 is excluded from global scope."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='code-writer',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.4,  # below threshold
            last_validated_at=now,
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='any-agent',
            top_n=5,
            fts_only=True,
            global_scope=True,
        )
        self.assertEqual(len(results), 0, "confidence < 0.5 should be excluded")

    def test_global_scope_excludes_null_last_validated_at(self) -> None:
        """last_validated_at IS NULL is excluded from global scope."""
        _insert_memory(
            self.db_path,
            agent='code-writer',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.9,
            last_validated_at=None,  # not validated
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='any-agent',
            top_n=5,
            fts_only=True,
            global_scope=True,
        )
        self.assertEqual(len(results), 0, "last_validated_at IS NULL should be excluded")

    def test_global_scope_excludes_superseded(self) -> None:
        """valid_to set (superseded) is excluded from global scope."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='code-writer',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.9,
            last_validated_at=now,
            valid_to=now,  # superseded
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='any-agent',
            top_n=5,
            fts_only=True,
            global_scope=True,
        )
        self.assertEqual(len(results), 0, "superseded memory (valid_to set) should be excluded")

    def test_agent_scope_unchanged_when_global_scope_false(self) -> None:
        """agent-scope path (default) still filters by agent — cross-agent memories excluded."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='code-writer',  # different agent
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.9,
            last_validated_at=now,
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='some-other-agent',  # not code-writer, not shared
            top_n=5,
            fts_only=True,
            global_scope=False,  # default agent scope
        )
        self.assertEqual(len(results), 0,
                         "agent-scope should exclude memories belonging to other agents")

    def test_agent_scope_returns_shared_memories(self) -> None:
        """agent-scope still returns shared-pool memories (agent='shared')."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='shared',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.9,
            last_validated_at=now,
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='any-agent',
            top_n=5,
            fts_only=True,
            global_scope=False,
        )
        self.assertGreater(len(results), 0,
                           "agent-scope should still return shared-pool memories")

    def test_global_scope_confidence_boundary_at_0_5(self) -> None:
        """confidence = 0.5 exactly meets the threshold and IS included."""
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        _insert_memory(
            self.db_path,
            agent='code-writer',
            content='approval gate code reviewer mandatory commit workflow',
            confidence=0.5,  # boundary value — must be included
            last_validated_at=now,
            valid_to=None,
        )
        results = self.retrieve(
            'approval gate code-reviewer commit',
            agent='any-agent',
            top_n=5,
            fts_only=True,
            global_scope=True,
        )
        self.assertGreater(len(results), 0, "confidence = 0.5 should meet the >= 0.5 threshold")


if __name__ == '__main__':
    unittest.main()
