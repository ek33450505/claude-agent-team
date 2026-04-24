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

**CAST is the control plane for Anthropic's native Agent Teams.** Define multiagent swarms in YAML, let the framework handle orchestration, quality gates, and observability.

**[CAST Framework](https://castframework.dev)**

## Table of Contents

- [What is CAST?](#what-is-cast)
- [Quick Start](#quick-start)
- [Your First Workflow](#your-first-workflow)
- [Architecture](#architecture)
- [Personal Overlay — Layered Configuration](#personal-overlay--layered-configuration)
- [Swarm System](#swarm-system)
- [Agent Constellation Dashboard](#agent-constellation-dashboard)
- [Agent Roster](#agent-roster)
- [Token Efficiency & Cost Optimization](#token-efficiency--cost-optimization)
- [Hook Event Coverage](#hook-event-coverage)
- [Observability & cast.db v8](#observability--castdb-v8)
- [Peer Messaging & Gossip Protocol](#peer-messaging--gossip-protocol)
- [Multi-Agent Pipelines (v4.6+)](#multi-agent-pipelines-v46)
- [Agent Memory & Persistence (v4.3+)](#agent-memory--persistence-v43)
- [Project Structure](#project-structure)
- [Scheduled Tasks](#scheduled-tasks)
- [Test Suite](#test-suite)
- [Version History](#version-history)
- [CAST Ecosystem](#cast-ecosystem)
- [Local-First & Offline](#local-first--offline)
- [Contributing](#contributing)
- [License](#license)
- [Author](#author)
- [Stats](#stats)

---

## What is CAST?

CAST transforms Agent Teams into a **production control plane:**

- **Swarm composition in YAML.** Define teams, assign roles, set quality gates. CAST bootstraps worktrees, seeds teammates with identity + prompts, manages peer messaging.
- **Structural quality gates.** Code changes mandate a reviewer pass. Raw `git commit` and `git push` are hard-blocked by hooks.
- **Full observability.** Every session, task, peer message, and token spend logs to `cast.db` (SQLite).
- **Local model routing.** Haiku agents route to Ollama; cost per swarm drops 40-60% with LiteLLM proxy.

---

## Quick Start

```bash
brew tap ek33450505/cast && brew install cast && cast doctor
```

Or: `claude plugin install ek33450505/cast` — or clone + `bash install.sh`.

---

## Your First Workflow

1. **Plan** — `/plan add user auth feature` → planner writes an Agent Dispatch Manifest.
2. **Execute** — `/orchestrate next` → code-writer implements, code-reviewer checks, test-runner verifies, commit agent stages.
3. **Ship** — `/ship` → tests, CI sanity check, push, journal entry.

---

## Architecture

CAST operates alongside Anthropic Agent Teams: Anthropic handles execution parallelism, CAST handles definition, composition, and observability. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) for the full guide including Agent Teams comparison table.

<p align="center">
  <img src="docs/architecture/cast-architecture.svg" alt="CAST swarm architecture" />
</p>

---

## Personal Overlay — Layered Configuration

CAST ships in two layers: `core` (always installed) and `personal` (optional, `--personal` flag).

| Layer | Contents | Installed |
|---|---|---|
| `rules-core/` | Generic conventions (shell, python, typescript) | Always |
| `agents/core/` | Specialist agents (code-writer, debugger, planner, …) | Always |
| `rules-personal/` | Maintainer project catalog, identity traits | `--personal` |
| `agents/personal/` | Maintainer-specific agents (e.g., portfolio-sync) | `--personal` |

New clones get a trustworthy, generic installation. `rules-personal/` ships empty for clones to populate.

---

## Swarm System

CAST swarms are defined in YAML and bootstrapped with `cast swarm bootstrap`. Teams get isolated worktrees, agent identity, peer messaging, and quality gates. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#swarm-system).

---

## Agent Constellation Dashboard

**Constellation** — force-directed graph showing agent nodes, task satellites, token heatmaps, peer messages, and hook audit trails in real time. Part of [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard). See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md#agent-constellation-dashboard).

---

## Agent Roster

30 core specialists. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, and isolation. Agent responses validate against JSON schemas in `schemas/`. See [docs/agents/AGENT-ROSTER.md](docs/agents/AGENT-ROSTER.md) for the full table with model tiers.

Key agents: `code-writer`, `debugger`, `planner`, `researcher`, `security`, `code-reviewer`, `commit`, `push`, `test-writer`, `devops`, `bash-specialist`, `migration-reviewer`, `api-contract`, `dep-auditor`, `perf-sentinel`.

---

## Token Efficiency & Cost Optimization

Model tiering, response budgets, Ollama local routing, laconic mode, and RTK compression achieve ~30-50% token spend reduction. See [docs/TOKEN-OPTIMIZATION.md](docs/TOKEN-OPTIMIZATION.md).

---

## Hook Event Coverage

Hooks cover the full swarm lifecycle: SessionStart, TaskCreated, WorktreeCreate, PreToolUse:Bash (commit guard), PostToolUse, PostCompact, SessionEnd. See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md#hook-event-coverage).

---

## Observability & cast.db v8

SQLite WAL mode at `~/.claude/cast.db` — append-only, never truncated. Stores swarm_sessions, teammate_runs, teammate_messages, agent_runs, routing_events, stream_events. See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md#observability--castdb-v8).

---

## Peer Messaging & Gossip Protocol

Teammates communicate via cast.db message bus — no central broker, fully decentralized. Types: task_claim, status_update, peer_query, idle_event. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#peer-messaging--gossip-protocol).

---

## Multi-Agent Pipelines (v4.6+)

The `/orchestrate` skill executes **Agent Dispatch Manifests (ADM)** — JSON plan files defining sequential/parallel agent batches. `owns_files` prevents write conflicts between parallel agents. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#multi-agent-pipelines) for the full ADM format.

```bash
cast exec ~/.claude/plans/my-plan.md
cast parallel ~/.claude/plans/my-plan.md --dry-run
```

---

## Agent Memory & Persistence (v4.3+)

Each agent accumulates domain knowledge in `~/.claude/agent-memory-local/<name>/MEMORY.md`. Features: FTS5 full-text search, relevance scoring, temporal validity (history preserved), shared pool (`agent='shared'`), procedural memory, session distiller. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md#agent-memory).

---

## Project Structure

```
claude-agent-team/
  agents/{core,personal}/   ← agent definitions
  config/                   ← LiteLLM proxy, managed-settings.d/
  rules-{core,personal}/    ← conventions and overlays
  docs/                     ← architecture docs, diagrams
  schemas/                  ← JSON schemas (status-block, work-log, routing-event)
  scripts/                  ← hook scripts, swarm bootstrap, utilities
  swarm-configs/            ← YAML team definitions
  tests/                    ← BATS suite (core, hooks, swarm, agents, scripts)
  .github/workflows/        ← bats-ci.yml
```

Runtime installs to `~/.claude/` — agents, memory, plans, swarm sessions, cast.db, scripts.

---

## Scheduled Tasks

Hybrid model: **RemoteTriggers** for AI-powered tasks (briefings, standups, reports); **cron** for local shell maintenance (CI monitoring, log cleanup, cast.db pruning). `cast tidy` cleans items older than 14 days.

---

## Test Suite

<!-- CAST_TEST_COUNT -->514<!-- /CAST_TEST_COUNT --> BATS tests across 5 directories. 0 failures. Coverage: core hooks, swarm bootstrap, message bus, database migrations, guard logic, event emission, memory persistence. Run with `bats tests/`.

---

## Version History

See [CHANGELOG.md](CHANGELOG.md).

---

## CAST Ecosystem

| Repo | Description | Distribution |
|---|---|---|
| [claude-agent-team](https://github.com/ek33450505/claude-agent-team) | Core framework | Homebrew `ek33450505/cast`, Claude plugin |
| [cast-hooks](https://github.com/ek33450505/cast-hooks) | Hook scripts — 13 hooks | Homebrew `ek33450505/cast-hooks` |
| [cast-dash](https://github.com/ek33450505/cast-dash) | TUI dashboard | Homebrew `ek33450505/cast-dash` |
| [cast-memory](https://github.com/ek33450505/cast-memory) | Standalone memory persistence | Homebrew `ek33450505/cast-memory` |
| [cast-parallel](https://github.com/ek33450505/cast-parallel) | Parallel plan execution | Homebrew `ek33450505/cast-parallel` |
| [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) | React UI — Constellation graph | Standalone repo |

---

## Local-First & Offline

macOS Keychain, age encryption (Secure Enclave), WAL-safe SQLite backups, offline queue with auto-replay, Ollama fallback. All observability stays in `cast.db` on disk — zero cloud lock-in.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Open an issue first for non-trivial changes. PRs trigger `cast-pr-review.yml` — `code-reviewer` agent reviews your diff.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Author

**Edward Kubiak** — Full-stack engineer, Claude Code expert.  
GitHub: [ek33450505](https://github.com/ek33450505) | CAST Portfolio: [castframework.dev](https://castframework.dev)

---

## Stats

<!-- CAST_AGENT_COUNT -->30<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->514<!-- /CAST_TEST_COUNT --> tests |
<!-- CAST_COMMAND_COUNT -->19<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->16<!-- /CAST_SKILL_COUNT --> skills
