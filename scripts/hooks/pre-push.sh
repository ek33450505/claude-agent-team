#!/bin/bash
# pre-push.sh — CAST git pre-push hook
#
# Enqueues a security scan into the CAST task queue before every push.
# Priority 2 (high) — but NON-BLOCKING: this hook always exits 0.
# The push proceeds immediately; the security scan runs asynchronously.
#
# Install: cast-route-install.sh will symlink this to .git/hooks/pre-push

# Do not trigger if inside a CAST subprocess
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE_ADD="${SCRIPTS_DIR}/cast-queue-add.sh"

# Gracefully skip if cast-queue-add.sh is not available
if [[ ! -x "$QUEUE_ADD" ]]; then
  exit 0
fi

# Read push target from stdin (format: <local_ref> <local_sha> <remote_ref> <remote_sha>)
# We just collect the refs being pushed for context
PUSH_REFS=$(cat 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | head -c 200 || echo "")

REMOTE="${1:-origin}"
REMOTE_URL="${2:-}"

# Determine the branch being pushed
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")

# Collect recently changed files (commits not yet on remote, up to 20)
CHANGED_FILES=$(git log "@{u}.." --name-only --pretty=format: 2>/dev/null | \
  grep -v '^$' | sort -u | head -20 | tr '\n' ' ' || \
  git diff HEAD~1 --name-only 2>/dev/null | head -20 | tr '\n' ' ' || echo "unknown")

TASK="Security scan before push to ${REMOTE} (branch: ${CURRENT_BRANCH}). Review changed files for security issues: credentials, injection vulnerabilities, insecure dependencies, exposed secrets. Files: ${CHANGED_FILES:-none listed}"

# Enqueue with priority 2 (high urgency — security scan should run soon after push)
"$QUEUE_ADD" "security" "$TASK" --priority 2 2>/dev/null || true

# Always exit 0 — never block the push
exit 0
