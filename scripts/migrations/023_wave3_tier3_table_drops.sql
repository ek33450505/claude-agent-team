-- Migration 023: Drop Tier-3 write-only tables (Wave-3 Inc 2)
-- batch_dispatches, contract_test_runs, files_api_events:
--   verified 0 rows in live DB, no readers in bin/cast / scripts/ / cast-desktop,
--   no indexes, created only in cast-db-init.sh. Writers removed in lockstep.
DROP TABLE IF EXISTS batch_dispatches;
DROP TABLE IF EXISTS contract_test_runs;
DROP TABLE IF EXISTS files_api_events;
