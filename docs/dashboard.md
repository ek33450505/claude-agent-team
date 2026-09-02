# Observability Dashboards

> The CAST observability layer is available via two interfaces: a web UI (claude-code-dashboard) and a native desktop app (cast-desktop). Both are fed live from `~/.claude/cast.db`.

## claude-code-dashboard

**[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard)** is a React 19 + Vite + Express observability UI over `~/.claude/cast.db`. Local-only, no cloud dependencies, and **read-only by default** — the server performs zero writes at startup and every mutating endpoint sits behind an opt-in token gate (`CAST_DASHBOARD_CONTROL=1` + `DASHBOARD_TOKEN`).

### Views

**19 navigable views** plus 2 detail views reached by link (21 routes total). Verified against `src/components/Sidebar.tsx` and `src/App.tsx` on 2026-09-01.

*Overview*

- **Dashboard** (`/`) — today's runs, active agents, token-spend sparkline, gate and tool-failure counts
- **Executive** (`/executive`) — run-status rollup, cost today/week, top agents, blockers
- **Sessions** (`/sessions`) — session list with live hook events and compaction badges
- **Session Detail** (`/sessions/:project/:sessionId`) — virtualized JSONL timeline, token and tool breakdown, agent runs
- **Analytics** (`/analytics`) — token spend, agent scorecard, dispatch activity, delegation savings, cache breakdown
- **Analytics Agent Detail** (`/analytics/agents/:agent`) — per-agent run history and charts

*Observability*

- **Work Log** (`/work-log`) — agent response work logs and Status blocks
- **Evals** (`/evals`) — `eval_runs` table
- **Injection Log** (`/injection-log`) — memory and context injection audit trail
- **Routines** (`/routines`) — scheduled routine definitions and last-run status
- **Hooks** (`/hooks`) — hook definitions plus per-hook health (script present, executable, recent failures)
- **Database** (`/db`) — direct `cast.db` table browser, paginated

*Reliability*

- **Failures** (`/hook-failures`) — hook failure log with stderr
- **Reliability** (`/agent-reliability`) — hallucinations, completeness events, truncations, protocol violations, worktree anomalies
- **Incidents** (`/incidents`) — recorded incidents and resolution status

*System*

- **Memory** (`/memory`) — agent and project memory files, consolidation runs
- **Plans** (`/plans`) — plan files and `plan_sessions`
- **Agents** (`/agents`) — agent roster, scorecard, recent runs, routing intel
- **Outputs** (`/outputs`) — briefings, meetings, reports
- **System** (`/system`) — CAST health, rules, skills, cron, policies, pricing, control surface, integrity
- **Docs** (`/docs`) — embedded slash-command, agent, skill and CLI reference


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
