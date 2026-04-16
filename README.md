<p align="center">
  <img src="docs/cast-banner.png" alt="CAST — Swarm control plane for Anthropic Agent Teams" />
</p>

# CAST v6.0 — Swarm Control Plane

[![BATS Tests](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml/badge.svg)](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml)
![Version](https://img.shields.io/badge/version-6.0-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-30-green)<!-- CAST_AGENT_COUNT -->
![Tests](https://img.shields.io/badge/tests-409-brightgreen)<!-- CAST_TEST_COUNT -->
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

**CAST v6.0 is the control plane for Anthropic's native Agent Teams.** Define multiagent swarms in YAML, let the framework handle orchestration, quality gates, and observability. 29 core specialist agents + peer-to-peer messaging + force-directed swarm visualization + local model fallback.

**[CAST Framework](https://castframework.dev)** | **[Cloud-native deployment guide](docs/swarm-deployment.md)**

---

## What is CAST?

CAST v5.0 transforms Agent Teams from a raw execution primitive into a **production control plane:**

- **Swarm composition in YAML.** Define teams (full-stack, review squad, research cluster), assign agent roles, set quality gates. CAST bootstraps worktrees, seeds teammates with identity + prompts, manages peer messaging.
- **Quality gates are structural, not advisory.** Code changes mandate a reviewer pass. Commits only happen through the commit agent. Raw `git commit` and `git push` are hard-blocked by hooks. Violations trigger build failures.
- **Everything is observable.** Every swarm session, teammate task, peer message, and token spend is logged to `cast.db` (SQLite). Real-time dashboard shows agent force-directed graph, worktree isolation, task satellites.
- **Local models for cost optimization.** Haiku agents route to local Ollama (commit-message model, fast-review model) while Sonnet agents use Claude API. Cost per swarm drops 40-60% when paired with LiteLLM proxy.
- **Teammate peer networking.** Agents send task claims, status updates, and query results to each other via cast.db message bus. No central coordinator—fully decentralized gossip protocol.

---

## Architecture

CAST v5.0 operates as the native Agent Teams companion — Anthropic handles execution parallelism, CAST handles definition, composition, and observability.

```
Agent Teams (Anthropic Native)
    ↓
    └─ CAST Swarm Bootstrap
        ├─ Parse YAML team definition
        ├─ Create worktree per teammate
        ├─ Seed agent identity + quality gates preamble
        └─ Stream events → cast.db
            ├─ swarm_sessions table
            ├─ teammate_runs table (per-agent task tracking)
            └─ teammate_messages table (peer gossip)
```

<p align="center">
  <img src="docs/cast-architecture-v5.svg" alt="CAST v5.0 swarm architecture" />
</p>

### Where CAST extends Agent Teams

| Agent Teams (native) | CAST v5.0 (on top) | Design rationale |
|---|---|---|
| Parallel agent execution | Swarm bootstrap + composition layer | Lift team definition out of code, standardize YAML config |
| No cross-agent messaging | Peer gossip protocol (cast.db message bus) | Agents collaborate without central broker |
| Hook system exists | Production-hardened hooks: TeammateIdle, TaskCreated, TaskCompleted, WorktreeCreate | Real-time swarm lifecycle events |
| Model selection per-session | Per-task routing: Haiku → Ollama (cheap), Sonnet → Claude (smart) | Automatic cost optimization |
| No persistent audit trail | `cast.db` v8: swarm_sessions, teammate_runs, teammate_messages, with temporal indices | Queryable, immutable swarm history |
| No visual observability | Constellation Dashboard: force-directed agent graph + task satellites (React 19 + D3) | Live swarm topology + task flow |
| No agent response schema | Structured Output JSON schemas (`schemas/`) defining status-block, work-log, routing-event contracts | Machine-readable agent response contract for API pipelines |

---

## Quick Start

**Homebrew** (recommended):

```bash
brew tap ek33450505/cast
brew install cast
cast doctor
```

**Claude Code Plugin** (v5.0):

```bash
claude plugin install ek33450505/cast
```

Installs CAST as a Claude Code plugin. Scripts relocate via `CAST_SCRIPTS_DIR` environment variable.

**Git clone** (development):

```bash
git clone https://github.com/ek33450505/claude-agent-team
cd claude-agent-team
bash install.sh
```

`cast doctor` (or `cast-validate.sh`) checks hook wiring, agent files, database schema, CLI path, advanced features (swarm bootstrap, Ollama proxy, channel bus). Green across the board means you're ready.

---

## Personal Overlay — Layered Configuration

CAST ships in **two layers:** a generic `core` layer (29 agents, 11 skills, rules templates) safe for 2000+ clones, and an optional `personal` overlay for maintainer-specific content.

**Default behavior:**
```bash
bash install.sh
```
Installs only the core layer. Your clone is safe, trustworthy, and contains no maintainer-specific paths or projects.

**With personal overlay** (for CAST maintainers or anyone who has populated `rules-personal/`):
```bash
bash install.sh --personal
```
Installs both layers — personal files are merged on top of core into `~/.claude/rules/` and `~/.claude/agents/core/`. Both overlay directories (`rules-personal/`, `agents/personal/`) are tracked in the repo but their contents are only copied into the runtime when `--personal` is passed. `rules-personal/` ships empty for clones to populate themselves; `agents/personal/` holds maintainer-specific agents like `portfolio-sync`.

**What's in each layer:**

| Layer | What It Contains | Shipped? |
|---|---|---|
| `rules-core/` | Generic CAST setup, stack-reference skill, shell/python/typescript conventions | Always |
| `rules-personal/` | Maintainer's project catalog, identity traits, journal settings, custom config.sh | Optional (--personal flag) |
| `agents/core/` | 29 specialist agents (code-writer, debugger, planner, etc.) | Always |
| `agents/personal/` | Maintainer-specific agents (e.g., portfolio-sync) | Optional (--personal flag) |

**Why the split?**

CAST is dogfooded against the maintainer's portfolio and personal projects. A fresh clone must not load that context. The split ensures:
- New users get a trustworthy, generic installation
- Maintainers can overlay personal agents and rules without risk of leaking them to clones
- PRs from contributors target the core layer by default

**Migration for existing clones:**

If you cloned before this split, `rules/` has been renamed to `rules-core/`. Re-run `bash install.sh` to pick up the new structure. If you had custom rules in your runtime `~/.claude/rules/`, back them up before reinstalling — they live in the same runtime directory and the installer may overwrite.

---

## Swarm System

### Define a Team (YAML)

```yaml
# swarm-configs/fullstack-team.yml
team_name: fullstack
description: "Full-stack feature implementation with review loop"

teammates:
  - role: frontend
    agent_def: code-writer
    task: "Implement React component for feature X"
    model: claude-sonnet-4-6
  - role: backend
    agent_def: code-writer
    task: "Implement Express API route and database migration"
    model: claude-sonnet-4-6
  - role: reviewer
    agent_def: code-reviewer
    task: "Review all changes from frontend and backend before merge"
    model: claude-haiku-4-5

quality_gates:
  require_reviewer: true
  commit_agent_only: true
  pre_merge_review: true
  
merge_strategy: squash  # squash | merge | rebase
```

### Bootstrap and Run

```bash
# Spawn the swarm
cast swarm bootstrap swarm-configs/fullstack-team.yml

# Monitor in real time
cast swarm status <swarm_id>

# Merge results when done
cast swarm merge <swarm_id>
```

Under the hood:
1. CAST creates isolated git worktrees per teammate
2. Each teammate gets a Claude Code terminal with agent identity preamble
3. Agent Teams parallelizes execution; CAST emits lifecycle events
4. Peer messages route through cast.db message bus
5. Dashboard displays force-directed graph of all teammates + active tasks

---

## Agent Constellation Dashboard

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) v5.0 introduces **Constellation** — a force-directed graph visualization of your swarm:

| Feature | What It Shows |
|---|---|
| **Agent Force Graph** | 29 core agents + task satellites, gravity physics, live updates |
| **Swarm Sessions** | Active swarms, teammates, task assignments, peer messages |
| **Worktree Isolation** | Per-teammate file ownership, no write conflicts |
| **Token Heatmap** | Per-agent token spend, cost trends, local vs Claude |
| **Hook Audit Trail** | TeammateIdle, TaskCreated, TaskCompleted lifecycle events |
| **Peer Messages** | Task claims, status updates, query results flowing between teammates |

```bash
cd ~/Projects/personal/claude-code-dashboard
npm run dev    # Vite :5173 + Express :3001
# Visit http://localhost:5173/constellation
```

---

## Agent Roster

29 core specialists across 4 categories, with optional personal overlay. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, and isolation.

**New in v5.0:** Agent responses validate against JSON schemas in `schemas/` — status-block contract, work-log entries, and routing events are machine-readable for API pipelines and validation tools.

### Core Agents

| Agent | Model | Effort | Purpose |
|---|---|---|---|
| `code-writer` | sonnet | high | Feature implementation across files or logical units |
| `debugger` | sonnet | high | Root-cause diagnosis and fixes for failures |
| `planner` | sonnet | high | Breaks features into sequenced task plans with ADM |
| `researcher` | sonnet | high | Multi-source analysis, gap reports, data synthesis, source citations |
| `security` | sonnet | high | Auth, input validation, secrets, vulnerability audit |
| `merge` | haiku | low | Git merges, rebases, conflict resolution |
| `test-writer` | haiku | low | Unit and integration tests |
| `devops` | haiku | low | CI/CD, Docker, infrastructure |
| `docs` | haiku | low | Documentation, READMEs, changelogs |
| `morning-briefing` | haiku | low | Daily git activity summary |
| `bash-specialist` | haiku | low | Shell scripts, BATS tests, hook scripts |
| `code-reviewer` | haiku | low | Diff scan for correctness and conventions |
| `test-runner` | haiku | low | Runs test suites (bats, jest, vitest) |
| `commit` | haiku | low | Stages and commits with semantic messages |
| `push` | haiku | low | Pushes to remote with safety checks |
| `frontend-qa` | haiku | low | Frontend diff review, component audit |

### Dev Workflow Agents

| Agent | Model | Effort | Purpose |
|---|---|---|---|
| `migration-reviewer` | sonnet | high | Database schema change safety review, rollback plans |
| `api-contract` | sonnet | high | REST API breaking change detection, OpenAPI-style diffs |
| `adr-writer` | haiku | low | Architecture Decision Record drafting |
| `dep-auditor` | haiku | low | Dependency audit: CVEs, licenses, version compatibility |
| `release-notes` | haiku | low | Structured changelog generation from git history |
| `perf-sentinel` | sonnet | high | Performance regression detection, git bisect suggestions |

### Productivity Agents

| Agent | Model | Effort | Purpose |
|---|---|---|---|
| `task-triage` | haiku | low | Todoist inbox triage, priority assignment, stale task surfacing |
| `standup-writer` | haiku | low | Daily standup generation from git activity and completions |
| `meeting-prep` | haiku | low | Calendar-aware meeting prep briefs via Google Calendar MCP |
| `email-drafter` | haiku | low | Professional email drafting via Gmail MCP (never sends) |
| `pr-narrator` | haiku | low | PR diffs translated to stakeholder-facing summaries |

### Knowledge & Career Agents

| Agent | Model | Effort | Purpose |
|---|---|---|---|
| `knowledge-curator` | haiku | low | Obsidian vault organization, orphan/stale note surfacing |
| `learning-scout` | sonnet | high | Tech topic research and resource curation to Obsidian |
| `portfolio-sync` | haiku | low | Syncs showcase repo READMEs with actual project stats |

**Model tiering:** 20 core agents on Haiku ($1/MTok), 9 on Sonnet ($3/MTok). This 25-40% cost savings scales across the swarm.

**MCP integrations:** Todoist (task-triage), Google Calendar (meeting-prep), Gmail (email-drafter), Obsidian (knowledge-curator, learning-scout).

---

## Token Efficiency & Cost Optimization

CAST v5.0 uses five optimization layers:

| Layer | Impact |
|---|---|
| **Model tiering** | Haiku for reviews/commits (high-frequency), Sonnet for writing/planning | 3x cost reduction on lightweight tasks |
| **Response budgets** | Enforced token limits per agent: 300 (lightweight), 800 (medium), 2,000 (heavy) | Prevents context bloat |
| **Ollama contractor** | Cheap agents route to local codellama/deepseek-coder; fallback to Claude if unavailable | 40-60% cost drop for local tasks |
| **Orchestrator preamble tiers** | Full context for complex agents, minimal for lightweight agents | ~80 tokens saved per dispatch |
| **Output compression** | Responses summarized in <100 words before next batch | Prevents window bloat |

**Net result:** ~30-50% reduction in swarm token spend vs. naive multi-agent dispatch.

---

## Token Optimization (v5.0+)

Beyond cost tiering, CAST v5.0 introduces five new optimization features to reduce token consumption:

| Feature | Usage | Impact |
|---|---|---|
| **Caveman Mode** | `/caveman [lite\|full\|ultra\|off]` | 15-25% output reduction via terse formatting (3 intensity levels) |
| **RTK Hook** | `scripts/cast-rtk-install.sh` | 60-89% compression on tool outputs; optional install |
| **Context Audit** | `scripts/audit-context-size.sh` | Measures always-loaded context; warns if >500 lines (rules slimmed by 95 lines) |
| **Compact Discipline** | Auto-trigger at 40 tool calls/session | Suggests `/compact` via reminder hook + best practices skill |
| **Thinking Budgets** | `config/thinking-budgets.json` | Per-agent extended thinking tiers (0–8192 tokens); prevents wasteful defaults |

**Combined:** These optimizations reduce total session token spend by 20-35% without sacrificing output quality.

---

## Hook Event Coverage

**New in v5.0:** TaskCreated, WorktreeCreate are production-hardened hooks capturing swarm lifecycle. All responses validate against JSON schemas in `schemas/`.

| Event | Hook Script | What It Does |
|---|---|---|
| `SessionStart` | `cast-session-start-hook.sh` | Opens session row in cast.db |
| `TaskCreated` | `cast-task-created-hook.sh` | Logs task assignment; updates teammate_runs table |
| `WorktreeCreate` | `cast-worktree-create-hook.sh` | Creates isolated worktree; seeds agent identity preamble |
| `PreToolUse:Bash` | `pre-tool-guard.sh` | Hard-blocks `git commit` / `git push` (exit 2) |
| `PostToolUse:Write\|Edit` | `post-tool-hook.sh` | Logs file modifications; emits HTTP event to dashboard |
| `PostCompact` | `cast-post-compact-hook.sh` | Reinjects swarm context after compaction |
| `SessionEnd` | `cast-session-end.sh` | Archives session, syncs peer messages, closes cast.db rows |

**Exit code convention:**
- Exit 0 — hook passed, tool call proceeds
- Exit 2 — hook blocked the tool call (guard hooks only)
- Never exit 1 (reserved for fatal hook errors)

---

## Observability & cast.db v8

`cast.db` at `~/.claude/cast.db` — SQLite WAL mode, append-only, never truncated.

**New in v5.0:**

| Table | Purpose |
|---|---|
| `swarm_sessions` | Swarm metadata: team_name, started_at, status, merge_strategy |
| `teammate_runs` | Per-agent task tracking: swarm_id, agent_role, status, token counts |
| `teammate_messages` | Peer gossip: from_agent, to_agent, message_type, JSON payload |

**Existing tables** (v4.6):
| Table | Contents |
|---|---|
| `sessions` | Session start/end, model, token counts |
| `agent_runs` | Every dispatch: agent, model, duration, status, batch_id |
| `routing_events` | Prompt routing records |
| `agent_memories` | Synced from `~/.claude/agent-memory-local/` with temporal validity |
| `stream_events` | Real-time tool events from stream-json pipeline |

```bash
# Query active swarms
sqlite3 ~/.claude/cast.db "SELECT swarm_id, team_name, status, COUNT(*) FROM swarm_sessions \
  JOIN teammate_runs ON swarm_sessions.id = teammate_runs.swarm_id \
  WHERE status='running' GROUP BY swarm_id;"

# Export swarm timeline
sqlite3 ~/.claude/cast.db "SELECT timestamp, from_agent, to_agent, message_type \
  FROM teammate_messages WHERE swarm_id = ? ORDER BY timestamp;"

# Cast health check
cast doctor
```

---

## Peer Messaging & Gossip Protocol

Teammates communicate via cast.db message bus — no central broker, fully decentralized:

```json
{
  "message_type": "task_claim",
  "from_agent": "backend",
  "to_agent": "reviewer",
  "payload": {
    "task_id": "task-123",
    "subject": "Implement POST /users route",
    "status": "complete",
    "files_changed": ["/src/routes/users.ts"]
  }
}
```

Message types:
- **task_claim** — Agent announces it's starting a task
- **status_update** — Agent reports progress or completion
- **peer_query** — Agent asks other teammate for information
- **idle_event** — Agent is waiting for next task

All messages are logged to `teammate_messages` table with timestamps, enabling full swarm replay and debugging.

---

## Ollama Integration & Local Model Fallback

**New in v5.0:** LiteLLM proxy with transparent Ollama fallback.

```bash
# Start LiteLLM proxy (port 8000)
scripts/cast-litellm-start.sh

# Start Ollama with recommended models
ollama pull codellama:7b
ollama pull deepseek-coder:7b
ollama pull nomic-embed-text  # for semantic search

# Route cheap agents to local models
# Model routing in managed-settings.d/25-litellm.json
```

**Routing strategy:**
- `claude-haiku-4-5` (review, commit) → local-commit (codellama) if Ollama available
- `claude-sonnet-4-6` (write, plan) → claude-sonnet-4-6 (Claude API, no fallback)
- **Fallback:** If Ollama unavailable, silently retry via Claude API

`cast.db` tracks `model_used` in `agent_runs` — you can measure how many tokens stayed local vs. went to Claude.

```bash
# Cost breakdown: local vs Claude
sqlite3 ~/.claude/cast.db "SELECT model_used, COUNT(*), SUM(tokens_in + tokens_out) as total_tokens \
  FROM agent_runs WHERE created_at > datetime('now', '-7 days') GROUP BY model_used;"
```

---

## Multi-Agent Pipelines (v4.6+)

The `/orchestrate` skill executes **Agent Dispatch Manifests (ADM)** — JSON structures for sequential/parallel work:

```json
{
  "batches": [
    {
      "id": 1,
      "parallel": true,
      "agents": [
        {
          "subagent_type": "code-writer",
          "owns_files": ["/src/app.ts"],
          "prompt": "Implement authentication module"
        },
        {
          "subagent_type": "test-writer",
          "owns_files": ["/src/app.test.ts"],
          "prompt": "Write unit tests for auth"
        }
      ]
    },
    {
      "id": 2,
      "parallel": false,
      "agents": [
        {
          "subagent_type": "code-reviewer",
          "prompt": "Review changes from batch 1"
        }
      ]
    }
  ]
}
```

`owns_files` prevents write conflicts — `/orchestrate` blocks if two parallel agents claim the same file.

```bash
cast exec ~/.claude/plans/my-plan.md
cast parallel ~/.claude/plans/my-plan.md --split 2
cast parallel ~/.claude/plans/my-plan.md --dry-run
```

**Maintenance Skills:**
- `/cast-audit` — Monthly codebase audit (bugs, security, performance, test coverage) — runs first Monday of each month at 08:00, dispatches 4 parallel researchers, surfaces findings to `~/.claude/reports/cast-audit-YYYY-MM-DD.md`.

---

## Agent Memory & Persistence (v4.3+)

Each agent accumulates domain knowledge across sessions in `~/.claude/agent-memory-local/<name>/`:

```
~/.claude/agent-memory-local/
  code-writer/
    MEMORY.md              ← index (loaded into every session)
    feedback_testing.md    ← user guidance on testing approach
    project_auth.md        ← project-specific context
  debugger/
    MEMORY.md
    ...
```

**v4.3+ features:**
- FTS5 full-text search on memory descriptions
- Relevance scoring: recency + importance + semantic similarity
- Temporal validity: memories superseded but not deleted (history preserved)
- Shared pool: memories with `agent='shared'` visible to all teammates
- Procedural type: operational patterns (e.g., "BATS whitespace fixes")
- Session distiller: extracts decisions into procedural memory at session end

```bash
# Search across all agent memories
python3 scripts/cast-memory-router.py --mode retrieve --agent shared --prompt "how to fix BATS"

# Back up all memories to GitHub release
bash scripts/cast-memory-backup.sh
```

---

## Dashboard

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) v5.0 — React 19 + Vite + Express observability UI.

| Page | What It Shows |
|---|---|
| `/constellation` | Force-directed agent graph + task satellites (NEW v5.0) |
| `/activity` | Live swarm spawn timeline, hook events, peer messages (NEW v5.0) |
| `/sessions` | Session list with swarm affiliation and compaction markers |
| `/analytics` | Token spend by agent + model (Claude vs Ollama), trends |
| `/agents` | Agent roster status, last active, run count per teammate |
| `/hooks` | Hook health: fired/blocked/failed counts per event type |
| `/memory` | Per-agent MEMORY.md viewer + FTS5 search |
| `/token-spend` | Budget burn rate, cost trends, local vs cloud split |
| `/db` | Raw cast.db explorer |

**Start the dashboard:**

```bash
cd ~/Projects/personal/claude-code-dashboard
npm run dev    # Vite :5173 + Express :3001
```

---

## Project Structure

```
claude-agent-team/
  agents/
    core/                        ← 29 core agent definitions
    personal/                    ← optional: maintainer-specific agents
  config/
    cast-litellm.yaml            ← LiteLLM proxy config
    managed-settings.d/          ← modular settings
  rules-core/
    working-conventions.md       ← shared conventions, shell, python, typescript
    stack-reference.md           ← generic stack reference
  rules-personal/                ← .gitignored; created with install.sh --personal
    project-catalog.md           ← maintainer's project list
    engram-identity.md           ← personal traits and context
  docs/
    cast-architecture-v5.svg     ← swarm topology diagram
    swarm-deployment.md          ← production guide
    articles/                    ← feature audit docs (NEW v5.0)
  schemas/                       ← JSON schemas (NEW v5.0)
    status-block.schema.json     ← CAST agent status response contract
    work-log.schema.json         ← Work log entry format
    routing-event.schema.json    ← Event routing format
  scripts/
    cast-swarm-bootstrap.sh      ← team bootstrap (NEW v5.0)
    cast-swarm-*.sh              ← swarm management scripts (NEW v5.0)
    cast-teammate-*.sh           ← teammate hooks (HARDENED v5.0)
    cast-litellm-*.sh            ← LiteLLM proxy control
    cast-*.sh                    ← core hooks + utilities
  swarm-configs/                 ← YAML team definitions
    fullstack-team.yml
    review-team.yml
    research-team.yml
  tests/
    *.bats                       ← core test suite
    hooks/                       ← hook tests
    swarm/                       ← swarm-specific tests (NEW v5.0)
  .github/
    workflows/
      bats-ci.yml                ← BATS CI on push
  VERSION
  CHANGELOG.md
  README.md
```

**Runtime (in `~/.claude/`):**

```
~/.claude/
  agents/                ← live agent definitions
  agent-memory-local/    ← per-agent persistent memory
  plans/                 ← planner output + ADM files
  swarm-sessions/        ← active swarm metadata (NEW v5.0)
  cast.db                ← SQLite observability (v8)
  scripts/               ← installed hook scripts
```

---

## Scheduled Tasks

CAST uses a hybrid scheduling model: **Anthropic RemoteTriggers** for AI-powered tasks with MCP access (run in the cloud, fire even when Claude Code is closed), and **cron** for pure shell maintenance tasks.

### RemoteTriggers (cloud-scheduled)

| Trigger | Schedule (EDT) | Model | MCPs | Output |
|---|---|---|---|---|
| `pa-briefing` | Weekdays 7:27 AM | Sonnet | Calendar + Gmail + Jira | `Briefings/` + `Reports/` (standup) |
| `pa-eod` | Daily 4:53 PM | Haiku | Jira | `Daily Notes/` |
| `pa-weekly` | Friday 3:57 PM | Sonnet | Jira | `Reports/` |

The morning briefing is a mega-trigger that combines weather, calendar, email triage (with draft replies), Jira standup, and sprint overview into one session. It writes both a full briefing and a copy-paste-ready Teams standup.

Local-only sections (git status, cast.db health) gracefully degrade with a note to run `/morning` locally for full data.

### Cron (local shell tasks)

| Schedule | Job | Purpose |
|---|---|---|
| Every 30 min | `cast-ci-monitor.sh` | GitHub Actions failure alerts |
| Daily 3:00 AM | `cast tidy` | Clean old plans, events, logs |
| Daily 3:30 AM | SQLite prune | 90-day data retention on cast.db |
| Daily 3:45 AM | Log compress | gzip event logs older than 7 days |
| Daily 10:47 PM | `pa-backup` | rsync ~/.claude/ + ~/JARVIS/ vault |

```bash
# View scheduled cron jobs
crontab -l

# Manual cleanup
cast tidy            # clean plans, events, logs, db rows older than 14 days
cast tidy --dry-run  # preview what would be removed
```

---

## Test Suite

**409 BATS tests** across 5 directories. 0 failures. Coverage includes:

- Core hook scripts (13 hooks)
- Swarm bootstrap and lifecycle (NEW v5.0)
- Agent team definitions
- Message bus communication (NEW v5.0)
- Database migrations (v7 → v8)
- Guard logic (commit/push blocking)
- Event emission (HTTP SSE, database logging)
- Memory persistence (FTS5, temporal validity)
- Cron setup and cleanup

```bash
bats tests/
bats tests/hooks/
bats tests/swarm/        # NEW v5.0
bats tests/agents/
bats tests/scripts/
```

---

## Version History

| Version | Highlights |
|---|---|
| v1 | Manual dispatch, no hooks, no memory |
| v2 | 42 agents, routing table, regex dispatch |
| v3.0 | 16 agents, model-driven dispatch, 4 hooks, cast.db |
| v3.1 | Async hooks, worktree isolation, per-agent memory |
| v3.3 | Audit hardening: WAL mode, SQL injection fixes, 324 BATS tests |
| v3.4 | Security hardening: path injection fix, frontend-qa agent, portability |
| v4.0 | Hook system rewrite (15 → 13 hooks), CLI slim, drop 5 empty DB tables |
| v4.1 | Native adoption: native statusline cost display, migration to sandbox rules |
| v4.2 | `cast dash` TUI dashboard, `cast tidy` cleanup, CHEATSHEET |
| v4.3 | Memory persistence: FTS5, relevance scoring, shared pool, session distiller, MCP server |
| v4.4 | Temporal validity on agent_memories |
| v4.5 | Token efficiency: model tiering (11 Haiku/6 Sonnet), response budgets, local worktree isolation, Ollama fallback, parallel dual-worktree execution |
| v4.6 | Stream-JSON observability, advanced hooks (HTTP/Prompt/Agent), Channel Event Bus, LiteLLM proxy, plugin packaging |
| v5.0 | **Agent Teams Integration:** swarm bootstrap from YAML, peer gossip protocol, force-directed Constellation dashboard, TeammateIdle/TaskCreated/TaskCompleted hooks, cast.db v8 (swarm_sessions/teammate_runs/teammate_messages), Ollama contractor hardening, production quality gates |

---

## CAST Ecosystem

CAST is distributed across focused repos. The core framework lives here.

| Repo | Description | Distribution |
|---|---|---|
| [claude-agent-team](https://github.com/ek33450505/claude-agent-team) | Core v5.0 framework — agents, swarm bootstrap, hooks, CLI, observability | Homebrew `ek33450505/cast`, Claude plugin |
| [cast-hooks](https://github.com/ek33450505/cast-hooks) | Hook scripts framework — 13 hooks, CLI tool | Homebrew `ek33450505/cast-hooks` |
| [cast-dash](https://github.com/ek33450505/cast-dash) | TUI dashboard — htop for CAST | Homebrew `ek33450505/cast-dash` |
| [cast-memory](https://github.com/ek33450505/cast-memory) | Standalone memory persistence — FTS5, embeddings, MCP | Homebrew `ek33450505/cast-memory` |
| [cast-parallel](https://github.com/ek33450505/cast-parallel) | Parallel plan execution across dual worktrees | Homebrew `ek33450505/cast-parallel` |
| [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) | v5.0 React UI — Constellation graph, swarm activity, analytics | Standalone repo |

**Distribution:** 2 Claude Code plugins, 4 Homebrew taps, 1 React dashboard.

---

## Local-First & Offline

CAST v5.0 maintains v4.5's local-first hardening:

- **macOS Keychain integration** for API key storage
- **age encryption** for agent memory with Secure Enclave binding
- **WAL-safe SQLite backups** with 7-day retention
- **Network detection** with offline queue and auto-replay
- **Ollama local model fallback** for offline tasks
- **Parallel worktree isolation** — no shared state between teammates

All observability stays in `cast.db` on disk — zero cloud lock-in, zero network required for core functionality.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Open an issue first for non-trivial changes. PRs automatically trigger the `cast-pr-review.yml` workflow — the `code-reviewer` agent reviews your diff and posts inline comments.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Author

**Edward Kubiak**  
Full-stack engineer, Claude Code expert, building the future of multi-agent orchestration.

GitHub: [ek33450505](https://github.com/ek33450505)  
CAST Portfolio: [castframework.dev](https://castframework.dev)

---

## Stats

<!-- CAST_AGENT_COUNT -->30<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->501<!-- /CAST_TEST_COUNT --> tests |
<!-- CAST_COMMAND_COUNT -->19<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->16<!-- /CAST_SKILL_COUNT --> skills
