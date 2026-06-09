#!/usr/bin/env bash
# write-guards.sh — thin wrapper for the merged PreToolUse Write|Edit guard.
# All logic lives in write-guards.py (one python process; keeps this .sh free of
# inline-python invocations for the cold-start lint). Exit 2 = block, 0 = allow/advisory.
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/write-guards.py"
