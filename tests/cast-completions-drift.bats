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
ZSH_COMPLETIONS="$REPO_DIR/completions/_cast"
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

# completions/_cast (zsh) carries its top-level subcommand set as a bare-name
# array literal `subcommands=(name1 name2 ...)`, bounded by the same
# BEGIN/END GENERATED SUBCOMMANDS (zsh) sentinel style as the bash regions
# above. Scoped by sentinel range deliberately: the file has THREE other
# `subcommands=(` array literals (in _cast_memory and, historically,
# _cast_queue/_cast_daemon) that must never be confused with this one.
_extract_zsh_list_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED SUBCOMMANDS (zsh)/,/END GENERATED SUBCOMMANDS (zsh)/p' "$file" \
    | grep -oE 'subcommands=\([^)]*\)' \
    | sed -E 's/subcommands=\(//; s/\)$//' \
    | tr ' ' '\n' | sort -u
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
# 5. Idempotent generation — run twice against an isolated copy.
#
#    gen-completions.sh now does
#    `cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"`,
#    anchored to the SCRIPT's own location rather than the ambient cwd (fixed
#    2026-08-16 — the old bare `cd "$(git rev-parse --show-toplevel)"`
#    resolved against whatever repo the caller's cwd happened to be in, and
#    a non-git tmpdir would fall through to bats' real cwd inside this repo,
#    silently escaping and rewriting the live tracked completions files; see
#    `tests/cast-generator-anchor.bats` for the two-repo regression that
#    proves the escape is closed). `git -C "$tmpdir" init -q` is still
#    load-bearing here: with the fix the generator resolves its root from
#    the copied script's own directory ($tmpdir/scripts), so $tmpdir itself
#    must still be a real repo or the run now fails closed instead of
#    escaping. The `cd "$1"` in the invocation below is no longer required
#    for correctness (script-anchored resolution works from any cwd — see
#    the anchor-fix regression file) but is kept so this test also covers
#    the from-repo-root invocation style. A planted phantom is used to prove
#    the generator actually wrote $tmpdir's files rather than the real ones.
# ───────────────────────────────────────────────────────────────────────────

@test "generator is idempotent: second run produces no further diff" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/completions" "$tmpdir/scripts"
  git -C "$tmpdir" init -q
  cp "$CAST_BIN" "$tmpdir/bin/cast"
  cp "$COMPLETIONS" "$tmpdir/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$tmpdir/completions/_cast"
  cp "$GEN_SCRIPT" "$tmpdir/scripts/gen-completions.sh"

  # Plant a detectable phantom inside the generated (list) region of the
  # COPY only. Its removal by the first run is the proof that the generator
  # operated on $tmpdir's files rather than escaping elsewhere — without
  # this, comparing two files the generator never touched would pass
  # unconditionally regardless of where it actually wrote.
  python3 -c "
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = text.replace('local subcommands=\"', 'local subcommands=\"ZZPHANTOM ', 1)
with open(path, 'w') as f:
    f.write(text)
" "$tmpdir/completions/cast.bash"
  run grep -q 'ZZPHANTOM' "$tmpdir/completions/cast.bash"
  assert_success

  run bash -c 'cd "$1" && bash scripts/gen-completions.sh' _ "$tmpdir"
  assert_success
  run grep -q 'ZZPHANTOM' "$tmpdir/completions/cast.bash"
  assert_failure
  cp "$tmpdir/completions/cast.bash" "$tmpdir/after-first-run.bash"
  cp "$tmpdir/completions/_cast" "$tmpdir/after-first-run.zsh"

  run bash -c 'cd "$1" && bash scripts/gen-completions.sh' _ "$tmpdir"
  assert_success

  # Byte-identical after a second run.
  run cmp -s "$tmpdir/after-first-run.bash" "$tmpdir/completions/cast.bash"
  assert_success
  run cmp -s "$tmpdir/after-first-run.zsh" "$tmpdir/completions/_cast"
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

# ───────────────────────────────────────────────────────────────────────────
# 7. zsh coverage: completions/_cast's top-level generated `subcommands=(...)`
#    array (inside _cast()'s ->subcommand state) is the zsh half of the same
#    defect class covered above for completions/cast.bash — it previously
#    carried `run queue audit daemon` phantoms and was missing `install-
#    completions`/`status`. Set equality both directions, plus an explicit
#    count assertion (40) per the dispatch-table ground truth.
# ───────────────────────────────────────────────────────────────────────────

@test "zsh: generated subcommands region == dispatch table (count 40)" {
  local dispatch_set zsh_set missing phantom count
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  zsh_set="$(_extract_zsh_list_set "$ZSH_COMPLETIONS")"
  count="$(printf '%s\n' "$zsh_set" | grep -c .)"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from _cast generated region: $missing"
    echo "phantom in _cast generated region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
  [ "$count" -eq 40 ]
}

@test "zsh: zero phantom subcommands (run queue audit daemon) in generated region" {
  local zsh_set
  zsh_set="$(_extract_zsh_list_set "$ZSH_COMPLETIONS")"
  ! printf '%s\n' "$zsh_set" | grep -qxE 'run|queue|audit|daemon'
}

# ───────────────────────────────────────────────────────────────────────────
# 8. Dead-code absence: the 5 completion functions that existed solely to
#    serve the 4 removed phantoms (_cast_run, _cast_queue, its helper
#    _cast_queue_statuses, _cast_audit, _cast_daemon) must be gone from
#    completions/_cast, and the 4 hand-maintained `case "$subcmd" in ...`
#    detail-completion branches for those same phantoms must be gone from
#    completions/cast.bash. (Distinct from tests 2/3/7 above: those check the
#    GENERATED sentinel regions, which never contained these names in the
#    first place since they're dispatch-table-derived; this checks the
#    hand-maintained branches that used to reference them anyway.)
# ───────────────────────────────────────────────────────────────────────────

@test "no dead zsh completion functions remain for removed phantoms" {
  local fn
  for fn in _cast_run _cast_queue _cast_queue_statuses _cast_audit _cast_daemon; do
    run grep -qE "^${fn}\(\)" "$ZSH_COMPLETIONS"
    assert_failure
  done
}

@test "no dead bash case branches remain for removed phantoms" {
  local name
  for name in run queue audit daemon; do
    run grep -qE "^ *${name}\)\$" "$COMPLETIONS"
    assert_failure
  done
}

# ───────────────────────────────────────────────────────────────────────────
# 9. Prove the zsh comparison logic bites: plant a fake subcommand into a
#    COPY of completions/_cast's generated region (never the real tracked
#    file) and assert the comparison FAILS. Anchored to the BEGIN sentinel so
#    the mutation lands in the top-level array, not _cast_memory's nested one
#    (the file has more than one `subcommands=(` literal).
# ───────────────────────────────────────────────────────────────────────────

@test "zsh: comparison logic catches a planted phantom subcommand" {
  local tmpdir tmpfile
  tmpdir="$(mktemp -d)"
  tmpfile="$tmpdir/_cast"
  cp "$ZSH_COMPLETIONS" "$tmpfile"

  python3 -c "
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(
    r'(# BEGIN GENERATED SUBCOMMANDS \(zsh\).*?subcommands=\([^)]*)\)',
    r'\1 notarealcmd)',
    text, count=1, flags=re.DOTALL,
)
with open(path, 'w') as f:
    f.write(text)
" "$tmpfile"

  local dispatch_set zsh_set phantom
  dispatch_set="$(_extract_dispatch_set "$CAST_BIN")"
  zsh_set="$(_extract_zsh_list_set "$tmpfile")"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"

  rm -rf "$tmpdir"

  [ "$phantom" = "notarealcmd" ]
}

# ───────────────────────────────────────────────────────────────────────────
# 10. Generator fails closed for the zsh region: with the sentinels stripped
#     from a COPY, gen-completions.sh must error out rather than guess which
#     of the file's several `subcommands=(` arrays to rewrite.
# ───────────────────────────────────────────────────────────────────────────

# ───────────────────────────────────────────────────────────────────────────
# Memory-nested extraction helpers — independent of gen-completions.sh's own
# extraction, same rationale as the top-level helpers above: duplicated
# deliberately so a bug in the generator's extraction can't also hide from
# the test that's supposed to catch drift. Covers the defect this section
# exists to prevent recurring: completions/cast.bash and completions/_cast
# offered only 4 of _cmd_memory()'s 9 real sub-subcommands (search list
# forget export), silently hiding verify/show/delete/review/dream.
# ───────────────────────────────────────────────────────────────────────────

_extract_memory_dispatch_set() {
  local file="$1"
  awk '
    /^_cmd_memory\(\) \{$/ { flag=1 }
    flag { print }
    flag && /^}$/ { exit }
  ' "$file" \
    | grep -E '^    [a-z][a-z0-9-]*\)' \
    | sed -E 's/^    ([a-z][a-z0-9-]*)\).*/\1/' \
    | sort -u
}

