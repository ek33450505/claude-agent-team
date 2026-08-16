#!/bin/bash
set -euo pipefail

# Guard: skip in subprocess
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# gen-completions.sh — regenerate completions/cast.bash's (bash) and
# completions/_cast's (zsh) subcommand lists from bin/cast's dispatch
# tables (the single source of truth): the top-level `case "$SUBCOMMAND" in`
# dispatch in bin/cast, and the nested `case "$subcmd" in` dispatch inside
# `_cmd_memory()`.
#
# completions/cast.bash carries FOUR generated regions that must all stay in
# sync with bin/cast:
#   1. the top-level `local subcommands="..."` list used for top-level
#      compgen
#   2. the top-level `case "${words[$i]}" in name1|name2|...)` active-
#      subcommand detector
#   3. the memory `COMPREPLY=( $(compgen -W "...") )` sub-subcommand list
#   4. the memory `case "${words[$i]}" in name1|name2|...)` sub-subcommand
#      detector
#
# completions/_cast carries TWO generated regions:
#   1. the top-level `subcommands=(...)` bare-name array inside `_cast()`'s
#      `->subcommand` state
#   2. the `_cast_memory()` nested `subcommands=(...)` array of
#      `name:description` pairs
#
# All regions are bounded by their OWN BEGIN/END sentinel comments so this
# script can rewrite each one idempotently, by exact marker match, without
# ever hand-parsing the surrounding shell or guessing which of the file's
# several similarly-shaped blocks it is looking at.
#
# The two top-level bash regions fall back to a legacy-line bootstrap when
# their sentinels are absent (first-run migration path). Every other
# region — both zsh regions and both memory-nested bash regions — has no
# such fallback: it fails closed if its sentinels are missing, since
# guessing which occurrence of a same-shaped block to rewrite risks
# silently corrupting a DIFFERENT list instead (e.g. writing the top-level
# array's contents over the memory-nested one, or vice versa).
#
# The zsh memory region additionally carries `name:description` pairs, not
# bare names (bin/cast --help formats descriptions inconsistently — args
# interleaved, variable spacing — so they are NOT parsed from --help text).
# Descriptions live in an explicit map below (MEMORY_DESCRIPTIONS, passed
# into the zsh python step) and the script fails closed if the dispatch
# table contains a subcommand the map doesn't cover, so adding a 10th
# memory subcommand forces a human to write one description line rather
# than silently shipping a blank or guessed one.

cd "$(git rev-parse --show-toplevel)"

CAST_BIN="bin/cast"
COMPLETIONS="completions/cast.bash"
ZSH_COMPLETIONS="completions/_cast"

# --- Extract the top-level dispatch table (case "$SUBCOMMAND" in ... esac) -
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

# --- Extract the memory dispatch table (case "$subcmd" in ... esac inside
# _cmd_memory()) -------------------------------------------------------------
# Anchored on the function's own open/close braces (both at column 0) rather
# than on `case "$subcmd" in`, since that exact case-header text is reused
# by several other `_cmd_*` functions in bin/cast (e.g. _cmd_eval) and would
# be ambiguous on its own.
MEMORY_BLOCK="$(awk '
  /^_cmd_memory\(\) \{$/ { flag=1 }
  flag { print }
  flag && /^}$/ { exit }
' "$CAST_BIN")"

if [[ -z "$MEMORY_BLOCK" ]]; then
  echo "gen-completions: could not find _cmd_memory() in $CAST_BIN" >&2
  exit 1
fi

# 4-space-indented `name)` entries only (e.g. "    search)   _memory_search
# \"\$@\" ;;"); excludes the "    --help|-h)" and "    *)" catch-alls (neither
# matches `^    [a-z]`), and excludes the --help heredoc's usage lines (those
# are 2-space indented and don't end the name with `)`). Dispatch order is
# preserved deliberately (no sort): the zsh region's name:description pairs
# read most naturally in the same order as bin/cast's own --help usage
# block, which itself follows dispatch order.
MEMORY_SUBCOMMANDS="$(printf '%s\n' "$MEMORY_BLOCK" \
  | grep -E '^    [a-z][a-z0-9-]*\)' \
  | sed -E 's/^    ([a-z][a-z0-9-]*)\).*/\1/')"

MEMORY_COUNT="$(printf '%s\n' "$MEMORY_SUBCOMMANDS" | grep -c .)"

