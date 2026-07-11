---
name: agent-registry
description: Full CAST agent registry with model assignments. Load when building an Agent Dispatch Manifest, orchestrating multi-agent workflows, or when you need to verify which model a specific agent runs on.
user-invocable: true
allowed-tools: []
---

# CAST Agent Registry

The full CAST agent roster with model tier and one-line role description. The plugin installs a curated subset — run `cast status` or `cast doctor` for the live installed count.

| Agent | Model | Role |
|---|---|---|
| `api-contract` | haiku 4.5 | API contract guardian — detects breaking changes in REST endpoints, compares route signatures and response shapes, generates contract tests |
| `backend-writer` | sonnet | Implementation specialist for backend feature work, bug fixes, and planned changes — receives tasks from planner or orchestrator and owns the full write-test-review cycle |
| `bash-specialist` | sonnet | Shell scripting specialist for CAST hook scripts, BATS tests, and automation scripts — use for new hook scripts, BATS test authoring, and shell refactors |
| `code-reviewer` | haiku 4.5 | Per-unit code-quality and security review of a single logical change mid-flight, any language — dispatched after every writer or debugger unit, before commit |
| `commit` | haiku 4.5 | Git commit specialist — reads staged changes, writes a semantic commit message, and creates the commit following CAST conventions |
| `db-reader` | sonnet | Read-only data-analysis specialist — SQL queries, data exploration, and reporting against BigQuery or SQLite |
| `debugger` | sonnet | Root-cause debugging of concrete failures — a reproduced error, a stack trace, a failing test, or observably wrong runtime behavior |
| `dep-auditor` | haiku 4.5 | Dependency auditor — reviews package changes for transitive risk, known CVEs, version compatibility, and license concerns |
| `devops` | haiku 4.5 | CI/CD pipeline management and GitHub Actions workflow authoring |
| `docs` | haiku 4.5 | Documentation specialist — handles README audits/rewrites and doc updates after code changes |
| `email-drafter` | haiku 4.5 | Email and portfolio-sync specialist — drafts Gmail messages (compose, reply) for review, never sends, and syncs showcase repo READMEs with actual project state |
| `eval-writer` | sonnet | Eval and benchmark fixture author for Claude API and CAST agent prompts — generates YAML eval cases with runnable graders that catch prompt-level behavior drift |
| `frontend-qa` | haiku 4.5 | Deep React 19 and TypeScript review of .tsx/.ts files — prop typing, TanStack Query hook usage, frontend-to-backend API-contract alignment, Vitest coverage gaps, and a11y basics |
| `frontend-writer` | sonnet | Implementation specialist for frontend feature work, bug fixes, and planned changes — receives tasks from planner or orchestrator and owns the full write-test-review cycle |
| `infra-writer` | haiku 4.5 | Docker/containerization, infrastructure-as-code (Terraform, CloudFormation stubs), deployment configuration, and environment management |
| `merge` | haiku 4.5 | PR lifecycle agent — watches CI checks on the current PR and stops for confirmation before squash-merging after approval |
| `migration-reviewer` | opus | Database schema change reviewer — analyzes migration files for safety, generates rollback plans, validates ordering, and checks for destructive operations |
| `morning-briefing` | haiku 4.5 | Daily briefing agent that gathers git activity, action items, and CAST system intelligence, then assembles a structured morning report |
| `planner` | sonnet | Planning specialist that converts feature requests into specs and ordered task breakdowns — reserve for genuinely multi-file/multi-agent work requiring an Agent Dispatch Manifest |
| `pr-reviewer` | sonnet | Whole-PR review at PR-open time — reads the full multi-commit diff, commit-message coherence, scope creep, coverage gaps, and breaking-change surface |
| `push` | haiku 4.5 | Git push specialist — verifies branch safety, shows unpushed commits, sets upstream if needed, then pushes using the CAST workflow |
| `release-notes` | haiku 4.5 | Release notes generator — creates structured changelogs from git commits, resolved issues, and breaking changes between tags |
| `report-writer` | haiku 4.5 | Status/chain-reporting specialist — generates weekly status updates, project health checks, and multi-agent chain execution summaries |
| `researcher` | sonnet | Multi-purpose research and analysis specialist for codebase exploration, web research, technology comparisons, and architectural recommendations |
| `security` | sonnet | Security review specialist for code handling user input, auth, API keys, database queries, or external data — flags injection risks, secrets exposure, and authorization gaps |
| `test-runner` | haiku 4.5 | Test execution gate — runs the project test suite and gates the chain on real exit codes; MUST run in its own sequential batch, never co-scheduled with review agents |
| `test-writer` | haiku 4.5 | Test design specialist — writes test suites for existing code covering happy path, edge cases, and error states; detects the test framework in use and follows its conventions |

## Model Tier Summary

- **haiku 4.5** — api-contract, code-reviewer, commit, dep-auditor, devops, docs, email-drafter, frontend-qa, infra-writer, merge, morning-briefing, push, release-notes, report-writer, test-runner, test-writer
- **Sonnet** — backend-writer, bash-specialist, db-reader, debugger, eval-writer, frontend-writer, planner, pr-reviewer, researcher, security
- **Opus** — migration-reviewer

Agent definitions: `~/.claude/agents/`
