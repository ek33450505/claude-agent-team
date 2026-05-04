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
| Phase C (structured) | `agent_response.content[]` — list of `{type, text}` blocks | Used by `cast-truncation-check.sh` and `cast-agent-protocol-check.sh` |
| Older / flat | `last_assistant_message` or `output` or `body` | Used by the main `cast-subagent-stop-hook.sh` before this change |

The hook now tries the structured path first (joining all `type=text` blocks), then falls back to the flat fields. This single unified `response_text` is written to `agent_runs.response` and also used for truncation detection.

## Why truncation underrecording happened

`agent_truncations` had only 2 rows despite known truncations because:

1. `cast-truncation-check.sh` only reads `agent_response.content` (structured path)
2. `cast-truncation-check.sh` is only called by `cast-subagent-worktree-check.sh`
3. `cast-subagent-worktree-check.sh` is only dispatched for a subset of agents: `code-writer|debugger|test-writer|security|frontend-qa`
4. All other agents (commit, planner, researcher, etc.) hit the main `cast-subagent-stop-hook.sh` but it had no truncation logging

## Fix applied

Added **Step 2.1** to `cast-subagent-stop-hook.sh` that logs truncations to `agent_truncations` for ALL agents, using the unified `response_text`. This runs in addition to `cast-truncation-check.sh` (which still fires for the worktree-matched agents). The two paths do not double-count because `cast-truncation-check.sh` uses the structured payload field only available on Phase C dispatches.

## Column idempotency

The `response` column is added via:
- `ALTER TABLE agent_runs ADD COLUMN response TEXT` wrapped in `try/except` in the hook's Python block
- A `grep`-guarded `ALTER` in the `cast-db-init.sh` self-heal block
- `scripts/migrations/011_agent_response_capture.sql` for documentation
