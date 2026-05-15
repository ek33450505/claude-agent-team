# CAST MCP Memory Server — Setup Notes

## Prerequisites

Install the MCP Python SDK:

```bash
pip3 install mcp
```

## MCP Server Registration

The cast-memory MCP server is registered in `.mcp.json` at the repo root. Claude Code will automatically start it when configured.

To verify the server is registered:

```bash
python3 -c "import json; d=json.load(open('.mcp.json')); assert 'cast-memory' in d['mcpServers']; print('OK')"
```

## Weekly Memory Consolidation (Cron)

The consolidation script applies importance decay, deduplicates similar memories, archives low-value ones, and promotes frequently-retrieved memories.

Add this cron entry (runs weekly, Sunday at 3am):

```
0 3 * * 0 python3 $(git rev-parse --show-toplevel)/scripts/cast-memory-consolidate.py >> ~/.claude/logs/memory-consolidate.log 2>&1
```

To run manually:

```bash
# Dry run (no changes):
python3 scripts/cast-memory-consolidate.py --dry-run

# Full run:
python3 scripts/cast-memory-consolidate.py
```

## Preamble Hook Wiring

The preamble hook injects procedural memories into Agent tool calls. Add this to `~/.claude/settings.json` under the `hooks` key:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "bash $(git rev-parse --show-toplevel)/scripts/cast-agent-preamble-hook.sh"
          }
        ]
      }
    ]
  }
}
```

To test the hook manually:

```bash
echo '{"tool_name":"Task","tool_input":{"description":"Run code-writer agent"}}' | bash scripts/cast-agent-preamble-hook.sh
```

## Verification

```bash
# Schema migration (idempotent):
python3 scripts/cast-memory-schema-v4.py

# MCP server starts:
python3 -c "from mcp.server import Server; print('OK')"

# Preamble generator:
python3 scripts/cast-agent-preamble.py --agent planner --types procedural,feedback

# Consolidation dry run:
python3 scripts/cast-memory-consolidate.py --dry-run
```
