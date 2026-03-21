# CAST — Claude Agent System & Team

**An AI-enforced software development process embedded at the Claude Code infrastructure layer.**

CAST turns Claude Code from a conversational assistant into an orchestrated team with automatic routing, chain execution, and hard enforcement — all through config files, shell scripts, and markdown. No application code. No runtime server.

```
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

> **[Interactive Architecture Diagram](https://gistpreview.github.io/?318b393bdb8cf26b18ce66334bcafc91)**

---

## The Problem

Claude Code out of the box is a generalist. It will write tests, do code review, plan features, and commit changes — but you have to remember to ask. You have to know which specialist to invoke, type the right command, and manually chain follow-up steps.

CAST intercepts that loop at the infrastructure layer. Type naturally. The right agent fires. When that agent finishes, the next one in the chain fires automatically.

---

## How It Works: 3 Layers

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1 — Agents                                        │
│  24 specialists. Each has a defined role, model          │
│  assignment, and persistent per-agent memory.            │
│                                                          │
│  planner  debugger  security  commit  test-writer  +19   │
└──────────────────┬───────────────────────────────────────┘
                   │ dispatched by
┌──────────────────▼───────────────────────────────────────┐
│  Layer 2 — Intelligence (this repo)                      │
│  route.sh: UserPromptSubmit hook intercepts every prompt │
│  routing-table.json: 13 routes → agent + post_chain      │
│  git-commit-intercept.sh: PreToolUse hard block          │
│                                                          │
│  "fix this bug" → debugger → code-reviewer → commit      │
└──────────────────┬───────────────────────────────────────┘
                   │ visualized by
┌──────────────────▼───────────────────────────────────────┐
│  Layer 3 — Visibility (claude-code-dashboard)            │
│  Real-time routing events, miss-rate tracking,           │
│  dispatch stats, session replay, cost analytics          │
└──────────────────────────────────────────────────────────┘
```

---

## Layer 2: The Routing System

This is the differentiator. Everything else — agents, commands, memory — exists in other frameworks. The routing system does not.

### What fires on every prompt

A `UserPromptSubmit` hook calls `route.sh` before Claude sees your message. The script:

1. Reads the routing table from `~/.claude/config/routing-table.json`
2. Matches your prompt against regex patterns using Python's `re` module (no external dependencies)
3. If matched: injects a direct dispatch instruction into Claude's context
4. Logs every decision — matched route, pattern, timestamp, prompt preview — to `~/.claude/routing-log.jsonl`

The instruction Claude receives is not a suggestion. It reads:

```
**[Router]** Dispatch to `debugger` agent now using the Agent tool
(subagent_type: 'debugger'). Do NOT ask the user first — invoke the
agent immediately with the user's prompt as the task.

**[Router - Chain]** After the agent completes, continue the chain:
`code-reviewer` agent → `commit` agent. Invoke each agent in sequence
when the previous one finishes.
```

### What a routing decision looks like

You type: `"why is this function failing with a TypeError"`

```jsonl
{
  "timestamp": "2026-03-21T19:42:11Z",
  "prompt_preview": "why is this function failing with a TypeError",
  "action": "dispatched",
  "matched_route": "debugger",
  "command": "/debug",
  "pattern": "why.*failing"
}
```

Claude dispatches `debugger` (Sonnet). When it finishes, `code-reviewer` (Haiku) runs automatically. When that finishes, `commit` (Haiku) runs. You typed one sentence. Three agents executed in sequence.

### The 13 routes

All patterns live in `config/routing-table.json`. Edit them freely.

| Patterns (examples) | Agent | Post-chain |
|---|---|---|
| `fix.*bug`, `debug`, `why.*failing`, `stack trace` | `debugger` | `code-reviewer` → `commit` |
| `write.*test`, `test coverage`, `vitest`, `jest` | `test-writer` | `commit` |
| `review.*code`, `code review`, `check.*changes` | `code-reviewer` | `commit` |
| `plan.*implement`, `how.*should.*build`, `architect` | `planner` | auto-dispatch-from-manifest |
| `refactor`, `dead code`, `clean up`, `unused import` | `refactor-cleaner` | `code-reviewer` → `commit` |
| `write.*docs`, `update.*readme`, `add.*jsdoc` | `doc-updater` | `commit` |
| `security.*review`, `owasp`, `sql injection`, `xss` | `security` | — |
| `e2e test`, `playwright`, `end.to.end` | `e2e-runner` | — |
| `build.*error`, `typescript error`, `eslint.*error` | `build-error-resolver` | `commit` |
| `research`, `compare.*librar`, `evaluate.*tool` | `researcher` | — |
| `morning briefing`, `daily briefing`, `my schedule` | `morning-briefing` | — |
| `slide deck`, `create.*presentation` | `presenter` | — |
| `^commit$`, `git commit`, `stage and commit` | `commit` | — |

