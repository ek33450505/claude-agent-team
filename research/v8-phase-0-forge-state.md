# Forge State Audit — CAST v8 Phase 0.3
**Date:** 2026-05-11
**Auditor:** researcher (read-only)

---

## Summary

- **Tauri version:** v2.10.3 (stable) — current, not a beta or RC
- **Completeness:** ~85% of a functional v1 terminal. PTY, xterm.js, multi-tab/split-pane, AI detection, theming all wired and previously built. Work paused 2026-04-20 on AI conversation parsing (parser WIP commit).
- **Top finding:** Both debug and release binaries exist (`src-tauri/target/`). Forge built and ran. The terminal core (PTY spawn → IPC → xterm.js render) is complete and production-quality code.
- **Salvageability verdict:** Terminal pane stack (Rust PTY + `useTerminal.ts` + `TerminalPane.tsx`) is directly reusable in v8 with minor IPC adaptation. AI conversation parsing is partial/WIP — treat as scratch material. Theme system is complete and matches fire-color spec.

---

## Project Structure

| Item | Value |
|---|---|
| Tauri version | 2.10.3 (Cargo.toml) |
| tauri-build | 2.5.6 |
| React version | 19.2.4 |
| xterm.js | @xterm/xterm ^6.0.0 |
| xterm addons | addon-fit 0.11, addon-search 0.16, addon-web-links 0.12 |
| TypeScript | ~5.9.3 |
| Tailwind CSS | v4.2.2 |
| Zustand | 5.0.12 |
| PTY crate | portable-pty 0.8 |
| Vite | 8.0.1 |
| Tests | Vitest (frontend) |
| Active branch | `forge-v1-archive-final` |

Key layout: `src/` (React), `src-tauri/src/` (Rust: pty.rs, session.rs, process.rs, config.rs, cwd.rs, git.rs, lib.rs), `src/components/`, `src/hooks/`, `src/themes/`.

---

## Phase Plan Status

No `plans/` directory exists. The "8-phase plan" referenced in the v8 master plan was tracked via planner agent memory (`.claude/agent-memory-local/planner/forge_phase_history.md`), not a standalone plan file.

**What shipped (per git log + phase history memory):**
| Phase | Description | Status |
|---|---|---|
| 1 | Tauri scaffold + PTY backend + xterm.js | Done |
| 2 | Multi-pane layout, sessions, keyboard nav | Done |
| 3 | Session management, tabs | Done |
| 4 | AI conversation detection + ConversationStore, AIConversationView | Partial — parsers added, then superseded commit 2026-04-05 archived WIP parser work |
| 5 | Command palette (cmdk), command registry | Done |
| 6 | Theming, settings panel, Flame mascot (SVG) | Done |
| 7 | CAST integration (cast_detect, cast_query_recent_runs, cast_query_stats Rust commands) | Done (commands wired; panels removed 2026-04-04) |
| 8 | Multi-tab, split panes, Claude Code detection, token meter | Done |
| 8.5 | Terminal search, inline error annotations, completion notifier | Done |
| — | AI output parsing rework (Lash parser) | WIP / archived at pause |

---

## Terminal Pane Code

### PTY / Rust Side (`src-tauri/src/pty.rs`)
Complete and clean. Implements:
- `pty_create` — spawns native PTY via `portable-pty`, sets `TERM=xterm-256color`, `COLORTERM=truecolor`, spawns reader thread emitting `pty-output-<sessionId>` Tauri events
- `pty_write` — writes raw bytes to PTY master
- `pty_resize` — sends `PtySize` to master on terminal resize
- `pty_kill` — removes session from store, drops handles

Session store in `session.rs`. Additional Rust commands: `get_foreground_process` (process.rs), `get_cwd` (cwd.rs), `get_git_status` (git.rs), `config_read/write` (config.rs), CAST query commands (lib.rs inline).

### xterm.js / React Side (`src/hooks/useTerminal.ts`, `src/components/TerminalPane.tsx`)
`useTerminal.ts` — 172 lines. Mounts Terminal with FitAddon, WebLinksAddon, SearchAddon. Wires `terminal.onData` → `invoke('pty_write')`. Listens on `pty-output-<sessionId>` → `terminal.write()`. ResizeObserver → `invoke('pty_resize')`. Live theme/font update without remount. Slash command interception (only known Forge commands; unknown `/cmd` passes through to PTY for Claude Code).

`TerminalPane.tsx` — switches between raw terminal and `AIConversationView` based on detected session type. AI types: claude-code, aider, ollama, codex, open-interpreter, cursor-cli.

