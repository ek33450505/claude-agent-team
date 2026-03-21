# CAST — Claude Agent System & Team

**An AI-enforced software development process embedded at the Claude Code infrastructure layer.**

CAST turns Claude Code from a conversational assistant into an orchestrated team with automatic routing, chain execution, persistent memory, and hard enforcement — all through config files, shell scripts, and markdown. No application code. No runtime server.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

> **[Interactive Architecture Diagram](https://gistpreview.github.io/?318b393bdb8cf26b18ce66334bcafc91)**

---

## The Problem

Claude Code out of the box is a generalist. It will write tests, do code review, plan features, and commit changes — but you have to remember to ask. You have to know which specialist to invoke, type the right command, and manually chain follow-up steps. And every new session, you start from scratch.

CAST intercepts that loop at the infrastructure layer. Type naturally — the right agent fires. When that agent finishes, the next one in the chain fires automatically. And agents remember what they've learned across every session.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1 — Agents + Memory                               │
│  28 specialists. Each has a defined role, model          │
│  assignment, and persistent per-agent memory.            │
│                                                          │
│  planner  debugger  security  commit  orchestrator  +23  │
│                                                          │
│  Agent memory: ~/.claude/agent-memory-local/<name>/      │
│  Project memory: ~/.claude/projects/*/memory/            │
└──────────────────┬───────────────────────────────────────┘
                   │ dispatched by
┌──────────────────▼───────────────────────────────────────┐
│  Layer 2 — Enforcement (this repo)                       │
│  route.sh: UserPromptSubmit hook — regex routing +       │
│    chain injection. Fires on every prompt.               │
│  PostToolUse hooks: soft warnings after code changes     │
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

## Memory Architecture

CAST maintains two independent memory layers that persist across every session. You never re-explain your stack, projects, or preferences.

### Two-Layer Memory System

```
~/.claude/
├── projects/*/memory/          ← Project memory (per working directory)
│   ├── MEMORY.md               ← Index — loaded into every session automatically
│   ├── user_role.md
│   ├── feedback_testing.md
│   └── project_oauth_rewrite.md
│
└── agent-memory-local/         ← Agent memory (per specialist)
    ├── planner/MEMORY.md       ← What planner has learned across all sessions
    ├── debugger/MEMORY.md      ← Recurring failure patterns this debugger has seen
    ├── code-reviewer/MEMORY.md ← Project-specific review preferences
    └── ...23 more agents
```

**Project memory** is loaded into every session automatically via CLAUDE.md. `MEMORY.md` is an index of memory files — it's always in context, so Claude never asks you who you are or what your stack is.

**Agent memory** is per-specialist. The `planner` agent learns your planning patterns. The `debugger` learns recurring failure modes in your codebase. The `commit` agent learns your commit message style. Each agent consults its own `MEMORY.md` when invoked and updates it when it discovers something worth preserving.

### Memory Types

Each memory file uses a structured format with one of four types:

| Type | Stores | Example |
|---|---|---|
| `user` | Role, preferences, expertise level | "Senior Go developer, new to this React frontend" |
| `feedback` | What worked, what to avoid, corrections | "Never mock the DB — mocked tests passed but prod migration failed" |
| `project` | Goals, decisions, deadlines | "Auth middleware rewrite driven by compliance, not tech debt" |
| `reference` | Where to find external info | "Pipeline bugs tracked in Linear project INGEST" |

Memory accumulates over sessions. The longer you use CAST, the more context agents carry — without any manual maintenance.

---

## Three-Layer Enforcement

CAST enforces good process at three escalating levels of authority.

```
Layer 1 — CLAUDE.md mandatory rules
  "Use planner before any non-trivial change"
  "Invoke code-reviewer after every logical unit"
  Binding instructions loaded into every session.
  Failure mode: Claude ignores the rule when not reminded.

Layer 2 — Hook-injected behavioral enforcement
  route.sh (UserPromptSubmit): injects dispatch instructions Claude follows
  PostToolUse hooks: fire after Write/Edit → inject code-reviewer requirement
  Failure mode: Claude follows soft routing but could theoretically skip it.

Layer 3 — PreToolUse hard block
  git-commit-intercept.sh: exit code 2 — the Bash tool call never executes
  Failure mode: none — hardware-level interception, not a suggestion.
```

Each layer catches a different failure mode:
- CLAUDE.md catches Claude skipping process when no one's watching
- route.sh catches the case where you typed naturally instead of a slash command
- The PreToolUse hook catches Claude trying to shortcut past the commit agent

### Layer 1: CLAUDE.md Mandatory Delegation Rules

CLAUDE.md loads into every session. These are binding constraints, not guidelines:

| Trigger | Rule |
|---|---|
| Any error, test failure, unexpected behavior | Dispatch `debugger` immediately — no inline diagnosis |
| After every logical unit of code changes | Dispatch `code-reviewer` — not optional |
| 10+ file changes | Dispatch `code-reviewer` + `security` + `qa-reviewer` in parallel |
| Any new feature or non-trivial change | Start with `planner` — planner writes plan + dispatch manifest |
| Committing changes | Use `commit` agent — never `git commit` directly |

### Layer 2: Hook-Injected Routing

`route.sh` fires on every prompt before Claude reads it. When a pattern matches, the instruction Claude receives reads:

```
**[Router]** Dispatch to `debugger` agent now using the Agent tool
(subagent_type: 'debugger'). Do NOT ask the user first — invoke the
agent immediately with the user's prompt as the task.

**[Router - Chain]** After the agent completes, continue the chain:
`code-reviewer` agent → `commit` agent. Invoke each agent in sequence
when the previous one finishes.
```

When no pattern matches, Claude receives the senior developer standing permission — never silence:

```
**[CAST]** No pattern matched. You are the senior developer — assess this
prompt and dispatch any specialized agent (planner, debugger, code-reviewer,
researcher, orchestrator, verifier, security, etc.) if it would improve the
outcome. Do not handle complex tasks alone when a specialist exists.
```

### Layer 3: PreToolUse Hard Block

`git-commit-intercept.sh` intercepts every Bash tool call. If the command contains `git commit` without the `CAST_COMMIT_AGENT=1` escape hatch, it blocks with exit code 2 — the tool call never runs:

```
**[CAST PreToolUse]** Raw git commit blocked. Use the commit agent
instead (Agent tool, subagent_type: 'commit'). Stage files with
git add first, then delegate to the commit agent.
```

**The escape hatch:** The `commit` agent runs `CAST_COMMIT_AGENT=1 git commit ...` inline in the command string. The hook checks for this literal string before blocking. This is an inline env var in the command itself — not a separate `export` — because a pre-exported env var would survive across tool calls and defeat the enforcement.

---

## Routing System

### The 13 Routes

All patterns live in `config/routing-table.json`. Every route specifies a `post_chain` array — agents that execute automatically after the primary agent completes.

| Patterns (examples) | Agent | Post-chain |
|---|---|---|
| `fix.*bug`, `debug`, `why.*failing`, `not working` | `debugger` | `code-reviewer` → `commit` |
| `write.*test`, `test coverage`, `vitest`, `jest` | `test-writer` | `commit` |
| `review.*code`, `code review`, `check.*changes` | `code-reviewer` | `commit` |
| `plan.*implement`, `design.*feature`, `architect` | `planner` | auto-dispatch-from-manifest |
| `refactor`, `dead code`, `clean up`, `unused import` | `refactor-cleaner` | `code-reviewer` → `commit` |
| `write.*docs`, `update.*readme`, `update.*changelog` | `doc-updater` | `commit` |
| `security.*review`, `owasp`, `sql injection`, `xss` | `security` | — |
| `e2e test`, `playwright`, `end.to.end` | `e2e-runner` | — |
| `build.*error`, `typescript error`, `eslint.*error` | `build-error-resolver` | `commit` |
| `research`, `compare.*librar`, `evaluate.*tool` | `researcher` | — |
| `morning briefing`, `daily briefing`, `what.*on.*today` | `morning-briefing` | — |
| `slide deck`, `create.*presentation` | `presenter` | — |
| `^commit$`, `git commit`, `stage and commit` | `commit` | — |

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

### Opus Escalation

Prefix any message with `opus:` to bypass routing for that message:

```
opus: design the entire authentication system from scratch
```

Complexity signals (`"design the entire"`, `"analyze the whole codebase"`, `"system design"`) also trigger escalation automatically. Every escalation decision is logged.

### Miss Rate and Phase 2

Unmatched prompts log `"action": "no_match"`. When miss-rate exceeds 20%, the `router` agent (Phase 2) activates — a Haiku LLM classifier that handles prompts the regex table misses.

---

## Post-Plan Auto-Dispatch

The Phase 3 flagship feature. One approval — multiple agents execute automatically.

When `planner` matches, the post-chain is `auto-dispatch-from-manifest`. After the planner agent completes:

1. The plan file is saved to `~/.claude/plans/YYYY-MM-DD-<feature-name>.md`
2. The `## Agent Dispatch Manifest` section at the end of the plan is parsed
3. Claude presents the full dispatch queue to you
4. On approval, batches execute in order — parallel agents simultaneously, sequential agents one at a time

### Dispatch Queue Display

```
Agent Dispatch Queue — OAuth2 Login Implementation
═══════════════════════════════════════════════════
  Batch 1 (parallel)  : architect, security
  Batch 2 (sequential): main (implementation)
  Batch 3 (parallel)  : code-reviewer, test-writer
  Batch 4 (sequential): commit
═══════════════════════════════════════════════════
Total: 6 agents across 4 batches
Approve to execute all batches automatically? [yes/no]
```

### Agent Dispatch Manifest Format

The planner writes this JSON block at the end of every plan file:

````markdown
## Agent Dispatch Manifest

```json dispatch
{
  "batches": [
    {
      "id": 1,
      "description": "Research / architecture review",
      "parallel": true,
      "agents": [
        {"subagent_type": "architect", "prompt": "Review the proposed architecture for OAuth2 login..."},
        {"subagent_type": "security", "prompt": "Review the OAuth2 implementation plan for security issues..."}
      ]
    },
    {
      "id": 2,
      "description": "Implementation",
      "parallel": false,
      "agents": [
        {"subagent_type": "main", "prompt": "Implement OAuth2 login per the plan at ~/.claude/plans/2026-03-21-oauth2-login.md"}
      ]
    },
    {
      "id": 3,
      "description": "Quality gates",
      "parallel": true,
      "agents": [
        {"subagent_type": "code-reviewer", "prompt": "Review the OAuth2 login implementation changes"},
        {"subagent_type": "test-writer", "prompt": "Write tests for the OAuth2 login handler edge cases"}
      ]
    },
    {
      "id": 4,
      "description": "Commit",
      "parallel": false,
      "agents": [
        {"subagent_type": "commit", "prompt": "Create a semantic commit for the completed OAuth2 login work."}
      ]
    }
  ]
}
```
````

**Manifest rules:**
- `"parallel": true` — agents in this batch don't depend on each other's output; they run simultaneously
- `"parallel": false` — wait for this batch to complete before the next one starts
- `"subagent_type": "main"` — Claude itself implements; no Agent tool call spawned
- Maximum 4 agents per parallel batch
- Minimum manifest: implement → code-reviewer → commit
- Include `security` agent whenever auth, API, or input handling is touched

### Phase 3 Orchestration Agents

The orchestration group handles post-plan execution and chain management:

| Agent | Model | Command | Role |
|---|---|---|---|
| `orchestrator` | Sonnet | `/orchestrate` | Reads dispatch manifests, presents queue, executes batches |
| `auto-stager` | Haiku | `/stage` | Stages the right files before commit — never `.env` or secrets |
| `verifier` | Haiku | `/verify` | Checks build, TODOs, missing files before quality-gate batch |
| `chain-reporter` | Haiku | `/chain-report` | Summarizes completed multi-agent chains, saves to `~/.claude/reports/` |

**verifier** sits between implementation and code review. It runs `npm run build`, checks for incomplete TODOs, verifies referenced files exist, and returns a pass/fail verdict. Code-reviewer only runs on work that passes verification.

**auto-stager** replaces `git add .` with intelligent staging — stages source files by extension, never stages `.env`, `node_modules/`, `dist/`, or credential files. Hands off to commit agent automatically.

---

## Agent Roster

28 agents across 5 categories. Each agent has: defined role, model assignment, disallowed tools, and persistent memory.

### Core (8) — always installed

| Agent | Model | Command | Role |
|---|---|---|---|
| `planner` | Sonnet | `/plan` | Converts requests into ordered task plans with JSON dispatch manifest |
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
| `readme-writer` | Sonnet | `/readme` | Full README audit against codebase, then rewrite |
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

### Orchestration — Phase 3 (4)

| Agent | Model | Command | Role |
|---|---|---|---|
| `orchestrator` | Sonnet | `/orchestrate` | Execute Agent Dispatch Manifest; parallel batch execution |
| `auto-stager` | Haiku | `/stage` | Intelligent pre-commit staging; never stages `.env` or secrets |
| `verifier` | Haiku | `/verify` | Implementation completeness check before quality-gate batch |
| `chain-reporter` | Haiku | `/chain-report` | Summarize completed chains; save to `~/.claude/reports/` |

### Slash Commands

29 commands at `~/.claude/commands/`. Every agent has a corresponding slash command.

| Command | Agent | Command | Agent |
|---|---|---|---|
| `/plan` | planner | `/research` | researcher |
| `/review` | code-reviewer | `/report` | report-writer |
| `/debug` | debugger | `/meeting` | meeting-notes |
| `/test` | test-writer | `/email` | email-manager |
| `/secure` | security | `/morning` | morning-briefing |
| `/commit` | commit | `/browser` | browser |
| `/data` | data-scientist | `/qa` | qa-reviewer |
| `/query` | db-reader | `/present` | presenter |
| `/architect` | architect | `/build-fix` | build-error-resolver |
| `/tdd` | tdd-guide | `/refactor` | refactor-cleaner |
| `/e2e` | e2e-runner | `/docs` | doc-updater |
| `/readme` | readme-writer | `/eval` | evaluator-optimizer |
| `/orchestrate` | orchestrator | `/stage` | auto-stager |
| `/verify` | verifier | `/chain-report` | chain-reporter |
| `/help` | — | | |

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
route.sh matches "plan.*implement" → planner
  post_chain: auto-dispatch-from-manifest
      ↓
planner (Sonnet) reads codebase, writes plan to
  ~/.claude/plans/2026-03-21-oauth2-login.md
  with Agent Dispatch Manifest JSON at the end
      ↓
Agent Dispatch Queue presented to user
  Batch 1 (parallel): architect, security
  Batch 2 (sequential): main (implementation)
  Batch 3 (parallel): code-reviewer, test-writer
  Batch 4 (sequential): commit
  Approve? [yes/no]
      ↓
You: yes
      ↓
Batch 1: architect + security run simultaneously
Batch 2: Claude implements per plan
Batch 3: code-reviewer + test-writer run simultaneously
Batch 4: commit agent writes semantic commit
```

### Morning briefing

```
You: "what's on today"
      ↓
route.sh matches "what.*on.*today" → morning-briefing
      ↓
morning-briefing invokes 5 skills in parallel:
  calendar-fetch, inbox-fetch, reminders-fetch,
  git-activity, action-items
      ↓
briefing-writer assembles output
      ↓
Saved to ~/.claude/briefings/2026-03-21.md
```

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
| **Full install** | 24 agents, 24 commands, 9 skills, 3 scripts, 3 rules, hooks |
| **Core only** | 8 essential agents + their commands (minimal, portable) |
| **Custom** | Choose categories: core, extended, productivity, professional, macOS skills |

The installer backs up your existing `~/.claude/` before copying anything.

After install, personalize 3 files:

1. `~/.claude/config.sh` — your project directories
2. `~/.claude/rules/stack-context.md` — your tech stack
3. `~/.claude/rules/project-catalog.md` — your projects

Then merge `settings.template.json` into your `~/.claude/settings.local.json` to activate the hooks.

> The orchestration agents (orchestrator, auto-stager, verifier, chain-reporter) are in the repo under `agents/orchestration/` and can be installed manually. They will be added to the installer menu in a future release.

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
| `PreToolUse` | Before any Bash call | `git-commit-intercept.sh` | Block raw `git commit` (exit code 2), redirect to commit agent |
| `PostToolUse` | After Write or Edit | `auto-format.sh` | Run Prettier if configured |
| `Stop` | Before response completes | (prompt) | Nudge: if code changed but tests not run, suggest running them |

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
│   ├── git-commit-intercept.sh       # PreToolUse hook — hard-blocks raw git commit (exit 2)
│   └── auto-format.sh                # PostToolUse hook — Prettier on Write/Edit
│
├── config/
│   └── routing-table.json            # 13 routes: patterns → agent + post_chain arrays
│
├── agents/
│   ├── core/          (8 agents)
│   ├── extended/      (8 agents)
│   ├── productivity/  (5 agents)
│   ├── professional/  (3 agents)
│   └── orchestration/ (4 agents)    # Phase 3 — orchestrator, auto-stager, verifier, chain-reporter
│
├── commands/          (29 commands)  # One .md per slash command
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
    └── agent-quality-rubric.md       # 5-dimension scoring sheet for all agents
```

---

## Agent Quality Rubric

Every agent is scored across 5 dimensions (1–5 each, 25 max):

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
| `calendar-fetch` | macOS + Outlook | Stub returns "unavailable" |
| `inbox-fetch` | macOS + Outlook | Stub returns "unavailable" |
| `reminders-fetch` | macOS | Section omitted from briefing |
| `email-manager` | macOS + Outlook | Installed but AppleScript calls will fail |

The installer detects your platform and installs Linux stubs for macOS-only skills automatically. Morning briefings on Linux still work — `git-activity` and `action-items` run on all platforms.

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
CAST                            Claude Code Dashboard
──────────────────────          ────────────────────────────────────
~/.claude/agents/*.md       →   Agent roster, model badges, quality scores
~/.claude/routing-log.jsonl →   Live routing feed, miss-rate chart, dispatch stats
~/.claude/plans/            →   Plan history, dispatch manifest viewer
~/.claude/briefings/        →   Productivity output feed
~/.claude/reports/          →   Chain execution reports from chain-reporter
```

The dashboard auto-discovers agents from `~/.claude/agents/*.md` on every API call — no sync step needed. It works with any Claude Code installation, not just CAST.

---

## License

MIT. See [LICENSE](LICENSE).

---

Built with Claude Code. Designed to make Claude Code work the way a senior engineering team works.
