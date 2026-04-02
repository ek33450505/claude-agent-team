# CHANGELOG

## v3.3 — Phase 11: Audit Hardening (2026-04-01)

### Code Fixes (C1–C8)

- **C1** — `cast-task-completed-hook.sh` added to repo and wired into `install.sh`
- **C2** — `cast-db-log.py` silent exceptions replaced with structured error logging to `~/.claude/logs/db-write-errors.log`
- **C3** — Orchestrator classifies TRUNCATED responses separately from BLOCKED; no cascade on truncation
- **C4** — All critical hook scripts gain `_log_error()` helper — no more silent failures
- **C5** — `cast-audit-hook.sh` PII enforcement is advisory by default; opt into strict mode via `CAST_PII_ENFORCEMENT=strict`; 9-pattern safelist added to suppress false positives
- **C6** — `cast-memory-write.sh` SQL injection fixed — `sed` string escaping replaced with Python parameterized queries
- **C7** — Orchestrator `TodoWrite` references replaced with `TaskCreate`/`TaskUpdate`
- **C8** — `docs.md` command fixed — `doc-updater` → `docs` agent name

### Hardening Fixes (H1–H9)

- **H1** — `install.sh` now syncs `agents/core/*.md` to runtime on every install
- **H2** — `cast-memory-backup.sh` now includes `cast.db`, `plans/`, and `auto-memory/` in backup tarball
- **H3** — `cast-agent-memory-init.sh` ghost agent list removed — dynamic discovery via `find ~/.claude/agents/`
- **H4** — `code-writer` and `devops` agents no longer self-dispatch review chains — use Recommended Next Agents pattern instead
- **H5** — Orchestrator checkpoint system added — plans survive session disconnects mid-execution
- **H6** — Orchestrator policy enforcement gate added — reads `config/policies.json` before each batch dispatch
- **H7** — `post-tool-hook.sh` exits non-zero on prettier crash or status file write failure
- **H8** — SQLite WAL mode enabled; subagent hooks retry up to 3× with backoff on `SQLITE_BUSY`
- **H9** — 4 runtime-only scripts committed to repo: `cast-ci-monitor.sh`, `cast-route-install.sh`, `cast-routing-feedback.sh`, `tidy.sh`

### Behavior Change

- **Approval gate removed** — Orchestrator no longer pauses for user confirmation before batch dispatch; queue display is informational only, execution is immediate

---

## 2026-03-31

### Schema v6 + SessionStart write (`e4019cb`)
- **Migrated:** cast.db v5 → v6: added `event_type` and `data` columns to `routing_events` table
- **Fixed:** Spurious `exit 0` in v4→v5 migration path that caused the migration to silently succeed without running
- **Updated:** Fresh-install `CREATE TABLE routing_events` now includes `event_type` and `data` columns
- **Added:** `cast-session-start-hook.sh` writes `INSERT OR IGNORE` into sessions table on SessionStart (GAP-005)
- **Schema version:** bumped to 6

---

- 2026-03-28: Add cast-archive.sh — automated Stop hook for ~/.claude/ file archiving and cast.db pruning

## Phase 5 (2026-03-22 to 2026-03-26)

### Merge Skill (`b2edc4c`)
- **New:** `skills/merge/` — reusable skill fragment for git merge, rebase, and conflict resolution scenarios
- **New:** Scenario detection logic routes to appropriate merge strategy based on conflict type
- **Added:** `merge` agent promoted to core tier; dispatch routing wired in routing-table.json

### Specialist Agents — 6 New Agents (`1c87077`)
- **New:** `frontend-designer` — production-grade UI and design systems (React, Vue, Tailwind, MUI, shadcn)
- **New:** `framework-expert` — framework-native implementation for Laravel, Django, Rails, React, Vue
- **New:** `pentest` — automated security scanning, dependency audits, OWASP scanning (reports only, no file writes)
- **New:** `infra` — Terraform/IaC and cloud resource provisioning (AWS, GCP, Azure)
- **New:** `db-architect` — schema design, migration authoring, query optimization (write-capable counterpart to `db-reader`)
- **Updated:** Agent registry in CLAUDE.md.template updated to 42 total agents

### Documentation Updates (`1c1eeae`)
- **Updated:** README to document v1.9.0 validation output and new check table
- **Added:** Stage 2.5 architecture diagram entry for semantic routing
- **Added:** Parallel post-chain protocol section
- **Added:** ACI reference sections

### Infrastructure Hardening (`232f212`)
- **New:** Dry-run mode — `CAST_DRY_RUN=1` bypasses all hook side effects for safe testing
- **New:** `stop-hook.sh` — runs at session end: routing feedback, project board derivation, agent memory seeding, temp file cleanup
- **New:** `cast-rollback.sh` — restores working tree to pre-batch state after orchestrator failures
- **New:** `cast-board.sh` — derives project board state from event log
- **Fixed:** Four identified gaps from code audit (see commit body for details)

