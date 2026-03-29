# CAST — Claude Agent Specialist Team

![Version](https://img.shields.io/badge/version-2.4-blue)
![Agents](https://img.shields.io/badge/agents-42-green)
![Routes](https://img.shields.io/badge/routes-21-blue)
![Commands](https://img.shields.io/badge/commands-32-blue)
![Tests](https://img.shields.io/badge/tests-307%20total-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

CAST is a local-first OS built on Claude Code. 42 specialist agents. A routing system. A background daemon. A privacy layer. Zero cloud lock-in.

Every prompt you type is intercepted before Claude sees it. The right agent is dispatched automatically. Code review is mandatory and non-skippable. `git commit` is hard-blocked — the `commit` agent is the only path through. Agent memory lives in plain markdown files you can read, edit, and back up. Nothing syncs to a server you don't control.

This is not a prompt library. It is infrastructure.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

[Interactive Architecture Diagram](docs/architecture.html)

---

## Table of Contents

- [The OS Analogy](#the-os-analogy)
- [Architecture Overview](#architecture-overview)
- [How It Works](#how-it-works)
- [Hook Directives](#hook-directives)
- [Routing](#routing)
- [Parallel Post-Chain](#parallel-post-chain)
- [post-tool-hook.sh — Five Parts](#post-tool-hooksh--five-parts)
- [agent-status-reader.sh — Status Propagation](#agent-status-readersh--status-propagation)
- [Work Logs](#work-logs)
- [Parallel Agent Waves](#parallel-agent-waves)
- [What's in the Box](#whats-in-the-box)
- [The Agents (42)](#the-agents-42)
- [The Commit → Push Chain](#the-commit--push-chain)
- [Rollback Protocol](#rollback-protocol)
- [Event-Sourcing Protocol](#event-sourcing-protocol)
- [Quick Start](#quick-start)
- [cast CLI Reference](#cast-cli-reference)
- [Slash Commands](#slash-commands)
- [Memory](#memory)
- [Skills](#skills)
- [Privacy Layer](#privacy-layer)
- [Background Daemon (castd)](#background-daemon-castd)
- [macOS Integration](#macos-integration)
- [Self-Learning Routing](#self-learning-routing)
- [Self-Improving Routing](#self-improving-routing)
- [Memory-Assisted Routing](#self-improving-routing)
- [Agent Performance Profiling](#agent-performance-profiling)
- [Dry-Run Mode](#dry-run-mode)
- [ACI Reference Sections](#aci-reference-sections)
- [Phase History](#phase-history)
- [Stats](#stats)
- [Known Limitations](#known-limitations)
- [Companion](#companion)

---

## The OS Analogy

Claude Code is a capable shell. Without infrastructure, you are the scheduler, the enforcer, and the memory system. CAST is the OS layer that handles all three.

| OS concept | CAST component | What it does |
|---|---|---|
| Kernel | `route.sh` + `pre-tool-guard.sh` + `post-tool-hook.sh` | Routes every prompt, enforces every policy, reacts to every tool call |
| Processes | 42 specialist agents | Each agent is an isolated, role-bounded executor with its own instructions |
| Scheduler | Agent groups + routing table | Matches work to the right agent — no manual dispatch needed |
| Interrupts | Hook directives (`[CAST-CHAIN]`, `[CAST-HALT]`, `[CAST-DEBUG]`) | Inject mandatory signals alongside prompt context; Claude cannot ignore them |
| Shell | `cast` CLI | Subcommand surface for running agents, inspecting queues, managing memory, controlling the daemon |
| Daemon | `castd` (background process) | Processes the async task queue, runs health checks, fires budget alerts |
| Filesystem | `~/.claude/` | Everything — agents, memory, events, config, logs — is a plain file you control |

Zero custom application code. Pure config, shell, and markdown. If you understand bash and JSON, you can read and modify every part of CAST.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Your Terminal                                  │
│                                                                         │
│  You type a prompt → Claude Code receives it                            │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hook Layer  (~/.claude/scripts/)                     │
│                                                                         │
│  [UserPromptSubmit]  route.sh                                           │
│      Stage 1: agent-groups.json match (31 groups)  → [CAST-DISPATCH-GROUP]
│      Stage 2: routing-table.json regex (35 routes) → [CAST-DISPATCH]   │
│      Stage 3: catch-all NLU (router agent)         → [CAST-DISPATCH]   │
│                                                                         │
│  [PostToolUse]  post-tool-hook.sh  (5 independent parts)               │
│      Part 1: prettier auto-format on code files                         │
│      Part 2: inject [CAST-CHAIN] (mandatory) or [CAST-REVIEW] (soft)   │
│      Part 3: plan file written → [CAST-ORCHESTRATE]                    │
│      Part 4: Agent tool fired → log to routing-log.jsonl               │
│      Part 5: Bash non-zero exit → [CAST-DEBUG]                         │
│                                                                         │
│  [PostToolUse]  agent-status-reader.sh                                  │
│      Reads ~/.claude/agent-status/ — BLOCKED → [CAST-HALT] exit 2      │
│                                                                         │
│  [PreToolUse]  pre-tool-guard.sh                                        │
│      Hard-blocks: git commit, git push (escape: env var)                │
│      Policy engine: auth, migrations, workflows, .env                   │
│                                                                         │
│  [Stop]  stop-hook.sh                                                   │
│      Routing feedback (weekly) / project board / memory seeding         │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Agent Layer  (~/.claude/agents/)                    │
│                                                                         │
│  42 specialist agents organized in 5 tiers:                             │
│                                                                         │
│  Core (12)       code-writer, code-reviewer, debugger, test-writer,    │
│                  commit, push, security, merge, planner, data-scientist,│
│                  db-reader, bash-specialist                              │
│                                                                         │
│  Extended (8)    architect, tdd-guide, build-error-resolver, e2e-runner,│
│                  refactor-cleaner, doc-updater, readme-writer, router   │
│                                                                         │
│  Orchestration (5)  orchestrator, auto-stager, chain-reporter,          │
│                     verifier, test-runner                               │
│                                                                         │
│  Productivity (5)  researcher, report-writer, meeting-notes,            │
│                    email-manager, morning-briefing                      │
│                                                                         │
│  Professional (3)  browser, qa-reviewer, presenter                     │
│                                                                         │
│  Specialist (9)  devops, performance, seo-content, linter,             │
│                  frontend-designer, framework-expert, pentest,          │
│                  infra, db-architect                                    │
└────────────────────────────┬────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                   Persistence Layer  (~/.claude/)                       │
│                                                                         │
│  cast.db              SQLite — task queue, cost tracking, agent stats   │
│  routing-log.jsonl    Every routing decision, matched or not            │
│  cast/events/         Immutable event log (append-only)                 │
│  agent-status/        Latest status from each agent run                 │
│  agent-memory-local/  Per-agent markdown memory files                  │
│  reports/             Chain summaries, routing gap reports              │
└─────────────────────────────────────────────────────────────────────────┘
```

**Three enforcement tiers** operate in parallel. They are not redundant — each catches what the others cannot:

| Tier | Mechanism | Enforces |
|---|---|---|
| Advisory | `CLAUDE.md` directive definitions | Claude's understanding of the protocol |
| Behavioral | `route.sh` hookSpecificOutput injection | Claude's next action (alongside the prompt) |
| Hard | `pre-tool-guard.sh` exit 2 | OS-level block — Claude cannot bypass |

---

## How It Works

```
User Prompt
    |
    v
[Hook 1: UserPromptSubmit] -- route.sh
    |
    |-- Stage 1: agent-groups.json match (31 groups) --> [CAST-DISPATCH-GROUP]
    |                                                         |
    |-- Stage 2: routing-table.json match (35 routes) -----> [CAST-DISPATCH]
    |                                                         |
    |-- Stage 3: catch-all — 5+ words, action verb, -------> router agent (NLU)
    |            not question
    |
    v (no match)
Claude handles inline
    |
    v (Write or Edit tool fires on any matched path)
[Hook 2: PostToolUse] -- post-tool-hook.sh
    |-- Part 1: prettier auto-format (JS/TS/CSS/JSON, if .prettierrc found)
    |-- Part 2: main session + code file  -> [CAST-CHAIN]  (mandatory, non-skippable)
    |           main session + other file -> [CAST-REVIEW] (soft review suggestion)
    |           subagent + depth >= 2     -> [CAST-DEPTH-WARN] + [CAST-REVIEW]
    |           subagent + code file      -> [CAST-REVIEW] (reinforcing signal)
    |-- Part 3: plan file with dispatch manifest -> [CAST-ORCHESTRATE]
    |-- Part 4: Agent tool fired -> log dispatch to routing-log.jsonl
    |-- Part 5: Bash non-zero exit (main session only) -> [CAST-DEBUG]
    |
    v
code-reviewer (haiku) -- emits Work Log + Status Block
    |
    v
[Hook 2b: PostToolUse] -- agent-status-reader.sh
    | age guard: status files > 60s ignored (stale cross-session protection)
    | BLOCKED           -> [CAST-HALT] exit 2
    | DONE_WITH_CONCERNS -> [CAST-REVIEW] advisory
    | NEEDS_CONTEXT     -> [CAST-NEEDS-CONTEXT] advisory
    | 3rd BLOCKED       -> [CAST-ESCALATE] advisory
    | 90min no commit   -> [CAST-TIMEOUT] advisory
    |
    v
[Hook 3: PreToolUse] -- pre-tool-guard.sh
    policy engine (Write/Edit): path matches policies.json rule -> [CAST-POLICY-BLOCK] exit 2
                                 unless required agent ran this session (or CAST_POLICY_OVERRIDE=1)
    hard-block: git commit  (escape: CAST_COMMIT_AGENT=1 git commit ...)
    hard-block: git push    (escape: CAST_PUSH_OK=1 git push ...)
    |
    v
commit agent (haiku) -- CAST_COMMIT_AGENT=1 git commit
    |
    v
[Hook 4: Stop] -- stop-hook.sh
    chain-reporter dispatch (if multi-batch session detected)
    cast-routing-feedback.sh (weekly, background — writes routing-gaps report if >7 days stale)
    cast-board.sh (background — derives project-board.json from event files)
    cast-agent-memory-init.sh (background — seeds each agent's MEMORY.md)
    session temp file cleanup
    |
    v
cast-events.sh -- ~/.claude/cast/events/ (append-only, immutable)
```

**Tier 2 supervisory layer** — five capabilities that run at session boundaries, not per-prompt:

| Capability | Script | When | Output |
|---|---|---|---|
| Pre-session briefing | `route.sh` | First prompt of every new session | `[CAST-SESSION-BRIEFING]` with git status, last 3 routing events, BLOCKED agents, project board snapshot |
| Policy engine | `pre-tool-guard.sh` | Every Write/Edit tool call | `[CAST-POLICY-BLOCK]` exit 2 if path matches a policy rule and required agent hasn't run |
| Routing feedback | `cast-routing-feedback.sh` | Session end, weekly | `~/.claude/reports/routing-gaps-YYYY-MM-DD.md` with top-5 unmatched prompt clusters; also writes `~/.claude/routing-proposals.json` with staged route proposals |
| Project board | `cast-board.sh` | Session end | `~/.claude/cast/project-board.json` with blocked/in-flight tasks and stale rollback refs |
| Agent memory init | `cast-agent-memory-init.sh` | Session end | Seeds each agent's `MEMORY.md` with project context and recent dispatch history |

Policy rules live in `config/policies.json`. Four rules ship by default: auth files, DB migrations, GitHub workflows, and `.env` files each require the appropriate specialist agent before modification. Override any block with `CAST_POLICY_OVERRIDE=1`.

---

## Hook Directives

Eleven directives drive the system. Four are defined in `CLAUDE.md.template` as standing instructions. Seven are injected at runtime by hook scripts alongside the triggering event.

### Defined in CLAUDE.md.template

| Directive | Injected by | Behavior |
|---|---|---|
| `[CAST-DISPATCH]` | `route.sh` via UserPromptSubmit | Dispatch the named agent. Do not handle inline. |
| `[CAST-CHAIN]` | `post-tool-hook.sh` Part 2 (code files, main session) | Dispatch listed agents in sequence. Non-skippable. |
| `[CAST-REVIEW]` | `post-tool-hook.sh` Part 2 (non-code files or subagent context) | Soft: dispatch `code-reviewer` if the change is significant. |
| `[CAST-DISPATCH-GROUP]` | `route.sh` (agent-groups.json match) | Execute the named group: waves in order, post-chain after final wave. |

### Injected at runtime by hooks

| Directive | Source | Behavior |
|---|---|---|
| `[CAST-ORCHESTRATE]` | `post-tool-hook.sh` Part 3 | Plan file with dispatch manifest written — dispatch `orchestrator` (or use `cast exec` for direct execution). |
| `[CAST-DEBUG]` | `post-tool-hook.sh` Part 5 | Bash command exited non-zero in main session — route to `debugger`. |
| `[CAST-HALT]` | `agent-status-reader.sh` | Agent reported BLOCKED — hard-block (exit 2) until blocker resolved. |
| `[CAST-REVIEW]` (status) | `agent-status-reader.sh` | Agent completed with concerns — dispatch `code-reviewer` before proceeding. |
| `[CAST-NEEDS-CONTEXT]` | `agent-status-reader.sh` | Agent needs more context — dispatch `researcher` to gather it. |
| `[CAST-ESCALATE]` | `agent-status-reader.sh` | Third consecutive BLOCKED from same agent — suggest model escalation or task split. |
| `[CAST-TIMEOUT]` | `agent-status-reader.sh` | Session running 90+ minutes without a commit — suggest `/commit` or `/fresh`. |
| `[CAST-DEPTH-WARN]` | `route.sh` (subagent context) | Nesting depth >= 2 — warn that Agent tool may be unavailable; inline session is fallback. |
| `[CAST-LOOP-BREAK]` | `route.sh` | Loop detected in routing — break and handle inline. |

---

## Routing

`route.sh` runs on every user prompt via the `UserPromptSubmit` hook. Routing has three stages, evaluated in order:

**Stage 1 — Agent Group pre-check:** matches against `config/agent-groups.json` (31 groups). On match, the orchestrator receives a full Payload JSON with wave definitions and runs them immediately (via `orchestrator` agent or `cast exec` for direct execution).

**Stage 2 — Routing table:** matches against `config/routing-table.json` (35 routes). On match, Claude sees:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: debugger (confidence: hard)\nMANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).\nPass the user's full prompt as the agent task. Do NOT handle this inline.\n[CAST-CHAIN] After debugger completes: dispatch `code-reviewer` in sequence."
  }
}
```

**Stage 3 — Catch-all:** fires when no route matched, the prompt is 5+ words, is not a question, and contains an action verb (`fix`, `add`, `implement`, `build`, etc.). Routes to the `router` agent (haiku) for NLU classification. If `router` returns confidence < 0.7, it returns `"main"` and Claude handles inline.

Every routing decision — match, no-match, catch-all, group dispatch — is logged to `~/.claude/routing-log.jsonl`.

---

## Parallel Post-Chain

Routes can define a `post_chain` array that runs agents after the primary dispatch completes. The `code-writer` route uses the parallel voting pattern:

```json
{
  "agent": "code-writer",
  "post_chain": [["code-reviewer", "security"], "commit"]
}
```

Nested arrays mean parallel execution. `["code-reviewer", "security"]` fires both agents simultaneously. `"commit"` runs after both complete. This gives security review at no extra latency cost on auth and implementation work.

Sequential post-chains use a flat array:

```json
"post_chain": ["code-reviewer", "commit"]
```

`cast-validate.sh` Check 11 verifies that `security` is wired into at least one `post_chain` — either as a parallel member `["code-reviewer", "security"]` or as a sequential step.

---

## post-tool-hook.sh — Five Parts

`post-tool-hook.sh` runs on every `PostToolUse` event. Its five parts are independent — each fires based on its own conditions:

| Part | Trigger | Action |
|---|---|---|
| 1 | Write or Edit on `.js/.jsx/.ts/.tsx/.css/.json`, `.prettierrc` found | Run `npx prettier --write` |
| 2 | Write or Edit — main session + code file | Inject `[CAST-CHAIN]` (mandatory) |
| 2 | Write or Edit — main session + non-code file | Inject `[CAST-REVIEW]` (soft) |
| 2 | Write or Edit — subagent depth >= 2 | Inject `[CAST-DEPTH-WARN]` + `[CAST-REVIEW]` |
| 2 | Write or Edit — subagent + code file | Inject `[CAST-REVIEW]` (reinforcing signal) |
| 3 | Write on `.md` file under `plans/` containing a dispatch block | Inject `[CAST-ORCHESTRATE]` |
| 4 | Agent tool fired (any session) | Append dispatch entry to `routing-log.jsonl` |
| 5 | Bash non-zero exit in main session | Inject `[CAST-DEBUG]` (suppresses benign exits: grep/rg exit 1, git diff exit 1) |

---

## agent-status-reader.sh — Status Propagation

`agent-status-reader.sh` runs at `PostToolUse` inside subagent context (`CLAUDE_SUBPROCESS=1`). It reads the latest file from `~/.claude/agent-status/` and acts on the `status` field:

| Status | Action | Exit |
|---|---|---|
| `BLOCKED` | Inject `[CAST-HALT]` message, hard-stop | exit 2 |
| `BLOCKED` (3rd time, same agent, same session) | Inject `[CAST-ESCALATE]` advisory | exit 2 |
| `DONE_WITH_CONCERNS` | Inject `[CAST-REVIEW]` advisory | exit 0 |
| `NEEDS_CONTEXT` | Inject `[CAST-NEEDS-CONTEXT]` advisory | exit 0 |
| `DONE` | Reset BLOCKED counter, exit silently | exit 0 |
| File older than 60s | Ignore (stale from prior session) | exit 0 |

The 90-minute timeout check runs on every invocation. If the session has been running for 90+ minutes without a commit event in the last 60 minutes, `[CAST-TIMEOUT]` is injected — but only when the status check result is non-blocking (it does not override `[CAST-HALT]`).

---

## Work Logs

Every agent that modifies code emits a structured Work Log before its Status Block. `CLAUDE.md` instructs Claude to echo it verbatim — this is the primary visibility into what happened during an agent run.

Example from `code-writer` implementing a new feature:

```
## Work Log

- Read: src/auth.ts (142 lines), middleware/validate.ts (67 lines), utils/retry.js (28 lines)
- Wrote/edited: src/auth.ts — added OAuth token refresh handler with retry on 401
- Wrote/edited: src/auth.ts:89 — wrapped async handler in try/catch per YAGNI (no logger abstraction, direct console.error)
- code-reviewer result: DONE_WITH_CONCERNS — non-descriptive variable name `d` at line 94
- test-writer result: DONE — auth.test.ts updated: happy path, token expiry edge case, 401 retry
- Decisions: used existing retry helper at utils/retry.js rather than inlining new logic

Status: DONE_WITH_CONCERNS
Summary: OAuth refresh handler implemented in src/auth.ts, reviewed and tested
Files changed: src/auth.ts, src/auth.test.ts
Concerns: Variable `d` at line 94 renamed to `decodedToken` — low priority, no functional impact
```

Example from `code-reviewer` reviewing the same change:

```
## Work Log

- Files reviewed: auth.ts (142 lines), middleware/validate.ts (67 lines)
- git diff: 3 functions added in auth.ts, null check added at line 47
- Critical issues: 1 — missing error boundary in async handler (auth.ts:89)
- Warnings: 2 — non-descriptive variable name `d`, unused import `lodash`
- Suggestions: 1

Status: DONE_WITH_CONCERNS
Summary: auth.ts and middleware/validate.ts reviewed
Concerns: Async handler at auth.ts:89 has no error boundary — unhandled rejection possible
Recommended agents:
  - debugger: auth.ts:89 — async handler needs try/catch or .catch() wrapper
```

The Status Block is read by `agent-status-reader.sh`. A `BLOCKED` status emits `[CAST-HALT]` (exit 2), halting execution until the block is resolved.

---

## Parallel Agent Waves

31 compound workflows are defined in `config/agent-groups.json`. Each group is a named sequence of parallel waves triggered by natural language — no slash commands needed.

Example — the `full-audit` group:

```json
{
  "id": "full-audit",
  "patterns": ["full.?audit", "audit.*codebase", "production.*ready", "ready.*to.*ship"],
  "confidence": "soft",
  "waves": [
    {
      "id": 1,
      "description": "Parallel audit — security, code quality, functional QA",
      "parallel": true,
      "agents": ["security", "code-reviewer", "qa-reviewer"]
    },
    {
      "id": 2,
      "description": "Consolidated audit report",
      "parallel": false,
      "agents": ["report-writer"]
    }
  ],
  "post_chain": ["chain-reporter"]
}
```

Say "audit the codebase" and `route.sh` matches the `full.?audit` pattern, injects `[CAST-DISPATCH-GROUP: full-audit]` with the full Payload JSON, and the orchestrator runs Wave 1 (`security`, `code-reviewer`, `qa-reviewer` simultaneously), then Wave 2 (`report-writer`), then `chain-reporter`.

Selected groups:

| Trigger phrase | Group | Waves | Post-chain |
|---|---|---|---|
| "ship it" | `ship-it` | W1: verifier + test-runner + devops | auto-stager, commit, push |
| "pre-release" | `pre-release` | W1: security + e2e-runner + qa-reviewer + performance. W2: devops + readme-writer | report-writer, commit, push |
| "hotfix" | `hotfix` | W1: debugger + security. W2: test-writer + verifier + build-error-resolver | commit, push |
| "security audit" | `security-audit` | W1: security + linter. W2: qa-reviewer + code-reviewer | report-writer, email-manager |
| "good morning" | `morning-start` | W1: morning-briefing + chain-reporter. W2: report-writer | — |
| "fix and ship" | `fix-and-ship` | W1: debugger. W2: test-writer + code-reviewer + build-error-resolver | commit |
| "full audit" | `full-audit` | W1: security + code-reviewer + qa-reviewer. W2: report-writer | chain-reporter |
| "tech spike" | `tech-spike` | W1: researcher + browser. W2: architect | report-writer |

Other groups: `feature-build`, `ui-build`, `backend-build`, `api-integration`, `quality-sweep`, `refactor-sprint`, `performance-audit`, `cross-browser`, `test-suite`, `full-test`, `db-migration`, `devops-setup`, `seo-sprint`, `doc-sprint`, `adr-session`, `dependency-audit`, `client-update`, `meeting-debrief`, `data-analysis`, `daily-wrap`, `pr-review`, `sprint-kickoff`, `project-brief`.

---

## What's in the Box

| Component | Count | Where |
|---|---|---|
| Specialist agents | 42 | `~/.claude/agents/` |
| Routing rules | 35 | `config/routing-table.json` |
| Agent groups | 31 | `config/agent-groups.json` |
| Slash commands | 32 | `~/.claude/commands/` |
| Skills | 13 | `~/.claude/skills/` |
| Hook scripts | 5 | `~/.claude/scripts/` (route.sh, post-tool-hook.sh, pre-tool-guard.sh, agent-status-reader.sh, stop-hook.sh) |
| cast CLI subcommands | 10 | `bin/cast` (run, queue, memory, budget, audit, airgap, daemon, status, install-completions, learn) |
| SQLite database | 1 | `~/.claude/cast.db` |
| Event types | 7 | `~/.claude/cast/events/` |
| Hook directives | 11 | `CLAUDE.md` + injected at runtime |
| Validation checks | 11 | `scripts/cast-validate.sh` |
| Agent groups | 31 | `config/agent-groups.json` |
| ACI reference agents | 6 | In-agent `## ACI Reference` sections |

---

## The Agents (42)

### Core — 12 agents

The foundation of every CAST install. Every quality gate flows through this tier.

| Agent | Model | Role |
|---|---|---|
| `planner` | sonnet | Task planning with Agent Dispatch Manifest output. Dispatches implementation tasks to `code-writer` |
| `code-writer` | sonnet | Implementation specialist for feature work and bug fixes. Mandatory chains `code-reviewer` + `test-writer` after each logical unit |
| `debugger` | sonnet | Root cause analysis. Self-dispatches: `test-writer` → `code-reviewer` → `commit` |
| `test-writer` | sonnet | Jest/Vitest/RTL/Playwright tests with behavior-based queries. Self-dispatches: `code-reviewer` → `commit` |
| `code-reviewer` | haiku | Diff-focused review. Emits Work Log + structured Status Block. `disallowedTools: Write, Edit` |
| `data-scientist` | sonnet | SQL queries, BigQuery analysis, data visualization |
| `db-reader` | haiku | Read-only SQL exploration — write operations blocked at hook level |
| `commit` | haiku | Semantic commits via `CAST_COMMIT_AGENT=1` escape hatch. Auto-chains `push` when "and push" is in the prompt |
| `security` | sonnet | OWASP review, secrets scanning, XSS/SQLi analysis |
| `push` | haiku | Managed push workflow with pre-push verification via `CAST_PUSH_OK=1` |
| `bash-specialist` | sonnet | CAST hook scripts, exit codes, `hookSpecificOutput` format — consulted when modifying CAST itself |
| `merge` | sonnet | Git merge, rebase, and conflict resolution — hard-blocks force-merges to main/master without explicit approval |

### Extended — 8 agents

| Agent | Model | Role |
|---|---|---|
| `architect` | sonnet | System design, ADRs, module boundaries, trade-off analysis |
| `tdd-guide` | sonnet | Red-green-refactor TDD workflow enforcement |
| `build-error-resolver` | haiku | Vite/CRA/TypeScript/ESLint errors, minimal diffs only. Self-dispatches: `code-reviewer` → `commit` |
| `e2e-runner` | sonnet | Playwright E2E with automatic stack discovery |
| `refactor-cleaner` | haiku | Dead code, unused imports, complexity reduction — batch-by-batch. Self-dispatches: `code-reviewer` → `commit` |
| `doc-updater` | haiku | README, changelog, JSDoc — generates diffs before applying. Self-dispatches: `commit` |
| `readme-writer` | sonnet | Full README audit against actual codebase — accuracy and positioning |
| `router` | haiku | NLU classifier for prompts that don't match regex routes |

### Orchestration — 5 agents

| Agent | Model | Role |
|---|---|---|
| `orchestrator` | sonnet | Reads Agent Dispatch Manifests, runs full queue with batch-aware status handling. Superseded by `cast exec` for direct plan execution. |
| `auto-stager` | haiku | Pre-commit staging — never stages `.env` or sensitive files |
| `chain-reporter` | haiku | Writes chain execution summaries to `~/.claude/reports/` |
| `verifier` | haiku | Build check and TODO scan before quality gate passes |
| `test-runner` | haiku | Runs test suite, parses output, dispatches `debugger` automatically on failure |

### Productivity — 5 agents

| Agent | Model | Role |
|---|---|---|
| `researcher` | sonnet | Tool/library evaluation, comparisons, pros/cons. Wired to browser for live docs |
| `report-writer` | haiku | Status reports, sprint summaries to `~/.claude/reports/` |
| `meeting-notes` | haiku | Extracts action items and decisions from raw meeting notes |
| `email-manager` | sonnet | Email triage and drafting (macOS + Outlook via AppleScript) |
| `morning-briefing` | sonnet | Calendar, inbox, reminders, git activity — assembled into a structured daily briefing |

### Professional — 3 agents

| Agent | Model | Role |
|---|---|---|
| `browser` | sonnet | Browser automation, screenshots, scraping, live documentation fetching |
| `qa-reviewer` | sonnet | Second-opinion QA on functional correctness — catches what `code-reviewer` misses |
| `presenter` | sonnet | Slide decks and status presentations from specs or notes |

### Specialist — 9 agents

| Agent | Model | Role |
|---|---|---|
| `devops` | sonnet | CI/CD pipelines, Dockerfile, GitHub Actions, deploy config |
| `performance` | sonnet | Core Web Vitals, bundle analysis, render performance |
| `seo-content` | haiku | Meta tags, accessibility, WCAG, localization |
| `linter` | haiku | Lint rule enforcement and auto-fix |
| `frontend-designer` | sonnet | Production-grade UI and design systems — avoids generic templates, covers React/Vue/Tailwind/MUI/shadcn |
| `framework-expert` | sonnet | Framework-native implementation for Laravel, Django, Rails, React, and Vue |
| `pentest` | sonnet | Automated security scanning, dependency audits, OWASP scanning — scans and reports only, never modifies files |
| `infra` | sonnet | Terraform/IaC and cloud resource provisioning (AWS, GCP, Azure); deeper infrastructure layer than `devops` |
| `db-architect` | sonnet | Schema design, migration authoring, and query optimization — write-capable counterpart to `db-reader` |

---

## The Commit → Push Chain

Raw `git commit` is hard-blocked by `pre-tool-guard.sh` (exit 2). The `commit` agent is the only path through:

```bash
# Blocked — pre-tool-guard.sh catches this and exits 2
git commit -m "message"

# The commit agent uses this escape hatch internally
CAST_COMMIT_AGENT=1 git commit -m "message"
```

The same applies to `git push`:

```bash
# Blocked
git push

# The push agent uses this escape hatch internally
CAST_PUSH_OK=1 git push
```

To push after committing, include "and push" in your original prompt. The `commit` agent detects this phrase and auto-chains `push`. You can also say "ship it" to trigger the full `ship-it` agent group, which runs `verifier` + `test-runner` + `devops` first, then commits and pushes.

### Rollback Protocol

When an orchestrator batch fails mid-execution, `cast-rollback.sh` restores the working tree to the pre-batch state:

```bash
# Review what will change (no changes applied)
CAST_ROLLBACK_DRY_RUN=1 cast-rollback.sh --batch <id>

# Apply rollback after reviewing the diff
cast-rollback.sh --batch <id>

# Or use a stash SHA directly
cast-rollback.sh --sha <stash-sha>
```

The orchestrator captures a `git stash create` SHA at the start of each code-modifying batch and writes it to `~/.claude/cast/rollback/batch-<id>.sha`. Stash files older than 7 days are surfaced as warnings in the pre-session briefing via the project board. Clean the old refs with `cast-rollback.sh --batch <id>` once a failed batch is resolved.

---

## Event-Sourcing Protocol

Every agent action writes an immutable, timestamped event file. State is derived from events by replaying them in order.

```
~/.claude/cast/
├── events/     # Immutable: {timestamp}-{agent}-{task_id}.json
├── state/      # Derived task state: {task_id}.json
├── reviews/    # Review decisions: {artifact_id}-{reviewer}-{timestamp}.json
└── artifacts/  # Plans, patches, test files
```

Each event file:

```json
{
  "event_id": "20260324T142301Z-debugger-batch-2",
  "timestamp": "2026-03-24T14:23:01Z",
  "agent": "debugger",
  "task_id": "batch-2",
  "parent_task_id": null,
  "event_type": "task_completed",
  "status": "DONE",
  "summary": "Fixed TypeError in auth middleware — null check added at line 47",
  "artifact_id": "batch-2-fix-20260324T142301Z.patch",
  "concerns": null
}
```

Seven event types: `task_created`, `task_claimed`, `task_completed`, `task_blocked`, `task_rejected`, `artifact_written`, `review_submitted`.

`cast-events.sh` exposes four shell functions: `cast_emit_event`, `cast_write_review`, `cast_derive_state`, `cast_read_board`. Source it from any agent or hook script.

---

## Quick Start

### Prerequisites

- [Claude Code](https://claude.ai/code) installed and authenticated
- `bash` (macOS, Linux, or WSL)
- `python3` in PATH (stdlib only — no pip packages required)

### Install

```bash
git clone https://github.com/ek33450505/claude-agent-team.git && cd claude-agent-team && bash install.sh
```

### Three modes

```
[1] Full    — all 42 agents, 32 commands, 13 skills, scripts, rules
[2] Core    — 11 core agents + their commands (minimal, portable)
[3] Custom  — choose categories: core, extended, productivity, professional, specialist
```

Your existing `~/.claude/` is backed up with a timestamp before anything is written.

### Post-install steps

**1. Wire the hooks** — merge `settings.template.json` into `~/.claude/settings.local.json`. CAST without hook wiring is an agent directory, not a system.

**2. Personalize three files:**

```
~/.claude/config.sh                    # Your project directories (sourced by skills)
~/.claude/rules/stack-context.md       # Your tech stack — agents read this on every invocation
~/.claude/rules/project-catalog.md    # Your projects — agents use for cross-repo context
```

**3. Rename the CLAUDE.md template:**

```bash
cp ~/.claude/CLAUDE.md.template ~/.claude/CLAUDE.md
```

This file contains the directive definitions. Without it, hooks inject directives that Claude has no instruction to follow.

**4. Verify your install:**

```bash
bash ~/.claude/scripts/cast-validate.sh
```

A clean install reports:

```
CAST Validate v1.9.0 (11 checks)
══════════════════════════════
✓ Hook wiring: route.sh, pre-tool-guard.sh, post-tool-hook.sh wired
✓ Agent frontmatter: 42 agents — all valid
✓ Routing table: 35 routes — schema valid
✓ CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] [CAST-DISPATCH-GROUP] present
✓ CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present
✓ cast-events.sh: installed at /Users/you/.claude/scripts/cast-events.sh
✓ agent-groups.json: 31 groups — present and valid
✓ cast-route-install.sh: present and executable (repo copy)
✓ stop-hook.sh: wired in settings.local.json
✓ routing-proposals.json: not present (proposals pipeline not yet run — OK)
✓ Security post_chain: security agent wired in ≥1 route (parallel or sequential)
══════════════════════════════
0 errors, 0 warnings
```

---

## cast CLI Reference

`cast` is the unified command-line interface for CAST. After install, it lives at `~/.claude/bin/cast` (symlinked to `/usr/local/bin/cast` or `~/bin/cast`).

```
cast <subcommand> [args] [--json] [--quiet] [--verbose]
```

### Subcommands

**`cast run`** — Run an agent synchronously or queue it for async execution.

```bash
cast run code-reviewer "Review src/auth.js"
cast run debugger "Fix failing tests" --async --priority 2
cast run planner "Plan the auth refactor" --model local
```

Flags: `--model local|cloud|auto`, `--priority 1-10`, `--async`

**`cast queue`** — Inspect and manage the async task queue (backed by SQLite).

```bash
cast queue list              # Show pending, claimed, and recently completed tasks
cast queue add debugger "Fix the auth bug"
cast queue cancel <task-id>
cast queue retry <task-id>
```

**`cast memory`** — Search and manage per-agent markdown memory.

```bash
cast memory search "auth middleware" --agent debugger
cast memory list --agent code-reviewer
cast memory forget <memory-id>
cast memory export --agent planner
```

**`cast budget`** — View and set API cost limits.

```bash
cast budget                        # Show today's spend and limits
cast budget set --global 10.00     # Set $10/day global limit
cast budget set --session 2.00     # Set $2/session limit
```

**`cast audit`** — Review the tool-use audit trail and manage PII redaction.

```bash
cast audit                         # Show recent audit log entries
cast audit --redact on             # Enable Presidio PII redaction pipeline
cast audit --since 24h             # Filter to last 24 hours
```

**`cast daemon`** — Control the background daemon (`castd`).

```bash
cast daemon status                 # Check castd running state and queue depth
cast daemon start                  # Start castd (launchctl or background process)
cast daemon start --airgap         # Start in air-gap mode (no outbound network)
cast daemon stop
cast daemon restart
cast daemon logs                   # Tail castd.log
```

**`cast airgap`** — Toggle and inspect air-gap mode.

```bash
cast airgap status
cast airgap on                     # Block all outbound LLM calls
cast airgap off
```

**`cast doctor`** — System health diagnostic. Runs 9 checks and prints a traffic-light report: cast.db accessible, schema current, hooks registered, hook scripts exist, events dir writable, routing_events populated, budget table, BATS available, version.

```bash
cast doctor
```

**`cast status`** — Terminal health dashboard: castd state, queue depth, budget.

```bash
cast status
```

**`cast install-completions`** — Install bash/zsh tab completions for the cast CLI.

```bash
cast install-completions
```

**`cast learn`** — Teach the routing table a new pattern directly from the command line.

```bash
# Add a new route
cast learn "\brefactor\b" refactor-cleaner --confidence soft --description "Refactor requests"

# Learn from the last session's unmatched and mismatched prompts (interactive)
cast learn --from-session
```

Each learned route is written to `routing-table.json` with `source='cast-learn'` and logged to `routing_events` with `action='learned'`. The `--from-session` mode surfaces prompts that either had no match or triggered a rapid re-prompt mismatch signal.

**`cast exec`** — Execute a task plan from the orchestrator. Dispatches parallel waves and sequential post-chains.

```bash
cast exec ~/.claude/plans/my-plan.json
cast exec <plan-file> --dry-run    # Show what would execute without running
cast exec <plan-file> --model local # Override model selection
```

Replaces the orchestrator agent for reproducible plan execution outside of Claude Code sessions.

**`cast compat`** — Test compatibility with Anthropic Claude Code hook updates.

```bash
cast compat test                      # Run full contract test suite
cast compat status                    # Show compatible hook versions
cast compat upgrade --check           # Check for available upgrades
```

Ensures CAST remains compatible as Claude Code's hook system evolves.

**`cast upgrade`** — Check for and apply new CAST versions.

```bash
cast upgrade check                    # Check for new releases
cast upgrade list                     # Show version changelog
cast upgrade apply <version>          # Apply a specific version
```

Watches the release channel and manages versioned upgrades safely.

---

## Slash Commands

32 commands at `~/.claude/commands/`. Use these as manual overrides when you know exactly which agent you want, or when automatic routing doesn't fire.

| Command | Agent | Model |
|---|---|---|
| `/plan` | planner | sonnet |
| `/debug` | debugger | sonnet |
| `/test` | test-writer | sonnet |
| `/review` | code-reviewer | haiku |
| `/commit` | commit | haiku |
| `/push` | push | haiku |
| `/secure` | security | sonnet |
| `/data` | data-scientist | sonnet |
| `/query` | db-reader | haiku |
| `/architect` | architect | sonnet |
| `/tdd` | tdd-guide | sonnet |
| `/e2e` | e2e-runner | sonnet |
| `/build-fix` | build-error-resolver | haiku |
| `/refactor` | refactor-cleaner | haiku |
| `/docs` | doc-updater | haiku |
| `/readme` | readme-writer | sonnet |
| `/research` | researcher | sonnet |
| `/report` | report-writer | haiku |
| `/meeting` | meeting-notes | haiku |
| `/email` | email-manager | sonnet |
| `/morning` | morning-briefing | sonnet |
| `/browser` | browser | sonnet |
| `/qa` | qa-reviewer | sonnet |
| `/present` | presenter | sonnet |
| `/stage` | auto-stager | haiku |
| `/verify` | verifier | haiku |
| `/orchestrate` | orchestrator | sonnet |
| `/cast` | router | haiku |
| `/cast-stats` | cast-stats.sh | — |
| `/chain-report` | chain-reporter | haiku |
| `/help` | — | — |
| `/eval` | — | — |

`/cast` is the universal fallback — it bypasses the regex layer entirely and uses NLU to classify intent and select the right agent.

`/cast-stats` runs `cast-stats.sh` directly, printing 8 sections: unmatched prompts, route match frequency, agent lifecycle events, loop breaks, model escalations, group dispatches, catch-all dispatches, and config errors.

---

## Memory

Agent memory is plain markdown files in `~/.claude/agent-memory-local/<agent-name>/`. Nothing is synced to the cloud. Open any file in any editor to see exactly what your agent remembers.

```
~/.claude/agent-memory-local/
├── debugger/
│   └── MEMORY.md       # What debugger has learned about your codebase
├── planner/
│   └── MEMORY.md       # Project patterns, recurring task shapes
├── code-reviewer/
│   └── MEMORY.md       # Your team's review preferences
└── ...
```

Not a vector database. Not an opaque embedding. A markdown file you can edit, back up, or delete.

`cast-agent-memory-init.sh` seeds these files automatically at session end (triggered by `stop-hook.sh`). For each of the 17 core agents, it writes project name, root path, recent task history (last 3 events from the event log), and any BLOCKED history. If a `MEMORY.md` already exists with a `## Custom Notes` section, that section is preserved — auto-init only rewrites the header and history blocks.

`cast memory search` (via the CLI) does full-text search across all agent memory files using grep-based substring matching.

---

## Skills

13 skills in `~/.claude/skills/`. Skills are reusable prompt fragments sourced by agents at runtime — not agents themselves.

| Skill | Platform | Purpose |
|---|---|---|
| `action-items` | all | Extract action items from text |
| `briefing-writer` | all | Assemble a structured daily briefing from component outputs |
| `git-activity` | all | Summarize recent git activity across configured projects |
| `careful-mode` | all | Slow down — confirm before each write |
| `freeze-mode` | all | Read-only mode — no writes, analysis only |
| `wizard` | all | Interactive step-by-step prompting for complex tasks |
| `plan` | all | Plan skill fragment used by planner agent |
| `merge` | all | Scenario detection and dispatch routing for git merge, rebase, and conflict resolution |
| `calendar-fetch` | macOS | Fetch today's calendar events (Microsoft Outlook) |
| `inbox-fetch` | macOS | Fetch unread emails (Microsoft Outlook) |
| `reminders-fetch` | macOS | Fetch pending reminders |
| `calendar-fetch-linux` | Linux | Stub for calendar-fetch |
| `inbox-fetch-linux` | Linux | Stub for inbox-fetch |

macOS skills require Microsoft Outlook. Linux installs receive stubs automatically.

---

## Privacy Layer

CAST includes a PII redaction pipeline that intercepts tool-use output before it is stored or logged.

**`cast-redact.py`** — Presidio-based redaction engine. Detects and masks: names, emails, phone numbers, IP addresses, credit card numbers, SSNs, and custom patterns defined in `config/redact-config.json`. Enabled by default (`redact_pii: true` in `config/cast-cli.json`) — disable with `cast audit --redact off`.

**`cast-audit-hook.sh`** — Writes every tool call (tool name, file path, truncated args) to an append-only audit log at `~/.claude/logs/cast-audit.jsonl`. Independent of the redaction pipeline — audit logging is always on.

**Air-gap mode** — `CAST_AIRGAP=1` blocks all outbound LLM API calls. Toggle via `cast airgap on/off` or `cast daemon start --airgap`.

```bash
# Inspect the audit trail
cast audit --since 24h

# Enable PII redaction
cast audit --redact on

# Run in full air-gap mode
cast daemon start --airgap
```

---

## Background Daemon (castd)

`castd` is a background process that polls the SQLite task queue and dispatches agents without requiring an active Claude Code session.

```
~/.claude/scripts/castd.sh          # Daemon process
~/.claude/logs/castd.log            # Daemon log
~/.claude/cast.db                   # SQLite queue and cost tracking
com.cast.daemon.plist               # launchd plist for macOS login-time launch
```

`castd` handles:
- Async task queue processing (tasks added via `cast queue add` or `cast run --async`)
- Budget monitoring and alerts when cost thresholds are hit
- Queue depth reporting (shown in `cast status` and the pre-session briefing)

Control the daemon:

```bash
cast daemon start      # Start (or register with launchctl on macOS)
cast daemon stop
cast daemon status     # PID, queue depth, last run timestamp
cast daemon logs       # Tail the daemon log
```

---

## macOS Integration

Phase 7g adds OS-level integration for macOS users. These components are optional and installed separately via `scripts/cast-install-7g.sh`.

**Status bar app** (`macos/cast-statusbar.py`) — A menu bar app (requires `rumps`) showing live agent activity, castd state, and current budget. Launches at login via `macos/cast-statusbar.plist`.

**Alfred workflow** (`macos/cast-alfred-workflow.json`) — Trigger any cast CLI subcommand from Alfred 5 without switching to a terminal. Includes keyword triggers for `cast run`, `cast status`, and common agent dispatches.

**File watcher** (`scripts/cast-fswatcher.sh`) — Watches configured directories with `fswatch` (macOS) or `inotifywait` (Linux) and enqueues agent tasks when matching file events fire. Rules defined in `config/fswatcher-config.json.template`.

**Notification Center** (`scripts/cast-notify.sh`) — Sends native macOS notifications (via `osascript`) or Linux `notify-send` alerts on agent completion, BLOCKED events, and budget threshold hits.

**Cross-machine sync** (`scripts/cast-sync.sh`) — `rsync`-based sync for `cast.db` and `agent-memory-local/` across multiple machines. Config in `config/sync-config.json.template`.

---

## Self-Learning Routing

Phase 9 adds a closed-loop learning layer. Three mechanisms feed routing intelligence back into the system automatically.

### Mismatch Detection

Every time a route fires, `route.sh` checks whether another route fired for the same session within the last 60 seconds. A rapid re-prompt after a route match is a signal that the first route was wrong. These events are stored in the `mismatch_signals` table.

### Memory-Assisted Routing

A third routing stage sits between pattern/semantic match and the no_match fallback. `cast-memory-router.py` tokenizes the incoming prompt and computes keyword overlap against every row in `agent_memories`. If any memory row scores >= 0.7 confidence, that agent is dispatched with `match_type='memory'`. This stage is always fail-safe — any error returns `{"agent": null}` and routing continues to no_match.

### cast learn

The `cast learn` subcommand lets you teach the routing table directly:

```bash
# Add a pattern → agent mapping
cast learn "\bdeploy\b" infra --confidence hard --description "Deployment requests"

# Review last session's misses and mismatches interactively
cast learn --from-session
```

### Mismatch Analyzer

`cast-mismatch-analyzer.sh` reads the `mismatch_signals` table and auto-generates proposals for routes with >= 10 signals. Proposals appear in `~/.claude/routing-proposals.json` with `source='mismatch'`, distinct from `source='no_match'` proposals generated by `cast-routing-feedback.sh`.

---

## Self-Improving Routing

The routing table is static by default but can evolve. `stop-hook.sh` runs `cast-routing-feedback.sh` weekly, which clusters unmatched prompts and writes candidate routing proposals to `~/.claude/routing-proposals.json`. You review and install them with two scripts:

```bash
# Review pending proposals (opens formatted display)
bash ~/.claude/scripts/cast-route-review.sh

# Approve one or more proposals and merge them into routing-table.json
bash ~/.claude/scripts/cast-route-install.sh --approve <proposal-id>

# Reject a proposal
bash ~/.claude/scripts/cast-route-install.sh --reject <proposal-id>

# List all proposals with status
bash ~/.claude/scripts/cast-route-install.sh --list

# Print count of pending proposals
bash ~/.claude/scripts/cast-route-install.sh --pending-count
```

Each proposal has a `status` field: `pending`, `installed`, or `rejected`. The pre-session briefing surfaces the pending count so you see it on the first prompt of each session.

---

## Agent Performance Profiling

`cast-agent-stats.sh` reads `~/.claude/routing-log.jsonl` and reports DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT rates per agent, with a composite health score.

```bash
# All-time stats for every agent (table format)
bash ~/.claude/scripts/cast-agent-stats.sh

# Single agent detail
bash ~/.claude/scripts/cast-agent-stats.sh --agent debugger

# Filter to last 7 days
bash ~/.claude/scripts/cast-agent-stats.sh --since 7d

# JSON output (for piping or dashboard ingestion)
bash ~/.claude/scripts/cast-agent-stats.sh --format json
```

Example output:

```
Agent Performance Report (last 7 days)
==============================================================
Agent                Runs   DONE    DWC    BLK  NEEDS  Score
--------------------------------------------------------------
code-reviewer          42    88%    10%     2%     0%     94
debugger               11    73%    18%     9%     0%     84
test-writer             8    75%    25%     0%     0%     90
--------------------------------------------------------------
  Total:               61    83%    13%     4%     0%
```

The Score column is `DONE% + DWC% × 0.60`, capped at 100. Use it to spot agents accumulating BLOCKED events before they affect velocity.

The pre-session briefing's Agent Health advisory is also derived from this data: if any agent has a BLOCKED rate >= 20% across 5+ runs, it appears as a warning on the first prompt of the next session.

---

## Dry-Run Mode

`CAST_DRY_RUN=1` runs the full routing pipeline without side effects. No `hookSpecificOutput` is emitted, no `routing-log.jsonl` entries are written, and no agent is dispatched. Instead, `route.sh` prints a JSON summary of what would have been dispatched:

```bash
echo '{"prompt": "debug this error"}' | CAST_DRY_RUN=1 bash ~/.claude/scripts/route.sh
```

```json
{
  "dry_run": true,
  "prompt": "debug this error",
  "matched_agent": "debugger",
  "match_type": "regex",
  "match_pattern": "\\bdebug\\b",
  "post_chain": null,
  "directive_would_be": "[CAST-DISPATCH] debugger"
}
```

`match_type` is one of `regex`, `group`, `memory`, `no_match`, or `catchall`. The integration test suite uses `CAST_DRY_RUN=1` to verify routing decisions against a minimal routing table without triggering live agent dispatches.

---

## ACI Reference Sections

Six core agent definitions include an `## ACI Reference` section — structured guidance for the orchestrating session on when to dispatch, what to include in the prompt, and how to handle edge cases:

| Agent | ACI topics covered |
|---|---|
| `code-writer` | Dispatch threshold (>1 file or >5 lines), prompt structure, parallel post_chain note |
| `code-reviewer` | What to include in review scope, when not to re-dispatch after self-dispatch |
| `debugger` | Escalation rule (>1 inline tool call → dispatch), what context to pass |
| `test-writer` | When to dispatch vs. inline, behavior-based query guidance |
| `bash-specialist` | When CAST hook script work requires this agent rather than inline editing |
| `commit` | Commit message conventions, "and push" detection, escape hatch usage |

The `## ACI Reference` sections address the most common dispatch mistakes: vague prompts, double-dispatching after self-dispatch, and handling `DONE_WITH_CONCERNS` before proceeding.

---

## Phase History

| Phase | Delivered |
|---|---|
| Phase 1 (2026-03-20) | Initial release: 24 agents, 24 commands, 9 skills, 3 lifecycle hooks. Regex routing + Opus escalation. Agent quality rubric. Cross-platform support (macOS + Linux/WSL). |
| Phase 2 (2026-03-21) | Auto-dispatch routing (1-step loop vs. 4-step). 4 new routes. False-positive fix for `<task-notification>` XML. `/help` command. Official rename to CAST. |
| Phase 3 | Parallel post-chain voting pattern. Agent groups (31 compound workflows). Pre-session briefing. Policy engine (`policies.json`). Dry-run mode. Event-sourcing protocol. |
| Phase 4 (2026-03-22) | Universal dispatcher (`/cast`). BATS test suite. Pattern simplification — NLU replaces broad regex. `stop-hook.sh`. Agent status reader. Rollback protocol. |
| Phase 5 (2026-03-22–26) | Agent performance profiling. Self-improving routing proposals pipeline. 6 specialist agents added (frontend-designer, framework-expert, pentest, infra, db-architect, merge). Merge skill. |
| Phase 6 | SQLite state foundation (`cast.db`). Background daemon (`castd`) with queue polling and offline mode. Agent memory evolution. PII redaction pipeline (Presidio). Audit hook. |
| Phase 7 (2026-03-26) | `cast` CLI (9 subcommands: run, queue, memory, budget, audit, airgap, daemon, status, install-completions). macOS OS-level integration: status bar app, Alfred workflow, file watcher, Notification Center, cross-machine sync. Air-gap mode. 35 routes. 205 tests. |
| Phase 9 (2026-03-27) | Self-learning routing: mismatch detection (rapid re-prompt signal → `mismatch_signals` table), memory-assisted routing pass (`cast-memory-router.py`, keyword overlap against `agent_memories`), `cast learn` subcommand (direct pattern install + `--from-session` mode), `cast-mismatch-analyzer.sh` (auto-proposals from mismatch data). DB migrated to v3. |
| Phase 9.9 (2026-03-27) | Pre-release systems check: dead code removal, `routing_events` column fix, `cast doctor` diagnostic command, privacy view wired to `audit.jsonl`, SSE auto-reconnect, error boundaries. 307 tests. v2.4. |

---

## Stats

| Metric | Count |
|---|---|
| Agents | 42 |
| Agent groups | 31 |
| Routes | 35 |
| Slash commands | 32 |
| Skills | 13 |
| Tests | 307 |
| Hook directives | 11 |
| post-tool-hook.sh parts | 5 |
| agent-status-reader responses | 5 |
| Event types | 7 |
| cast-stats.sh sections | 8 |
| cast-validate.sh checks | 11 |
| cast CLI subcommands | 10 |
| Agents with ACI Reference sections | 6 |

---

## Known Limitations

See [docs/known-limitations.md](docs/known-limitations.md) for details on:

- **SendMessage Gap** — orchestrator cannot resume after a network drop; workaround: checkpoint log + re-invocation with `pre_approved: true`
- **Agent tool depth** — nesting depth >= 3 may suppress self-dispatch chains; inline session acts as fallback enforcer
- **Turn ceiling** — orchestrator stops cleanly at turn 40 and checkpoints for manual resume
- **CAST-DEBUG silent suppression** — `post-tool-hook.sh` Part 5 uses `echo "$INPUT" | python3 - <<'PYEOF'`; in bash, the heredoc takes precedence as stdin for `python3 -`, leaving `sys.stdin` empty in the script. The `json.load(sys.stdin)` call raises and is caught by `|| true`. CAST-DEBUG directives are not emitted in the current implementation. The `[CAST-DEBUG]` directive in `CLAUDE.md` remains effective as a defined instruction; the auto-injection from the hook is the broken path.

---

## Companion

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — observability UI for CAST. Reads `routing-log.jsonl`, `agent-status/`, and `cast/` directories written by CAST hooks. Shows routing decisions, agent status, and chain execution history in a React dashboard. No backend, no database — filesystem scan only.

**Dashboard Pages:**
- `/activity` — Live stream of agent runs and dispatches
- `/sessions` — Session history and session detail view
- `/analytics` — Agent performance analytics
- `/analytics/agents/:agent` — Per-agent scorecard and metrics
- `/agents` — List of all 42 agents
- `/agents/:name` — Agent detail view
- `/routing` — Routing log and routing decision history
- `/hooks` — Hook health and event stream
- `/plans` — Stored plan files and plan detail views
- `/memory` — Memory browser with keyword search across agent memory files
- `/system` — System health, castd status, queue depth
- `/privacy` — Privacy audit log and redaction events
- `/token-spend` — Token usage tracking
- `/db` — SQLite explorer (read-only)

---

MIT License
