CAST diagnostic and manual dispatch command.

## Usage

- `/cast` (no args) — Show system status: available agents, hook health, recent agent runs
- `/cast <agent> <prompt>` — Force-dispatch a specific agent via the Agent tool

## If arguments provided:

$ARGUMENTS

Parse the first word as the agent name. Dispatch that agent via the Agent tool with the remaining text as the prompt. If the first word is not a recognized agent name, use the CLAUDE.md dispatch table to select the agent.

## If no arguments:

Show:
1. **Available agents** — List the installed agents from `~/.claude/agents/` with their model
2. **Hook status** — Confirm post-tool-hook.sh, cast-pretool-dispatch.py, write-guards.sh, cast-audit-hook.sh, and cast-session-end.sh are present
3. **Recent agent runs** — Query last 5 entries from cast.db agent_runs table

## Agent Registry (for manual dispatch)

Load the `agent-registry` skill for the current agent names and models.
