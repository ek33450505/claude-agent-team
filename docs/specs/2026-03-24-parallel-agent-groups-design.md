# CAST Parallel Agent Groups — Design Spec
**Date:** 2026-03-24
**Version:** 1.0
**Status:** Historical / Superseded by CAST v3

> **Note (2026-03-28):** This spec describes the parallel agent groups feature designed for CAST v2. In the v3 lean architecture redesign, the routing table (`routing-table.json`), agent groups (`agent-groups.json`), and `route.sh` were all removed. CAST v3 uses model-driven dispatch via a CLAUDE.md dispatch table — the model reads 15 rows and decides which agent to call. This document is preserved for historical context only.

---

## Context

CAST v1.5.0 routes every user prompt to a single specialist agent. This works well for isolated tasks but leaves compound developer intents underserved — prompts like "implement user authentication", "pre-release check", or "ship it" naturally call for multiple agents working simultaneously. The orchestrator already supports parallel batch execution via Agent Dispatch Manifests, but it requires a planner to generate the manifest first.

This spec defines **Parallel Agent Groups** — a curated catalog of compound dispatch configurations that fire automatically from the `UserPromptSubmit` hook, skip the planner intermediary, and run multi-wave parallel agent batches through the existing orchestrator infrastructure.

**Goals:**
- Cover a web developer's complete daily workflow — not just code writing
- Use all 35 agents (31 existing + 4 new)
- Zero slash commands — fully automatic like existing routing
- Wave-based execution: parallel agents within each wave, wave output feeds the next wave
- Clean agent folder structure with a new `specialist/` tier

---

## Architecture

### Data Flow

```
User Prompt
    │
    ▼
route.sh (UserPromptSubmit hook)
    │
    ├─ Check agent-groups.json first
    │   └─ Group match → [CAST-DISPATCH-GROUP: <name>] + serialized wave payload
    │
    └─ Fall back to routing-table.json
        ├─ Route match → [CAST-DISPATCH] (existing single-agent path)
        └─ No match → Claude inline
                │
                ▼
    CLAUDE.md handles [CAST-DISPATCH-GROUP]:
        → Auto-generate inline manifest from wave payload
        → Pass to orchestrator (no approval gate — groups are pre-vetted)
        → Orchestrator runs waves: parallel agents within wave, output feeds next wave
        → Fan-out Summary between waves
        → Post-chain (code-reviewer, commit, push) runs as final sequential batches
```

### Key Design Decisions

1. **Groups check before routes** — a group match short-circuits single-agent routing entirely
2. **No approval gate** — groups are pre-vetted at catalog build time; orchestrator runs immediately
3. **Wave-based, not flat fan-out** — wave 1 output is synthesized and prepended to wave 2 prompts
4. **Reuses orchestrator infrastructure** — no new execution engine needed; manifest is generated inline
5. **Max 4 agents per wave** — enforced by protocol spec constraint

---

## New Directive: `[CAST-DISPATCH-GROUP]`

Added to `CLAUDE.md.template` directive table:

```
[CAST-DISPATCH-GROUP: <group-name>]
  Payload: JSON object in additionalContext with keys: waves[], post_chain[], pre_approved: true
  Action:  Translate the waves payload into an Agent Dispatch Manifest and pass to orchestrator.
           Because pre_approved: true is set, orchestrator skips its approval gate and runs immediately.

  Manifest translation rules:
    - Each wave becomes one batch entry (id = wave.id, description = wave.description, parallel = wave.parallel)
    - Each agent name in wave.agents becomes one { subagent_type, prompt } entry
    - Wave 1 agent prompts = original user prompt
    - Wave N (N > 1) agent prompts = original user prompt + "Context from previous wave: <Fan-out Summary>"
    - post_chain agents become final sequential batches (parallel: false, one agent per batch)
    - Set pre_approved: true in the manifest root so orchestrator skips the queue presentation step

  Do NOT: handle inline, ask for confirmation, generate the manifest manually without orchestrator.
```

### Orchestrator `pre_approved` flag

