# Agent Inventory Audit — CAST v7 Phase 4
**Date:** 2026-05-09
**Branch:** feature/cast-v7-phase-4-agents
**Data window:** 90-day dispatch counts (pinned baseline)

## Executive Summary

Of 30 active agents, 18 are recommended KEEP (heavy/moderate dispatchers or wired into skills/slash commands), 4 are MERGE candidates (roles fully absorbed by a heavier peer), 5 are RETIRE candidates (zero dispatches, no wiring, no unique capability), and 3 are EVALUATE (zero dispatches but a plausible trigger exists). Cutting from 30 to 21 removes the long tail of never-used agents while preserving every capability that has fired in 90 days. The team shrinks by 30% with zero capability loss; truncation rates drop for every surviving agent because the routing table resolves faster.

**Lateral, not up:** Recommend cutting from 30 → 21 agents. The removed agents averaged 0 dispatches in 90 days and their roles either duplicate a heavier agent or require external integrations (Todoist, Google Calendar, Obsidian) that are not wired in the active stack.

---

## Disposition Table

| name | model | dispatches (90d) | wiring | disposition | justification |
|---|---|---|---|---|---|
| code-writer | sonnet | 698 | skills=0, refs=3 | KEEP | Highest dispatch rate; core implementation agent |
| commit | haiku | 552 | skills=2, refs=3 | KEEP | Mandatory by convention; slash+skill wired |
| code-reviewer | haiku | 435 | skills=2, refs=3 | KEEP | Chain-map + skill wired; post-code-writer gate |
| push | haiku | 255 | skills=2, refs=3 | KEEP | Slash command wired; end-of-session workflow |
| researcher | sonnet | 247 | skills=2, refs=3 | KEEP | Slash command + chain-map → planner |
| bash-specialist | haiku | 197 | skills=0, refs=3 | KEEP | High dispatch; scripting workhorse |
| planner | sonnet | 111 | skills=0, refs=3 | KEEP | Chain-map receiver from researcher; pre-build gate |
| security | sonnet | 96 | skills=2, refs=3 | KEEP | /secure command wired; meaningful dispatch rate |
| test-runner | haiku | 74 | skills=0, refs=3 | KEEP | Chain-map receiver from test-writer |
| docs | haiku | 59 | skills=0, refs=3 | KEEP | /docs command wired; solid dispatch rate |
| debugger | sonnet | 51 | skills=2, refs=3 | KEEP | /debug command; mandatory error routing |
| test-writer | haiku | 43 | skills=2, refs=3 | KEEP | Chain-map → test-runner; skill wired |
| frontend-qa | haiku | 37 | skills=0, refs=3 | KEEP | Auto-triggered on .tsx/.ts changes; distinct from code-reviewer |
| merge | haiku | 29 | skills=2, refs=3 | KEEP | /merge command wired |
| devops | haiku | 12 | skills=0, refs=3 | KEEP | /devops command wired; CI/infra unique scope |
| perf-sentinel | sonnet | 1 | skills=2, refs=2 | KEEP | cast-audit skill wired as follow-up; unique benchmark+bisect capability not covered by any other agent |
| dep-auditor | haiku | 3 | skills=0, refs=2 | KEEP | routing-table wired on `dependency/audit/cve` keywords; unique CVE triage scope; cost is haiku, risk of missing is high |
| morning-briefing | haiku | 2 | skills=0, refs=3 | KEEP | /morning command wired; git-activity + briefing-writer skills; session-start ritual with real usage |
| migration-reviewer | opus | 0 | skills=0, refs=2 | EVALUATE | Routing-table wired on `migrate/schema/alter table`. Triggers when DB migrations land — low frequency by design. Unique capability: opus-tier safety review before schema change ships. Would trigger on next SQLite migration in any project. |
| api-contract | sonnet | 2 | skills=0, refs=2 | EVALUATE | Routing-table wired. Trigger: API breaking-change work. Low but non-zero dispatches. Overlaps with code-reviewer on surface but adds contract/OpenAPI reasoning code-reviewer lacks. Watch for next API refactor. |
| release-notes | haiku | 2 | skills=0, refs=3 | EVALUATE | No slash command. Routing-table wired on `release/changelog`. Would trigger on version bumps. Haiku cost is negligible. Could merge into docs, but changelog format is distinct. Keep unless Phase 4.5 finds zero use after 30 more days. |
| portfolio-sync | haiku | 1 | skills=0, refs=2 | MERGE-INTO-docs | Role: sync README stats. Docs agent already reads/writes markdown; portfolio-sync adds no unique tool capability. Would lose: dedicated routing-table keyword `portfolio/sync/readme stats` — move those keywords to docs. |
| email-drafter | haiku | 3 | skills=0, refs=2 | MERGE-INTO-docs | Role: draft email text. docs agent can draft communication artifacts equally well; email-drafter's only distinction is Gmail draft creation, which is not wired (no MCP). Would lose: Gmail-draft intent framing — low impact since it never fires. |
| standup-writer | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. Requires Todoist integration not wired. git-activity skill duplicated in morning-briefing which fires. Would lose: outward-facing standup format — morning-briefing covers the internal version; stakeholder format unused in 90d. |
| task-triage | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. Requires Todoist MCP not wired in active stack. Would lose: Todoist inbox triage; not exercised in 90 days, no integration path in current sprint. |
| meeting-prep | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. Requires Google Calendar MCP not wired. Would lose: pre-meeting brief generation; unblockable without calendar integration. |
| adr-writer | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. No slash command. Routing-table wired but keyword `adr/architecture decision` never fired. Would lose: structured ADR format authoring — researcher + docs covers this on demand. |
| pr-narrator | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. No wiring beyond routing-table. Would lose: stakeholder-friendly PR summary format — researcher can produce equivalent prose when asked. |
| knowledge-curator | haiku | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. Requires Obsidian vault path. Would lose: orphan-note detection and MOC generation — not relevant to current active projects (CAST, dashboard). |
| learning-scout | sonnet | 0 | skills=0, refs=2 | RETIRE | Zero dispatches. Sonnet cost, no trigger in 90 days. Would lose: structured learning note generation — researcher covers on-demand topic research. |

