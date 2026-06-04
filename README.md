<p align="center">
  <img src="docs/cast-banner.png" alt="CAST — Swarm control plane for Anthropic Agent Teams" />
</p>

# CAST

[![BATS Tests](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml/badge.svg)](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml)
![Version](https://img.shields.io/badge/version-7.3.1-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-23-green)<!-- CAST_AGENT_COUNT -->
![Tests](https://img.shields.io/badge/tests-1154-brightgreen)<!-- CAST_TEST_COUNT -->
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

> CAST is a production control plane for Claude Code built on three pillars: **hook enforcement** (every agent change is gated by validators — `cast-validate-all-hooks.sh` runs in CI and hookSpecificOutput shape is contract-validated), **audit trail** (cast.db with <!-- CAST_DB_TABLE_COUNT -->30<!-- /CAST_DB_TABLE_COUNT --> tables records every session, agent run, routing decision, quality gate, and memory write), and a **typed agent registry** (<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents, model-assigned across haiku 4.5 / sonnet / opus tiers, quality-gated, with frontmatter contracts). Define a workflow once; specialist agents plan, implement, review, test, and commit — automatically.

**[CAST Framework](https://castframework.dev)**

---

## Installation

### Homebrew

```bash
brew tap ek33450505/cast && brew install cast
```

### Manual install

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

---

## Quick Start

**[docs/tutorial/getting-started.md](docs/tutorial/getting-started.md)** — install, verify, and run `cast status` in 5 minutes.

---

## What Makes CAST Different

- **Quality gates that actually enforce.** Raw `git commit` and `git push` are hard-blocked by hooks. Code changes mandate a reviewer pass. You cannot skip this.
- **<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> specialist agents, pre-configured.** Each has a bounded scope, a model tier, and a thinking budget. `code-writer` implements; `code-reviewer` reviews; `commit` commits. They don't cross lanes.
- **SQLite audit trail, fully local.** Every agent dispatch, tool call, and token spend logs to `cast.db` on your machine. No SaaS dashboard, no cloud lock-in.
- **<!-- CAST_TEST_COUNT -->1154<!-- /CAST_TEST_COUNT --> BATS test cases with 0 failures.** Every hook script and utility is covered. CI runs on both macOS and Ubuntu on every push.

---

## Documentation

| Guide | Description |
|---|---|
| [Tutorial](docs/tutorial/getting-started.md) | Install CAST and run your first agent dispatch |
| [Compatibility Matrix](docs/compatibility.md) | Claude Code version requirements and known breakages |
| [Hook Authoring Guide](docs/hooks/authoring-guide.md) | Write, test, and install custom hook scripts |
| [Full Docs Index](docs/README.md) | All documentation with one-line descriptions |

---

<!-- TODO(ed): record 10s asciinema of `cast status` + an orchestrate run, replace this block with the SVG/GIF -->
<p align="center">
  <em>Demo: <code>cast status</code> + orchestrate run — recording in progress</em>
</p>

---

## Table of Contents

[What is CAST?](#what-is-cast) · [Architecture](#architecture) · [Agents](#agents) · [Hooks](#hooks) · [Observability](#observability--castdb) · [Ecosystem](#cast-ecosystem) · [Testing](#testing) · [Contributing](#contributing) · [Stats](#stats)

---

## What is CAST?

CAST transforms Agent Teams into a **production control plane:**

- **Swarm composition in YAML.** Define teams, assign roles, set quality gates. CAST bootstraps worktrees, seeds teammates with identity + prompts, manages peer messaging.
- **Structural quality gates.** Code changes mandate a reviewer pass. Raw `git commit` and `git push` are hard-blocked by hooks.
- **Full observability.** Every session, task, peer message, and token spend logs to `cast.db` (SQLite).
- **Local model routing.** Haiku agents route to Ollama; cost per swarm drops 40-60% with LiteLLM proxy.

---

## Your First Workflow

1. **Plan** — `/plan add user auth feature` → planner writes an Agent Dispatch Manifest.
2. **Execute** — `/orchestrate next` → code-writer implements, code-reviewer checks, test-runner verifies, commit agent stages.
3. **Ship** — `/ship` → tests, CI sanity check, push, journal entry.

---

## Architecture

Every CAST operation follows a four-stage flow: (1) **hook validation** — pre-tool hooks enforce quality gates and block non-compliant writes before any change lands; (2) **agent dispatch** — the typed agent registry routes work to the correct model tier (haiku 4.5 for review/commit, sonnet for implementation, opus for migration review); (3) **memory injection** — each agent receives relevant prior-session context from its `~/.claude/agent-memory-local/<name>/MEMORY.md` on startup; (4) **cast.db audit** — every session, routing decision, quality gate result, and token spend is appended to the local SQLite database. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) for the full guide including Agent Teams comparison table.

<p align="center">
  <img src="docs/architecture/cast-architecture.svg" alt="CAST swarm architecture" />
</p>

---

## Personal Overlay

CAST ships in two layers: `core` (always installed) and `personal` (optional, `--personal` flag). New clones get a trustworthy, generic installation; `rules-personal/` ships empty for clones to populate. See [docs/personal-overlay.md](docs/personal-overlay.md).

## Swarm System

CAST swarms are defined in YAML and bootstrapped with `cast swarm bootstrap`. Teams get isolated worktrees, agent identity, peer messaging, and quality gates. See [docs/swarm.md](docs/swarm.md).

## Agent Constellation Dashboard

**Constellation** — force-directed graph showing agent nodes, task satellites, token heatmaps, peer messages, and hook audit trails in real time. Part of [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard). See [docs/dashboard.md](docs/dashboard.md).

**Cast Desktop** — Tauri 2 native app surfacing the same observability layer with an embedded PTY terminal, command palette, and 11 dashboard views. See [cast-desktop](https://github.com/ek33450505/cast-desktop) (v0.1.0).

---

## Agents

23 core specialists. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, isolation, and thinking budget tier. Agent responses validate against JSON schemas in `schemas/`. See [docs/agents/AGENT-ROSTER.md](docs/agents/AGENT-ROSTER.md) for the full table with model tiers and thinking budgets.

Key agents: `code-writer`, `debugger`, `planner`, `researcher`, `security`, `code-reviewer`, `commit`, `push`, `test-writer`, `devops`, `bash-specialist`, `migration-reviewer`, `api-contract`, `dep-auditor`, `perf-sentinel`.

---

## Token Efficiency & Cost Optimization

Model tiering, response budgets, Ollama local routing, laconic mode, and RTK compression achieve ~30-50% token spend reduction. See [docs/TOKEN-OPTIMIZATION.md](docs/TOKEN-OPTIMIZATION.md).

### Optional: Local-first cheap-mode (claude-code-router)

For local Haiku-tier work without API spend, install [claude-code-router](https://github.com/musistudio/claude-code-router) and run `ccr` instead of `claude`. CCR proxies all model calls to local Ollama (default: `deepseek-coder:latest`). Opt-in per session — vanilla `claude` continues to use Anthropic API.

---

## Hooks

Hooks cover the full swarm lifecycle: SessionStart, TaskCreated, WorktreeCreate, PreToolUse:Bash (commit guard), PostToolUse, PostCompact, SessionEnd. See [docs/hooks/authoring-guide.md](docs/hooks/authoring-guide.md).

## Observability & cast.db

SQLite WAL mode at `~/.claude/cast.db` — append-only, never truncated. Stores swarm_sessions, teammate_runs, agent_runs, routing_events, stream_events. See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md).

## Peer Messaging & Gossip Protocol

Teammates communicate via cast.db message bus — no central broker, fully decentralized. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#peer-messaging--gossip-protocol).

## Multi-Agent Pipelines

The `/orchestrate` skill executes **Agent Dispatch Manifests (ADM)** — JSON plan files defining sequential/parallel agent batches. `owns_files` prevents write conflicts between parallel agents. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#multi-agent-pipelines).

## Agent Memory & Persistence

Each agent accumulates domain knowledge in `~/.claude/agent-memory-local/<name>/MEMORY.md`. Features: FTS5 full-text search, relevance scoring, shared pool, procedural memory, session distiller. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#agent-memory).

## Routines: Scheduled Workflows

11 built-in time-triggered or event-triggered agent jobs — daily briefings, inbox triage, standup, weekly cost reports, and more. Manage with `cast routines list` / `cast routines trigger <name>`. Full guide: [docs/routines.md](docs/routines.md).

---

## Project Structure

`agents/` · `rules-{core,personal}/` · `docs/` · `schemas/` · `scripts/` · `swarm-configs/` · `tests/` · `.github/workflows/`

Runtime installs to `~/.claude/` — agents, memory, plans, swarm sessions, cast.db, scripts.

---

## Testing

153 BATS test files covering core hooks, swarm bootstrap, message bus, database migrations, guard logic, event emission, and memory persistence. 0 failures. BATS is installed via package manager — `brew install bats-core` (macOS) or `apt-get install bats` (Ubuntu). Run with `bats tests/`.

---

## Version History

Full changelog: [CHANGELOG.md](CHANGELOG.md).

---

## CAST Ecosystem

CAST is one of 13 source repositories in a connected ecosystem — each solves a piece of the multi-agent workflow puzzle. All are open-source and actively maintained. See [docs/ecosystem.md](docs/ecosystem.md) for the full repo table and install commands.

<!-- ECOSYSTEM_START -->
| Tier | Repos |
|---|---|
| Core Framework | cast-hooks, cast-agents, cast-memory, cast-observe, cast-security, cast-parallel |
| Tooling | cast-claudes_journal, cast-dash, cast-time, cast-routines, cast-doctor |
| Observability | claude-code-dashboard, cast-desktop |
<!-- ECOSYSTEM_END -->

**New to CAST?** [Quick Start](docs/tutorial/getting-started.md) · [Agent Roster](docs/agents/AGENT-ROSTER.md) · [Architecture](docs/architecture/ARCHITECTURE.md)

**Already using CAST?** [Changelog](CHANGELOG.md) · [Hook Authoring Guide](docs/hooks/authoring-guide.md) · [Full Docs](docs/README.md)

---

## Used In / Built With CAST

- [**claude-code-dashboard**](https://github.com/ek33450505/claude-code-dashboard) — React observability UI; Constellation 3D graph of agents and token spend
- [**cast-desktop**](https://github.com/ek33450505/cast-desktop) — Tauri 2 native app with embedded PTY terminal, command palette, 11 dashboard views
- [**cast-claudes_journal**](https://github.com/ek33450505/cast-claudes_journal) — Session journaling; auto-injects prior-day context via SessionStart hook
- [**cast-dash**](https://github.com/ek33450505/cast-dash) — TUI dashboard for live swarm monitoring
- [**cast-hooks**](https://github.com/ek33450505/cast-hooks) · [**cast-routines**](https://github.com/ek33450505/cast-routines) · [**cast-doctor**](https://github.com/ek33450505/cast-doctor)

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=ek33450505/claude-agent-team&type=Date)](https://star-history.com/#ek33450505/claude-agent-team&Date)

---

## Contributing

Contributions are welcome — CAST is built in the open and actively developed. New agents, shell script fixes, BATS test coverage, and documentation improvements are all fair game.

**Good first issues:** [`good first issue` label](https://github.com/ek33450505/claude-agent-team/issues?q=label%3A%22good+first+issue%22) — curated entry points with clear scope and test expectations.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow. Open an issue first for non-trivial changes.

---

## Support & Portfolio

**Star this repo** if CAST is useful — visibility helps.

Built by [Ed Kubiak](https://github.com/ek33450505) as a showcase of production-grade multi-agent AI tooling. [Portfolio →](https://edkubiak.dev)

---

## License

MIT — see [LICENSE](LICENSE). Built by [Edward Kubiak](https://github.com/ek33450505) — full-stack engineer, Claude Code expert. CAST Portfolio: [castframework.dev](https://castframework.dev)

---

## Stats

<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->1154<!-- /CAST_TEST_COUNT --> test cases |
<!-- CAST_COMMAND_COUNT -->19<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->16<!-- /CAST_SKILL_COUNT --> skills
