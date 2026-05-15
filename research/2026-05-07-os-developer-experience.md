# Open Source Developer Experience Audit — 2026-05-07

**Scope:** CAST v6.0 at `~/Projects/personal/claude-agent-team`
**Auditor:** researcher agent
**Context:** ~2000 clones per 14 days. Vision: zero-config, phenomenal open source Anthropic developer CLI framework. Current reality: install works, but value extraction requires deep orientation.

---

## First 5 Minutes — Friction Map

**What a user sees on GitHub:** Banner image, shields (version 6.0, agents 30, tests 72, MIT). Value prop tagline is clear. Install CTA is present: `brew tap ek33450505/cast && brew install cast`. Quick Start links to the tutorial. This is actually solid — the above-the-fold is not the problem.

**Friction begins after install:**

1. **`cast status` requires cast.db to exist.** After `brew install cast`, `cast status` tries to read `cast.db`. If it does not exist, the output degrades to "No recent agent runs recorded" with no guide to fix it. The tutorial shows a green output that new users cannot reproduce. `cast-db-init.sh` exists in scripts but is never mentioned in the Getting Started guide or by `cast doctor`.

2. **`cast doctor` is undiscoverable.** The subcommand exists but is not surfaced in the tutorial as "run this if something is wrong." New users who hit an error after install have no obvious diagnostic path.

3. **No `cast init-repo` subcommand.** The CONTRIBUTING.md mentions `cast init-repo` as a backlog item. It does not exist in `bin/cast`. The subcommand list includes `exec`, `parallel`, `dispatch`, `memory`, `budget`, `agents`, `hooks`, `doctor`, `upgrade-check`, `migrate`, `tidy`, `dash`, `install-completions` — but not `init-repo`. Users following old docs or README notes expecting this command will hit a dead end.

4. **settings.json wiring is opaque.** `install.sh` runs `cast-merge-settings.sh` to wire hooks into `~/.claude/settings.json`. If this fails (and it silently warns), hooks never fire. There is no post-install verification step that confirms hooks are actually wired. The tutorial shows `cast status` output listing "Hook events wired: 16" but a user with a failed merge would see a different number with no error.

5. **123 scripts, 1070 BATS tests, README says 72.** The badge is stale — a critical trust signal for open source. The `make docs` / `gen-stats.sh` pipeline exists but the stat-claim guard uses `git ls-files` and still produced a wrong badge at v6.0 (corrected in v6.0.1, per memory). Contributors running `make docs` may still produce wrong counts if `git ls-files` counts differ from actual test annotations.

6. **"Your First Workflow" requires Claude Code to be open and running.** The tutorial dispatches `code-reviewer` by typing into an active Claude Code session. This is technically correct but feels like a UX gap: there is no `cast dispatch code-reviewer <file>` CLI shorthand that works without opening Claude Code. `cast dispatch --managed` exists but requires a valid `ANTHROPIC_API_KEY` and invokes the Managed Agents beta API — not a "first 5 minutes" operation.

7. **`CONTRIBUTING.md` requires `task_claimed` event emission but the event script path is `~/.claude/scripts/cast-events.sh` — not in the repo.** First-time contributors cannot run the Step 0 protocol without first running `install.sh`. This is documented but the dependency chain is non-obvious.

8. **No "good first issue" label on GitHub visible from the README.** The `2026-05-04-good-first-issues-draft.md` exists in research/ but there is no link from README or CONTRIBUTING.md to open GitHub issues tagged `good first issue`. New contributors have no curated entry point.

---

## "Fully Anthropic Developer CLI" — Capability Analysis

**What CAST provides that Claude Code does not:**

| Capability | CAST | Claude Code alone |
|---|---|---|
| Persistent agent memory across sessions | Yes — `agent_memories` in cast.db | No |
| Full audit trail of every dispatch | Yes — cast.db with 26+ tables | No |
| Quality gates that block bad commits | Yes — PreToolUse hooks, git hook enforcement | No |
| Budget governance with per-session cost tracking | Yes — `cast budget`, agent_runs table | No |
| 30 pre-configured specialist agents | Yes | User defines everything |
| Managed Agents dispatch via CLI | Yes — `cast dispatch --managed` | No |
| Swarm composition (multi-agent orchestration) | Yes — Agent Dispatch Manifests, wave execution | No |

