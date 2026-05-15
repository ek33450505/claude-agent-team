# CAST v8 Phase 0.2 — Dashboard State Audit

**Date:** 2026-05-11
**Repo:** `~/Projects/personal/claude-code-dashboard` (React 19 + Vite + TypeScript / Express 5 + better-sqlite3)
**Auditor:** researcher agent (read-only)

---

## Summary

- **8 live pages** (not 10). The master plan's route list is stale — several pages were consolidated into redirects. `/docs` and `/swarm` are present pages not in the plan.
- **~40 API route modules** mounted under `/api/`; at least 6 have write paths into `cast.db`. This is a v8 concern.
- **Build: 1.5 MB total, 1.37 MB JS uncompressed** (420 KB vendor-charts alone). Fits Tauri, but chunk size warrants review.
- **No hardcoded `localhost:` URLs in frontend source** — all API calls proxy through Vite's `/api` prefix, which must be resolved differently in Tauri (Tauri webview has no Vite dev proxy).
- **`/work-log` shipped** (commit `c22075d`, most recent) — confirms v8's "live runtime visibility" thesis is already surfaced in the dashboard.

---

## Page Inventory

| Route | File | Classification | Notes |
|---|---|---|---|
| `/` | `HomeView.tsx` (378 LOC) | stable | Activity hub, cast.db live stats |
| `/sessions` | `SessionsView.tsx` (490 LOC) | stable | Absorbs /activity, /agent-runs, /dispatch-log, /routing |
| `/sessions/:project/:sessionId` | `SessionDetailView.tsx` (411 LOC) | stable | Session drill-down |
| `/analytics` | `AnalyticsView.tsx` (880 LOC) | stable | Absorbs /token-spend, /quality-gates |
| `/analytics/agents/:agent` | `AnalyticsAgentDetailView.tsx` (222 LOC) | stable | Agent detail drill-down |
| `/system` | `SystemView.tsx` (818 LOC) | stable | Absorbs /hooks, /memory, /plans, /db, /castd, /rules, /knowledge, /privacy |
| `/docs` | `DocsView.tsx` (350 LOC) | stable | Absorbs /commands |
| `/agents` | `AgentsView.tsx` (512 LOC) | stable | Agent roster; not in master plan's 10-page list |
| `/swarm` | `SwarmView.tsx` (224 LOC) | stable | Swarm control; not in master plan's 10-page list |
| `/work-log` | `WorkLogView.tsx` (29 LOC) | stable (thin shell) | NEW — live agent work-log stream; shipped most recently |
| `SqliteExplorerView.tsx` | (392 LOC) | orphaned | File exists, not in router; absorbed into /system redirect |

**Redirect-only routes** (no page behind them): `/activity`, `/dispatch-log`, `/routing`, `/agent-runs`, `/task-queue`, `/token-spend`, `/quality-gates`, `/hooks`, `/privacy`, `/db`, `/castd`, `/rules`, `/knowledge`, `/memory`, `/plans`, `/commands`, `/local-os/*`

---

## Backend API

Routes mounted under `/api/` (all via `server/routes/index.ts`):

| Mount path | Type | Notes |
|---|---|---|
| `/api/agents/live` | JSON | Live agent status |
| `/api/agents` | JSON | Agent roster from `~/.claude/agents/` |
| `/api/sessions` | JSON | Session listing/detail |
| `/api/analytics` | JSON | Token + agent analytics |
| `/api/routing` | JSON | Routing events |
| `/api/quality-gates` | JSON | Gate verdicts |
| `/api/dispatch-decisions` | JSON | Dispatch log |
| `/api/parry-guard` | JSON | Parry guard events |
| `/api/agent-truncations` | JSON | Truncation records |
| `/api/injection-log` | JSON | Injection log |
| `/api/unstaged-warnings` | JSON | Unstaged file warnings |
| `/api/cast/token-spend` | JSON | Token totals |
| `/api/cast/memories` | JSON + **WRITE** | `DELETE` memory by id |
| `/api/cast/task-queue` | JSON + **WRITE** | `DELETE` task by id |
| `/api/hook-events/stream` | **SSE** | Live hook events push |
| `/api/work-log-stream` | JSON (polled) | Agent work log feed; NOT SSE — React Query polling |
| `/api/control` | JSON + **WRITE** | Spawn agent runs, update status in cast.db |
| `/api/castd` | JSON + **WRITE** | castd start/stop control |
| `/api/cast/seed` | JSON + **WRITE** | Seed test data |
| `/api/budget` | JSON + **WRITE** | Budget table CREATE + read |
| `/api/cast/explore` | JSON | SQLite explorer (read-only) |
| `/api/swarm` | JSON + **WRITE** | Rate-limited; swarm control |
| `/api/memory`, `/api/plans`, `/api/rules`, `/api/skills`, `/api/scripts`, `/api/search`, `/api/config`, `/api/outputs`, `/api/keybindings`, `/api/tasks`, `/api/debug`, `/api/commands` | JSON | CAST runtime file reads |
| `/api/health` | JSON | Health check |

**SSE count: 1** (`/api/hook-events/stream`)
**Write-path routes: 6+** (control, castd, hook-events ingest, memories DELETE, task-queue DELETE, budget, seed)

