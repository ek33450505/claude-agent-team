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
# Resolve the scripts directory from BASH_SOURCE so the Python heredoc can locate
# cast_guard.py without relying on __file__ (which resolves to stdin in heredocs).
SCRIPTS_DIR_VAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFEST_CONTENT="$MANIFEST_CONTENT" \
DB_PATH_VAL="$DB_PATH" \
SWARM_ID_VAL="$SWARM_ID" \
GIT_ROOT_VAL="$GIT_ROOT" \
MANIFEST_FILE_VAL="$MANIFEST_FILE" \
SCRIPTS_DIR_VAL="$SCRIPTS_DIR_VAL" \
python3 - <<'PYEOF'
import json, os, sqlite3, sys, subprocess
from datetime import datetime, timezone

# Inject the scripts dir (resolved in bash via BASH_SOURCE) so cast_guard is importable.
# __file__ is not usable inside a heredoc — it resolves to stdin.
_scripts_dir = os.environ.get("SCRIPTS_DIR_VAL", "")
if _scripts_dir:
    sys.path.insert(0, _scripts_dir)
from cast_guard import safe_rmtree

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

# SAFETY GUARD (§3.8.A): refuse to delete any path that is not a non-empty
# absolute path under the allowed swarm worktree root (/tmp/cast-swarm-*).
# A manifest whose "worktree" value is empty, ".", "/", a home directory, or
# anything containing "/.claude" must never drive an unbounded delete.
# Path is canonicalized via os.path.realpath before checking, which:
#   (a) collapses ".." sequences (preventing directory traversal)
#   (b) resolves symlinks including macOS /tmp -> /private/tmp
def _is_safe_worktree(path):
    if not path or not os.path.isabs(path):
        return False
    # Canonicalize: collapses '..' and resolves symlinks (incl. macOS /tmp -> /private/tmp)
    real = os.path.realpath(path)
    # Never touch anything that looks like a runtime/home path
    if '/.claude' in real or '/.claude' in path:
        return False
    home = os.path.expanduser('~').rstrip('/')
    if real in ('', '/', home):
        return False
    # Must live under the swarm worktree root (handle both /tmp and macOS /private/tmp)
    allowed_roots = ('/tmp/cast-swarm-', '/private/tmp/cast-swarm-')
    if not any(real.startswith(r) for r in allowed_roots):
        return False
    return True

# Collect checked-out branches once (for the branch-deletion guard below)
wt_check = subprocess.run(
    ["git", "-C", git_root, "worktree", "list", "--porcelain"],
    capture_output=True, text=True
)
checked_out_branches = set()
for wt_line in wt_check.stdout.splitlines():
    if wt_line.startswith("branch "):
        # "branch refs/heads/<name>"
        checked_out_branches.add(wt_line.split("/")[-1])

# Remove each worktree and delete the associated branch
for tm in teammates:
    worktree = tm.get("worktree")
    role     = tm.get("role", "unknown")

    # ── Worktree removal ──────────────────────────────────────────────────
    if not worktree:
        print(f"  {role}: no worktree (read-only) — skipping worktree removal")
    elif not _is_safe_worktree(worktree):
        print(
            f"  {role}: REFUSED — worktree path '{worktree}' is outside allowed "
            f"/tmp/cast-swarm-* root; skipping to prevent accidental data loss (§3.8.A)",
            file=sys.stderr
        )
    else:
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
            # Try to clean up the directory directly as last resort.
            # SAFETY: path was validated by _is_safe_worktree above;
            # safe_rmtree enforces the swarm blast-radius as an additional layer.
            try:
                if os.path.exists(worktree):
                    safe_rmtree(worktree, f"/tmp/cast-swarm-{swarm_id}", label="swarm-teardown")
                    print(f"  {role}: forcibly removed directory {worktree}")
            except Exception as rm_err:
                print(f"  {role}: ERROR — could not remove directory: {rm_err}", file=sys.stderr)

    # ── Branch deletion ───────────────────────────────────────────────────
    # Reconstruct branch name using the same convention as bootstrap:
    #   cast-swarm-<swarm_id>-<role>
    # This runs for EVERY teammate, regardless of whether they had a worktree.
    branch_name = f"cast-swarm-{swarm_id}-{role}"
    # PREFIX GUARD: only ever delete cast-swarm-* branches.
    if not branch_name.startswith("cast-swarm-"):
        print(f"  {role}: SKIP branch deletion — '{branch_name}' is not a cast-swarm-* branch", file=sys.stderr)
    elif branch_name in checked_out_branches:
        # Cannot delete a branch that is currently checked out in a worktree
        print(f"  {role}: SKIP branch deletion — '{branch_name}' is checked out in a worktree")
    else:
        del_result = subprocess.run(
            ["git", "-C", git_root, "branch", "-D", branch_name],
            capture_output=True, text=True
        )
        if del_result.returncode == 0:
            print(f"  {role}: deleted branch '{branch_name}'")
        else:
            # Defensive: a failed delete must not abort teardown
            print(
                f"  {role}: WARNING — could not delete branch '{branch_name}': "
                f"{del_result.stderr.strip()}",
                file=sys.stderr
            )

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
