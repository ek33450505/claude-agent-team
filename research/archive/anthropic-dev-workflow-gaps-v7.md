# Anthropic Developer Workflow Gaps — CAST v7 Agent Evaluation
**Date:** 2026-05-09
**Question:** What does an Anthropic developer's full workflow need in 2026? Validate/retire 6 agent candidates.

---

## What the 2026 Anthropic Dev Workflow Looks Like

Based on Anthropic engineering posts, Claude Code documentation, and the Code w/ Claude 2026 conference:

- **Evals are first-class:** Anthropic builds eval suites before shipping agents. Capability evals graduate to regression suites. Teams use the Console Evaluation Tool, Bloom (automated behavioral evals), and custom benchmark modes. Writing these fixtures is a real recurring task.
- **PR review is multi-agent:** Anthropic's own Code Review product dispatches a fleet of specialized agents at PR-open time, not per-unit reviewers. This is distinct from the `code-reviewer` (per-unit, triggered per logical change).
- **Releases are shipped frequently:** API volume is up 17× YoY. Changelogs and release notes are a constant artifact. The release-notes agent has value if the trigger is clear.
- **DB migrations are high-risk:** No change in 2026 — schema migrations remain one of the most dangerous operations in any backend workflow. `migration-reviewer` covers a real gap.
- **API contracts matter as code becomes more agentic:** Breaking REST changes cause agent failures downstream. Still a real risk.
- **Marketing content load:** Anthropic ships major features monthly (Claude Code Skills 2.0, Managed Agents, Claude Design). Developer advocacy content is a real output. But CAST is a dev toolchain, not a content company.

---

## ADD Candidates

### 1. eval-writer (sonnet)
**Gap filled:** Writing eval fixtures and benchmark test cases for Claude API calls and agent prompt regressions. Anthropic now provides infrastructure (Console eval tool, Bloom, benchmark mode in skills) but developers must still author the fixture files.

**Trigger description:** Fires when a user adds or modifies a prompt file, agent definition, or system prompt; also on /eval or when a prompt engineering session completes. Writes `.eval.json` fixture files alongside the prompt.

**Model tier:** Sonnet — writing structured fixture files requires reasoning but not Opus-tier depth.

**Verdict: JUSTIFIED**
Evals are now a first-class part of Anthropic's recommended dev loop. CAST has no agent covering prompt/agent regression fixtures. The gap is real and the trigger is deterministic. Code w/ Claude 2026 explicitly called out eval-writing as the highest-leverage skill teams can develop. This closes a genuine hole.

---

### 2. pr-reviewer (sonnet)
**Gap filled:** Holistic PR-level review at PR-open time — reviewing the full diff in context of the entire changeset, not a single logical unit.

**Trigger description:** Fires when `gh pr create` is called or when a PR is opened. Reads all changed files in the PR diff, produces a single structured overview comment covering logic errors, security issues, scope drift, and missing tests.

**Model tier:** Sonnet — full-diff review with codebase context needs reasoning capability.

**Verdict: JUSTIFIED**
The existing `code-reviewer` is per-unit (fires after each logical change in a session). It does not do holistic PR review. Anthropic's own Code Review product (launched 2026) proves the PR-level review is a distinct and valuable signal — Anthropic's internal data shows it raised substantive review comments from 16% to 54% of PRs. CAST has this gap. The trigger is clean and unambiguous. The separation from `code-reviewer` is architecturally sound.

---

### 3. marketing-copy (haiku)
**Gap filled:** Writing landing pages, README heroes, LinkedIn posts, blog intros, social announcements for CAST releases.

**Trigger description:** Fires when user asks for announcement copy, README updates, social posts, or landing page content. No automated trigger — manual dispatch only.

**Model tier:** Haiku — copywriting is low-complexity text generation.

**Verdict: NOT JUSTIFIED**
The gap is real in the abstract but CAST is a developer toolchain, not a content production system. Marketing copy tasks occur infrequently (one per release cycle at most), have no deterministic trigger, and the output is always reviewed/revised manually before publishing. Haiku-tier copywriting does not require a dedicated agent — the main session handles this inline under the whitelist rule ("Documentation edits under 10 lines"). For larger pieces, dispatching `docs` agent is sufficient. Adding a `marketing-copy` agent would be YAGNI — it adds registry weight with near-zero automated dispatch potential.

---

## EVALUATE Agents

### 4. migration-reviewer (opus) — 0 dispatches
**Gap filled:** Safety review of database schema migrations — rollback plans, data-loss risk, ordering validation. Covers SQLite, PostgreSQL, MS SQL Server.

