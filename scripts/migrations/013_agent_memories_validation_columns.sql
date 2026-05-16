-- Migration 013: add validation/retrieval tracking columns to agent_memories.
-- Idempotent via try/except in the runner. Closes correction #2 (audit 2026-05-16).
ALTER TABLE agent_memories ADD COLUMN last_validated_at TEXT;
ALTER TABLE agent_memories ADD COLUMN retrieval_count INTEGER DEFAULT 0;
