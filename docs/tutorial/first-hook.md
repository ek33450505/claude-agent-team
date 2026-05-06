# How Hooks Work

This is Part 3 of the CAST tutorial. It covers what hook events are, how CAST wires
them into Claude Code, and how to verify a hook fired by querying `cast.db`.

**Prerequisite:** Complete [Part 2 — First Agent Dispatch](./first-agent-dispatch.md).

---

## What is a hook event?

Claude Code fires **hook events** at key lifecycle points during a session:

| Event | When it fires |
|---|---|
| `SessionStart` | Once when a new session starts |
| `PreToolUse` | Before Claude invokes any tool (Bash, Write, Edit, etc.) |
| `PostToolUse` | After a tool call completes |
| `SubagentStop` | When a dispatched subagent finishes |
| `StopFailure` | When an agent API call fails mid-task |
| `PreCompact` | Before the `/compact` context summary runs |
| `CwdChanged` | When the working directory changes |

Each event delivers a JSON payload on stdin to any hook scripts you've registered. The
script reads the payload, does its work (log to a file, write to `cast.db`, send a
notification), and exits. Hook scripts do not modify Claude's response — they are
observers and, for `PreToolUse` only, blockers.

---

## How CAST wires hooks

CAST registers its hook scripts in `~/.claude/settings.json` under the `"hooks"` key.
After installation, that section looks like:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/cast-session-start-hook.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/cast-subagent-stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

When Claude Code fires a `SubagentStop` event (because a dispatched agent just finished),
it runs the registered command and passes the event JSON on stdin. CAST's script parses
the agent name, status, and output, then writes a row to `cast.db`.

---

## The CLAUDE_SUBPROCESS guard

CAST hook scripts begin with this guard:

```bash
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
```

When a hook script runs inside a subagent's context (not the parent session), Claude Code
sets `CLAUDE_SUBPROCESS=1`. Without this guard, hook scripts would fire recursively —
the SubagentStop hook would trigger a new subagent, which would trigger SubagentStop
again, and so on. The guard short-circuits that loop immediately.

This is the first line in every CAST hook script. Write it before `set -euo pipefail`.

---

## Exit codes and blocking

Hook scripts communicate with Claude Code via exit code:

- **Exit 0** — pass/continue; Claude Code proceeds normally
- **Exit 2** — **block** (PreToolUse hooks only); Claude Code cancels the tool call and
  shows the hook's stdout as the reason

All non-PreToolUse hooks must exit 0. A SubagentStop hook that exits non-zero would
interrupt the parent session, which is always wrong.

---

## Verify a hook fired: check cast.db

After any agent dispatch or tool call, you can query `cast.db` to confirm the hook ran:

```bash
sqlite3 ~/.claude/cast.db \
  "SELECT event_type, payload, created_at
   FROM routing_events
   ORDER BY created_at DESC
   LIMIT 5;"
```

For session starts specifically:

```bash
cat ~/.claude/cast/session-starts.jsonl | tail -3
```

Expected output (one JSON object per line):

```json
{"session_id":"ses_01Xabc...","cwd":"/Users/you/project","ts":"2026-05-06T14:20:00Z"}
```

---

## What just happened (conceptually)

When you opened a Claude Code session earlier:
1. Claude Code fired `SessionStart` with `{"session_id":"...","cwd":"..."}`
2. `cast-session-start-hook.sh` received that JSON on stdin
3. The script parsed it and appended a line to `~/.claude/cast/session-starts.jsonl`
4. The script exited 0 — Claude Code continued normally

You didn't see any of this. Hooks are silent by default. The only evidence is the log
entries they write.

---

## Next steps

You've completed the CAST tutorial. From here:

- **Write your own hook:** [Hook Authoring Guide](../hooks/authoring-guide.md)
- **Check version compatibility:** [Compatibility Matrix](../compatibility.md)
- **Explore the agent roster:** [docs/agents/AGENT-ROSTER.md](../agents/AGENT-ROSTER.md)
- **Full documentation index:** [docs/README.md](../README.md)
