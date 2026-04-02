# COORDINATOR_MODE Preparation Guide
**Date:** 2026-04-02
**Agent:** researcher
**Question:** What does CAST need to do when Anthropic ships COORDINATOR_MODE publicly?

---

## What COORDINATOR_MODE Provides (from leaked source)

The leaked Claude Code internals show COORDINATOR_MODE with 150+ references — indicative of a feature that is functionally complete but held behind a flag, likely for billing/safety review before public release. Its capabilities:

- **One coordinator spawning multiple workers** — the coordinator session holds context; workers run in isolated, restricted contexts
- **Worker tool isolation** — each worker has a subset of tools, preventing dangerous cross-contamination
- **XML-structured task notifications** — inter-agent communication uses `<task>` / `<result>` XML envelopes rather than free-form text
- **Shared scratchpad directory** — workers read/write a shared filesystem directory for data exchange, replacing the need to pass data through the coordinator context window
- **Prompt cache sharing** — coordinator and workers share a prompt prefix, making multi-worker plans economically viable at scale
- **Mailbox pattern** — dangerous operations (file writes, shell commands above a risk threshold) are queued to a mailbox for coordinator approval before execution
- **Worker lifecycle hooks** — SubagentStart/SubagentStop fire per worker, meaning CAST's existing hooks already capture the data

---

## 1. Overlap: Where COORDINATOR_MODE Duplicates CAST Functionality

| Capability | COORDINATOR_MODE | CAST Equivalent |
|---|---|---|
| Spawning multiple agents | Yes — native coordinator/worker pattern | Yes — orchestrator ADM batches |
| Worker tool isolation | Yes — per-worker tool allowlist | Partial — CAST has per-agent `disallowedTools` frontmatter |
| Inter-agent data exchange | Yes — shared scratchpad directory | Yes — agents write files; next agent reads them (convention, not enforced) |
| Lifecycle visibility | Yes — SubagentStart/Stop per worker | Yes — cast-subagent-start/stop-hook.sh already fires |
| Prompt cache sharing | Yes — automatic prefix sharing | Partial — CAST can structure prompts to exploit this (see orchestrator optimization) |
| Mailbox for dangerous ops | Yes — coordinator approval gate | Yes — pre-tool-guard.sh blocks raw git commit/push; approval required |

**Assessment:** The overlap is real but not fatal. COORDINATOR_MODE duplicates CAST's orchestration *mechanism* but not CAST's *infrastructure layer* — CAST's observability, cost governance, checkpoint/resume, and routing intelligence have no COORDINATOR_MODE equivalent.

---

## 2. Complementary: Where They Work Together

The most interesting possibility is using CAST's orchestrator to *dispatch* COORDINATOR_MODE sessions — i.e., the CAST ADM becomes the outer planning layer, and individual batches use COORDINATOR_MODE internally for parallel sub-tasks.

**Proposed hybrid architecture:**
```
CAST orchestrator (ADM wave planning)
  └─ Batch 1: COORDINATOR_MODE session (coordinator + 3 workers in parallel)
  └─ Batch 2: COORDINATOR_MODE session (coordinator + 2 workers in parallel)
  └─ Post-chain: code-reviewer + commit (sequential, lightweight, haiku)
```

In this model:
- CAST provides: wave ordering, checkpoint/resume, cost governance, cast.db logging, mismatch detection
- COORDINATOR_MODE provides: worker isolation, XML task dispatch, shared scratchpad, prompt cache economics

CAST becomes a **meta-orchestrator** — it doesn't need to replicate COORDINATOR_MODE's low-level worker mechanics. It just needs to know how to dispatch a COORDINATOR_MODE session as one of its batch agents.

**Key integration requirement:** CAST's ADM would need a new agent type: `"subagent_type": "coordinator"` (or a flag on existing agent entries). The orchestrator would pass a coordinator-specific prompt that sets up the worker pattern internally.

---

## 3. Migration Path

If COORDINATOR_MODE becomes the preferred multi-agent pattern, CAST should adapt in three phases:

### Phase A: Monitor and instrument (now, no code changes)
- The existing SubagentStart/SubagentStop hooks already fire for COORDINATOR_MODE workers
- cast.db will capture coordinator and worker agent_runs rows automatically when the feature ships
- No CAST changes needed — observability is already in place

### Phase B: ADM compatibility layer (when COORDINATOR_MODE ships publicly)
Add a `mode: "coordinator"` field to ADM agent entries:
```json
{
  "id": 2,
  "parallel": true,
  "mode": "coordinator",
  "agents": [
    {
      "subagent_type": "general-purpose",
      "coordinator_workers": 3,
      "prompt": "You are the coordinator. Spawn 3 workers to..."
    }
  ]
}
```
The orchestrator reads `mode` and constructs a coordinator-appropriate prompt. This is a small orchestrator.md change (add a `mode` field handler to Step 3).