Unmatched prompts log `"action": "no_match"`. When miss-rate exceeds 20%, the `router` agent (Phase 2 — Haiku LLM classifier) activates to handle the gap.

### Opus escalation

Prefix any message with `opus:` to bypass routing for that message:

```
opus: design the entire authentication system from scratch
```

Complexity signals (`"design the entire"`, `"analyze the whole codebase"`, `"system design"`) also trigger Opus escalation automatically.

---

## Post-Plan Auto-Dispatch

When the `planner` agent matches (e.g., `"plan this feature"`), the post-chain is `auto-dispatch-from-manifest`. This triggers a different behavior.

The planner writes a structured plan file to `~/.claude/plans/`. At the bottom of that plan file is an **Agent Dispatch Manifest**:

```markdown
## Agent Dispatch Manifest

### Batch 1 (parallel — independent tasks)
- test-writer: src/api/auth.js
- doc-updater: README.md

### Batch 2 (after Batch 1)
- code-reviewer: all modified files
- commit: staged changes
```

After the planner completes, `route.sh` instructs Claude to:

1. Read the plan file
2. Find the `## Agent Dispatch Manifest` section
3. Present the queue to you: "Here are the agents queued. Approve to execute."
4. On approval — execute all batches, parallelizing within each batch

One approval. Multiple agents execute automatically.

---

## Hard Enforcement: git-commit-intercept.sh

`route.sh` routes soft — it injects instructions, which Claude follows. `git-commit-intercept.sh` enforces hard.

This `PreToolUse` hook intercepts every `Bash` tool call before execution. If the command contains `git commit` and does not carry the `CAST_COMMIT_AGENT=1` escape hatch, the hook blocks it with exit code 2:

```
**[CAST PreToolUse]** Raw git commit blocked. Use the commit agent
instead (Agent tool, subagent_type: 'commit'). Stage files with
git add first, then delegate to the commit agent.
```

The commit agent uses `CAST_COMMIT_AGENT=1 git commit ...` internally. Claude cannot bypass this. The only path to a committed change is through the commit agent, which enforces semantic messages and checks staged content.

---

## Three Enforcement Tiers

```
CLAUDE.md rules        →  Advisory ("Use planner before any non-trivial change")
route.sh               →  Behavioral (injects dispatch instructions Claude follows)
git-commit-intercept   →  Hard block (exit 2 — the tool call never executes)
```

Each tier handles a different failure mode:
- CLAUDE.md catches cases where Claude might otherwise skip process
- route.sh catches cases where you didn't type the right command
- The PreToolUse hook catches cases where Claude tries to shortcut past the commit agent

---

## Quick Start

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

The installer offers three options:

| Option | What you get |
|---|---|
| **Full install** | 24 agents, 25 commands, 9 skills, 3 scripts, 3 rules, hooks |
| **Core only** | 8 essential agents + their commands (minimal, portable) |
| **Custom** | Choose categories: core, extended, productivity, professional, macOS skills |

The installer backs up your existing `~/.claude/` before copying anything.

After install, personalize 3 files:

1. `~/.claude/config.sh` — your project directories
2. `~/.claude/rules/stack-context.md` — your tech stack
3. `~/.claude/rules/project-catalog.md` — your projects

Then merge `settings.template.json` into your `~/.claude/settings.local.json` to activate the hooks.

---

## Agent Roster

### Core (8) — always installed

| Agent | Model | Command | Role |
|---|---|---|---|
| `planner` | Sonnet | `/plan` | Converts requests into ordered task plans with dispatch manifest |
| `debugger` | Sonnet | `/debug` | Investigates errors, stack traces, unexpected behavior |
| `test-writer` | Sonnet | `/test` | Writes Jest/Vitest/RTL tests with coverage |
| `code-reviewer` | Haiku | `/review` | Code review focused on readability and correctness |
| `security` | Sonnet | `/secure` | OWASP review, secrets scanning, vulnerability analysis |
| `data-scientist` | Sonnet | `/data` | SQL queries, BigQuery analysis, data exploration |
| `db-reader` | Haiku | `/query` | Read-only DB queries — writes blocked at tool level |
| `commit` | Haiku | `/commit` | Semantic commit messages, staged content verification |

### Extended (8)

| Agent | Model | Command | Role |
|---|---|---|---|
| `architect` | Sonnet | `/architect` | System design, ADRs, module boundaries |
| `tdd-guide` | Sonnet | `/tdd` | Red-green-refactor TDD workflow |
| `build-error-resolver` | Haiku | `/build-fix` | Vite/CRA/TS/ESLint build errors, minimal diffs |
| `e2e-runner` | Sonnet | `/e2e` | Playwright E2E tests with stack auto-discovery |
| `refactor-cleaner` | Haiku | `/refactor` | Dead code, unused imports, dependency cleanup |
| `doc-updater` | Haiku | `/docs` | README, changelog, JSDoc — diff preview workflow |
| `readme-writer` | Sonnet | `/readme` | Full README audit against codebase, rewrite |
| `router` | Haiku | — | Phase 2 LLM classifier for unmatched prompts |

