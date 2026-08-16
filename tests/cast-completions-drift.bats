#!/usr/bin/env bats
# Tests for completions/cast.bash drift against bin/cast's dispatch table
# (v10 gen-completions.sh). Guards against the "advertises phantom
# subcommands" defect: completions/cast.bash was stranded on a pre-v7
# vocabulary and offered `run queue audit daemon` — four subcommands that
# do not exist in the dispatch table and are rejected with
# "Unknown subcommand".
#
# Covers:
#   1. sanity: dispatch-table extraction is not silently empty
#   2. list region == dispatch table (no missing, no phantom)
#   3. case region == dispatch table (no missing, no phantom)
#   4. list region == case region (the two generated spots can't drift
#      from each other even if both drift from bin/cast identically)
#   5. generator is idempotent (second run produces no further diff)
#   6. the comparison logic actually bites: a planted phantom subcommand
#      in a COPY of the completion file is caught, not silently passed

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"
COMPLETIONS="$REPO_DIR/completions/cast.bash"
GEN_SCRIPT="$REPO_DIR/scripts/gen-completions.sh"

# ───────────────────────────────────────────────────────────────────────────
# Extraction helpers (independent of gen-completions.sh's own extraction —
# duplicated deliberately so a bug in the generator's extraction can't also
# hide from the test that's supposed to catch drift).
# ───────────────────────────────────────────────────────────────────────────

_extract_dispatch_set() {
  local file="$1"
  awk '
    /^case "\$SUBCOMMAND" in$/ { flag=1 }
    flag { print }
    flag && /^esac$/ { exit }
  ' "$file" \
    | grep -E '^  [a-z][a-z0-9-]*\)' \
    | sed -E 's/^  ([a-z][a-z0-9-]*)\).*/\1/' \
    | sort -u
}

_extract_list_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED SUBCOMMANDS (list)/,/END GENERATED SUBCOMMANDS (list)/p' "$file" \
    | grep -oE 'local subcommands="[^"]*"' \
    | sed -E 's/local subcommands="//; s/"$//' \
    | tr ' ' '\n' | sort -u
}

_extract_case_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED SUBCOMMANDS (case)/,/END GENERATED SUBCOMMANDS (case)/p' "$file" \
    | grep -E '^ *[a-z][a-z0-9|-]*\)$' \
    | sed -E 's/^ *//; s/\)$//' \
    | tr '|' '\n' | sort -u
}

# ───────────────────────────────────────────────────────────────────────────
# 1. Sanity: extraction is not silently empty (false-green guard — an empty
#    set on both sides would pass "no missing / no phantom" vacuously).
# ───────────────────────────────────────────────────────────────────────────

@test "sanity: dispatch table extraction is not silently empty" {
  local dispatch_set count
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  count="$(printf '%s\n' "$dispatch_set" | grep -c .)"
  [ "$count" -ge 30 ]
}

# ───────────────────────────────────────────────────────────────────────────
# 2/3. Set equality in BOTH directions — the actual defect this file exists
#    to prevent recurring: a completion list that PASSES on "mentions agents"
#    while still advertising phantoms (run/queue/audit/daemon).
# ───────────────────────────────────────────────────────────────────────────

@test "list region: no subcommand missing, no phantom, vs dispatch table" {
  local dispatch_set list_set missing phantom
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  list_set="$(_extract_list_set "$COMPLETIONS")"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from completions list region: $missing"
    echo "phantom in completions list region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
}

@test "case region: no subcommand missing, no phantom, vs dispatch table" {
  local dispatch_set case_set missing phantom
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  case_set="$(_extract_case_set "$COMPLETIONS")"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$case_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$case_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from completions case region: $missing"
    echo "phantom in completions case region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
}

# ───────────────────────────────────────────────────────────────────────────
# 4. The two generated regions can't drift from each other.
# ───────────────────────────────────────────────────────────────────────────

@test "list region and case region carry the same set" {
  local list_set case_set only_list only_case
  list_set="$(_extract_list_set "$COMPLETIONS")"
  case_set="$(_extract_case_set "$COMPLETIONS")"
  only_list="$(comm -23 <(printf '%s\n' "$list_set") <(printf '%s\n' "$case_set"))"
  only_case="$(comm -13 <(printf '%s\n' "$list_set") <(printf '%s\n' "$case_set"))"
  if [ -n "$only_list" ] || [ -n "$only_case" ]; then
    echo "only in list region: $only_list"
    echo "only in case region: $only_case"
  fi
  [ -z "$only_list" ]
  [ -z "$only_case" ]
}

# ───────────────────────────────────────────────────────────────────────────
# 5. Idempotent generation — run twice against an isolated copy (a plain
#    temp dir, no git repo needed); never mutate the real tracked file.
# ───────────────────────────────────────────────────────────────────────────

@test "generator is idempotent: second run produces no further diff" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/completions" "$tmpdir/scripts"
  cp "$CAST_BIN" "$tmpdir/bin/cast"
  cp "$COMPLETIONS" "$tmpdir/completions/cast.bash"
  cp "$GEN_SCRIPT" "$tmpdir/scripts/gen-completions.sh"

  run bash "$tmpdir/scripts/gen-completions.sh"
  assert_success
  cp "$tmpdir/completions/cast.bash" "$tmpdir/after-first-run.bash"

  run bash "$tmpdir/scripts/gen-completions.sh"
  assert_success

  # Byte-identical after a second run — a STRONGER assertion than the old
  # `git diff --stat` comparison, and it needs no git repo or git identity.
  run cmp -s "$tmpdir/after-first-run.bash" "$tmpdir/completions/cast.bash"
  assert_success

  rm -rf "$tmpdir"
}

# ───────────────────────────────────────────────────────────────────────────
# 6. Prove it bites: plant a fake subcommand into a COPY of the completion
#    file (never the real tracked file) and assert the comparison FAILS.
# ───────────────────────────────────────────────────────────────────────────

@test "comparison logic catches a planted phantom subcommand" {
  local tmpdir tmpfile
  tmpdir="$(mktemp -d)"
  tmpfile="$tmpdir/cast.bash"
  cp "$COMPLETIONS" "$tmpfile"

  python3 -c "
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(r'(local subcommands=\"[^\"]*)\"', r'\1 notarealcmd\"', text, count=1)
with open(path, 'w') as f:
    f.write(text)
" "$tmpfile"

  local dispatch_set list_set phantom
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  list_set="$(_extract_list_set "$tmpfile")"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"

  rm -rf "$tmpdir"

  [ "$phantom" = "notarealcmd" ]
}