`orchestrator.md` must be updated to check for `pre_approved: true` at the manifest root:
- If present and `true`: skip Step 2 (Present Queue / wait for user approval), execute immediately from Step 3
- If absent or `false`: existing behavior (present queue, wait for approval)

This resolves the conflict between the existing `[CAST-ORCHESTRATE]` approval-gate contract and the group dispatch no-gate intent.

---

## `config/agent-groups.json` Schema

```json
{
  "version": "1.0",
  "groups": [
    {
      "id": "feature-build",
      "description": "Full feature implementation with planning, testing, docs, and security",
      "patterns": ["implement", "add feature", "build .+", "create .+ component"],
      "confidence": "soft",
      "waves": [
        {
          "id": 1,
          "description": "Planning and research",
          "parallel": true,
          "agents": ["planner", "researcher"]
        },
        {
          "id": 2,
          "description": "Implementation wave",
          "parallel": true,
          "agents": ["test-writer", "security", "doc-updater"]
        }
      ],
      "post_chain": ["code-reviewer", "commit"]
    }
  ]
}
```

### Schema Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Unique group identifier, kebab-case |
| `description` | string | yes | Human-readable label shown in dispatch queue |
| `patterns` | string[] | yes | Regex patterns matched against lowercased prompt |
| `confidence` | "hard"\|"soft" | yes | hard = always dispatch; soft = recommended |
| `waves` | Wave[] | yes | Ordered execution waves (1-N) |
| `post_chain` | string[] | no | Sequential agents run after all waves complete |

### Wave Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | integer | yes | Monotonically increasing wave number |
| `description` | string | yes | Label for dispatch queue display |
| `parallel` | boolean | yes | true = all agents run simultaneously |
| `agents` | string[] | yes | Agent names (max 4 per wave) |

---

## route.sh Changes

Add group matching block **before** the existing routing-table.json loop:

```bash
# --- Check agent-groups.json first ---
GROUPS_FILE="$(dirname "$0")/../config/agent-groups.json"
if [ -f "$GROUPS_FILE" ]; then
  # Pass values via env vars (same safe pattern as existing route.sh) to avoid
  # shell interpolation bugs when group JSON contains single quotes.
  CAST_GROUPS_FILE="$GROUPS_FILE" \
  CAST_PROMPT_VAL="$ORIGINAL_PROMPT" \
  CAST_SESSION_ID="${CLAUDE_SESSION_ID:-unknown}" \
  python3 -c "
import json, re, sys, os, datetime

groups_file = os.environ['CAST_GROUPS_FILE']
prompt = os.environ['CAST_PROMPT_VAL'].lower()
session_id = os.environ['CAST_SESSION_ID']

try:
    groups = json.load(open(groups_file)).get('groups', [])
except Exception:
    sys.exit(0)

for group in groups:
    for pattern in group.get('patterns', []):
        if len(pattern) > 200:
            continue  # ReDoS guard
        try:
            if re.search(pattern, prompt):
                payload = {
                    'waves': group['waves'],
                    'post_chain': group.get('post_chain', []),
                    'pre_approved': True   # skips orchestrator approval gate
                }
                directive = '[CAST-DISPATCH-GROUP: ' + group['id'] + ']\n'
                directive += 'Payload: ' + json.dumps(payload)
                print(json.dumps({'hookSpecificOutput': {'additionalContext': directive}}))

                log = {
                    'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
                    'session_id': session_id,
                    'prompt': os.environ['CAST_PROMPT_VAL'][:200],
                    'matched': 'group:' + group['id'],
                    'confidence': group.get('confidence', 'soft'),
                    'wave_count': len(group['waves'])
                }
                log_path = os.path.expanduser('~/.claude/routing-log.jsonl')
                with open(log_path, 'a') as f:
                    f.write(json.dumps(log) + '\n')
                sys.exit(0)
        except re.error:
            continue
" 2>/dev/null && exit 0
fi
# --- Fall through to existing routing-table.json logic ---
```

---

## CLAUDE.md.template Changes

Add to the Hook Directives section:

