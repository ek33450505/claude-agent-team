# Stream-JSON Observability Pipeline for CAST

**Date:** 2026-04-10
**Author:** CAST Researcher Agent
**Status:** Research Complete

---

## Concept

Instead of relying on multiple shell hook scripts to log events to cast.db, run Claude Code with `--output-format stream-json` and pipe the full event stream to a consumer process that writes to cast.db.

```
claude -p "task" --output-format stream-json --include-hook-events | cast-stream-consumer
```

## The stream-json Format

When Claude Code runs with `--output-format stream-json`, it emits newline-delimited JSON objects representing every event in the session:

### Event Types
- `system` — system messages, configuration
- `assistant` — Claude's text responses (streamed as deltas)
- `tool_use` — tool invocations (name, parameters)
- `tool_result` — tool outputs
- `error` — errors
- `hook_event` (with `--include-hook-events`) — hook invocations and results

### Sample Event Structure
```json
{"type": "tool_use", "id": "toolu_...", "name": "Bash", "input": {"command": "ls"}, "timestamp": "2026-04-10T14:55:31Z"}
{"type": "tool_result", "id": "toolu_...", "output": "file1.txt\nfile2.txt", "status": "success", "timestamp": "2026-04-10T14:55:32Z"}
{"type": "hook_event", "hook": "PreToolUse", "tool": "Bash", "result": "pass", "timestamp": "2026-04-10T14:55:31Z"}
```

## The --include-hook-events Flag

This flag adds hook execution events to the stream, including:
- Which hooks fired for each event
- Hook execution time
- Hook output (hookSpecificOutput)
- Hook errors (timeout, crash)

Without this flag, hook execution is invisible in the stream.

## Consumer Architecture

### Prototype: Python Consumer

```python
#!/usr/bin/env python3
"""cast-stream-consumer.py — Consume stream-json and write to cast.db"""
import sys
import json
import sqlite3
import os
from datetime import datetime, timezone

DB_PATH = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

def ensure_tables(con):
    """Create stream event tables if they don't exist."""
    con.execute("""
        CREATE TABLE IF NOT EXISTS stream_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            timestamp TEXT,
            event_type TEXT,
            tool_name TEXT,
            tool_input_preview TEXT,
            status TEXT,
            duration_ms INTEGER,
            raw_json TEXT
        )
    """)
    con.execute("""
        CREATE TABLE IF NOT EXISTS stream_hook_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            timestamp TEXT,
            hook_type TEXT,
            tool_name TEXT,
            result TEXT,
            duration_ms INTEGER,
            output TEXT
        )
    """)
    con.commit()

def process_event(con, session_id, event):
    """Route a stream event to the appropriate table."""
    event_type = event.get('type', '')
    timestamp = event.get('timestamp', datetime.now(timezone.utc).isoformat())

    if event_type in ('tool_use', 'tool_result'):
        con.execute("""
            INSERT INTO stream_events
                (session_id, timestamp, event_type, tool_name, tool_input_preview, status)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            session_id, timestamp, event_type,
            event.get('name', ''),
            json.dumps(event.get('input', ''))[:200],
            event.get('status', '')
        ))
    elif event_type == 'hook_event':
        con.execute("""
            INSERT INTO stream_hook_events
                (session_id, timestamp, hook_type, tool_name, result, duration_ms, output)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (
            session_id, timestamp,
            event.get('hook', ''),
            event.get('tool', ''),
            event.get('result', ''),
            event.get('duration_ms', 0),
            json.dumps(event.get('output', ''))[:500]
        ))
    con.commit()

def main():
    session_id = os.environ.get('CLAUDE_SESSION_ID', 'stream-' + datetime.now().strftime('%Y%m%d%H%M%S'))
    con = sqlite3.connect(DB_PATH, timeout=5)
    ensure_tables(con)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            process_event(con, session_id, event)
        except json.JSONDecodeError:
            continue
        except Exception as e:
            sys.stderr.write(f"Stream consumer error: {e}\n")

    con.close()

if __name__ == '__main__':
    main()
```

### Usage