### Phase C: Evaluate replacement vs. augmentation (6-12 months post-ship)
After COORDINATOR_MODE ships and stabilizes, evaluate whether CAST's ADM batch system is still the right abstraction or whether it should be replaced by native coordination. Key decision criteria:
- Does COORDINATOR_MODE provide checkpoint/resume? (CAST has this; native doesn't yet)
- Does COORDINATOR_MODE integrate with cast.db? (Likely not — it's a native feature with no external hooks)
- Does COORDINATOR_MODE support cross-wave fan-out summary injection? (No — this is CAST-specific)

Decision point: **if COORDINATOR_MODE ships without checkpoint/resume and fan-out summary, keep CAST's ADM layer**. If it ships with both, the ADM layer becomes optional scaffolding.

---

## 4. Competitive Moat: What CAST Has That COORDINATOR_MODE Cannot Replicate

These features have no COORDINATOR_MODE equivalent and represent CAST's durable differentiators:

### 4.1 cast.db observability stack
COORDINATOR_MODE is a runtime coordination pattern — it has no persistent event store, no historical query capability, no cost analytics. Every session in CAST writes to cast.db forever. You can query `SELECT agent, sum(cost_usd) FROM agent_runs GROUP BY agent` across all time. COORDINATOR_MODE provides no equivalent.

### 4.2 Checkpoint/resume
If a COORDINATOR_MODE session crashes mid-run, there is no resume mechanism visible in the leaked source. CAST's `orchestrator-checkpoint-<hash>.log` pattern allows arbitrary plan resumption from any completed batch. For plans that run > 40 turns (the practical orchestrator limit), this is essential.

### 4.3 Wave-level fan-out summary injection
CAST's orchestrator prepends the output of Wave N to every agent in Wave N+1. This cross-wave context coherence has no native equivalent in COORDINATOR_MODE, which provides a shared scratchpad but no automatic summarization injection between waves.

### 4.4 Cost governance and budget enforcement
`cast-budget-alert.sh` fires on every PostToolUse and compares cumulative spend against per-session budgets. COORDINATOR_MODE has no budget concept. This is a portfolio differentiator — especially for teams billing AI usage against client projects.

### 4.5 Mismatch detection and routing feedback
`cast-mismatch-analyzer.sh` + `cast-routing-feedback.sh` track when agents are dispatched to tasks outside their specialty (e.g., code-writer doing bash-only work) and feed this back to improve future routing. COORDINATOR_MODE has no equivalent feedback loop.

### 4.6 Homebrew distribution
`brew install cast` sets up the entire framework including hooks, agents, settings.json fragments, and cast.db schema. COORDINATOR_MODE is a Claude Code internal — it requires no installation and provides no distribution story for custom agent definitions.

---

## 5. Timeline Estimate

Based on the leaked source's maturity indicators:

| Signal | Assessment |
|---|---|
| 150+ references in source | Feature is functionally complete, not experimental |
| No public announcement as of 2026-04-02 | Likely in internal beta or staged rollout review |
| XML-structured task notifications | Suggests billing/safety review in progress (structured = auditable) |
| Mailbox pattern for dangerous ops | Suggests safety team approval is a prerequisite |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` already public | This is the precursor flag; COORDINATOR_MODE may extend it |

**Estimate:** COORDINATOR_MODE ships publicly within 60-90 days (by June 2026), initially behind the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` flag as an extension, then enabled by default in a subsequent release.

**CAST preparation timeline:**
- Now: no changes needed; existing hooks capture all COORDINATOR_MODE lifecycle events
- T+30 days: draft ADM `mode: "coordinator"` field spec
- T+60 days (if shipped): implement Phase B ADM compatibility in orchestrator.md
- T+90 days: evaluate Phase C migration path decision

---

## Summary

COORDINATOR_MODE is coming. CAST is well-positioned: the observability hooks already instrument it, the ADM layer can wrap it, and CAST's infrastructure layer (cast.db, budget governance, checkpoint/resume, fan-out injection) provides durable differentiation that COORDINATOR_MODE will not replicate.

The recommended stance: **extend CAST to be a meta-orchestrator for COORDINATOR_MODE sessions, not a competitor to them.** CAST's value is in the infrastructure layer — the database, the dashboard, the cost governance, the routing intelligence. Native COORDINATOR_MODE is a better worker dispatch mechanism than CAST's current Agent tool calls. Use both.

---

*Generated by researcher agent (Batch 3 — Wave 3)*
*Sources: agents/core/orchestrator.md, skills/orchestrate/SKILL.md, managed-settings.d/00-env.json, research/leak-architecture-comparison.md*