if [[ "$MEMORY_COUNT" -eq 0 ]]; then
  echo "gen-completions: extracted 0 memory subcommands — refusing to write an empty list" >&2
  exit 1
fi

MEMORY_SPACE="$(printf '%s\n' "$MEMORY_SUBCOMMANDS" | tr '\n' ' ' | sed 's/ $//')"
MEMORY_PIPE="$(printf '%s\n' "$MEMORY_SUBCOMMANDS" | tr '\n' '|' | sed 's/|$//')"

# --- Rewrite completions/cast.bash between sentinel markers ----------------
# Uses python3 (not sed -i) to avoid BSD/GNU -i divergence; the same
# replacement handles first-run bootstrap (top-level markers absent, legacy
# line present) and steady-state idempotent regeneration (markers present).
# The two memory-nested regions have no legacy bootstrap path (they didn't
# exist as generated regions before this script grew memory-awareness) so
# they fail closed if their sentinels are missing.
python3 - "$COMPLETIONS" "$SUBCOMMANDS_SPACE" "$SUBCOMMANDS_PIPE" "$MEMORY_SPACE" "$MEMORY_PIPE" <<'PYEOF'
import re
import sys

path, space_list, pipe_list, mem_space_list, mem_pipe_list = sys.argv[1:6]

with open(path) as f:
    text = f.read()

LIST_BEGIN = "  # BEGIN GENERATED SUBCOMMANDS (list) — do not edit by hand; run scripts/gen-completions.sh"
LIST_END = "  # END GENERATED SUBCOMMANDS (list)"
CASE_BEGIN = "      # BEGIN GENERATED SUBCOMMANDS (case) — do not edit by hand; run scripts/gen-completions.sh"
CASE_END = "      # END GENERATED SUBCOMMANDS (case)"
MEM_LIST_BEGIN = "        # BEGIN GENERATED MEMORY SUBCOMMANDS (list) — do not edit by hand; run scripts/gen-completions.sh"
MEM_LIST_END = "        # END GENERATED MEMORY SUBCOMMANDS (list)"
MEM_CASE_BEGIN = "          # BEGIN GENERATED MEMORY SUBCOMMANDS (case) — do not edit by hand; run scripts/gen-completions.sh"
MEM_CASE_END = "          # END GENERATED MEMORY SUBCOMMANDS (case)"

list_block = f'{LIST_BEGIN}\n  local subcommands="{space_list}"\n{LIST_END}'
case_block = f'{CASE_BEGIN}\n      {pipe_list})\n{CASE_END}'
mem_list_block = f'{MEM_LIST_BEGIN}\n        COMPREPLY=( $(compgen -W "{mem_space_list}" -- "$cur") )\n{MEM_LIST_END}'
mem_case_block = f'{MEM_CASE_BEGIN}\n          {mem_pipe_list})\n{MEM_CASE_END}'


def replace_bounded(text, begin, end, new_block, legacy_pattern):
    marker_re = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if marker_re.search(text):
        return marker_re.sub(lambda _m: new_block, text, count=1)
    # Bootstrap: markers absent yet — replace the known legacy line instead.
    legacy_re = re.compile(legacy_pattern, re.MULTILINE)
    if not legacy_re.search(text):
        raise SystemExit(f"gen-completions: neither markers nor legacy pattern found for {begin!r}")
    return legacy_re.sub(lambda _m: new_block, text, count=1)


def replace_bounded_strict(text, begin, end, new_block, label):
    marker_re = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if not marker_re.search(text):
        raise SystemExit(
            f"gen-completions: sentinel markers not found for {label} in {path} — "
            "refusing to guess where to write it. Restore the BEGIN/END "
            f"markers for {label} by hand before re-running this script."
        )
    return marker_re.sub(lambda _m: new_block, text, count=1)


text = replace_bounded(
    text, LIST_BEGIN, LIST_END, list_block,
    r'^  local subcommands="[^"]*"$',
)
text = replace_bounded(
    text, CASE_BEGIN, CASE_END, case_block,
    r'^      [a-z][a-z0-9|-]*\)$',
)
text = replace_bounded_strict(text, MEM_LIST_BEGIN, MEM_LIST_END, mem_list_block, "memory list region")
text = replace_bounded_strict(text, MEM_CASE_BEGIN, MEM_CASE_END, mem_case_block, "memory case region")

with open(path, "w") as f:
    f.write(text)
PYEOF

echo "[gen-completions] wrote $COUNT subcommands to $COMPLETIONS"
echo "[gen-completions] wrote $MEMORY_COUNT memory subcommands to $COMPLETIONS"

