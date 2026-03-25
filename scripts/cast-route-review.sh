#!/bin/bash
# cast-route-review.sh — Display pending routing proposals in human-readable format
#
# Usage: cast-route-review.sh
#
# Prints a formatted table of pending routing proposals.
# Approval/rejection is handled by calling cast-route-install.sh --approve/--reject.

set -euo pipefail

INSTALL_SCRIPT="${HOME}/.claude/scripts/cast-route-install.sh"

# Check if install script exists
if [ ! -x "$INSTALL_SCRIPT" ]; then
  # Try the repo scripts dir
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  INSTALL_SCRIPT="${SCRIPT_DIR}/cast-route-install.sh"
  if [ ! -x "$INSTALL_SCRIPT" ]; then
    echo "No pending route proposals."
    exit 0
  fi
fi

# Get pending proposals JSON
PENDING_JSON="$("$INSTALL_SCRIPT" --list 2>/dev/null || echo '{"proposals":[]}')"

python3 << PYEOF
import json, sys

pending_json = '''${PENDING_JSON}'''

try:
    data = json.loads(pending_json)
    proposals = data.get('proposals', [])
except Exception:
    proposals = []

if not proposals:
    print('No pending route proposals.')
    sys.exit(0)

n = len(proposals)
print(f'Pending Route Proposals ({n})')
print('=' * 52)

for i, p in enumerate(proposals, 1):
    prop_id = p.get('id', '?')
    patterns = p.get('patterns', [])
    pattern_str = ', '.join(patterns) if patterns else '(none)'
    agent = p.get('agent', '?')
    confidence = p.get('confidence', 'soft')
    frequency = p.get('frequency', 0)
    examples = p.get('example_prompts', [])[:2]

    print(f'{i}. ID: {prop_id}')
    print(f'   Pattern:   {pattern_str}')
    print(f'   Agent:     {agent} ({confidence})')
    print(f'   Frequency: {frequency} events')
    if examples:
        quoted = ', '.join(f'"{e}"' for e in examples)
        print(f'   Examples:  {quoted}')
    if i < n:
        print()

print()
print('-' * 52)
ids = ','.join(p.get('id', '?') for p in proposals)
print(f'To approve: cast-route-install.sh --approve {ids}')
print(f'To reject:  cast-route-install.sh --reject <id>')
PYEOF
