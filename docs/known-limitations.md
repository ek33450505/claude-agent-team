# CAST — Known Limitations

This document records framework-level limitations that are not bugs but rather constraints of the Claude Code runtime that CAST works around.

---

## 1. SendMessage Gap — Orchestrator Cannot Resume After Network Drop

**Symptom:** If the inline session is dropped mid-execution (network error, timeout, process kill), the orchestrator subagent cannot be resumed by sending it a follow-up message via `SendMessage`.

**Root cause:** Claude Code's `Agent` tool does not expose a `SendMessage` / continuation mechanism for already-running subagent contexts. When a subagent's session ends, it ends permanently.

**Workaround:**
1. The orchestrator writes a checkpoint to `~/.claude/cast/orchestrator-checkpoint.log` after each completed batch.
2. On re-invocation, the orchestrator reads the checkpoint and skips all batches already completed.
3. Use `"pre_approved": true` in the Agent Dispatch Manifest to bypass the confirmation gate on restart — this avoids the user needing to re-approve the queue.

**Example restart flow:**
```bash
# Re-invoke the orchestrator agent with the same plan file path
# It will read orchestrator-checkpoint.log and resume from the last completed batch
```

---

## 2. Agent Tool Unavailable at Nesting Depth >= 3

**Symptom:** Agents nested 3+ levels deep (orchestrator → agent → sub-agent) may not have access to the `Agent` tool, causing self-dispatch chains to silently fail.

**Root cause:** Claude Code imposes a nesting depth limit on tool availability. The `Agent` tool is restricted in deeply nested subagent contexts.

**Workaround:**
- The inline session acts as fallback enforcer: it checks each agent's response for the expected downstream dispatch confirmation.
- If an agent finishes without its mandatory chain (e.g., `code-writer` completes without dispatching `code-reviewer`), the inline session re-dispatches the missing agent.
- The `post-tool-hook.sh` injects a `DEEP NESTING WARNING` when `SUBAGENT_DEPTH >= 2` to alert the agent.

**Detection:** Parse the agent's `Status:` block. If no chain confirmation is present and the agent was expected to self-dispatch, re-dispatch inline.

---

## 3. Turn Limit — Orchestrator Session Ceiling

**Symptom:** Orchestrator sessions approaching turn 50 risk orphaning mid-execution with no automatic resume.

**Root cause:** Claude Code sessions have a hard turn ceiling (~50 turns). The orchestrator has no `SendMessage` continuation mechanism.

**Workaround:**
- When approaching turn 40, the orchestrator writes the checkpoint log and stops cleanly.
- The user re-invokes the orchestrator to resume from the last completed batch.
- Manifests with many batches should use `"pre_approved": true` to minimize turns spent on confirmation.
