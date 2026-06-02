# CAST v8 Phase 0.4 — Tauri Architecture Decision

**Date:** 2026-05-11
**Inputs:** `v8-phase-0-dashboard-state.md`, `v8-phase-0-forge-state.md`, v8 master plan (internal planning doc)
**Decision-maker on record:** Ed (this doc is the recommendation + reasoning)

---

## Decision (recommended)

**Adopt Option C — Express as Tauri sidecar, Express serves both `dist/` static and `/api/*`. Single sidecar process. Tauri webview points at `http://localhost:<port>/`.**

Defer Rust-port of Express routes to v8.1+ as selective optimization, not a v8.0 prerequisite.

Why: v8 is the visibility move, not the rewrite move. Express + better-sqlite3 is a year of working code; throwing it away costs months and adds bugs. Tauri's `externalBin` sidecar pattern is well-trodden. Bundle-size cost (~50–80 MB Node binary) is acceptable for solo desktop tooling — Docker Desktop ships 1 GB+ and nobody flinches.

---

## The fork — three options

### Option A — Express as sidecar; Tauri webview loads bundled `dist/`
- Tauri serves React static assets from its own webview.
- Express runs as `externalBin` sidecar on a localhost port. React calls `http://localhost:<port>/api/*` (absolute URL).
- **Pros:** Clean Tauri-native asset loading. Sidecar isolated. SSE works.
- **Cons:** CORS surface (webview origin ≠ Express origin). CSP must allow `connect-src http://localhost:<port>` (currently `default-src 'self'` only — Forge's existing CSP needs widening). Dashboard's relative `/api/*` URLs must become absolute via `VITE_API_URL` at build.

### Option B — Reimplement all ~40 Express routes as Rust `#[tauri::command]` functions
- Drop Express entirely. Use `rusqlite` for cast.db. SSE becomes Tauri `emit`/`listen` events (native).
- **Pros:** Smaller binary (~20 MB instead of ~80 MB). Faster cold start. Single process. SSE becomes natural Tauri events. Forge already proved the pattern works (`cast_detect`, `cast_query_recent_runs`, `cast_query_stats` are Rust-side calls into cast.db).
- **Cons:** Massive rewrite. ~40 routes × hours each = months. better-sqlite3 features (prepared statement caching, transactions, JSON1) need Rust equivalents. File-reading routes (`/api/memory`, `/api/plans`, `/api/rules`, etc.) all need Rust ports too — 30+ filesystem-reading endpoints. Every route is a regression risk. v8.0 ships months later.

### Option C — Express as sidecar; Express serves BOTH `dist/` static AND `/api/*`. Tauri webview = `http://localhost:<port>/` (RECOMMENDED)
- Add `app.use(express.static('dist'))` to Express. Tauri webview points at `http://localhost:<port>/` instead of bundled assets.
- React's existing relative `/api/*` URLs work unchanged — same-origin.
- One sidecar process. One port. No CORS, no CSP widening, no env-var build dance.
- **Pros:** Smallest delta from current state. Dashboard's 8 pages work as-is. SSE works. Vite proxy dependency disappears (Express IS the server in production). The dashboard auditor's recommendation, verbatim.
- **Cons:** Webview is "localhost browser tab," not native shell — loses some Tauri benefits (faster IPC for hot paths). But: Tauri commands for PTY (Forge's `pty_create`/`pty_write`/`pty_resize`) still go through native IPC; only Express routes go through HTTP. Hybrid is the result, but it's *natural* hybrid, not bolted-on.

---

## Comparison

| Dimension | A (sidecar + bundled dist) | B (full Rust port) | C (sidecar serves dist + api) |
|---|---|---|---|
| Code changes to dashboard | Medium (absolute URLs, CSP, CORS) | Total rewrite of ~40 routes | Minimal (add `express.static`) |
| Code changes to Forge | Medium (Tauri shell rebuild) | Total rewrite | Medium (Tauri shell rebuild) |
| Bundle size | ~80 MB (Node sidecar) | ~20 MB (no Node) | ~80 MB (Node sidecar) |
| Cold start | ~500ms (Express spawn) | <100ms | ~500ms (Express spawn) |
| SSE / streaming | Works (HTTP) | Native (Tauri events) | Works (HTTP) |
| PTY (Forge terminal pane) | Native Tauri IPC | Native Tauri IPC | Native Tauri IPC |
| Time to v8.0 ship | ~2–3 weeks integration | 3–6 months | ~1–2 weeks integration |
| Regression risk | Medium | High (40 ports × bugs) | Low |
| Path to native Rust later | Same as C | Already there | Open — migrate hot paths in v8.1+ |

---

## Recommended path — Option C, concretely

1. **Add static serving to dashboard's Express:** in `server/index.ts`, `app.use(express.static(path.join(__dirname, '../dist')))` + SPA fallback `app.get('*', (req, res) => res.sendFile('dist/index.html'))`.
2. **Build dashboard:** `npm run build` produces `dist/` (1.5 MB, verified clean).
3. **Bundle Node + Express + dist/ as Tauri sidecar:** use `bun build --compile` or `pkg` to produce a single-binary `cast-server` (~50–80 MB depending on packager). Drop into Forge's `src-tauri/binaries/`.
4. **Wire `externalBin` in `tauri.conf.json`:** Tauri spawns `cast-server` on app start, kills on app exit.
5. **Point Tauri window at `http://localhost:<port>/`:** in `tauri.conf.json`, `windows[0].url` = the sidecar URL.
6. **Forge's PTY stack stays as-is:** `pty.rs`, `useTerminal.ts`, `TerminalPane.tsx` already work via native Tauri IPC. Just add a terminal pane to the dashboard layout.
7. **Voice MVP (Phase 2) plugs in cleanly:** push-to-talk Tauri binding → Whisper → invokes dashboard `/api/*` or PTY input. Doesn't interact with the sidecar architecture.

---

## Bundle size + ship-cost reality check

| Reference | Size |
|---|---|
| Forge release binary (current) | ~30 MB |
| Node 22 standalone binary | ~50 MB |
| Express + dependencies | ~5 MB |
| Dashboard `dist/` | 1.5 MB |
| **Estimated v8 .dmg** | **~80–100 MB** |
| Docker Desktop .dmg (reference) | 1.4 GB |
| Postman .dmg (reference) | 400 MB |
| VS Code .dmg (reference) | 350 MB |

v8 at ~100 MB is *small* in this category. Not a constraint worth optimizing for in v8.0.

---

## Migration path (v8.1+, post-ship)

The hot paths most worth porting to native Rust commands (when v8.0 has shipped and there's usage data):

1. `/api/hook-events/stream` (SSE) → Tauri `emit`. Eliminates HTTP roundtrip for live event push.
2. `/api/work-log-stream` (currently polled) → Tauri event stream. Saves dashboard's polling overhead.
3. `/api/cast/explore` (SQLite query passthrough) → Rust `rusqlite` command. Forge already has the pattern.

The COLD paths (file-reading `/api/memory`, `/api/plans`, `/api/rules`, etc.) stay in Express forever — there's zero benefit to porting them and significant rewrite cost.

This is the natural-hybrid endgame: Rust for native concerns (PTY, hot streams, system queries), Express for filesystem traversal and database CRUD. Option C *starts* in this shape; v8.1+ migrates the boundary.

---

## Master-plan gap notes (Phase 0.1 fold-in)

The v8 master plan (internal planning doc, written 2026-05-09) drifts from reality and from tonight's framing in five places:

1. **Dashboard page list is stale.** Plan lists 10 pages; reality is 8 stable + 2 newer (`/docs`, `/swarm`, `/work-log`). Six of the plan's "pages" are now redirects absorbed into `/system`/`/sessions`/`/analytics`. Plan should sync after this audit.

2. **Forge is mis-classified as "in progress."** Reality: ~85% complete, on `forge-v1-archive-final` branch, with both debug and release binaries built locally. It's *paused after near-completion*, not in-flight. The salvageable artifact (PTY stack + xterm.js hooks + 6 themes + Flame mascot) is larger and cleaner than the plan implies.

3. **The terminal-main, dashboard-sidebar framing is inverted by the visibility-move reframe.** Plan says "terminal main pane, dashboard side pane." Visibility-move framing says the dashboard IS the watchable runtime; the terminal is a side pane you can drop into if you want. This is a UX call Ed should make explicit before Phase 1 — not blocking, but worth surfacing.

4. **Phase 6 (Memory v2 + Reliability layer) adds dependencies and changes data model.** Vector DB, embedding model, observer process — all worthwhile, none aligned with "visibility move." Recommend deferring Phase 6 to v8.1, keeping v8.0 the pure visibility-and-ship play. The marketing push works without Memory v2.

5. **AI conversation parsing in Forge is the one artifact to discard, not adapt.** Plan doesn't address this. Reality: the WIP parser work paused 2026-04-20 should be dropped — dashboard's `/sessions` view already covers agent observability from cast.db.

---

## Open questions for Ed

1. **Sidecar packager choice:** `bun build --compile` (fast, modern, smaller binaries) vs `pkg` (mature, larger output, broader Node compat). Recommend bun; fallback pkg if bun fails on better-sqlite3 native bindings.
2. **First-paint UX:** dashboard `/` or a v8-specific landing surface? Plan didn't specify.
3. **Terminal pane positioning:** main pane (Forge's framing) vs side pane / collapsible drawer (visibility-move framing)? Recommend collapsible drawer — runtime visibility is the headline.
4. **Memory v2 scope for v8.0:** keep deferred (recommended), or pull forward one piece (e.g. vector DB) to anchor the marketing story? Recommend keep deferred.
5. **Voice MVP in v8.0 or v8.1?** Plan says v8.0 with push-to-talk-only. Reasonable. Confirm.

---

## Status

DONE_WITH_CONCERNS

Concerns:
- The recommendation (Option C) is a strong default but assumes Ed is fine with the ~80 MB bundle and the sidecar-process model. If he wants a smaller binary or single-process architecture from day one, Option B's rewrite scope must be priced honestly (months, not weeks).
- The master-plan gap on Phase 6 (Memory v2) is a real scope question. v8.0 vs v8.1 is Ed's call.
- Terminal-as-main vs terminal-as-side is the UX call that most shapes Phase 1's first concrete sprint.

---

Sources verified during this decision:
- `claude-code-dashboard/server/constants.ts` — Express paths, CAST_DB location
- `claude-code-dashboard/server/index.ts` — confirmed no `express.static` yet
- `forge/src-tauri/tauri.conf.json` — Tauri v2 config, frontendDist pattern, CSP currently `default-src 'self'`
- `forge/src-tauri/Cargo.toml` — Tauri 2.10.3, portable-pty 0.8
- Both Phase 0 audit reports (above)
