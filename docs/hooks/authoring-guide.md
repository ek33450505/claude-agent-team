# Hook Authoring Guide

CAST hooks are shell scripts that Claude Code runs at lifecycle events — before and after
tool calls, when sessions start, when subagents stop. This guide covers how to write
them, test them, and register them.

---

## 1. Hook Anatomy

A hook script is a Bash script that:
1. Reads a JSON payload from stdin (Claude Code delivers it there)
2. Does its work (log, write to `cast.db`, send a notification, or block a tool call)
3. Exits 0 (pass) or 2 (block — PreToolUse only)

### Stdin JSON shape

Each hook event has its own payload. Common fields across all events:

| Field | Type | Description |
|---|---|---|
| `session_id` | string | Current Claude Code session ID |
| `tool_name` | string | (PreToolUse/PostToolUse) Name of the tool being called |
| `tool_input` | object | (PreToolUse/PostToolUse) Tool call arguments |
| `agent_type` | string | (SubagentStop) Agent that just stopped |
| `stop_reason` | string | (SubagentStop) `"end_turn"`, `"max_turns"`, `"error"` |
| `cwd` | string | (SessionStart, CwdChanged) Working directory |

Read stdin **once**, immediately, before any other work:

```bash
INPUT="$(cat 2>/dev/null || true)"
```

### Stdout: hookSpecificOutput

To return structured feedback to Claude (shown in the session when a PreToolUse hook
blocks), write JSON to stdout:

```bash
echo '{"hookSpecificOutput": {"reason": "dirty worktree — commit or stash first"}}'
```

For hooks that only log (PostToolUse, SubagentStop), stdout is ignored.

### Exit codes

| Code | Effect | When |
|---|---|---|
| 0 | Pass / continue | All hooks |
| 2 | Block tool call | PreToolUse **only** |

Any non-zero exit from a non-PreToolUse hook will interrupt the parent session. Always
use `set +e` (or careful error handling) in SubagentStop and PostToolUse hooks so a
script bug cannot crash the session.

---

## 2. The CLAUDE_SUBPROCESS Guard

Every CAST hook starts with this guard:

```bash
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
```

**Why it exists:** When a hook dispatches a subagent (or any tool call), that subagent
runs in a subprocess context where Claude Code sets `CLAUDE_SUBPROCESS=1`. Without
this guard, the SubagentStop hook would trigger recursively — the new subagent would
stop, trigger SubagentStop again, dispatch another subagent, and so on.

Place this line *before* `set -euo pipefail`, so it fires even if the guard itself
encounters an error.

Full preamble pattern:

```bash
#!/usr/bin/env bash
# my-hook.sh — one-line description

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

_log_error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" \
    >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true
}
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"
```

---

## 3. Writing to cast.db from a Hook

Use the `scripts/cast_db.py` abstraction instead of raw SQLite calls. Pass data via
environment variable to avoid shell-injection in heredoc interpolation:

```bash
export CAST_HOOK_DATA='{"tool":"Bash","session":"ses_01X..."}'

python3 - <<'PYEOF'
import json, os, sys

# Resolve DB path the same way cast_db.py does
db_path = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))

raw = os.environ.get('CAST_HOOK_DATA', '')
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

# Import the abstraction
sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
try:
    from cast_db import db_write
except ImportError:
    sys.exit(0)

db_write('tool_calls', {
    'tool_name':  data.get('tool', ''),
    'session_id': data.get('session', ''),
})
PYEOF
```

Key rules:
- **Always pass data via `os.environ`**, not shell variable interpolation into the
  heredoc body. Interpolating shell vars breaks `json.dumps` escaping and is an
  injection vector.
- Use `sys.path.insert(0, ...)` only when running cast_db.py from a hook heredoc.
  In standalone Python scripts, use an import from the module directly.
- Wrap every db call in try/except — a failed write must not exit non-zero.
- Use `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` with try/except
  when adding new tables from a hook, to keep migrations idempotent.

---

## 4. BATS Testing a Hook

CAST uses [bats-core](https://github.com/bats-core/bats-core) for hook script testing.
Tests live in `tests/` alongside the source.

### Minimal fixture pattern

```bash
# tests/my-hook.bats

setup() {
  # Create a temp dir for test artifacts
  export TMPDIR
  TMPDIR="$(mktemp -d)"
  # Point cast.db at a temp path so tests never touch ~/.claude/cast.db
  export CAST_DB_PATH="${TMPDIR}/test.db"
  # Disable subprocess guard for testing
  export CLAUDE_SUBPROCESS=0
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "passes on valid input" {
  INPUT='{"session_id":"ses_test","tool_name":"Bash"}'
  run bash scripts/my-hook.sh <<< "$INPUT"
  assert_success
}

@test "exits 0 when CLAUDE_SUBPROCESS=1" {
  CLAUDE_SUBPROCESS=1 run bash scripts/my-hook.sh <<< '{}'
  assert_success
  assert_output ""
}
```

Key assertions: `assert_success`, `assert_failure`, `assert_output`, `assert_output --partial`.

Run all tests:

```bash
bats tests/
```

Run a single file:

```bash
bats tests/my-hook.bats
```

---

## 5. Installing a Hook: The managed-settings.d Fragment System

CAST uses a **fragment merge system** to register hooks in `~/.claude/settings.json`
without overwriting the whole file.

Each fragment file in `managed-settings.d/` is a partial `settings.json` containing
only the `"hooks"` key for a specific concern. Naming convention:

```
managed-settings.d/
  00-env.json             # Environment variables
  20-hooks-telemetry.json # Observability hooks
  25-hooks-security.json  # PreToolUse security gates
  30-hooks-session.json   # SessionStart, CwdChanged
  40-hooks-tasks.json     # SubagentStop, PostToolUse
```

Fragment format:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/my-hook.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

`install.sh` merges all fragments into `~/.claude/settings.json` using
`scripts/cast-settings-merge.sh`. Adding your hook to an existing fragment (or a new
numbered fragment) is the correct install path — do not edit `settings.json` by hand.

### Adding a new hook

1. Write your hook script to `scripts/my-hook.sh`
2. Add a fragment (or append to an existing one) in `managed-settings.d/`
3. Run `bash install.sh` to merge
4. Verify with:
   ```bash
   python3 -c "import json; d=json.load(open('$HOME/.claude/settings.json')); print(json.dumps(d['hooks'], indent=2))" | grep my-hook
   ```

---

## See also

- [Example: Log every tool call](./examples/log-every-tool-call.sh)
- [Example: Block on dirty worktree](./examples/block-on-dirty-worktree.sh)
- [Example: Notify on agent stop](./examples/notify-on-agent-stop.sh)
- [Compatibility matrix](../compatibility.md) — which hook events require which Claude Code version
