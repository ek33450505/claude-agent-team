CAST diagnostic and manual override command.

## Usage

- `/cast` (no args) — Show routing status: last matched route, available agents, hook health
- `/cast <agent> <prompt>` — Force-dispatch a specific agent, bypassing automatic routing

## If arguments provided:

$ARGUMENTS

Parse the first word as the agent name. Dispatch that agent via the Agent tool with the remaining text as the prompt. If the first word is not a recognized agent name, treat the entire text as a prompt and use the automatic routing table to select the agent.

## If no arguments:

Show:
1. **Last routing decision** — Read the last 3 entries from `~/.claude/routing-log.jsonl`
2. **Available agents** — List all agents from `~/.claude/agents/` with their model tier
3. **Hook status** — Confirm route.sh, pre-tool-guard.sh, and post-tool-hook.sh are present

## Agent Registry (for manual dispatch)

| Agent | Model | Agent | Model |
|---|---|---|---|
| `commit` | haiku | `debugger` | sonnet |
| `code-reviewer` | haiku | `test-writer` | sonnet |
| `build-error-resolver` | haiku | `planner` | sonnet |
| `refactor-cleaner` | haiku | `security` | sonnet |
| `doc-updater` | haiku | `architect` | sonnet |
| `auto-stager` | haiku | `researcher` | sonnet |
| `db-reader` | haiku | `e2e-runner` | sonnet |
| `report-writer` | haiku | `qa-reviewer` | sonnet |
| `meeting-notes` | haiku | `data-scientist` | sonnet |
| `chain-reporter` | haiku | `morning-briefing` | sonnet |
