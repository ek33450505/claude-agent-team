---
name: project-catalog
description: Full project catalog — project paths, stacks, remotes, and runtime paths. Load when you need a project's path, remote, stack, or build/deploy specifics.
user-invocable: false
allowed-tools: []
---

# Key Projects

<!--
  TEMPLATE: This generic stub ships with CAST. Populate it on your machine with your own
  project catalog so on-demand lookups return real data. The maintainer's personal catalog
  lives only on the local install (`~/.claude/skills/project-catalog/SKILL.md`), never in
  this public repo — keeping personal paths/remotes off the framework.

  NOTE: `cp -R` on reinstall overwrites the installed SKILL.md with this stub. If you keep a
  personal catalog here, restore it from your local backup after `bash install.sh`, or keep
  the real catalog in a `--personal` overlay. (Tracked: Lean-CAST Findings Log.)
-->

## Personal Projects

| Name | Path | Stack | Notes |
|---|---|---|---|
| my-framework | `~/Projects/personal/my-framework` | Bash + Python + SQLite | Core framework |
| my-dashboard | `~/Projects/personal/my-dashboard` | React + Vite + Express | Observability UI |

## Work Projects

| Name | Path | Stack | Remote / Branch | Notes |
|---|---|---|---|---|
| my-app | `~/Projects/work/my-app` | React + Vite | git / main | Main web app |

## Key Runtime Paths

| Purpose | Path |
|---|---|
| CAST runtime root | `~/.claude/` |
| Agent definitions | `~/.claude/agents/` |
| Hook scripts | `~/.claude/scripts/` |
| CAST SQLite DB | `~/.claude/cast.db` |
| CAST CLI | `~/.local/bin/cast` |
