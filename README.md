# CAST — Claude Agent Specialist Team

[![BATS Tests](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml/badge.svg)](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml)
![Version](https://img.shields.io/badge/version-4.1-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-17-green)<!-- CAST_AGENT_COUNT -->
![Tests](https://img.shields.io/badge/tests-262-brightgreen)<!-- CAST_TEST_COUNT -->
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

**A multi-agent framework for Claude Code.** 17 specialist agents, hook-enforced quality gates, async observability, and a full SQLite audit trail — all running locally with zero cloud lock-in.

**[Live Demo →](https://cast-site-iota.vercel.app)** | [Dashboard →](https://github.com/ek33450505/claude-code-dashboard)

---

## What is CAST?

CAST turns Claude Code from a single-session assistant into a coordinated team:

- **Every task goes to the right expert.** Code changes dispatch to `code-writer`, failures to `debugger`, scripts to `bash-specialist`. The model reads a 17-row dispatch table and picks the agent — no regex, no routing config.
- **Quality is enforced, not requested.** Raw `git commit` and `git push` are hard-blocked by shell hooks. Every code change mandates a `code-reviewer` pass. Commit only happens through the `commit` agent.
- **Everything is observable.** Every agent dispatch, session, and token spend is logged to `cast.db` (SQLite). A companion React dashboard shows activity, analytics, agent status, and memory in real time.
- **Lightweight tasks use cheaper models automatically.** Haiku handles `code-reviewer`, `commit`, `push`, and `test-runner` — the high-frequency, low-complexity work. Sonnet handles planning, writing, and debugging. The cost difference is 20x per token. CAST routes silently; you pay for what the task actually needs.

---

## Architecture

Claude Code exposes ~40 discrete tools, each with a per-tool permission gate evaluated in `Deny → Ask → Allow` order, and an `AgentTool` that dispatches subagents as flat tool calls with no orchestration layer. Hook events (`PreToolUse`, `PostToolUse`, `SessionStart/Stop`, `SubagentStart/Stop`, `PostCompact`, `TaskCreated`) are first-class extension points. Context compaction runs at three internal tiers. An autonomous daemon mode and a coordinator pattern exist internally but are not yet shipped.

CAST is built to fill the gaps those unshipped features leave, and to make the hook system load-bearing rather than observational.

```
User Prompt
      │
      ▼
┌─────────────────────────────────────────────┐
│  CLAUDE.md dispatch table (17-row routing)  │
│  Model reads table → picks specialist agent │
└──────────────────┬──────────────────────────┘
                   │
      ┌────────────▼────────────┐
      │   PreToolUse hooks      │
      │  • pre-tool-guard.sh    │  ← blocks raw git commit/push
      │  • cast-audit-hook.sh   │  ← logs file modifications
      │  • cast-headless-guard  │  ← auto-answers AskUserQuestion
      └────────────┬────────────┘
                   │
      ┌────────────▼────────────┐
      │  Agent Tool dispatch    │
      │  Specialist agent runs  │
      │  (SubagentStart hook    │  ← emits task_claimed to cast.db
      │   fires on spawn)       │
      └────────────┬────────────┘
                   │
      ┌────────────▼────────────┐
      │   PostToolUse hooks     │
      │  • post-tool-hook.sh    │  ← injects [CAST-REVIEW] after writes
      └────────────┬────────────┘
                   │
      ┌────────────▼────────────┐
      │   Post-chain protocol   │
      │  code change?           │
      │    yes → code-reviewer  │
      │          → commit       │
      │          → push         │
      │    no  → done           │
      └────────────┬────────────┘
                   │
      ┌────────────▼────────────┐
      │   Stop hook             │
      │  cast-session-end.sh    │  ← archival, DB pruning, memory sync
      └────────────┬────────────┘
                   │
      ┌────────────────────────────┐
      │        cast.db             │
      │  sessions  │  agent_runs   │
      │  routing_events            │
      │  agent_memories            │
      └────────────────────────────┘
                   │
      ┌────────────▼────────────┐
      │  claude-code-dashboard  │
      │  React UI on :5173      │
      │  /activity /sessions    │
      │  /analytics /agents     │
      │  /memory /token-spend   │
      └─────────────────────────┘
```

---

### Where CAST extends Claude Code

| Claude Code (native) | CAST (on top) | Design rationale |
|---|---|---|
| `AgentTool` dispatches one subagent per call, no sequencing | Orchestrator executes Agent Dispatch Manifests: parallel batches fire simultaneously, sequential batches gate on prior completion, `owns_files` prevents write conflicts | Fills the gap left by the native coordinator pattern not yet shipping |
| No post-agent successor logic | Chain-maps: `code-writer` → `code-reviewer` → `commit` enforced by `PostToolUse` hook injecting `[CAST-CHAIN]` directive | Makes quality gates structural, not advisory |
| Hook system exists but carries no persistent state | `cast.db` (SQLite, WAL mode): 4 tables — `sessions`, `agent_runs`, `routing_events`, `agent_memories` | Turns ephemeral hook events into a queryable audit trail |
| No native cost display beyond statusline | Native `cost.total_cost_usd` exposed in statusline format; CAST statusline script surfaces it per-session | Claude Code now provides cost natively; CAST presents it |
| `PostCompact` fires but has no default handler | `cast-pre-compact-hook.sh` detects dumb-zone onset; `cast-post-compact-hook.sh` reinjects plan context | Both Pre and PostCompact are covered to prevent plan amnesia |
| `PreToolUse` exit codes 0/2 are the permission gate | `pre-tool-guard.sh` (exit 2 on raw `git commit`/`push`), `cast-audit-hook.sh` (file modification logging) | Security guard behavior migrated to native sandbox `denyRead`/`denyWrite` rules |

### On the native coordinator pattern

Claude Code's internal coordinator pattern specifies one coordinator spawning workers with isolated contexts, a shared scratchpad, a mailbox pattern for dangerous operations, and prompt cache prefix sharing between subagents. CAST's orchestrator covers most of this surface today — ADM batches, parallel dispatch, file ownership to prevent write contention, and checkpoint files for plan resumption across session disconnects. When the native coordinator ships, CAST adapts rather than competes: the ADM format maps onto the coordinator's worker model, hook coverage remains additive, and `cast.db` observability applies regardless of which dispatch path Claude Code uses internally.

---

## Quick Start

Three commands to a working CAST installation:

```bash
brew tap ek33450505/cast
brew install cast
cast doctor
```

`cast doctor` runs `cast-validate.sh` — checks hook wiring, agent files, database schema, and CLI path. Green across the board means you're ready.

**Git clone alternative:**

```bash
git clone https://github.com/ek33450505/claude-agent-team
cd claude-agent-team
bash install.sh
```

---

## Agent Roster

17 specialists. Each is a plain markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, effort, and isolation.

| Agent | Model | Effort | Purpose |
|---|---|---|---|
| `code-writer` | sonnet | high | Feature implementation spanning files or logical units |
| `debugger` | sonnet | high | Root-cause diagnosis and fixes for failures |
| `planner` | sonnet | high | Breaks features into sequenced task plans with ADM |
| `orchestrator` | sonnet | high | Executes multi-agent plan manifests (ADM) |
| `researcher` | sonnet | high | Multi-source analysis, gap reports, data synthesis |
| `security` | sonnet | high | Auth, input validation, secrets, vulnerability audit |
| `merge` | sonnet | high | Git merges, rebases, conflict resolution |
| `test-writer` | sonnet | medium | Unit and integration tests |
| `devops` | sonnet | medium | CI/CD, Docker, infrastructure |
| `docs` | sonnet | medium | Documentation, READMEs, changelogs |
| `morning-briefing` | sonnet | medium | Daily git activity summary |
| `bash-specialist` | sonnet | medium | Shell scripts, BATS tests, hook scripts |
| `code-reviewer` | haiku | low | Diff scan for correctness and conventions |
| `test-runner` | haiku | low | Runs test suites (bats, jest, vitest) |
| `commit` | haiku | low | Stages and commits with semantic messages |
| `push` | haiku | low | Pushes to remote with safety checks |
| `frontend-qa` | haiku | low | Frontend diff review, component audit |

All agents carry `memory: local` — each accumulates session knowledge in `~/.claude/agent-memory-local/<name>/`.

> Haiku agents (`code-reviewer`, `commit`, `push`, `test-runner`) run at ~$0.25/MTok vs Sonnet's ~$3/MTok — a 12x cost difference on high-frequency tasks.

---

## Hook Event Coverage

13 Claude Code lifecycle events are wired. Every event that matters for observability, safety, or pipeline automation is handled.

| Event | Hook Script | What It Does |
|---|---|---|
| `SessionStart` | `cast-session-start-hook.sh` | Opens session row in cast.db |
| `UserPromptSubmit` | `cast-user-prompt-hook.sh` | Logs prompt metadata to routing_events |
| `InstructionsLoaded` | `cast-instructions-loaded-hook.sh` | Logs session context load |
| `PreToolUse:Bash` | `pre-tool-guard.sh` | Hard-blocks `git commit` / `git push` (exit 2) |
| `PreToolUse:AskUserQuestion` | `cast-headless-guard.sh` | Auto-answers AskUserQuestion in pipelines |
| `PreToolUse:Write\|Edit` | `cast-audit-hook.sh` | Logs file modification events |
| `PostToolUse:Write\|Edit\|Agent\|Bash` | `post-tool-hook.sh` | Injects [CAST-REVIEW] directive after code changes |
| `PostToolUseFailure` | `cast-tool-failure-hook.sh` | Logs tool failures to cast.db |
| `PreCompact` | `cast-pre-compact-hook.sh` | Detects dumb-zone onset, emits pre_compact event |
| `PostCompact` | `cast-post-compact-hook.sh` | Reinjects plan context, emits context_compacted |
| `SubagentStart` | `cast-subagent-start-hook.sh` | Emits task_claimed on agent spawn (async) |
| `SubagentStop` | `cast-subagent-stop-hook.sh` | Closes agent_runs row on completion (async) |
| `SessionEnd` | `cast-session-end.sh` | Archives session, closes DB row, syncs memory |

**Exit code convention:**
- Exit 0 — hook passed, tool call proceeds
- Exit 2 — hook blocked the tool call (guard hooks only)
- Never exit 1 (reserved for fatal hook errors)

---

## Observability

`cast.db` at `~/.claude/cast.db` — append-only SQLite. Never truncated.

| Table | Contents |
|---|---|
| `sessions` | Session start/end, model, token counts |
| `agent_runs` | Every dispatch: agent, model, duration, status, batch_id |
| `routing_events` | Prompt routing records, event types, JSON payloads |
| `agent_memories` | Synced from `~/.claude/agent-memory-local/` on Stop |

```bash
# Usage analytics
bash scripts/cast-stats.sh

# Health check
bash scripts/cast-validate.sh   # also available as: cast doctor

# Query recent agent runs
sqlite3 ~/.claude/cast.db "SELECT agent, status, created_at FROM agent_runs ORDER BY id DESC LIMIT 10;"
```

---

## Multi-Agent Pipelines

The `orchestrator` agent executes plans defined by an **Agent Dispatch Manifest (ADM)** — a JSON structure inside plan files. Plans live in `~/.claude/plans/`.

**ADM structure:**

```json
{
  "batches": [
    {
      "id": 1,
      "parallel": true,
      "agents": [
        {
          "subagent_type": "code-writer",
          "owns_files": ["/abs/path/to/file.sh"],
          "prompt": "..."
        },
        {
          "subagent_type": "security",
          "owns_files": ["/abs/path/to/other.sh"],
          "prompt": "..."
        }
      ]
    },
    {
      "id": 2,
      "parallel": false,
      "agents": [{ "subagent_type": "commit", "prompt": "..." }]
    }
  ]
}
```

`owns_files` prevents two parallel agents from writing the same file. The orchestrator detects conflicts before dispatch and blocks the batch if any overlap exists.

```bash
# Run a plan
cast exec ~/.claude/plans/my-plan.md

# Or dispatch the orchestrator agent directly:
# "Orchestrate the plan at ~/.claude/plans/my-plan.md"
```

---

## Agent Memory

Each agent has a persistent markdown-based memory directory. Agents accumulate domain knowledge across sessions.

```
~/.claude/agent-memory-local/
  code-writer/
    MEMORY.md              ← index (loaded into every session)
    feedback_testing.md    ← user guidance on testing approach
    project_auth.md        ← project-specific auth context
  debugger/
    MEMORY.md
    ...
```

Memory files are plain markdown with YAML frontmatter. `cast-session-end.sh` syncs them to `agent_memories` in cast.db on every Stop. The markdown files are the source of truth.

```bash
# Back up all agent memory to a GitHub release
bash scripts/cast-memory-backup.sh --dry-run   # preview only
bash scripts/cast-memory-backup.sh             # creates tarball + gh release
```

---

## Dashboard

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — React 19 + Vite + Express observability UI for CAST.

Reads `cast/events/`, `agent-status/`, and `cast.db` directly — no backend API required for reads.

| Page | What It Shows |
|---|---|
| `/activity` | Live agent spawn timeline, hook events |
| `/sessions` | Session list with compaction markers |
| `/analytics` | Token spend by agent, prompt volume over time |
| `/agents` | Agent roster status, last active, run count |
| `/hooks` | Hook health: fired/blocked/failed counts |
| `/plans` | Plan files, ADM batch status |
| `/memory` | Per-agent MEMORY.md viewer, last-modified |
| `/token-spend` | Budget burn rate, cost trends |
| `/db` | Raw cast.db explorer |

```bash
cd ~/Projects/personal/claude-code-dashboard
npm run dev    # Vite :5173 + Express :3001
```

---

## Project Structure

```
claude-agent-team/
  agents/
    core/               ← 17 agent definitions (mirrored to ~/.claude/agents/)
  docs/                 ← architecture specs, native-tools-reference.md, protocol docs
  scripts/              ← hook scripts, utilities, cron setup
  tests/
    *.bats              ← core test suite
    hooks/              ← hook-specific BATS tests
    agents/             ← agent frontmatter BATS tests
    scripts/            ← script utility BATS tests
  .github/
    workflows/
      bats-ci.yml       ← BATS CI on push + daily schedule
      cast-pr-review.yml← Automated PR review via claude-code-action
  .mcp.json             ← Project-scoped MCP server config
  install.sh
  VERSION
  CHANGELOG.md
```

**Runtime (outside repo, in `~/.claude/`):**

```
~/.claude/
  agents/               ← live agent definitions (copied from agents/core/)
  agent-memory-local/   ← per-agent persistent memory
  plans/                ← planner output + ADM plan files
  settings.json         ← Claude Code config with all hooks registered
  cast.db               ← SQLite observability database
  cast/events/          ← append-only event log (one JSON per session)
  scripts/              ← installed hook scripts
  logs/                 ← pipeline, headless-stalls, memory-backup logs
```

---

## Scheduled Tasks

Pure cron. No daemon. No background process.

| Schedule | Script | Purpose |
|---|---|---|
| Daily 7am | morning-briefing agent | Git activity summary across all repos |
| Daily 6pm | cast-stats.sh | Daily usage summary |
| Monday 9am | cast-stats.sh --weekly | Weekly cost report |
| Daily 2am | cast-memory-backup.sh | Backup agent memory to GitHub release |

```bash
bash scripts/cast-cron-setup.sh          # install
bash scripts/cast-cron-setup.sh --list   # view
bash scripts/cast-cron-setup.sh --remove # uninstall
```

---

## Test Suite

324 BATS tests across 4 directories. 0 failures.

```bash
# Run all tests
bats tests/

# Run a specific category
bats tests/hooks/
bats tests/agents/
bats tests/scripts/
```

Tests cover: hook scripts, guard logic, event emission, stats generation, DB init, cron setup, agent-status reader, effort frontmatter, headless guard, and memory backup.

---

## Version History

| Version | Highlights |
|---|---|
| v1 | Manual dispatch, no hooks, no memory |
| v2 | 42 agents, routing table, regex dispatch, castd daemon |
| v3.0 | 16 agents, model-driven dispatch, 4 hooks, cron, cast.db |
| v3.1 | Async hooks, worktree isolation, per-agent memory, headless pipelines, GitHub CI |
| v3.3 | Audit hardening: WAL mode, structured error logging, SQL injection fix, PII advisory mode, orchestrator resilience (checkpoints, policy gate, TRUNCATED classification), 4 scripts committed to repo |
| v3.4 | Security hardening: Python injection fix, path injection fix, --model flag on CLI; portability: __HOME__ tokens replace hardcoded paths; settings cleanup; daemon cleanup (flock lockfile); frontend-qa agent added; docs/native-tools-reference.md; 324 BATS tests |
| v4.0 | Major cleanup: gut 33 hooks to 15, slim CLI from 2331→976 lines, installer 351→193 lines; drop 5 empty DB tables (9→4 canonical); delete observe-* shadow system, daemon, routing scripts; rebuild cast.db at v7 with batch_id; 271 BATS tests |
| v4.1 | Native adoption: replace cost-tracker with native statusline, remove prettier hook, delete 4 dead routing scripts, migrate security guard to sandbox rules, add PreCompact hook, add effort/background/initialPrompt to agent frontmatter; 262 BATS tests |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Open an issue first for non-trivial changes. PRs automatically trigger the `cast-pr-review.yml` workflow — the `code-reviewer` agent reviews your diff and posts inline comments.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Stats

<!-- CAST_AGENT_COUNT -->17<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->307<!-- /CAST_TEST_COUNT --> tests |
<!-- CAST_COMMAND_COUNT -->18<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->8<!-- /CAST_SKILL_COUNT --> skills
