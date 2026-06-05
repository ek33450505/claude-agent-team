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

## Observability & cast.db

`cast.db` at `~/.claude/cast.db` — SQLite WAL mode, append-only, never truncated.

| Table | Purpose |
|---|---|
| `swarm_sessions` | Swarm metadata: team_name, started_at, status, merge_strategy |
| `teammate_runs` | Per-agent task tracking: swarm_id, agent_role, status, token counts |
| `teammate_messages` | Peer gossip: from_agent, to_agent, message_type, JSON payload |

**Existing tables:**
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

---

## Native OpenTelemetry (Phase 12)

### Hybrid Observability Model

CAST uses two complementary observability layers that serve different purposes:

**cast.db — the curated CAST store (keep forever)**

| Table | Purpose | OTel analog? |
|---|---|---|
| `routing_events` | Prompt-to-agent routing decisions, matched route, confidence | None |
| `quality_gates` | Gate evaluations, pass/fail per unit | None |
| `dispatch_decisions` | Agent selection rationale, batch context | None |
| `swarm_sessions` | Multi-agent swarm metadata | None |
| `parry_guard_events` | Guard-blocked tool calls (PreToolUse exit 2) | None |
| `agent_truncations` | Context-limit truncation events | None |
| `injection_log` | Memory and context injection audit trail | None |

These tables capture CAST-specific semantics — routing logic, quality enforcement, swarm coordination — that have no equivalent in OpenTelemetry's generic data model. They are NOT candidates for replacement by native OTel.

**Native OTel — generic session/token/latency primitives**

Claude Code's built-in OpenTelemetry support (`CLAUDE_CODE_ENABLE_TELEMETRY=1`) exports generic session metrics (token counts, latency, model invocations) to any OTLP-compatible collector (Prometheus, Jaeger, Grafana, etc.). This is the layer Phase 12 enables.

### How to Enable (Opt-In)

Native OTel is **off by default**. To enable, set `OTEL_EXPORTER_OTLP_ENDPOINT` in your shell or environment:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

When the `SessionStart` hook fires, it detects the endpoint and writes to `CLAUDE_ENV_FILE`:

```
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
```

**With no endpoint configured:** telemetry stays fully off. No `CLAUDE_CODE_ENABLE_TELEMETRY` is exported, no console metric dumps appear in interactive sessions.

**For process-start telemetry** (before the `SessionStart` hook runs): operators can set `CLAUDE_CODE_ENABLE_TELEMETRY=1` directly in their shell profile or `settings.json` env block. The hook adds OTLP routing on top; it does not conflict.

**Do NOT add `CLAUDE_CODE_ENABLE_TELEMETRY=1` to `settings.json`** for daily interactive use — without a collector running, this produces console metric noise on every session.

### Deprecation Candidates

The following cast.db columns track data that native OTel also covers (once a collector is running). They are **NOT dropped now** — 15+ scripts read/write them and the dashboard depends on them.

| Column | Table | Why it's a candidate | Blocker before dropping |
|---|---|---|---|
| `total_input_tokens` | `sessions` | Duplicates OTel `claude_code.token.usage` (input dimension) | Collector confirmed running; dashboard reader migrated to OTel |
| `total_output_tokens` | `sessions` | Duplicates OTel `claude_code.token.usage` (output dimension) | Collector confirmed running; dashboard reader migrated to OTel |
| `input_tokens` | `agent_runs` | Per-dispatch token count, available via OTel span attributes | Collector confirmed running; dashboard reader migrated to OTel |
| `output_tokens` | `agent_runs` | Per-dispatch token count, available via OTel span attributes | Collector confirmed running; dashboard reader migrated to OTel |
| `cost_usd` | `agent_runs` | Cost derived from tokens; OTel has no cost semantic (compute locally from token counts) | Cost calculation migrated to dashboard layer; collector confirmed running |

**Migration path:** A `migration-reviewer` pass is required before any schema change. The dashboard `/token-spend` and `/sessions` pages must be updated to read from OTel before any column is dropped. Until both conditions are met, the columns remain active.
