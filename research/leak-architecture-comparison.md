# CAST vs Claude Code Internals: Architecture Comparison
**Date:** 2026-04-02
**Context:** Based on the npm source map incident (2026-03-31) which exposed ~512K lines of Claude Code internals. This document compares CAST's architecture against the now-public Claude Code source.

---

## 1. Tool System

### Claude Code's Internal Tool Architecture
The leak reveals approximately 40 internal tools organized in tiers:
- **FileReadTool, FileWriteTool, FileEditTool** — atomic file operations with schema-validated inputs
- **BashTool** — sandboxed shell execution with configurable excluded commands
- **AgentTool** — subagent dispatch with isolated context and restricted tool sets
- **WebFetchTool, WebSearchTool** — network access with domain allowlisting
- **GlobTool, GrepTool** — file search, optimized to avoid spawning shell processes
- **ToolSearch** — deferred tool loading for context efficiency

The permission system operates on a **4-tier model**:
- **Tier 1 (always-allowed):** Read-only tools like Glob, Grep, Read — never prompt
- **Allow:** Explicitly permitted tools (Bash, Write, Edit) — run without asking
- **Ask:** Tools requiring confirmation — routes through PermissionRequest hook
- **Deny:** Hard-blocked tools — pre-tool-guard exits 2

Tool inputs are schema-validated before dispatch. The leak confirms hooks receive a structured JSON payload — not raw text — matching what CAST's hook scripts already assume (`json.load(sys.stdin)`).

### How CAST Hooks Into the Tool System
CAST intercepts the tool lifecycle at every hook event:

| Hook Event | CAST Script | Purpose |
|---|---|---|
| PreToolUse (Write/Edit) | `cast-audit-hook.sh` | Audit trail, PII enforcement, policy block |
| PreToolUse (Bash git) | `pre-tool-guard.sh` | Block raw git commit/push → agent dispatch |
| PreToolUse (Bash curl/ssh/scp) | `cast-security-guard.sh` | Advisory security warning |
| PreToolUse (Write/Edit) | `cast-security-guard.sh` | Sensitive path detection |
| PreToolUse (AskUserQuestion) | `cast-headless-guard.sh` | Auto-respond to prevent pipeline stalls |
| PostToolUse (Write/Edit/Bash/Agent) | `post-tool-hook.sh` | Prettier auto-format, CAST-CHAIN/CAST-REVIEW injection |
| PostToolUse (Write/Edit/Bash/Agent) | `cast-cost-tracker.sh` | Per-tool cost logging to cast.db |
| PostToolUse (Write/Edit/Bash/Agent) | `cast-budget-alert.sh` | Spend threshold alerting |
| PermissionRequest | `cast-permission-hook.sh` | Rule-based auto-approve/deny |

**Alignment finding:** CAST's hooks are fully aligned with the schema-validated JSON inputs the leak confirms. All hooks use `json.load(sys.stdin)` — not string parsing — which means they're robust to tool name changes as long as the `tool_name` / `tool_input` envelope is preserved.

**Gap finding:** CAST's `permission-rules.json` uses a simple `auto_approve` / `auto_deny` / `default: allow` model. The leaked 4-tier system is richer — it has a distinct `Tier 1` (always-allowed without any hook firing) that CAST doesn't model. CAST could add a `tier1_passthrough` list to skip hook overhead for read-only tools.

**`if:` field optimization:** CAST's settings use the `if:` field correctly on PostToolUse (`"if": "Write|Edit|Agent|Bash"`), but PreToolUse hooks still fire a shell process for all tools before the if-filter applies on some hooks. The `25-hooks-security.json` audit hook has no `if:` guard — it fires on every Write/Edit unconditionally (which is intentional for audit completeness).

---

## 2. Agent & Orchestration

### Claude Code's Native Agent System
The leak reveals:
- **AgentTool** dispatches a subagent in a fresh isolated context
- **COORDINATOR_MODE** (feature-flagged, 150+ references) is a native multi-agent coordinator pattern with:
  - One coordinator spawning multiple workers
  - Workers in isolated contexts with restricted tool permissions
  - XML-structured task notifications for inter-agent communication
  - Shared scratchpad directory for data exchange
  - Prompt cache sharing for economic viability
  - Mailbox pattern for dangerous operation approval
- Without COORDINATOR_MODE, Claude Code's multi-agent dispatch is **flat and sequential** — one AgentTool call at a time, no native batching

### CAST's Orchestration System
CAST adds a full orchestration layer on top of the flat AgentTool:

