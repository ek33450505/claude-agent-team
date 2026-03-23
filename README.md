# CAST — Claude Agent System & Team

**One command. Any task. The right specialist, automatically.**

CAST embeds a 28-agent development team into Claude Code at the infrastructure layer — no application code, no runtime server. Type `/cast <request>` and Claude's own NLU classifies the intent, selects the appropriate specialist, and dispatches work directly.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

> **[Interactive Architecture Diagram](https://gistpreview.github.io/?318b393bdb8cf26b18ce66334bcafc91)**

---

## The Problem

Claude Code out of the box is a generalist. It will write tests, do code review, plan features, and commit changes — but you have to remember to ask. Every session starts from scratch. There is no enforcement layer.

CAST solves this at the infrastructure layer. One command replaces 28 different decision points. A hard block prevents raw `git commit` from running. Persistent memory means agents already know your stack, preferences, and codebase patterns when they wake up.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1 — Context (CLAUDE.md)                           │
│  ~75 lines. Agent registry, dispatch protocol,           │
│  delegation rules. Loaded into every session.            │
│                                                          │
│  "Inline only for: reading code, short analysis,         │
│   <5 line edits. Everything else: /cast or specialist."  │
└──────────────────┬───────────────────────────────────────┘
                   │ dispatches via
┌──────────────────▼───────────────────────────────────────┐
│  Layer 2 — Dispatch (/cast command)                      │
│  /cast analyzes intent with Claude NLU — no regex.       │
│  Selects specialist, chains follow-up agents, executes.  │
│                                                          │
│  /cast "add login page" → planner → code-reviewer →     │
│    test-writer → commit                                  │
│                                                          │
│  git-commit-intercept.sh: PreToolUse hard block          │
│  Raw git commit → exit 2 → tool call never runs          │
└──────────────────┬───────────────────────────────────────┘
                   │ logged by
┌──────────────────▼───────────────────────────────────────┐
│  Layer 3 — Observability (route.sh → dashboard)          │
│  route.sh matches prompts against routing-table.json     │
│  for logging only — no dispatch, no injection.           │
│  Writes to ~/.claude/routing-log.jsonl                   │
│  Feeds the Claude Code Dashboard in real time.           │
└──────────────────────────────────────────────────────────┘
```

Pure config, shell scripts, and markdown. Zero custom application code.

---

## Usage

### The universal dispatcher

```
/cast add a login page to the dashboard
```

`/cast` reads the request, classifies intent, and dispatches the right specialist immediately — without asking first.

What happens above: `planner` runs to break down the feature, produces a plan file with an `## Agent Dispatch Manifest`, then presents a batch queue for one approval:

```
Agent Dispatch Queue — Login Page
═══════════════════════════════════════════════
  Batch 1 (parallel)  : architect, security
  Batch 2 (sequential): main (implementation)
  Batch 3 (parallel)  : code-reviewer, test-writer
  Batch 4 (sequential): commit
═══════════════════════════════════════════════
Approve to execute all batches? [yes/no]
```

### Direct dispatch (when you know the agent)

```
/debug why is this function failing with a TypeError
/test write coverage for the auth middleware
/commit
```

Every agent has a corresponding slash command. Use `/cast` when you want classification; use the direct command when you already know.

### Opus escalation

```
opus: design the entire authentication system from scratch
```

Prefix with `opus:` to bypass normal dispatch for that message.

---

## Enforcement

Two hard constraints that cannot be bypassed by Claude's context window:

**1. git-commit-intercept.sh** (PreToolUse hook)

Every Bash tool call is intercepted. If the command contains `git commit` without `CAST_COMMIT_AGENT=1` in the command string, it exits with code 2 — the tool call never runs:

```
[CAST PreToolUse] Raw git commit blocked. Use the commit agent instead.
```

The `commit` agent runs `CAST_COMMIT_AGENT=1 git commit ...` inline. The inline env var — not a pre-exported one — prevents the escape hatch from surviving across tool calls.

**2. CLAUDE.md context rules**

Loaded into every session. Defines what Claude does inline vs. what always dispatches to a specialist. Approximately 75 lines — compact enough that Claude actually reads it.

---

## Memory Architecture

Two layers that persist across every session.

```
~/.claude/
├── projects/*/memory/          ← Project memory (per working directory)
│   ├── MEMORY.md               ← Index — loaded into every session
│   ├── user_role.md
│   ├── feedback_testing.md
│   └── project_decisions.md
│
└── agent-memory-local/         ← Agent memory (per specialist)
    ├── planner/MEMORY.md       ← What planner has learned across all sessions
    ├── debugger/MEMORY.md      ← Recurring failure patterns
    ├── code-reviewer/MEMORY.md ← Project-specific review preferences
    └── ...25 more agents
```

**Project memory** — loaded automatically via CLAUDE.md. Claude never asks who you are or what your stack is.

**Agent memory** — per-specialist. The `planner` learns your planning patterns. The `debugger` learns recurring failure modes. Each agent consults its own `MEMORY.md` on invocation and updates it when something is worth preserving. Four memory types: `user` (role, preferences), `feedback` (what worked, corrections), `project` (goals, decisions), `reference` (where external info lives).

---

## Agent Roster

28 agents across 5 categories. All have a defined role, model assignment, tool restrictions, and persistent memory.

| Agent | Category | Tier | Command | Role |
|---|---|---|---|---|
| `planner` | Core | sonnet | `/plan` | Task plans with JSON dispatch manifest |
| `debugger` | Core | sonnet | `/debug` | Errors, stack traces, unexpected behavior |
| `test-writer` | Core | sonnet | `/test` | Jest/Vitest/RTL tests with coverage |
| `security` | Core | sonnet | `/secure` | OWASP review, secrets scanning |
| `data-scientist` | Core | sonnet | `/data` | SQL queries, BigQuery analysis |
| `code-reviewer` | Core | haiku | `/review` | Readability, correctness, diff-focused |
| `db-reader` | Core | haiku | `/query` | Read-only queries — writes blocked |
| `commit` | Core | haiku | `/commit` | Semantic commits, staged content verification |
| `architect` | Extended | sonnet | `/architect` | System design, ADRs, module boundaries |
| `tdd-guide` | Extended | sonnet | `/tdd` | Red-green-refactor TDD workflow |
| `e2e-runner` | Extended | sonnet | `/e2e` | Playwright E2E with stack auto-discovery |
| `readme-writer` | Extended | sonnet | `/readme` | Full README audit against codebase |
| `build-error-resolver` | Extended | haiku | `/build-fix` | Vite/CRA/TS/ESLint errors, minimal diffs |
| `refactor-cleaner` | Extended | haiku | `/refactor` | Dead code, unused imports, cleanup |
| `doc-updater` | Extended | haiku | `/docs` | README, changelog, JSDoc |
| `router` | Extended | haiku | — | LLM classifier for unmatched prompts |
| `researcher` | Productivity | sonnet | `/research` | Tool/library evaluation, comparisons |
| `email-manager` | Productivity | sonnet | `/email` | Email triage and drafting (macOS + Outlook) |
| `morning-briefing` | Productivity | sonnet | `/morning` | Calendar + email + reminders + git activity |
| `report-writer` | Productivity | haiku | `/report` | Status reports, sprint summaries |
| `meeting-notes` | Productivity | haiku | `/meeting` | Action items and decisions from notes |
| `browser` | Professional | sonnet | `/browser` | Browser automation, screenshots, scraping |
| `qa-reviewer` | Professional | sonnet | `/qa` | Second-opinion QA on functional correctness |
| `presenter` | Professional | sonnet | `/present` | Slide decks, status presentations |
| `orchestrator` | Orchestration | sonnet | `/orchestrate` | Agent Dispatch Manifest execution |
| `auto-stager` | Orchestration | haiku | `/stage` | Pre-commit staging; never stages `.env` |
| `verifier` | Orchestration | haiku | `/verify` | Build check + TODO scan before quality gate |
| `chain-reporter` | Orchestration | haiku | `/chain-report` | Chain summaries to `~/.claude/reports/` |

30 slash commands at `~/.claude/commands/` — 28 agent commands plus `/cast` and `/help`.

---

## Skills

9 reusable multi-step procedures that agents invoke as sub-workflows: `calendar-fetch`, `inbox-fetch`, `reminders-fetch` (macOS + Outlook), `git-activity`, `action-items`, `briefing-writer`, `careful-mode`, `freeze-mode`, `wizard` (all platforms).

The installer detects your platform and installs Linux stubs for macOS-only skills. Morning briefings on Linux still work — `git-activity` and `action-items` run on all platforms.

---

## Hooks

| Hook | Trigger | Script | What it does |
|---|---|---|---|
| `UserPromptSubmit` | Every prompt | `route.sh` | Pattern match for logging only — writes to routing-log.jsonl |
| `PreToolUse` | Every Bash call | `git-commit-intercept.sh` | Hard-blocks raw `git commit` (exit 2) |
| `PostToolUse` | After Write/Edit | `auto-format.sh` | Run Prettier if configured |
| `Stop` | Before response | (prompt) | Nudge: if code changed but tests not run, suggest running them |

---

## Installation

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

| Option | What you get |
|---|---|
| **Full** | All 28 agents, 30 commands, 9 skills, 4 scripts, 3 rules, hooks |
| **Core** | 8 essential agents + their commands (minimal, portable) |
| **Custom** | Choose categories: core, extended, productivity, professional, macOS skills |

The installer backs up your existing `~/.claude/` before copying anything.

**After install, personalize 3 files:**

1. `~/.claude/config.sh` — your project directories
2. `~/.claude/rules/stack-context.md` — your tech stack
3. `~/.claude/rules/project-catalog.md` — your projects

Then merge `settings.template.json` into your `~/.claude/settings.local.json` to activate the hooks.

---

## Repo Structure

```
claude-agent-team/
├── install.sh                        # Interactive installer (full / core / custom)
├── CLAUDE.md.template                # Global context — fill in your projects + stack
├── config.sh.template                # Shared project paths for skills and scripts
├── settings.template.json            # Hooks + sandbox config (merge into settings.local.json)
│
├── scripts/
│   ├── route.sh                      # UserPromptSubmit hook — logs routing decisions
│   ├── git-commit-intercept.sh       # PreToolUse hook — hard-blocks raw git commit
│   └── auto-format.sh                # PostToolUse hook — Prettier on Write/Edit
│
├── config/
│   └── routing-table.json            # Route patterns → agent mapping (logging reference)
│
├── agents/
│   ├── core/           (8 agents)
│   ├── extended/       (8 agents)
│   ├── productivity/   (5 agents)
│   ├── professional/   (3 agents)
│   └── orchestration/  (4 agents)
│
├── commands/           (30 commands)  # One .md per slash command
│
├── skills/             (9 skills)     # Each in its own subdirectory with SKILL.md
│
├── rules/
│   ├── working-conventions.md        # Quality standards (copy verbatim)
│   ├── stack-context.md.template     # Your tech stack
│   └── project-catalog.md.template  # Your projects
│
├── tests/                            # BATS test suite
│
└── docs/
    └── agent-quality-rubric.md       # 5-dimension scoring sheet for all agents
```

---

## Customization

### Add an agent

Create `~/.claude/agents/my-agent.md`:

```markdown
---
name: my-agent
description: What this agent does and when to use it
tools: Read, Write, Edit, Glob, Grep
model: sonnet
---

You are a specialist in [domain]...
```

`/cast` will automatically include it in dispatch decisions. No routing table update required.

### Add a slash command

Create `~/.claude/commands/my-command.md` with the agent prompt and `$ARGUMENTS` placeholder. Reference it as `/my-command <input>`.

### Extend the routing table

`config/routing-table.json` controls what gets logged to the dashboard (observability only). Add a route with `patterns`, `agent`, `command`. Dispatch goes through `/cast`, not this table.

---

## Companion: Claude Code Dashboard

CAST generates structured data that the **[Claude Code Dashboard](https://github.com/ek33450505/claude-code-dashboard)** visualizes in real time.

| CAST output | Dashboard view |
|---|---|
| `~/.claude/agents/*.md` | Agent roster, model badges, quality scores |
| `~/.claude/routing-log.jsonl` | Live routing feed, dispatch stats |
| `~/.claude/plans/` | Plan history, manifest viewer |
| `~/.claude/briefings/` | Productivity output feed |
| `~/.claude/reports/` | Chain execution reports |

The dashboard auto-discovers agents from `~/.claude/agents/*.md` on every API call — no sync step needed. It works with any Claude Code installation, not just CAST.

---

## License

MIT. See [LICENSE](LICENSE).

---

Built with Claude Code. Designed to make Claude Code work the way a senior engineering team works.
