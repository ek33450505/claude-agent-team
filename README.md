# CAST — Claude Agent Specialist Team

<!-- CAST_VERSION_BADGE -->![Version](https://img.shields.io/badge/version-1.5.0-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-36-green)
![Routes](https://img.shields.io/badge/routes-28-blue)
![Commands](https://img.shields.io/badge/commands-32-blue)
![Tests](https://img.shields.io/badge/tests-138%20total-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

Claude Code is a capable editor. Without infrastructure, you are still manually deciding which agent to call, remembering to run tests, remembering to review your own code, and typing `git commit` by hand. CAST is the infrastructure layer that removes that coordination overhead entirely.

Install CAST and every prompt you type is intercepted by `route.sh` before Claude sees it. The right specialist agent is dispatched automatically. After it writes code, `post-tool-hook.sh` injects a mandatory `[CAST-CHAIN]` directive that forces `code-reviewer` to run — you cannot skip it. Raw `git commit` is hard-blocked at the `PreToolUse` hook; the `commit` agent is the only escape hatch. Parallel agent waves handle complex multi-file work without you coordinating anything. Work Logs surface exactly what every agent did, inline in your terminal.

This is not a prompt library. It is 36 specialists wired into Claude Code at the hook layer, enforcing their own quality gates.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

[Interactive Architecture Diagram](docs/architecture.html)

---

## Table of Contents

- [How It Works](#how-it-works)
- [Hook Directives](#hook-directives)
- [Routing](#routing)
- [post-tool-hook.sh — Five Parts](#post-tool-hooksh--five-parts)
- [agent-status-reader.sh — Status Propagation](#agent-status-readersh--status-propagation)
- [Work Logs](#work-logs)
- [Parallel Agent Waves](#parallel-agent-waves)
- [The Agents (36)](#the-agents-36)
- [The Commit → Push Chain](#the-commit--push-chain)
- [Rollback Protocol](#rollback-protocol)
- [Event-Sourcing Protocol](#event-sourcing-protocol)
- [Installation](#installation)
- [Slash Commands](#slash-commands)
- [Memory](#memory)
- [Skills](#skills)
- [Stats](#stats)
- [Companion](#companion)

---

## How It Works

```
User Prompt
    |
    v
[Hook 1: UserPromptSubmit] -- route.sh
    |
    |-- agent-groups.json match (31 groups) ------> [CAST-DISPATCH-GROUP]
    |                                                    |
    |-- routing-table.json match (28 routes) -------> [CAST-DISPATCH]
    |                                                    |
    |-- catch-all: 5+ words, action verb, not question -> router agent (NLU)
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

**Three enforcement tiers** operate in parallel. They are not redundant — each catches what the others cannot:

| Tier | Mechanism | Enforces |
|---|---|---|
| Advisory | `CLAUDE.md` directive definitions | Claude's understanding of the protocol |
| Behavioral | `route.sh` hookSpecificOutput injection | Claude's next action (alongside the prompt) |
| Hard | `pre-tool-guard.sh` exit 2 | OS-level block — Claude cannot bypass |

`confidence: "hard"` produces `MANDATORY: Dispatch the agent`. `confidence: "soft"` produces `RECOMMENDED: Consider dispatching`. No routing match and no catch-all hit means `route.sh` outputs nothing — Claude handles inline.

**Tier 2 supervisory layer** — five capabilities that run at session boundaries, not per-prompt:

| Capability | Script | When | Output |
|---|---|---|---|
| Pre-session briefing | `route.sh` | First prompt of every new session | `[CAST-SESSION-BRIEFING]` with git status, last 3 routing events, BLOCKED agents, project board snapshot |
| Policy engine | `pre-tool-guard.sh` | Every Write/Edit tool call | `[CAST-POLICY-BLOCK]` exit 2 if path matches a policy rule and required agent hasn't run |
| Routing feedback | `cast-routing-feedback.sh` | Session end, weekly | `~/.claude/reports/routing-gaps-YYYY-MM-DD.md` with top-5 unmatched prompt clusters |
| Project board | `cast-board.sh` | Session end | `~/.claude/cast/project-board.json` with blocked/in-flight tasks and stale rollback refs |
| Agent memory init | `cast-agent-memory-init.sh` | Session end | Seeds each agent's `MEMORY.md` with project context and recent dispatch history |

Policy rules live in `config/policies.json`. Four rules ship by default: auth files, DB migrations, GitHub workflows, and `.env` files each require the appropriate specialist agent before modification. Override any block with `CAST_POLICY_OVERRIDE=1`.

The project board snapshot is consumed by the pre-session briefing: on the first prompt of a new session, `route.sh` reads `project-board.json` and surfaces blocked tasks, in-flight tasks, and stale rollback checkpoints as context before routing begins.

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
| `[CAST-ORCHESTRATE]` | `post-tool-hook.sh` Part 3 | Plan file with dispatch manifest written — dispatch `orchestrator`. |
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

**Stage 1 — Agent Group pre-check:** matches against `config/agent-groups.json` (31 groups). On match, the orchestrator receives a full Payload JSON with wave definitions and runs them immediately.

**Stage 2 — Routing table:** matches against `config/routing-table.json` (28 routes). On match, Claude sees:

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

## The Agents (36)

### Core — 11 agents

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
| `orchestrator` | sonnet | Reads Agent Dispatch Manifests, runs full queue with batch-aware status handling |
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

### Specialist — 4 agents

| Agent | Model | Role |
|---|---|---|
| `devops` | sonnet | CI/CD pipelines, Dockerfile, GitHub Actions, deploy config |
| `performance` | sonnet | Core Web Vitals, bundle analysis, render performance |
| `seo-content` | haiku | Meta tags, accessibility, WCAG, localization |
| `linter` | haiku | Lint rule enforcement and auto-fix |

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

## Installation

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
[1] Full    — all 36 agents, 32 commands, 12 skills, scripts, rules
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
CAST Validate v1.8.0 (10 checks)
══════════════════════════════
✓ Hook wiring: route.sh, pre-tool-guard.sh, post-tool-hook.sh wired
✓ Agent frontmatter: 36 agents — all valid
✓ Routing table: 28 routes — schema valid
✓ CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] [CAST-DISPATCH-GROUP] present
✓ CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present
✓ cast-events.sh: installed at /Users/you/.claude/scripts/cast-events.sh
✓ agent-groups.json: 31 groups — present and valid
✓ cast-route-install.sh: present and executable (repo copy)
✓ stop-hook.sh: wired in settings.local.json
✓ routing-proposals.json: not present (proposals pipeline not yet run — OK)
══════════════════════════════
0 errors, 0 warnings
```

The validator checks three additions introduced in v1.8.0:

| Check | What it verifies |
|---|---|
| 8 | `cast-route-install.sh` present and executable (routing proposal approval pipeline) |
| 9 | `stop-hook.sh` wired in `settings.local.json` (chain-reporter auto-dispatch at session end) |
| 10 | `routing-proposals.json` schema valid, if present (generated proposals are structurally correct) |

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

---

## Skills

12 skills in `~/.claude/skills/`. Skills are reusable prompt fragments sourced by agents at runtime — not agents themselves.

| Skill | Purpose |
|---|---|
| `action-items` | Extract action items from text |
| `briefing-writer` | Assemble a structured daily briefing from component outputs |
| `git-activity` | Summarize recent git activity across configured projects |
| `careful-mode` | Slow down — confirm before each write |
| `freeze-mode` | Read-only mode — no writes, analysis only |
| `wizard` | Interactive step-by-step prompting for complex tasks |
| `calendar-fetch` | Fetch today's calendar events (macOS/Outlook) |
| `inbox-fetch` | Fetch unread emails (macOS/Outlook) |
| `reminders-fetch` | Fetch pending reminders (macOS) |
| `calendar-fetch-linux` | Linux stub for calendar-fetch |
| `inbox-fetch-linux` | Linux stub for inbox-fetch |
| `plan` | Plan skill fragment used by planner agent |

macOS skills (calendar, inbox, reminders) require Microsoft Outlook. Linux installs receive stubs automatically.

---

## Self-Improving Routing

The routing table is static by default but can evolve. `stop-hook.sh` runs `cast-routing-feedback.sh` weekly, which clusters unmatched prompts and writes candidate routing proposals to `~/.claude/routing-proposals.json`. You review and install them with two scripts:

```bash
# Review pending proposals (opens formatted display)
bash ~/.claude/scripts/cast-route-review.sh

# Approve one proposal and merge it into routing-table.json
bash ~/.claude/scripts/cast-route-install.sh --install <proposal-id>

# Reject a proposal
bash ~/.claude/scripts/cast-route-install.sh --reject <proposal-id>

# List all proposals with status
bash ~/.claude/scripts/cast-route-install.sh --list
```

Each proposal has a `status` field: `pending`, `installed`, or `rejected`. The pre-session briefing surfaces the pending count so you see it on the first prompt of each session.

`cast-validate.sh` Check 8 confirms `cast-route-install.sh` is present and executable. Check 10 validates the proposals file schema if it exists.

---

## Stats

| Metric | Count |
|---|---|
| Agents | 36 |
| Agent groups | 31 |
| Routes | 28 |
| Slash commands | 32 |
| Skills | 12 |
| Tests | 138 |
| Hook directives | 11 |
| post-tool-hook.sh parts | 5 |
| agent-status-reader responses | 5 |
| Event types | 7 |
| cast-stats.sh sections | 8 |
| cast-validate.sh checks | 10 |

---

## Known Limitations

See [docs/known-limitations.md](docs/known-limitations.md) for details on:

- **SendMessage Gap** — orchestrator cannot resume after a network drop; workaround: checkpoint log + re-invocation with `pre_approved: true`
- **Agent tool depth** — nesting depth ≥ 3 may suppress self-dispatch chains; inline session acts as fallback enforcer
- **Turn ceiling** — orchestrator stops cleanly at turn 40 and checkpoints for manual resume
- **CAST-DEBUG silent suppression** — `post-tool-hook.sh` Part 5 uses `echo "$INPUT" | python3 - <<'PYEOF'`; in bash, the heredoc takes precedence as stdin for `python3 -`, leaving `sys.stdin` empty in the script. The `json.load(sys.stdin)` call raises and is caught by `|| true`. CAST-DEBUG directives are not emitted in the current implementation. The `[CAST-DEBUG]` directive in `CLAUDE.md` remains effective as a defined instruction; the auto-injection from the hook is the broken path.

---

## Companion

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — observability UI for CAST. Reads `routing-log.jsonl`, `agent-status/`, and `cast/` directories written by CAST hooks. Shows routing decisions, agent status, and chain execution history in a React dashboard.

---

MIT License
