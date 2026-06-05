# CAST Agent Roster

> Canonical agent roster (referenced by README). See also: [Agent Contracts](agent-contracts.md) | [Quality Rubric](agent-quality-rubric.md)

23 core specialists. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, and isolation. Agent responses validate against JSON schemas in `schemas/` — status-block contract, work-log entries, and routing events are machine-readable for API pipelines and validation tools.

### Core Implementation & Review

| Agent | Model | Purpose |
|---|---|---|
| `code-writer` | sonnet | Implementation specialist for feature work, bug fixes, and planned changes |
| `debugger` | sonnet | Debugging specialist for errors, test failures, and unexpected behavior |
| `planner` | sonnet | Planning specialist that converts feature requests into specs and ordered task breakdowns |
| `researcher` | sonnet | Multi-purpose research and analysis specialist for codebase exploration and synthesis |
| `security` | sonnet | Security review specialist for auth, input validation, secrets, and vulnerability audit |
| `code-reviewer` | haiku | Post-change code review — use immediately after writing or modifying code |
| `test-writer` | haiku | Test design specialist — writes test suites covering happy path, edge cases, and error states |
| `test-runner` | haiku | Test execution gate — runs the project test suite and gates the chain on real exit codes |
| `eval-writer` | sonnet | Eval and benchmark fixture author for Claude API and CAST agent prompts |
| `pr-reviewer` | sonnet | Holistic pull-request reviewer — reads full diff, commit history, and linked issues at PR-open time |
| `frontend-qa` | haiku | Frontend QA specialist for React/TypeScript — prop correctness, API contract alignment, a11y |

### Operations & Workflow

| Agent | Model | Purpose |
|---|---|---|
| `commit` | haiku | Git commit specialist — stages and commits with semantic messages |
| `push` | haiku | Git push specialist — verifies branch safety and sets upstream |
| `merge` | haiku | PR lifecycle agent — git merges, rebases, conflict resolution |
| `devops` | haiku | CI/CD pipeline management, Docker, GitHub Actions workflow authoring |
| `bash-specialist` | haiku | Shell scripting specialist for CAST hook scripts, BATS tests, and automation |
| `docs` | haiku | Documentation specialist — README audits, doc updates, changelog entries |
| `morning-briefing` | haiku | Daily briefing agent — gathers git activity, action items, and CAST health summary |
| `release-notes` | haiku | Release notes generator — structured changelogs from git commits |

### Specialist Review

| Agent | Model | Purpose |
|---|---|---|
| `migration-reviewer` | opus | Database schema change reviewer — analyzes migration files for safety and rollback plans |
| `api-contract` | sonnet | API contract guardian — detects breaking changes in REST endpoints |
| `dep-auditor` | haiku | Dependency auditor — reviews package changes for CVEs, licenses, version compatibility |
| `perf-sentinel` | sonnet | Performance regression detector — runs benchmarks, interprets results in context |

**Model tiering:** Haiku (13 agents) for review, commit, ops, and doc work ($1/MTok); Sonnet (9 agents) for implementation, planning, and research ($3/MTok); Opus (1 agent) for high-stakes schema review. Tiering scales cost savings across the swarm.
