<p align="center">
  <img src="docs/cast-banner.png" alt="CAST — Swarm control plane for Anthropic Agent Teams" />
</p>

# CAST v6.0 — Swarm Control Plane

[![BATS Tests](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml/badge.svg)](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml)
![Version](https://img.shields.io/badge/version-6.0-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-30-green)<!-- CAST_AGENT_COUNT -->
![Tests](https://img.shields.io/badge/tests-55-brightgreen)<!-- CAST_TEST_COUNT -->
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

## Recent Capabilities (v6.0+)

**Anthropic API Integration:**
- **Files API adapter** — `scripts/cast-files-api.sh` wraps the Anthropic Files API with upload/download/delete commands. Opt-in via `CAST_FILES_API=1` environment variable. Test and morning-briefing agents can upload reports as file objects instead of pasting inline.
- **Citations API guidance** — `researcher` and `learning-scout` agents prefer document-grounded completions via the Citations API, with fallback to `[unverified]`-flagged markdown links for sources that cannot be verified.
- **Vision capture step** — `scripts/cast-screenshot.sh` integrates Playwright or Puppeteer for full-page screenshot capture. `frontend-qa` agent visually inspects layouts, color contrast, and rendering before text-only analysis. Graceful degradation when tools unavailable.

**Agent Enhancements:**
- **Per-agent extended thinking budgets** — All 30 agents have fine-grained thinking token allocations: HIGH (8192) for debugger, security, planner, researcher, migration-reviewer, perf-sentinel, api-contract; MEDIUM (4096) for code-writer, test-writer, learning-scout, and others; LOW (0) for fast agents like commit, code-reviewer, merge.
- **Commit agent identity clarification** — Explicit instruction that the commit agent is authorized to run `CAST_COMMIT_AGENT=1 git commit` directly, eliminating recursion confusion.

**Quality & Observability:**
- **Stat-claim verification hook** — `scripts/cast-stat-claim-guard.sh` blocks README.md writes/edits with incorrect test count badges, using `git ls-files` as source of truth. Prevents badge drift during updates.
- **Truncated response detection** — `scripts/cast-response-completeness-hook.sh` logs agent responses missing Status blocks to `~/.claude/logs/hook-errors.log` and `cast.db`, flagging potential context window exhaustion.
- **Parry-guard monitoring** — `scripts/cast-parry-guard-monitor.sh` tracks security gate rejections, identifies possible false positives (≥3 rejections of same tool in 24h), and surfaces anomalies in `morning-briefing` output.
- **Cookbook drift tracking** — `scripts/cast-cookbook-drift.sh` monthly dispatcher audits CAST patterns against Anthropic Cookbook for deprecated APIs and missing features. Reports to `~/.claude/reports/`.
- **Prompt cache metrics** — `scripts/cast-cache-metrics.sh` computes 30-day cache hit rates from cast.db, writing JSON reports and tracking efficiency trends.

**Testing & Deployment:**
- **BATS un-vendored** — BATS framework now installed via package manager (`brew install bats-core` on macOS, `apt-get install bats` on Ubuntu) instead of vendored in repo. Reduces checkout bloat, simplifies CI.

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

30 core specialists. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, isolation, and thinking budget tier. Agent responses validate against JSON schemas in `schemas/`. See [docs/agents/AGENT-ROSTER.md](docs/agents/AGENT-ROSTER.md) for the full table with model tiers and thinking budgets.

Key agents: `code-writer`, `debugger`, `planner`, `researcher`, `security`, `code-reviewer`, `commit`, `push`, `test-writer`, `devops`, `bash-specialist`, `migration-reviewer`, `api-contract`, `dep-auditor`, `perf-sentinel`.

---

## Token Efficiency & Cost Optimization

Model tiering, response budgets, Ollama local routing, laconic mode, and RTK compression achieve ~30-50% token spend reduction. See [docs/TOKEN-OPTIMIZATION.md](docs/TOKEN-OPTIMIZATION.md).

### Optional: Local-first cheap-mode (claude-code-router)

For local Haiku-tier work without API spend, install [claude-code-router](https://github.com/musistudio/claude-code-router) and run `ccr` instead of `claude`. CCR proxies all model calls to local Ollama (default: `deepseek-coder:latest`). Opt-in per session — vanilla `claude` continues to use Anthropic API.

**Install:** `npm install -g @musistudio/claude-code-router`  
**Config:** `~/.claude-code-router/config.json` (CAST-compatible default ships with this repo)  
**Use for:** code-reviewer-only sessions, doc edits, quick exploration  
**Avoid for:** sonnet/opus-tier agents (code-writer, debugger, planner, researcher) — local models cannot match

---

## Hook Event Coverage

Hooks cover the full swarm lifecycle: SessionStart, TaskCreated, WorktreeCreate, PreToolUse:Bash (commit guard), PostToolUse, PostCompact, SessionEnd. See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md#hook-event-coverage).

### Recent Hook Enhancements (Phase A–C, as of 2026-04-26)

**New Hook Events:**
- **StopFailure** (REC-01) — Fires when agent API calls fail mid-task. Logs error details to `cast.db` `stop_failure_events` table; triggers osascript desktop notification with error context.
- **CwdChanged** (REC-06) — Reads `.claude/cast.json` repo metadata and exports `CAST_REPO_CLASS` environment variable (values: `personal`, `work`). Enables repo-aware hooks and agent behavior.
- **SessionStart** — Now reads the latest `~/Documents/Claude/YYYY-MM/*.md` journal entry (if present) and injects a context banner for continuity. Sourced via `cast-claudes_journal` standalone repo.

**Hook Matcher Pattern (REC-02):**
All PreToolUse/PostToolUse hook entries in CAST agent definitions already use the `matcher` field as an equivalent pre-filter to the deprecated `if` field. No migration needed.

**Trail of Bits Security Skills (Phase 7):**
Install security audit skills via `/plugin marketplace add trailofbits/skills`. Integrated with `security` agent for enhanced vulnerability scanning. Requires Claude Code v2.1.118+.

**Managed Agents & Forked Subagents (REC-04):**
Parallel local agent dispatch via `cast-managed-agent.sh --fork` exports `CLAUDE_CODE_FORK_SUBAGENT=1` for worktree-free parallel work. Managed Agents preferred for long-running autonomously-executed tasks.

**Rate Limits API (REC-05):**
`cast-rate-check.py` snapshots `cast.db` `rate_limit_snapshots` table on SessionStart, capturing Anthropic API rate limit headroom. Surfaced in `morning-briefing` output to prevent surprise throttling.

**PreCompact Guard Block (REC-10):**
`/compact` now blocks when the current git repository has staged or unstaged changes. Gracefully passes through outside git worktrees. Prevents accidental context loss mid-work.

**Agent initialPrompt Frontmatter (REC-08):**
`morning-briefing` and `standup-writer` agents auto-load context from agent definition `initialPrompt` field on first turn, reducing cold-start latency and improving continuity.

**Journal Continuity:**
SessionStart hook reads the latest dated journal entry from Claude's Journal (cast-claudes_journal standalone repo) and injects it as a SessionStart banner. Enables context carryover from prior day without explicit carry-forward.

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

55 BATS test files with 520+ individual test assertions across core hooks, swarm bootstrap, message bus, database migrations, guard logic, event emission, and memory persistence. 0 failures. BATS is installed via package manager — `brew install bats-core` (macOS) or `apt-get install bats` (Ubuntu). Run with `bats tests/`.

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

## Deferred Work (Phase A–C Follow-up)

The following capabilities were audited but deferred pending dependency updates or effort assessment:

- **REC-03: MCP Tools from Hooks** — Allow hook scripts to define custom MCP tools (`type: "mcp_tool"` in hook JSON). Currently blocked: installed Claude Code v2.1.116 < required v2.1.118. Re-evaluate after `claude update` and once Anthropic publishes the MCP parameter schema.
- **REC-07: Haiku 3 → 4.5 Migration** — Zero hits found in code paths; Haiku 3 is fully retired as of 2026-04. No migration work needed — Anthropic API defaults to Haiku 4.5.
- **REC-09: Effort Flag Upgrade (xhigh)** — `planner.md` and `debugger.md` agent definitions remain model: sonnet. REC-09 proposes adding `effort: xhigh` to these files, but this requires Opus-tier models. Defer until these agents are promoted to Opus or the `effort` field supports sonnet-tier thresholds.
- **CAST_ALLOW_DIRTY_COMPACT Env Var** — Future UX improvement to allow `/compact` override when git has dirty state. Suggested by `code-reviewer` to reduce friction in iterative sessions. Currently blocks for safety; revisit after gathering user feedback.
- **Journal Session Re-prompt Hardening** — Apr 22–26 entry gap traced to `/tmp/cast_journal_cancelled_*` flag files persisting across sessions. Future work to detect prior-day empty entries and re-prompt on next SessionStart.
- **cast-claudes_journal v0.2.0 Release** — After release tarball is cut, bump `homebrew-claudes-journal` formula sha256 checksum.

---

## Stats

<!-- CAST_AGENT_COUNT -->30<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->572<!-- /CAST_TEST_COUNT --> test files (520+ assertions) |
<!-- CAST_COMMAND_COUNT -->19<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->16<!-- /CAST_SKILL_COUNT --> skills