| Capability | CAST | Native Claude Code |
|---|---|---|
| Parallel batch dispatch | Yes (ADM `"parallel": true`) | No (COORDINATOR_MODE only, unreleased) |
| Sequential wave ordering | Yes (ADM batch IDs, dependency enforced) | No |
| Checkpoint/resume | Yes (`orchestrator-checkpoint-<hash>.log`) | No |
| Fan-out summary injection | Yes (next wave gets prior wave summary prepended) | No |
| Chain-maps / post-chain | Yes (CAST-CHAIN directive, `post-tool-hook.sh`) | No |
| Turn budget tracking | Yes (turn ceiling check before each batch) | No |
| Cost tracking per agent | Yes (`cast.db agent_runs` with cost fields) | No |
| Mismatch detection | Yes (`cast-mismatch-analyzer.sh`) | No |
| Routing feedback loop | Yes (`cast-routing-feedback.sh`) | No |
| File ownership conflict detection | Yes (ADM `owns_files` field) | No |

**CAST's orchestrator provides capabilities that COORDINATOR_MODE does not:**
1. **Batch sequencing with dependency ordering** — COORDINATOR_MODE dispatches workers without enforced ordering across waves
2. **Checkpoint resume** — if a plan stops mid-execution (turn limit, block), `cast orchestrate resume` picks up from the last completed batch
3. **Cost governance per wave** — CAST tracks which agents ran in which batch and their token spend
4. **Mismatch detection** — CAST logs when agents are dispatched to tasks outside their specialty and feeds this back to improve routing
5. **Fan-out summary** — the output of Wave N is automatically prepended to Wave N+1 agent prompts, creating cross-wave context coherence

---

## 3. Context Management

### Claude Code's 3-Tier Compaction
The leak reveals three compaction tiers:
- **MicroCompact:** Lightweight summarization for near-limit contexts; preserves tool call structure
- **AutoCompact:** Triggered at configurable threshold (default varies); full conversation summarization
- **Full Compact:** User-initiated `/compact`; most aggressive summarization

The leak also revealed: **250K wasted API calls/day from compaction failures** — cases where compaction triggers incorrectly or incompletely, causing context to bloat rather than compress.

### CAST's Compaction Integration
CAST's compaction setup:
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80` — triggers AutoCompact at 80% context fill (in `managed-settings.d/00-env.json`)
- `PostCompact` hook wired to:
  - `cast-post-compact-hook.sh` (async) — logs compaction event to cast.db
  - HTTP hook to dashboard at `localhost:3001/api/hook-events` (async) — real-time compaction tracking
  - `prompt` hook — "Context was automatically compacted. Briefly let the user know this happened, summarize the current task state, and continue where you left off."

**Gap finding:** CAST fires PostCompact but doesn't distinguish MicroCompact from AutoCompact from Full Compact. The hook fires on all three. The dashboard could benefit from compaction tier tracking to identify which sessions are hitting MicroCompact repeatedly (indicating context bloat patterns).

**Advantage:** CAST's 80% threshold is lower than Claude Code's default, which means CAST sessions compact more aggressively and are less likely to hit the failure mode that causes the 250K wasted API calls the leak identified.

---

## 4. Prompt Cache Sharing

### What the Leak Reveals
The leak confirms that subagents dispatched via AgentTool share the **prompt cache prefix** with the coordinator session. This means:
- If the coordinator and subagent share a long common prefix (system prompt, project description, conventions), the subagent pays near-zero input tokens for that shared prefix on subsequent calls
- Prompts that diverge early (agent-specific instructions first) waste the cache sharing opportunity
- The leaked implementation shows cache sharing is automatic — no explicit opt-in — but it only works when prefixes truly match

### CAST's Current Pattern
CAST orchestrator prompts currently structure as:
1. Agent role declaration (`"You are the researcher agent..."`)
2. Agent-specific task instructions (unique per agent)
3. File paths and repo structure (partly shared)

This structure diverges **immediately** — the role declaration is unique per agent, so cache prefix sharing provides minimal benefit. The shared context (repo layout, conventions) comes after divergence.

**Optimization opportunity:** Front-loading shared context (project description, working directory, repo structure, CAST conventions) before agent-specific instructions would maximize cache hits across parallel wave agents. For a Wave 2 with 3 parallel agents, this could reduce input token costs by 40-60% on the shared prefix.

**Concrete recommendation:** Add a shared preamble block to all orchestrator-dispatched prompts:
```
[CAST SHARED CONTEXT]
Project: claude-agent-team (CAST v3.3)
Repo: /Users/edkubiak/Projects/personal/claude-agent-team
Stack: Bash + Python + SQLite, 17 agents, 324 BATS tests
Conventions: YAGNI, DRY, always use cast_db.py for DB access
[END SHARED CONTEXT]

