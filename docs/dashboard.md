# Observability Dashboards

> The CAST observability layer is available via two interfaces: a web UI (claude-code-dashboard) and a native desktop app (cast-desktop). Both are fed live from `~/.claude/cast.db`.

## claude-code-dashboard

**[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard)** is a React 19 + Vite + Express observability UI that provides ~21 views into your CAST runtime. All data is read from `~/.claude/cast.db` — local-only, no cloud dependencies.

### Views

Core observability pages:

- **Sessions** — active and historical Claude Code sessions with token counts, models, duration
- **Session Detail** — deep dive into a single session with tool calls, memory injections, routing events
- **Agents** — agent dispatch history, reliability metrics, model-specific performance
- **Agent Reliability** — error rates, fallback patterns, model comparison
- **Analytics** — multi-dimension analysis (sessions over time, cost trends, agent performance)
- **Analytics Agent Detail** — per-agent analytics with cost attribution
- **Hooks** — hook execution history and lifecycle event coverage
- **Hook Failures** — guard hook blocks, gate violations, pre-tool-use failures
- **Memory** — agent-accumulated knowledge from the memory system
- **Plans** — Agent Dispatch Manifest history and orchestration execution
- **Incidents** — critical events and anomalies
- **Routines** — scheduled workflow execution and trigger history
- **File Writes** — audit trail of all file modifications with agent and timestamp
- **Injection Log** — memory and context injection events
- **Executive Summary** — dashboard-level health and key metrics
- **SQLite Explorer** — direct query interface to cast.db schema
- **System** — CAST health, version, installed hooks and agents, database stats
- **Docs** — embedded documentation reference
- **Work Log** — agent response work logs and status blocks

### Development

```bash
cd ~/Projects/personal/claude-code-dashboard
npm run dev    # Vite :5173 + Express :3001
# Open http://localhost:5173
```

---

## Cast Desktop

**[Cast Desktop](https://github.com/ek33450505/cast-desktop)** is a Tauri 2 native macOS application that embeds the same observability layer alongside a real PTY-backed terminal.

### Features

- **Embedded terminal** — xterm-backed, real shell environment for running CAST commands
- **Command palette** — Cmd+K to search and filter
- **11 dashboard views** — core observability pages accessible from the app
- **Native macOS menu bar** — standard file, edit, window menus
- **Fast, lightweight** — native Rust/Tauri performance

See [observability/OBSERVABILITY.md](observability/OBSERVABILITY.md) for the full observability guide including cast.db schema, hook event coverage, and dashboard integration schemas.