### Productivity (5)

| Agent | Model | Command | Role |
|---|---|---|---|
| `researcher` | Sonnet | `/research` | Tool/library evaluation, technical comparisons |
| `report-writer` | Haiku | `/report` | Status reports, sprint summaries |
| `meeting-notes` | Haiku | `/meeting` | Extract action items and decisions from notes |
| `email-manager` | Sonnet | `/email` | Email triage and drafting (macOS + Outlook) |
| `morning-briefing` | Sonnet | `/morning` | Calendar + email + reminders + git activity briefing |

### Professional (3)

| Agent | Model | Command | Role |
|---|---|---|---|
| `browser` | Sonnet | `/browser` | Browser automation, screenshots, web scraping |
| `qa-reviewer` | Sonnet | `/qa` | Second-opinion QA focused on functional correctness |
| `presenter` | Sonnet | `/present` | Slide decks, status presentations |

### Standalone commands

`/help` — lists all installed agents with model, trigger conditions, and routing examples.
`/eval` — evaluator-optimizer loop: dispatch reviewer, fix critical issues, re-evaluate (max 2x).

---

## Skills

Skills are reusable multi-step procedures that agents invoke as sub-workflows.

| Skill | Platform | Purpose |
|---|---|---|
| `calendar-fetch` | macOS + Outlook | Fetch today's calendar |
| `inbox-fetch` | macOS + Outlook | Fetch unread emails |
| `reminders-fetch` | macOS | Fetch due Apple Reminders |
| `git-activity` | All | Scan project repos for recent commits |
| `action-items` | All | Find unchecked items from meeting notes |
| `briefing-writer` | All | Assemble morning briefing from all data sources |
| `careful-mode` | All | Require confirmation before every Write, Edit, Bash |
| `freeze-mode` | All | Read-only session — no file modifications |
| `wizard` | All | Human-approval gates before destructive operations |

---

## Hooks

| Hook | Trigger | Script | What it does |
|---|---|---|---|
| `UserPromptSubmit` | Before every message | `route.sh` | Pattern match → agent dispatch + chain injection + routing log |
| `PreToolUse` | Before any Bash call | `git-commit-intercept.sh` | Block raw `git commit`, redirect to commit agent |
| `PostToolUse` | After Write or Edit | `auto-format.sh` | Run Prettier if configured |
| `Stop` | Before response completes | (prompt) | Nudge: if code changed but tests not run, suggest running them |

---

## Memory

| Layer | Location | Purpose |
|---|---|---|
| Project memory | `~/.claude/projects/*/memory/` | Per-project context across sessions |
| Agent memory | `~/.claude/agent-memory-local/` | Each agent stores learned patterns independently |

Output directories under `~/.claude/`: `briefings/`, `meetings/`, `reports/`, `plans/`.

---

## Data Flow Examples

### Debug session

```
You: "why is this failing with a TypeError"
      ↓
route.sh matches "why.*failing" → debugger
      ↓
[Router] Dispatch to debugger now. After completion:
  chain: code-reviewer → commit
      ↓
debugger (Sonnet) investigates, proposes fix
      ↓
code-reviewer (Haiku) reviews the fix
      ↓
commit (Haiku) writes semantic commit message, commits
```

### Planning + auto-dispatch

```
You: "plan implementing OAuth2 login"
      ↓
route.sh matches "plan.*implement" → planner, post_chain: auto-dispatch-from-manifest
      ↓
planner (Sonnet) reads codebase, writes plan to ~/.claude/plans/2026-03-21-oauth2-login.md
      ↓
[Router - Chain] Reads plan, finds ## Agent Dispatch Manifest section
      ↓
"Agent queue:
  Batch 1 (parallel): test-writer, doc-updater
  Batch 2: code-reviewer → commit
  Approve to execute? [y/n]"
      ↓
You: y
      ↓
Batch 1: test-writer + doc-updater run in parallel
Batch 2: code-reviewer runs, then commit runs
```

### Morning briefing

```
You: "what's on today"
      ↓
route.sh matches "what.*on.*today" → morning-briefing
      ↓
morning-briefing invokes 5 skills in parallel:
  calendar-fetch, inbox-fetch, reminders-fetch, git-activity, action-items
      ↓
briefing-writer assembles output
      ↓
Saved to ~/.claude/briefings/2026-03-21.md
```

---

## What's in This Repo

