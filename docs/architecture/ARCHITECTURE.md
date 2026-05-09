# CAST Architecture

> Extracted from [README](../../README.md). See also: [Protocol Spec](cast-protocol-spec.md)

## Architecture

CAST operates as the native Agent Teams companion — Anthropic handles execution parallelism, CAST handles definition, composition, and observability.

```
Agent Teams (Anthropic Native)
    ↓
    └─ CAST Swarm Bootstrap
        ├─ Parse YAML team definition
        ├─ Create worktree per teammate
        ├─ Seed agent identity + quality gates preamble
        └─ Stream events → cast.db
            ├─ swarm_sessions table
            ├─ teammate_runs table (per-agent task tracking)
            └─ teammate_messages table (peer gossip)
```

<p align="center">
  <img src="cast-architecture.svg" alt="CAST swarm architecture" />
</p>

### Where CAST extends Agent Teams

| Agent Teams (native) | CAST (on top) | Design rationale |
|---|---|---|
| Parallel agent execution | Swarm bootstrap + composition layer | Lift team definition out of code, standardize YAML config |
| No cross-agent messaging | Peer gossip protocol (cast.db message bus) | Agents collaborate without central broker |
| Hook system exists | Production-hardened hooks: TeammateIdle, TaskCreated, TaskCompleted, WorktreeCreate | Real-time swarm lifecycle events |
| Model selection per-session | Per-task routing: Haiku → Ollama (cheap), Sonnet → Claude (smart) | Automatic cost optimization |
| No persistent audit trail | `cast.db` v8: 31 tables including swarm_sessions, teammate_runs, teammate_messages, agent_runs, routing_events, agent_memories, quality_gates, parry_guard_events, worktree_anomalies, and more — with temporal indices | Queryable, immutable swarm history |
| No visual observability | Constellation Dashboard: force-directed agent graph + task satellites (React 19 + D3) | Live swarm topology + task flow |
| No agent response schema | Structured Output JSON schemas (`schemas/`) defining status-block, work-log, routing-event contracts | Machine-readable agent response contract for API pipelines |

---

## Swarm System

### Define a Team (YAML)

```yaml
# swarm-configs/fullstack-team.yml
team_name: fullstack
description: "Full-stack feature implementation with review loop"

teammates:
  - role: frontend
    agent_def: code-writer
    task: "Implement React component for feature X"
    model: claude-sonnet-4-6
  - role: backend
    agent_def: code-writer
    task: "Implement Express API route and database migration"
    model: claude-sonnet-4-6
  - role: reviewer
    agent_def: code-reviewer
    task: "Review all changes from frontend and backend before merge"
    model: claude-haiku-4-5

quality_gates:
  require_reviewer: true
  commit_agent_only: true
  pre_merge_review: true
  
merge_strategy: squash  # squash | merge | rebase
```

### Bootstrap and Run

```bash
# Spawn the swarm
cast swarm bootstrap swarm-configs/fullstack-team.yml

# Monitor in real time
cast swarm status <swarm_id>

# Merge results when done
cast swarm merge <swarm_id>
```

Under the hood:
1. CAST creates isolated git worktrees per teammate
2. Each teammate gets a Claude Code terminal with agent identity preamble
3. Agent Teams parallelizes execution; CAST emits lifecycle events
4. Peer messages route through cast.db message bus
5. Dashboard displays force-directed graph of all teammates + active tasks

---

## Peer Messaging & Gossip Protocol

Teammates communicate via cast.db message bus — no central broker, fully decentralized:

```json
{
  "message_type": "task_claim",
  "from_agent": "backend",
  "to_agent": "reviewer",
  "payload": {
    "task_id": "task-123",
    "subject": "Implement POST /users route",
    "status": "complete",
    "files_changed": ["/src/routes/users.ts"]
  }
}
```

Message types:
- **task_claim** — Agent announces it's starting a task
- **status_update** — Agent reports progress or completion
- **peer_query** — Agent asks other teammate for information
- **idle_event** — Agent is waiting for next task

All messages are logged to `teammate_messages` table with timestamps, enabling full swarm replay and debugging.

---

## Memory Pipeline

CAST persists agent-discovered knowledge across sessions via `cast-memory-router.py`:

**Save flow (SubagentStop hook):**
1. Agent emits a `## Facts` block in its response (pipe-delimited: `name | type | content`)
2. `post-tool-hook.sh` fires on `SubagentStop`, extracts the Facts block
3. `cast-memory-router.py` validates each entry (slug name, known type, ≤500 char content) and writes to `agent_memories` table in `cast.db`
4. Malformed lines are skipped silently; valid entries are upserted by name

**Retrieval flow (SessionStart / UserPromptSubmit hooks):**
1. `cast-user-prompt-hook.sh` calls `cast-memory-router.py --query` with the incoming prompt text
2. Router searches `agent_memories` using keyword matching; high-confidence entries (confidence ≥ 0.7) are injected into session context
3. Agent definitions also read their own `~/.claude/agent-memory-local/<agent>/MEMORY.md` file at task start for agent-scoped persistent memory

**Memory types:** `user`, `feedback`, `project`, `reference`, `procedural`

**DB table:** `agent_memories` — columns: `name` (slug, unique), `type`, `content`, `description`, `confidence`, `created_at`, `updated_at`
