# CAST — Claude Agent Specialist Team

**Automatic agent dispatch for Claude Code. The right specialist runs without you asking.**

CAST embeds a 29-agent development team into Claude Code at the hook layer. When you type a prompt, three enforcement hooks intercept it before Claude sees it — dispatching the right specialist, enforcing code review after every write, and hard-blocking raw `git commit`. No manual `/cast` command required for most tasks.

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
│  Matches prompt against 21 routes in routing-table.  │
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

## Agent Self-Dispatch

Hook-layer dispatch gets the right specialist running. But four agents go further — they internally dispatch other agents as mandatory post-steps, without waiting for the hook layer to catch it.

| Agent | After completing | Dispatches |
|---|---|---|
| `debugger` | Fix is verified | `test-writer` (regression test), then `code-reviewer` (review fix + test) |
| `test-writer` | Tests pass | `code-reviewer` (review test quality: behavior-based queries, edge case coverage) |
| `refactor-cleaner` | Each batch passes build + tests | `code-reviewer` (confirm no logic changed), then `commit` |
| `build-error-resolver` | Build passes | `code-reviewer` (confirm minimal diff), then `commit` |

This is a second enforcement layer — agents cannot complete without triggering their downstream chain. The hook layer catches cases that slip through; the self-dispatch layer is unconditional within the agent itself.

### Structured Status Blocks

All four code-modifying agents end with a standardized status block:

```
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Summary: [what was done]
Files changed: [list]
Concerns: [required if DONE_WITH_CONCERNS]
Context needed: [required if NEEDS_CONTEXT]
```

The orchestrator reads these blocks to control execution flow: `DONE` proceeds, `DONE_WITH_CONCERNS` logs and continues, `BLOCKED` halts and surfaces to the user, `NEEDS_CONTEXT` pauses for clarification.

---

## Routing Table

21 routes covering the most common development tasks. Each route specifies the agent, model tier, and optional post-chain:

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

## Planner Manifests

The `planner` agent doesn't just write a task breakdown — it appends an **Agent Dispatch Manifest** to the plan file. The orchestrator reads this manifest and executes the full agent queue with one user approval.

Every planner manifest follows a 5-batch structure:

| Batch | Type | Description |
|---|---|---|
| 1 | parallel | Architecture / research review |
| 2 | sequential | Implementation (main model or specialist) |
| 3 | sequential | Spec compliance review — "did we build what was asked?" |
| 4 | sequential | Code quality review + test writing |
| 5 | sequential | Commit |

Batches 3 and 4 are always sequential and always separate. Batch 3 checks spec compliance — whether every requirement was implemented, nothing extra was built, no misunderstandings of the plan. Batch 4 checks code quality — correctness, edge cases, naming, error handling. Merging these into a single parallel batch is disallowed by the planner's rules.

The manifest is a `json dispatch` code block in the plan file. The orchestrator parses it, presents the queue for one-shot approval, then executes in batch order.

---

## Orchestrator

The `orchestrator` agent reads an Agent Dispatch Manifest and runs the full queue. It handles four batch types:

| Batch type | How it runs |
|---|---|
| `"parallel": true` | All agents dispatched simultaneously in a single response |
| `"parallel": false` | Single agent dispatched, waits for output before next batch |
| `"subagent_type": "main"` | Claude (the main model) implements directly — no Agent tool call |
| `"type": "fan-out"` | Agents dispatched in parallel; outputs synthesized into a **Fan-out Summary**; that summary is passed as prefixed context to every agent in the next batch |

**Progress tracking:** The orchestrator initializes a TodoWrite list at startup — one item per batch. Items are marked `completed` as batches finish, giving visible per-batch status throughout execution.

**Status-aware execution:** After each batch, the orchestrator reads the agent's status block:

- `DONE` — proceed to next batch
- `DONE_WITH_CONCERNS` — mark completed, log the Concerns line, surface in final summary
- `BLOCKED` — mark as stuck, halt immediately, report to user and wait for direction
- `NEEDS_CONTEXT` — pause, surface the missing context to the user, re-dispatch with updated context

