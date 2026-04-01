#!/usr/bin/env bash
# CAST TeammateIdle hook
# Fired when an agent team teammate goes idle.
# Exit 0 = done (acceptable). Exit 2 = send feedback to keep working.

set -euo pipefail

INPUT=$(cat)

# Check if teammate produced any output
RESULT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo "")

if [ -z "$RESULT" ]; then
  echo '{"feedback": "Your task produced no output. Please complete the assigned work before going idle. Review your task description and produce the required artifacts."}'
  exit 2
fi

# Check for placeholder/incomplete markers
if echo "$RESULT" | grep -qiE '(TODO|FIXME|PLACEHOLDER|NOT IMPLEMENTED|to be implemented)'; then
  echo '{"feedback": "Your output contains TODO or placeholder markers. Please complete the implementation before going idle."}'
  exit 2
fi

exit 0
