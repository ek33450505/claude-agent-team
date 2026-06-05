# Personal Overlay

> Source: Moved from README.md as part of 2026-05-25 ecosystem alignment.

CAST ships in two layers: `core` (always installed) and `personal` (optional, `--personal` flag during install).

## Core Layer (always installed)

| Directory | Contents |
|---|---|
| `rules-core/` | Generic conventions (shell, python, typescript) |
| `agents/core/` | Specialist agents (code-writer, debugger, planner, …) |

## Personal Layer (optional, created on `--personal` flag)

When you run `bash install.sh --personal`, the installer creates local directories for you to populate:

| Directory | Purpose |
|---|---|
| `~/.claude/rules-personal/` | Your project-specific rules and conventions |
| `~/.claude/agents/personal/` | Your custom agents (e.g., portfolio-sync, domain-specific specialists) |

The personal layer is NOT shipped in the repo — it's configuration you build locally. New clones get the trustworthy, generic core installation, then you optionally add personal layers for your own projects and workflow.