```markdown
- **`[CAST-DISPATCH-GROUP: <group-id>]`** — Auto-generate an Agent Dispatch Manifest
  from the Payload JSON in the directive. Pass immediately to orchestrator with no
  approval gate. Orchestrator runs waves in order: parallel agents fire simultaneously,
  Fan-out Summary is prepended to the next wave's prompts, post_chain agents run
  sequentially after all waves complete.
  Do NOT ask for confirmation. Do NOT handle inline. Do NOT skip orchestrator.
```

---

## New Agents (4) — `agents/specialist/`

### `devops.md`
- **Tier:** specialist
- **Model:** sonnet
- **Role:** CI/CD pipeline management, Docker/containerization, GitHub Actions workflow authoring, infrastructure-as-code (Terraform, CloudFormation stubs), deployment configuration, environment management
- **Self-dispatch chain:** → security → code-reviewer → commit
- **Triggers from groups:** `ship-it`, `devops-setup`, `pre-release`

### `performance.md`
- **Tier:** specialist
- **Model:** sonnet
- **Role:** Core Web Vitals analysis, Lighthouse audit interpretation, bundle size analysis, caching strategy recommendations, lazy loading, image optimization, rendering performance
- **Self-dispatch chain:** → code-reviewer → commit
- **Triggers from groups:** `performance-audit`, `pre-release`

### `seo-content.md`
- **Tier:** specialist
- **Model:** haiku
- **Role:** SEO meta tag generation, structured data (JSON-LD), accessibility audits (WCAG 2.1), localization/i18n setup, CMS content strategy, Open Graph tags, sitemap recommendations
- **Self-dispatch chain:** → code-reviewer → commit
- **Triggers from groups:** `seo-sprint`

### `linter.md`
- **Tier:** specialist
- **Model:** haiku
- **Role:** ESLint/Prettier configuration, code style enforcement, formatting standards, import ordering, simple reflex code quality tasks that don't require full code-reviewer analysis
- **Self-dispatch chain:** → commit
- **Triggers from groups:** `quality-sweep`, `security-audit`

---

## Agent Folder Restructuring

### Current Problems
- `agents/commit.md` and `agents/planner.md` duplicate `agents/core/commit.md` and `agents/core/planner.md` (causes 33 vs 31 count discrepancy in gen-stats.sh)
- `agents/bash-specialist.md` is orphaned at root level

### Target Structure

```
agents/
├── core/            (10 agents)
│   planner, debugger, test-writer, code-reviewer, commit,
│   push, security, bash-specialist, data-scientist, db-reader
│
├── extended/        (8 agents)
│   architect, tdd-guide, build-error-resolver, e2e-runner,
│   refactor-cleaner, doc-updater, readme-writer, router
│
├── specialist/      (4 NEW agents)
│   devops, performance, seo-content, linter
│
├── orchestration/   (5 agents)
│   orchestrator, auto-stager, chain-reporter, verifier, test-runner
│
├── productivity/    (5 agents)
│   researcher, report-writer, meeting-notes, email-manager, morning-briefing
│
└── professional/    (3 agents)
    browser, qa-reviewer, presenter
```

### Baseline Counts (pre-migration)
- `tests/install.bats` currently asserts 30 agents installed (full install)
- After migration + 4 new specialist agents: full install target = **35 agents**
- `install.bats` must update assertion from 30 → 35

### Migration Steps
1. Move `agents/bash-specialist.md` → `agents/core/bash-specialist.md`
2. Delete `agents/commit.md` (duplicate of `agents/core/commit.md`)
3. Delete `agents/planner.md` (duplicate of `agents/core/planner.md`)
4. Create `agents/specialist/` directory with 4 new agent files
5. Update `install.sh`: add `SPECIALIST_AGENTS` list, include in Full + Custom menus
6. Update `CLAUDE.md.template` agent registry table — add ALL currently missing agents:
   `tdd-guide`, `build-error-resolver`, `e2e-runner`, `refactor-cleaner`, `doc-updater`,
   `readme-writer`, `router`, `orchestrator`, `auto-stager`, `chain-reporter`, `verifier`,
   `test-runner`, `researcher`, `report-writer`, `meeting-notes`, `email-manager`,
   `morning-briefing`, `browser`, `qa-reviewer`, `presenter`, `bash-specialist`, `push`,
   plus 4 new specialist agents
