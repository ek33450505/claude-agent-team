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
| `~/.claude/skills/` (personal subset) | Skills from `skills-personal/` — skip-if-exists, preserving user content |

### skills-personal/ overlay

`skills-personal/` mirrors the same `--personal`-gated, skip-if-exists semantics as `rules-personal/` and `agents/personal/`. Skills in `skills-personal/` are installed only when `--personal` is passed; the stub is copied on a fresh install and preserved if you have already populated the directory.

`project-catalog` lives here: its `SKILL.md` is a private catalog (real project paths, remotes, runtime paths) that should never appear in the public repo. Populate it locally after running `bash install.sh --personal`.

The personal layer is NOT shipped in the repo — it's configuration you build locally. New clones get the trustworthy, generic core installation, then you optionally add personal layers for your own projects and workflow.
