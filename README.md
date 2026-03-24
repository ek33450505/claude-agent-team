# CAST — Claude Agent Specialist Team

![Version](https://img.shields.io/badge/version-1.5.0-blue)
![Agents](https://img.shields.io/badge/agents-31-green)
![Tests](https://img.shields.io/badge/tests-86%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

**The right specialist. Every time. Automatically.**

CAST is a <!-- CAST_AGENT_COUNT -->31<!-- /CAST_AGENT_COUNT -->-agent development team embedded directly into Claude Code at the hook layer. When you type a prompt, three enforcement hooks intercept it — dispatching the right specialist, enforcing code review after every write, and hard-blocking raw `git commit`. No `/commands` required. No remembering which agent to call. Just type naturally and your expert team handles the rest.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

[Interactive Architecture Diagram](docs/architecture.html)

---

## The Problem

Claude Code out of the box is a generalist. Given free rein, it will write tests, review code, plan features, and commit changes — all inline, all as the most expensive model available. There is no enforcement layer. You have to remember to ask for the right specialist. You have to remember to run code review. You have to remember not to commit directly. You have to re-explain your stack at the start of every session.

The result is expensive, inconsistent, and undisciplined. A debugging task runs on Sonnet when it needed Haiku for review. A feature ships without a regression test. A commit goes out without a code review. Context about your project evaporates between sessions.

CAST solves this at the infrastructure layer — not by adding commands you have to remember, but by wiring enforcement directly into Claude Code's event system. Three hooks run before, during, and after every interaction. A routing engine matches your prompt against <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> patterns and dispatches the right specialist automatically. Model tier discipline is enforced at the route level — routine tasks route to Haiku, reasoning-heavy tasks route to Sonnet, and Opus escalation is opt-in. Agent memory persists across sessions so your context survives a window close.

This is infrastructure. It runs underneath every prompt, every session, every project.

---

## Architecture

```
User Prompt
    |
    v
[Hook 1: UserPromptSubmit] ── route.sh ── 21-route regex engine
    | match                              | no match
    v                                   v
[CAST-DISPATCH] injected          Claude handles inline
    |
    v
Agent executes (haiku / sonnet / opus tier discipline)
    |
    v (Write/Edit tool fires)
[Hook 2: PostToolUse] ── post-tool-hook.sh
    | --> [CAST-REVIEW] injected into main session context
    | --> prettier auto-format (JS/TS/CSS/JSON)
    | --> [CAST-ORCHESTRATE] if plan file contains dispatch manifest
    v
code-reviewer (haiku) emits Status Block JSON
    |
    v
[Hook 2b: PostToolUse] ── agent-status-reader.sh  (subagent context)
    | BLOCKED --> [CAST-HALT] exit 2       | DONE --> log silently
    v                                      v
[Hook 3: PreToolUse] ── pre-tool-guard.sh
    hard-blocks: git commit (escape: CAST_COMMIT_AGENT=1)
    hard-blocks: git push   (escape: CAST_PUSH_OK=1)
    |
    v
commit agent (haiku) --> CAST_COMMIT_AGENT=1 git commit
    |
    v
[Hook 4: Stop] ── unpushed-commit check
    |
    v
cast-events.sh --> ~/.claude/cast/events/ (append-only, immutable)
    |
    v
Dashboard (routing-log.jsonl + agent-status/ + cast/ dirs)
```

Pure config, shell scripts, and markdown. Zero custom application code to maintain.

### How Dispatch Works

`route.sh` runs on every user prompt via the `UserPromptSubmit` hook. It matches against `routing-table.json` and outputs structured JSON that Claude Code injects directly into Claude's context window alongside the prompt.

On a match:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: debugger (confidence: hard)\nMANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).\nPass the user's full prompt as the agent task. Do NOT handle this inline.\n[CAST-CHAIN] After debugger completes: dispatch `code-reviewer` -> `commit` in sequence."
  }
}
```

Claude sees `[CAST-DISPATCH]` as a system-level directive. `CLAUDE.md` (60 lines, intentionally minimal) defines three directives Claude must obey unconditionally:

| Directive | Meaning |
|---|---|
| `[CAST-DISPATCH]` | Dispatch the named agent via the Agent tool. Do not handle inline. |
| `[CAST-REVIEW]` | Dispatch `code-reviewer` (haiku) after completing the current logical unit. |
| `[CAST-CHAIN]` | After the primary agent completes, dispatch the listed agents in sequence. |

`confidence: "hard"` produces `MANDATORY: Dispatch the agent`. `confidence: "soft"` produces `RECOMMENDED: Consider dispatching`. On no match, `route.sh` outputs nothing and Claude handles the prompt inline.

---

## What's New in v1.5.0

| Feature | What changed |
|---|---|
| Event-sourcing protocol | `cast-events.sh` replaces mutable `task-board.json` — immutable append-only events with derived state |
| Status Block Protocol | Machine-readable JSON enforcement via `agent-status-reader.sh` PostToolUse hook |
| `cast-validate.sh` | 6-check installability CLI — verify your install before use |
| <!-- CAST_TEST_COUNT -->86<!-- /CAST_TEST_COUNT --> BATS tests | Full coverage: event-sourcing, status enforcement, validate CLI, routing, install |
| `push` agent + `/push` command | Managed push workflow with unpushed-commit Stop hook |
| Formal protocol spec | `docs/cast-protocol-spec.md` — 796 lines, 7 sections |
| Dashboard integration contract | `docs/dashboard-integration.md` — schema for routing-log.jsonl, agent-status/, cast/ dirs |
| `uninstall.sh` + `VERSION` file | Clean removal; version pinned at 1.5.0 |
| Routing hardening | ReDoS protection (pattern length cap at 200 chars), log rotation at 5MB, `session_id` in every log entry |
| `test-runner` agent | Wired to `debugger` fallback on test failure — automatic |
| `researcher` agent | Wired to `browser` for live documentation fetching |
| `code-reviewer` `Recommended agents:` | Structured field in Status Block — machine-readable follow-up suggestions |
| `gen-stats.sh` | Sentinel-token README updater called from `install.sh` automatically |

---

## Agent Directory

<!-- CAST_AGENT_COUNT -->31<!-- /CAST_AGENT_COUNT --> specialist agents across 5 tiers. Model tier is enforced at the routing layer — haiku for mechanical tasks, sonnet for reasoning-heavy work.

### Core Tier (9 agents)

These agents form the foundation of every CAST install. Every quality gate flows through this tier.

| Agent | Model | Role | Self-Dispatch Chain |
|---|---|---|---|
| `planner` | sonnet | Task planning with Agent Dispatch Manifest output | → orchestrator (via manifest) |
| `debugger` | sonnet | Errors, stack traces, unexpected behavior — root cause analysis | → test-writer → code-reviewer → commit |
| `test-writer` | sonnet | Jest/Vitest/RTL/Playwright tests with behavior-based queries and edge case coverage | → code-reviewer → commit |
| `code-reviewer` | haiku | Diff-focused review: readability, correctness, naming, error handling. Emits `Recommended agents:` field | — |
| `data-scientist` | sonnet | SQL queries, BigQuery analysis, data visualization | — |
| `db-reader` | haiku | Read-only SQL exploration — write operations blocked at hook level | — |
| `commit` | haiku | Semantic commits with staged content verification — uses `CAST_COMMIT_AGENT=1` escape hatch | — |
| `security` | sonnet | OWASP review, secrets scanning, XSS/SQLi analysis | — |
| `push` | haiku | Managed push workflow with pre-push verification | — |

### Extended Tier (8 agents)

Specialist agents for common development workflows.

| Agent | Model | Role | Self-Dispatch Chain |
|---|---|---|---|
| `architect` | sonnet | System design, ADRs, module boundaries, trade-off analysis | — |
| `tdd-guide` | sonnet | Red-green-refactor TDD workflow enforcement | — |
| `build-error-resolver` | haiku | Vite/CRA/TypeScript/ESLint errors, minimal diffs only | → code-reviewer → commit |
| `e2e-runner` | sonnet | Playwright E2E with automatic stack discovery | — |
| `refactor-cleaner` | haiku | Dead code, unused imports, complexity reduction — batch-by-batch | → code-reviewer → commit |
| `doc-updater` | haiku | README, changelog, JSDoc — generates diffs before applying | → commit |
| `readme-writer` | sonnet | Full README audit against actual codebase — accuracy + positioning | → commit |
| `router` | haiku | LLM classifier for prompts that don't match regex routes | — |

### Orchestration Tier (5 agents)

Control-plane agents that coordinate multi-agent workflows and enforce quality gates.

| Agent | Model | Role | Self-Dispatch Chain |
|---|---|---|---|
| `orchestrator` | sonnet | Reads Agent Dispatch Manifests, runs full queue with batch-aware status handling | — |
| `auto-stager` | haiku | Pre-commit staging, never stages `.env` or sensitive files | — |
| `chain-reporter` | haiku | Writes chain execution summaries to `~/.claude/reports/` | — |
| `verifier` | haiku | Build check + TODO scan before quality gate passes | — |
| `test-runner` | sonnet | Runs test suite, parses output, dispatches `debugger` automatically on failure | → debugger |

### Productivity Tier (5 agents)

Agents that automate developer productivity workflows — morning briefings, email triage, reports.

| Agent | Model | Role | Self-Dispatch Chain |
|---|---|---|---|
| `researcher` | sonnet | Tool/library evaluation, comparisons, pros/cons | → browser (for live docs) |
| `report-writer` | haiku | Status reports, sprint summaries → `~/.claude/reports/` | — |
| `meeting-notes` | haiku | Extracts action items and decisions from raw meeting notes | — |
| `email-manager` | sonnet | Email triage and drafting (macOS + Outlook via AppleScript) | — |
| `morning-briefing` | sonnet | Calendar + inbox + reminders + git activity assembled into a structured daily briefing | — |

### Professional Tier (3 agents)

High-output agents for client-facing and cross-functional work.

| Agent | Model | Role | Self-Dispatch Chain |
|---|---|---|---|
| `browser` | sonnet | Browser automation, screenshots, scraping, live documentation fetching | — |
| `qa-reviewer` | sonnet | Second-opinion QA on functional correctness — catches what code-reviewer misses | — |
| `presenter` | sonnet | Slide decks and status presentations from specs or notes | — |

### Supporting (2 agents)

| Agent | Model | Role |
|---|---|---|
| `bash-specialist` | sonnet | CAST hook scripts, exit codes, `hookSpecificOutput` format — consulted when modifying CAST itself |
| `router` | haiku | NLU classifier — invoked by `/cast` for prompts that don't match routing patterns |

### Self-Dispatch Chains

The most important architectural feature you won't find in other agent frameworks: agents internally dispatch mandatory downstream agents. The hook layer catches misses. The self-dispatch layer is unconditional.

```
debugger completes fix
    --> test-writer (write regression test)
        --> code-reviewer (review test quality)
    --> code-reviewer (review the fix itself)
    --> commit

