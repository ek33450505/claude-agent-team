# CAST — Claude Agent Specialist Team

![Version](https://img.shields.io/badge/version-3.0-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-<!-- CAST_AGENT_COUNT -->15<!-- /CAST_AGENT_COUNT -->-green)
![Tests](https://img.shields.io/badge/tests-<!-- CAST_TEST_COUNT -->216<!-- /CAST_TEST_COUNT -->%20total-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

A local-first agent infrastructure layer built on Claude Code. 15 specialist agents, model-driven dispatch, mandatory code review, and hard-blocked git operations — all enforced by 4 shell hooks. Zero cloud lock-in. Everything lives in `~/.claude/`.

---

## Quick Start

```bash
git clone https://github.com/ek33450505/claude-agent-team
cd claude-agent-team
bash install.sh
```

`install.sh` copies agents to `~/.claude/agents/`, installs hooks into `~/.claude/settings.json`, initializes `cast.db`, and optionally sets up cron tasks.

---

## Architecture

```
User prompt
     |
     v
[CLAUDE.md dispatch table]   <-- model reads 15 rows, picks agent
     |
     v
[PreToolUse hook]            <-- pre-tool-guard.sh: blocks raw git commit/push
     |
     v
[Agent tool dispatch]        <-- specialist agent runs
     |
     v
[PostToolUse hook]           <-- post-tool-hook.sh: injects [CAST-REVIEW] after writes
     |                        -- cast-cost-tracker.sh: logs dispatch to cast.db
     v
[Code change?]
   yes --> code-reviewer --> commit --> push
    no --> done
     |
     v
[Stop hook]                  <-- cast-session-end.sh: archival, pruning, memory sync
     |
     v
[cast.db]                    <-- SQLite: sessions, agent_runs, budgets, agent_memories
```

---

## The 15 Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| code-writer | sonnet | Feature work spanning >1 file or >5 lines |
| code-reviewer | haiku | Reviews diffs for correctness and conventions |
| debugger | sonnet | Diagnoses and fixes failures |
| planner | sonnet | Breaks features into sequenced task plans |
| security | sonnet | Auth, input handling, API keys, vulnerabilities |
| merge | sonnet | Git merges, rebases, conflict resolution |
| researcher | sonnet | Codebase exploration, web research, data analysis |
| docs | sonnet | Documentation, READMEs, reports |
| bash-specialist | sonnet | Shell scripts, BATS tests, hook scripts |
| orchestrator | sonnet | Executes multi-agent plan manifests |
| morning-briefing | sonnet | Daily briefing from git activity |
| devops | sonnet | CI/CD, Docker, infrastructure |
| commit | haiku | Stages and commits with semantic messages |
| push | haiku | Pushes to remote with safety checks |
| test-runner | haiku | Runs test suites (jest, vitest, bats) |

Agent definitions live in `~/.claude/agents/` as plain markdown files.

---

## How Dispatch Works

CAST v3 has no routing table. No regex. No `route.sh`.

`CLAUDE.md` contains a 15-row dispatch table. When a prompt arrives, the model reads it and decides which agent to call via the Agent tool. This follows Anthropic's "Building Effective Agents" principle: let the model decide.

**CLAUDE.md structure (47 lines):**
- Core Rules (6 rules)
- Dispatch Table (15 rows mapping situation to agent)
- Post-Chain protocol (what runs after each agent)
- Agent Models (sonnet vs haiku split)
- Config paths

**Example dispatch rules in the table:**
- Feature work spanning >1 file → `code-writer`
- Any test failure or bug → `debugger`
- Auth, input validation, API key handling → `security`
- Git merges or conflict resolution → `merge`
- Shell scripts or BATS tests → `bash-specialist`

The model is the router. It reads the table at inference time and dispatches accordingly.

---

## Hook Architecture

4 hooks enforce CAST conventions at the Claude Code process boundary. Hooks fire before or after every tool call — they cannot be bypassed by agents.

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| Bash guard | PreToolUse:Bash | pre-tool-guard.sh | Hard-blocks raw `git commit` and `git push` |
| Code chain | PostToolUse:Write\|Edit | post-tool-hook.sh | Injects `[CAST-REVIEW]` after code changes |
| Cost tracker | PostToolUse:Agent | cast-cost-tracker.sh | Logs every agent dispatch to cast.db |
| Session end | Stop | cast-session-end.sh | Archival, DB pruning, memory sync, temp cleanup |

**Exit code convention:**
- Exit 0 — hook passed, tool call proceeds normally
- Exit 2 — hook blocked the tool call (bash guard uses this to stop raw commits)

**Bash guard escape hatches:**
- `CAST_COMMIT_AGENT=1` — allows a single git commit through (used by the commit agent internally)
- `CAST_PUSH_OK=1` — allows a single git push through (used by the push agent internally)

These are set by the commit and push agents as environment flags before their git calls. They are not for general use.

---

## Post-Chain Protocol

After code changes, agents follow a mandatory post-chain. The model reads the post-chain protocol from `CLAUDE.md` and dispatches accordingly.

**Standard chain (after code-writer or debugger):**
```
code-reviewer --> commit --> push
```

**Security-sensitive chain (parallel review):**
```
[code-reviewer, security] (parallel) --> commit --> push
```

Parallel agents in a nested array dispatch simultaneously — neither influences the other before reporting. Both must return DONE before commit proceeds.

The inline session acts as fallback enforcer: if an agent returns without having dispatched its mandatory chain, the session immediately dispatches the missing agent.

---

## Observability

**cast.db** — SQLite database at `~/.claude/cast.db`

| Table | Contents |
|-------|----------|
| sessions | Session start/end, model, token counts |
| agent_runs | Every agent dispatch: agent name, model, duration, status |
| budgets | Per-session and per-agent token budgets |
| agent_memories | Synced from `~/.claude/agent-memory-local/` on session close |

**Key scripts:**
- `cast-cost-tracker.sh` — writes a row to agent_runs on every Agent tool PostToolUse event
- `cast-validate.sh` — system health check (also available as `/doctor` slash command)
- `cast-stats.sh` — usage analytics: top agents, average durations, cost trends
- `cast/events/` — append-only event log (one JSON file per session)

**Running stats:**
```bash
bash scripts/cast-stats.sh
bash scripts/cast-validate.sh
```

---

## Scheduled Tasks

`cast-cron-setup.sh` installs 3 cron entries. No daemon. No background process. Pure cron.

| Schedule | Script | Purpose |
|----------|--------|---------|
| Daily 7am | morning-briefing agent | Git activity summary across all repos |
| Daily 6pm | cast-stats.sh | Daily usage summary |
| Monday 9am | cast-stats.sh --weekly | Weekly cost report |

```bash
# Install cron tasks
bash scripts/cast-cron-setup.sh

# List installed tasks
bash scripts/cast-cron-setup.sh --list

# Remove cron tasks
bash scripts/cast-cron-setup.sh --remove
```

---

## Memory System

Each agent has its own persistent markdown-based memory directory.

**Location:** `~/.claude/agent-memory-local/<agent>/`

**Structure:**
```
~/.claude/agent-memory-local/
  code-writer/
    MEMORY.md          <-- index file loaded into every session
    feedback_*.md      <-- guidance the user gave this agent
    project_*.md       <-- project context relevant to this agent
    user_*.md          <-- user profile for this agent
  code-reviewer/
    MEMORY.md
    ...
```

**Persistence:** `cast-session-end.sh` syncs memory files to the `agent_memories` table in `cast.db` on every session close. The markdown files are the source of truth — cast.db is the backup.

**Why plain files:** Read them, edit them, back them up, version control them. No proprietary format. A memory is just a `.md` file with frontmatter.

---

## Scripts Reference

All scripts live in `scripts/`.

| Script | Purpose |
|--------|---------|
| pre-tool-guard.sh | PreToolUse bash guard (installed as hook) |
| post-tool-hook.sh | PostToolUse code chain injector (installed as hook) |
| cast-cost-tracker.sh | Agent dispatch logger (installed as hook) |
| cast-session-end.sh | Consolidated Stop hook |
| cast-cron-setup.sh | Cron installer for scheduled tasks |
| cast-validate.sh | System health checks |
| cast-stats.sh | Usage analytics |
| cast-exec.sh | Standalone plan executor |
| cast-events.sh | Event emission helpers |
| cast-db-init.sh | Initialize cast.db schema |
| agent-status-reader.sh | Reads agent status JSON files |
| gen-stats.sh | Auto-generates stats for README badges |
| install.sh | Full CAST installation |

---

## Test Suite

224 BATS tests across 15 files. 0 failures.

```bash
# Run all tests
bats tests/

# Run a single test file
bats tests/pre-tool-guard.bats
```

Tests cover: hook scripts, guard logic, event emission, stats generation, DB init, cron setup, and agent-status reader.

---

## Project Structure

```
claude-agent-team/
  agents/
    core/               <-- agent definitions (mirrored to ~/.claude/agents/)
  scripts/              <-- all hook and utility scripts
  tests/                <-- BATS test suite
  config/               <-- CLAUDE.md and any static config
  cast/                 <-- runtime: events/, logs/
  install.sh
  VERSION
  README.md
```

**Runtime directories (outside repo, in ~/.claude/):**
```
~/.claude/
  agents/               <-- live agent definitions (copied from agents/core/)
  agent-memory-local/   <-- per-agent persistent memory
  plans/                <-- planner output files
  settings.json         <-- Claude Code config with hooks registered
  cast.db               <-- SQLite observability database
```

---

## Companion Dashboard

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) — React observability UI for CAST. Reads `cast/events/`, `agent-status/`, and `cast.db`. No backend — filesystem scan and SQLite only.

Dashboard pages: `/activity`, `/sessions`, `/analytics`, `/agents`, `/hooks`, `/plans`, `/memory`, `/system`, `/token-spend`, `/db`

---

## Privacy

Everything is local. No data leaves your machine.

- Agents run via Claude Code's Agent tool (local process)
- cast.db is `~/.claude/cast.db` — your filesystem
- Memory files are `~/.claude/agent-memory-local/` — plain markdown
- No telemetry, no cloud sync, no external API calls beyond Anthropic's API (which Claude Code already uses)

---

## Known Limitations

- **Agent tool depth** — nesting depth >= 3 may suppress self-dispatch chains. The inline session acts as fallback enforcer for broken chains.
- **Turn ceiling** — orchestrator stops cleanly at turn 40 (of 50) and checkpoints for manual resume. No automatic continuation.
- **SendMessage gap** — orchestrator cannot auto-resume after a network drop. Workaround: checkpoint log + re-invocation.
- **CAST-DEBUG hook** — the auto-injection path in `post-tool-hook.sh` is broken (heredoc stdin conflict). The `[CAST-DEBUG]` directive in `CLAUDE.md` works as a manual instruction; only auto-injection is broken.

---

## Version History

| Version | Highlights |
|---------|------------|
| v1 | Manual dispatch, no hooks, no memory system |
| v2 | 42 agents, routing table (`routing-table.json`), regex-based dispatch, `castd` daemon |
| v3 | 15 agents, model-driven dispatch (no routing table), 4 hooks, cron replaces daemon, plain-file memory, cast.db observability |

**v3 changes from v2:**
- Agent count: 42 → 15 (consolidated by domain)
- Routing table: removed entirely — model decides
- Daemon (`castd`): removed — replaced by cron
- Dispatch mechanism: regex matching → CLAUDE.md table lookup
- New agents: orchestrator, morning-briefing, devops, docs, researcher, test-runner
- Removed agents: ~27 single-purpose agents folded into the 15 specialists

---

## Stats

<!-- CAST_AGENT_COUNT -->15<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->216<!-- /CAST_TEST_COUNT --> tests |
<!-- CAST_COMMAND_COUNT -->16<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->7<!-- /CAST_SKILL_COUNT --> skills

---

MIT License