_extract_memory_list_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED MEMORY SUBCOMMANDS (list)/,/END GENERATED MEMORY SUBCOMMANDS (list)/p' "$file" \
    | grep -oE 'compgen -W "[^"]*"' \
    | sed -E 's/compgen -W "//; s/"$//' \
    | tr ' ' '\n' | sort -u
}

_extract_memory_case_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED MEMORY SUBCOMMANDS (case)/,/END GENERATED MEMORY SUBCOMMANDS (case)/p' "$file" \
    | grep -E '^ *[a-z][a-z0-9|-]*\)$' \
    | sed -E 's/^ *//; s/\)$//' \
    | tr '|' '\n' | sort -u
}

# completions/_cast's memory array carries `name:description` pairs, not
# bare names — pull just the name before the colon.
_extract_memory_zsh_set() {
  local file="$1"
  sed -n '/BEGIN GENERATED MEMORY SUBCOMMANDS (zsh)/,/END GENERATED MEMORY SUBCOMMANDS (zsh)/p' "$file" \
    | grep -oE "'[a-z][a-z0-9-]*:" \
    | sed -E "s/^'//; s/:\$//" \
    | sort -u
}

@test "sanity: memory dispatch table extraction is not silently empty" {
  local dispatch_set count
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  count="$(printf '%s\n' "$dispatch_set" | grep -c .)"
  [ "$count" -ge 9 ]
}

