# CAST — Claude Agent Specialist Team

![Version](https://img.shields.io/badge/version-1.5.0-blue)
![Agents](https://img.shields.io/badge/agents-36-green)
![Routes](https://img.shields.io/badge/routes-22-blue)
![Tests](https://img.shields.io/badge/tests-106%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

CAST is a local AI ecosystem that grows with you. Agents that remember. Workflows that self-coordinate. Everything on your machine.

<!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> specialist agents embedded into Claude Code at the hook layer. When you type a prompt, routing intercepts it and dispatches the right specialist automatically. Agent memory persists across sessions in plain markdown files you own. Compound workflows run in parallel waves without slash commands. Nothing is synced to the cloud. Nothing requires a new network surface beyond what Claude Code already uses.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

[Interactive Architecture Diagram](docs/architecture.html)

---

## How It Works

- **Agents** — <!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> specialists across 6 tiers. Each agent is a markdown file with a defined role, model tier, and self-dispatch chain. Haiku for mechanical tasks, Sonnet for reasoning-heavy work — enforced at the route level.
- **Routing** — `route.sh` runs on every prompt via the `UserPromptSubmit` hook. It matches against <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> regex patterns in `routing-table.json` and injects a `[CAST-DISPATCH]` directive into Claude's context. No match means Claude handles it inline.
- **Agent Groups** — 30 compound workflows defined in `config/agent-groups.json`. Each group runs agents in parallel waves with a post-chain. Type "ship it" or "pre-release check" — CAST handles the rest.
- **Memory** — Plain markdown files in `~/.claude/agent-memory-local/<agent-name>/`. Agents read and write them across sessions. Open any file in any editor to see exactly what your agent remembers.

---

## Architecture

```
User Prompt
    |
    v
[Hook 1: UserPromptSubmit] -- route.sh -- routing-table.json (22 routes)
    | match                             | no match
    v                                  v
[CAST-DISPATCH] injected          Claude handles inline
    |
    v
Agent executes (haiku / sonnet tier discipline enforced)
    |
    v (Write/Edit tool fires)
[Hook 2: PostToolUse] -- post-tool-hook.sh
    | --> [CAST-REVIEW] injected into main session context
    | --> prettier auto-format (JS/TS/CSS/JSON)
    | --> [CAST-ORCHESTRATE] if plan file contains dispatch manifest
    v
code-reviewer (haiku) emits Status Block JSON
    |
    v
[Hook 2b: PostToolUse] -- agent-status-reader.sh (subagent context)
    | BLOCKED --> [CAST-HALT] exit 2      | DONE --> log silently
    v
[Hook 3: PreToolUse] -- pre-tool-guard.sh
    hard-blocks: git commit (escape: CAST_COMMIT_AGENT=1)
    hard-blocks: git push   (escape: CAST_PUSH_OK=1)
    |
    v
commit agent (haiku) --> CAST_COMMIT_AGENT=1 git commit
    |
    v
[Hook 4: Stop] -- unpushed-commit check
    |
    v
cast-events.sh --> ~/.claude/cast/events/ (append-only, immutable)
```

Pure config, shell scripts, and markdown. Zero custom application code to maintain.

---

## The Agents (<!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT -->)

### Core Tier — 10 agents

The foundation of every CAST install. Every quality gate flows through this tier.

| Agent | Model | Role |
|---|---|---|
| `planner` | sonnet | Task planning with Agent Dispatch Manifest output |
| `debugger` | sonnet | Root cause analysis for errors and stack traces. Self-dispatches: test-writer, code-reviewer, commit |
| `test-writer` | sonnet | Jest/Vitest/RTL/Playwright tests with behavior-based queries and edge case coverage. Self-dispatches: code-reviewer, commit |
| `code-reviewer` | haiku | Diff-focused review: readability, correctness, naming, error handling. Emits machine-readable Status Block |
| `data-scientist` | sonnet | SQL queries, BigQuery analysis, data visualization |
| `db-reader` | haiku | Read-only SQL exploration — write operations blocked at hook level |
| `commit` | haiku | Semantic commits with staged content verification via CAST_COMMIT_AGENT=1 escape hatch |
| `security` | sonnet | OWASP review, secrets scanning, XSS/SQLi analysis |
| `push` | haiku | Managed push workflow with pre-push verification |
| `bash-specialist` | sonnet | CAST hook scripts, exit codes, hookSpecificOutput format — consulted when modifying CAST itself |

### Extended Tier — 8 agents

Specialist agents for common development workflows.

| Agent | Model | Role |
|---|---|---|
| `architect` | sonnet | System design, ADRs, module boundaries, trade-off analysis |
| `tdd-guide` | sonnet | Red-green-refactor TDD workflow enforcement |
| `build-error-resolver` | haiku | Vite/CRA/TypeScript/ESLint errors, minimal diffs only. Self-dispatches: code-reviewer, commit |
| `e2e-runner` | sonnet | Playwright E2E with automatic stack discovery |
| `refactor-cleaner` | haiku | Dead code, unused imports, complexity reduction — batch-by-batch. Self-dispatches: code-reviewer, commit |
| `doc-updater` | haiku | README, changelog, JSDoc — generates diffs before applying. Self-dispatches: commit |
| `readme-writer` | sonnet | Full README audit against actual codebase — accuracy and positioning |
| `router` | haiku | NLU classifier for prompts that don't match regex routes |

### Orchestration Tier — 5 agents

Control-plane agents that coordinate multi-agent workflows and enforce quality gates.

| Agent | Model | Role |
|---|---|---|
| `orchestrator` | sonnet | Reads Agent Dispatch Manifests, runs full queue with batch-aware status handling |
| `auto-stager` | haiku | Pre-commit staging, never stages .env or sensitive files |
| `chain-reporter` | haiku | Writes chain execution summaries to ~/.claude/reports/ |
| `verifier` | haiku | Build check and TODO scan before quality gate passes |
| `test-runner` | sonnet | Runs test suite, parses output, dispatches debugger automatically on failure |

### Productivity Tier — 5 agents

Automate developer productivity workflows — briefings, email triage, reports.

| Agent | Model | Role |
|---|---|---|
| `researcher` | sonnet | Tool/library evaluation, comparisons, pros/cons. Wired to browser for live docs |
| `report-writer` | haiku | Status reports, sprint summaries to ~/.claude/reports/ |
| `meeting-notes` | haiku | Extracts action items and decisions from raw meeting notes |
| `email-manager` | sonnet | Email triage and drafting (macOS + Outlook via AppleScript) |
| `morning-briefing` | sonnet | Calendar, inbox, reminders, git activity assembled into a structured daily briefing |

### Professional Tier — 3 agents

High-output agents for client-facing and cross-functional work.

| Agent | Model | Role |
|---|---|---|
| `browser` | sonnet | Browser automation, screenshots, scraping, live documentation fetching |
| `qa-reviewer` | sonnet | Second-opinion QA on functional correctness — catches what code-reviewer misses |
| `presenter` | sonnet | Slide decks and status presentations from specs or notes |

### Specialist Tier — 4 agents

Purpose-built agents for infrastructure, performance, content, and lint workflows.

| Agent | Model | Role |
|---|---|---|
| `devops` | sonnet | CI/CD pipelines, Dockerfile, GitHub Actions, deploy config |
| `performance` | sonnet | Core Web Vitals, bundle analysis, render performance |
| `seo-content` | sonnet | Meta tags, accessibility, WCAG, localization |
| `linter` | haiku | Lint rule enforcement and auto-fix |

---

## Routing

`route.sh` runs on every user prompt via the `UserPromptSubmit` hook. It matches against `config/routing-table.json` and outputs structured JSON injected directly into Claude's context window alongside the prompt.

On a match, Claude sees:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: debugger (confidence: hard)\nMANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).\nPass the user's full prompt as the agent task. Do NOT handle this inline.\n[CAST-CHAIN] After debugger completes: dispatch `code-reviewer` -> `commit` in sequence."
  }
}
```

`confidence: "hard"` produces `MANDATORY: Dispatch the agent`. `confidence: "soft"` produces `RECOMMENDED: Consider dispatching`. No match means `route.sh` outputs nothing and Claude handles the prompt inline.

---

## Agent Groups

30 compound workflows defined in `config/agent-groups.json`. Each group is a named sequence of parallel waves. You trigger them with natural language — no slash commands needed.

| Phrase | Group | What runs |
|---|---|---|
| "ship it" | `ship-it` | Wave 1: verifier + test-runner + devops in parallel. Post-chain: auto-stager, commit, push |
| "pre-release check" | `pre-release` | Wave 1: security + e2e-runner + qa-reviewer + performance. Wave 2: devops + readme-writer. Post-chain: report-writer, commit, push |
| "good morning" | `morning-start` | Wave 1: morning-briefing + chain-reporter in parallel. Wave 2: report-writer |
| "fix and ship" | `fix-and-ship` | Wave 1: debugger. Wave 2: test-writer + code-reviewer + build-error-resolver in parallel. Post-chain: commit |
| "security audit" | `security-audit` | Wave 1: security + linter. Wave 2: qa-reviewer + code-reviewer. Post-chain: report-writer, email-manager |

Waves run in order. Agents within a wave with `"parallel": true` run simultaneously. The post-chain fires after all waves complete. `[CAST-DISPATCH-GROUP]` is the directive that triggers group execution.

Other groups include: `feature-build`, `ui-build`, `backend-build`, `quality-sweep`, `refactor-sprint`, `performance-audit`, `db-migration`, `devops-setup`, `seo-sprint`, `doc-sprint`, `data-analysis`, `tech-spike`, `adr-session`, `dependency-audit`, `hotfix`, `daily-wrap`, `pr-review`, and more.

---

## Memory — Local, You Own It

Agent memory is plain markdown files in `~/.claude/agent-memory-local/<agent-name>/`. Open them in any editor. Edit them. Back them up. Delete them.

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

Key properties:

- Nothing is synced to the cloud. Memory files never leave your machine.
- Not a vector database. Not an opaque embedding. A markdown file.
- Agents read and write across sessions — they get smarter over time without any extra setup.
- If you want to know what your agent remembers, open a file.
- Zero new network surface area beyond what Claude Code already uses.

---

## The CAST Protocol

Four directives that enforce agent behavior. Defined in `CLAUDE.md`, enforced by hooks.

| Directive | Source | What it does |
|---|---|---|
| `[CAST-DISPATCH]` | route.sh via UserPromptSubmit | Dispatch the named agent via the Agent tool. Do not handle inline. |
| `[CAST-REVIEW]` | post-tool-hook.sh via PostToolUse | Dispatch code-reviewer (haiku) after completing the current logical unit. |
| `[CAST-CHAIN]` | route.sh or agent self-dispatch | After the primary agent completes, dispatch the listed agents in sequence. |
| `[CAST-DISPATCH-GROUP]` | agent-groups.json matching | Execute the named group — run waves in order, post-chain after final wave. |

`CLAUDE.md` treats these as unconditional system-level directives. An agent cannot skip code review. A raw `git commit` cannot bypass `pre-tool-guard.sh`. The hooks enforce what the directives declare.

---

## Slash Commands

<!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT --> commands at `~/.claude/commands/`. Use these as manual overrides when you know exactly which agent you want, or when automatic routing doesn't fire.

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
| `/morning` | morning-briefing | sonnet | Daily briefing: calendar, inbox, git |
| `/browser` | browser | sonnet | Browser automation and scraping |
| `/qa` | qa-reviewer | sonnet | Second-opinion QA review |
| `/present` | presenter | sonnet | Slide decks from specs |
| `/stage` | auto-stager | haiku | Pre-commit staging |
| `/verify` | verifier | haiku | Build check and TODO scan |
| `/orchestrate` | orchestrator | sonnet | Execute Agent Dispatch Manifest |
| `/chain-report` | chain-reporter | haiku | Write chain execution report |
| `/cast` | router | haiku | Universal dispatcher — NLU-based routing for any prompt |
| `/eval` | — | — | Evaluate a prompt against routing patterns |
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
| **[1] Full** | All <!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> agents, <!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT --> commands, <!-- CAST_SKILL_COUNT -->12<!-- /CAST_SKILL_COUNT --> skills, all scripts, rules | Most users |
| **[2] Core** | 9 essential agents + their commands, scripts, rules | Minimal installs, CI |
| **[3] Custom** | Choose categories: core, extended, productivity, professional, specialist | Power users |

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
  Hook wiring: route.sh, pre-tool-guard.sh, post-tool-hook.sh wired
  Agent frontmatter: 35 agents — all valid
  Routing table: 22 routes — schema valid
  CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] present
  CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present
  cast-events.sh: installed at /Users/you/.claude/scripts/cast-events.sh
==============================
0 errors, 0 warnings
```

Fix any errors before use. CAST without hook wiring is an agent directory — not a system.

---

## Event-Sourcing Protocol

Every agent action writes an immutable, timestamped event file. State is derived from events by replaying them in order. No agent ever overwrites another agent's data.

```
~/.claude/cast/
├── events/     # Immutable event files: {timestamp}-{agent}-{task_id}.json
├── state/      # Derived task state: {task_id}.json  (written by orchestrator)
├── reviews/    # Review decisions: {artifact_id}-{reviewer}-{timestamp}.json
└── artifacts/  # Plans, patches, test files
```

Each event file contains:

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

## Skills

<!-- CAST_SKILL_COUNT -->12<!-- /CAST_SKILL_COUNT --> skills in `~/.claude/skills/`. Skills are reusable prompt fragments sourced by agents at runtime — they are not agents themselves.

| Skill | Purpose |
|---|---|
| `calendar-fetch` | Fetch today's calendar events (macOS/Outlook) |
| `inbox-fetch` | Fetch unread emails (macOS/Outlook) |
| `reminders-fetch` | Fetch pending reminders (macOS) |
| `git-activity` | Summarize recent git activity across configured projects |
| `action-items` | Extract action items from text |
| `briefing-writer` | Assemble a structured daily briefing from component outputs |
| `careful-mode` | Slow down — confirm before each write |
| `freeze-mode` | Read-only mode — no writes, analysis only |
| `wizard` | Interactive step-by-step prompting for complex tasks |
| `calendar-fetch-linux` | Linux stub for calendar-fetch |
| `inbox-fetch-linux` | Linux stub for inbox-fetch |

macOS skills (calendar, inbox, reminders) require Microsoft Outlook. Linux installs receive stubs automatically.

---

## Stats

| Metric | Count |
|---|---|
| Agents | <!-- CAST_AGENT_COUNT -->36<!-- /CAST_AGENT_COUNT --> |
| Agent groups | 30 |
| Routes | <!-- CAST_ROUTE_COUNT -->22<!-- /CAST_ROUTE_COUNT --> |
| Commands | <!-- CAST_COMMAND_COUNT -->31<!-- /CAST_COMMAND_COUNT --> |
| Skills | <!-- CAST_SKILL_COUNT -->12<!-- /CAST_SKILL_COUNT --> |
| Tests | <!-- CAST_TEST_COUNT -->106<!-- /CAST_TEST_COUNT --> |
| Directives | 4 |

---

## Companion

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — observability UI for CAST. Reads `routing-log.jsonl`, `agent-status/`, and `cast/` directories written by CAST hooks. Shows routing decisions, agent status, and chain execution history in a React dashboard.

---

MIT License
