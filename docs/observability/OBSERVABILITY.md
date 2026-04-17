# CAST Observability

> Extracted from [README](../../README.md).

## Agent Constellation Dashboard

[claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) ships **Constellation** — a force-directed graph visualization of your swarm:

| Feature | What It Shows |
|---|---|
| **Agent Force Graph** | Core agents + task satellites, gravity physics, live updates |
| **Swarm Sessions** | Active swarms, teammates, task assignments, peer messages |
| **Worktree Isolation** | Per-teammate file ownership, no write conflicts |
| **Token Heatmap** | Per-agent token spend, cost trends, local vs Claude |
| **Hook Audit Trail** | TeammateIdle, TaskCreated, TaskCompleted lifecycle events |
| **Peer Messages** | Task claims, status updates, query results flowing between teammates |

```bash
cd ~/Projects/personal/claude-code-dashboard
npm run dev    # Vite :5173 + Express :3001
# Visit http://localhost:5173/constellation
```

---

## Hook Event Coverage

TaskCreated and WorktreeCreate are production-hardened hooks capturing swarm lifecycle. All responses validate against JSON schemas in `schemas/`.

| Event | Hook Script | What It Does |
|---|---|---|
| `SessionStart` | `cast-session-start-hook.sh` | Opens session row in cast.db |
| `TaskCreated` | `cast-task-created-hook.sh` | Logs task assignment; updates teammate_runs table |
| `WorktreeCreate` | `cast-worktree-create-hook.sh` | Creates isolated worktree; seeds agent identity preamble |
| `PreToolUse:Bash` | `pre-tool-guard.sh` | Hard-blocks `git commit` / `git push` (exit 2) |
| `PostToolUse:Write\|Edit` | `post-tool-hook.sh` | Logs file modifications; emits HTTP event to dashboard |
| `PostCompact` | `cast-post-compact-hook.sh` | Reinjects swarm context after compaction |
| `SessionEnd` | `cast-session-end.sh` | Archives session, syncs peer messages, closes cast.db rows |

**Exit code convention:**
- Exit 0 — hook passed, tool call proceeds
- Exit 2 — hook blocked the tool call (guard hooks only)
- Never exit 1 (reserved for fatal hook errors)

---

## Observability & cast.db v8

`cast.db` at `~/.claude/cast.db` — SQLite WAL mode, append-only, never truncated.

| Table | Purpose |
|---|---|
| `swarm_sessions` | Swarm metadata: team_name, started_at, status, merge_strategy |
| `teammate_runs` | Per-agent task tracking: swarm_id, agent_role, status, token counts |
| `teammate_messages` | Peer gossip: from_agent, to_agent, message_type, JSON payload |

**Existing tables** (v4.6):
| Table | Contents |
|---|---|
| `sessions` | Session start/end, model, token counts |
| `agent_runs` | Every dispatch: agent, model, duration, status, batch_id |
| `routing_events` | Prompt routing records |
| `agent_memories` | Synced from `~/.claude/agent-memory-local/` with temporal validity |
| `stream_events` | Real-time tool events from stream-json pipeline |

```bash
# Query active swarms
sqlite3 ~/.claude/cast.db "SELECT swarm_id, team_name, status, COUNT(*) FROM swarm_sessions \
  JOIN teammate_runs ON swarm_sessions.id = teammate_runs.swarm_id \
  WHERE status='running' GROUP BY swarm_id;"

# Export swarm timeline
sqlite3 ~/.claude/cast.db "SELECT timestamp, from_agent, to_agent, message_type \
  FROM teammate_messages WHERE swarm_id = ? ORDER BY timestamp;"

# Cast health check
cast doctor
```

---

## Dashboard Integration

### routing-log.jsonl Schema

Location: `~/.claude/routing-log.jsonl`
Format: newline-delimited JSON (one object per line)
Rotation: files rotate at 5MB → routing-log.jsonl.1, routing-log.jsonl.2

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

### agent-status/ Schema

Location: `~/.claude/agent-status/<agent>-<timestamp>.json`

| Field | Type | Description |
|---|---|---|
| agent | string | Agent name |
| status | string | DONE \| DONE_WITH_CONCERNS \| BLOCKED \| NEEDS_CONTEXT |
| summary | string | One-sentence summary |
| concerns | string \| null | Details if DONE_WITH_CONCERNS |
| recommended_agents | string \| null | Pipe-separated agent recommendations |
| timestamp | ISO8601 string | When status was written |

### task-board.json Schema

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

### Integration Notes

The dashboard should poll routing-log.jsonl and agent-status/ for live session observability.
Agent-level status files are append-only (never overwritten). Read newest file per agent by timestamp in filename.
Task board is mutable — read task-board.json for current state, not history.
