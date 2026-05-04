-- Migration 010: Work-Log Stream upstream data hardening
-- Applied by: cast migrate
-- Idempotent: safe to run multiple times

-- Add partial_work_log column to agent_truncations.
-- Stores any ## Work Log section extracted from a truncated agent response,
-- enabling the /work-log dashboard page to show partial work logs for
-- runs that were cut off before emitting a Status block.
-- The column is TEXT (NULL when no ## Work Log section was present in the output).

ALTER TABLE agent_truncations ADD COLUMN partial_work_log TEXT;
