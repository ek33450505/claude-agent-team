# Dispatch DAG Decision — Phase 3 Data Source

**Date:** 2026-05-04
**Task:** 1.3 of Live Work-Log Stream Plan
**Decision:** Phase 3 governance annotations will use `agent_runs.session_id` grouping (NOT `dispatch_decisions`) for dispatched-by / dispatched-to relationships.

---

## Investigation Results

### `dispatch_decisions` row count: 5

Schema:
```
id TEXT PRIMARY KEY
session_id TEXT
timestamp TEXT
dispatch_backend TEXT
plan_file TEXT
```

> **Superseded (v9 S6):** the `dispatch_backend` selection concept was removed — native Agent Teams supersedes coordinator-mode. This block is retained as a historical record.

Sample rows:
- One row per `/orchestrate` plan invocation (e.g., `2026-05-04-live-work-log-stream.md`)
- Written by the `/orchestrate` skill once per plan dispatch

**Conclusion:** `dispatch_decisions` records plan-level dispatch events only. It does NOT track individual agent-to-agent relationships within a plan. It is a log of "which plan was dispatched when," not a DAG.

### `agent_runs.parent_id` column: does not exist

`PRAGMA table_info(agent_runs)` returned 18 columns — no `parent_id`. The DAG parent/child relationship is not currently tracked at the agent_run level.

### `agent_runs` row count: 3,481

Agents within the same session share a `session_id`. This is the only co-location signal available.

---

## Decision

**Phase 3 will use `session_id` grouping for dispatched-by / dispatched-to relationships**, not `dispatch_decisions`.

The DAG reconstruction approach for Phase 3:
1. Group `agent_runs` by `session_id` — all agents dispatched within a session share the same `session_id`.
2. Order by `started_at` within the group — the earliest agent in a session is the orchestrator or root dispatcher.
3. Use `dispatch_decisions.plan_file` to identify which plan drove the session (if available).

**Why not fix `dispatch_decisions`:** The table's schema is designed for plan-level tracking, not agent-level DAG edges. Adding per-agent rows to it would conflict with its current semantic (one-row-per-plan). It would require a schema redesign.

**Future option:** Add `parent_agent_run_id TEXT` column to `agent_runs` so the Agent tool dispatch writes it. This would give a proper DAG. Track as a future enhancement — do NOT implement in Phase 3.

---

## Implication for Phase 2 `WorkLogEntry` Schema

The `dispatchedBy` and `dispatchedTo` fields in `WorkLogEntry` will:
- **Phase 2:** always return `null` (as specced)
- **Phase 3:** be populated via session-group reconstruction (not `dispatch_decisions`)

The `data-annotation-slot` attribute on WorkLogFeed card footer ensures Phase 3 can inject these fields without restructuring the component.
