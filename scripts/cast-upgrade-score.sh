#!/usr/bin/env bash
# cast-upgrade-score.sh — Haiku API relevance scorer for Claude Code release notes
#
# Usage: cast-upgrade-score.sh <repo> <tag> <release-notes-file>
# Output: JSON array of scored items, written to stdout
#
# Each item:
#   { "item": "...", "category": "CRITICAL|UPGRADE|MONITOR|SKIP",
#     "reason": "...", "cast_component": "..." }
#
# Requires: ANTHROPIC_API_KEY in environment

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

REPO="${1:-}"
TAG="${2:-}"
NOTES_FILE="${3:-}"

if [ -z "$REPO" ] || [ -z "$TAG" ] || [ -z "$NOTES_FILE" ]; then
  printf "Usage: cast-upgrade-score.sh <repo> <tag> <notes-file>\n" >&2
  exit 1
fi

if [ ! -f "$NOTES_FILE" ]; then
  printf "Error: notes file not found: %s\n" "$NOTES_FILE" >&2
  exit 1
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  printf "Error: ANTHROPIC_API_KEY not set\n" >&2
  exit 1
fi

RELEASE_NOTES="$(cat "$NOTES_FILE")"

# Build prompt using heredoc to avoid shell injection
SYSTEM_PROMPT="You are a release notes analyst for CAST, a Claude Code orchestration system.
CAST uses: hooks (PreToolUse/PostToolUse/UserPromptSubmit/SubagentStop/StopFailure),
agent definitions with tools/model/maxTurns frontmatter, route.sh for routing,
castd daemon for async task execution, sqlite cast.db for state, --agent and --print flags.

For each change in the release notes, output a JSON array. Each item must have:
{
  \"item\": \"brief description\",
  \"category\": \"CRITICAL|UPGRADE|MONITOR|SKIP\",
  \"reason\": \"one sentence why\",
  \"cast_component\": \"which CAST file/system is affected\"
}

CRITICAL = breaking change that CAST currently uses.
UPGRADE = new capability directly applicable to CAST.
MONITOR = potentially relevant in future.
SKIP = not relevant to CAST.

Output ONLY valid JSON array, no other text."

USER_CONTENT="Release notes for ${REPO}@${TAG}:

${RELEASE_NOTES}"

# Call Haiku API via claude CLI (avoids managing API keys in curl)
SCORED_OUTPUT="$(claude -p "$USER_CONTENT" \
  --print \
  --dangerously-skip-permissions \
  --model claude-haiku-4-5 \
  2>/dev/null || echo "[]")"

# Validate JSON output — fall back to empty array on parse failure
python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    if not isinstance(data, list):
        data = []
    print(json.dumps(data))
except Exception:
    print('[]')
" "$SCORED_OUTPUT" 2>/dev/null || echo "[]"
