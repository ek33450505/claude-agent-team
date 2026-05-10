# CAST v8 — Desktop App Master Plan

**Status:** Forward-planning document. v7 must ship first.
**Created:** 2026-05-09 (during Phase 4 session — captured the strategic conversation before it faded)
**Author:** Ed + Claude conversation, transcribed and structured

---

## The thesis in one paragraph

CAST v8 bundles three started-projects-that-already-point-at-this-shape into one shippable desktop product: **Forge** (Tauri v2 + React + xterm.js terminal — 8-phase plan, in progress), **claude-code-dashboard** (mature React 19 + Vite + Express observability UI), and a new **voice layer**. The pitch: "an OS app for Claude Code power users — terminal, agent dashboard, voice-driven dispatch, all in one bundle." This is the moment CAST graduates from "Ed's personal workshop" to "thing other developers install and use." The team-sharing / SaaS pivot is v9 territory and depends on v8 landing as a working solo product first.

---

## Why v8, not v7

v7 is honest technical depth — agent inventory, token optimization, hook contracts, BATS coverage, fewer-but-better team. It's a portfolio piece for technical reviewers. **v7 should ship cleanly without scope creep.** Bolting a desktop app onto v7 is exactly the "build up, not laterally" anti-pattern Ed rejected on 2026-05-09. v7 finishes; v8 starts.

The Engram lesson reinforces this: v0.8.0 shipped, then a pivot, then private repo — that's what happens when product ambition gets bolted onto a technical release mid-flight. Don't repeat.

The marketing math also works better with one bigger push at v8 than two narrower pushes at v7 + v8. v7's release notes go on the README and Homebrew tap; v8's release gets the LinkedIn announcement, the dev.to series, the demo video, the HackerNews show-and-tell, the Anthropic Discord drop. Phase 6.6 of v7 explicitly defers all of these.

---

## What v8 is NOT (scope guardrails)

- **Not a SaaS.** Local-first, single-user. Same architectural posture as the rest of the CAST ecosystem. SaaS / team-sharing is a v9+ pivot decision that requires its own master plan.
- **Not a Claude Code replacement.** Claude Code (the CLI) remains the engine. v8 is a wrapper that adds terminal UX, dashboard surface, voice input. The Claude Agent SDK does the heavy lifting; v8 is the host process and UX.
- **Not a from-scratch build.** Three started projects merging is the value prop AND the constraint. If we discover one of the three is unsalvageable, kill it — but no greenfield "let's rewrite Forge in $NEW_FRAMEWORK" temptations.
- **Not a v7 deliverable.** Said three times because it matters.

---

## The three components

### Component 1: Forge (terminal)
- **Current state:** Tauri v2 + React + xterm.js, 8-phase plan, "in progress." Per `project_forge.md`. Standalone repo.
- **Mascot:** "Flame" (warm fire colors per `feedback_forge_theme.md`).
- **v8 ask:** Finish whatever's incomplete, then host the dashboard webview as a sidebar/panel. Probably means the Tauri app gets multi-pane support — terminal main pane, dashboard side pane.
- **Phase 0 audit (mandatory):** What state is Forge actually in? What's done, what's started, what's untouched? Same discovery-gate pattern as v7 Phase 4.

### Component 2: claude-code-dashboard
- **Current state:** Mature React 19 + Vite + Express + SQLite. Pages: /activity, /sessions, /analytics, /agents, /hooks, /plans, /memory, /system, /token-spend, /db. Dev: :5173 (Vite) + :3001 (Express API).
- **v8 ask:** Get it to run inside a Tauri webview without the dev-server-pair pattern. Likely means bundling the built artifacts and pointing the Express server at a localhost socket the Tauri host manages. Or: collapse to single-process by serving the static React build from Express.
- **Phase 0 audit:** Which pages are stable, which are stubs? What's the actual CRUD surface vs. read-only views? The /agents page especially — it'll need agent count sync per Phase 4.5.7.

