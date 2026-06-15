# CAST Plugin Architecture Research

**Date:** 2026-04-10
**Author:** CAST Researcher Agent
**Status:** Research Complete (Superseded 2026-06-14)

> **Superseded:** This research describes a single-file `claude-plugin.json` manifest at repo root. The shipped v8 design uses a **committed `plugin/` artifact** with `.claude-plugin/plugin.json` (for local development) **and** a repo-root `.claude-plugin/marketplace.json` (for marketplace distribution). For the current plugin architecture, see CHANGELOG v8 entry and the actual manifest at `plugin/.claude-plugin/plugin.json`.

---

## What Is the Claude Code Plugin System?

Claude Code plugins are distributable packages that extend Claude Code with agents, skills, hooks, rules, and MCP servers. They provide a standardized way to share Claude Code configurations across teams and projects.

## Plugin Structure

A plugin is a directory (or npm package) with a `claude-plugin.json` manifest:

```json
{
  "name": "cast",
  "version": "4.5.0",
  "description": "Claude Agent Specialist Team — multi-agent framework",
  "author": "ek33450505",
  "license": "MIT",
  "components": {
    "agents": "agents/core/",
    "skills": "skills/",
    "hooks": "managed-settings.d/",
    "rules": "rules/"
  },
  "install": {
    "scripts": "scripts/",
    "postInstall": "bash install.sh"
  },
  "dependencies": {
    "python3": ">=3.9",
    "sqlite3": true,
    "bats": ">=1.10.0"
  }
}
```

## CAST Structure Mapping

| CAST Component | Plugin Location | Notes |
|---|---|---|
| `agents/core/*.md` | `components.agents` | Direct mapping — agent .md files |
| `skills/*/SKILL.md` | `components.skills` | Direct mapping — skill directories |
| `managed-settings.d/*.json` | `components.hooks` | Hook registrations merge into settings |
| `rules/*.md` | `components.rules` | Path-scoped rules with globs |
| `scripts/*.sh` | `install.scripts` | Installed to `~/.claude/scripts/` |
| `scripts/*.py` | `install.scripts` | Same — Python scripts |
| `install.sh` | `install.postInstall` | Post-install setup script |

### What Maps Cleanly
- Agent definitions (direct 1:1 mapping)
- Skills (direct 1:1 mapping)
- Rules (direct 1:1 mapping with path-scoped globs)
- Hook registrations (merge into managed-settings.d)

### What Needs Adaptation
- **Scripts:** Plugin system expects scripts to be self-contained. CAST scripts reference `~/.claude/scripts/` paths — need to be relocatable or use a `$CAST_SCRIPTS_DIR` variable.
- **cast.db:** Local database. Plugin can create it on install, but path must be configurable.
- **Agent memory:** `~/.claude/agent-memory-local/` is CAST-specific. Plugin needs to initialize this on install.
- **cast-events.sh:** Shared library sourced by all hooks. Must be installed before any hook runs.
- **Config files:** `~/.claude/config/cast-cli.json` is outside plugin scope.

## Distribution Methods

### 1. npm Package (Recommended)
```bash
npm install -g @ek33450505/cast-plugin
claude plugin install @ek33450505/cast-plugin
```

**Pros:** Standard package manager, versioning, dependency resolution, wide reach.
**Cons:** Requires npm publish setup, Node.js ecosystem dependency.

### 2. GitHub Release
```bash
claude plugin install github:ek33450505/claude-agent-team
```

**Pros:** No npm publish needed, direct from source repo.
**Cons:** No version resolution, must specify tag.

### 3. Local Path
```bash
claude plugin install ./path/to/cast
```

**Pros:** Development workflow, no publishing needed.
**Cons:** Not distributable.

## Homebrew Tap Comparison

CAST currently distributes via Homebrew tap (`brew install ek33450505/cast/cast`).

