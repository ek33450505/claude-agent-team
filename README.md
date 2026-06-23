<p align="center">
  <img src="docs/cast-banner.png" alt="CAST — a local-first, data-integrity control plane for Claude Code" />
</p>

# CAST

[![BATS Tests](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml/badge.svg)](https://github.com/ek33450505/claude-agent-team/actions/workflows/bats-ci.yml)
![Version](https://img.shields.io/badge/version-8.0.0-blue)<!-- /CAST_VERSION_BADGE -->
![Agents](https://img.shields.io/badge/agents-23-green)<!-- CAST_AGENT_COUNT -->
![Tests](https://img.shields.io/badge/tests-1807-brightgreen)<!-- CAST_TEST_COUNT -->
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)
![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-blueviolet)

> **CAST v8 — "Native CAST."** A production-grade control plane for Claude Code, built on two convictions: the core development loop should never have to leave your machine, and an agent platform should be structurally unable to destroy its own evidence. Those are the two pillars — **local-first by construction** and **data integrity by construction** — and they are enforced by hooks, guards, and a local SQLite audit trail (<!-- CAST_DB_TABLE_COUNT -->36<!-- /CAST_DB_TABLE_COUNT -->+ tables), not by convention. <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> specialist agents plan, implement, review, test, and commit; raw `git commit` and `git push` are hard-blocked; every dispatch is logged. Define a workflow once; the team runs it.

**[CAST Framework](https://castframework.dev)**

CAST is the system I'd want if I were building production software with Claude Code every day — so I built it, broke it, and hardened it until it earned trust. The hard part wasn't wiring agents together; it was making the platform **honest** (it tells you when work is unverified) and **safe** (it cannot delete its own runtime). Pillar 2 wasn't designed on a whiteboard — it was earned through repeated full `~/.claude` wipes, including one that took out the colocated backups with it. The engineering response *is* the story: backups moved outside the failure domain (continuous Litestream replication + dated snapshots to `~/Library`), the wipe canary relocated off the blast radius so forensics survive the event that triggers them, and a PreToolUse command-guard plus write-guards that make `rm -rf ~/.claude` or a machine-wide `pkill` structurally impossible from an agent. The destructive paths are tested by **proving the system refuses them**, not by proving the happy path works.

Where Claude Code now ships a native primitive, v8 **retires** CAST's bespoke version (language rules became on-demand skills; heavy planning yields to native plan mode for single-session work; the whole thing ships as a **native plugin**). Where the platform still has a gap, CAST fills it and is, in places, ahead of Anthropic's own published guidance: a fresh-context `code-reviewer` gate (the Writer/Reviewer pattern, mandatory here), an honesty/verification doctrine (`DONE_WITH_CONCERNS`, a typed Handoff contract, a Pre-existing-Failure-Evidence rule), and an **eval harness mined from real agent failures** — closing what is arguably Anthropic's largest documented gap.

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

### Install as a plugin (v8)

CAST ships as a native Claude Code plugin (**dual-ship** — the plugin coexists with `install.sh`, it does not replace it). Two ways to load it:

**From the marketplace (recommended):**
```bash
/plugin marketplace add ek33450505/claude-agent-team
/plugin install cast
/plugin enable cast@cast
```

**From a local checkout:**
```bash
git clone https://github.com/ek33450505/claude-agent-team.git
claude --plugin-dir claude-agent-team/plugin
```

The plugin bundles CAST's curated agents, skills, commands, `command`-type enforcement hooks, and the GitHub MCP server (provide a token via the plugin's `GITHUB_TOKEN` config to enable it). It is **opt-in** (`defaultEnabled: false`) — **until you run `/plugin enable cast@cast`, the SessionStart bootstrap does not run.** `install.sh` remains authoritative for the runtime layer (`~/.claude/scripts`, `cast.db`, launchd jobs, git hooks); when both are present, the plugin's hooks defer to install.sh via a `~/.claude/config/cast-hook-owner` sentinel so nothing double-fires.

> **Curated payload:** the plugin ships **17 lean agents**; the `push` agent (needs the install.sh runtime) and `morning-briefing` are excluded. Add the 4 opt-in extras (perf-sentinel, release-notes, api-contract, dep-auditor) by regenerating with `bash scripts/gen-plugin.sh --with-extras dist/cast-plugin` then `claude --plugin-dir dist/cast-plugin`. The full `install.sh` carries all <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents.

---

## Quick Start

**[docs/tutorial/getting-started.md](docs/tutorial/getting-started.md)** — install, verify, and run `cast status` in 5 minutes.

---

## Why CAST

- **Local-first by construction.** Your code, prompts, memory, and the full audit trail (`cast.db`, SQLite) live on your disk. No SaaS dashboard, no telemetry egress, no "sign in to use it." Every cloud feature is strictly opt-in.
- **Data integrity by construction.** Backups live outside the blast radius; the failure detector lives outside it too; CAST cannot delete its own runtime. Born from real `~/.claude` wipes.
- **Quality gates that actually enforce.** Raw `git commit` and `git push` are hard-blocked by hooks. Code changes mandate a fresh-context reviewer pass. You cannot skip this.
- **<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> specialist agents, pre-configured.** Each has a bounded scope, a model tier (haiku 4.5 / sonnet / opus), and a thinking budget. `code-writer` implements; `code-reviewer` reviews; `commit` commits. They don't cross lanes.
- **Agent behavior is tested, not hoped for.** The `cast eval` harness runs an agent-behavior corpus mined from real failures — with LLM-judge graders and `pass@k`.
- **<!-- CAST_TEST_COUNT -->1807<!-- /CAST_TEST_COUNT --> BATS test cases** across the hook and utility layer. CI runs on macOS and Ubuntu on every push.

---

## The v8 Thesis: Less Bespoke, More Platform

CAST's organizing principle is convergence: **retire custom code wherever Claude Code now ships a native primitive, and keep only what the platform still lacks.** v8 acts on it — language-specific rules became demand-loaded skills, the mandatory planner chain softened to native plan mode for single-session work, and distribution moved to a native plugin (the breaking change behind the major version bump). What stays bespoke is what the platform doesn't yet provide: deterministic enforcement, a local audit trail, data-integrity guarantees, and agent-behavior evals. The flagship comes out *smaller*. See [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md).

---

## Pillar 1 — Local-First by Construction

The core loop never requires leaving the machine. Observability is local SQLite (`cast.db`); memory is local files + a local FTS5 index; enforcement is local hooks. Every cloud capability is an *additive convenience*, clearly labelled and never a dependency:

- **Managed Agents** (`--cloud`) — dispatch parallel agents on Anthropic infrastructure instead of git worktrees. Opt-in.
- **Cross-LLM routing** — route Haiku-tier work to a local Ollama model via [claude-code-router](https://github.com/musistudio/claude-code-router) (`ccr`). Opt-in, per session.

A CAST user with no network still has a fully working system. *Design rule: no feature may make the core dev loop depend on a remote service — if it would, it ships as an opt-in track.*

---

## Pillar 2 — Data Integrity by Construction

The thing that bit me three to four times (full `~/.claude` wipes) is now a headline guarantee. Hard-won lessons made into invariants:

- **Backups live outside the failure domain.** [Litestream](docs/backups.md) replicates `cast.db` continuously to `~/Library/Application Support/cast/` (off the `~/.claude` blast radius); dated snapshots land there too. The colocated `~/.claude/backups` that died with its host is gone.
- **The detector survives the blast radius.** The wipe canary runs from `~/Library/.../cast/bin/`, so it captures forensics the instant `~/.claude` vanishes — the detector can't be deleted by the event it detects.
- **CAST cannot destroy its own runtime.** Write-guards block writes outside a declared blast radius; a PreToolUse **command-guard** blocks `pkill`/`killall`/`kill -9` and `rm -rf` of protected roots; a `blast-radius-lint` ratchet fails CI on any bare `rm -rf` in `scripts/`; teardown guards isolate every test to a temp HOME.
- **Destructive ops are tested by proving refusal**, not just success. Schema migrations and prune jobs back up fail-closed before they touch data (`cast-migrate.py --confirm`).

`cast integrity` is the read surface — one honest command answering "are my guards live, backups fresh and off-radius, canary loaded, evidence path writable, *right now*?" — and a daily monitor notifies only when something regresses. Full design: [docs/backups.md](docs/backups.md).

---

## Documentation

| Guide | Description |
|---|---|
| [Tutorial](docs/tutorial/getting-started.md) | Install CAST and run your first agent dispatch |
| [Architecture](docs/architecture/ARCHITECTURE.md) | The v8 control plane, enforcement, data-integrity stack, evals |
| [Backups & Recovery](docs/backups.md) | Litestream, off-radius snapshots, `cast integrity` |
| [Hook Authoring Guide](docs/hooks/authoring-guide.md) | Write, test, and install custom hook scripts |
| [Compatibility Matrix](docs/compatibility.md) | Claude Code version requirements and known breakages |
| [Full Docs Index](docs/README.md) | All documentation with one-line descriptions |

---

## What is CAST?

CAST transforms Claude Code's agent loop into a **production-grade control plane:**

- **Structural quality gates.** Code changes mandate a reviewer pass; raw `git commit` and `git push` are hard-blocked by hooks.
- **Full, local observability.** Every session, task, routing decision, quality gate, peer message, and token spend logs to `cast.db` (SQLite, on your machine).
- **Typed agent contracts.** Agents emit a typed `## Handoff` block (JSON-schema-validated) so multi-agent chains don't fail silently.
- **Swarm composition in YAML.** Define teams, assign roles, set quality gates; CAST bootstraps worktrees and manages peer messaging.

---

## Your First Workflow

CAST matches planning ceremony to task size (the softened v8 planner doctrine):

1. **Trivial** (a typo, a one-value tweak) — just make the change. (Code still routes to a specialist; "no plan" never means "no review.")
2. **Single-session** (one or a few files) — native plan mode (shift-tab), single agent. The default for ordinary work.
3. **Multi-file / multi-agent** — `/plan add user auth feature` → the `planner`→`/orchestrate` chain writes an Agent Dispatch Manifest and runs it in waves.

Then **execute** — code-writer implements, code-reviewer checks (**mandatory**, fresh context), test-runner verifies, the commit agent stages — and **ship** (`/ship` → tests, CI sanity, push, journal entry).

---

## Architecture

Every CAST operation follows the same gated pipeline: a user prompt is routed by `CLAUDE.md`; **PreToolUse guards** (write-guard, command-guard, commit-guard) block non-compliant actions before they land; the **typed agent registry** dispatches to the right model tier; a **mandatory `code-reviewer` gate** reviews code in fresh context; the **SubagentStop** hook validates the typed Handoff, runs honesty sensors, and writes memory; and every step is appended to the local `cast.db` — which Litestream replicates *outside* the blast radius. Full guide: [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md).

<p align="center">
  <img src="docs/architecture/cast-architecture.svg" alt="CAST v8 control-plane request lifecycle" />
</p>

---

## Agents

<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> core specialists, each a markdown file in `~/.claude/agents/` with YAML frontmatter defining model tier, memory, isolation, and thinking budget. Agent responses validate against JSON schemas in `schemas/` (including the typed `## Handoff` contract). The plugin curates **17 lean agents** for distribution (+4 opt-in extras); the full `install.sh` carries all <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT -->. See [docs/agents/AGENT-ROSTER.md](docs/agents/AGENT-ROSTER.md) for the full table with model tiers.

Key agents: `code-writer`, `debugger`, `planner`, `researcher`, `security`, `code-reviewer`, `commit`, `push`, `test-writer`, `devops`, `bash-specialist`, `migration-reviewer`, `eval-writer`, `pr-reviewer`.

---

## Hooks

Deterministic `command`-type hooks enforce; `prompt`-type hooks are advisory. The lifecycle: **SessionStart** (bootstrap + context banner), **UserPromptSubmit** (memory recall + routing), **PreToolUse:Bash** (commit/push/stash block + the `pkill`/`rm -rf` command-guard), **PreToolUse:Write|Edit** (write-guards + reviewer injection), **PostToolUse**, **SubagentStop** (truncation detection + typed Handoff validation + honesty sensors + memory write), **PostCompact**, **SessionEnd** (memory distiller). See [docs/hooks/authoring-guide.md](docs/hooks/authoring-guide.md).

---

## Eval Harness

CAST has thousands of BATS *script* tests but, until v8, zero agent-*behavior* evals — the largest documented gap versus Anthropic's guidance. `cast eval` closes it: a corpus in `evals/cases/<agent>/*.yaml` mined from real failures (missed bugs, false `DONE`s, ignored scope), three-outcome graders (a grader that can't decide never false-fails), an LLM-judge grader, and `pass@k` for probabilistic behavior. Runs land in the `eval_runs` table.

```bash
cast eval list                 # available cases
cast eval run --all            # run the corpus
cast eval report               # latest verdict per case
```

---

## Observability & cast.db

SQLite (WAL mode) at `~/.claude/cast.db` — append-only, never truncated, **fully local**. Stores sessions, agent_runs, routing_events, quality_gates, agent_memories, eval_runs, agent_protocol_violations, swarm_sessions, teammate_runs, and more. Surfaced by two read-only dashboards:

**[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard)** — React 19 + Vite + Express, ~21 views (sessions, agent analytics & reliability, hook health, memory browser, plans, incidents, swarm runs, file-write audits, a SQLite explorer). **[Cast Desktop](https://github.com/ek33450505/cast-desktop)** — Tauri 2 native macOS app with an embedded PTY terminal, command palette, and 11 views. Both read `cast.db` locally — no cloud. See [docs/observability/OBSERVABILITY.md](docs/observability/OBSERVABILITY.md).

---

## Swarm System

CAST swarms are defined in YAML and bootstrapped with `cast swarm bootstrap`. Teams get isolated worktrees, agent identity, peer messaging (a decentralized cast.db message bus, no central broker), and quality gates. See [docs/swarm.md](docs/swarm.md) and [the architecture guide](docs/architecture/ARCHITECTURE.md#swarm-system).

---

## Agent Memory & Persistence

Each agent accumulates domain knowledge in `~/.claude/agent-memory-local/<name>/MEMORY.md` (Tier 1, native auto-load) alongside a dynamic per-prompt router over the `agent_memories` table (Tier 2, FTS5 relevance + confidence scoring). Language conventions load on demand as skills. See [the architecture guide](docs/architecture/ARCHITECTURE.md#memory-pipeline).

---

## Routines: Scheduled Workflows

Time- and event-triggered agent jobs — daily briefings, inbox triage, standup, weekly cost reports, the daily `cast integrity` monitor, and more. Manage with `cast routines list` / `cast routines trigger <name>`. Full guide: [docs/routines.md](docs/routines.md).

---

## Token Efficiency & Cost Optimization

Model tiering, response budgets, optional local Ollama routing (opt-in, never a dependency — Pillar 1), and laconic mode reduce token spend. See [docs/TOKEN-OPTIMIZATION.md](docs/TOKEN-OPTIMIZATION.md).

---

## Project Structure

`agents/core/` · `rules-{core,personal}/` · `skills/` · `commands/` · `docs/` · `schemas/` · `scripts/` · `swarm-configs/` · `evals/` · `plugin/` · `.claude-plugin/` · `tests/` · `.github/workflows/`

Runtime installs to `~/.claude/` — agents, memory, plans, swarm sessions, `cast.db`, scripts.

---

## Testing

163 CAST-authored BATS test files (<!-- CAST_TEST_COUNT -->1807<!-- /CAST_TEST_COUNT --> test cases) covering hooks, swarm bootstrap, the message bus, database migrations, guard logic (including **proving destructive ops refuse**), event emission, and memory persistence. Every test isolates to a temp HOME and stubs GUI side effects — a HARD RULE born from a wipe. BATS installs via package manager (`brew install bats-core` / `apt-get install bats-core`). Run with `bash tests/run.sh` (the CI-glob runner; plain `bats tests/` is non-recursive and skips subdirectory tests). **Never run the suite against your real `~/.claude`.**

---

## Version History

Full changelog: [CHANGELOG.md](CHANGELOG.md).

---

## CAST Ecosystem

CAST is one of 13 source repositories in a connected ecosystem — each solves a piece of the multi-agent workflow puzzle. All are open-source. See [docs/ecosystem.md](docs/ecosystem.md) for the full repo table and install commands.

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

- [**claude-code-dashboard**](https://github.com/ek33450505/claude-code-dashboard) — React observability UI — sessions, agent analytics, hook health, memory browser, SQLite explorer
- [**cast-desktop**](https://github.com/ek33450505/cast-desktop) — Tauri 2 native app with embedded PTY terminal, command palette, 11 dashboard views
- [**cast-claudes_journal**](https://github.com/ek33450505/cast-claudes_journal) — Session journaling; auto-injects prior-day context via SessionStart hook
- [**cast-dash**](https://github.com/ek33450505/cast-dash) — TUI dashboard for live swarm monitoring
- [**cast-hooks**](https://github.com/ek33450505/cast-hooks) · [**cast-routines**](https://github.com/ek33450505/cast-routines) · [**cast-doctor**](https://github.com/ek33450505/cast-doctor)

---

## Contributing

Contributions are welcome — CAST is built in the open and actively developed. New agents, shell script fixes, BATS test coverage, and documentation improvements are all fair game.

**Good first issues:** [`good first issue` label](https://github.com/ek33450505/claude-agent-team/issues?q=label%3A%22good+first+issue%22) — curated entry points with clear scope and test expectations.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow (including how to regenerate the plugin artifact). Open an issue first for non-trivial changes.

### Community

**Start here:** the pinned [start-here issue (#284)](https://github.com/ek33450505/claude-agent-team/issues/284) indexes every open good-first issue. [**GitHub Discussions**](https://github.com/ek33450505/claude-agent-team/discussions) is now open for questions and ideas. There are 8 scoped good-first issues right now — test-writing and documentation — and development is active.

---

## Support & Portfolio

Built by [Ed Kubiak](https://github.com/ek33450505) as a showcase of production-grade multi-agent AI tooling. [Portfolio →](https://edwardkubiak.com)

---

## License

MIT — see [LICENSE](LICENSE). Built by [Edward Kubiak](https://github.com/ek33450505) — full-stack engineer, Claude Code expert. CAST Portfolio: [castframework.dev](https://castframework.dev)

---

## Stats

<!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents |
<!-- CAST_TEST_COUNT -->1807<!-- /CAST_TEST_COUNT --> test cases |
<!-- CAST_COMMAND_COUNT -->20<!-- /CAST_COMMAND_COUNT --> commands |
<!-- CAST_SKILL_COUNT -->18<!-- /CAST_SKILL_COUNT --> skills
