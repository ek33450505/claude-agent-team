# Channels as CAST Event Bus

**Date:** 2026-04-10
**Author:** CAST Researcher Agent
**Status:** Research Complete

---

## What Are Channels?

The `--channels` flag in Claude Code enables MCP servers to push structured events into the session stream. This creates a bidirectional communication channel between external services and the Claude Code session.

Key characteristics:
- MCP servers can publish events to named channels
- The session receives events as structured JSON
- Events can trigger Claude actions or be logged passively
- Low-latency, integrated into the session event loop

## Current CAST Event Architecture

```
                      BEFORE (Current)
    ┌──────────────────────────────────────────────┐
    │                Claude Session                  │
    │                                                │
    │  Hook Script ─── cast_emit_event() ───┐       │
    │  Hook Script ─── cast_emit_event() ───┤       │
    │  Hook Script ─── cast_emit_event() ───┤       │
    │                                       ▼       │
    │                              cast/events/     │
    │                              (JSON files)     │
    │                                   │           │
    │                                   ▼           │
    │                              cast.db          │
    │                           (SQLite tables)     │
    └──────────────────────────────────────────────┘
```

Each hook script independently:
1. Receives event JSON via stdin
2. Processes it locally
3. Calls `cast_emit_event` to write a JSON file to `~/.claude/cast/events/`
4. Optionally writes to cast.db via `cast_db.py`

Problems with current approach:
- Each hook is a separate bash subprocess (process overhead)
- No centralized event stream (events scattered across files)
- No real-time visibility (must poll files or query DB)
- Event format varies between hooks

## Proposed Channels Architecture

```
                       AFTER (Channels)
    ┌──────────────────────────────────────────────┐
    │                Claude Session                  │
    │                     │                          │
    │           ┌─────────┼─────────┐               │
    │           ▼         ▼         ▼               │
    │       Hook A    Hook B    Hook C              │
    │           │         │         │               │
    │           └─────────┼─────────┘               │
    │                     ▼                          │
    │            Channel: "cast-events"              │
    │                     │                          │
    │           ┌─────────┼─────────┐               │
    │           ▼         ▼         ▼               │
    │      cast.db    Dashboard   Alerts            │
    │     (consumer)  (consumer)  (consumer)        │
    └──────────────────────────────────────────────┘
```

With channels:
1. Hooks publish events to a named channel (`cast-events`)
2. Multiple consumers can subscribe to the channel
3. Events are structured and typed
4. Real-time visibility without polling

## Feasibility Assessment

### What Channels Provide
- Native event streaming within Claude Code sessions
- Structured JSON event format
- Multiple consumer support
- Low overhead (no subprocess per event)

### What Channels Do NOT Provide
- Cross-session event persistence (channels are session-scoped)
- External service integration out of the box (need an MCP server as bridge)
- Backward compatibility with file-based events

### Current Stability
- Channels are available as of Claude Code v2.1.90+
- API is evolving but core publish/subscribe is stable
- Limited documentation and community adoption so far

## Migration Path

### Phase 1: Parallel Mode
- Keep existing `cast_emit_event` file-based system
- Add a channel publisher that mirrors events to a `cast-events` channel
- Dashboard can subscribe to the channel for real-time updates
- No breaking changes

### Phase 2: Channel-First
- New hooks publish directly to channels
- A single consumer process writes to cast.db (replaces per-hook DB writes)
- File-based events become a fallback

### Phase 3: Full Migration
- Remove file-based event system
- All events flow through channels
- Single consumer handles cast.db persistence
- Dashboard reads from channel in real-time

## Implementation Sketch

### Channel Publisher (MCP Server)
```python
# cast-channel-server.py — MCP server for CAST event channel
# Publishes events to "cast-events" channel
# Consumes from channel and writes to cast.db

async def publish_event(channel, event_type, agent, data):
    await channel.publish({
        "type": event_type,
        "agent": agent,
        "timestamp": datetime.utcnow().isoformat(),
        "data": data
    })
```

### Hook Integration
```bash
# In hook scripts, replace:
#   cast_emit_event 'task_completed' 'agent' ...
# With:
#   cast_channel_publish 'task_completed' 'agent' ...
# (thin wrapper that publishes to the MCP channel)
```

## Limitations and Edge Cases

1. **Session scope:** Channels die when the session ends. Need cast.db for persistence.
2. **MCP dependency:** Requires an MCP server running. Adds startup overhead.
3. **Error handling:** If the channel consumer crashes, events are lost (no replay).
4. **Multi-session:** Each session has its own channels. Cross-session events still need file/DB.

## Recommendation

**PARTIAL GO** — Channels are a strong complement to the existing system but cannot fully replace it. The file-based system provides persistence and cross-session visibility. The recommended approach:

1. Add channel publishing as an additional output (Phase 1)
2. Use channels for real-time dashboard updates
3. Keep cast.db as the source of truth for historical data
4. Revisit full migration when channels support persistence or cross-session events
