# CAST Dashboard Integration

## routing-log.jsonl Schema

Location: `~/.claude/routing-log.jsonl`
Format: newline-delimited JSON (one object per line)
Rotation: files rotate at 5MB → routing-log.jsonl.1, routing-log.jsonl.2

### Fields

| Field | Type | Values | Description |
|---|---|---|---|
| timestamp | ISO8601 string | UTC | When the routing event occurred |
| session_id | string | UUID or "unknown" | From CLAUDE_SESSION_ID env var |
| prompt_preview | string | max 80 chars | First 80 chars of prompt — never full prompt |
| action | string | "dispatched" \| "no_match" \| "config_error" \| "opus_escalation" | What the router did |
| matched_route | string \| null | agent name | Which agent was selected |
| command | string \| null | slash command | If prompt was a slash command |
| pattern | string \| null | regex string | Which pattern matched |
| confidence | string \| null | "hard" \| "soft" | Route confidence level |

## agent-status/ Schema

Location: `~/.claude/agent-status/<agent>-<timestamp>.json`

| Field | Type | Description |
|---|---|---|
| agent | string | Agent name |
| status | string | DONE \| DONE_WITH_CONCERNS \| BLOCKED \| NEEDS_CONTEXT |
| summary | string | One-sentence summary |
| concerns | string \| null | Details if DONE_WITH_CONCERNS |
| recommended_agents | string \| null | Pipe-separated agent recommendations |
| timestamp | ISO8601 string | When status was written |

## task-board.json Schema

Location: `~/.claude/task-board.json`

| Field | Type | Description |
|---|---|---|
| tasks | array | List of task entries |
| tasks[].id | string | Unique task ID: "batch-N-agentname" |
| tasks[].status | string | PENDING \| IN_PROGRESS \| DONE \| BLOCKED \| DONE_WITH_CONCERNS |
| tasks[].agent | string | Agent that owns this task |
| tasks[].summary | string | What was done or what is blocked |
| tasks[].updated | ISO8601 string | Last update time |
| updated | ISO8601 string | Board-level last update |

## Integration Notes

The dashboard should poll routing-log.jsonl and agent-status/ for live session observability.
Agent-level status files are append-only (never overwritten). Read newest file per agent by timestamp in filename.
Task board is mutable — read task-board.json for current state, not history.
