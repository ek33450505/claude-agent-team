# CAST — Claude Agent Specialist Team

**Automatic agent dispatch for Claude Code. The right specialist runs without you asking.**

CAST embeds a 28-agent development team into Claude Code at the hook layer. When you type a prompt, three enforcement hooks intercept it before Claude sees it — dispatching the right specialist, enforcing code review after every write, and hard-blocking raw `git commit`. No manual `/cast` command required for most tasks.

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

> **[Interactive Architecture Diagram](https://gistpreview.github.io/?318b393bdb8cf26b18ce66334bcafc91)**

---

## The Problem

Claude Code out of the box is a generalist. Given free rein, it will write tests, review code, plan features, and commit changes — all inline, all as the most expensive model available. There is no enforcement layer. You have to remember to ask for the right specialist. You have to remember to run code review. You have to remember not to use `git commit` directly.

CAST solves this at the infrastructure layer with three hooks wired into Claude Code's event system — before, during, and after every interaction.

---

## Architecture

```
User types a prompt
        │
        ▼
┌───────────────────────────────────────────────────────┐
│  Hook 1 — UserPromptSubmit                            │
│  scripts/route.sh                                     │
│                                                       │
│  Matches prompt against 19 routes in routing-table.  │
│  On match: injects [CAST-DISPATCH] directive into    │
│  Claude's context via hookSpecificOutput.            │
│  Claude sees the directive alongside the prompt and  │
│  dispatches the named agent immediately.             │
│                                                       │
│  Also logs every prompt to routing-log.jsonl.        │
└─────────────────────────┬─────────────────────────────┘
                          │ Claude dispatches agent
                          ▼
        Agent executes (Write/Edit tools)
                          │
                          ▼
┌───────────────────────────────────────────────────────┐
│  Hook 2 — PostToolUse (Write|Edit)                    │
│  scripts/post-tool-hook.sh                            │
│                                                       │
│  Injects [CAST-REVIEW] directive — Claude must        │
│  dispatch code-reviewer (haiku) after finishing.      │
│  Also runs prettier auto-format on JS/TS/CSS/JSON.    │
│  Skips subagents (CLAUDE_SUBPROCESS check).           │
└───────────────────────────────────────────────────────┘

        Claude issues: git commit
                          │
                          ▼
┌───────────────────────────────────────────────────────┐
│  Hook 3 — PreToolUse (Bash)                           │
│  scripts/pre-tool-guard.sh                            │
│                                                       │
│  If command contains "git commit" without             │
│  CAST_COMMIT_AGENT=1 inline → exit 2.                │
│  Tool call never runs. Commit agent is required.      │
│                                                       │
│  Same pattern for git push (CAST_PUSH_OK=1).          │
└───────────────────────────────────────────────────────┘

        Claude issues: response
                          │
                          ▼
┌───────────────────────────────────────────────────────┐
│  Hook 4 — Stop                                        │
│  Prompt injection                                     │
│                                                       │
│  Safety net: were code changes made without           │
│  dispatching code-reviewer? Commits made without      │
│  the commit agent? Dispatch now before completing.    │
└───────────────────────────────────────────────────────┘
```

Pure config, shell scripts, and markdown. Zero custom application code.

---

## How Dispatch Works

`route.sh` is the primary dispatcher. It runs on every user prompt via the `UserPromptSubmit` hook and outputs structured JSON that Claude Code injects into Claude's context window alongside the user's message.

When a prompt matches a route:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: debugger (confidence: hard)\nMANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).\nPass the user's full prompt as the agent task. Do NOT handle this inline.\n[CAST-CHAIN] After debugger completes: dispatch `code-reviewer` -> `commit` in sequence."
  }
}
```

Claude sees `[CAST-DISPATCH]` as a system-level instruction. `CLAUDE.md` (60 lines) defines three directives it must obey unconditionally:

- **`[CAST-DISPATCH]`** — Dispatch the named agent. Do not handle inline.
- **`[CAST-REVIEW]`** — Dispatch `code-reviewer` after the current logical unit of changes.
- **`[CAST-CHAIN]`** — After the primary agent completes, dispatch the listed agents in sequence.

The `confidence` field in each route controls directive strength:
- `"confidence": "hard"` → `MANDATORY: Dispatch the agent`
- `"confidence": "soft"` → `RECOMMENDED: Consider dispatching`

On no match, `route.sh` outputs nothing. Claude handles the prompt inline (answering questions, reading code, short analysis).

---

## Routing Table

19 routes covering the most common development tasks. Each route specifies the agent, model tier, and optional post-chain:

| Trigger patterns (examples) | Agent | Model | Post-chain |
|---|---|---|---|
| `fix.*bug`, `debug`, `not working`, `error`, `crash` | `debugger` | sonnet | code-reviewer → commit |
| `write.*test`, `test coverage`, `jest`, `vitest` | `test-writer` | sonnet | commit |
| `^commit$`, `git commit`, `create a commit` | `commit` | haiku | — |
| `review.*code`, `code review`, `check.*changes` | `code-reviewer` | haiku | commit |
| `plan.*implement`, `let's build`, `add.*feature` | `planner` | sonnet | auto-dispatch-from-manifest |
| `refactor`, `dead code`, `clean up`, `unused import` | `refactor-cleaner` | haiku | code-reviewer → commit |
| `update.*readme`, `write.*docs`, `update.*changelog` | `doc-updater` | haiku | commit |
| `security.*review`, `owasp`, `sql injection` | `security` | sonnet | — |
| `architecture`, `trade-off`, `ADR`, `design.*decision` | `architect` | sonnet | — |
| `build.*error`, `typescript error`, `eslint.*error` | `build-error-resolver` | haiku | commit |
| `e2e test`, `playwright`, `end-to-end` | `e2e-runner` | sonnet | — |
| `research`, `compare.*librar`, `evaluate.*tool` | `researcher` | sonnet | — |
| `rewrite.*readme`, `readme.*audit` | `readme-writer` | sonnet | commit |

