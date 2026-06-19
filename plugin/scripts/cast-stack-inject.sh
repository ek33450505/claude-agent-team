#!/usr/bin/env bash
# cast-stack-inject.sh — Print 2-line [CAST context] block for agent dispatch prompts
#
# Usage:
#   # From env var (set by CwdChanged hook):
#   CAST_STACK_PROFILE='{"fw":"vite-react","test_cmd":"bash tests/run.sh"}' \
#     bash cast-stack-inject.sh
#
#   # From cast.json in a specific repo:
#   bash cast-stack-inject.sh --repo /path/to/repo
#
# Output: 0-2 lines. Silent when neither source is available.
# Not a hook — no SUBPROCESS guard needed.

set -euo pipefail

REPO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            shift
            REPO_PATH="${1:-}"
            shift || true
            ;;
        *)
            shift
            ;;
    esac
done

CAST_STACK_PROFILE="${CAST_STACK_PROFILE:-}" \
CAST_REPO_CLASS="${CAST_REPO_CLASS:-}" \
REPO_PATH="$REPO_PATH" \
python3 - <<'PYEOF'
import json, os, subprocess, sys

stack_profile_raw = os.environ.get("CAST_STACK_PROFILE", "").strip()
repo_path         = os.environ.get("REPO_PATH", "").strip()

fw        = ""
test_cmd  = ""
lint_cmd  = ""
repo_class = ""

if repo_path:
    # --repo mode: read stack block from <repo>/.claude/cast.json
    cast_json = os.path.join(repo_path, ".claude", "cast.json")
    try:
        with open(cast_json, "r", encoding="utf-8") as f:
            d = json.load(f)
        repo_class = d.get("repo_class", "personal")
        stack = d.get("stack", {})
        fw       = stack.get("framework", "") or stack.get("fw", "")
        test_cmd = stack.get("test_cmd", "")
        lint_cmd = stack.get("lint_cmd", "")
    except Exception:
        sys.exit(0)
elif stack_profile_raw:
    # env var mode: compact JSON from CwdChanged hook
    try:
        sp = json.loads(stack_profile_raw)
        fw       = sp.get("fw", "") or sp.get("framework", "")
        test_cmd = sp.get("test_cmd", "")
        lint_cmd = sp.get("lint_cmd", "")
        repo_class = sp.get("repo_class", os.environ.get("CAST_REPO_CLASS", "personal"))
    except Exception:
        sys.exit(0)
else:
    sys.exit(0)

# ── Sanitize field values ─────────────────────────────────────────────────────
import re as _re

def _sanitize(s: str) -> str:
    """Cap at 80 chars and neutralize [CAST- directive tokens."""
    s = s[:80]
    s = _re.sub(r'\[CAST-', '[CAST_', s)
    return s

fw         = _sanitize(fw)
test_cmd   = _sanitize(test_cmd)
lint_cmd   = _sanitize(lint_cmd)
repo_class = _sanitize(repo_class)

# ── Line 1: stack info ────────────────────────────────────────────────────────
parts = []
if fw:
    parts.append("Stack: " + fw)
if test_cmd:
    parts.append("test: " + test_cmd)
if lint_cmd:
    parts.append("lint: " + lint_cmd)

if not parts:
    sys.exit(0)

line1 = "[CAST context] " + " | ".join(parts)

# ── Line 2: repo class + current branch ──────────────────────────────────────
branch = ""
try:
    git_cwd = repo_path if repo_path else None
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        capture_output=True, text=True,
        cwd=git_cwd, timeout=3
    )
    branch = result.stdout.strip()
except Exception:
    pass

rc = repo_class if repo_class else "personal"
line2_parts = ["Repo class: " + rc]
if branch:
    line2_parts.append("branch: " + branch)
line2 = "[CAST context] " + " | ".join(line2_parts)

print(line1)
print(line2)
PYEOF
