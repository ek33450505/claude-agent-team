#!/bin/bash
# cast-rtk-hook.sh — Optional RTK token compression PreToolUse hook
# RTK compresses large tool output before it enters Claude Code context.
# No-op if rtk binary not found.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

# If rtk not installed, pass through unchanged
if ! command -v rtk >/dev/null 2>&1; then
  echo "$INPUT"
  exit 0
fi

# Pipe tool output through rtk compression
echo "$INPUT" | rtk compress 2>/dev/null || echo "$INPUT"
exit 0