test-writer completes
    --> code-reviewer (behavior-based queries, edge case coverage)
    --> commit

refactor-cleaner completes batch
    --> code-reviewer (confirm no logic changed)
    --> commit

build-error-resolver passes build
    --> code-reviewer (confirm minimal diff)
    --> commit

planner writes plan file
    --> [CAST-ORCHESTRATE] injected by post-tool-hook.sh
    --> orchestrator reads manifest, presents queue for approval
    --> executes batches in order

test-runner detects failure
    --> debugger (automatic, no user prompt required)

researcher needs live docs
    --> browser (fetches current documentation)
```

Every chain is a quality guarantee: no code ships without review, no bug fix ships without a regression test, no plan executes without manifest approval.

---

## Slash Commands

<!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT --> commands at `~/.claude/commands/`. Use these as manual overrides when you know exactly which agent you want, or when automatic routing doesn't fire for your prompt.

| Command | Agent | Model | What it does |
|---|---|---|---|
| `/plan` | planner | sonnet | Task planning with Agent Dispatch Manifest |
| `/debug` | debugger | sonnet | Root cause analysis for errors and failures |
| `/test` | test-writer | sonnet | Write Jest/Vitest/RTL tests |
| `/review` | code-reviewer | haiku | Diff-focused code review |
| `/commit` | commit | haiku | Semantic commit with staged content verification |
| `/push` | push | haiku | Managed push with pre-push verification |
| `/secure` | security | sonnet | OWASP review, secrets scan |
| `/data` | data-scientist | sonnet | SQL queries, BigQuery analysis |
| `/query` | db-reader | haiku | Read-only SQL exploration |
| `/architect` | architect | sonnet | ADRs, system design, trade-offs |
| `/tdd` | tdd-guide | sonnet | Red-green-refactor TDD workflow |
| `/e2e` | e2e-runner | sonnet | Playwright E2E tests |
| `/build-fix` | build-error-resolver | haiku | Build and TypeScript errors |
| `/refactor` | refactor-cleaner | haiku | Dead code, cleanup, complexity |
| `/docs` | doc-updater | haiku | README, changelog, JSDoc |
| `/readme` | readme-writer | sonnet | Full README audit |
| `/research` | researcher | sonnet | Library/tool evaluation |
| `/report` | report-writer | haiku | Status reports, sprint summaries |
| `/meeting` | meeting-notes | haiku | Action items from meeting notes |
| `/email` | email-manager | sonnet | Email triage and drafting |
| `/morning` | morning-briefing | sonnet | Daily briefing: calendar + inbox + git |
| `/browser` | browser | sonnet | Browser automation and scraping |
| `/qa` | qa-reviewer | sonnet | Second-opinion QA review |
| `/present` | presenter | sonnet | Slide decks from specs |
| `/stage` | auto-stager | haiku | Pre-commit staging |
| `/verify` | verifier | haiku | Build check + TODO scan |
| `/orchestrate` | orchestrator | sonnet | Execute Agent Dispatch Manifest |
| `/chain-report` | chain-reporter | haiku | Write chain execution report |
| `/cast` | router | haiku | Universal dispatcher — NLU-based routing for any prompt |
| `/help` | — | — | Lists all agents, triggers, examples, and cost hints |

`/cast` is the universal fallback — it uses Claude's native language understanding to classify your intent and select the right agent, bypassing the regex layer entirely.

---

## Installation

### Prerequisites

- [Claude Code](https://claude.ai/code) installed and authenticated
- `bash` (macOS, Linux, or WSL)
- `python3` in PATH (stdlib only — no pip packages required)

### One-line install

```bash
git clone https://github.com/ek33450505/claude-agent-team.git && cd claude-agent-team && bash install.sh
```

### Three modes

| Mode | What you get | Best for |
|---|---|---|
| **[1] Full** | All <!-- CAST_AGENT_COUNT -->31<!-- /CAST_AGENT_COUNT --> agents, <!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT --> commands, <!-- CAST_SKILL_COUNT -->11<!-- /CAST_SKILL_COUNT --> skills, all scripts, rules | Most users |
| **[2] Core** | 9 essential agents + their commands, scripts, rules | Minimal installs, CI |
| **[3] Custom** | Choose categories: core, extended, productivity, professional | Power users |

Your existing `~/.claude/` is backed up with a timestamp before anything is written.

### Post-install steps

**1. Wire the hooks** — merge `settings.template.json` into `~/.claude/settings.local.json`.

**2. Personalize three files:**

```
~/.claude/config.sh                    # Your project directories (sourced by skills)
~/.claude/rules/stack-context.md       # Your tech stack — agents read this on every invocation
~/.claude/rules/project-catalog.md    # Your projects — agents use this for cross-repo context
```

**3. Verify your install:**

```bash
bash ~/.claude/scripts/cast-validate.sh
```

A clean install reports:

```
CAST Validate v1.6.0 (6 checks)
==============================
✓ Hook wiring: route.sh, pre-tool-guard.sh, post-tool-hook.sh wired
✓ Agent frontmatter: 31 agents — all valid
✓ Routing table: 22 routes — schema valid
✓ CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] present
✓ CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present
✓ cast-events.sh: installed at /Users/you/.claude/scripts/cast-events.sh
==============================
0 errors, 0 warnings
```

Fix any errors before use. CAST without hook wiring is an agent directory — not a system.

---

## Event-Sourcing Protocol

### Why append-only beats mutable state

The previous CAST version used `task-board.json` — a single mutable file that all agents wrote to. Two agents completing simultaneously would race. A failed agent left partial state. A crashed session left stale `IN_PROGRESS` entries that blocked future sessions.

v1.5.0 replaces this with an event-sourcing architecture: every agent action writes an immutable, timestamped event file. State is derived from events by replaying them in order. No agent ever overwrites another agent's data.

```
~/.claude/cast/
├── events/     # Immutable event files: {timestamp}-{agent}-{task_id}.json
├── state/      # Derived task state: {task_id}.json  (written by orchestrator)
├── reviews/    # Review decisions: {artifact_id}-{reviewer}-{timestamp}.json
└── artifacts/  # Plans, patches, test files
```

### Event schema

Each event file in `events/` contains:

```json
{
  "event_id": "20260324T142301Z-debugger-batch-2",
  "timestamp": "20260324T142301Z",
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

### Six event types

| Event type | When it fires |
|---|---|
| `task_created` | Orchestrator initializes a batch |
| `task_claimed` | Agent begins work on a task |
| `task_completed` | Agent finishes — carries final status |
| `task_blocked` | Agent cannot proceed — triggers halt |
| `artifact_written` | Agent writes a file (patch, test, plan) |
| `review_submitted` | `code-reviewer` emits approval or rejection |

### Querying state

```bash
# View current board (all tasks, derived from events)
source ~/.claude/scripts/cast-events.sh
cast_read_board

# Check if a task has required approvals before committing
cast_check_approvals "batch-2" "code-reviewer"

# Derive state for a specific task
cast_derive_state "batch-2"
```

The dashboard reads `~/.claude/cast/events/` directly — the append-only log is the source of truth. State files are caches. Neither is ever deleted.

---

## Status Block Protocol

Every CAST agent ends its response with a structured Status block. This is not a convention — it is a machine-readable contract that drives automatic routing, review triggers, and halt conditions.

### The four statuses

| Status | Meaning | System response |
|---|---|---|
| `DONE` | Task completed with no issues | Log to `agent-events.jsonl`, proceed to next batch |
| `DONE_WITH_CONCERNS` | Completed but issues found that need follow-up | `agent-status-reader.sh` injects `[CAST-REVIEW]` into main session |
| `BLOCKED` | Cannot proceed — unresolvable dependency or ambiguity | `agent-status-reader.sh` emits `[CAST-HALT]`, exits with code 2, halts parent session |
| `NEEDS_CONTEXT` | Missing information — pauses for clarification | Surfaces to user, re-dispatches with updated context |

### Text format (always required)

```
Status: DONE_WITH_CONCERNS
Summary: Refactored auth middleware — removed 3 unused imports, simplified token validation
Concerns: Line 89 in middleware.js — token expiry check may fail for tokens issued before UTC offset change
Recommended agents:
  - security: verify token validation logic at middleware.js:89 against OWASP JWT guidelines
  - test-writer: add edge case test for pre-offset tokens
```

### JSON format (machine-readable, written by status-writer.sh)

```json
{
  "agent": "refactor-cleaner",
  "status": "DONE_WITH_CONCERNS",
  "summary": "Refactored auth middleware — 3 unused imports removed",
  "concerns": "Line 89 — token expiry check may fail for pre-UTC-offset tokens",
  "recommended_agents": "security|test-writer",
  "timestamp": "20260324T142301Z"
}
```

### How agent-status-reader.sh processes status

`agent-status-reader.sh` runs as a `PostToolUse` hook in the subagent context (`CLAUDE_SUBPROCESS=1`). It reads the latest file in `~/.claude/agent-status/` and acts:

- **BLOCKED** — emits `[CAST-HALT]` message and exits with code 2. Exit code 2 is a hard block — Claude Code cannot bypass it. The parent session halts immediately and surfaces the blocker to the user.
- **DONE_WITH_CONCERNS** — injects `[CAST-REVIEW]` with the concerns and recommendations into the main session context. `code-reviewer` is dispatched before the next step.
- **DONE / NEEDS_CONTEXT** — exits 0 silently.

The `Recommended agents:` field is parsed by the orchestrator and main session — the recommending agent never auto-dispatches these itself. The decision to dispatch is always one level up.

### Writing status from a script

```bash
source ~/.claude/scripts/status-writer.sh

# On success
cast_write_status "DONE" "Fixed TypeError in auth middleware" "debugger"

# On concerns
cast_write_status "DONE_WITH_CONCERNS" \
  "Refactored auth middleware" \
  "refactor-cleaner" \
  "Line 89: token expiry edge case" \
  "security|test-writer"

# On blocker
cast_write_status "BLOCKED" \
  "Cannot resolve import — module not found" \
  "build-error-resolver" \
  "src/utils/auth.ts references @company/internal-sdk which is not in package.json"
```

---

## Hook Enforcement Layer

CAST uses four Claude Code lifecycle hooks. Together they form a complete enforcement perimeter around every development session.

### Hook 1 — UserPromptSubmit (`route.sh`)

Fires on every user prompt before Claude processes it. Matches the prompt against <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> routes in `routing-table.json`. On a match, injects `[CAST-DISPATCH]` into Claude's context. Also logs every prompt to `routing-log.jsonl` regardless of match status — no-match events are first-class observability data.

### Hook 2 — PostToolUse (`post-tool-hook.sh`)

Fires after every Write or Edit tool call. Three actions in sequence:

1. **Auto-format** — runs `prettier` on JS/TS/CSS/JSON files if a `.prettierrc` is found walking up the directory tree. Fires in all sessions including subagents.
2. **Review injection** — injects `[CAST-REVIEW]` into the main session context (not subagent context). `code-reviewer` (haiku) must run before the session continues.
3. **Manifest detection** — if the written file is a `.md` plan file containing a ` ```json dispatch ` block, injects `[CAST-ORCHESTRATE]`. The orchestrator is dispatched to present the queue for user approval.

### Hook 2b — PostToolUse (`agent-status-reader.sh`)

Fires in the subagent context (`CLAUDE_SUBPROCESS=1`). Reads the latest status file from `~/.claude/agent-status/`. Routes BLOCKED to `[CAST-HALT]` (exit 2) and DONE_WITH_CONCERNS to `[CAST-REVIEW]`. The main session hook and the subagent hook are intentionally separate — subagent writes do not trigger review injection in the main session.

### Hook 3 — PreToolUse (`pre-tool-guard.sh`)

Fires before every Bash tool call. Hard-blocks `git commit` and `git push` unless the escape hatch env var appears as a leading assignment before the git command.

```bash
# BLOCKED — exit 2, tool never runs
git commit -m "message"

# ALLOWED — commit agent workflow
CAST_COMMIT_AGENT=1 git commit -m "message"

# BLOCKED — message injection attempt
git commit -m "CAST_COMMIT_AGENT=1 message"  # The guard is not fooled

# BLOCKED — chained echo
echo "CAST_COMMIT_AGENT=1" && git commit       # Also blocked
```

Same pattern for `git push` with `CAST_PUSH_OK=1`.

### Hook 4 — Stop (prompt injection)

Fires before Claude delivers its final response. Checks whether the session made code changes without dispatching `code-reviewer`, or made commits without the commit agent. If either condition is true, the missing step is dispatched before the session closes. Also checks for unpushed commits and prompts the user.

### Escape hatches

| Env var | Allows |
|---|---|
| `CAST_COMMIT_AGENT=1` | `commit` agent to run `git commit` directly |
| `CAST_PUSH_OK=1` | `push` agent to run `git push` directly |

Both must appear as leading env var assignments immediately before the git command. They cannot appear inside commit messages, comments, or `echo` output.

---

## Routing Engine

The routing engine is a regex-based pattern matcher with <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> routes, ReDoS protection, log rotation, and per-session observability.

### How it works

`route.sh` reads `routing-table.json` on every prompt. Python's `re` module matches each route's `patterns` array against the lowercased prompt. First match wins. On a match, the engine injects a `[CAST-DISPATCH]` directive with the agent name, model, and post-chain. On no match, the engine logs `action: "no_match"` and exits with no output.

### Sample route entry

```json
{
  "patterns": [
    "fix.*bug", "\\bdebugg?ing\\b", "debug this",
    "traceback", "stack trace", "\\bnot working\\b",
    "\\bTypeError\\b", "\\bReferenceError\\b",
    "blank.*screen", "console.*error"
  ],
  "agent": "debugger",
  "model": "sonnet",
  "command": "/debug",
  "confidence": "hard",
  "post_chain": ["code-reviewer"]
}
```

### Confidence levels

| Confidence | Directive text | When to use |
|---|---|---|
| `hard` | `MANDATORY: Dispatch the agent` | Unambiguous task types (debugging, committing, building) |
| `soft` | `RECOMMENDED: Consider dispatching` | Ambiguous or overlapping patterns (planning, research) |

### Routing log schema

Every prompt — matched or not — writes to `~/.claude/routing-log.jsonl`:

```json
{
  "timestamp": "2026-03-24T14:23:01Z",
  "session_id": "sess_abc123",
  "prompt_preview": "fix the TypeError in the auth middleware",
  "action": "dispatched",
  "matched_route": "debugger",
  "command": "/debug",
  "pattern": "\\bTypeError\\b",
  "confidence": "hard"
}
```

### Safety features

- **ReDoS protection** — patterns longer than 200 characters are flagged as warnings by `cast-validate.sh` and skipped by the matcher
- **Log rotation** — `routing-log.jsonl` rotates at 5MB to `routing-log.jsonl.1`, `routing-log.jsonl.2`
- **Session ID** — `CLAUDE_SESSION_ID` env var is captured in every log entry for cross-session analysis
- **Subprocess guard** — `route.sh` exits immediately when `CLAUDE_SUBPROCESS=1` is set, preventing subagent prompts from triggering re-routing
- **System message skip** — `<task-notification>`, `<system->`, and `<task-id>` prefixes exit cleanly with no output

### Opus escalation

Prefix any prompt with `opus:` to escalate to the full model. The router logs `action: "opus_escalation"` and exits — Claude handles the prompt with no agent routing.

### Adding a route

Edit `~/.claude/config/routing-table.json` directly — `route.sh` reads the file on every prompt, no restart required:

```json
{
  "patterns": ["deploy.*staging", "push.*to.*staging", "^/deploy\\b"],
  "agent": "deploy-runner",
  "model": "sonnet",
  "command": "/deploy",
  "confidence": "hard",
  "post_chain": ["verifier", "commit"]
}
```

---

## Dashboard Integration

CAST writes structured data that the **[Claude Code Dashboard](https://github.com/ek33450505/claude-code-dashboard)** visualizes in real time. Install both and get a live observability layer over your entire Claude Code workflow.

### What CAST writes

| File / directory | Updated by | Contains |
|---|---|---|
| `~/.claude/routing-log.jsonl` | `route.sh` (every prompt) | Dispatch events, no-match events, opus escalations |
| `~/.claude/agent-status/` | `status-writer.sh` (each agent) | Per-agent status files with DONE/BLOCKED/concerns |
| `~/.claude/cast/events/` | `cast-events.sh` | Immutable append-only event log |
| `~/.claude/cast/state/` | `cast-events.sh` | Derived task state per task_id |
| `~/.claude/cast/reviews/` | `cast-events.sh` | Review decisions per artifact |

### What the dashboard shows

- Live routing feed — which agents are firing, which prompts match, which go inline
- Dispatch stats — hit rate by agent, miss rate, model distribution
- No-match analysis — prompts that didn't route (first signal for adding new routes)
- Agent status timeline — DONE / DONE_WITH_CONCERNS / BLOCKED history across sessions
- Plan viewer — Agent Dispatch Manifests from `~/.claude/plans/`
- Productivity output — briefings, reports, chain summaries

The dashboard auto-discovers agents from `~/.claude/agents/*.md` on every API call. It works with any Claude Code installation — CAST is not required to use the dashboard, but CAST is required for routing data.

### Dashboard integration contract

The full schema for every data structure is in `docs/dashboard-integration.md`. Key points:

- `routing-log.jsonl` rotates at 5MB — the dashboard must handle `.1` and `.2` files
- Agent status files are append-only, never overwritten — read newest by timestamp in filename
- `cast/` event files are immutable — never delete; the dashboard reads them as a log

---

## Local Memory Architecture

Two independent memory layers persist context across every session. Together they eliminate the "re-explain your stack" problem — every conversation starts informed.

### Agent memory

Each specialist maintains its own memory at `~/.claude/agent-memory-local/<agent>/MEMORY.md`. Memory is isolated per agent and per codebase. It is consulted at invocation time.

```
~/.claude/agent-memory-local/
├── planner/MEMORY.md          # Preferred plan formats, task sizing, batch structure
├── debugger/MEMORY.md         # Recurring failure patterns in this codebase
├── code-reviewer/MEMORY.md    # Project-specific review standards, what to ignore
├── commit/MEMORY.md           # Commit message style, branch conventions
├── test-writer/MEMORY.md      # Test patterns, framework setup, coverage targets
└── ... (one per agent)
```

The debugger remembers where bugs have appeared before. The code reviewer remembers your project's acceptable patterns. The commit agent remembers your message style. Each specialist improves over time for your specific working patterns — not globally.

### Rules layer

`~/.claude/rules/` sets behavioral context that loads into every session, regardless of which agent is running or which project is open.

```
~/.claude/rules/
├── working-conventions.md     # Quality gates: TDD, commit agent mandate, review mandate
├── stack-context.md           # Your tech stack: React version, test framework, DB, CSS lib
└── project-catalog.md         # Your projects: paths, stacks, notes per repo
```

**`working-conventions.md`** carries the same mandates as the hooks but in natural language — always use the commit agent, always invoke code-reviewer after changes. Claude reads this alongside hook directives.

**`stack-context.md`** means agents never guess your stack. The test-writer knows you're on Vitest, not Jest. The build-error-resolver knows you're on Vite, not webpack. The architect knows your ORM.

**`project-catalog.md`** gives agents a complete map of your workspace — which repos exist, where they live, what stack they use, and per-project notes. The debugger can cross-reference other projects. The planner can scope work against your actual repository structure.

### Output directories

```
~/.claude/briefings/           # morning-briefing output (daily markdown)
~/.claude/reports/             # chain-reporter and report-writer output
~/.claude/meetings/            # meeting-notes processor output
~/.claude/plans/               # planner output — JSON manifests + markdown specs
```

---

## Skills System

Skills are reusable multi-step procedures — composed workflows that agents invoke as sub-routines. Unlike slash commands (which dispatch a single agent), skills orchestrate sequences of tool calls and can be called from within any agent's context.

<!-- CAST_SKILL_COUNT -->11<!-- /CAST_SKILL_COUNT --> skills ship with CAST. The installer detects platform and installs Linux stubs for macOS-only skills.

| Skill | Platform | What it does |
|---|---|---|
| `calendar-fetch` | macOS + Outlook | Fetches today's calendar events via AppleScript — time blocks, meeting titles, durations |
| `inbox-fetch` | macOS + Outlook | Fetches unread emails, classifies by priority (action required vs. FYI) |
| `reminders-fetch` | macOS | Fetches due and overdue Apple Reminders tasks |
| `git-activity` | All | Scans all projects in your catalog for yesterday's commits |
| `action-items` | All | Extracts unchecked checkboxes from meeting notes files |
| `briefing-writer` | All | Assembles calendar, inbox, reminders, and git activity into a structured markdown briefing |
| `careful-mode` | All | Read-only session enforcement — blocks Write, Edit, and Bash operations |
| `freeze-mode` | All | Exploration mode — no modifications allowed |
| `wizard` | All | Multi-step workflow with human approval gates before destructive operations |

The `morning-briefing` agent chains six skills in sequence: `calendar-fetch` → `inbox-fetch` → `reminders-fetch` → `git-activity` → `action-items` → `briefing-writer`. The result is a structured markdown file at `~/.claude/briefings/YYYY-MM-DD.md` assembled from live data — calendar events, prioritized inbox, overdue tasks, and a summary of what you shipped yesterday. Run `/morning` once and get a complete briefing without touching email, calendar, or git log.

`careful-mode` and `freeze-mode` are safety modes for exploratory sessions where you want to read and analyze without any risk of modification. `wizard` adds human approval gates to workflows that include destructive operations.

---

## Testing

<!-- CAST_TEST_COUNT -->86<!-- /CAST_TEST_COUNT --> BATS tests covering the core protocol infrastructure.

### Running the suite

```bash
# Install BATS (once)
brew install bats-core         # macOS
apt-get install bats           # Ubuntu/Debian

# Run all tests
cd /path/to/claude-agent-team
bats tests/

# Run a specific suite
bats tests/cast-events.bats
bats tests/cast-validate.bats
```

### What's covered

| Test file | Tests | What it covers |
|---|---|---|
| `cast-events.bats` | 24 | Event emission, state derivation, review writing, board read, approval gating |
| `agent-status-reader.bats` | 17 | BLOCKED halt (exit 2), DONE_WITH_CONCERNS review injection, DONE passthrough, path canonicalization |
| `cast-validate.bats` | 16 | All 6 validation checks: hooks, frontmatter, routing schema, CLAUDE.md directives, CAST dirs, cast-events.sh |
| `route.bats` | 16 | Pattern matching, hard/soft confidence, no-match logging, system message skip, subprocess guard |
| `install.bats` | 13 | File placement, backup creation, directory structure, script permissions |

The test suite is the authoritative specification for the protocol contracts. If a behavior is tested, it is guaranteed. If you add a route, add a test.

---

## cast-validate.sh

Run this after every install, upgrade, or configuration change. It is the fastest way to confirm CAST is operational.

```bash
bash ~/.claude/scripts/cast-validate.sh
```

### Six checks

| Check | What it verifies |
|---|---|
| **Hook wiring** | `route.sh`, `pre-tool-guard.sh`, `post-tool-hook.sh` all appear in `~/.claude/settings.local.json` hooks |
| **Agent frontmatter** | Every `.md` in `~/.claude/agents/` has `name:`, `description:`, `tools:`, `model:` fields |
| **Routing table schema** | Every route has `patterns` (array), `agent` (string), `model` (string), `confidence` ("hard" or "soft") — patterns flagged if >200 chars |
| **CLAUDE.md directives** | `[CAST-DISPATCH]`, `[CAST-REVIEW]`, `[CAST-CHAIN]` all present in `~/.claude/CLAUDE.md` |
| **CAST directory structure** | `events/`, `state/`, `reviews/`, `artifacts/`, `agent-status/` all exist under `~/.claude/cast/` |
| **cast-events.sh installed** | `~/.claude/scripts/cast-events.sh` exists (required for event-sourcing protocol) |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks pass — system operational |
| `1` | Warnings only — CAST will function but may be degraded |
| `2` | One or more errors — fix before use |

---

## Dynamic Stats (gen-stats.sh)

Agent counts, command counts, test counts, and route counts in this README are maintained by sentinel tokens. A script updates them automatically whenever the counts change.

### Sentinel format

```html
<!-- CAST_AGENT_COUNT -->31<!-- /CAST_AGENT_COUNT -->
<!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT -->
<!-- CAST_SKILL_COUNT -->11<!-- /CAST_SKILL_COUNT -->
<!-- CAST_TEST_COUNT -->86<!-- /CAST_TEST_COUNT -->
<!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT -->
```

The tokens appear inline in prose and tables throughout the README. The script finds and replaces the content between each token pair.

### Running the updater

```bash
# Update README.md in-place
bash scripts/gen-stats.sh

# Update a different file
bash scripts/gen-stats.sh path/to/other.md
```

`gen-stats.sh` is called automatically by `install.sh` after copying files — the README is always current after install. Run it manually whenever you add agents, commands, or tests.

### What it counts

- **Agents** — `find agents/ -name "*.md" | wc -l`
- **Commands** — `find commands/ -name "*.md" | wc -l`
- **Skills** — `find skills/ -name "*.md" | wc -l`
- **Tests** — `grep -r "^@test" tests/ --include="*.bats" | wc -l`
- **Routes** — parses `config/routing-table.json` with Python

---

## Protocol Spec

`docs/cast-protocol-spec.md` — 796 lines. The authoritative specification for CAST-compatible agent systems.

Seven sections:

1. **Status Blocks** — text format, JSON format, field semantics for all four status values
2. **Escape Hatches** — env-var guards, valid usage, injection attack prevention
3. **Agent Dispatch Manifests** — batch structure, `parallel`/`sequential`/`fan-out` types, manifest schema
4. **Dispatch Directives** — `[CAST-DISPATCH]`, `[CAST-REVIEW]`, `[CAST-CHAIN]`, `[CAST-HALT]`, `[CAST-ORCHESTRATE]`
5. **Hook Event Model** — stdin/stdout contract for UserPromptSubmit, PreToolUse, PostToolUse, Stop
6. **Shared Task Board** — cross-agent progress tracking contract
7. **Fan-out Dispatch** — parallel multi-agent execution, output synthesis, context propagation

The protocol spec is what makes CAST extensible. Build a new agent that follows Section 1 (Status Blocks) and it integrates immediately with the orchestrator, status reader, and dashboard. Build a new hook script that follows Section 5 (Hook Event Model) and it integrates with the enforcement layer.

---

## Configuration

### CLAUDE.md

`CLAUDE.md.template` is 60 lines. This constraint is intentional — Claude Code loads this into every context window. A 230-line advisory document gets ignored when context pressure builds. A 60-line file with three unconditional directives does not.

The file defines: the three hook directives (mandatory), the inline whitelist (what Claude handles directly), the agent registry (model assignments), and the slash command list (manual overrides).

Do not expand it beyond 80 lines. Conciseness is the enforcement mechanism.

### settings.json hooks

The hook wiring in `settings.local.json` follows the Claude Code hook schema:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/scripts/route.sh" }] }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "bash ~/.claude/scripts/post-tool-hook.sh" }]
      },
      {
        "hooks": [{ "type": "command", "command": "bash ~/.claude/scripts/agent-status-reader.sh" }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash ~/.claude/scripts/pre-tool-guard.sh" }]
      }
    ]
  }
}
```

See `settings.template.json` for the full config including sandbox permissions.

### routing-table.json customization

The routing table is the primary extension point. Add routes, remove routes, change confidence levels, or modify post-chains — all without touching the hook scripts. Changes take effect on the next prompt.

---

## Planner Manifests and Orchestration

The `planner` agent produces a plan file with an embedded Agent Dispatch Manifest — a JSON block that the `orchestrator` reads to execute a full agent queue with one user approval.

Every manifest follows a 5-batch structure:

| Batch | Type | Purpose |
|---|---|---|
| 1 | parallel | Architecture and research review |
| 2 | sequential | Implementation (main model or specialist) |
| 3 | sequential | Spec compliance review — did we build exactly what was asked? |
| 4 | sequential | Code quality review + test writing |
| 5 | sequential | Commit |

Batches 3 and 4 are always separate and always sequential. Batch 3 checks whether every requirement was implemented and nothing extra was built. Batch 4 checks code quality. Merging them is disallowed by the planner's internal rules.

When `post-tool-hook.sh` detects a ` ```json dispatch ` block in a plan file, it injects `[CAST-ORCHESTRATE]`. The orchestrator is dispatched, presents the full queue to the user for one-shot approval, then executes batches in order.

The orchestrator handles four batch types:

| Type | Execution |
|---|---|
| `"parallel": true` | All agents dispatched simultaneously |
| `"parallel": false` | Single agent dispatched, waits for output before next |
| `"subagent_type": "main"` | Claude implements directly — no Agent tool call |
| `"type": "fan-out"` | Agents dispatched in parallel; outputs synthesized; summary passed as context to next batch |

After each batch, the orchestrator reads the status block. DONE proceeds. DONE_WITH_CONCERNS logs and continues. BLOCKED halts and surfaces to user. NEEDS_CONTEXT pauses for clarification.

---

## Token Efficiency

Haiku agents cost roughly 20x less than Opus and 5x less than Sonnet. CAST enforces model tier discipline automatically — the routing table is the budget enforcer.

| Task type | Model | Agents |
|---|---|---|
| Commit, review, docs, cleanup, build fixes, staging | haiku | `commit`, `code-reviewer`, `doc-updater`, `refactor-cleaner`, `build-error-resolver`, `auto-stager`, `db-reader`, `report-writer`, `meeting-notes`, `chain-reporter`, `verifier` |
| Debugging, planning, testing, architecture, security | sonnet | `debugger`, `planner`, `test-writer`, `architect`, `security`, `researcher`, `e2e-runner`, `data-scientist`, `orchestrator`, `morning-briefing`, `email-manager`, `browser`, `qa-reviewer`, `presenter`, `test-runner`, `readme-writer` |
| Full codebase analysis, system design | opus | Prefix any prompt with `opus:` to escalate |

Without enforcement, Claude Code defaults to running everything as the active model — typically Sonnet. Every haiku agent dispatched instead of Sonnet is a 5x cost reduction on that task.

---

## Repo Structure

```
claude-agent-team/                    # What you clone
├── install.sh                        # Interactive installer (full / core / custom)
├── uninstall.sh                      # Clean removal
├── VERSION                           # 1.5.0
├── CLAUDE.md.template                # 60-line directive file — 3 directives, agent registry
├── config.sh.template                # Shared project paths for skills and scripts
├── settings.template.json            # Hooks + sandbox config (merge into settings.local.json)
│
├── scripts/
│   ├── route.sh                      # UserPromptSubmit — dispatch injection + logging
│   ├── post-tool-hook.sh             # PostToolUse Write|Edit — review + prettier + manifest
│   ├── pre-tool-guard.sh             # PreToolUse Bash — hard-blocks git commit/push
│   ├── agent-status-reader.sh        # PostToolUse (subagent) — status propagation
│   ├── cast-events.sh                # Event-sourcing functions library
│   ├── status-writer.sh              # cast_write_status helper
│   ├── cast-validate.sh              # 6-check install verifier
│   └── gen-stats.sh                  # Sentinel token README updater
│
├── config/
│   └── routing-table.json            # 22 routes: patterns, agent, model, confidence, post_chain
│
├── agents/
│   ├── core/           (9 agents)
│   ├── extended/       (8 agents)
│   ├── orchestration/  (5 agents)
│   ├── productivity/   (5 agents)
│   └── professional/   (3 agents)
│
├── commands/           (30 commands) # One .md per slash command
├── skills/             (9 skills)    # Each in its own subdirectory with SKILL.md
│
├── rules/
│   ├── working-conventions.md        # Quality standards (copy verbatim)
│   ├── stack-context.md.template     # Your tech stack
│   └── project-catalog.md.template   # Your projects
│
├── tests/                            # BATS test suite (86 tests across 5 files)
│
└── docs/
    ├── cast-protocol-spec.md         # 796-line protocol specification
    ├── dashboard-integration.md      # Schema contract for dashboard data structures
    └── agent-quality-rubric.md       # 5-dimension scoring sheet for all agents
```

### Runtime layout (`~/.claude/` after install)

```
~/.claude/
├── CLAUDE.md                         # 60-line directive file — loaded every session
├── settings.local.json               # Hook wiring (4 hooks), permissions, sandbox
├── config.sh                         # Your project paths — sourced by skills
│
├── agents/                           # 31 agent definitions
├── commands/                         # 30 slash command prompts
├── skills/                           # 9 multi-step skill workflows
│
├── scripts/
│   ├── route.sh
│   ├── post-tool-hook.sh
│   ├── pre-tool-guard.sh
│   ├── agent-status-reader.sh
│   ├── cast-events.sh
│   ├── status-writer.sh
│   └── cast-validate.sh
│
├── rules/
│   ├── working-conventions.md
│   ├── stack-context.md
│   └── project-catalog.md
│
├── config/
│   └── routing-table.json
│
├── routing-log.jsonl                 # Append-only dispatch log (every prompt)
├── agent-status/                     # Per-agent status files (append-only)
│
├── cast/
│   ├── events/                       # Immutable event log
│   ├── state/                        # Derived task state
│   ├── reviews/                      # Review decisions
│   └── artifacts/                    # Plans, patches, test files
│
├── agent-memory-local/
│   └── <agent>/MEMORY.md             # Per-agent learned preferences
│
├── plans/                            # Planner output — JSON manifests + specs
├── briefings/                        # Morning briefing output (daily markdown)
├── reports/                          # Chain reporter output
└── meetings/                         # Meeting notes processor output
```

---

## Example: End-to-End Dispatch

You type: `fix the TypeError in the auth middleware`

1. `route.sh` matches `\bTypeError\b` against the `debugger` route (hard confidence)
2. Injects into Claude's context:
   ```
   [CAST-DISPATCH] Route: debugger (confidence: hard)
   MANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).
   [CAST-CHAIN] After debugger completes: dispatch `code-reviewer` -> `commit` in sequence.
   ```
3. Claude dispatches `debugger` (sonnet) with your full prompt
4. Debugger finds and fixes the bug, writes to file
5. `post-tool-hook.sh` fires on the Write — injects `[CAST-REVIEW]` and runs prettier
6. **Debugger self-dispatches `test-writer`** — writes a regression test that would have caught the bug
7. `test-writer` self-dispatches `code-reviewer` (haiku) after the test file is written
8. `code-reviewer` emits Status Block: `DONE` — test is well-structured, behavior-based
9. Debugger self-dispatches `code-reviewer` on the fix itself
10. `code-reviewer` emits `DONE_WITH_CONCERNS` with a note about the token expiry edge case
11. `agent-status-reader.sh` reads the status file, injects `[CAST-REVIEW]` — security agent recommended
12. Claude dispatches `commit` (haiku) per the `[CAST-CHAIN]` directive
13. `pre-tool-guard.sh` allows the commit because the commit agent uses `CAST_COMMIT_AGENT=1 git commit`
14. `Stop` hook verifies nothing was skipped, checks for unpushed commits
15. `cast-events.sh` appends `task_completed` events for each agent action

Total model cost: sonnet (debugger) + sonnet (test-writer) + haiku (code-reviewer x2) + haiku (commit). Not five sonnet calls. The routing engine paid for itself in token savings.

---

## Extending CAST

### Add an agent

Create `~/.claude/agents/my-agent.md`:

```markdown
---
name: my-agent
description: What this agent does and when to dispatch it
tools: Read, Write, Edit, Glob, Grep
model: sonnet
---

You are a specialist in [domain]...

End every response with a Status block:
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Summary: [one sentence]
```

Add a route entry to `routing-table.json` to auto-dispatch it. Or invoke it manually via `/cast my-agent <task>`.

### Add a route

Edit `~/.claude/config/routing-table.json`:

```json
{
  "patterns": ["deploy.*staging", "push.*to.*staging", "^/deploy\\b"],
  "agent": "deploy-runner",
  "model": "sonnet",
  "command": "/deploy",
  "confidence": "hard",
  "post_chain": ["verifier", "commit"]
}
```

Changes take effect immediately. Run `cast-validate.sh` to verify the new route passes schema checks.

### Add a slash command

Create `~/.claude/commands/my-command.md` with the agent prompt and `$ARGUMENTS` placeholder. Reference it as `/my-command <input>`.

### Add a skill

Create `~/.claude/skills/my-skill/SKILL.md` with the multi-step procedure. Reference it from any agent definition.

---

## Roadmap

- **v1.6.0** — `cast-validate.sh` pre-install check integrated into Claude Code session startup
- **v1.7.0** — Cross-session memory compression: agent memory summarization when MEMORY.md exceeds token budget
- **v2.0.0** — Manifest schema v2 with conditional batch execution (skip batch N if batch M returned DONE_WITH_CONCERNS on specific concern types)
- **Long-term** — Multi-project orchestration: orchestrator spans repos, coordinates agents across codebases

---

## Contributing

Contributions welcome. The most valuable additions:

1. **New agents** — follow the frontmatter schema and Status Block protocol; add a route; add BATS tests
2. **New routes** — check for ReDoS risk (pattern <200 chars); add a `route.bats` test for the new pattern
3. **Protocol improvements** — open an issue before changing Status Block format or hook contracts — downstream tooling depends on stability
4. **Skills** — cross-platform skills (macOS + Linux) are preferred over macOS-only additions

Run `bash scripts/gen-stats.sh` before opening a PR so the README reflects actual counts.

---

## License

MIT. See [LICENSE](LICENSE).

---

Built with Claude Code. Designed to run the way a real engineering team works — automatically, at the infrastructure layer, with every session informed by what the last one learned. The right specialist. Every time. Automatically.