@test "memory list region: no subcommand missing, no phantom, vs _cmd_memory dispatch table" {
  local dispatch_set list_set missing phantom
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  list_set="$(_extract_memory_list_set "$COMPLETIONS")"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from memory list region: $missing"
    echo "phantom in memory list region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
}

@test "memory case region: no subcommand missing, no phantom, vs _cmd_memory dispatch table" {
  local dispatch_set case_set missing phantom
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  case_set="$(_extract_memory_case_set "$COMPLETIONS")"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$case_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$case_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from memory case region: $missing"
    echo "phantom in memory case region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
}

@test "memory list region and memory case region carry the same set" {
  local list_set case_set only_list only_case
  list_set="$(_extract_memory_list_set "$COMPLETIONS")"
  case_set="$(_extract_memory_case_set "$COMPLETIONS")"
  only_list="$(comm -23 <(printf '%s\n' "$list_set") <(printf '%s\n' "$case_set"))"
  only_case="$(comm -13 <(printf '%s\n' "$list_set") <(printf '%s\n' "$case_set"))"
  if [ -n "$only_list" ] || [ -n "$only_case" ]; then
    echo "only in memory list region: $only_list"
    echo "only in memory case region: $only_case"
  fi
  [ -z "$only_list" ]
  [ -z "$only_case" ]
}

@test "zsh: memory generated subcommands region == _cmd_memory dispatch table (count 9)" {
  local dispatch_set zsh_set missing phantom count
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  zsh_set="$(_extract_memory_zsh_set "$ZSH_COMPLETIONS")"
  count="$(printf '%s\n' "$zsh_set" | grep -c .)"
  missing="$(comm -23 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"
  if [ -n "$missing" ] || [ -n "$phantom" ]; then
    echo "missing from _cast memory generated region: $missing"
    echo "phantom in _cast memory generated region: $phantom"
  fi
  [ -z "$missing" ]
  [ -z "$phantom" ]
  [ "$count" -eq 9 ]
}

@test "memory list region: comparison logic catches a planted phantom subcommand" {
  local tmpdir tmpfile
  tmpdir="$(mktemp -d)"
  tmpfile="$tmpdir/cast.bash"
  cp "$COMPLETIONS" "$tmpfile"

  # Mutate ONLY inside the memory-list sentinel region — the file's
  # top-level compgen -W "..." line matches the same bare regex, so the
  # replacement is bounded to the memory region's marker span first.
  python3 - "$tmpfile" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
begin = "# BEGIN GENERATED MEMORY SUBCOMMANDS (list)"
end = "# END GENERATED MEMORY SUBCOMMANDS (list)"
region_re = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
m = region_re.search(text)
region = re.sub(r'(compgen -W "[^"]*)"', r'\1 notarealcmd"', m.group(0), count=1)
text = text[:m.start()] + region + text[m.end():]
with open(path, "w") as f:
    f.write(text)
PYEOF

  local dispatch_set list_set phantom
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  list_set="$(_extract_memory_list_set "$tmpfile")"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$list_set"))"

  rm -rf "$tmpdir"

  [ "$phantom" = "notarealcmd" ]
}

