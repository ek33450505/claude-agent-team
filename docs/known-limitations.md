# CAST — Known Limitations

This document records framework-level limitations that are not bugs but rather constraints of the Claude Code runtime that CAST works around.

---

## 1. SendMessage Gap — Orchestrate Skill Cannot Resume After Network Drop

> **Resolved (partially) 2026-04-16:** The orchestrator agent was retired. Plan execution now runs via the `/orchestrate` skill in the main session, which eliminates the subagent-specific SendMessage gap. However, if the main session itself is dropped mid-execution, the same constraint applies to any subagent it has dispatched.

> **Partially resolved — v7 Phase 1 (2026-05-08):** Three additional friction points were addressed: (1) `push`, `install`, and `compact` operations now run with `bypassPermissions` mode so agent-initiated pushes no longer stall mid-chain waiting for user approval; (2) PII redaction via `cast-redact.py` prevents session tokens and API keys from being logged to `cast.db` or hook output, reducing the blast radius of a dropped/replayed session; (3) the `pre_approved: true` manifest flag is now the documented default for long-running plans. The core gap — inability to resume a dropped subagent session — remains open at the Claude Code runtime level.

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

## 2. Agent Tool Unavailable at Nesting Depth >= 3

> **Status as of v7 Phase 1 (2026-05-08):** Still accurate. Claude Code enforces nesting depth limits on tool availability and there is no known upstream change to this behavior. The workarounds below remain the recommended mitigations.

**Symptom:** Agents nested 3+ levels deep (main session → specialist agent → sub-agent) may not have access to the `Agent` tool, causing self-dispatch chains to silently fail.

**Root cause:** Claude Code imposes a nesting depth limit on tool availability. The `Agent` tool is restricted in deeply nested subagent contexts.

**Workaround:**
- The main session acts as fallback enforcer: it checks each agent's response for the expected downstream dispatch confirmation.
- If an agent finishes without its mandatory chain (e.g., `backend-writer` completes without dispatching `code-reviewer`), the main session re-dispatches the missing agent.
- The `post-tool-hook.sh` injects a `DEEP NESTING WARNING` when `SUBAGENT_DEPTH >= 2` to alert the agent.

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
