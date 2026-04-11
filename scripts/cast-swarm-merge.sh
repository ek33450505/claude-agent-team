#!/bin/bash
# cast-swarm-merge.sh — Post-swarm merge script
# Verifies all teammates are done, then merges per merge_strategy.
# Safety: never force-merges in-progress work.
#
# Usage: cast-swarm-merge.sh <swarm_id>

set -euo pipefail

SWARM_ID="${1:-}"

if [ -z "$SWARM_ID" ]; then
    echo "Usage: $(basename "$0") <swarm_id>" >&2
    exit 1
fi

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
MANIFEST_FILE="${HOME}/.claude/cast/swarms/${SWARM_ID}.json"

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Error: swarm manifest not found: $MANIFEST_FILE" >&2
    exit 1
fi

MANIFEST_CONTENT="$(cat "$MANIFEST_FILE")"
DB_PATH_VAL="$DB_PATH"
SWARM_ID_VAL="$SWARM_ID"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

MANIFEST_CONTENT="$MANIFEST_CONTENT" \
DB_PATH_VAL="$DB_PATH_VAL" \
SWARM_ID_VAL="$SWARM_ID_VAL" \
GIT_ROOT_VAL="$GIT_ROOT" \
python3 - <<'PYEOF'
import json, os, sqlite3, sys, subprocess
from datetime import datetime, timezone

manifest_raw = os.environ.get("MANIFEST_CONTENT", "")
db_path      = os.environ.get("DB_PATH_VAL", "")
swarm_id     = os.environ.get("SWARM_ID_VAL", "")
git_root     = os.environ.get("GIT_ROOT_VAL", "")

try:
    manifest = json.loads(manifest_raw)
except Exception as e:
    print(f"Error: could not parse manifest: {e}", file=sys.stderr)
    sys.exit(1)

team_name      = manifest.get("team_name", "unknown")
merge_strategy = manifest.get("merge_strategy", "squash")
teammates      = manifest.get("teammates", [])
iso_ts         = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

print(f"Swarm: {swarm_id} ({team_name})")
print(f"Merge strategy: {merge_strategy}")
print(f"Teammates: {len(teammates)}")
print()

# Verify all teammates are done
not_done = []
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_runs'")
        if cur.fetchone():
            cur.execute(
                "SELECT agent_role, status FROM teammate_runs WHERE swarm_id=?",
                (swarm_id,)
            )
            rows = cur.fetchall()
            for role, status in rows:
                if status != "done":
                    not_done.append({"role": role, "status": status})
        conn.close()
    except Exception as e:
        print(f"Warning: could not check teammate status: {e}", file=sys.stderr)
else:
    # Fall back to manifest — warn but proceed
    print("Warning: cast.db not available — cannot verify teammate statuses. Proceeding with manifest data.", file=sys.stderr)

if not_done:
    print("ERROR: Not all teammates are done. Refusing to merge.", file=sys.stderr)
    print("Incomplete teammates:", file=sys.stderr)
    for tm in not_done:
        print(f"  - {tm['role']}: {tm['status']}", file=sys.stderr)
    print("\nWait for all teammates to complete and show Status: DONE, then re-run.", file=sys.stderr)
    sys.exit(1)

# Perform merge
if merge_strategy == "none":
    print("merge_strategy is 'none' — no merge to perform (research/review team).")
    sys.exit(0)

if merge_strategy == "rebase":
    print("merge_strategy 'rebase' is too risky to automate.")
    print()
    print("Manual steps:")
    for tm in teammates:
        branch = tm.get("branch")
        if branch:
            print(f"  git rebase {branch}")
    sys.exit(0)

# squash or merge
merge_errors = []
for tm in teammates:
    branch = tm.get("branch")
    role   = tm.get("role", "unknown")
    if not branch:
        continue

    print(f"Merging {role} ({branch})...")
    if merge_strategy == "squash":
        cmd = ["git", "-C", git_root, "merge", "--squash", "--no-commit", branch]
    else:
        cmd = ["git", "-C", git_root, "merge", branch]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        merge_errors.append({
            "role": role,
            "branch": branch,
            "stderr": result.stderr.strip(),
        })
        print(f"  ERROR: {result.stderr.strip()}", file=sys.stderr)
    else:
        print(f"  OK")

# Update swarm_sessions status to completed
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='swarm_sessions'")
        if cur.fetchone():
            cur.execute(
                "UPDATE swarm_sessions SET status='completed', ended_at=? WHERE id=?",
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
                    "cast-swarm-merge",
                    None,
                    "merge_completed",
                    json.dumps({
                        "merge_strategy": merge_strategy,
                        "errors": merge_errors,
                    }),
                    iso_ts,
                )
            )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Warning: cast.db update failed: {e}", file=sys.stderr)

# Remove worktrees
for tm in teammates:
    worktree = tm.get("worktree")
    if not worktree:
        continue
    role = tm.get("role", "unknown")
    result = subprocess.run(
        ["git", "-C", git_root, "worktree", "remove", worktree],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        print(f"Removed worktree: {role} ({worktree})")
    else:
        print(f"Warning: could not remove worktree {worktree}: {result.stderr.strip()}", file=sys.stderr)

if merge_errors:
    print()
    print(f"Merge completed with {len(merge_errors)} error(s). Review above output.", file=sys.stderr)
    sys.exit(1)
else:
    print()
    if merge_strategy == "squash":
        print("Squash merge staged. Review the diff with `git diff --cached`, then commit with the commit agent.")
    else:
        print("Merge complete.")
PYEOF