Full table: `config/routing-table.json`

---

## Token Efficiency

Haiku agents cost roughly 20x less than Opus and 5x less than Sonnet. CAST enforces model tier discipline automatically — routine mechanical tasks always route to haiku, reasoning-heavy tasks route to Sonnet.

| Task type | Model | Examples |
|---|---|---|
| Commit, review, docs, cleanup, build fixes | **haiku** | commit, code-reviewer, doc-updater, refactor-cleaner, build-error-resolver |
| Debugging, planning, testing, architecture | **sonnet** | debugger, planner, test-writer, architect, security |
| Full codebase analysis, system design | **opus** | prefix prompt with `opus:` to escalate |

Without enforcement, Claude Code defaults to running everything as the active model — typically Sonnet. CAST's routing table forces the cheapest capable model for every task.

---

## Example: End-to-End Dispatch

You type: `fix the TypeError in the auth middleware`

1. `route.sh` matches `TypeError` against the debugger route (hard confidence)
2. Injects into Claude's context:
   ```
   [CAST-DISPATCH] Route: debugger (confidence: hard)
   MANDATORY: Dispatch the `debugger` agent via the Agent tool (model: sonnet).
   [CAST-CHAIN] After debugger completes: dispatch `code-reviewer` -> `commit` in sequence.
   ```
3. Claude dispatches `debugger` (sonnet) with your full prompt
4. Debugger finds and fixes the bug — writes to file
5. `post-tool-hook.sh` fires on the Write, injects `[CAST-REVIEW]`
6. Claude dispatches `code-reviewer` (haiku) per the chain directive
7. Code reviewer approves — Claude dispatches `commit` (haiku)
8. `pre-tool-guard.sh` allows the commit because the commit agent uses `CAST_COMMIT_AGENT=1 git commit`
9. Session ends — `Stop` hook verifies nothing was skipped

Total cost: sonnet (debug) + haiku (review) + haiku (commit). Not three sonnet calls.

---

## CLAUDE.md Design

`CLAUDE.md.template` is 60 lines. The design constraint is intentional — Claude Code loads this into every context window. A 230-line advisory document gets ignored when context pressure builds. A 60-line file with three unconditional directives does not.

The file defines:
1. The three hook directives (mandatory, no exceptions)
2. The inline whitelist (what Claude handles directly)
3. The agent registry (28 agents, haiku/sonnet assignments)
4. Slash command list (manual overrides when routing misses)