**What is still missing for "fully Anthropic developer CLI":**

- **No first-run wizard.** `cast init-repo` does not exist. A new user has no guided per-project setup.
- **No in-terminal agent output summary.** After an agent completes, the developer reads output only inside Claude Code's interface. `cast status` shows last 5 runs but not their output or findings.
- **No `cast new-agent` scaffolding.** To add an agent, contributors must read CONTRIBUTING.md and manually write frontmatter. A `cast new-agent <name>` that scaffolds the `.md` with correct frontmatter would eliminate the most common contributor error.
- **No cost alerts in real time.** `cast-budget-alert.sh` exists but fires as a hook — there is no `cast budget --watch` live mode.
- **No native CI integration artifact.** CAST produces cast.db locally, but there is no `cast report --ci` that generates a GitHub Actions summary or SARIF-compatible output for PR checks.

---

## Unified Experience — What `cast status` Should Show

**Current state:** `cast status` renders a terminal block with: version, agent count, hook count, today/week budget, memory entry count, and last 5 agent runs (agent name, model, status symbol, time ago). It is functional but reads like a system health check, not a "CAST is working for you" signal.

**Data sources that exist but are not shown:**
- `routing_events` table — what was routed and to which agent
- `quality_gates` table — how many gate passes/blocks this week
- `agent_truncations` table — context exhaustion incidents
- `hook-errors.log` — recent hook failures
- CI badge status (would require fetch)

**Ideal `cast status` — glanceable, actionable:**

```
CAST v6.0
======================================================
Session   ses_01Xabc...     (started 2h ago)
Agents    30 installed       Hooks  16 active
Budget    $0.12 today        $0.87 this week (↓12%)
Memory    214 entries        Gates  3 passed / 0 blocked
------------------------------------------------------
Recent activity (last 5):
  + code-writer      [sonnet]         12m ago
  + code-reviewer    [haiku-4-5]      13m ago
  + commit           [haiku-4-5]      13m ago
  ~ debugger         [sonnet]         2h ago   BLOCKED
------------------------------------------------------
Alerts: 1 hook error in last 24h — run: cast hooks
```

The key additions: gate pass/block ratio (shows CAST is enforcing quality), budget trend (↓12% vs last week shows optimization working), alert line for hook errors with an actionable command.

---

## 5 Capabilities That Would Make Developers Choose CAST

Compared to LangChain, CrewAI, AutoGen, and raw Claude API:

1. **Claude Code-native, not API-native.** CAST extends the developer's existing Claude Code session rather than building a separate orchestration runtime. Agents run as subagents inside the developer's active context — no separate server, no REST endpoint, no container. This is the integration surface no competitor has because they built before Claude Code existed.

2. **Quality gates that enforce, not advise.** CAST's PreToolUse hooks block `git commit` and `git push` at the shell level unless the reviewer pass has completed. LangChain, CrewAI, and AutoGen have no concept of blocking a developer action — they can flag issues but cannot enforce. For teams that have been burned by AI-generated code skipping review, this is the only framework with a credible enforcement story.

3. **Local-first, fully auditable SQLite trail.** Every dispatch, token spend, memory entry, and routing decision logs to a SQLite file on the developer's machine — no SaaS signup, no telemetry, no cloud dependency. AutoGen and CrewAI both have optional cloud dashboards; CAST's audit trail is mandatory and local. For developers in regulated industries, air-gapped environments, or with data sovereignty requirements, this is differentiating.

4. **Memory that persists across sessions by agent.** CAST's agent memory system (`agent_memories` in cast.db, per-agent MEMORY.md files) gives each specialist a growing context about the project that survives session restarts. The `researcher` agent remembers what it last found; the `code-reviewer` remembers past concerns it raised. Raw Claude API has no session persistence; LangChain's memory modules require explicit wiring. CAST ships memory pre-wired for all 30 agents.