7. Update `orchestrator.md` to handle `pre_approved: true` manifest flag
8. Run `gen-stats.sh` to sync README counts (target: 35 agents)

---

## Full Group Catalog (28 groups)

### Morning & Planning (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `morning-start` | "good morning", "start my day", "daily briefing" | morning-briefing + chain-reporter | report-writer | — | — |
| `sprint-kickoff` | "start sprint", "sprint planning", "new sprint" | meeting-notes + planner | report-writer | — | email-manager |
| `project-brief` | "new project", "scope this", "kick off" | researcher + architect | planner | — | doc-updater → commit |

### Feature Development (4)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `feature-build` | "implement", "add feature", "build .+" | planner + researcher | test-writer + security + doc-updater | — | code-reviewer → commit |
| `ui-build` | "build ui", "front.?end", "new component", "design.*page" | planner + researcher | test-writer + e2e-runner | qa-reviewer | code-reviewer → commit |
| `backend-build` | "api endpoint", "back.?end", "server.*route", "database.*feature" | planner + architect | test-writer + security + db-reader | — | code-reviewer → commit |
| `api-integration` | "integrate.*api", "connect.*service", "third.?party" | researcher + architect | test-writer + security | — | code-reviewer → commit |

### Debugging & Performance (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `fix-and-ship` | "fix and (commit\|ship\|push)", "debug and ship" | debugger | test-writer + code-reviewer | — | commit |
| `performance-audit` | "performance", "slow.*app", "optimize.*speed", "core web vitals" | performance + browser | data-scientist | — | report-writer |
| `cross-browser` | "cross.?browser", "browser compat", "safari.*issue", "firefox.*broken" | e2e-runner + browser | qa-reviewer | — | report-writer → commit |

### Testing (2)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `test-suite` | "write.*test suite", "full.*test coverage", "tdd.*feature" | tdd-guide + planner | test-writer + e2e-runner | — | test-runner → code-reviewer → commit |
| `full-test` | "run.*all.*tests", "test everything", "full.*regression" | test-runner + e2e-runner | qa-reviewer | — | report-writer |

### Code Quality & Maintenance (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `quality-sweep` | "audit", "full review", "code.*quality", "pre.?release check" | security + code-reviewer + qa-reviewer + linter | — | — | report-writer |
| `refactor-sprint` | "refactor.*everything", "clean.*codebase", "tech.*debt" | refactor-cleaner + code-reviewer | test-runner + doc-updater | — | commit |
| `security-audit` | "security audit", "owasp.*scan", "vuln.*check" | security + linter | qa-reviewer + code-reviewer | — | report-writer → email-manager |

### Architecture & Research (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `tech-spike` | "research.*option", "compare.*approach", "evaluate.*librar", "tech.*spike" | researcher + browser | architect | — | report-writer |
| `adr-session` | "architecture.*decision", "adr", "design.*system" | architect + researcher | — | — | doc-updater → commit |
| `dependency-audit` | "check.*dependencies", "npm audit", "upgrade.*packages" | researcher + security + browser | — | — | report-writer |

### Documentation & Communication (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `doc-sprint` | "update.*all.*docs", "document.*everything", "full.*documentation" | doc-updater + readme-writer | — | — | code-reviewer → commit |
| `client-update` | "client.*update", "status.*report.*client", "project.*summary" | chain-reporter + report-writer | presenter | — | email-manager |
| `meeting-debrief` | "meeting.*notes", "debrief.*meeting", "action.*items.*from" | meeting-notes | report-writer | — | email-manager |

### Data & Database (2)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `data-analysis` | "analyze.*data", "data.*insight", "query.*and.*report" | db-reader + data-scientist | — | — | report-writer |
| `db-migration` | "database.*migration", "schema.*change", "migrate.*table" | db-reader + architect | security + test-writer | — | code-reviewer → commit |

