# CAST Agent Roster

> Canonical agent roster (referenced by README). See also: [Agent Contracts](agent-contracts.md) | [Quality Rubric](agent-quality-rubric.md)

27 core specialists. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, and isolation. Agent responses validate against JSON schemas in `schemas/` — status-block contract, work-log entries, and routing events are machine-readable for API pipelines and validation tools.

### Core Implementation & Review

| Agent | Model | MaxTurns | Purpose |
|---|---|---|---|
| `frontend-writer` | sonnet | 80 | Implementation specialist for frontend feature work, bug fixes, and planned changes |
| `backend-writer` | sonnet | 80 | Implementation specialist for backend feature work, bug fixes, and planned changes |
| `debugger` | sonnet | 50 | Debugging specialist for errors, test failures, and unexpected behavior |
| `planner` | sonnet | 20 | Planning specialist that converts feature requests into specs and ordered task breakdowns |
| `researcher` | sonnet | 40 | Multi-purpose research and analysis specialist for codebase exploration and synthesis |
| `db-reader` | sonnet | 25 | Read-only data-analysis specialist for SQL queries, data exploration, and reporting against BigQuery or SQLite |
| `security` | sonnet | 20 | Security review specialist for auth, input validation, secrets, and vulnerability audit |
| `code-reviewer` | haiku | 50 | Post-change code review — use immediately after writing or modifying code |
| `test-writer` | haiku | 50 | Test design specialist — writes test suites covering happy path, edge cases, and error states |
| `test-runner` | haiku | 20 | Test execution gate — runs the project test suite and gates the chain on real exit codes |
| `eval-writer` | sonnet | 25 | Eval and benchmark fixture author for Claude API and CAST agent prompts |
| `pr-reviewer` | sonnet | 25 | Holistic pull-request reviewer — reads full diff, commit history, and linked issues at PR-open time |
| `frontend-qa` | haiku | 20 | Frontend QA specialist for React/TypeScript — prop correctness, API contract alignment, a11y |

### Operations & Workflow

| Agent | Model | MaxTurns | Purpose |
|---|---|---|---|
| `commit` | haiku | 20 | Git commit specialist — stages and commits with semantic messages |
| `push` | haiku | 15 | Git push specialist — verifies branch safety and sets upstream |
| `merge` | haiku | 20 | PR lifecycle agent — git merges, rebases, conflict resolution |
| `devops` | haiku | 15 | CI/CD pipeline management and GitHub Actions workflow authoring |
| `infra-writer` | haiku | 20 | Docker/containerization, infrastructure-as-code (Terraform, CloudFormation stubs), deployment configuration, and environment management |
| `bash-specialist` | sonnet | 30 | Shell scripting specialist for CAST hook scripts, BATS tests, and automation |
| `docs` | haiku | 20 | Documentation specialist — README audits/rewrites and doc updates after code changes |
| `report-writer` | haiku | 20 | Status/chain-reporting specialist — weekly status updates, project health checks, multi-agent chain execution summaries |
| `email-drafter` | haiku | 15 | Email and portfolio-sync specialist — drafts Gmail messages for review (never sends) and syncs showcase repo READMEs with project state |
| `morning-briefing` | haiku | 25 | Daily briefing agent — gathers git activity, action items, and CAST health summary |
| `release-notes` | haiku | 15 | Release notes generator — structured changelogs from git commits |

### Specialist Review

| Agent | Model | MaxTurns | Purpose |
|---|---|---|---|
| `migration-reviewer` | opus | 20 | Database schema change reviewer — analyzes migration files for safety and rollback plans |
| `api-contract` | haiku | 20 | API contract guardian — detects breaking changes in REST endpoints |
| `dep-auditor` | haiku | 15 | Dependency auditor — reviews package changes for CVEs, licenses, version compatibility |

**Model tiering:** Haiku (16 agents) for review, commit, ops, and doc work ($1/MTok); Sonnet (10 agents) for implementation, planning, and research ($3/MTok); Opus (1 agent) for high-stakes schema review. Tiering scales cost savings across the swarm.

**Note on turn budgets:** `code-reviewer` carries a maxTurns of 50 — notably higher than the 15–25 band most non-implementation agents occupy — which may correlate with its `background: true` frontmatter flag (background/async execution), though the exact rationale for this distinction is not documented elsewhere, so treat this as an observed asymmetry rather than a confirmed causal link.

**Main-loop default (inline session):** `claude-sonnet-5` — set in `managed-settings.d/16-model-defaults.json` (pinned ID, not the `sonnet` alias, to prevent silent model drift). Chosen for documented near-Opus-4.8 capability at a fraction of the cost ($2/$10 per 1M vs Opus 4.8's $5/$25 — 2.5x cheaper on both input and output). The $2/$10 rate was announced as introductory pricing through 2026-08-31; Anthropic has since made it the standard price and cancelled the scheduled increase to $3/$15 (verified 2026-09-01). Rates live in `config/model-pricing.json` — verify against <https://platform.claude.com/docs/en/about-claude/pricing> before changing them, never from memory.

**Manual escalation:** `/model opus` for the hardest reasoning tasks, within the standing Opus-4.8 subagent cap; `/model fable` for the very hardest **solo** work only (no fan-outs — see warning below).

> **⚠ Workflow / Explore / Plan / general-purpose subagents INHERIT the main-loop model.** A `/model fable` session that fans out a Workflow spawns *Fable* subagents — which violates the "no Fable dispatches / no subagents beyond Opus 4.8" rule. Keep `/model fable` to solo work only; for fan-outs stay on Sonnet 5 or Opus (or set per-agent model overrides in the Workflow script). `migration-reviewer` is unaffected — its frontmatter `model: opus` is explicit and does not inherit from the main-loop setting.
