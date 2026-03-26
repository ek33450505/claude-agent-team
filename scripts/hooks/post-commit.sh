#!/bin/bash
# post-commit.sh — CAST git post-commit hook
#
# Enqueues a code-reviewer task into the CAST task queue after every commit.
# Priority 7 (low) — non-blocking background review; does not delay the commit.
#
# Install: cast-route-install.sh will symlink this to .git/hooks/post-commit
#
# Note: never exits non-zero — a failing queue-add must not abort the commit.

# Do not trigger if inside a CAST subprocess (prevents recursive dispatch)
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_ADD="${SCRIPTS_DIR}/cast-queue-add.sh"

# Gracefully skip if cast-queue-add.sh is not available
if [[ ! -x "$QUEUE_ADD" ]]; then
  exit 0
fi

# Build a task description that includes the latest commit summary
COMMIT_MSG=$(git log -1 --pretty=format:"%h %s" 2>/dev/null || echo "unknown commit")
CHANGED_FILES=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null | head -10 | tr '\n' ' ' || echo "")

TASK="Review the latest commit for code quality and correctness. Commit: ${COMMIT_MSG}. Files changed: ${CHANGED_FILES:-none listed}"

# Enqueue with priority 7 (low — background, non-blocking)
"$QUEUE_ADD" "code-reviewer" "$TASK" --priority 7 2>/dev/null || true

exit 0