---

## Phase 4.5 Priority Order

Execute retire/merge in this sequence to minimize disruption:

### Tier 1 — Safe Retire (no integration deps, role covered)
1. **standup-writer** — morning-briefing covers git activity; standup format unused
2. **pr-narrator** — researcher produces equivalent prose on demand
3. **knowledge-curator** — Obsidian workflow not active; no routing path
4. **learning-scout** — researcher handles topic research; sonnet cost with zero ROI

### Tier 2 — Retire with routing-table cleanup
5. **adr-writer** — remove `adr/architecture decision` from routing-table or redirect to researcher
6. **task-triage** — remove `triage/inbox/todoist` routing keywords (no integration)
7. **meeting-prep** — remove `meeting/prep/calendar` routing keywords (no integration)

### Tier 3 — Merge (requires routing-table keyword migration)
8. **email-drafter** → docs — move `email/draft/compose/reply/gmail` keywords to docs
9. **portfolio-sync** → docs — move `portfolio/sync/readme stats` keywords to docs

### Tier 4 — Watch/Defer
- **migration-reviewer**, **api-contract**, **release-notes**: keep for one more 30-day window. If still zero, re-evaluate. Retirement cost is low (haiku/sonnet), recovery cost if needed is medium.

---

## Impact Summary

| Disposition | Count | Net effect |
|---|---|---|
| KEEP | 18 | No change |
| EVALUATE | 3 | Watch 30d, then decide |
| MERGE-INTO | 2 | Collapse into docs; move routing keywords |
| RETIRE | 7 | Remove files + routing-table entries |
| **Total cuts** | **9** | **30 → 21 agents** |

Sources:
- Pinned 90-day dispatch baseline (`/tmp/cast-v7-phase4-agent-baseline.txt`)
- Agent frontmatter: `agents/core/*.md`, `agents/personal/portfolio-sync.md`
- `config/chain-map.json` — successor chain wiring
- `config/routing-table.json` — keyword-to-agent routing
- `~/.claude/skills/` — skill-level dispatch references
- `~/.claude/commands/` — slash command wiring
