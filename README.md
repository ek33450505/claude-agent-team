# CAST — Claude Agent Specialist Team

![Version](https://img.shields.io/badge/version-1.5.0-blue)
![Agents](https://img.shields.io/badge/agents-<!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT -->-green)
![Routes](https://img.shields.io/badge/routes-<!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT -->-blue)
![Tests](https://img.shields.io/badge/tests-<!-- CAST_TEST_COUNT -->106<!-- /CAST_TEST_COUNT -->%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

Claude Code is a capable editor. Without infrastructure, you're still manually deciding which agent to call, remembering to run tests, remembering to review your own code, and typing `git commit` by hand. CAST is the infrastructure layer that removes that coordination overhead entirely.

Install CAST and every prompt you type is intercepted by `route.sh` before Claude sees it. The right specialist agent is dispatched automatically. After it writes code, `post-tool-hook.sh` injects a mandatory `[CAST-CHAIN]` directive that forces `code-reviewer` to run — you cannot skip it. Raw `git commit` is hard-blocked at the `PreToolUse` hook; the `commit` agent is the only escape hatch. Parallel agent waves handle complex multi-file work without you coordinating anything. Work Logs surface exactly what every agent did, inline in your terminal.

This is not a prompt library. It is <!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> specialists wired into Claude Code at the hook layer, enforcing their own quality gates.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

[Interactive Architecture Diagram](docs/architecture.html)

---

## How It Works

```
User Prompt
    |
    v
[Hook 1: UserPromptSubmit] -- route.sh
    |
    |-- agent-groups.json match (31 groups) -------> [CAST-DISPATCH-GROUP]
    |                                                    |
    |-- routing-table.json match (22 routes) --------> [CAST-DISPATCH]
    |                                                    |
    |-- catch-all: 5+ words, action verb, not question -> router agent (NLU)
    |
    v (no match)
Claude handles inline
    |
    v (Write or Edit tool fires on any matched path)
[Hook 2: PostToolUse] -- post-tool-hook.sh
    |-- prettier auto-format (JS/TS/CSS/JSON, if .prettierrc found)
    |-- main session + code file  -> [CAST-CHAIN]  (mandatory, non-skippable)
    |-- main session + other file -> [CAST-REVIEW] (soft review suggestion)
    |-- subagent + code file      -> [CAST-REVIEW] (reinforcing signal)
    |-- plan file with dispatch manifest -> [CAST-ORCHESTRATE]
    |
    v
code-reviewer (haiku) -- emits Work Log + Status Block
    |
    v
[Hook 2b: PostToolUse] -- agent-status-reader.sh
    | age guard: status files >60s ignored (stale cross-session protection)
    | BLOCKED -> [CAST-HALT] exit 2
    | DONE    -> log silently
    |
    v
[Hook 3: PreToolUse] -- pre-tool-guard.sh
    hard-block: git commit  (escape: CAST_COMMIT_AGENT=1 git commit ...)
    hard-block: git push    (escape: CAST_PUSH_OK=1 git push ...)
    |
    v
commit agent (haiku) -- CAST_COMMIT_AGENT=1 git commit
    |
    v
[Hook 4: Stop] -- unpushed-commit check
    |
    v
cast-events.sh -- ~/.claude/cast/events/ (append-only, immutable)
```

**Five directives drive all of this.** They are defined in `CLAUDE.md` and treated as unconditional system-level instructions:

| Directive | Injected by | Behavior |
|---|---|---|
| `[CAST-DISPATCH]` | `route.sh` via `UserPromptSubmit` | Dispatch the named agent. Do not handle inline. |
| `[CAST-CHAIN]` | `post-tool-hook.sh` (code files, main session) | Dispatch the listed agents in sequence. Non-skippable. |
| `[CAST-REVIEW]` | `post-tool-hook.sh` (non-code files, subagent context) | Soft: dispatch `code-reviewer` if the change is significant. |
| `[CAST-DISPATCH-GROUP]` | `route.sh` (agent-groups.json match) | Execute the named group: waves in order, post-chain after final wave. |
| `[CAST-ORCHESTRATE]` | `post-tool-hook.sh` (plan files with dispatch manifest) | Dispatch `orchestrator` with the plan file path. |

`confidence: "hard"` produces `MANDATORY: Dispatch the agent`. `confidence: "soft"` produces `RECOMMENDED: Consider dispatching`. No routing match and no catch-all hit means `route.sh` outputs nothing — Claude handles inline.

---

## Routing

`route.sh` runs on every user prompt via the `UserPromptSubmit` hook. Routing has three stages, evaluated in order:

**Stage 1 — Agent Group pre-check:** matches against `config/agent-groups.json` (31 groups). On match, the orchestrator receives a full Payload JSON with wave definitions and runs them immediately.

**Stage 2 — Routing table:** matches against `config/routing-table.json` (<!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> routes). On match, Claude sees:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: debugger (confidence: hard)\nMANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).\nPass the user's full prompt as the agent task. Do NOT handle this inline.\n[CAST-CHAIN] After debugger completes: dispatch `code-reviewer` in sequence."
  }
}
```

**Stage 3 — Catch-all:** fires when no route matched, the prompt is 5+ words, is not a question, and contains an action verb (`fix`, `add`, `implement`, `build`, etc.). Routes to the `router` agent (haiku) for NLU classification. If `router` returns confidence < 0.7, it returns `"main"` and Claude handles inline.

Every routing decision — match, no-match, catch-all, group dispatch — is logged to `~/.claude/routing-log.jsonl`. The [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) companion reads this file for observability.

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

The Status Block is also read by `agent-status-reader.sh` at the `PostToolUse` hook. A `BLOCKED` status emits `[CAST-HALT]` (exit 2), halting execution until the block is resolved.

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

## The Agents (<!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT -->)

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
| `test-runner` | sonnet | Runs test suite, parses output, dispatches `debugger` automatically on failure |

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
| `seo-content` | sonnet | Meta tags, accessibility, WCAG, localization |
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
[1] Full    — all 36 agents, 26 commands, 9 skills, scripts, rules
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
CAST Validate v1.7.0 (7 checks)
══════════════════════════════
  Hook wiring: route.sh, pre-tool-guard.sh, post-tool-hook.sh wired
  Agent frontmatter: 36 agents — all valid
  Routing table: 22 routes — schema valid
  CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] [CAST-DISPATCH-GROUP] present
  CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present
  cast-events.sh: installed at /Users/you/.claude/scripts/cast-events.sh
  agent-groups.json: 31 groups — present and valid
══════════════════════════════
0 errors, 0 warnings
```

---

## Slash Commands

26 commands at `~/.claude/commands/`. Use these as manual overrides when you know exactly which agent you want, or when automatic routing doesn't fire.

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
| `/cast` | router | haiku |
| `/eval` | — | — |

`/cast` is the universal fallback — it bypasses the regex layer entirely and uses NLU to classify intent and select the right agent.

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
  "timestamp": "20260324T142301Z",
  "agent": "debugger",
  "task_id": "batch-2",
  "event_type": "task_completed",
  "status": "DONE",
  "summary": "Fixed TypeError in auth middleware — null check added at line 47",
  "artifact_id": "batch-2-fix-20260324T142301Z.patch"
}
```

Six event types: `task_created`, `task_claimed`, `task_completed`, `task_blocked`, `artifact_written`, `review_submitted`.

---

## Stats

| Metric | Count |
|---|---|
| Agents | <!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> |
| Agent groups | 31 |
| Routes | <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> |
| Commands | 26 |
| Skills | <!-- CAST_SKILL_COUNT -->12<!-- /CAST_SKILL_COUNT --> |
| Tests | <!-- CAST_TEST_COUNT -->106<!-- /CAST_TEST_COUNT --> |
| Hook directives | 5 |

---

## Companion

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — observability UI for CAST. Reads `routing-log.jsonl`, `agent-status/`, and `cast/` directories written by CAST hooks. Shows routing decisions, agent status, and chain execution history in a React dashboard.

---

MIT License
