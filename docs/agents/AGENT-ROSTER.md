# CAST Agent Roster

> Extracted from [README](../../README.md). See also: [Agent Contracts](agent-contracts.md) | [Quality Rubric](agent-quality-rubric.md)

Core specialists across 4 categories, with optional personal overlay. Each is a markdown file in `~/.claude/agents/` with YAML frontmatter defining model, memory, and isolation.

Agent responses validate against JSON schemas in `schemas/` — status-block contract, work-log entries, and routing events are machine-readable for API pipelines and validation tools.

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

**Model tiering:** Most lightweight agents run on Haiku ($1/MTok); reasoning-heavy agents on Sonnet ($3/MTok). This cost savings scales across the swarm.

**MCP integrations:** Todoist (task-triage), Google Calendar (meeting-prep), Gmail (email-drafter), Obsidian (knowledge-curator, learning-scout).
