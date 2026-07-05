# Agent Response Capture — Decision Record

**Date:** 2026-05-04  
**Migration:** 011  
**Files changed:** `scripts/migrations/011_agent_response_capture.sql`, `scripts/cast-subagent-stop-hook.sh`, `scripts/cast-db-init.sh`

## What was added

`agent_runs.response TEXT` — stores the agent's full output text captured at SubagentStop time. Populated going forward only; historical rows are NULL.

## Payload field mapping

The SubagentStop hook payload has two distinct paths for agent output depending on dispatch mode:

| Dispatch path | Payload field | Notes |
|---|---|---|
| Phase C (structured) | `agent_response.content[]` — list of `{type, text}` blocks | Used by `cast_subagent_stop.py` (truncation + protocol stages) |
| Older / flat | `last_assistant_message` or `output` or `body` | Used by the main `cast-subagent-stop-hook.sh` before this change |

The hook now tries the structured path first (joining all `type=text` blocks), then falls back to the flat fields. This single unified `response_text` is written to `agent_runs.response` and also used for truncation detection.

## Why truncation underrecording happened

`agent_truncations` had only 2 rows despite known truncations because:

1. The old per-script truncation check (now consolidated into `cast_subagent_stop.py`) only read `agent_response.content` (structured path)
2. It was only called by `cast-subagent-worktree-check.sh`
3. `cast-subagent-worktree-check.sh` was only dispatched for a subset of agents
4. All other agents hit the main hook but it had no truncation logging

## Fix applied (consolidated)

`cast_subagent_stop.py` (truncation stage, §2 stage 4) merges both paths: it logs truncations to `agent_truncations` for ALL agents using the unified `response_text`, eliminating the previous double-write (old Step 2.1 in the main hook + `cast-truncation-check.sh`) and the subset-only gap. The `cast-truncation-check.sh` script has been deleted.

## Column idempotency

The `response` column is added via:
- `ALTER TABLE agent_runs ADD COLUMN response TEXT` wrapped in `try/except` in the hook's Python block
- A `grep`-guarded `ALTER` in the `cast-db-init.sh` self-heal block
- `scripts/migrations/011_agent_response_capture.sql` for documentation
