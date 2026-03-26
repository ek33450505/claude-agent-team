#!/bin/bash
# post-merge.sh — CAST git post-merge hook
#
# Enqueues a chain-reporter task to summarize the merge.
# Priority 5 (normal) — runs after the merge completes.
#
# Install: cast-route-install.sh will symlink this to .git/hooks/post-merge

# Do not trigger if inside a CAST subprocess
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_ADD="${SCRIPTS_DIR}/cast-queue-add.sh"

# Gracefully skip if cast-queue-add.sh is not available
if [[ ! -x "$QUEUE_ADD" ]]; then
  exit 0
fi

# $1 is 1 if this was a squash merge, 0 for a regular merge
IS_SQUASH="${1:-0}"

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")

# Collect files changed by the merge
MERGED_FILES=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null | head -20 | tr '\n' ' ' || echo "unknown")

# Get the merge commit message
MERGE_MSG=$(git log -1 --pretty=format:"%h %s" 2>/dev/null || echo "unknown merge")

MERGE_TYPE="merge"
if [[ "$IS_SQUASH" == "1" ]]; then
  MERGE_TYPE="squash merge"
fi

TASK="Summarize the ${MERGE_TYPE} into branch '${CURRENT_BRANCH}'. Merge commit: ${MERGE_MSG}. Files affected: ${MERGED_FILES:-none listed}. Provide a concise summary of what changed and any notable impacts on the codebase."

# Enqueue with priority 5 (normal)
"$QUEUE_ADD" "chain-reporter" "$TASK" --priority 5 2>/dev/null || true

exit 0
