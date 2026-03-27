#!/bin/bash
# cast-mismatch-analyzer.sh — Generate route proposals from mismatch signals
# Reads mismatch_signals table; for routes with >= 10 signals, adds a
# pending proposal to routing-proposals.json with source='mismatch'.
#
# Usage: cast-mismatch-analyzer.sh [--threshold N]   (default: 10)

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
PROPOSALS_PATH="${HOME}/.claude/routing-proposals.json"
THRESHOLD=10

if [ "${1:-}" = "--threshold" ] && [ -n "${2:-}" ]; then
  THRESHOLD="${2}"
fi

if [ ! -f "$DB_PATH" ]; then
  echo "cast.db not found at $DB_PATH — nothing to analyze" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found in PATH" >&2
  exit 1
fi

python3 - <<PYEOF
import sqlite3, json, os, sys

db_path = "${DB_PATH}"
proposals_path = "${PROPOSALS_PATH}"
threshold = int("${THRESHOLD}")

# Connect to DB
try:
    conn = sqlite3.connect(db_path)
except Exception as e:
    print(f"Error connecting to DB: {e}", file=sys.stderr)
    sys.exit(0)

# Check table exists
try:
    conn.execute("SELECT 1 FROM mismatch_signals LIMIT 1")
except sqlite3.OperationalError:
    print("mismatch_signals table not found — run cast-db-init.sh first", file=sys.stderr)
    conn.close()
    sys.exit(0)

# Query routes with enough signals
rows = conn.execute("""
    SELECT route_fired,
           COUNT(*) as cnt,
           GROUP_CONCAT(follow_up_prompt, '|||')
    FROM mismatch_signals
    GROUP BY route_fired
    HAVING cnt >= ?
""", (threshold,)).fetchall()
conn.close()

# Load existing proposals
existing_proposals = {}
if os.path.exists(proposals_path):
    try:
        with open(proposals_path) as f:
            data = json.load(f)
            if isinstance(data, list):
                for p in data:
                    existing_proposals[p['id']] = p
            elif isinstance(data, dict):
                for pid, p in data.items():
                    existing_proposals[pid] = p
    except Exception:
        pass

new_count = 0
updated_count = 0

for route_fired, cnt, follow_ups_raw in rows:
    prop_id = f"mismatch-{route_fired}"
    follow_ups = [s.strip() for s in (follow_ups_raw or '').split('|||') if s.strip()]
    example_prompts = follow_ups[:3]

    suggestion = (
        f"Review pattern(s) for agent {route_fired} — "
        f"{cnt} rapid re-prompts detected after this route fired."
    )

    existing = existing_proposals.get(prop_id)
    if existing:
        existing_status = existing.get('status', 'pending')
        if existing_status in ('installed', 'rejected'):
            continue
        # Update frequency on existing pending proposal
        existing_proposals[prop_id]['frequency'] = cnt
        existing_proposals[prop_id]['example_prompts'] = example_prompts
        updated_count += 1
    else:
        existing_proposals[prop_id] = {
            'id': prop_id,
            'source': 'mismatch',
            'route_fired': route_fired,
            'frequency': cnt,
            'example_prompts': example_prompts,
            'suggestion': suggestion,
            'status': 'pending',
        }
        new_count += 1

# Write back
os.makedirs(os.path.dirname(proposals_path) if os.path.dirname(proposals_path) else '.', exist_ok=True)
with open(proposals_path, 'w') as f:
    json.dump(list(existing_proposals.values()), f, indent=2)

print(f"Mismatch proposals: {new_count} new, {updated_count} updated")
PYEOF