---

## SQLite Access

- **DB path:** `~/.claude/cast.db` via `CAST_DB` constant (`server/constants.ts:26`)
- **Singleton handle:** `getCastDb()` — shared read-only connection, lazy-init, cached in module scope
- **Write handle:** `getCastDbWritable()` — opens a fresh read-write connection each call; **callers must close**
- **Read-only? No.** Write paths in: `control.ts` (INSERT agent_runs), `hookEvents.ts` (INSERT hook_events), `agentMemoriesDb.ts` (DELETE), `taskQueue.ts` (DELETE), `budgetStatus.ts` (CREATE TABLE + INSERT), `seed.ts` (INSERT sessions/runs for test data)
- **v8 concern:** The dashboard both reads and writes `cast.db`. v8 should audit which writes are essential vs. incidental (seed/budget likely dev-only; control/hookEvents are real).

---

## Build Output

- **Output dir:** `dist/` (not `build/`) — Vite default, no override in `vite.config.ts`
- **Total size:** 1.5 MB uncompressed, ~363 KB gzip (estimated from per-chunk gzip figures)
- **Largest chunks:** `vendor-charts` (420 KB), `index` bundle (331 KB), `vendor-motion` (142 KB)
- **Warnings:** None — clean build in 1.86s
- **Font assets:** 2 Geist variable font woff2 files (~44 KB total)

---

## Drift from Master Plan

| Master plan claim | Reality |
|---|---|
| 10 pages: /activity, /sessions, /analytics, /agents, /hooks, /plans, /memory, /system, /token-spend, /db | 8 live pages; /activity, /hooks, /plans, /memory, /token-spend, /db are all redirects absorbed into parent pages |
| /agents listed as a known page | Correct — stable |
| No mention of /docs, /swarm, /work-log | All three exist and are live pages |
| Dev: :5173 + :3001 | Correct |
| React 19 + Vite + Express 5 + better-sqlite3 | Correct |

---

## Blockers for v8 Absorption

1. **Vite proxy dependency (HIGH)** — All frontend API calls use relative `/api/...` paths relying on Vite's dev-server proxy (`proxy: { '/api': 'http://localhost:3001' }`). In production build inside a Tauri webview, the `dist/` static assets have no proxy. The Express server must be started separately and the frontend must point to it. Fix: configure absolute URL via `VITE_API_URL` env var at build time, or serve static assets from Express itself.

2. **Dual-server runtime requirement (HIGH)** — Tauri needs to manage both the static webview asset server and the Express API server as sidecar processes. The simplest path: serve `dist/` from Express directly (single process), then Tauri only manages one sidecar.

3. **Write paths into cast.db (MEDIUM)** — The dashboard writes to `cast.db` via 6+ routes. v8 should decide whether the dashboard retains write access or proxies through the CAST hook layer. The `seed` and `budget` routes are likely dev-only and can be gated.

4. **`/work-log` is a thin stub (LOW)** — `WorkLogView.tsx` is 29 lines; the real logic is in `WorkLogFeed` component and `useWorkLogStream` hook (React Query polling, not SSE). Functional but the page will need hardening for v8's "live runtime visibility" centrepiece role.

5. **`SqliteExplorerView.tsx` is orphaned (LOW)** — 392 LOC file with no route. Either absorb into `/system` for real or delete before bundling.

6. **Worktree branches stale (LOW)** — 15+ `worktree-agent-*` local branches have no remote tracking. Cosmetic noise; won't affect Tauri build but should be pruned per grooming policy.

---

## Recommendations

1. **Collapse to single-process for Tauri** — serve `dist/` from Express using `express.static()` and set `BASE_URL` via an env var so the Tauri shell only manages one sidecar. This resolves blockers 1 and 2 in a single move and is the cleanest Tauri integration pattern.

2. **Audit and gate write routes** — before Phase 1, run `grep -rn getCastDbWritable` and classify each call as dev-only (gatable) vs. runtime-required (keep). Reduces the write-surface audit scope for v8.

3. **Verify Forge state** — the master plan also calls for a Forge audit (Phase 0.1). Dashboard is clearly absorb-ready; whether the overall bundle is viable depends on Forge's state.

---

## Status

DONE_WITH_CONCERNS

Concerns: Dashboard is absorb-ready but has two high-priority Tauri blockers (Vite proxy dependency, dual-server runtime). Both are well-understood problems with known solutions — not blockers in the "stop work" sense, but they must be addressed before Phase 1 integration code starts.

---

Sources:
- `~/Projects/personal/claude-code-dashboard/src/App.tsx` — route config (verified)
- `~/Projects/personal/claude-code-dashboard/server/routes/index.ts` — API mount table (verified)
- `~/Projects/personal/claude-code-dashboard/server/routes/castDb.ts` — DB access layer (verified)
- `~/Projects/personal/claude-code-dashboard/server/constants.ts` — path/port constants (verified)
- `~/Projects/personal/claude-code-dashboard/vite.config.ts` — proxy config (verified)
- `~/Projects/personal/claude-code-dashboard/server/routes/workLogStream.ts` — work log stream route (verified)
- `npm run build` output — dist sizes verified in this session