### DevOps & Infrastructure (2)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `devops-setup` | "ci.*cd", "github.*action", "dockerfile", "deploy.*config", "pipeline" | devops + architect | security + doc-updater | — | code-reviewer → commit |
| `seo-sprint` | "seo", "meta.*tag", "accessibility", "wcag", "locali[sz]ation" | seo-content + browser + performance | — | — | code-reviewer → commit |

### Deployment & Release (3)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `ship-it` | "ship it", "ready.*deploy", "release.*this", "go.*live" | verifier + test-runner + devops | — | — | auto-stager → commit → push |
| `hotfix` | "hotfix", "urgent.*fix", "prod.*broken", "critical.*bug" | debugger + security | test-writer + verifier | — | commit → push |
| `pre-release` | "pre.?release", "release.*candidate", "final.*check.*before" | security + e2e-runner + qa-reviewer + performance | devops | — | report-writer → commit → push |

### End of Day (2)
| ID | Triggers | Wave 1 | Wave 2 | Wave 3 | Post-chain |
|---|---|---|---|---|---|
| `daily-wrap` | "end of day", "daily standup", "what did.*today", "wrap.*up" | chain-reporter + verifier | report-writer | — | — |
| `pr-review` | "review.*pr", "review.*pull request", "check.*pr" | code-reviewer + security + qa-reviewer | — | — | report-writer |

---

## install.sh Updates

Add `SPECIALIST_AGENTS` list:
```bash
SPECIALIST_AGENTS="devops performance seo-content linter"
```

Add specialist tier to Full install and Custom install menus.

Add `config/agent-groups.json` to the config copy step.

Update menu text: "Full install — all 35 agents, 32 commands, ..."

---

## gen-stats.sh Updates

The agent count fix (subdir agents + bash-specialist) needs updating:
```bash
# After restructure, bash-specialist moves to core/ — count all subdir agents only
AGENT_COUNT=$(find "$REPO_DIR/agents" -mindepth 2 -name "*.md" | wc -l | tr -d ' ')
```

---

## New BATS Tests Required

- `tests/agent-groups.bats` — validate agent-groups.json schema, pattern syntax, wave structure
- `tests/route.bats` — add tests for group match short-circuiting before route match
- `tests/install.bats` — update agent count assertions to 35

---

## Files to Create / Modify

| File | Action |
|---|---|
| `config/agent-groups.json` | **NEW** — 28 group definitions |
| `scripts/route.sh` | **MODIFY** — add group pre-check block |
| `CLAUDE.md.template` | **MODIFY** — add `[CAST-DISPATCH-GROUP]` directive |
| `agents/specialist/devops.md` | **NEW** |
| `agents/specialist/performance.md` | **NEW** |
| `agents/specialist/seo-content.md` | **NEW** |
| `agents/specialist/linter.md` | **NEW** |
| `agents/core/bash-specialist.md` | **MOVE** from `agents/bash-specialist.md` |
| `agents/commit.md` | **DELETE** (duplicate) |
| `agents/planner.md` | **DELETE** (duplicate) |
| `install.sh` | **MODIFY** — add specialist tier, update counts |
| `scripts/gen-stats.sh` | **MODIFY** — update agent counting after restructure |
| `tests/agent-groups.bats` | **NEW** |
| `tests/route.bats` | **MODIFY** — add group routing tests |
| `tests/install.bats` | **MODIFY** — update count assertions to 35 |
| `agents/orchestration/orchestrator.md` | **MODIFY** — add `pre_approved: true` flag handling (skip approval gate) |
| `docs/cast-protocol-spec.md` | **MODIFY** — add `[CAST-DISPATCH-GROUP]` section |

---

## Verification

1. `bash scripts/gen-stats.sh` → shows 35 agents
2. `echo "implement user auth" | bash scripts/route.sh` → emits `[CAST-DISPATCH-GROUP: feature-build]`
3. `echo "fix a bug" | bash scripts/route.sh` → emits `[CAST-DISPATCH: debugger]` (no group match, falls through to single-agent route)
4. `bash scripts/cast-validate.sh` → all 6 checks pass
5. `tests/bats/bin/bats tests/` → all tests pass including new agent-groups.bats
6. In Claude Code: type "ship it" → CAST auto-dispatches `ship-it` group without any slash command