You are the [agent-name] agent. [agent-specific instructions...]
```

---

## 5. Hidden Features Roadmap

The leak revealed 44+ feature flags. Key ones with CAST implications:

| Feature Flag | What It Does | CAST Overlap | CAST Action |
|---|---|---|---|
| `COORDINATOR_MODE` | Native multi-agent coordination (150+ refs, ~75% mature) | High — overlaps orchestrator | Monitor; prepare compatibility layer |
| `KAIROS` | Autonomous long-horizon task execution with calendar/deadline awareness | None | Low priority — watch for release |
| `ULTRAPLAN` | Enhanced planning with multi-step decomposition UI | Partial — overlaps planner agent | Keep CAST planner as ADM generator; ULTRAPLAN is UI-focused |
| `BUDDY` | Pair-programming mode with a persistent AI collaborator | None | Low priority |
| `VOICE_MODE` | Voice input/output interface | None | N/A for CAST CLI use case |
| `Undercover Mode` | Hides AI assistance indicators for stealth use | None | N/A |
| `Skill Search` | Semantic search across installed skills | Partial — overlaps cast-memory-router.py keyword routing | CAST's router is more structured; Skill Search is fuzzy |
| `ANTI_DISTILLATION_CC` | Injects decoy tool definitions to prevent model extraction/distillation | Risk — decoy tools could trigger CAST hooks | Audit hooks for decoy tool misfire risk |
| `CLAUDE_TEAMS` (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Teammate mode with parallel agents in shared context | Yes — CAST already has this enabled | Already exploiting |
| `WorktreeCreate` hook | Fires when a worktree is created | Partial — CAST has worktree symlink config | Wire `cast-fswatcher.sh` to WorktreeCreate |

**ANTI_DISTILLATION_CC risk:** This flag injects synthetic/decoy tool definitions into the model context. If CAST's `cast-audit-hook.sh` sees a write attempt to a decoy tool path, it would log it as a legitimate tool call. The risk is low (audit is advisory) but the `cast-permission-hook.sh` could auto-deny a decoy tool if its name matches an `auto_deny` pattern. Recommend adding a comment in permission-rules.json noting this risk.

---

## 6. Competitive Positioning

### What CAST Does That Claude Code Cannot Do Natively (Even with All Feature Flags)

| Capability | CAST | Native Claude Code (all flags) |
|---|---|---|
| Structured SQLite observability (cast.db) | Yes | No — no persistent event store |
| Real-time React dashboard with session timeline | Yes | No |
| 324 BATS tests for shell infrastructure | Yes | No |
| Homebrew tap (`brew install cast`) | Yes | N/A |
| Per-agent model selection (sonnet/haiku routing) | Yes | Partial (COORDINATOR_MODE hints) |
| Checkpoint/resume for interrupted plans | Yes | No |
| Wave-based fan-out summary injection | Yes | No |
| Budget alerts + spend governance per agent | Yes | No |
| Keyword-based agent routing with feedback loop | Yes | No |
| Policy-based commit/push blocking (pre-tool-guard) | Yes | No |
| PII redaction on cloud-bound tool calls | Yes | No |
| Mismatch detection + routing improvement | Yes | No |
| Managed settings fragments (drop-in policy) | Partial (managed-settings.d/) | Yes (same mechanism) |

### Portfolio Summary
CAST's differentiation is not breadth of agents — it's **infrastructure depth**:
1. **Observability stack** — cast.db + dashboard is unique in the agent framework ecosystem
2. **Quality enforcement** — pre-tool-guard, approval gates, PII enforcement are production-grade
3. **Economic governance** — cost tracking + budget alerts run on every tool call
4. **Checkpoint orchestration** — long-running plans can be interrupted and resumed
5. **Routing intelligence** — keyword router + mismatch feedback creates a self-improving dispatch system

The leaked Claude Code source confirms CAST is building on top of the right foundation: every CAST capability maps to a hook event or tool that the source confirms is stable and intentional. CAST is not fighting Claude Code — it's extending it at exactly the interfaces designed for extension.

---

*Generated by researcher agent (Batch 1 — Wave 1)*
*Sources: CAST repo at /Users/edkubiak/Projects/personal/claude-agent-team, managed-settings.d/*, scripts/cast-*, prior research in research/cast-differentiation-2026-04-01.md*