**Completion summary:** After all batches finish, the orchestrator outputs a per-batch summary. If any batch returned `DONE_WITH_CONCERNS`, a separate concerns section lists each concern with its batch number.

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
6. **Debugger self-dispatches `test-writer`** — writes a regression test that would have caught the bug
7. `test-writer` self-dispatches `code-reviewer` (haiku) after the test file is written
8. Code reviewer approves — debugger then self-dispatches `code-reviewer` again on the fix itself
9. Claude dispatches `commit` (haiku) per the hook chain directive
10. `pre-tool-guard.sh` allows the commit because the commit agent uses `CAST_COMMIT_AGENT=1 git commit`
11. Session ends — `Stop` hook verifies nothing was skipped

Total cost: sonnet (debug) + sonnet (test-writer) + haiku (code-reviewer × 2) + haiku (commit). Not five sonnet calls.

---

## CLAUDE.md Design

`CLAUDE.md.template` is 60 lines. The design constraint is intentional — Claude Code loads this into every context window. A 230-line advisory document gets ignored when context pressure builds. A 60-line file with three unconditional directives does not.

The file defines:
1. The three hook directives (mandatory, no exceptions)
2. The inline whitelist (what Claude handles directly)
3. The agent registry (29 agents, haiku/sonnet assignments)
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

29 agents across 5 tiers.

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
| `bash-specialist` | — | CAST hook scripts, exit codes, hookSpecificOutput format |

---

## Memory Architecture

Two independent memory layers persist state across every session. Together they make every conversation context-aware from the first token.

### Project Memory

Stored at `~/.claude/projects/<project-hash>/memory/`. This directory is project-specific — it lives alongside your working directory's session history and is loaded automatically when you open Claude Code in that project.

```
~/.claude/projects/<hash>/memory/
├── MEMORY.md                ← Index file — loaded into every context window
├── user_role.md             ← Who you are, your expertise level, your preferences
├── feedback_testing.md      ← Corrections and confirmations from past sessions
├── project_decisions.md     ← Goals, constraints, architectural choices
└── reference_external.md   ← Where to find info: Linear boards, Grafana dashboards, Slack channels
```

`MEMORY.md` is an index. When Claude loads a session, it reads the index, which points to individual memory files. Memory files use four typed categories:

| Type | Stores | Example |
|---|---|---|
| `user` | Role, expertise, preferences | "Senior Go dev, new to React — frame frontend explanations in terms of backend analogues" |
| `feedback` | Corrections + confirmed approaches | "Don't mock the database — integration tests must hit real DB; prior incident caused prod failure" |
| `project` | Goals, decisions, deadlines | "Auth rewrite is compliance-driven, not tech debt — scope decisions favor compliance over ergonomics" |
| `reference` | Where info lives externally | "Pipeline bugs tracked in Linear project INGEST; oncall watches grafana.internal/d/api-latency" |

Claude writes to project memory automatically — when it learns something about your role, when you correct an approach, when a project decision is made. The next session starts with full context. **You never re-explain your stack, preferences, or project history.**

### Agent Memory

Each specialist maintains its own memory at `~/.claude/agent-memory-local/<agent>/MEMORY.md`. These are isolated per-agent and consulted at invocation time.

```
~/.claude/agent-memory-local/
├── planner/MEMORY.md        ← Preferred plan formats, task sizing preferences
├── debugger/MEMORY.md       ← Recurring failure patterns in this codebase
├── code-reviewer/MEMORY.md  ← Project-specific review standards, what to ignore
├── commit/MEMORY.md         ← Commit message style, branch conventions
├── test-writer/MEMORY.md    ← Test patterns, framework setup, coverage targets
└── ...24 more agents
```

The debugger remembers where bugs have appeared before. The code reviewer remembers what your project considers acceptable. The commit agent remembers your commit message style. Each specialist improves over time within your codebase — not globally, but for your specific working patterns.

### What This Means in Practice

- Claude Code on a fresh session in a known project: full context, no onboarding prompts
- Agents invoked for the first time in a new project: they read what the previous session wrote
- Session consistency is maintained by the memory system, not by keeping the same context window alive
- Token usage drops because Claude isn't re-establishing context every session

---

## Config & Rules Layer

The `~/.claude/rules/` directory sets behavioral context that loads into every session automatically. Unlike agent-specific memory, rules are global — they apply regardless of which agent is running or which project is open.