---

## Slash Commands

30 commands at `~/.claude/commands/`. Each is a manual override — use when you know exactly which agent you want or when automatic routing doesn't fire.

```
/plan    /debug    /test     /review   /commit   /secure
/data    /query    /architect /tdd      /e2e      /build-fix
/refactor /docs    /readme   /research /report   /meeting
/email   /morning  /browser  /qa       /present  /stage
/verify  /orchestrate /chain-report    /cast     /eval
```

`/cast` is the universal dispatcher for prompts that don't match routing patterns — it uses Claude's NLU to classify intent and select the right agent.

---

## Agent Roster

28 agents across 5 tiers.

**Haiku — routine and mechanical**

| Agent | Command | Role |
|---|---|---|
| `commit` | `/commit` | Semantic commits, staged content verification |
| `code-reviewer` | `/review` | Readability, correctness, diff-focused |
| `build-error-resolver` | `/build-fix` | Vite/CRA/TS/ESLint errors, minimal diffs |
| `auto-stager` | `/stage` | Pre-commit staging, never stages `.env` |
| `refactor-cleaner` | `/refactor` | Dead code, unused imports, cleanup |
| `doc-updater` | `/docs` | README, changelog, JSDoc |
| `chain-reporter` | `/chain-report` | Chain summaries to `~/.claude/reports/` |
| `db-reader` | `/query` | Read-only SQL queries — writes blocked at hook level |
| `report-writer` | `/report` | Status reports, sprint summaries |
| `meeting-notes` | `/meeting` | Action items and decisions from notes |
| `verifier` | `/verify` | Build check + TODO scan before quality gate |
| `router` | — | LLM classifier for unmatched prompts |

**Sonnet — reasoning-heavy**

| Agent | Command | Role |
|---|---|---|
| `planner` | `/plan` | Task plans with JSON Agent Dispatch Manifest |
| `debugger` | `/debug` | Errors, stack traces, unexpected behavior |
| `test-writer` | `/test` | Jest/Vitest/RTL tests with coverage |
| `security` | `/secure` | OWASP review, secrets scanning |
| `architect` | `/architect` | System design, ADRs, module boundaries |
| `tdd-guide` | `/tdd` | Red-green-refactor TDD workflow |
| `e2e-runner` | `/e2e` | Playwright E2E with stack auto-discovery |
| `readme-writer` | `/readme` | Full README audit against codebase |
| `researcher` | `/research` | Tool/library evaluation, comparisons |
| `data-scientist` | `/data` | SQL queries, BigQuery analysis |
| `email-manager` | `/email` | Email triage and drafting (macOS + Outlook) |
| `morning-briefing` | `/morning` | Calendar + email + reminders + git activity |
| `browser` | `/browser` | Browser automation, screenshots, scraping |
| `qa-reviewer` | `/qa` | Second-opinion QA on functional correctness |
| `presenter` | `/present` | Slide decks, status presentations |
| `orchestrator` | `/orchestrate` | Agent Dispatch Manifest execution |

---

## Memory Architecture

Two layers that persist across every session.

```
~/.claude/
├── projects/*/memory/           ← Project memory (per working directory)
│   ├── MEMORY.md                ← Index — loaded into every session via CLAUDE.md
│   ├── user_role.md
│   ├── feedback_testing.md
│   └── project_decisions.md
│
└── agent-memory-local/          ← Agent memory (per specialist)
    ├── planner/MEMORY.md        ← What planner has learned across all sessions
    ├── debugger/MEMORY.md       ← Recurring failure patterns
    ├── code-reviewer/MEMORY.md  ← Project-specific review preferences
    └── ...25 more agents
```

**Project memory** — loaded automatically. Claude never asks who you are or what your stack is.

**Agent memory** — per-specialist. Each agent consults its own `MEMORY.md` on invocation and updates it when something is worth preserving. Four memory types: `user` (role, preferences), `feedback` (what worked, corrections), `project` (goals, decisions), `reference` (where external info lives).

---

## Skills

