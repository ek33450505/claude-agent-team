---
name: stack-reference
description: Full tech stack reference and dev command cheatsheet. Load when you need to look up exact package names, commands, or project paths.
user-invocable: false
allowed-tools: []
---

# Stack Reference

## Frontend Libraries (full list)
- **React 19** with Vite 6
- **TypeScript** — `.tsx` / `.ts`, `tsconfig.json`
- **Tailwind CSS v4** (via `@tailwindcss/vite`)
- **shadcn/ui** + `class-variance-authority` + `clsx` + `tailwind-merge`
- **Framer Motion** for animation
- **React Router v6** for routing
- **TanStack React Query v5** for data fetching
- **Recharts** + **@nivo** for charts/graphs
- **Lucide React** for icons
- **Sonner** for toasts
- **cmdk** for command palette
- **react-resizable-panels** for panel layouts

## Backend Libraries (full list)
- **Express 5** (Node.js) — API server
- **tsx** for TypeScript execution in dev (`tsx watch`)
- **concurrently** to run Vite + Express together

## Key Dev Commands
```bash
# Dashboard
cd ~/Projects/personal/claude-code-dashboard
npm run dev          # Vite :5173 + Express :3001

# CAST
cast status          # health dashboard
cast exec            # run cast plan executor
bats tests/          # run all 255 shell tests
bash install.sh      # reinstall CAST into ~/.claude/
```

## Project Catalog (full list)

| Name | Path | Stack | Notes |
|---|---|---|---|
| claude-agent-team | `~/Projects/personal/claude-agent-team` | Bash + Python + SQLite | CAST v4.6 — multi-agent framework |
| claude-code-dashboard | `~/Projects/personal/claude-code-dashboard` | React 19 + Vite + TS + Express 5 + SQLite | CAST observability UI |
| homebrew-cast | `~/Projects/personal/homebrew-cast` | Ruby | Homebrew tap for CAST |
| cast-claudes_journal | `~/Projects/personal/cast-claudes_journal` | Bash + Markdown | Claude's Journal |
| cast-dash | `~/Projects/personal/cast-dash` | Python (Textual) | CAST TUI dashboard |
| cast-hooks | `~/Projects/personal/cast-hooks` | Bash + Python | CAST hook scripts framework |
| homebrew-cast-dash | `~/Projects/personal/homebrew-cast-dash` | Ruby | Homebrew tap for cast-dash |
| homebrew-cast-hooks | `~/Projects/personal/homebrew-cast-hooks` | Ruby | Homebrew tap for cast-hooks |
| homebrew-claudes-journal | `~/Projects/personal/homebrew-claudes-journal` | Ruby | Homebrew tap for Claude's Journal |
| jarvis | `~/Projects/personal/jarvis` | Bash + Markdown | Archived |
| Edward_Kubiak | `~/Projects/personal/Edward_Kubiak` | React + Vite | Personal portfolio |
| promptbot | `~/Projects/personal/promptbot` | Python | promptbot |

## Key Runtime Paths

| Purpose | Path |
|---|---|
| CAST runtime root | `~/.claude/` |
| Agent definitions | `~/.claude/agents/` |
| Hook scripts | `~/.claude/scripts/` |
| Agent memory | `~/.claude/agent-memory-local/` |
| Plans output | `~/.claude/plans/` |
| CAST SQLite DB | `~/.claude/cast.db` |
| CAST event log | `~/.claude/cast/events/` |
| Agent status | `~/.claude/agent-status/` |
| Audit / logs | `~/.claude/logs/` |
| CAST CLI | `~/.local/bin/cast` |
