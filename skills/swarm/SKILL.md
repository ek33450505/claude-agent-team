---
name: swarm
description: >
  Bootstrap a CAST Agent Team from a swarm config file. Spawns parallel teammates
  with isolated git worktrees, seeds each with role identity and CAST quality gates,
  and logs the swarm to cast.db for observability.
usage: /swarm <team-config-name> "<task description>"
user-invocable: true
---

# Swarm

This is the `/swarm` skill. Bootstrap a multi-agent CAST swarm from a named config.

## Usage

```
/swarm fullstack-team "implement dark mode toggle"
/swarm review-team "review PR #42 changes"
/swarm research-team "investigate SQLite vs PostgreSQL for CAST observability"
```

## Available team configs

- `fullstack-team` — Frontend dev + backend dev + reviewer (parallel code development)
- `review-team` — Spec reviewer + quality reviewer + security reviewer (read-only, cost-saving Ollama models)
- `research-team` — Two parallel researchers + synthesizer (no code commits)

## How to execute

When the user invokes `/swarm <team-name> "<task>"`:

1. Resolve the config path: `~/.claude/swarm-configs/<team-name>.yml`
2. Run the bootstrap script:
   ```bash
   bash ~/.claude/scripts/cast-swarm-bootstrap.sh \
     ~/.claude/swarm-configs/<team-name>.yml \
     "<task description>"
   ```
3. Parse the JSON manifest output and display a summary table:
   - Swarm ID
   - Team name and description
   - For each teammate: role, agent_def, model, worktree path (or "read-only")
   - Merge strategy
4. Remind the user:
   - Teammates are seeded with role identity in `<worktree>/.claude/spawn_preamble.md`
   - Use `Shift+Down` in Claude Code to cycle between open terminal sessions
   - When all teammates show `Status: DONE`, run: `bash ~/.claude/scripts/cast-swarm-merge.sh <swarm_id>`
   - For emergency cleanup: `bash ~/.claude/scripts/cast-swarm-teardown.sh --force <swarm_id>`

## Error handling

If the config file is not found, tell the user to run `bash install.sh` in the
`claude-agent-team` repo to sync configs to `~/.claude/swarm-configs/`.

If PyYAML is not installed, instruct: `pip3 install pyyaml`