| Feature | Homebrew Tap | Plugin System |
|---|---|---|
| Install command | `brew install cast` | `claude plugin install cast` |
| Audience | macOS users | All Claude Code users |
| Auto-update | `brew upgrade` | Plugin auto-update (TBD) |
| Dependencies | Explicit in formula | Declared in manifest |
| Scripts | Installed to `/opt/homebrew/` | Installed to `~/.claude/` |
| Agents | Symlinked via install.sh | Direct plugin registration |
| Uninstall | `brew uninstall` | `claude plugin remove` |

**Assessment:** Plugin system complements Homebrew, doesn't replace it. Homebrew installs the `cast` CLI binary and shell completions. Plugin installs the agents, hooks, skills, and rules into Claude Code.

### Recommended Dual Distribution
- **Homebrew:** `cast` CLI tool, shell completions, system-level scripts
- **Plugin:** Agents, skills, hooks, rules (everything that lives inside Claude Code)

## Current Plugin System Status

- Plugin system is available as of Claude Code v2.1.90+
- Manifest format is documented but evolving
- Plugin registry/marketplace is not yet available
- Installation is via CLI (`claude plugin install`)
- Community adoption is early stage

## Changes Required for CAST Plugin

### 1. Create Plugin Manifest
Add `claude-plugin.json` to repo root (shown above).

### 2. Make Scripts Relocatable
Replace hardcoded `~/.claude/scripts/` paths with:
```bash
CAST_SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
```

### 3. Add Post-Install Script
The existing `install.sh` handles most of this. Needs adaptation:
- Create `~/.claude/agent-memory-local/` directories
- Initialize cast.db schema
- Create `~/.claude/cast/events/` directory
- Validate dependencies (python3, sqlite3, jq)

### 4. Handle Hook Registration Merging
Plugin hooks in `managed-settings.d/` must merge with existing user hooks, not replace them. The plugin system handles this automatically via the `components.hooks` path.

### 5. Version Migration
Add a `migrate.sh` script for upgrading between CAST versions:
```bash
# migrate.sh — Run after plugin update
# Handles schema migrations, config format changes, etc.
```

## Proposed Plugin Manifest

```json
{
  "name": "cast",
  "version": "4.5.0",
  "description": "Claude Agent Specialist Team — multi-agent framework with 17 agents, hook-enforced quality gates, and SQLite observability",
  "author": "ek33450505",
  "repository": "https://github.com/ek33450505/claude-agent-team",
  "license": "MIT",
  "claude_code_version": ">=2.1.90",
  "components": {
    "agents": "agents/core/",
    "skills": "skills/",
    "hooks": "managed-settings.d/",
    "rules": "rules/"
  },
  "install": {
    "scripts": {
      "source": "scripts/",
      "destination": "~/.claude/scripts/"
    },
    "postInstall": "bash scripts/cast-plugin-install.sh"
  },
  "dependencies": {
    "python3": ">=3.9",
    "jq": ">=1.6"
  },
  "keywords": ["agents", "multi-agent", "observability", "quality-gates"]
}
```

## Migration Checklist

- [ ] Create `claude-plugin.json` manifest in repo root
- [ ] Make all script paths configurable via `$CAST_SCRIPTS_DIR`
- [ ] Create `scripts/cast-plugin-install.sh` (adapted from install.sh)
- [ ] Test plugin install from local path
- [ ] Test plugin install from GitHub
- [ ] Verify hook registration merging works correctly
- [ ] Verify agents load via plugin system
- [ ] Verify skills load via plugin system
- [ ] Set up npm package (optional, for wider distribution)
- [ ] Document dual distribution (Homebrew + Plugin)
- [ ] Add version migration support

## Recommendation

**GO — but not urgent.** The plugin system is ready for early adoption. CAST's structure maps well to the plugin format. However:

1. Homebrew distribution is working and mature — no need to rush
2. Plugin system is still evolving — early adoption means maintaining against API changes
3. Best time to convert: when plugin registry/marketplace launches (wider discovery)

**Suggested timeline:**
- Now: Create the manifest and test local plugin install
- Q2 2026: Publish to npm when plugin format stabilizes
- Q3 2026: Dual distribution (Homebrew for CLI, Plugin for Claude Code integration)
