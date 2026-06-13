#!/usr/bin/env bash
# cast-push.sh — deterministic push primitive for CAST
# Exit 0: pushed + ls-remote SHA verified. Exit 1: failure (reason to stderr).
#
# Usage: cast-push.sh [branch]
#   branch  Optional. Defaults to the current branch (git branch --show-current).
#
# Escape hatch: CAST_PUSH_OK=1 must be set; this script sets it for you.
# Never call `git push` directly from the push agent — use this script.

set -euo pipefail

BRANCH="${1:-$(git branch --show-current 2>/dev/null)}"

if [ -z "$BRANCH" ]; then
  echo "cast-push: could not determine current branch" >&2
  exit 1
fi

# Capture HEAD SHA before push so a mid-run local commit cannot slip into the
# verification check (false-verify race: a commit landing after push starts
# would cause a re-read of HEAD to return a SHA that was never pushed).
PUSH_SHA=$(git rev-parse HEAD)

# Set upstream if none is configured; otherwise plain push.
if ! git rev-parse --abbrev-ref "@{u}" &>/dev/null; then
  CAST_PUSH_OK=1 git push --set-upstream origin "$BRANCH" 2>&1 || {
    echo "cast-push: push --set-upstream failed" >&2
    exit 1
  }
else
  CAST_PUSH_OK=1 git push 2>&1 || {
    echo "cast-push: push failed" >&2
    exit 1
  }
fi

# Verify via ls-remote that origin SHA matches the pre-push local SHA.
# Never re-read HEAD here — that would mask a mid-run commit landing.
REMOTE_SHA=$(git ls-remote --heads origin "$BRANCH" | awk '{print $1}')

if [ -z "$REMOTE_SHA" ]; then
  echo "cast-push: ls-remote returned empty — push may not have registered" >&2
  exit 1
fi

if [ "$REMOTE_SHA" != "$PUSH_SHA" ]; then
  echo "cast-push: SHA mismatch: local $PUSH_SHA vs remote $REMOTE_SHA" >&2
  exit 1
fi

echo "cast-push: pushed and verified: $BRANCH → origin ($PUSH_SHA)"

# Event tail must never affect exit status: bash 3.2 exits on source-of-missing-file even with || true outside a subshell.
( source ~/.claude/scripts/cast-events.sh 2>/dev/null && cast_emit_event "task_completed" "cast-push" "push-$(date +%Y%m%d)" "" "Pushed $BRANCH" "DONE" 2>/dev/null ) || true

exit 0