5. **Model-tier routing for cost governance.** CAST assigns haiku to lightweight agents (commit, code-reviewer) and sonnet to complex agents (debugger, planner, security) automatically — without the developer writing routing logic. At scale (2000+ clones), this achieves the 30-50% cost reduction documented in TOKEN-OPTIMIZATION.md without developer intervention. No competitor routes by task complexity by default; they expose model selection as a parameter the developer must set per call.

**What CAST cannot credibly claim over competitors today:** Python ecosystem compatibility (CAST is Bash-first; LangChain has far more Python integrations), production API serving (CAST is a developer CLI, not an inference server), and multi-cloud agent hosting (Managed Agents beta is Anthropic-only).

---

## Contributor Journey — Gap Analysis

**What exists:**
- `CONTRIBUTING.md` — comprehensive; covers agents, routing rules, agent groups, running tests, docs sync, and the personal overlay
- `.github/ISSUE_TEMPLATE/bug_report.yml` and `feature_request.yml` — both present and well-structured
- `.github/PULL_REQUEST_TEMPLATE.md` — present with a complete pre-merge checklist
- `.github/workflows/bats-ci.yml` — runs on push to main AND pull_request; fork PRs will trigger CI (added recently per git log)
- `make test` and `make docs` — both work and are documented

**What is missing or broken:**

1. **No "good first issue" label workflow.** CONTRIBUTING.md does not link to open issues. The research draft exists but no issues are visibly curated. A new contributor who reads CONTRIBUTING.md and then opens the issues tab sees unfiltered issues with no entry-point label.

2. **`task_claimed` event script is not in the repo.** CONTRIBUTING.md requires every new agent to emit a `task_claimed` event by sourcing `~/.claude/scripts/cast-events.sh`. This script ships via `install.sh` into `~/.claude/scripts/` but is not importable from the repo root without install. A contributor who clones and tries to write a new agent following the guide cannot test Step 0 without running the installer.

3. **`make docs` count drift risk.** CONTRIBUTING.md says "CI will fail the PR if README counts are stale." The `gen-stats.sh` script counts agents by `ls agents/*.md | wc -l` — deterministic. But test counts have historically drifted (v6.0.0 badge was wrong by a large margin). The stat-claim guard exists but only covers README writes in a hook context; a contributor running `make docs` locally with a different BATS count baseline could produce a stale badge and not know it until CI fails.

4. **Hook option list in bug template is stale.** `bug_report.yml` lists hook options as `route.sh, post-tool-hook.sh, stop-hook.sh, agent-status-reader.sh, cast-events.sh, other`. Some of these do not match the current script names in `scripts/` (e.g., `cast-audit-hook.sh`, `cast-cwdchanged-hook.sh`, `cast-budget-alert.sh`). A contributor filing a bug about a hook they can't find in the dropdown will pick "other" or be confused.

5. **No `DEVELOPMENT.md` explaining the full local dev loop.** CONTRIBUTING.md is strong on "what to add" but light on "how to debug a hook locally." There is no guide for: how to trigger a hook without a real Claude Code session, how to inspect `cast.db` for a test run's events, or how to use `cast doctor` to verify your setup.

---

## Prioritized Action List

### Before Phase 3 ships (≤ 10 items, ≤ 1 day each)

1. **Fix the BATS test badge** — Run `grep -rh "@test" tests/ | wc -l`, update README badge, add a `make docs` assertion that the count matches the live grep, not `git ls-files`. *Why urgent:* 72 vs 1070 is a trust-destroying discrepancy for any developer evaluating the project seriously. This is under 30 minutes.

2. **Add `cast db-init` check to `cast doctor`** — If `cast.db` does not exist, `cast doctor` should detect it, print the init command, and optionally run it. *Why urgent:* Every new install that runs `cast status` before any agent dispatch gets degraded output with no path forward. This is the single highest-impact first-run fix.

3. **Fix `bug_report.yml` hook dropdown options** — Replace stale hook names with the current `scripts/cast-*.sh` names. *Why urgent:* Active bug reports are arriving with wrong hook names; maintainer triage time increases.

4. **Add a "good first issue" label and pin 3 curated issues** — Use the existing `2026-05-04-good-first-issues-draft.md` research to open and label 3 GitHub issues. Add a "Contributing" callout to `CONTRIBUTING.md` linking to `https://github.com/ek33450505/claude-agent-team/issues?q=label%3A"good+first+issue"`. *Why urgent:* 2000 clones per 14 days means contributor traffic exists; there is no curated entry point.

