# Claude Agent Team

**A production-grade Claude Code framework with 22 specialized agents, 23 slash commands, 9 skills, and a 2-hook safety system.**

Install in 3 commands. Customize in 10 minutes. Transform how you use Claude Code.

```
22 Agents  |  23 Commands  |  9 Skills  |  2 Hooks  |  3 Rules  |  2 Scripts
```

---

## What This Is

Claude Code ships with powerful built-in tools, but out of the box it's a generalist. This framework turns it into an **orchestrated team of specialists** — a planner that architects before you code, a debugger that investigates before it guesses, a security reviewer that catches OWASP issues, a TDD guide that enforces red-green-refactor, and 18 more.

Every agent has a defined role, model assignment (sonnet or haiku), and trigger conditions. Slash commands route to agents. Skills chain multi-step workflows. Hooks enforce quality gates automatically. The result: Claude Code that works the way a senior engineering team works — with specialization, process, and memory.

> **[Interactive Architecture Diagram](https://gistpreview.github.io/?318b393bdb8cf26b18ce66334bcafc91)** — explore the full 5-layer system visually

---

## Quick Start

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

The installer gives you three options:

| Option | What you get |
|---|---|
| **Full install** | All 22 agents, 23 commands, 9 skills, scripts, rules, hooks |
| **Core only** | 8 essential agents + their commands (minimal, portable) |
| **Custom** | Pick categories: core, extended, productivity, professional, macOS skills |

After install, edit 3 files to personalize:
1. `~/.claude/config.sh` — your project directories
2. `~/.claude/rules/stack-context.md` — your tech stack
3. `~/.claude/rules/project-catalog.md` — your projects

---

## Architecture

```
                        ┌─────────────────────┐
                        │     YOU (Layer 1)    │
                        │  Natural language,   │
                        │  /commands, skills   │
                        └─────────┬───────────┘
                                  │
                        ┌─────────▼───────────┐
                        │  CLAUDE.md (Layer 2) │
                        │  Context injection,  │
                        │  routing decisions   │
                        └─────────┬───────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
    ┌─────────▼─────┐  ┌─────────▼─────┐  ┌─────────▼─────┐
    │   Commands    │  │    Skills     │  │    Rules      │
    │   (Layer 3)   │  │   (Layer 3)   │  │   (Layer 3)   │
    │  23 dispatch  │  │  9 reusable   │  │  3 always-on  │
    │   wrappers    │  │  procedures   │  │   context     │
    └───────┬───────┘  └───────┬───────┘  └───────────────┘
            │                  │
            └────────┬─────────┘
                     │
           ┌─────────▼───────────┐
           │   Agents (Layer 4)  │
           │  22 specialists     │
           │  sonnet + haiku     │
           └─────────┬───────────┘
                     │
           ┌─────────▼───────────┐
           │  Memory (Layer 5)   │
           │  2-layer persistent │
           │  + output dirs      │
           └─────────────────────┘
```

---

## Agent Roster

### Core Agents (8) — always installed

| Agent | Model | Slash Command | When to use |
|---|---|---|---|
| `planner` | sonnet | `/plan` | Starting any new feature, refactor, or complex change |
| `debugger` | sonnet | `/debug` | Any error, test failure, or unexpected behavior |
| `test-writer` | sonnet | `/test` | After writing or modifying code; when coverage is needed |
| `code-reviewer` | haiku | `/review` | Immediately after writing or modifying code |
| `data-scientist` | sonnet | `/data` | Data analysis tasks, SQL queries, BigQuery exploration |
| `db-reader` | haiku | `/query` | Read-only DB queries (SELECT only — writes blocked at hook level) |
| `commit` | haiku | `/commit` | Creating semantic git commits |
| `security` | sonnet | `/secure` | Security review, OWASP, secrets scanning |

### Extended Agents (6)

| Agent | Model | Slash Command | When to use |
|---|---|---|---|
| `architect` | sonnet | `/architect` | System design, ADRs, module boundaries, trade-off analysis |
| `tdd-guide` | sonnet | `/tdd` | Red-green-refactor TDD workflow (complements test-writer) |
| `build-error-resolver` | haiku | `/build-fix` | Fix Vite/CRA/TS/ESLint build errors with minimal diffs |
| `e2e-runner` | sonnet | `/e2e` | Playwright E2E tests for React apps |
| `refactor-cleaner` | haiku | `/refactor` | Dead code, unused imports, dependency cleanup |
| `doc-updater` | haiku | `/docs` | README, changelog, JSDoc updates |

### Productivity Agents (5)

| Agent | Model | Slash Command | When to use |
|---|---|---|---|
| `researcher` | sonnet | `/research` | Technical research, tool/library evaluation, comparisons |
| `report-writer` | haiku | `/report` | Status reports, sprint summaries, stakeholder updates |
| `meeting-notes` | haiku | `/meeting` | Process meeting notes, extract action items and decisions |
| `email-manager` | sonnet | `/email` | Email triage, drafting, inbox summary (macOS + Outlook) |
| `morning-briefing` | sonnet | `/morning` | Daily briefing: calendar + email + reminders + git + action items |

### Professional Agents (3)

| Agent | Model | Slash Command | When to use |
|---|---|---|---|
| `browser` | sonnet | `/browser` | Browser automation, form filling, screenshots, web scraping |
| `qa-reviewer` | sonnet | `/qa` | Second-opinion QA review focused on functional correctness |
| `presenter` | sonnet | `/present` | Slide decks, status presentations, demo materials |

### Standalone Command

| Command | Purpose |
|---|---|
| `/eval` | Evaluator-optimizer loop — dispatches a reviewer agent, fixes critical issues, re-evaluates (max 2x) |

---

## Skills

Skills are reusable procedures that agents invoke — multi-step workflows packaged as prompts.

| Skill | Type | Purpose |
|---|---|---|
| `calendar-fetch` | Data fetch | Fetch today's calendar from Outlook (macOS only) |
| `inbox-fetch` | Data fetch | Fetch unread emails from Outlook (macOS only) |
| `reminders-fetch` | Data fetch | Fetch due reminders from Apple Reminders (macOS only) |
| `git-activity` | Data fetch | Scan project repos for yesterday's commits |
| `action-items` | Data fetch | Find unchecked action items from meeting notes |
| `briefing-writer` | Composer | Assemble morning briefing from all data sources |
| `careful-mode` | Safety mode | Require confirmation before every Write, Edit, Bash |
| `freeze-mode` | Safety mode | Read-only session — no file modifications |
| `wizard` | Approval gate | Human-approval gates before destructive operations |

---

## Hooks

Two lifecycle hooks enforce quality automatically:

| Hook | Trigger | Action |
|---|---|---|
| **PostToolUse** | After any `Write` or `Edit` | Runs `auto-format.sh` (Prettier if configured) |
| **Stop** | Before Claude completes a response | Nudge: "if code was modified but no tests were run, suggest running them" |

---

## Memory Architecture

| Layer | Location | Purpose |
|---|---|---|
| **Project memory** | `~/.claude/projects/*/memory/` | Per-project context that persists across sessions |
| **Agent memory** | `~/.claude/agent-memory-local/` | Each agent learns and stores patterns independently |

### Output Directories

All generated output stays within `~/.claude/`:

| Directory | Purpose |
|---|---|
| `~/.claude/briefings/` | Morning briefing output |
| `~/.claude/meetings/` | Processed meeting notes |
| `~/.claude/reports/` | Generated reports |
| `~/.claude/plans/` | Implementation plans |

---

## Data Flow Patterns

### Simple Code Review (`/review` with 2 files)
```
You → /review → Main Agent → code-reviewer (haiku) → Summary
```

### Large Review (`/review` with 12+ files)
```
You → /review → Main Agent ─┬→ code-reviewer (readability)
                             ├→ security (OWASP)
                             └→ qa-reviewer (correctness)
                                      ↓
                              Synthesized report
```

### Morning Briefing (`/morning`)
```
You → /morning → morning-briefing ─→ 5 skills (calendar, inbox, reminders, git, action-items)
                                   ─→ briefing-writer
                                   ─→ ~/.claude/briefings/YYYY-MM-DD.md
```

### Evaluator-Optimizer (`/eval`)
```
You → /eval → Identify artifact → Dispatch reviewer → Critical? → Fix & re-evaluate (max 2x) → Report
```

---

## Customization Guide

### Add your projects

Edit `~/.claude/config.sh`:
```bash
PROJECTS=(
  "$HOME/Projects/your-app"
  "$HOME/Projects/your-api"
)

declare -A PROJECT_NAMES=(
  [your-app]="My App"
  [your-api]="My API"
)
```

### Define your tech stack

Edit `~/.claude/rules/stack-context.md` — describe your languages, frameworks, testing tools, and build systems. Agents reference this to give stack-aware advice.

### Add your own agents

Create a markdown file in `~/.claude/agents/`:
```markdown
---
name: my-agent
description: What this agent does
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
---

You are a specialist in [domain]. Your role is to...
```

Then create a matching command in `~/.claude/commands/`:
```markdown
---
description: Dispatch to my-agent
---

Use the `my-agent` agent for: $ARGUMENTS
```

### Merge settings

Review `~/.claude/settings.template.json` and merge the hooks and sandbox config into your existing `~/.claude/settings.local.json`. The companion `.jsonc` file has comments explaining each section.

---

## Platform Notes

Most of this framework is cross-platform. The following features require **macOS**:

| Feature | Requirement | Linux/WSL behavior |
|---|---|---|
| `calendar-fetch` skill | macOS + Microsoft Outlook | Skipped; stub returns "unavailable" note |
| `inbox-fetch` skill | macOS + Microsoft Outlook | Skipped; stub returns "unavailable" note |
| `reminders-fetch` skill | macOS | Skipped; section omitted from briefing |
| `email-manager` agent | macOS + Thunderbird or Outlook | Agent installed but AppleScript calls will fail |

**On Linux/WSL:** The installer auto-detects your platform and skips macOS-only skills. Morning briefings still work — `git-activity` and `action-items` run on all platforms.

These are clearly marked as optional during install.

---

## What's Included

```
claude-agent-team/
├── README.md
├── LICENSE (MIT)
├── install.sh                        # Interactive 3-option installer
├── config.sh.template                # Project directories (you fill in)
├── CLAUDE.md.template                # Global context file (you fill in)
├── settings.template.json            # Hooks + sandbox config
├── settings.template.jsonc           # Same, with comments
│
├── agents/
│   ├── core/          (8 agents)     # planner, debugger, test-writer, code-reviewer,
│   │                                 # data-scientist, db-reader, commit, security
│   ├── extended/      (6 agents)     # architect, tdd-guide, build-error-resolver,
│   │                                 # e2e-runner, refactor-cleaner, doc-updater
│   ├── productivity/  (5 agents)     # researcher, report-writer, meeting-notes,
│   │                                 # email-manager, morning-briefing
│   └── professional/  (3 agents)     # browser, qa-reviewer, presenter
│
├── commands/          (23 commands)   # Flat — one .md per slash command
│
├── skills/            (9 skills)     # Each in its own subdirectory
│   ├── calendar-fetch/SKILL.md       # macOS + Outlook
│   ├── inbox-fetch/SKILL.md          # macOS + Outlook
│   ├── reminders-fetch/SKILL.md      # macOS
│   ├── git-activity/SKILL.md
│   ├── action-items/SKILL.md
│   ├── briefing-writer/SKILL.md
│   ├── careful-mode/SKILL.md
│   ├── freeze-mode/SKILL.md
│   ├── wizard/SKILL.md
│   ├── calendar-fetch-linux/SKILL.md  # Linux stub (auto-detected)
│   └── inbox-fetch-linux/SKILL.md     # Linux stub (auto-detected)
│
├── scripts/
│   ├── auto-format.sh                # PostToolUse hook target
│   └── tidy.sh.template              # Cleanup script (you configure paths)
│
└── rules/
    ├── working-conventions.md        # Quality standards (copy verbatim)
    ├── stack-context.md.template     # Your tech stack (you fill in)
    └── project-catalog.md.template   # Your projects (you fill in)
```

---

## Companion: Claude Dashboard

This framework pairs with **[Claude Dashboard](https://github.com/ek33450505/claude-code-dashboard)** — a real-time web UI that visualizes everything this repo installs.

```
┌─────────────────────────────┐     ┌─────────────────────────────┐
│   Claude Agent Team         │     │   Claude Dashboard          │
│                             │     │                             │
│   22 agents, 23 commands,   │────▶│   Real-time agent activity  │
│   9 skills, hooks, rules    │     │   Session history & replay  │
│                             │     │   Agent roster & stats      │
│   Config layer (no runtime) │     │   Memory & knowledge viewer │
└─────────────────────────────┘     │   System health overview    │
          ~/.claude/                │                             │
                                    │   React 19 + Vite + Express │
                                    └─────────────────────────────┘
```

The dashboard reads from `~/.claude/` — the same directory this installer populates. Together they form a complete Claude Code power-user toolkit: **Agent Team** handles orchestration, **Dashboard** handles observability.

The dashboard works with any Claude Code installation, not just this framework.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with Claude Code. Designed to make Claude Code better.
