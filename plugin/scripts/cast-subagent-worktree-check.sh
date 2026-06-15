#!/usr/bin/env bash
# cast-subagent-worktree-check.sh — SubagentStop hook
#
# Detects unexpected agent worktrees after code-writer / debugger / test-writer /
# security / frontend-qa dispatches. Auto-removes empty/clean worktrees; escalates
# dirty ones (banner + DB row). Logs anomalies to cast.db worktree_anomalies table.
# Always exits 0.

[[ "${CLAUDE_SUBPROCESS:-}" == "1" ]] && exit 0

set -euo pipefail

INPUT="$(cat 2>/dev/null || true)"
export CAST_INPUT="$INPUT"

_log_error() {
  mkdir -p "$HOME/.claude/logs"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast-subagent-worktree-check: $1" \
    >> "$HOME/.claude/logs/hook-errors.log"
}

AGENT_ID="$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(d.get("agent_id") or d.get("subagent_id") or "unknown")
except Exception:
    print("unknown")
' 2>/dev/null || echo unknown)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"

# Run worktree scan only if we're inside a git repo. Sub-hooks (below) run regardless.
if [[ -n "$REPO_ROOT" ]]; then
  DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

  # Run the worktree scan + DB writes inside a single python invocation to keep
  # state consistent and to avoid shelling out for each worktree.
  python3 - "$AGENT_ID" "$REPO_ROOT" "$DB_PATH" <<'PYEOF' || _log_error "worktree scan failed"
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

agent_id, repo_root, db_path = sys.argv[1], sys.argv[2], sys.argv[3]
now_iso = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

# Ensure DB + table exist (idempotent)
Path(db_path).parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db_path, timeout=5)
conn.execute("""
    CREATE TABLE IF NOT EXISTS worktree_anomalies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id TEXT,
        worktree_path TEXT,
        detected_at TEXT,
        repo_root TEXT,
        state TEXT,
        reason TEXT
    )
""")
conn.commit()

# Parse `git worktree list --porcelain`
try:
    res = subprocess.run(
        ['git', '-C', repo_root, 'worktree', 'list', '--porcelain'],
        capture_output=True, text=True, timeout=10
    )
except Exception as e:
    print(f'worktree list failed: {e}', file=sys.stderr)
    conn.close()
    sys.exit(0)

worktree_paths = []
for line in res.stdout.splitlines():
    if line.startswith('worktree '):
        worktree_paths.append(line[len('worktree '):])

agent_pattern = re.compile(r'^' + re.escape(repo_root) + r'/\.claude/worktrees/agent-')

for wt in worktree_paths:
    if not agent_pattern.search(wt):
        continue
    if not Path(wt).exists():
        continue

    # Cleanliness check: ignore untracked-only output (build artifacts), and
    # confirm no commits ahead of origin/main (or main if origin/main missing).
    is_clean = True
    reason_bits = []

    try:
        st = subprocess.run(
            ['git', '-C', wt, 'status', '--porcelain'],
            capture_output=True, text=True, timeout=10
        )
        meaningful = [
            ln for ln in st.stdout.strip().split('\n')
            if ln and not ln.startswith('??')
        ]
        if meaningful:
            is_clean = False
            reason_bits.append(f'{len(meaningful)} uncommitted files')
    except Exception:
        is_clean = False
        reason_bits.append('status check failed')

    if is_clean:
        ahead = 0
        for upstream in ('origin/main', 'main'):
            try:
                ar = subprocess.run(
                    ['git', '-C', wt, 'rev-list', '--count', 'HEAD', f'^{upstream}'],
                    capture_output=True, text=True, timeout=10
                )
                if ar.returncode == 0:
                    ahead = int((ar.stdout or '0').strip() or '0')
                    break
            except Exception:
                continue
        if ahead > 0:
            is_clean = False
            reason_bits.append(f'{ahead} commits ahead')

    if is_clean:
        # Auto-remove
        try:
            subprocess.run(
                ['git', '-C', repo_root, 'worktree', 'remove', '--force', '--force', wt],
                capture_output=True, text=True, timeout=15
            )
            subprocess.run(
                ['git', '-C', repo_root, 'worktree', 'prune'],
                capture_output=True, text=True, timeout=10
            )
            print(f'✓ AGENT-WORKTREE CLEANUP: removed empty worktree at {wt} (agent {agent_id})')
            conn.execute(
                'INSERT INTO worktree_anomalies (agent_id, worktree_path, detected_at, repo_root, state, reason) VALUES (?,?,?,?,?,?)',
                (agent_id, wt, now_iso, repo_root, 'clean-removed', 'auto-cleanup: clean and at upstream')
            )
        except Exception as e:
            conn.execute(
                'INSERT INTO worktree_anomalies (agent_id, worktree_path, detected_at, repo_root, state, reason) VALUES (?,?,?,?,?,?)',
                (agent_id, wt, now_iso, repo_root, 'detect-only', f'cleanup failed: {e}')
            )
            print(f'⚠ AGENT-WORKTREE CLEANUP FAILED: {wt} (agent {agent_id}): {e}')
    else:
        reason = '; '.join(reason_bits) if reason_bits else 'unknown'
        conn.execute(
            'INSERT INTO worktree_anomalies (agent_id, worktree_path, detected_at, repo_root, state, reason) VALUES (?,?,?,?,?,?)',
            (agent_id, wt, now_iso, repo_root, 'dirty-escalated', reason)
        )
        print(f'⚠ AGENT-WORKTREE DETECTED (DIRTY): {agent_id} wrote to {wt}; manual recovery required ({reason})')

conn.commit()
conn.close()
PYEOF

  # Opportunistic prune: remove stale worktree entries where directory is gone.
  # Safe: git worktree prune only removes entries where the worktree dir no longer exists.
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
fi

# === Phase 5b additions: protocol violations, truncation, duration ===
# All three are advisory hooks — they log to cast.db and emit stderr,
# but never block. Failures are silently absorbed.
# NOTE: These run regardless of git context so they fire in non-repo CWDs.

if [[ -x "$HOME/.claude/scripts/cast-agent-protocol-check.sh" ]]; then
  bash "$HOME/.claude/scripts/cast-agent-protocol-check.sh" 2>&1 || true
fi

if [[ -x "$HOME/.claude/scripts/cast-truncation-check.sh" ]]; then
  bash "$HOME/.claude/scripts/cast-truncation-check.sh" 2>&1 || true
fi

if [[ -x "$HOME/.claude/scripts/cast-duration-check.sh" ]]; then
  bash "$HOME/.claude/scripts/cast-duration-check.sh" 2>&1 || true
fi

exit 0
