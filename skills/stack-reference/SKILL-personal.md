---
name: stack-reference-personal
description: Personal overlay for stack-reference. Adds project-specific dev commands and project catalog. Loaded on top of SKILL.md when the personal overlay is installed.
user-invocable: false
allowed-tools: []
---

# Stack Reference — Personal Overlay

> This file is a personal overlay on top of `skills/stack-reference/SKILL.md`. It contains project-specific paths and catalog entries that are specific to the maintainer's environment. Users installing via `bash install.sh --personal` will have this file available.

## Key Dev Commands (project-specific)
```bash
# Dashboard
cd ~/Projects/personal/claude-code-dashboard
npm run dev          # Vite :5173 + Express :3001
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
