#!/usr/bin/env bash
# cast-command-guard.sh — thin wrapper for the PreToolUse Bash command-guard.
# Logic lives in cast-command-guard.py (one python process). Exit 2 = block, 0 = allow.
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cast-command-guard.py"
