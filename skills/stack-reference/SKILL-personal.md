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
| claude-agent-team | `~/Projects/personal/claude-agent-team` | Bash + Python + SQLite | CAST — multi-agent framework |
| claude-code-dashboard | `~/Projects/personal/claude-code-dashboard` | React 19 + Vite + TS + Express 5 + SQLite | CAST observability UI |
| cast-claudes_journal | `~/Projects/personal/cast-claudes_journal` | Bash + Markdown | Claude's Journal |
| homebrew-claudes-journal | `~/Projects/personal/homebrew-claudes-journal` | Ruby | Homebrew tap for Claude's Journal |
| Edward_Kubiak | `~/Projects/personal/Edward_Kubiak` | React + Vite | Personal portfolio |