### Agent Profiling (`13ce26e`, `341c947`)
- **Removed:** Stage 2.5 semantic routing — reserved for future Claude Embeddings API integration
- **New:** `cast-agent-stats.sh` — agent performance profiling: hit rate, BLOCKED rate, avg turn count per agent
- **New:** `cast-validate.sh` v1.9.0 — adds 4 new checks (8–11): route install script, stop-hook wiring, proposals schema, security post_chain
- **Note:** semantic routing infrastructure remains in codebase for future development

---

## v1.5.0 — Fix (2026-03-26)

### Stale Count Corrections
- **Fixed:** `install.sh` menu string updated from "36 agents, 26 commands, 9 skills" to "42 agents, 32 commands, 13 skills"
- **Fixed:** `README.md` installer example updated from "36 agents, 32 commands, 12 skills" to "42 agents, 32 commands, 13 skills"
- **Fixed:** `README.md` validation output example updated from "36 agents" to "42 agents"
- **Fixed:** `~/.claude/CLAUDE.md` — added missing `[CAST-DISPATCH-GROUP]` directive to Hook Directives section (version drift from CLAUDE.md.template)

---

## Phase 4 (2026-03-22)

### Universal Dispatcher
- **New:** `/cast <request>` command — analyzes user intent and dispatches specialist agents
- **Changed:** `route.sh` stripped to logging-only for observability (no more text injection or dispatch messages)
- **Changed:** `CLAUDE.md.template` compressed from 175 to ~75 lines (delegation protocol now implicit in /cast behavior)
- **Added:** BATS test suite for `route.sh` (16 tests covering all routing scenarios and edge cases)

### Pattern Matching Simplification
- **Removed:** Overly broad planner patterns (`implement`, `we need to`, `i want to`, etc.) — replaced by Claude NLU in /cast
- **Removed:** `spawn-mode` from `route.sh` (superseded by explicit `/cast` invocation)
- **Removed:** `post-write-review.sh` and `code-review-gate.sh` PostToolUse hooks (enforcement moved to user command)
- **Simplified:** Stop hook to one-line prompt (reduced unnecessary output)

### Architecture Shift
- **From:** regex pattern matching (90 patterns, 15 routes) + text injection enforcement
- **To:** Claude's native NLU via /cast + explicit user commands
- **Result:** `route.sh` now observation-only (logs to dashboard), dispatch is user-initiated and transparent

---

## Phase 2 (2026-03-21)

### Routing System
- **Fixed:** `route.sh` false-positive on internal Claude Code `<task-notification>` XML messages — they now exit cleanly with no output
- **Changed:** Routing hints now instruct Claude to **dispatch agents directly** (not ask-first). The routing loop goes from 4 steps → 1 step.
- **Added:** `no_match` action logged to `routing-log.jsonl` for tracking routing miss rate (future: triggers Haiku router agent when miss rate > 20%)
- **Added:** 4 new routing patterns: `e2e-runner` (playwright/e2e test), `build-error-resolver` (typescript/build errors), `presenter` (slide deck/presentation), `morning-briefing` (daily briefing/schedule)
- **Fixed:** `commit` pattern tightened — no longer fires on "commit to this approach" or similar phrases

### Agents
- **Hardened:** `doc-updater` — added output format section, diff preview workflow, error handling table (was 16/25, now 23/25)
- **Synced:** `e2e-runner` installed version updated to match repo source (generic stack discovery replaces hardcoded project names)
- **Updated:** Agent quality rubric — re-scored `presenter` (14→20), `browser` (16→20), `e2e-runner` (16→23), `doc-updater` (16→23)

### Discoverability
- **Added:** `/help` command — lists all installed agents with model, command, and trigger conditions; explains routing system; shows examples with cost hints

### Installer
- **Updated:** Post-install "Next steps" now includes `/help` and a routing test example

### Branding
- **Renamed:** Project is now officially **CAST — Claude Agent System & Team** (README title updated)
- **Added:** Honest comparison table vs. NanoClaw v2 and Ruflo v3
- **Updated:** Architecture diagram agent/command counts from 23 → 24
- **Updated:** Router section describes Phase 2 auto-dispatch behavior

---

## Phase 1 (2026-03-20)

- Initial release: 24 agents, 24 commands, 9 skills, 3 lifecycle hooks
- Hook-based routing with regex pattern matching + Opus escalation via `opus:` prefix
- Agent quality rubric (`docs/agent-quality-rubric.md`) — 5-dimension scoring
- Cross-platform support — macOS + Linux/WSL with graceful degradation for macOS-only skills
- Companion dashboard: [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard)
