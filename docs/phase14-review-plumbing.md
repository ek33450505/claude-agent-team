# CAST Internal-Review Plumbing — Root Cause Analysis

> Added in v7.5 Phase 14. Describes why self-dispatched `code-reviewer` approval rows
> do not consistently land in the CAST state store, and what the commit gate does about it.

---

## Symptom

The commit agent's `cast_check_approvals` gate finds no approval record after a `code-writer`
self-dispatches `code-reviewer`. Two commit agents in the same session can produce different
outcomes (one skips the gate, one hard-blocks) for an identical absent-approval state.

---

## System Overview

The approval chain has three parts:

1. **`cast_write_review`** (`scripts/cast-events.sh`): Writes
   `~/.claude/cast/reviews/{artifact_id}-{reviewer}-{timestamp}.json` and emits a
   `review_submitted` event keyed by `TASK_ID`. Note: `code-reviewer` passes its own
   `TASK_ID` env var as the `artifact_id` parameter — so the review file is keyed by
   the reviewer's task_id, not by a file path or code artifact identifier.
2. **`cast_derive_state`** (`scripts/cast-events.sh`): Replays events matching
   `*-*-{task_id}.json`, builds an `artifact_ids` list from `artifact_written` events,
   then collects reviews for those artifact_ids.
3. **`cast_check_approvals`** (`scripts/cast-events.sh`): Calls `cast_derive_state`,
   reads the state file's `approvals` list, exits 0/1/2.

---

## Root Causes (three layered)

### Root Cause 1 (PRIMARY): Subagent nesting depth blocks self-dispatch

When `code-writer` runs as an orchestrator subagent, dispatching `code-reviewer` via the
Agent tool exceeds the nesting limit. The dispatch silently fails or is never attempted —
the review bash command never runs, and no review file is written.

`agents/core/code-writer.md` acknowledges this explicitly: "If the Agent tool dispatch
fails at this depth (e.g., max nesting), do NOT narrate a dispatch that did not occur."

This is why `code-writer` in plan-based dispatch mode returns `Status: DONE` with a
`## Recommended Next Agents` section rather than self-dispatching the reviewer — the
orchestrator handles it in the next batch.

### Root Cause 2 (SECONDARY): TASK_ID is not propagated to the reviewer

`agents/core/code-reviewer.md` writes:

```bash
cast_write_review "${TASK_ID:-batch-manual}" "code-reviewer" "approved" "Review complete" ""
```

When dispatched as a subagent, the harness assigns the reviewer its own `TASK_ID` — it
does not inherit the outer `code-writer` task's ID. `TASK_ID` defaults to `batch-manual`.
The review file is written as `batch-manual-code-reviewer-TIMESTAMP.json`.

Later, `cast_check_approvals(outer-task-id)` calls `cast_derive_state(outer-task-id)`,
which finds no events or reviews matching that ID. The approvals list is empty → exit 1.

### Root Cause 3 (TERTIARY): code-writer emits no `artifact_written` events

`cast_derive_state` builds the `artifact_ids` list only from `artifact_written` events.
`code-writer` never calls `cast_emit_event "artifact_written" ...`. Even if Root Cause 2
were fixed, `cast_derive_state` would see an empty `artifact_ids` list for the task and
match zero review files.

---

## Diverging Commit Agents (live evidence)

Two commit agents responded differently to the same absent-approval state because the
previous fallback used a fragile string-search: "if 'DONE' and 'code-reviewer' appear
in the prompt context, treat as approved." Different prompt framings produced different
search results — one agent found the strings and skipped the gate; the other did not
and hard-blocked.

---

## Fix Applied

`agents/core/commit.md` Approval Gate fallback was changed from the fragile string-search
to a visible WARN that always proceeds:

> `[WARN] No approval record found for task_id=<value> — proceeding with commit.
> Ensure code-reviewer ran before this commit. If this is a repeated miss, the
> review-dispatch plumbing may need investigation (see docs/phase14-review-plumbing.md).`

The WARN appears in the terminal output and in the commit message body. It does not
hard-block direct-dispatch commits (which legitimately have no task_id).

---

## Root Cause 4 (2026-07-22): the file-based state store is unreachable for Agent-tool dispatches

