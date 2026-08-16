#!/bin/bash
set -euo pipefail

# Guard: skip in subprocess
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# gen-completions.sh — regenerate completions/cast.bash's (bash) and
# completions/_cast's (zsh) top-level subcommand lists from bin/cast's
# dispatch table (the single source of truth).
#
# completions/cast.bash carries the subcommand set in TWO places that must
# stay in sync with each other AND with bin/cast:
#   1. the `local subcommands="..."` list used for top-level compgen
#   2. the `case "${words[$i]}" in name1|name2|...)` active-subcommand detector
#
# completions/_cast carries the subcommand set in ONE place that must also
# stay in sync: the top-level `subcommands=(...)` array inside `_cast()`'s
# `->subcommand` state (there is one OTHER `subcommands=(` array in that
# file — `_cast_memory`'s nested sub-subcommand list — which this script
# must never touch).
#
# All regions are bounded by BEGIN/END sentinel comments so this script can
# rewrite them idempotently without hand-parsing the surrounding shell.
#
# The bash regions fall back to a legacy-line bootstrap when the sentinels
# are absent (first-run migration path). The zsh region has no such
# fallback: it fails closed if its sentinels are missing, since guessing
# which of the two `subcommands=(` occurrences to rewrite would risk
# silently corrupting a nested sub-subcommand list instead.

cd "$(git rev-parse --show-toplevel)"

CAST_BIN="bin/cast"
COMPLETIONS="completions/cast.bash"
ZSH_COMPLETIONS="completions/_cast"

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

# --- Rewrite completions/_cast (zsh) between sentinel markers --------------
# Fail CLOSED: unlike the bash regions above, this region has no legacy-line
# bootstrap fallback. completions/_cast contains FOUR `subcommands=(` array
# literals (three belong to nested sub-subcommand lists in _cast_queue-style
# functions); guessing which one to rewrite when the sentinels are missing
# would risk silently corrupting the wrong array. If the markers are gone,
# stop and make a human re-add them rather than guessing at placement.
if [[ ! -f "$ZSH_COMPLETIONS" ]]; then
  echo "gen-completions: $ZSH_COMPLETIONS not found — refusing to guess" >&2
  exit 1
fi

python3 - "$ZSH_COMPLETIONS" "$SUBCOMMANDS_SPACE" <<'PYEOF'
import re
import sys

path, space_list = sys.argv[1], sys.argv[2]

with open(path) as f:
    text = f.read()

ZSH_BEGIN = "      # BEGIN GENERATED SUBCOMMANDS (zsh) — do not edit by hand; run scripts/gen-completions.sh"
ZSH_END = "      # END GENERATED SUBCOMMANDS (zsh)"

zsh_block = f'{ZSH_BEGIN}\n      subcommands=({space_list})\n{ZSH_END}'

marker_re = re.compile(re.escape(ZSH_BEGIN) + r".*?" + re.escape(ZSH_END), re.DOTALL)
if not marker_re.search(text):
    raise SystemExit(
        f"gen-completions: zsh sentinel markers not found in {path} — "
        "refusing to guess which of its `subcommands=(` arrays to rewrite "
        "(there are multiple: top-level plus per-subcommand nested lists). "
        "Restore the BEGIN/END GENERATED SUBCOMMANDS (zsh) markers by hand "
        "before re-running this script."
    )

text = marker_re.sub(lambda _m: zsh_block, text, count=1)

with open(path, "w") as f:
    f.write(text)
PYEOF

echo "[gen-completions] wrote $COUNT subcommands to $ZSH_COMPLETIONS"