```
~/.claude/rules/
├── working-conventions.md     ← Quality gates: TDD, commit agent mandate, review mandate
├── stack-context.md           ← Your tech stack: React version, test framework, DB, CSS lib
└── project-catalog.md         ← Your projects: paths, stacks, notes per repo
```

**`working-conventions.md`** is the enforcer — it contains the same mandates as the hooks but in natural language: always use the commit agent, always invoke code-reviewer after changes, never mock the database. Claude reads this alongside hook directives.

**`stack-context.md`** means agents never guess your stack. The test-writer knows you're on Vitest, not Jest. The build-error-resolver knows you're on Vite, not webpack. The architect knows your ORM.

**`project-catalog.md`** gives agents a map of your entire workspace — which repos exist, where they live, what stack they use, and any per-project notes. The debugger can cross-reference other projects. The planner can scope work against your actual repository structure.

These three files are the difference between an agent that asks "what's your tech stack?" on every session and one that already knows.

---

## Skills

Skills are reusable multi-step procedures — composed workflows that agents invoke as sub-routines. Unlike slash commands (which dispatch a single agent), skills orchestrate sequences of tool calls and can be called from within an agent's context.

| Skill | Platform | What it does |
|---|---|---|
| `calendar-fetch` | macOS + Outlook | Fetches today's calendar events via AppleScript |
| `inbox-fetch` | macOS + Outlook | Fetches unread emails, classifies by priority |
| `reminders-fetch` | macOS | Fetches due and overdue Apple Reminders tasks |
| `git-activity` | All | Scans project repos for yesterday's commits across your catalog |
| `action-items` | All | Extracts unchecked checkboxes from meeting notes |
| `briefing-writer` | All | Assembles morning briefing sections into a structured markdown file |
| `careful-mode` | All | Read-only session — blocks all Write, Edit, and Bash operations |
| `freeze-mode` | All | Exploration mode — no modifications allowed |
| `wizard` | All | Multi-step workflow with human approval gates before destructive operations |

The `morning-briefing` agent uses five of these skills in sequence: `calendar-fetch` → `inbox-fetch` → `reminders-fetch` → `git-activity` → `action-items` → `briefing-writer`. The result is a structured markdown briefing at `~/.claude/briefings/` every morning with zero prompting.

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
| **Full** | All 29 agents, 30 commands, 9 skills, 3 scripts, 4 hooks, rules |
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
claude-agent-team/                    # What you clone
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
│   └── routing-table.json            # 21 routes: patterns, agent, model, confidence, post_chain
│
├── agents/
│   ├── core/           (8 agents)
│   ├── extended/       (8 agents)
│   ├── productivity/   (5 agents)
│   ├── professional/   (3 agents)
│   └── orchestration/  (5 agents)
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

### Runtime Layout (`~/.claude/` after install)

```
~/.claude/
├── CLAUDE.md                         # 60-line directive file — loaded every session
├── settings.local.json               # Hook wiring (4 hooks), permissions, sandbox
├── config.sh                         # Your project paths — sourced by skills
│
├── agents/                           # 29 agent definitions (.md frontmatter + prompt)
├── commands/                         # 30 slash command prompts
├── skills/                           # 9 multi-step skill workflows
│
├── rules/
│   ├── working-conventions.md        # Global quality mandates
│   ├── stack-context.md              # Your tech stack (filled in at install)
│   └── project-catalog.md           # Your project map (filled in at install)
│
├── config/
│   └── routing-table.json            # 21 routes — edit here to add/remove dispatch rules
│
├── routing-log.jsonl                 # Append-only dispatch log (every prompt, every route)
│
├── projects/<hash>/
│   ├── memory/MEMORY.md             ← Project memory index (auto-loaded per project)
│   └── *.jsonl                       # Session conversation history
│
├── agent-memory-local/
│   └── <agent>/MEMORY.md            ← Per-agent learned preferences and patterns
│
├── plans/                            # Planner output — JSON manifests + markdown specs
├── briefings/                        # Morning briefing output (daily markdown)
├── reports/                          # Chain reporter output
└── meetings/                         # Meeting notes processor output
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
| `UserPromptSubmit` | Every user prompt | `route.sh` | Matches against 21 routes, injects [CAST-DISPATCH] directive or logs no-match |
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

Built with Claude Code. Designed to run the way a real engineering team works — automatically, at the infrastructure layer, with every session informed by what the last one learned.
