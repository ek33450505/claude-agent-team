# CAST Future Roadmap

**Generated:** 2026-04-01
**Status:** Living document — items not in the v3.2 plan, ordered by rough priority.

---

## Overview

CAST v3.2 closes the remaining v3.x gaps (P2–P5) and adds three new capabilities (N1–N3). This document captures the backlog beyond v3.2 — items worth building but deferred to a future sprint.

---

## Backlog Items

---

### 1. CAST Plugin Package

**What it is:** Publish CAST as a native Claude Code plugin for single-click installation via the Claude Code plugin marketplace, in addition to the existing Homebrew tap.

**Why it matters:** The Homebrew tap targets developers who are comfortable with CLI tooling. A plugin marketplace listing removes friction entirely — one click, zero setup. It's the highest-leverage distribution channel for Anthropic job visibility: it puts CAST in front of every Claude Code user browsing extensions, not just people who find the GitHub repo.

**Effort:** 2–3 days. Requires understanding the Claude Code plugin packaging format, writing a plugin manifest, and setting up CI to publish on version tags.

**Dependencies:** None. Can be done independently of any other work.

---

### 2. PermissionRequest Hook

**What it is:** Wire up the `PermissionRequest` hook event (available in Claude Code's hook system) to auto-approve known-safe agent operations without requiring a pre-configured allow-list entry for every command.

**Why it matters:** Currently, every new bash command pattern needs to be added to `settings.json` permissions. A `PermissionRequest` hook lets CAST intercept permission prompts programmatically — auto-approve low-risk patterns (like `git status`, `ls`, `cat`) and block high-risk ones (network calls, credential access). This makes CAST's security model dynamic rather than static.

**Effort:** 3–4 hours. Write `cast-permission-hook.sh`, define a rules table in `cast.db` or a config JSON, wire into `settings.json`.

**Dependencies:** None.

---

### 3. managed-settings.d/ Fragment Split

**What it is:** Break the monolithic `settings.json` into composable fragment files (e.g., `10-hooks-telemetry.json`, `20-hooks-security.json`, `30-mcp.json`, `40-env.json`) that are merged at install time.

**Why it matters:** `settings.json` has grown to 347 lines with 18 hooks, MCP config, sandbox rules, and env vars. Any addition risks merge conflicts and makes the file hard to reason about. Fragment-based config enables independent testing, modular installs ("install telemetry hooks only"), and reduces the blast radius of config errors.

**Effort:** 2–3 hours. Write `cast-merge-settings.sh` that merges fragments into the final `settings.json`. Update `install.sh` to run it. Add BATS tests for the merge logic.

**Dependencies:** None. Non-breaking — the final merged output is the same file Claude Code reads.

---

### 4. Show HN Post

**What it is:** Publish the existing Show HN draft to Hacker News.

**Why it matters:** CAST is the most complete open-source Claude Code framework that exists — 16 agents, 16 commands, hooks-based observability, SQLite state, Homebrew tap. A well-timed Show HN post reaches exactly the audience (developers + Anthropic employees who browse HN) that matters for the Anthropic job goal.

**Draft location:** `research/hn-show-hn-draft.md`

**Action:** Review draft, update with v3.2 features (async hooks, OTEL wiring, quality gates schema, Agent SDK reference), post when v3.2 is pushed and verified.

**Effort:** 1–2 hours to polish. Post timing matters — aim for Tuesday–Thursday morning US time.

---

### 5. GitHub Profile README

**What it is:** Publish the profile README draft as a live `ek33450505/ek33450505` repo README.

**Why it matters:** GitHub profile READMEs appear prominently on your public profile — every recruiter and hiring manager who looks at the GitHub account sees it. The draft positions CAST + dashboard + Homebrew tap as a cohesive portfolio story.

**Draft location:** `research/github-profile-README.md`

**Action:** Copy to `~/Projects/personal/Edward_Kubiak/` or directly to `ek33450505/ek33450505` repo. Minimal edits — the draft is already polished.

**Effort:** 30 minutes.

---

### 6. README Benchmark Section

**What it is:** Add a benchmarked "zero latency" claim to the CAST README with timing data proving that async telemetry hooks add no measurable latency to Claude Code tool calls.

**Why it matters:** One of the strongest differentiators of CAST v3.1 is `async: true` on all telemetry hooks. This means observability is truly non-blocking. Publishing timing data (e.g., "hook P99 = 12ms, async so Claude never waits") turns a feature into a credible claim with evidence.

**Action:** Write a `scripts/cast-bench-hook-latency.sh` script that fires hooks 100 times and measures wall time with and without hooks. Capture output as a Markdown table. Add to README.

**Effort:** 2–3 hours.

---

### 7. GitHub Actions Integration — @claude Automation

**What it is:** Run `/install-github-app` on the `claude-agent-team` and `claude-code-dashboard` repos to enable the `@claude` GitHub integration. Set up automated code-review workflows triggered on PR open/sync.

**Why it matters:** Demonstrates CAST's value loop in the repo itself: every PR gets automated `@claude` code review, using the `code-reviewer` agent. It's dogfooding at the repo level and makes the CI workflow visible to anyone who looks at the project.

**Effort:** 30 minutes to wire up. May require GitHub App approval from Anthropic.

**Dependencies:** Anthropic GitHub app must be installable on the repo.

---

### 8. SessionEnd Hook Wire-up Audit

**What it is:** Verify that `cast-session-end.sh` is correctly wired in `settings.json`. The `Stop` hook fires it, but `SessionEnd` may also need a dedicated entry.

**Why it matters:** Session-end cleanup (flushing pending events, writing final token totals) should fire reliably. `Stop` and `SessionEnd` are distinct events — `Stop` fires when the agent stops cleanly, `SessionEnd` fires when the session terminates. Both should be covered.

**Action:** Read Claude Code docs to confirm `SessionEnd` semantics. Check `settings.json` — `SessionEnd` currently has a separate entry. Verify `cast-session-end.sh` handles both call paths idempotently.

**Effort:** 30–60 minutes.

**Note:** May already be done — verify before building.

---

### 9. @github: MCP Resource Syntax in Agent Prompts

**What it is:** Update `researcher`, `merge`, and `devops` agent prompts to use `@github:repos/...` MCP resource syntax for PR/issue queries, instead of `gh` CLI shell calls.

**Why it matters:** `@github:` resource references in agent prompts are resolved by the MCP server without spinning up a subprocess, reducing tool call overhead. For agents that do heavy GitHub querying (researcher, devops), this is a meaningful efficiency gain.

**Effort:** 1–2 hours. Update 3 agent `.md` files to replace `bash gh ...` patterns with `@github:` resource syntax where applicable.

**Dependencies:** MCP GitHub server must be configured in `settings.json` (it already is — `"github": { "command": "npx", ... }`).

---

### 10. Channels / External Triggers

**What it is:** Use Claude Code's `--channels` research preview to allow GitHub webhooks and Slack messages to trigger CAST agent dispatch without a human in the loop.

**Why it matters:** This is the highest-leverage automation unlock — it turns CAST from a "human-triggered" system into a fully autonomous pipeline. A GitHub webhook on PR creation can automatically dispatch `code-reviewer`. A Slack message can dispatch `morning-briefing`. This is the CAST version of a CI/CD system.

**Effort:** Unknown — `--channels` is a research preview with limited documentation. Estimate 1–2 days of investigation + implementation.

**Dependencies:** `--channels` flag must be available in the installed Claude Code version.

---

### 11. OpenTelemetry to Prometheus/Grafana

**What it is:** Wire `OTEL_EXPORTER_OTLP_ENDPOINT` (added in v3.2 via the session-start hook) to a local Prometheus + Grafana stack, creating a full observability pipeline alongside the cast.db dashboard.

**Why it matters:** CAST v3.2 adds OTEL wiring at the session-start level. This item closes the loop by providing an actual backend to receive the telemetry. Running Prometheus + Grafana locally alongside claude-code-dashboard would make CAST the only open-source Claude Code framework with a complete observability stack (structured events in SQLite + metrics in Prometheus + dashboards in both Grafana and the custom React dashboard).

**Effort:** 3–4 hours to wire up a `docker-compose.yml` with Prometheus + Grafana + OTEL collector. Requires defining what metrics to export (session count, agent dispatch rate, gate pass/block ratio, token cost rate).

**Dependencies:** Docker. `OTEL_EXPORTER_OTLP_ENDPOINT` support in session-start hook (done in v3.2).

---

## Priority Summary

| # | Item | Effort | Impact |
|---|---|---|---|
| 1 | CAST Plugin Package | 2–3 days | Distribution / Anthropic visibility |
| 2 | PermissionRequest hook | 3–4 hrs | Security model completeness |
| 3 | settings.d/ fragment split | 2–3 hrs | Maintainability |
| 4 | Show HN post | 1–2 hrs | Community reach |
| 5 | GitHub profile README | 30 min | Recruiter visibility |
| 6 | README benchmark | 2–3 hrs | Credibility |
| 7 | GitHub Actions @claude | 30 min | Dogfooding / PR automation |
| 8 | SessionEnd audit | 30–60 min | Reliability |
| 9 | @github: MCP syntax | 1–2 hrs | Efficiency |
| 10 | --channels external triggers | 1–2 days | Autonomous pipeline |
| 11 | OTEL → Prometheus/Grafana | 3–4 hrs | Observability completeness |