### Component 3: Voice
- **Current state:** Greenfield.
- **v8 ask:** Voice-driven agent dispatch with structured output. NOT just "talk to Claude in a terminal" (the value over `whisper | claude` is marginal). The novel surface is **voice triggering structured agent dispatch**: "/voice plan a refactor of the auth module" → Claude Code orchestrate flow with voice as the input modality.
- **Stack candidates:** Whisper (local, OpenAI's open-weight) for STT. Native macOS speech APIs as a fallback. TTS for read-back via `say` or ElevenLabs.
- **Realistic scope for v8.0:** Push-to-talk binding in the Tauri app → Whisper → text → existing /skill or /agent dispatch flow. v8.1 adds always-listening + wake-word + TTS read-back.

---

## Phase plan (provisional — Phase 0 will reshape)

### Phase 0 — Discovery + audit (~3h, mandatory before any code)
- **Forge state audit** — what's done in Forge's 8-phase plan, what's in progress, what's untouched. Read every commit on `main` since the plan was last updated.
- **Dashboard state audit** — page-by-page, "stable / stub / abandoned." Identify what survives the bundle.
- **Tauri sidecar feasibility** — can claude-code-dashboard run inside a Tauri webview without the dual-server pattern? Spike a 2-hour proof of concept BEFORE committing.
- **Voice MVP scoping** — can Whisper + push-to-talk + Tauri's keyboard shortcut binding work? Spike a 2-hour proof of concept BEFORE committing.
- **Decide what's salvageable, what's deleted.** Per the discovery-gate pattern from v7 Phase 4: plans aren't truth, reality is.

### Phase 1 — Forge merge: dashboard as sidebar
- Bundle dashboard's React build into the Tauri resource directory
- Express API runs as a Tauri sidecar process (not external dev server)
- Sidebar panel toggle: terminal-only, terminal+dashboard, dashboard-only

### Phase 2 — Voice MVP
- Push-to-talk keyboard binding in Tauri (probably Cmd+Space or similar)
- Whisper STT (local model, no cloud roundtrip for privacy)
- Text → existing /skill dispatch flow
- No TTS in v8.0

### Phase 3 — Polish + UX
- Theme harmonization (warm fire colors per Forge feedback)
- Onboarding flow for first-time install
- Settings UI for model selection, voice toggle, dashboard layout

### Phase 4 — Distribution
- Code-signed `.dmg` for macOS
- Homebrew cask formula (separate from the existing `homebrew-cast` tap — needs `homebrew-cast-desktop` or similar)
- Auto-update mechanism (Tauri has a built-in updater)
- Notarization with Apple

### Phase 5 — Documentation + marketing push
- Per `cast-v7-master-plan.md` Phase 6.6, the held-back marketing items fire here:
  - LinkedIn long-form announcement
  - dev.to / Hashnode article series
  - Demo video / screencast
  - HackerNews show-and-tell
  - Anthropic Discord drop
  - Twitter / Bluesky thread
- Recruiter outreach citing v8 as portfolio

### Phase 6 — Memory v2 + Reliability layer (deferred from v7)
**Effort:** 1–2 weeks | **Branch:** `feature/cast-v8-phase-6-memory-v2`
**Origin:** Two pieces of research Ed dropped 2026-05-10 — local-LLM memory architecture (vector DB + decoupled observer + 3-tier semantic/episodic/procedural) and Claude Code limitations (silent fake success, latency, service instability, declining quality). The small surgical items from those pieces shipped in v7 Phase 4.8 (episodic incidents table, flag-for-review queue, stale-memory TTL, anti-fake-success guard, front-loaded Status). The bigger architectural items below were deferred because they change the data model and add dependencies — not v7-shaped work.

#### 6.1 — Vector DB over agent + project memory
- Replace grep-based memory retrieval with semantic search.
- Stack candidates: `sqlite-vss` (extends existing cast.db, no new process), `chromadb` (Python, more mature), or `lancedb` (Rust, fastest). Decide via Phase 0 spike.
- Embeddings: local model (no API roundtrip on every read). `nomic-embed-text` via Ollama or `all-MiniLM-L6-v2` via sentence-transformers.
- Migration path: keep the markdown files as canonical (human-editable), index them into the vector store on write. Vector store is a derived artifact — `cast memory reindex` rebuilds from scratch.
- Surface: `cast memory search "<query>"` returns ranked relevance, not just grep matches.

#### 6.2 — Decoupled observer process
- Today: memory writes happen at session-end via SubagentStop hook (synchronous, in the same process as the agent that triggered it).
- v8: separate `cast-memory-observer` daemon (Tauri sidecar in the desktop app) that watches `cast.db` and `~/.claude/agent-memory-local/` for writes, applies curation rules independently of the agent that triggered them.
- Rationale (per the research): "True improvement comes from decoupling [reasoning engine and memory store], where external 'observer' processes manage the memory to prevent the model from getting stuck in feedback loops of its own hallucinations."
- The observer runs the curation/summarization pass that's currently absent — proactive consolidation of redundant entries, cross-linking related memories, identifying conflicts.

#### 6.3 — Formal retry + backoff policy in orchestrate
- Today: agent truncations recovered ad-hoc via SendMessage in the orchestrating session. Worked tonight (2026-05-10) but cost minutes per recovery.
- v8: orchestrate skill detects truncation via missing Status block, auto-dispatches a "wrap-up only" SendMessage with explicit token cap. Logged to `cast.db agent_truncations`.
- Exponential backoff on Anthropic API 429/503 — 3 attempts with jittered delay. Surface failures to dashboard.
- This pairs with Phase 4.8.5 (front-loaded Status) — the convention reduces truncation risk; the retry policy handles it when it happens anyway.

#### 6.4 — 3-tier memory schema formalization
- v7 Phase 4.8.1 added an `incidents` table (episodic).
- v8 formalizes the full taxonomy:
  - **Semantic** — facts, preferences, project state (already in markdown auto-memory + cast.db `agent_memories`)
  - **Episodic** — events with outcomes (`incidents` table from v7 Phase 4.8.1, expanded)
  - **Procedural** — how-to workflows (already in `agent-memory-local/<agent>/procedural/` per memory-router)
- Add `cast memory tier <semantic|episodic|procedural>` filtering.
- Cross-tier graph view in dashboard — which incident relates to which procedural memory, etc.

#### 6.5 — Memory + reliability dashboard surface
- New `/memory-graph` page in the desktop app showing the cross-tier graph.
- New `/reliability` page showing truncation rate, retry success rate, observer activity, stale-memory count over time.
- Both surfaces depend on v8 desktop app being live — that's why this whole phase is v8, not v7.

### Why this is v8 work, not v7
- Adds dependencies (vector DB, embedding model) — v7 is "set in stone, ship it."
- Changes data model (new tables, new tier classification) — riskier than v7's "convention + small additions" pattern.
- Requires Tauri sidecar process for the observer — that infrastructure only exists in v8.
- The dashboard surfaces (6.5) only make sense in the desktop app context.

The v7 Phase 4.8 items were chosen specifically because they could ship without these dependencies. Deferring 6.1–6.5 to v8 is the right call given Ed's "v7 = tighten CAST further, v8 = the app" framing (2026-05-10).

---

## Strategic anchor

Per Ed (2026-05-09):

> "I want to put something really cool out there — when it's ready. v8 will be the next logical step, specifically when we turn this into a team sharing tool in the future. Voice could be part of that. We have a lot of started projects. Maybe we focus on building that out in v8. I would use it; it just seems like the next logical step."

The "really cool when it's ready" framing IS the discipline. v8 ships when it ships. No promised release dates that ratchet scope toward "almost done" forever.

Per the conversation:

> "If there were any marketing phases from v7 we were going to push until after the app idea, please move it as well."

Done — see Phase 6.6 of `cast-v7-master-plan.md`.

---

## Open questions (Ed decides closer to v8 kickoff)

1. **Distribution model:** Free download (homebrew cask + dmg)? Free with optional sponsorship? Paid? — assume free for v8.0; revisit at v8.1.
2. **Cross-platform:** Tauri can build for Linux/Windows. v8.0 ships macOS-only (Ed's primary stack); v8.1 considers Linux. Windows is unlikely.
3. **Telemetry:** Opt-in only. Anonymized usage stats. Decide schema before any code lands.
4. **Open-source vs. proprietary:** v7 stack is fully open. v8 likely stays open. The team-sharing pivot in v9 is when this question gets re-asked.
5. **The team-sharing pivot:** monetization (CAST as SaaS) or open-source-with-team-features? Different architectures. Different funding models. Defer until v8 lands and there's real usage data.

---

## Risks

1. **Scope drift.** Three projects merging is the highest-risk part. Phase 0 audit is the safety valve — kill components that are unsalvageable rather than rewrite.
2. **Tauri runtime surprises.** Sidecar process management, native shell access, code-signing — all real. Spike-then-commit pattern.
3. **Voice as a bolted-on feature.** If the only voice value is "talk to Claude," users will use existing tools. The voice value HAS to be voice-triggered structured dispatch — that's the novel surface.
4. **Marketing-push expectation creep.** v8 is the marketing-push moment, but only when it actually ships. Resist soft-launch / preview / beta pressure if the product isn't ready. The "really cool when it's ready" anchor prevents this.
5. **Forge's 8-phase plan was written months ago.** Apply the v7 lesson: plans aren't truth. Re-audit before building against any number.

---

## Predecessors / context this builds on

- `~/.claude/plans/forge/` — Forge's existing 8-phase plan (assumed; verify path in Phase 0)
- `claude-code-dashboard` — repo at `~/Projects/personal/claude-code-dashboard`
- `project_forge.md` memory — Tauri v2 + React + xterm.js, "Flame" mascot, fire-color theme
- `project_jarvis_pa.md` memory — JARVIS PA migration to RemoteTrigger + cron in 2026-04-11; precedent for the routines-as-automation pattern that Phase 4.6 generalizes
- `cast-v7-master-plan.md` Phase 6.6 — the marketing items deferred from v7 to v8
- `cast-v7-master-plan.md` Phase 4.6 — CAST Routines, the precursor to v8's admin UI
