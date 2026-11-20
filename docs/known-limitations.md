# CAST — Known Limitations

This document records framework-level limitations that are not bugs but rather constraints of the Claude Code runtime that CAST works around.

---

## 1. SendMessage Gap — Orchestrate Skill Cannot Resume After Network Drop

> **Resolved (partially) 2026-04-16:** The orchestrator agent was retired. Plan execution now runs via the `/orchestrate` skill in the main session, which eliminates the subagent-specific SendMessage gap. However, if the main session itself is dropped mid-execution, the same constraint applies to any subagent it has dispatched.

> **Partially resolved — v7 Phase 1 (2026-05-08):** Three additional friction points were addressed: (1) `push`, `install`, and `compact` operations now run with `bypassPermissions` mode so agent-initiated pushes no longer stall mid-chain waiting for user approval; (2) PII redaction via `cast-redact.py` prevents session tokens and API keys from being logged to `cast.db` or hook output, reducing the blast radius of a dropped/replayed session; (3) the `pre_approved: true` manifest flag is now the documented default for long-running plans. The core gap — inability to resume a dropped subagent session — remains open at the Claude Code runtime level.

> **⚠️ Correction — 2026-08-26 (v10 SEC-3):** Point (1) above is false as of this date, and the mechanism
> it names is narrower than it sounds. **`push`, `install` and `compact` do NOT run with
> `bypassPermissions`** — `agents/core/morning-briefing.md:12` is the only agent in the repo carrying
> `permissionMode: bypassPermissions` (grepped repo-wide). Separately, `bypassPermissions` does **not**
> disable `permissions.ask` gates: the Claude Code docs state that tools matched by an explicit ask rule
> are among the "actions no mode auto-approves … including `bypassPermissions`", that "Deny rules block in
> every mode, including `bypassPermissions`", and that a PreToolUse hook exiting 2 "stops the tool call
> before permission rules are evaluated". What `bypassPermissions` *does* disable is the built-in
> **protected-paths** protection. The real hook-removal mechanism is **`--bare`**, not `bypassPermissions`.
> See `plans/next-session.md` → SEC-3.

**Symptom:** If the main session is dropped mid-execution (network error, timeout, process kill), dispatched specialist subagents cannot be resumed via `SendMessage`.

**Root cause:** Claude Code's `Agent` tool does not expose a `SendMessage` / continuation mechanism for already-running subagent contexts. When a subagent's session ends, it ends permanently.

**Workaround:**
1. The `/orchestrate` skill writes a checkpoint to `~/.claude/cast/orchestrator-checkpoint.log` after each completed batch.
2. On re-invocation via `/orchestrate`, the skill reads the checkpoint and skips all batches already completed.
3. Use `"pre_approved": true` in the Agent Dispatch Manifest to bypass the confirmation gate on restart — this avoids the user needing to re-approve the queue.

**Example restart flow:**
```bash
# Re-invoke /orchestrate with the same plan file path
# It will read orchestrator-checkpoint.log and resume from the last completed batch
```

---

## 2. Nested agent dispatch is disabled (CAST pins depth 1)

> **Status as of 2026-11-20:** Intentional. Native nesting has changed across Claude Code releases: subagents could spawn subagents up to 5 levels in 2.1.172; nesting was off by default in 2.1.217; and since 2.1.219 the native default depth is 3 (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`). CAST pins `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` in `managed-settings.d/00-env.json` regardless of the native default.

**Symptom:** A dispatched agent has no `Agent` tool, so it cannot spawn its own agents. Self-dispatch chains (e.g. `backend-writer` dispatching `code-reviewer`) do not run.

**Root cause:** By design. CAST pins depth 1 on purpose: a dispatched agent cannot spawn its own agents, so the dispatching session runs the review gate.

**Workaround:** The dispatching session dispatches reviewers and commits.

**Detection:** Parse the agent's `Status:` block. If no chain confirmation is present and the agent was expected to self-dispatch, re-dispatch inline.

---

## 3. Turn Limit — Main Session Ceiling During Plan Execution

> **Updated 2026-04-16:** The orchestrator agent was retired. Plan execution now runs via the `/orchestrate` skill in the main session. The turn ceiling now applies to the main session itself when executing long manifests.

**Symptom:** Main sessions running a long Agent Dispatch Manifest (many batches) approaching turn 50 risk orphaning mid-execution with no automatic resume.

**Root cause:** Claude Code sessions have a hard turn ceiling (~50 turns). There is no `SendMessage` continuation mechanism for an in-progress session.

**Workaround:**
- When approaching turn 40, write the checkpoint log and stop cleanly.
- Re-invoke `/orchestrate` with the same plan file path to resume from the last completed batch.
- Manifests with many batches should use `"pre_approved": true` to minimize turns spent on confirmation.
