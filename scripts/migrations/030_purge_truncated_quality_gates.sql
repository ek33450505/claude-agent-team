-- Migration 030: Purge quality_gates truncation-mirror rows
-- Root cause: cast_subagent_stop.py stage4 wrote a quality_gates row
--   (status_line='TRUNCATED', gate_type='truncation_detected') mirroring every
--   agent_truncations row (380 rows on the live DB). Those conflate truncations
--   with real review gates and pollute gate/reviewer-rejection metrics (P5).
-- The producer mirror INSERT is removed in this same change; agent_truncations
--   remains the authoritative truncation record, so nothing is lost here.
-- Safe to re-run: DELETE WHERE is a no-op once the rows are gone.
DELETE FROM quality_gates WHERE status_line = 'TRUNCATED';
