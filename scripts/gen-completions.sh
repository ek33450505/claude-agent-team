#!/bin/bash
set -euo pipefail

# Guard: skip in subprocess
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# gen-completions.sh — regenerate completions/cast.bash's top-level subcommand
# list from bin/cast's dispatch table (the single source of truth).
#
# completions/cast.bash carries the subcommand set in TWO places that must
# stay in sync with each other AND with bin/cast:
#   1. the `local subcommands="..."` list used for top-level compgen
#   2. the `case "${words[$i]}" in name1|name2|...)` active-subcommand detector
#
# Both regions are bounded by BEGIN/END sentinel comments so this script can
# rewrite them idempotently without hand-parsing the surrounding bash.
#
# Does NOT touch completions/_cast (zsh) — that is a separate follow-up unit.

cd "$(git rev-parse --show-toplevel)"

CAST_BIN="bin/cast"
COMPLETIONS="completions/cast.bash"

# --- Extract the dispatch table (case "$SUBCOMMAND" in ... esac) -----------
# Anchor on the exact case-open/close lines so we never over-collect from the
# many other `case` statements in bin/cast.
DISPATCH_BLOCK="$(awk '
  /^case "\$SUBCOMMAND" in$/ { flag=1 }
  flag { print }
  flag && /^esac$/ { exit }
' "$CAST_BIN")"

if [[ -z "$DISPATCH_BLOCK" ]]; then
  echo "gen-completions: could not find dispatch table (case \"\$SUBCOMMAND\" in ... esac) in $CAST_BIN" >&2
  exit 1
fi

# 2-space-indented `name)` entries only; excludes the `""|--help|-h)` and
# `*)` catch-alls (neither matches `^  [a-z]`).
SUBCOMMANDS="$(printf '%s\n' "$DISPATCH_BLOCK" \
  | grep -E '^  [a-z][a-z0-9-]*\)' \
  | sed -E 's/^  ([a-z][a-z0-9-]*)\).*/\1/' \
  | sort -u)"

COUNT="$(printf '%s\n' "$SUBCOMMANDS" | grep -c .)"

if [[ "$COUNT" -eq 0 ]]; then
  echo "gen-completions: extracted 0 subcommands — refusing to write an empty list" >&2
  exit 1
fi

SUBCOMMANDS_SPACE="$(printf '%s\n' "$SUBCOMMANDS" | tr '\n' ' ' | sed 's/ $//')"
SUBCOMMANDS_PIPE="$(printf '%s\n' "$SUBCOMMANDS" | tr '\n' '|' | sed 's/|$//')"

# --- Rewrite completions/cast.bash between sentinel markers ----------------
# Uses python3 (not sed -i) to avoid BSD/GNU -i divergence; the same
# replacement handles first-run bootstrap (markers absent, legacy line
# present) and steady-state idempotent regeneration (markers present).
python3 - "$COMPLETIONS" "$SUBCOMMANDS_SPACE" "$SUBCOMMANDS_PIPE" <<'PYEOF'
import re
import sys

path, space_list, pipe_list = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    text = f.read()

LIST_BEGIN = "  # BEGIN GENERATED SUBCOMMANDS (list) — do not edit by hand; run scripts/gen-completions.sh"
LIST_END = "  # END GENERATED SUBCOMMANDS (list)"
CASE_BEGIN = "      # BEGIN GENERATED SUBCOMMANDS (case) — do not edit by hand; run scripts/gen-completions.sh"
CASE_END = "      # END GENERATED SUBCOMMANDS (case)"

list_block = f'{LIST_BEGIN}\n  local subcommands="{space_list}"\n{LIST_END}'
case_block = f'{CASE_BEGIN}\n      {pipe_list})\n{CASE_END}'


def replace_bounded(text, begin, end, new_block, legacy_pattern):
    marker_re = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if marker_re.search(text):
        return marker_re.sub(lambda _m: new_block, text, count=1)
    # Bootstrap: markers absent yet — replace the known legacy line instead.
    legacy_re = re.compile(legacy_pattern, re.MULTILINE)
    if not legacy_re.search(text):
        raise SystemExit(f"gen-completions: neither markers nor legacy pattern found for {begin!r}")
    return legacy_re.sub(lambda _m: new_block, text, count=1)


text = replace_bounded(
    text, LIST_BEGIN, LIST_END, list_block,
    r'^  local subcommands="[^"]*"$',
)
text = replace_bounded(
    text, CASE_BEGIN, CASE_END, case_block,
    r'^      [a-z][a-z0-9|-]*\)$',
)

with open(path, "w") as f:
    f.write(text)
PYEOF

echo "[gen-completions] wrote $COUNT subcommands to $COMPLETIONS"
