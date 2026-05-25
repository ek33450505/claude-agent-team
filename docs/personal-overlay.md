# Personal Overlay

> Source: Moved from README.md as part of 2026-05-25 ecosystem alignment.

CAST ships in two layers: `core` (always installed) and `personal` (optional, `--personal` flag).

| Layer | Contents | Installed |
|---|---|---|
| `rules-core/` | Generic conventions (shell, python, typescript) | Always |
| `agents/core/` | Specialist agents (code-writer, debugger, planner, …) | Always |
| `rules-personal/` | Maintainer project catalog, identity traits | `--personal` |
| `agents/personal/` | Maintainer-specific agents (e.g., portfolio-sync) | `--personal` |

New clones get a trustworthy, generic installation. `rules-personal/` ships empty for clones to populate.