```
claude-agent-team/
├── install.sh                        # Interactive installer (full / core / custom)
├── CLAUDE.md.template                # Global context — fill in your projects + stack
├── config.sh.template                # Shared project paths for skills and scripts
├── settings.template.json            # Hooks + sandbox config (merge into settings.local.json)
├── settings.template.jsonc           # Same with inline comments
│
├── scripts/
│   ├── route.sh                      # UserPromptSubmit hook — regex routing + chain injection
│   ├── git-commit-intercept.sh       # PreToolUse hook — hard-blocks raw git commit
│   └── auto-format.sh                # PostToolUse hook — Prettier on Write/Edit
│
├── config/
│   └── routing-table.json            # 13 routes: patterns → agent + post_chain arrays
│
├── agents/
│   ├── core/          (8 agents)
│   ├── extended/      (8 agents)
│   ├── productivity/  (5 agents)
│   └── professional/  (3 agents)
│
├── commands/          (25 commands)  # One .md per slash command
│
├── skills/            (9 skills)     # Each in its own subdirectory with SKILL.md
│   ├── calendar-fetch/               # macOS + Outlook
│   ├── inbox-fetch/                  # macOS + Outlook
│   ├── reminders-fetch/              # macOS
│   ├── git-activity/
│   ├── action-items/
│   ├── briefing-writer/
│   ├── careful-mode/
│   ├── freeze-mode/
│   └── wizard/
│
├── rules/
│   ├── working-conventions.md        # Quality standards (copy verbatim)
│   ├── stack-context.md.template     # Your tech stack
│   └── project-catalog.md.template  # Your projects
│
└── docs/
    └── agent-quality-rubric.md       # 5-dimension scoring sheet for all 22 scored agents
```

---

## Agent Quality Rubric

Every agent is scored across 5 dimensions (1-5 each, 25 max):

| Dimension | Score 5 means |
|---|---|
| Role Clarity | Explicit "I do NOT do X" boundary statements |
| Workflow Specificity | Numbered steps with concrete commands and file paths |
| Output Format | Exact output template with example — copy-paste ready |
| Error Handling | Named failure modes with explicit fallback for each |
| Tool Discipline | Minimal tool set; `disallowedTools` blocks writes for read-only agents |

Top-scoring agents: `planner` (24/25), `debugger` (24/25), `security` (23/25), `doc-updater` (23/25), `e2e-runner` (23/25). Full rubric: `docs/agent-quality-rubric.md`.

---

## Platform Notes

Most of CAST is cross-platform. macOS-only features:

| Feature | Requirement | Linux/WSL |
|---|---|---|
| `calendar-fetch` | macOS + Outlook | Skipped — stub returns "unavailable" |
| `inbox-fetch` | macOS + Outlook | Skipped — stub returns "unavailable" |
| `reminders-fetch` | macOS | Section omitted from briefing |
| `email-manager` | macOS + Outlook | Installed but AppleScript calls will fail |

The installer detects your platform and skips macOS-only skills automatically. Morning briefings on Linux still work — `git-activity` and `action-items` run on all platforms.

---

## Customization

### Add your projects

Edit `~/.claude/config.sh`:
```bash
PROJECTS=(
  "$HOME/Projects/your-app"
  "$HOME/Projects/your-api"
)
```

### Define your tech stack

Edit `~/.claude/rules/stack-context.md`. Agents read this file to give stack-specific advice. Describe your languages, frameworks, test tools, and build systems.

### Add your own agents

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

Add a routing pattern in `~/.claude/config/routing-table.json`:
```json
{
  "patterns": ["your trigger phrase"],
  "agent": "my-agent",
  "command": "/my-command",
  "post_chain": ["commit"]
}
```

### Extend the routing table

Every route supports `post_chain` — an array of agent names to execute in sequence after the primary agent finishes. Set it to `null` for agents that terminate the chain.

The special value `["auto-dispatch-from-manifest"]` tells `route.sh` to read the plan file after the planner finishes and present a batch execution queue for approval.

---

## Companion: Claude Code Dashboard

CAST generates structured data that the **[Claude Code Dashboard](https://github.com/ek33450505/claude-code-dashboard)** visualizes in real time.

```
CAST                          Claude Code Dashboard
────────────────              ────────────────────────────────
~/.claude/agents/         →   Agent roster, model badges, quality scores
~/.claude/routing-log.jsonl → Live routing feed, miss-rate chart, dispatch stats
~/.claude/plans/          →   Plan history, dispatch manifest viewer
~/.claude/briefings/      →   Productivity output feed
```

The dashboard is a separate React 19 + Vite app — no backend, no database. It reads your `~/.claude/` directory directly via a local scan script and reloads on filesystem changes. It works with any Claude Code installation, not just CAST.

---

## License

MIT. See [LICENSE](LICENSE).

---

Built with Claude Code. Designed to make Claude Code work the way a senior engineering team works.
