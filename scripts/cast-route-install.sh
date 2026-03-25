#!/bin/bash
# cast-route-install.sh — CAST Route Proposal Manager
# Approve or reject routing proposals, installing approved ones into routing-table.json
#
# Usage:
#   cast-route-install.sh --list              Print pending proposals as JSON
#   cast-route-install.sh --pending-count     Print integer count of pending proposals
#   cast-route-install.sh --approve <ids>     Comma-separated IDs to approve and install
#   cast-route-install.sh --reject <ids>      Comma-separated IDs to mark as rejected

set -euo pipefail

PROPOSALS_FILE="${HOME}/.claude/routing-proposals.json"
ROUTING_TABLE="${HOME}/.claude/config/routing-table.json"
LOG_APPEND="${HOME}/.claude/scripts/cast-log-append.py"

usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") [--list | --pending-count | --approve <ids> | --reject <ids>]

  --list              Print pending proposals as pretty JSON
  --pending-count     Print integer count of pending proposals
  --approve <ids>     Comma-separated proposal IDs to approve and install
  --reject <ids>      Comma-separated proposal IDs to mark as rejected

Exit codes: 0 success, 1 validation error, 2 file not found
USAGE
  exit 1
}

# Require at least one argument
if [ $# -eq 0 ]; then
  usage
fi

MODE="${1:-}"
ARG="${2:-}"

# --pending-count
if [ "$MODE" = "--pending-count" ]; then
  if [ ! -f "$PROPOSALS_FILE" ]; then
    echo "0"
    exit 0
  fi
  python3 -c "
import json, sys
try:
    with open('${PROPOSALS_FILE}') as f:
        data = json.load(f)
    pending = [p for p in data.get('proposals', []) if p.get('status') == 'pending']
    print(len(pending))
except Exception as e:
    print(0)
"
  exit 0
fi

# --list
if [ "$MODE" = "--list" ]; then
  if [ ! -f "$PROPOSALS_FILE" ]; then
    echo '{"proposals":[]}'
    exit 0
  fi
  python3 -c "
import json, sys
try:
    with open('${PROPOSALS_FILE}') as f:
        data = json.load(f)
    pending = [p for p in data.get('proposals', []) if p.get('status') == 'pending']
    print(json.dumps({'proposals': pending}, indent=2))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
"
  exit 0
fi

# --approve
if [ "$MODE" = "--approve" ]; then
  if [ -z "$ARG" ]; then
    echo "Error: --approve requires a comma-separated list of IDs" >&2
    exit 1
  fi
  if [ ! -f "$PROPOSALS_FILE" ]; then
    echo "Error: proposals file not found: ${PROPOSALS_FILE}" >&2
    exit 2
  fi
  if [ ! -f "$ROUTING_TABLE" ]; then
    echo "Error: routing table not found: ${ROUTING_TABLE}" >&2
    exit 2
  fi

  python3 << PYEOF
import json, sys, re, os, shutil, datetime

proposals_file = '${PROPOSALS_FILE}'
routing_table = '${ROUTING_TABLE}'
log_append = '${LOG_APPEND}'
ids_to_approve = [i.strip() for i in '${ARG}'.split(',') if i.strip()]

# Load proposals
with open(proposals_file) as f:
    proposals_data = json.load(f)

proposals_by_id = {p['id']: p for p in proposals_data.get('proposals', [])}

# Load routing table
with open(routing_table) as f:
    routing_data = json.load(f)

# Collect existing patterns for dedup
existing_patterns = set()
for route in routing_data.get('routes', []):
    for p in route.get('patterns', []):
        existing_patterns.add(p)

routes_to_insert = []
errors = []

for prop_id in ids_to_approve:
    if prop_id not in proposals_by_id:
        errors.append(f'Proposal ID not found: {prop_id}')
        continue

    prop = proposals_by_id[prop_id]
    current_status = prop.get('status', 'pending')

    # Idempotent: already installed
    if current_status == 'installed':
        print(f'[skip] {prop_id} is already installed (no-op)')
        continue

    if current_status == 'rejected':
        errors.append(f'Proposal {prop_id} was rejected — cannot approve rejected proposal')
        continue

    patterns = prop.get('patterns', [])

    # Validate each pattern
    for pattern in patterns:
        # Length check
        if len(pattern) > 200:
            errors.append(f'Pattern too long (>{200} chars) in proposal {prop_id}: {pattern[:50]}...')
            continue
        # Regex compile check
        try:
            re.compile(pattern)
        except re.error as e:
            errors.append(f'Invalid regex in proposal {prop_id}: {pattern!r} — {e}')
            continue
        # Dedup check
        if pattern in existing_patterns:
            errors.append(f'Pattern already exists in routing table (proposal {prop_id}): {pattern}')
            continue

    if not errors:
        routes_to_insert.append(prop)

if errors:
    for err in errors:
        print(f'Error: {err}', file=sys.stderr)
    sys.exit(1)

if not routes_to_insert:
    print('No proposals to install.')
    sys.exit(0)

# Backup routing table
backup_path = routing_table + '.bak'
shutil.copy2(routing_table, backup_path)
print(f'Backed up routing table to: {backup_path}')

# Find insertion point: before last entry whose agent == 'router' (catch-all)
routes = routing_data.get('routes', [])
catch_all_idx = None
for i in range(len(routes) - 1, -1, -1):
    if routes[i].get('agent') == 'router' and not routes[i].get('patterns'):
        catch_all_idx = i
        break
# If no pattern-less router entry, insert before last entry
if catch_all_idx is None:
    catch_all_idx = len(routes)

# Build new route objects
new_routes = []
for prop in routes_to_insert:
    new_route = {
        'patterns': prop['patterns'],
        'agent': prop['agent'],
        'model': prop.get('model', 'haiku'),
        'confidence': 'soft',
        'post_chain': [],
    }
    new_routes.append(new_route)
    print(f'Installing route: {prop["id"]} -> {prop["agent"]} (patterns: {prop["patterns"]})')

# Insert new routes before the catch-all
routing_data['routes'] = routes[:catch_all_idx] + new_routes + routes[catch_all_idx:]

# Write updated routing table
with open(routing_table, 'w') as f:
    json.dump(routing_data, f, indent=2)
print(f'Updated routing table: {routing_table}')

# Update proposal statuses
for prop in proposals_data.get('proposals', []):
    if prop['id'] in [p['id'] for p in routes_to_insert]:
        prop['status'] = 'installed'

with open(proposals_file, 'w') as f:
    json.dump(proposals_data, f, indent=2)
print(f'Updated proposal statuses to installed.')

# Log via cast-log-append.py if available
if os.path.exists(log_append):
    import subprocess
    for prop in routes_to_insert:
        log_entry = {
            'action': 'route_installed',
            'matched_route': prop['agent'],
            'pattern': prop['patterns'][0] if prop['patterns'] else '',
            'confidence': 'soft',
        }
        try:
            subprocess.run(
                ['python3', log_append, json.dumps(log_entry)],
                timeout=5, check=False
            )
        except Exception:
            pass

print(f'Done. {len(routes_to_insert)} route(s) installed.')
PYEOF
  exit $?
fi

# --reject
if [ "$MODE" = "--reject" ]; then
  if [ -z "$ARG" ]; then
    echo "Error: --reject requires a comma-separated list of IDs" >&2
    exit 1
  fi
  if [ ! -f "$PROPOSALS_FILE" ]; then
    echo "Error: proposals file not found: ${PROPOSALS_FILE}" >&2
    exit 2
  fi

  python3 << PYEOF
import json, sys

proposals_file = '${PROPOSALS_FILE}'
ids_to_reject = [i.strip() for i in '${ARG}'.split(',') if i.strip()]

with open(proposals_file) as f:
    proposals_data = json.load(f)

proposals_by_id = {p['id']: p for p in proposals_data.get('proposals', [])}
rejected = []

for prop_id in ids_to_reject:
    if prop_id not in proposals_by_id:
        print(f'Warning: proposal ID not found: {prop_id}', file=sys.stderr)
        continue
    prop = proposals_by_id[prop_id]
    if prop.get('status') == 'rejected':
        print(f'[skip] {prop_id} already rejected (no-op)')
        continue
    prop['status'] = 'rejected'
    rejected.append(prop_id)

with open(proposals_file, 'w') as f:
    json.dump(proposals_data, f, indent=2)

if rejected:
    print(f'Rejected {len(rejected)} proposal(s): {", ".join(rejected)}')
else:
    print('No proposals updated.')
PYEOF
  exit $?
fi

# Unknown mode
echo "Error: unknown option: ${MODE}" >&2
usage