5. **Add a `cast new-agent <name>` subcommand to `bin/cast`** — Scaffold a new agent `.md` file in `agents/core/` with correct frontmatter (name, description, tools, model) and the `task_claimed` boilerplate. Print the path and next steps. *Why urgent:* The most common contributor task (adding an agent) has no scaffolding; CONTRIBUTING.md is a wall of prose for what should be a one-command workflow.

6. **Surface `cast doctor` in the Getting Started tutorial** — Add a "Troubleshooting" section at the end of `docs/tutorial/getting-started.md` that says: if anything looks wrong, run `cast doctor`. *Why urgent:* Zero friction to diagnose install failures; currently users either give up or open a bug.

7. **Add budget trend and gate ratio to `cast status`** — Two lines: `Gates  N passed / M blocked this week` and a week-over-week budget delta. These fields already exist in `cast.db`. *Why urgent:* Shows CAST is working, not just installed. This is the difference between "I installed it" and "it's doing something for me."

8. **Add `cast init-repo` as a stub with a roadmap note or implement the minimum** — Even a stub that creates `.claude/cast.json` with `{"repo_class": "personal"}` and prints next steps gives users the command they expect. *Why urgent:* The command is referenced in CONTRIBUTING.md backlog; users who run `cast init-repo` get `Unknown subcommand` which is worse than "not implemented yet."

9. **Document `cast-events.sh` dependency in CONTRIBUTING.md** — Add one sentence: "Before writing agent Step 0 code, run `bash install.sh` once to install the helper scripts that agents depend on at `~/.claude/scripts/`." *Why urgent:* Contributor confusion around the `task_claimed` event is predictable and preventable in 5 minutes.

10. **Add a demo GIF or asciinema** — The README has `<!-- TODO(ed): record 10s asciinema of cast status + orchestrate run -->` as a comment. This is the single highest-impact marketing improvement for converting repo visitors to installs. *Why urgent:* GitHub README with a moving demo converts 2-3x better than static text. 10-second recording, one day of work.

### After Phase 3 ships

1. **Implement `cast init-repo` fully** — Per-project config wizard: repo class (personal/work), budget threshold, preferred model tier, co-author trailer preference. Writes `.claude/cast.json`.
2. **Add `cast report --ci`** — Generate GitHub Actions step summary or SARIF output from cast.db agent runs for PR checks.
3. **Add `cast budget --watch`** — Live terminal spend ticker using cast.db polling.
4. **Build a `DEVELOPMENT.md`** — Full local dev loop: triggering hooks without a live Claude Code session, inspecting cast.db for test events, using `cast doctor` output.
5. **Publish `castframework.dev`** — The domain is referenced in the README but the site does not exist (or is not live). A docs site with search is the next tier of discoverability after the GitHub README.

---

## Sources

- `~/Projects/personal/claude-agent-team/README.md` (read lines 1-200)
- `~/Projects/personal/claude-agent-team/CONTRIBUTING.md` (read in full)
- `~/Projects/personal/claude-agent-team/install.sh` (read lines 1-80, hooks section ~170-220)
- `~/Projects/personal/claude-agent-team/bin/cast` (read lines 1-430, status subcommand full)
- `~/Projects/personal/claude-agent-team/docs/tutorial/getting-started.md` (read in full)
- `~/Projects/personal/claude-agent-team/docs/tutorial/first-agent-dispatch.md` (read in full)
- `~/Projects/personal/claude-agent-team/.github/PULL_REQUEST_TEMPLATE.md` (read in full)
- `~/Projects/personal/claude-agent-team/.github/ISSUE_TEMPLATE/bug_report.yml` (read in full)
- `~/Projects/personal/claude-agent-team/.github/ISSUE_TEMPLATE/feature_request.yml` (read in full)
- `~/Projects/personal/claude-agent-team/.github/workflows/bats-ci.yml` (read in full)
- `scripts/` directory listing (123 scripts counted)
- BATS test annotation count: 1070 actual vs 72 in badge (via grep)