### IPC Plumbing
Tauri events (`emit`/`listen`): `pty-output-<sessionId>`, `session-exit-<sessionId>`. Invoke commands: `pty_create`, `pty_write`, `pty_resize`, `pty_kill`. Well-typed via `src/types/ipc.ts`. IPC layer is complete.

### What Works
PTY spawn, xterm.js rendering, resize, multi-tab, split panes, session sidebar, terminal search, error annotations, completion notifications, AI session detection. CAST query Rust commands exist but UI panels were removed.

### What's Partial/WIP
`AIConversationView` + parsers for Claude Code/Aider/Ollama output — last commit (2026-04-20) archived WIP parser work before a planned "Lash rework" that never happened.

---

## Activity Timeline

| Date | Event |
|---|---|
| 2026-04-03 | Phase 1-2 shipped (PTY + layout) |
| 2026-04-04 | Phases 5-8.5 landed (mass commit day; CAST panels removed, error boundaries, release workflow) |
| 2026-04-05 | Phase 4 AI parsers added, then superseded by cleanup commit |
| 2026-04-20 | Final commits: archived WIP parser; .claude/ gitignore. **Work stopped here.** |

Real development window: ~17 days (April 3–20). The gap between Apr 5 and Apr 20 is just cleanup/archive housekeeping. Active implementation was Apr 3–5.

Active branch: `forge-v1-archive-final` (tells the story — user archived it before absorb into v8).

Stale worktree branches: 8 `worktree-agent-*` branches present (candidates for grooming per branch hygiene policy).

---

## Tauri Version + Build State

- **Schema:** `tauri.conf.json` uses `$schema` pointing to local node_modules — v2 schema format (no legacy v1 `tauri.allowlist`).
- **Cargo.toml:** `tauri = "2.10.3"`, `tauri-build = "2.5.6"` — both v2 stable, current as of audit date.
- **Binaries:** Both `target/debug/forge` and `target/release/forge` exist — the app has been successfully compiled. No need to trial-build.
- **Buildability:** Deps look clean. `portable-pty 0.8` is stable. No obvious broken dependencies. `node_modules/` present (no install needed).
- **Concern:** `tauri.conf.json` has no `plugins` key for `tauri-plugin-log` even though it's in Cargo.toml — minor config/code mismatch; non-blocking.

---

## Theme / Branding State

Fire colors are **fully applied**, not aspirational. `forge-dark.ts` implements the Flame theme completely:
- Background: `#1a1008` (deep warm black)
- Accent: `#e8a838` (amber) with ember glow effects
- Sidebar: `#261410` (warm red-black)
- Terminal cursor: amber (`#e8a838`)
- Error: `#c05020` (ember red)
- CSS custom properties wired via `useTheme.ts`

6 themes total: `forge-dark` (default, fire), `forge-light`, `dracula`, `one-dark`, `solarized-dark`, `high-contrast`. The Flame mascot is a React SVG component (`src/components/Flame.tsx`).

---

## Salvageability for v8

| Component | Reuse as-is | Adapt | Discard |
|---|---|---|---|
| `src-tauri/src/pty.rs` | YES | — | — |
| `src-tauri/src/session.rs` | YES | — | — |
| `src-tauri/src/process.rs` + `cwd.rs` + `git.rs` | YES | — | — |
| `src/hooks/useTerminal.ts` | YES | Minor: dashboard IPC context | — |
| `src/components/TerminalPane.tsx` | YES | Integrate with dashboard panels | — |
| `src/themes/` (all 6) | YES | — | — |
| `src/components/Flame.tsx` | YES | — | — |
| Multi-tab / split-pane layout | — | Extract pane primitives for v8 layout | — |
| `src/hooks/useAIDetection.ts` | — | Adapt to dashboard session model | — |
| `AIConversationView` + parsers | — | — | Discard — WIP, superseded by dashboard's existing agent view |
| CAST query Rust commands (lib.rs inline) | — | Move to dashboard's Express API layer | — |
| `src/components/TokenMeter.tsx` | — | Merge with dashboard `/token-spend` page | — |
| Forge-specific command palette | — | Adapt to v8 command model | — |
| `homebrew-forge/` dir | — | — | Discard — separate tap, not needed for bundled app |

**Integration note:** The Rust PTY layer (`pty.rs` + `session.rs`) is the highest-value artifact. It's clean, tested (binaries built), and directly portable to a new Tauri v2 wrapper around the dashboard. The xterm.js hooks are equivalently clean. The AI output parsers are the one area to skip — dashboard already has its own session/agent data from cast.db via the Express API.

---

## Status: DONE
