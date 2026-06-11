-- Migration 013: validation + retrieval tracking columns on agent_memories.
-- Closes correction #2 from audit 2026-05-16.
--
-- Self-contained via CREATE TABLE IF NOT EXISTS so this migration runs cleanly
-- against fresh DBs that have not yet had cast-db-init.sh applied (CI test path).
-- Schema mirrors cast-db-init.sh:310 — keep in sync if the canonical schema changes.
-- Both ALTERs are idempotent: the runner tolerates "duplicate column" errors.

CREATE TABLE IF NOT EXISTS agent_memories (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  agent         TEXT NOT NULL,
  project       TEXT,
  type          TEXT,
  name          TEXT,
  description   TEXT,
  content       TEXT,
  created_at    TEXT,
  updated_at    TEXT,
  confidence    REAL DEFAULT 1.0,
  importance    REAL DEFAULT 0.5,
  decay_rate    REAL DEFAULT 0.0,
  valid_from    TEXT,
  valid_to      TEXT,
  embedding     BLOB,
  last_validated_at TEXT,
  retrieval_count   INTEGER DEFAULT 0
);

ALTER TABLE agent_memories ADD COLUMN last_validated_at TEXT;
ALTER TABLE agent_memories ADD COLUMN retrieval_count INTEGER DEFAULT 0;
