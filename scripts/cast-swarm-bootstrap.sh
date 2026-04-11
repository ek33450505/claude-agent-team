#!/bin/bash
# cast-swarm-bootstrap.sh — CAST Swarm Bootstrap Engine
# Reads a YAML team config and sets up git worktrees + cast.db rows for a swarm.
#
# Usage: cast-swarm-bootstrap.sh <config.yml> "<task description>"
#
# Outputs: JSON manifest to stdout + ~/.claude/cast/swarms/<swarm_id>.json

set -euo pipefail

CONFIG_FILE="${1:-}"
TASK_DESC="${2:-}"

if [ -z "$CONFIG_FILE" ] || [ -z "$TASK_DESC" ]; then
    echo "Usage: $(basename "$0") <config.yml> \"<task description>\"" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
SWARMS_DIR="${HOME}/.claude/cast/swarms"
mkdir -p "$SWARMS_DIR"

CONFIG_ABS="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

CONFIG_CONTENT="$(cat "$CONFIG_ABS")"
TASK_CONTENT="$TASK_DESC"
DB_PATH_VAL="$DB_PATH"
SWARMS_DIR_VAL="$SWARMS_DIR"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

CONFIG_CONTENT="$CONFIG_CONTENT" \
TASK_CONTENT="$TASK_CONTENT" \
DB_PATH_VAL="$DB_PATH_VAL" \
SWARMS_DIR_VAL="$SWARMS_DIR_VAL" \
GIT_ROOT_VAL="$GIT_ROOT" \
CONFIG_PATH_VAL="$CONFIG_ABS" \
python3 - <<'PYEOF'
import json, os, sys, uuid, sqlite3, subprocess
from datetime import datetime, timezone

config_raw   = os.environ.get("CONFIG_CONTENT", "")
task_desc    = os.environ.get("TASK_CONTENT", "")
db_path      = os.environ.get("DB_PATH_VAL", "")
swarms_dir   = os.environ.get("SWARMS_DIR_VAL", "")
git_root     = os.environ.get("GIT_ROOT_VAL", "")

try:
    import yaml
except ImportError:
    print(json.dumps({"error": "PyYAML not available — install with: pip3 install pyyaml"}), file=sys.stderr)
    sys.exit(1)

try:
    config = yaml.safe_load(config_raw)
except Exception as e:
    print(json.dumps({"error": f"YAML parse error: {e}"}), file=sys.stderr)
    sys.exit(1)

team_name     = config.get("name", "unnamed-team")
description   = config.get("description", "")
teammates_cfg = config.get("teammates", [])
merge_strategy = config.get("merge_strategy", "squash")
quality_gates  = config.get("quality_gates", {})

swarm_id = str(uuid.uuid4())[:16]
iso_ts   = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Insert swarm_sessions row
if db_path and os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        cur  = conn.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='swarm_sessions'")
        if cur.fetchone():
            cur.execute(
                '''INSERT INTO swarm_sessions
                   (id, team_name, config_path, started_at, status, notes)
                   VALUES (?, ?, ?, ?, ?, ?)''',
                (swarm_id, team_name, os.environ.get("CONFIG_PATH_VAL", ""), iso_ts, "running",
                 description)
            )
            conn.commit()
        conn.close()
    except Exception as e:
        print(json.dumps({"warning": f"cast.db write failed: {e}"}), file=sys.stderr)

spawned = []
errors  = []

for tm in teammates_cfg:
    role      = tm.get("role", "unknown")
    agent_def = tm.get("agent_def", "code-writer")
    model     = tm.get("model", "claude-sonnet-4-6")
    task      = tm.get("task", task_desc)
    read_only = tm.get("read_only", False)

    worktree_path = f"/tmp/cast-swarm-{swarm_id}/{role}"
    branch_name   = f"cast-swarm-{swarm_id}-{role}"

    # Build peer list (everyone except this teammate)
    peers = [t.get("role") for t in teammates_cfg if t.get("role") != role]
    peers_md = "\n".join(f"- {p}" for p in peers) if peers else "- (no peers)"

    # Write spawn_preamble.md
    preamble = f"""# Teammate Identity: {role}

You are the **{role}** in a CAST Agent Team swarm (swarm ID: {swarm_id}).

## Your Task
{task}

## Overall Swarm Goal
{task_desc}

## CAST Quality Gates (MANDATORY)
- After every logical unit of changes, dispatch code-reviewer agent
- Never run git commit directly — use the commit agent
- Route errors to the debugger agent
- End your work with a Status block: DONE | DONE_WITH_CONCERNS | BLOCKED

## Peer Teammates
{peers_md}

## Worktree
Your isolated worktree is at: {worktree_path}
Do not modify files outside this worktree.

## Merge Strategy
This swarm uses **{merge_strategy}** merge strategy.
"""

    # For read-only teams, skip worktree creation
    actual_worktree = None
    if not read_only:
        # Create parent dir so git worktree add can create the leaf
        parent_dir = os.path.dirname(worktree_path)
        os.makedirs(parent_dir, exist_ok=True)

        claude_dir = os.path.join(worktree_path, ".claude")
        try:
            result = subprocess.run(
                ["git", "-C", git_root, "worktree", "add", worktree_path, "-b", branch_name],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                # Try without -b if branch already exists
                result = subprocess.run(
                    ["git", "-C", git_root, "worktree", "add", worktree_path, branch_name],
                    capture_output=True, text=True
                )
            if result.returncode == 0:
                actual_worktree = worktree_path
                os.makedirs(claude_dir, exist_ok=True)
                preamble_path = os.path.join(claude_dir, "spawn_preamble.md")
                with open(preamble_path, "w") as f:
                    f.write(preamble)
            else:
                errors.append({"role": role, "error": f"git worktree add failed: {result.stderr.strip()}"})
        except Exception as e:
            errors.append({"role": role, "error": str(e)})

    # Insert teammate_runs row
    tm_run_id = str(uuid.uuid4())[:16]
    if db_path and os.path.exists(db_path):
        try:
            conn = sqlite3.connect(db_path, timeout=5)
            cur  = conn.cursor()
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='teammate_runs'")
            if cur.fetchone():
                cur.execute(
                    '''INSERT INTO teammate_runs
                       (id, swarm_id, agent_role, agent_def, worktree, task_subject, status, started_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
                    (tm_run_id, swarm_id, role, agent_def,
                     actual_worktree or "", task[:80], "idle", iso_ts)
                )
                conn.commit()
            conn.close()
        except Exception as e:
            errors.append({"role": role, "db_error": str(e)})

    spawned.append({
        "role":         role,
        "agent_def":    agent_def,
        "model":        model,
        "worktree":     actual_worktree,
        "branch":       branch_name if not read_only else None,
        "task":         task,
        "run_id":       tm_run_id,
        "read_only":    read_only,
    })

manifest = {
    "swarm_id":       swarm_id,
    "team_name":      team_name,
    "description":    description,
    "task":           task_desc,
    "merge_strategy": merge_strategy,
    "quality_gates":  quality_gates,
    "started_at":     iso_ts,
    "teammates":      spawned,
    "errors":         errors,
}

# Write manifest file
manifest_path = os.path.join(swarms_dir, f"{swarm_id}.json")
try:
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
except Exception as e:
    print(json.dumps({"warning": f"manifest write failed: {e}"}), file=sys.stderr)

print(json.dumps(manifest, indent=2))
PYEOF