@test "zsh: memory region comparison logic catches a planted phantom subcommand" {
  local tmpdir tmpfile
  tmpdir="$(mktemp -d)"
  tmpfile="$tmpdir/_cast"
  cp "$ZSH_COMPLETIONS" "$tmpfile"

  python3 - "$tmpfile" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(
    r"(# BEGIN GENERATED MEMORY SUBCOMMANDS \(zsh\).*?subcommands=\(\n)",
    r"\1    'notarealcmd:Fake description'\n",
    text, count=1, flags=re.DOTALL,
)
with open(path, "w") as f:
    f.write(text)
PYEOF

  local dispatch_set zsh_set phantom
  dispatch_set="$(_extract_memory_dispatch_set "$CAST_BIN")"
  zsh_set="$(_extract_memory_zsh_set "$tmpfile")"
  phantom="$(comm -13 <(printf '%s\n' "$dispatch_set") <(printf '%s\n' "$zsh_set"))"

  rm -rf "$tmpdir"

  [ "$phantom" = "notarealcmd" ]
}

@test "generator fails closed when memory list sentinels are missing" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/completions" "$tmpdir/scripts"
  git -C "$tmpdir" init -q
  cp "$CAST_BIN" "$tmpdir/bin/cast"
  cp "$COMPLETIONS" "$tmpdir/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$tmpdir/completions/_cast"
  cp "$GEN_SCRIPT" "$tmpdir/scripts/gen-completions.sh"

  # Simulate a human having deleted the memory-list BEGIN/END comments —
  # the region has no legacy-line bootstrap fallback, so this must abort
  # rather than guess where to write it.
  python3 - "$tmpdir/completions/cast.bash" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(
    r'        # BEGIN GENERATED MEMORY SUBCOMMANDS \(list\).*?# END GENERATED MEMORY SUBCOMMANDS \(list\)',
    '        COMPREPLY=( $(compgen -W "search list" -- "$cur") )',
    text, count=1, flags=re.DOTALL,
)
with open(path, "w") as f:
    f.write(text)
PYEOF

  run bash -c 'cd "$1" && bash scripts/gen-completions.sh' _ "$tmpdir"
  assert_failure
  assert_output --partial "memory list region"

  rm -rf "$tmpdir"
}

@test "generator fails closed when a memory subcommand has no mapped zsh description" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/completions" "$tmpdir/scripts"
  git -C "$tmpdir" init -q
  cp "$CAST_BIN" "$tmpdir/bin/cast"
  cp "$COMPLETIONS" "$tmpdir/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$tmpdir/completions/_cast"
  cp "$GEN_SCRIPT" "$tmpdir/scripts/gen-completions.sh"

  # Add a 10th memory dispatch arm with no matching entry in
  # MEMORY_DESCRIPTIONS — simulates a new subcommand landing in bin/cast
  # before a human has added its zsh description.
  python3 - "$tmpdir/bin/cast" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = text.replace(
    '    dream)    _memory_dream "$@" ;;',
    '    dream)    _memory_dream "$@" ;;\n    notmapped) _memory_notmapped "$@" ;;',
    1,
)
with open(path, "w") as f:
    f.write(text)
PYEOF

  run bash -c 'cd "$1" && bash scripts/gen-completions.sh' _ "$tmpdir"
  assert_failure
  assert_output --partial "no description mapped"
  assert_output --partial "notmapped"

  rm -rf "$tmpdir"
}

@test "generator fails closed when zsh sentinels are missing" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin" "$tmpdir/completions" "$tmpdir/scripts"
  # gen-completions.sh now anchors its root resolution to the SCRIPT's own
  # location (fixed 2026-08-16 — see `tests/cast-generator-anchor.bats` for
  # the two-repo escape regression), not the ambient cwd. $tmpdir must still
  # be a real repo: the generator resolves from $tmpdir/scripts (the copied
  # script's directory) and now fails closed rather than escaping if no
  # repo is found there.
  git -C "$tmpdir" init -q
  cp "$CAST_BIN" "$tmpdir/bin/cast"
  cp "$COMPLETIONS" "$tmpdir/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$tmpdir/completions/_cast"
  cp "$GEN_SCRIPT" "$tmpdir/scripts/gen-completions.sh"

  # Strip the zsh sentinel markers down to a bare (unsentineled) array —
  # simulates a human having deleted the BEGIN/END comments by hand.
  python3 -c "
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(
    r'      # BEGIN GENERATED SUBCOMMANDS \(zsh\).*?# END GENERATED SUBCOMMANDS \(zsh\)',
    '      subcommands=(agents ask backup)',
    text, count=1, flags=re.DOTALL,
)
with open(path, 'w') as f:
    f.write(text)
" "$tmpdir/completions/_cast"

  run bash -c 'cd "$1" && bash scripts/gen-completions.sh' _ "$tmpdir"
  assert_failure
  assert_output --partial "zsh sentinel markers not found"

  rm -rf "$tmpdir"
}
