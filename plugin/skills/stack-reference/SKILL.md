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
# CAST
cast status          # health dashboard
cast exec            # run cast plan executor
bash tests/run.sh    # run shell tests (isolated temp HOME — NEVER 'bats tests/' on real $HOME)
bash install.sh      # reinstall CAST into ~/.claude/
```

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