9 reusable multi-step procedures that agents invoke as sub-workflows: `calendar-fetch`, `inbox-fetch`, `reminders-fetch` (macOS + Outlook), `git-activity`, `action-items`, `briefing-writer`, `careful-mode`, `freeze-mode`, `wizard` (all platforms).

The installer detects platform and installs Linux stubs for macOS-only skills.

---

## Installation

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

The installer offers three modes:

| Option | What you get |
|---|---|
| **Full** | All 28 agents, 30 commands, 9 skills, 3 scripts, 4 hooks, rules |
| **Core** | 8 essential agents + their commands (minimal, portable) |
| **Custom** | Choose categories: core, extended, productivity, professional |

Your existing `~/.claude/` is backed up before anything is copied.

**After install, personalize 3 files:**

1. `~/.claude/config.sh` — your project directories
2. `~/.claude/rules/stack-context.md` — your tech stack
3. `~/.claude/rules/project-catalog.md` — your projects

Then merge `settings.template.json` into your `~/.claude/settings.local.json` to wire the hooks.

---

## Repo Structure

```
claude-agent-team/
├── install.sh                        # Interactive installer (full / core / custom)
├── CLAUDE.md.template                # Global context — 60 lines, 3 directives
├── config.sh.template                # Shared project paths for skills and scripts
├── settings.template.json            # Hooks + sandbox config (merge into settings.local.json)
│
├── scripts/
│   ├── route.sh                      # UserPromptSubmit — dispatch injection + logging
│   ├── post-tool-hook.sh             # PostToolUse Write|Edit — review injection + prettier
│   └── pre-tool-guard.sh             # PreToolUse Bash — hard-blocks git commit/push
│
├── config/
│   └── routing-table.json            # 19 routes: patterns, agent, model, confidence, post_chain
│
├── agents/
│   ├── core/           (8 agents)
│   ├── extended/       (8 agents)
│   ├── productivity/   (5 agents)
│   ├── professional/   (3 agents)
│   └── orchestration/  (4 agents)
│
├── commands/           (30 commands) # One .md per slash command
│
├── skills/             (9 skills)    # Each in its own subdirectory with SKILL.md
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

## Extending CAST

### Add a route

Edit `config/routing-table.json`:

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

`route.sh` reads this file on every prompt. No restart required.

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

Add a route entry to start auto-dispatching it. Or invoke it manually via `/cast`.

### Add a slash command

Create `~/.claude/commands/my-command.md` with the agent prompt and `$ARGUMENTS` placeholder. Reference it as `/my-command <input>`.

---

## Hooks Reference

| Hook | Trigger | Script | What it does |
|---|---|---|---|
| `UserPromptSubmit` | Every user prompt | `route.sh` | Matches against 19 routes, injects [CAST-DISPATCH] directive or logs no-match |
| `PostToolUse` | After Write or Edit | `post-tool-hook.sh` | Injects [CAST-REVIEW] directive; runs prettier auto-format |
| `PreToolUse` | Before every Bash call | `pre-tool-guard.sh` | Hard-blocks `git commit` and `git push` (exit 2) |
| `Stop` | Before response | prompt | Safety net — catches missed reviews and commits |

---

## Companion: Claude Code Dashboard

CAST writes structured data that the **[Claude Code Dashboard](https://github.com/ek33450505/claude-code-dashboard)** visualizes in real time.

| CAST output | Dashboard view |
|---|---|
| `~/.claude/routing-log.jsonl` | Live routing feed, dispatch stats, no-match rate |
| `~/.claude/agents/*.md` | Agent roster, model tier badges, quality scores |
| `~/.claude/plans/` | Plan history, manifest viewer |
| `~/.claude/briefings/` | Productivity output feed |
| `~/.claude/reports/` | Chain execution reports |

The dashboard reads `routing-log.jsonl` to show which agents are firing, how often routes miss, and which tasks are handled inline. Every `route.sh` execution writes a log entry regardless of whether it matched — no-match events are first-class data.

The dashboard auto-discovers agents from `~/.claude/agents/*.md` on every API call. It works with any Claude Code installation, not just CAST.

---

## License

MIT. See [LICENSE](LICENSE).

---

Built with Claude Code. Designed to make Claude Code work the way a senior engineering team works — automatically, at the infrastructure layer, not as advisory text that gets ignored.
