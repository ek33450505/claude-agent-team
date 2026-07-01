# cast.db Schema Rationale

Decoder ring for tables in `cast.db` that otherwise look confusing or overlapping in the /db browser.
Generated 2026-05-17 from the 2026-05-16 audit (see `~/.claude/plans/cast-agent-team-corrections-2026-05-16.md`).

## Three "dispatch" tables (closes Correction #6)

The cast.db has three tables with overlapping names but non-overlapping concerns:

| Table | Writer | What it tracks |
|---|---|---|
| `routing_events` | All hook scripts | **General hook-event log** despite the name. The naming predates the dispatch refactor. |
| `dispatch_decisions` | `/orchestrate` skill (LLM-driven) | One row per `/orchestrate` plan dispatched. Schema dropped richer fields in v6→v7. |
| `dispatch_events` | `scripts/cast-cookbook-drift.sh` | Single cron-job audit trail. Currently invisible in /db browser. |

> **Note:** Earlier revisions of this doc included absolute per-table row counts. Row counts are environment-specific and drift over time, so they have been removed — the qualitative active/dormant distinction per table is what matters here.

**Recommended long-term renames** (post v7.1 scope): `routing_events` → `hook_events`, `dispatch_decisions` → `orchestrate_invocations`, `dispatch_events` → `scheduled_dispatches`. Not done in v7.1 because rename migrations are riskier than warranted.

## Failure-tracking table pairs (closes Correction #12)

Two pairs of conceptually overlapping tables:

### `agent_truncations` vs `completeness_events`

Both capture "incomplete agent responses" but via different writer paths:
- `agent_truncations` — written by `cast-subagent-stop-hook.sh` when no Status block is detected in a sub-agent response.
- `completeness_events` — written by `cast-response-completeness-hook.sh` on `SubagentStop`, broader heuristic that includes response shape, not just Status block presence.

The two tables answer slightly different questions. Kept separate to preserve writer simplicity.

### `agent_hallucinations` vs `code_ref_checks`

Both capture "agent claim vs reality" mismatches but at different granularity:
- `agent_hallucinations` — file-level: agent claimed to write `/path/to/file` but the file doesn't exist post-stop.
- `code_ref_checks` — symbol-level: agent referenced a function/class name that doesn't exist in the codebase.

Kept separate to allow different remediation paths (hallucinations are usually agent errors; code_ref mismatches can be stale memory).

## `incidents` table (closes Correction #17)

`incidents` is the canonical retrospective post-mortem table. Manually-recorded incidents (currently 17 rows from CLI + backfill). Reader will be added to cast-desktop in a future iteration; for now the audit/correction file workflow in `~/.claude/plans/` serves the same purpose. This table is NOT auto-populated by hooks — it's deliberate human input.

## Swarm tables (closes Correction #21)

`swarm_sessions` and `teammate_runs` are dormant — the `/swarm` writers were retired in v9. Tables are retained as historical schema record; zero rows is CORRECT. The /db browser should show a tooltip indicating "dormant — /swarm writers retired in v9."

`teammate_messages` was **retired in v9 Phase C (U7a)** — removed from canonical schema (`cast-db-init.sh`) and all script references. Physical DROP from the live DB is a separate gated maintenance step (the empty table may linger on existing installs; `cast-db-contract.py` stays GREEN once all code references are removed).

`stream_events` was also **retired in v9 Phase C (U7a)** — 0 rows, no writers since the stream-JSON pipeline was decommissioned.

## `dispatch_events` placement (closes Correction #5)

`dispatch_events` should appear in cast-desktop's /db browser GROUP_MAP under a "Scheduled Jobs" group when added. Until then it is invisible in the UI but still receives writes from `cast-cookbook-drift.sh`. Decision: keep, surface later.

## `schema_migrations` dual-runner drift (discovered 2026-05-17 during P2 pre-flight)

The live cast.db `schema_migrations` table has schema **`(version TEXT PRIMARY KEY, applied_at TEXT, checksum TEXT)`** — created by the original `scripts/cast-migrate.sh` runner. A newer `scripts/cast-migrate.py` runner was added in v7 but creates an INCOMPATIBLE schema **`(id INTEGER PK, migration_name TEXT UNIQUE, applied_at TEXT)`** via its own `CREATE TABLE IF NOT EXISTS`.

**Symptom:** the python runner's INSERT references `migration_name`, which doesn't exist on the bash-created live table. So `cast-migrate.py` only works on fresh DBs (CI test DB) and silently breaks on the live DB.

**Impact on the live DB:** the migration's ALTER/CREATE statements still apply successfully; only the INSERT that records the migration into `schema_migrations` fails (no such column: migration_name). So schema drift does not accumulate — the audit trail simply lags. Migrations themselves apply cleanly; the `schema_migrations` table just does not log them via the python runner.

**Backfill in Phase 2 #18:** uses the LIVE bash schema. Does NOT attempt to reconcile the two runners.

**Resolved (PR #114):** `cast-db-init.sh` now provisions `schema_migrations` directly using the bash shape `(version TEXT PRIMARY KEY, applied_at TEXT, checksum TEXT)` and is the single source of truth for the schema. The dual-runner drift is closed — init handles schema migrations at install time; neither bash runner nor python runner needs to reconcile independently. The python runner's incompatible schema `(id INTEGER PK, migration_name TEXT UNIQUE, applied_at TEXT)` remains on disk but is not invoked by install. If the python runner is retained for other purposes, its CREATE TABLE statement should be made compatible with the bash shape to avoid confusion on fresh DBs.

## Orphan columns (v9 Phase C note)

Several columns were **dropped from the canonical schema** (`cast-db-init.sh`) but **linger empty on existing live DBs** because SQLite column-drop requires a full table rebuild (DDL: `ALTER TABLE DROP COLUMN` is SQLite ≥ 3.35, but the rebuild risk is high for observability tables). Code sources these columns via `PRAGMA table_info()` guards rather than hard-referencing them. They are intentionally NOT physically dropped:

- `sessions.total_input_tokens`, `sessions.total_output_tokens`, `sessions.total_cost_usd`, `sessions.model` — dropped from canonical in migration 022 wave-3; zero values on live.
- `agent_runs.project`, `agent_runs.prompt` — dropped from canonical in migration 022 wave-3; code uses `sessions JOIN` to source project instead.

These are not SAFE-DROP candidates in `db-contract` because they exist only on live DBs, not in the canonical init (they never appear as missing writers/readers). If physical column removal is ever needed, it requires a backed-up table-rebuild step.

---

*This doc is maintained alongside cast.db schema evolution. When adding a new table, add a section here explaining its intent if the name isn't self-evident.*