# --- Rewrite completions/_cast (zsh) between sentinel markers --------------
# Fail CLOSED: unlike the bash regions above, neither zsh region has a
# legacy-line bootstrap fallback. completions/_cast contains multiple
# `subcommands=(` array literals (the top-level one plus _cast_memory's
# nested one); guessing which to rewrite when a region's sentinels are
# missing would risk silently corrupting the wrong array. If either
# region's markers are gone, stop and make a human re-add them rather than
# guessing at placement.
if [[ ! -f "$ZSH_COMPLETIONS" ]]; then
  echo "gen-completions: $ZSH_COMPLETIONS not found — refusing to guess" >&2
  exit 1
fi

python3 - "$ZSH_COMPLETIONS" "$SUBCOMMANDS_SPACE" "$MEMORY_SUBCOMMANDS" <<'PYEOF'
import re
import sys

path, space_list, memory_names_raw = sys.argv[1], sys.argv[2], sys.argv[3]
memory_names = [n for n in memory_names_raw.splitlines() if n]

# Descriptions are NOT derived from bin/cast --help text (interleaved args,
# inconsistent spacing — see the matching comment on completions/_cast's
# top-level array). Their source is two-fold: `verify`, `show`, `delete`,
# `review` and `dream` are taken verbatim from bin/cast's USAGE block
# (`cast memory --help`), which annotates exactly those five; `search`,
# `list`, `forget` and `export` carry no prose description there and are
# carried forward from the pre-existing completions/_cast array. Both sets
# are kept in sync by hand; the fail-closed check below is what forces that
# sync when a new subcommand appears.
MEMORY_DESCRIPTIONS = {
    "search": "Search memories by query",
    "list": "List all memories",
    "verify": "Run staleness sweep",
    "show": "Print full memory entry",
    "delete": "Delete a memory entry",
    "forget": "Delete a memory by ID",
    "export": "Export all memories as JSON",
    "review": "Pending memory review TUI",
    "dream": "Run markdown memory consolidation",
}

missing_desc = [n for n in memory_names if n not in MEMORY_DESCRIPTIONS]
if missing_desc:
    raise SystemExit(
        "gen-completions: no description mapped for memory subcommand(s) "
        f"{missing_desc!r} — add an entry to MEMORY_DESCRIPTIONS in "
        "scripts/gen-completions.sh before regenerating (refusing to ship "
        "a blank or guessed zsh description)"
    )

with open(path) as f:
    text = f.read()

ZSH_BEGIN = "      # BEGIN GENERATED SUBCOMMANDS (zsh) — do not edit by hand; run scripts/gen-completions.sh"
ZSH_END = "      # END GENERATED SUBCOMMANDS (zsh)"
MEM_ZSH_BEGIN = "  # BEGIN GENERATED MEMORY SUBCOMMANDS (zsh) — do not edit by hand; run scripts/gen-completions.sh"
MEM_ZSH_END = "  # END GENERATED MEMORY SUBCOMMANDS (zsh)"

zsh_block = f'{ZSH_BEGIN}\n      subcommands=({space_list})\n{ZSH_END}'
mem_entries = "\n".join(f"    '{n}:{MEMORY_DESCRIPTIONS[n]}'" for n in memory_names)
mem_zsh_block = f'{MEM_ZSH_BEGIN}\n  subcommands=(\n{mem_entries}\n  )\n{MEM_ZSH_END}'

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

mem_marker_re = re.compile(re.escape(MEM_ZSH_BEGIN) + r".*?" + re.escape(MEM_ZSH_END), re.DOTALL)
if not mem_marker_re.search(text):
    raise SystemExit(
        f"gen-completions: memory zsh sentinel markers not found in {path} — "
        "refusing to guess which of its `subcommands=(` arrays to rewrite "
        "(there are multiple: top-level plus _cast_memory's nested list). "
        "Restore the BEGIN/END GENERATED MEMORY SUBCOMMANDS (zsh) markers "
        "by hand before re-running this script."
    )
text = mem_marker_re.sub(lambda _m: mem_zsh_block, text, count=1)

with open(path, "w") as f:
    f.write(text)
PYEOF

echo "[gen-completions] wrote $COUNT subcommands to $ZSH_COMPLETIONS"
echo "[gen-completions] wrote $MEMORY_COUNT memory subcommands to $ZSH_COMPLETIONS"