Root Causes 1–3 share one consequence: in an ad-hoc session where the orchestrating main
session dispatches `code-reviewer` and `commit` via the **Agent tool** (not a DB-tracked
`/orchestrate` task), there is no `TASK_ID` to thread and no `artifact_written` event to link
a task to its reviews. `cast_derive_state` builds an empty `artifact_ids` list and collects
zero reviews — every real, passing review lands in the generic `batch-manual` sink (441 files
as of 2026-07-22) the gate can never reach. `cast_check_approvals` returns exit 1
("Missing approvals") for every commit, forcing the human onto a raw `CAST_COMMIT_AGENT=1 git commit`.

Threading a real `TASK_ID` (old Future Work item 3) does not fix this: the harness does not
propagate `TASK_ID` into Agent-tool subagents, and even a correct `TASK_ID` still hits Root
Cause 3 (no `artifact_written` event → empty `artifact_ids`).

## Fix Applied (2026-07-22): session-scoped `agent_runs` fallback

`cast_check_approvals` now falls through to a **session-scoped `agent_runs` query** when the
file-based state yields no approval for a required reviewer. `agent_runs` is populated
automatically by the `SubagentStart`/`SubagentStop` hooks per dispatch — independent of any
`TASK_ID` — so it records "a `code-reviewer` ran in this session" reliably and tamper-evidently.

For each still-missing reviewer, the fallback selects the most-recent *decisive* row
(`status IN (DONE, DONE_WITH_CONCERNS, completed, BLOCKED)`) for `(session_id, agent)` and applies:

- **freshness window** — the row's `ended_at` must be within `CAST_APPROVAL_WINDOW_MIN` minutes
  (default 120), checked in Python against a UTC cutoff (robust to `T`/space/`Z` timestamp variants);
- **branch guard** — when both the row's `branch` and the current branch are known, they must
  match (skipped when either is unknown, since `branch` is ~52% populated);
- **status mapping** — `DONE`/`DONE_WITH_CONCERNS`/`completed` = approved; `BLOCKED` = rejected
  (exit 2); `failed`/`abandoned`/`running`/absent = missing (exit 1).

This is **strictly safer** than the file path it backstops: it survives reviewer truncation
(the hook writes the row even when the agent hits `maxTurns` and never reaches its "Mandatory
Final Step"), it is session-scoped (a prior session's reviews cannot leak in), and it captures
the `BLOCKED` rejection signal the `batch-manual` sink discarded. Session id resolves via
`CAST_SESSION_ID` → `CLAUDE_SESSION_ID`; with neither, the fallback fails **closed** (missing),
never open. The file-based path runs first and is unchanged, so task-tracked `/orchestrate`
runs are unaffected. Env knob: `CAST_APPROVAL_WINDOW_MIN`. Regression coverage:
`tests/cast-events.bats` Section 7.

---

## Future Work

1. Enforce orchestrator-only reviewer dispatch (already the plan-based convention;
   deprecate self-dispatch in direct mode too).
2. Add `cast_emit_event "artifact_written"` calls in `code-writer` after each file edit.
3. Investigate harness-level `TASK_ID` propagation for Agent tool dispatches.
4. `agents/core/code-writer.md` review dispatch template now includes
   `Task context: TASK_ID=[value]` in the prompt — sets up future harness propagation
   without requiring changes today.

---

## Known Limitations

The stale-context guard (added in `skills/cast-conventions/SKILL.md`) is a heuristic
against context-replay misfires and has three residual bypass paths:

1. **File-content injection:** content inside a file being processed (e.g., a plan or
   log file) could embed trigger-matching text — the guard cannot distinguish injected
   prose from genuine prior-output context.
2. **Recycled-content fresh dispatch:** an orchestrator that includes prior session
   output verbatim in a new dispatch prompt bypasses the "same agent instance" criterion
   (the agent sees a fresh dispatch, not its own prior output).
3. **String-trigger in docs/examples** *(now mitigated)*: bare "Status: DONE" appearing
   in loaded docs or examples could previously fire the over-broad trigger; the rewritten
   guard requires the string to appear in *this agent instance's own prior final response*
   for a materially identical task, which eliminates the docs/Work-Log false-positive class.
