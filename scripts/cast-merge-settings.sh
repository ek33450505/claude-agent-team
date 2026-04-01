#!/bin/bash
# cast-merge-settings.sh — CAST managed-settings.d/ fragment merger
# Reads all *.json fragments from ~/.claude/managed-settings.d/ in lexicographic order,
# deep-merges them (hooks arrays concatenated, all other keys merged), and writes the
# result to ~/.claude/settings.json (or the path given as $1).
#
# Usage:
#   cast-merge-settings.sh [output_path]
#
# Exit codes:
#   0 — success
#   1 — fragment dir missing or no fragments found
#   2 — invalid JSON in a fragment (output NOT written)
#   3 — merged output failed JSON validation

set -euo pipefail

OUTPUT="${1:-${HOME}/.claude/settings.json}"
FRAGMENT_DIR="${HOME}/.claude/managed-settings.d"

if [ ! -d "$FRAGMENT_DIR" ]; then
  echo "[cast-merge-settings] ERROR: fragment dir not found: $FRAGMENT_DIR" >&2
  exit 1
fi

# Collect fragments in sort order
FRAGMENTS=()
while IFS= read -r -d '' f; do
  FRAGMENTS+=("$f")
done < <(find "$FRAGMENT_DIR" -maxdepth 1 -name '*.json' -print0 | sort -z)

if [ ${#FRAGMENTS[@]} -eq 0 ]; then
  echo "[cast-merge-settings] ERROR: no *.json fragments found in $FRAGMENT_DIR" >&2
  exit 1
fi

# Validate all fragments before merging
for f in "${FRAGMENTS[@]}"; do
  if ! python3 -c "import json, sys; json.load(open('$f'))" 2>/dev/null; then
    echo "[cast-merge-settings] ERROR: invalid JSON in fragment: $f — aborting, output not written" >&2
    exit 2
  fi
done

# Deep-merge fragments using Python
MERGED=$(python3 - "${FRAGMENTS[@]}" <<'PYEOF'
import json
import sys

def merge(base, override):
    """Deep-merge override into base. Hooks arrays are concatenated. All other keys are merged recursively."""
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override
    result = dict(base)
    for key, val in override.items():
        if key == "hooks" and isinstance(val, dict) and isinstance(result.get("hooks"), dict):
            # Merge hooks dicts: concatenate arrays for each event key
            merged_hooks = dict(result["hooks"])
            for event, arr in val.items():
                if event in merged_hooks:
                    merged_hooks[event] = merged_hooks[event] + arr
                else:
                    merged_hooks[event] = arr
            result["hooks"] = merged_hooks
        elif key in result and isinstance(result[key], dict) and isinstance(val, dict):
            result[key] = merge(result[key], val)
        else:
            result[key] = val
    return result

files = sys.argv[1:]
combined = {}
for fpath in files:
    with open(fpath) as f:
        fragment = json.load(f)
    combined = merge(combined, fragment)

print(json.dumps(combined, indent=2))
PYEOF
)

# Validate merged output
if ! echo "$MERGED" | python3 -m json.tool > /dev/null 2>&1; then
  echo "[cast-merge-settings] ERROR: merged output is invalid JSON — output not written" >&2
  exit 3
fi

# Write atomically via temp file
TMP_OUT=$(mktemp "${OUTPUT}.tmp.XXXXXX")
echo "$MERGED" > "$TMP_OUT"
mv "$TMP_OUT" "$OUTPUT"

echo "[cast-merge-settings] merged ${#FRAGMENTS[@]} fragments → $OUTPUT"
