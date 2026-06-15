#!/usr/bin/env bash
# cast-rollback.sh — Recover the working tree after a failed orchestrator batch.
#
# Usage:
#   cast-rollback.sh --batch <id> [--yes]
#   cast-rollback.sh --sha <sha>  [--yes]
#
# Environment:
#   CAST_ROLLBACK_DRY_RUN=1  — preview diff only, no changes applied

set -euo pipefail

ROLLBACK_DIR="${HOME}/.claude/cast/rollback"

BATCH_ID=""
STASH_SHA=""
YES_FLAG=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)
      BATCH_ID="$2"
      shift 2
      ;;
    --sha)
      STASH_SHA="$2"
      shift 2
      ;;
    --yes)
      YES_FLAG=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: cast-rollback.sh --batch <id> [--yes] | --sha <sha> [--yes]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BATCH_ID" && -z "$STASH_SHA" ]]; then
  echo "Error: must provide --batch <id> or --sha <sha>" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve SHA
# ---------------------------------------------------------------------------
if [[ -n "$BATCH_ID" ]]; then
  mkdir -p "$ROLLBACK_DIR"
  SHA_FILE="${ROLLBACK_DIR}/batch-${BATCH_ID}.sha"
  if [[ ! -f "$SHA_FILE" ]]; then
    echo "Error: no rollback checkpoint found for batch ${BATCH_ID} (expected ${SHA_FILE})" >&2
    exit 1
  fi
  STASH_SHA="$(cat "$SHA_FILE")"
fi

# Guard: clean tree checkpoint
if [[ "$STASH_SHA" == "CLEAN" ]]; then
  echo "Batch ${BATCH_ID:-<direct>} had a clean tree at checkpoint — nothing to roll back."
  exit 0
fi

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: not inside a git repository" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Diff preview
# ---------------------------------------------------------------------------
echo "--- Rollback preview (changes that will be reverted) ---"
git -C "$REPO_ROOT" diff --stat "${STASH_SHA}..HEAD" 2>/dev/null || {
  echo "(Could not compute diff — SHA may be a stash ref rather than a commit)"
}
echo "--------------------------------------------------------"

# Dry-run guard
if [[ "${CAST_ROLLBACK_DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN — no changes applied."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "$YES_FLAG" -eq 0 ]]; then
  printf "Apply rollback? [y/N] "
  read -r REPLY
  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    echo "Rollback aborted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Apply rollback
# ---------------------------------------------------------------------------
_emit_event() {
  local event_type="$1" agent="$2" batch="$3" msg="$4" status="${5:-}"
  python3 -c "
import json, os, time, uuid
event = {
    'id': str(uuid.uuid4()),
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'type': '$event_type',
    'agent': '$agent',
    'batch': '$batch',
    'artifact_id': '',
    'message': '$msg',
    'status': '$status'
}
os.makedirs(os.path.expanduser('~/.claude/cast/events'), exist_ok=True)
fname = os.path.expanduser(f'~/.claude/cast/events/{event[\"timestamp\"].replace(\":\",\"-\")}-{event[\"id\"][:8]}.json')
with open(fname, 'w') as f:
    json.dump(event, f)
" 2>/dev/null || true
}

APPLY_FAILED=0
git -C "$REPO_ROOT" stash apply "$STASH_SHA" 2>/dev/null || APPLY_FAILED=1

if [[ "$APPLY_FAILED" -eq 1 ]]; then
  echo "git stash apply failed — attempting per-file checkout fallback..."
  FAILED_FILES=()
  while IFS= read -r changed_file; do
    git -C "$REPO_ROOT" checkout "$STASH_SHA" -- "$changed_file" 2>/dev/null && \
      echo "  restored: $changed_file" || \
      FAILED_FILES+=("$changed_file")
  done < <(git -C "$REPO_ROOT" diff --name-only "${STASH_SHA}..HEAD" 2>/dev/null)

  if [[ "${#FAILED_FILES[@]}" -gt 0 ]]; then
    echo "Error: could not restore the following files:" >&2
    printf '  %s\n' "${FAILED_FILES[@]}" >&2
    _emit_event 'task_blocked' 'cast-rollback' "rollback" \
      "Rollback failed for batch ${BATCH_ID:-direct}: per-file checkout failed on ${#FAILED_FILES[@]} file(s)" 'BLOCKED'
    exit 1
  fi
fi

echo "Rollback applied successfully."
_emit_event 'task_completed' 'cast-rollback' "rollback" \
  "Rolled back batch ${BATCH_ID:-direct} to ${STASH_SHA}" 'DONE'
exit 0
