#!/bin/bash
# cast-swarm-teardown.sh — Emergency swarm cleanup
# Removes all worktrees for a swarm regardless of teammate status.
# Requires --force or interactive confirmation.
#
# Usage: cast-swarm-teardown.sh [--force] <swarm_id>

set -euo pipefail

FORCE=0
SWARM_ID=""

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) SWARM_ID="$arg" ;;
    esac
done

if [ -z "$SWARM_ID" ]; then
    echo "Usage: $(basename "$0") [--force] <swarm_id>" >&2
    exit 1
fi

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
MANIFEST_FILE="${HOME}/.claude/cast/swarms/${SWARM_ID}.json"

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Error: swarm not found: $SWARM_ID" >&2
    exit 1
fi

# Confirm unless --force
if [ "$FORCE" -eq 0 ]; then
    echo "WARNING: This will remove all worktrees for swarm $SWARM_ID regardless of status."
    echo "Any in-progress work in teammate worktrees will be lost."
    printf "Type 'yes' to confirm: "
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

MANIFEST_CONTENT="$(cat "$MANIFEST_FILE")"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

MANIFEST_CONTENT="$MANIFEST_CONTENT" \
DB_PATH_VAL="$DB_PATH" \
SWARM_ID_VAL="$SWARM_ID" \
GIT_ROOT_VAL="$GIT_ROOT" \
MANIFEST_FILE_VAL="$MANIFEST_FILE" \
python3 - <<'PYEOF'
import json, os, sqlite3, sys, subprocess, shutil
from datetime import datetime, timezone

manifest_raw  = os.environ.get("MANIFEST_CONTENT", "")
db_path       = os.environ.get("DB_PATH_VAL", "")
swarm_id      = os.environ.get("SWARM_ID_VAL", "")
git_root      = os.environ.get("GIT_ROOT_VAL", "")
manifest_file = os.environ.get("MANIFEST_FILE_VAL", "")

try:
    manifest = json.loads(manifest_raw)
except Exception as e:
    print(f"Error: could not parse manifest: {e}", file=sys.stderr)
    sys.exit(1)

teammates = manifest.get("teammates", [])
iso_ts    = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

print(f"Tearing down swarm: {swarm_id}")
print(f"Removing {len(teammates)} teammate worktree(s)...")

# Remove each worktree
for tm in teammates:
    worktree = tm.get("worktree")
    role     = tm.get("role", "unknown")

    if not worktree:
        print(f"  {role}: no worktree (read-only) — skipping")
        continue

    # Try graceful remove first, then force
    result = subprocess.run(
        ["git", "-C", git_root, "worktree", "remove", worktree],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["git", "-C", git_root, "worktree", "remove", "--force", worktree],
            capture_output=True, text=True
        )

    if result.returncode == 0:
        print(f"  {role}: removed ({worktree})")
    else:
        print(f"  {role}: WARNING — could not remove {worktree}: {result.stderr.strip()}", file=sys.stderr)
        # Try to clean up the directory directly as last resort
        try:
            if os.path.exists(worktree):
                shutil.rmtree(worktree)
                print(f"  {role}: forcibly removed directory {worktree}")
        except Exception as rm_err:
            print(f"  {role}: ERROR — could not remove directory: {rm_err}", file=sys.stderr)

# Update cast.db
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='swarm_sessions'")
        if cur.fetchone():
            cur.execute(
                "UPDATE swarm_sessions SET status='failed', ended_at=? WHERE id=?",
                (iso_ts, swarm_id)
            )
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_messages'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO teammate_messages
                   (id, swarm_id, from_agent, to_agent, message_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (
                    __import__("uuid").uuid4().hex[:16],
                    swarm_id,
                    "cast-swarm-teardown",
                    None,
                    "teardown",
                    json.dumps({"reason": "emergency_teardown"}),
                    iso_ts,
                )
            )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Warning: cast.db update failed: {e}", file=sys.stderr)

# Remove manifest file
try:
    os.remove(manifest_file)
    print(f"Removed manifest: {manifest_file}")
except Exception as e:
    print(f"Warning: could not remove manifest: {e}", file=sys.stderr)

print(f"\nSwarm {swarm_id} torn down. Status set to 'failed' in cast.db.")
PYEOF