```bash
# Headless pipeline mode
claude -p "run the BATS tests" \
  --output-format stream-json \
  --include-hook-events \
  | python3 ~/.claude/scripts/cast-stream-consumer.py

# Background mode with tee
claude -p "task" --output-format stream-json --include-hook-events \
  | tee >(python3 ~/.claude/scripts/cast-stream-consumer.py) \
  | jq -r 'select(.type == "assistant") | .content // empty'
```

## Performance Analysis

### Process Overhead Comparison

| Approach | Overhead per event | Processes spawned |
|---|---|---|
| Current (command hooks) | ~50-100ms (bash subprocess) | 1 per hook per event |
| Stream consumer | ~1-5ms (JSON parse + SQLite write) | 1 total (persistent) |

### Throughput

- Stream-json output: ~100-500 events per session
- SQLite write speed: ~50,000 inserts/second
- **Bottleneck:** Not the consumer. It's the Claude API response speed.

### Memory

- Consumer memory: ~10-20MB (Python process + SQLite connection)
- Current hooks total: ~5-15MB per active hook process (but short-lived)

**Conclusion:** Stream consumer is significantly more efficient than per-hook command subprocesses.

## What This Replaces

| Current Hook | Replaced by Stream? | Notes |
|---|---|---|
| cast-session-start-hook.sh | Partially | Stream starts after session, so session start is implicit |
| cast-audit-hook.sh | Yes | Tool use events are in the stream |
| post-tool-hook.sh | Yes | Tool results are in the stream |
| cast-cost-tracker.sh | Partially | Token counts are in the stream, but budget logic needs consumer |
| cast-tool-failure-hook.sh | Yes | PostToolUseFailure events are in the stream |
| cast-security-guard.sh | No | PreToolUse blocking requires exit code 2 — stream is read-only |
| pre-tool-guard.sh | No | Same — blocking hooks must remain as command hooks |
| cast-headless-guard.sh | No | Same — blocking hooks |
| cast-stop-hook.sh | No | Needs to produce hookSpecificOutput |

## What Still Needs Hook Scripts

**All blocking hooks must remain as command hooks.** The stream is a read-only observation of events — it cannot block tool execution. Specifically:

1. **PreToolUse hooks that return exit 2** (security guards, permission checks)
2. **Hooks that produce hookSpecificOutput** (stop reminder, worktree setup)
3. **TeammateIdle hooks** (return feedback to the agent)
4. **Any hook that modifies the session's behavior**

## Coexistence Strategy

The stream consumer can coexist with existing hooks:

```
                     ┌──────────────────┐
                     │  Claude Session   │
                     │                   │
                     │  PreToolUse ──────┼──── Blocking hooks (command)
                     │  PostToolUse ─────┼──── Non-blocking hooks (command)
                     │                   │
                     │  stream-json ─────┼──── Consumer (writes to cast.db)
                     │  + hook events    │
                     └──────────────────┘
```

- Blocking hooks: keep as command hooks (security, guards)
- Non-blocking telemetry: migrate to stream consumer
- Result: fewer subprocess spawns, centralized logging, real-time data

## Recommendation

**GO — Phase 1 (Coexist)**

1. Build `cast-stream-consumer.py` as shown above
2. Integrate into `cast-tmux-session.sh` pipeline (pipe claude through consumer)
3. Keep all blocking hooks as command hooks
4. Gradually remove non-blocking command hooks (telemetry, logging) as the consumer handles them
5. Add a `--stream` flag to `cast-tmux-session.sh` to opt into the pipeline

**Phase 2 (Optimize)**
- Remove cast-audit-hook.sh, post-tool-hook.sh, cast-tool-failure-hook.sh
- Consumer handles all telemetry
- Remaining command hooks: only blocking guards + session lifecycle

## Limitations

1. **Interactive mode:** Stream-json only works with `-p` (programmatic mode), not interactive sessions
2. **Dashboard integration:** Consumer writes to cast.db, but dashboard still needs to poll DB (no push)
3. **Hook events flag:** `--include-hook-events` may increase output volume and is still evolving
4. **Session ID:** Must be passed via environment or extracted from the stream's initial system event