**Trigger description:** Routes on keywords: migrate, migration, schema, ALTER TABLE, DROP COLUMN, CREATE TABLE, data loss.

**Model tier:** Opus — schema safety reasoning requires deep analysis of cascading effects.

**Current dispatch count:** 0

**Verdict: JUSTIFIED — retain with trigger audit**
Zero dispatches reflects the CAST project's light migration cadence (SQLite via `better-sqlite3`, schema is append-only), not a flaw in the agent. The agent is a safety net — its value is in the rare high-stakes case, not frequency. Opus is appropriate: a migration error can destroy data. However, the routing keywords should be audited. Haiku routing may be missing trigger matches on `CREATE TABLE IF NOT EXISTS` + `ALTER TABLE` patterns in Python scripts (the most common CAST migration pattern). Recommend: add explicit routing tests in BATS for the Python script migration pattern. Retain at Opus.

---

### 5. api-contract (sonnet) — 2 dispatches
**Gap filled:** Detecting breaking REST API changes — route signature diffs, response shape changes, removed endpoints.

**Trigger description:** Routes on: API breaking, breaking change, route change, endpoint removed, response shape.

**Model tier:** Sonnet — diff analysis with reasoning, no extended thinking needed.

**Current dispatch count:** 2

**Verdict: JUSTIFIED — retain**
Two dispatches is low but the trigger is narrow by design. This agent fires on specific high-risk changes, not routine code. Anthropic's shift toward agentic workflows (API volume 17× YoY) makes breaking API contracts more dangerous — downstream agents fail silently on schema mismatches. The claude-code-dashboard project (Express 5 API + React frontend) has real REST surfaces that this agent guards. Retain.

---

### 6. release-notes (haiku) — 2 dispatches
**Gap filled:** Generating structured changelogs from git commits between two refs, grouped by conventional commit prefix.

**Trigger description:** Routes on: release, changelog, version bump, tag, what changed.

**Model tier:** Haiku — structured text generation from git log output, low reasoning requirement.

**Current dispatch count:** 2

**Verdict: JUSTIFIED — retain**
Two dispatches is appropriate for a release-cadence agent — CAST ships roughly every few weeks per the git log. The agent is correctly scoped and correctly tier'd at Haiku. The output (structured markdown changelog) has a clear consumer: the GitHub release, Homebrew formula bump, and README badge updates. No overlap with other agents. Retain as-is.

---

## Summary Matrix

| Agent | Status | Verdict | Model | Dispatches |
|---|---|---|---|---|
| eval-writer | ADD | JUSTIFIED | sonnet | new |
| pr-reviewer | ADD | JUSTIFIED | sonnet | new |
| marketing-copy | ADD | NOT JUSTIFIED | haiku | — |
| migration-reviewer | EVALUATE | JUSTIFIED — retain | opus | 0 |
| api-contract | EVALUATE | JUSTIFIED — retain | sonnet | 2 |
| release-notes | EVALUATE | JUSTIFIED — retain | haiku | 2 |

**Net result:** Add 2 agents (eval-writer, pr-reviewer). Keep 3 evaluate agents as-is. Reject marketing-copy.

---

## Sources

- [Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) — Anthropic Engineering (verified via WebSearch)
- [Code Review for Claude Code](https://claude.com/blog/code-review) — Anthropic announcement (verified via WebSearch)
- [Anthropic launches multi-agent code review — The New Stack](https://thenewstack.io/anthropic-launches-a-multi-agent-code-review-tool-for-claude-code/) — external coverage (verified via WebSearch)
- [Live blog: Code w/ Claude 2026](https://simonwillison.net/2026/May/6/code-w-claude-2026/) — Simon Willison conference notes (verified via WebSearch)
- [Using the Evaluation Tool — Claude API Docs](https://docs.anthropic.com/en/docs/test-and-evaluate/eval-tool) — Anthropic docs (verified via WebSearch)
- [Create strong empirical evaluations — Claude Docs](https://docs.anthropic.com/en/docs/test-and-evaluate/develop-tests) — Anthropic docs (verified via WebSearch)
- [Bloom: open source tool for automated behavioral evaluations](https://alignment.anthropic.com/2025/bloom-auto-evals/) — Anthropic alignment (verified via WebSearch)
- `~/Projects/personal/claude-agent-team/.claude/agents/migration-reviewer.md` — local agent def
- `~/Projects/personal/claude-agent-team/.claude/agents/api-contract.md` — local agent def
- `~/Projects/personal/claude-agent-team/.claude/agents/release-notes.md` — local agent def
