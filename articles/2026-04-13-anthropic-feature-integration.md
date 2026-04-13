# CAST Feature Audit: Integrating Unused Anthropic Features

**Date:** 2026-04-13
**Author:** CAST docs agent
**Context:** CAST v4.6 — 31 agents, hook-enforced quality gates, cast.db observability

---

## Background

CAST has been built on Claude Code's core primitives since v1: the Agent tool, PreToolUse/PostToolUse hooks, MCP servers, extended thinking, prompt caching, and Skills. But Anthropic has shipped 23+ features since late 2025 that CAST wasn't using. This article documents the audit and integration decisions.

The full feature audit is at `~/.claude/research/2026-04-13-anthropic-feature-audit.md`.

---

## What Was Integrated

### 1. Agent Teams (Experimental)

**Feature:** Multiple Claude Code sessions with shared task list, peer-to-peer messaging, and team lead coordination. Hooks: `TeammateIdle`, `TaskCreated`, `TaskCompleted`.

**What we did:**
- Enabled `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json`
- Updated the orchestrator agent definition with a documented Agent Teams team-lead pattern as an alternative dispatch backend
- Wrote `TeammateIdle` and `TaskCompleted` hook scripts following CAST conventions (`set -euo pipefail`, `CLAUDE_SUBPROCESS` guard, `hookSpecificOutput` JSON format)
- Preserved the existing hub-and-spoke subagent model as the default; Agent Teams is opt-in

**Architecture decision:** Agent Teams supplements rather than replaces CAST's dispatch model. The orchestrator checks a `dispatch_backend` config flag to choose between `cast` (current subagent model) and `coordinator` (Agent Teams). This keeps the system backward-compatible while enabling peer-to-peer coordination for workloads that benefit from it.

### 2. Structured Output Schemas

**Feature:** Guaranteed JSON schema conformance for API responses. GA since Jan 2026.

**What we did:**
- Defined three JSON schemas in `schemas/`:
  - `status-block.schema.json` — validates the CAST Status block format (`DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`)
  - `work-log.schema.json` — validates Work Log entries (timestamp, agent, action, files_changed, summary)
  - `routing-event.schema.json` — validates routing events (session_id, agent, model, timestamp, prompt_summary)
- These schemas serve as machine-readable documentation of CAST's agent response contract

**Limitation:** Structured Outputs is an API-level feature. Claude Code agent responses (via the Agent tool) don't currently support structured output mode. The schemas are published as reference for future custom CAST API pipelines and for validation tooling.

### 3. Citations in Researcher Agent

**Feature:** Claude can ground answers in source documents and return exact citations. GA since Jan 2025.

**What we did:**
- Updated the researcher agent prompt to explicitly request source citations with URLs in all research reports
- Added a citation section convention to the report template

**Limitation:** Claude Code's WebSearch/WebFetch tools provide URLs in results, but the Citations API (with `file_id` references and sentence-level attribution) is an API-only feature. The researcher agent uses inline URL attribution as the Claude Code-compatible approach.

### 4. Advisor Tool Guidance in Code-Writer and Debugger

**Feature:** Pairs a Sonnet executor with Opus as a mid-generation advisor. Single API call. Near-Opus quality at near-Sonnet cost.

**What we did:**
- Added notes to both `code-writer.md` and `debugger.md` documenting the Advisor Tool as a future integration opportunity for custom CAST API pipelines

**Limitation:** The Advisor Tool is API-only (requires `advisor-tool-2026-03-01` beta header and direct Messages API calls). It cannot be used through Claude Code's Agent tool. This is the highest-value deferred integration — when CAST builds custom API pipelines, the Advisor Tool should be the first addition.

---

## What Was Deferred

| Feature | Reason |
|---|---|
| **Managed Agents** | Hosted agent infrastructure. Interesting for JARVIS RemoteTrigger jobs, but CAST's local model works well. Revisit when CAST needs long-running stateful sessions. |
| **Compaction API** | Claude Code already has `/compact`. API version is for custom pipelines. |
| **Programmatic Tool Calling** | GA, no header needed. Would reduce token costs for multi-tool agents. Requires API-level integration — deferred to custom pipeline work. |
| **Files API** | Useful for researcher/docs agents reading large documents. Requires API-level integration. |
| **Memory Tool** | CAST has `agent-memory-local/`. Official Memory Tool is for API consumers. Evaluate when CAST agents run outside Claude Code. |
| **Claude Code Analytics API** | Could feed into claude-code-dashboard. Requires Admin API key. Lower priority than direct feature integrations. |

---

## Files Changed

| File | Change |
|---|---|
| `settings.json` | Added `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` |
| `agents/core/orchestrator.md` | Agent Teams team-lead pattern documentation |
| `agents/core/researcher.md` | Citation request instructions |
| `agents/core/code-writer.md` | Advisor Tool future integration note |
| `agents/core/debugger.md` | Advisor Tool future integration note |
| `scripts/cast-teammate-idle-hook.sh` | New TeammateIdle hook script |
| `scripts/cast-task-completed-hook.sh` | New TaskCompleted hook script |
| `schemas/status-block.schema.json` | CAST Status block JSON schema |
| `schemas/work-log.schema.json` | Work Log entry JSON schema |
| `schemas/routing-event.schema.json` | Routing event JSON schema |

---

## Key Takeaway

Most of Anthropic's powerful new features (Advisor Tool, Structured Outputs, Managed Agents, Compaction API) are **API-level features** that don't work through Claude Code's Agent tool. CAST's architecture — built on Claude Code primitives — can adopt Agent Teams (which is a Claude Code feature) but must build custom API pipelines to access the rest.

The schemas, hook scripts, and agent prompt updates from this integration lay the groundwork for that future API layer. When CAST builds direct Anthropic API pipelines (e.g., for JARVIS or standalone agent execution), the Advisor Tool and Structured Outputs should be the first integrations.
