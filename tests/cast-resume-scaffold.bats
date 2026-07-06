#!/usr/bin/env bats
# cast-resume-scaffold.bats — Tests for cast-resume-scaffold.py
#
# All tests use setup_temp_home / teardown_temp_home to isolate file operations
# from the real ~/.claude directory (HARD RULE: tests touching HOME use temp HOME).
# Hermetic: `gh` is PATH-shimmed with a no-op stub so tests never hit the network.
#
# Coverage:
#   1. Writes <date>-<slug>-auto.md to out-dir.
#   2. Frontmatter has origin / inferred_by / as_of_sha.
#   3. §2 contains a planted commit subject (deterministic).
#   4. §3 reflects the planted uncommitted file.
#   5. §5 / §8 reference the planted plan file.
#   6. Slot placeholders {{ }} present for enrich sections.
#   7. gh failure → still exit 0, still writes file with commit data + note.
#   8. --dry-run prints markdown to stdout, writes NO file.
#   9. Not-a-git repo → exit 0, no crash, no file.
#  10. Newest plan that self-declares SUPERSEDED is skipped for the current one.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-resume-scaffold.py"

FIXED_NOW="2026-07-05T00:00:00Z"
OUT_FILE_NAME="2026-07-05-fixture-repo-auto.md"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME + hermetic gh stub + fixture git repo
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  OUT_DIR="$HOME/resume-out"

  # Hermetic gh stub: default behaves as gh returning an empty JSON array.
  # NEVER hits the network. Individual tests may overwrite it (e.g. exit 1).
  STUB_DIR="$HOME/stubbin"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
exit 0
EOF
  chmod +x "$STUB_DIR/gh"
  export PATH="$STUB_DIR:$PATH"

  # Fixture git repo — basename "fixture-repo" is the slug.
  FIXTURE_REPO="$HOME/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test User"
  git -C "$FIXTURE_REPO" config commit.gpgsign false

  echo "one" > "$FIXTURE_REPO/file1.txt"
  git -C "$FIXTURE_REPO" add file1.txt
  git -C "$FIXTURE_REPO" commit -q -m "Add first fixture file"

  echo "two" > "$FIXTURE_REPO/file2.txt"
  git -C "$FIXTURE_REPO" add file2.txt
  git -C "$FIXTURE_REPO" commit -q -m "Add second fixture file"

  mkdir -p "$FIXTURE_REPO/plans"
  echo "# plan" > "$FIXTURE_REPO/plans/some-plan.md"
  git -C "$FIXTURE_REPO" add plans/some-plan.md
  git -C "$FIXTURE_REPO" commit -q -m "Add plan doc"

  # Normalize the branch name so default-branch logic is deterministic.
  git -C "$FIXTURE_REPO" branch -M main

  # Planted dirty state:
  #  - an untracked file  -> "?? uncommitted.txt"  (no leading space)
  #  - a modified TRACKED file -> " M file1.txt"    (LEADING space; porcelain
  #    lists it first, so a naive whole-output strip would eat its first char)
  echo "dirty" > "$FIXTURE_REPO/uncommitted.txt"
  echo "modified" >> "$FIXTURE_REPO/file1.txt"
}

teardown() {
  teardown_temp_home
}

# Run the scaffold against the fixture with a deterministic timestamp.
run_scaffold() {
  run python3 "$SCRIPT" --repo "$FIXTURE_REPO" --out-dir "$OUT_DIR" \
      --now "$FIXED_NOW" "$@"
}

# ---------------------------------------------------------------------------
# 1. Output file naming
# ---------------------------------------------------------------------------

@test "writes <date>-<slug>-auto.md to out-dir" {
  run_scaffold
  assert_success
  [ -f "$OUT_DIR/$OUT_FILE_NAME" ]
}

# ---------------------------------------------------------------------------
# 2. Frontmatter business-card fields
# ---------------------------------------------------------------------------

@test "frontmatter has origin / inferred_by / as_of_sha" {
  run_scaffold
  assert_success
  local f="$OUT_DIR/$OUT_FILE_NAME"
  grep -q "^origin: resume-scaffold" "$f"
  grep -q "^inferred_by: cast-resume-scaffold.py" "$f"
  grep -q "^as_of_sha:" "$f"
}

# ---------------------------------------------------------------------------
# 3. §2 deterministic commit data
# ---------------------------------------------------------------------------

@test "section 2 contains a planted commit subject" {
  run_scaffold
  assert_success
  grep -q "Add first fixture file" "$OUT_DIR/$OUT_FILE_NAME"
}

# ---------------------------------------------------------------------------
# 4. §3 working-tree state
# ---------------------------------------------------------------------------

@test "section 3 reflects the planted uncommitted file" {
  run_scaffold
  assert_success
  grep -qE "uncommitted\.txt|Uncommitted:" "$OUT_DIR/$OUT_FILE_NAME"
}

@test "section 3 preserves the full path of a modified tracked file (leading-space regression)" {
  # " M file1.txt" is the first porcelain line; a whole-output strip would drop
  # the leading space and render "ile1.txt". Assert the full name survives.
  run_scaffold
  assert_success
  grep -q "file1.txt" "$OUT_DIR/$OUT_FILE_NAME"
}

# ---------------------------------------------------------------------------
# 5. §5 / §8 plan pointer
# ---------------------------------------------------------------------------

@test "section 5 / 8 reference the planted plan file" {
  run_scaffold
  assert_success
  grep -q "some-plan.md" "$OUT_DIR/$OUT_FILE_NAME"
}

# ---------------------------------------------------------------------------
# 6. Enrich slots
# ---------------------------------------------------------------------------

@test "slot placeholders {{ }} present for enrich sections" {
  run_scaffold
  assert_success
  grep -q "{{" "$OUT_DIR/$OUT_FILE_NAME"
}

# ---------------------------------------------------------------------------
# 7. gh degradation is hook-safe
# ---------------------------------------------------------------------------

@test "gh failure: still exits 0, writes file, notes gh unavailable" {
  # Make the gh stub fail (as if gh missing / unauthenticated).
  cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_DIR/gh"

  run_scaffold
  assert_success
  local f="$OUT_DIR/$OUT_FILE_NAME"
  [ -f "$f" ]
  grep -q "_(gh unavailable" "$f"
  grep -q "Add first fixture file" "$f"
}

# ---------------------------------------------------------------------------
# 8. --dry-run
# ---------------------------------------------------------------------------

@test "--dry-run prints markdown to stdout and writes no file" {
  run_scaffold --dry-run
  assert_success
  echo "$output" | grep -q "## 1. TL;DR"
  [ ! -f "$OUT_DIR/$OUT_FILE_NAME" ]
}

# ---------------------------------------------------------------------------
# 9. Not a git repo — hook-safe degradation
# ---------------------------------------------------------------------------

@test "not a git repo: exits 0, no crash, no file" {
  local notrepo="$HOME/notarepo"
  mkdir -p "$notrepo"
  run python3 "$SCRIPT" --repo "$notrepo" --out-dir "$OUT_DIR" --now "$FIXED_NOW"
  assert_success
  [ ! -f "$OUT_DIR/2026-07-05-notarepo-auto.md" ]
}

# ---------------------------------------------------------------------------
# 10. SUPERSEDED plan skip — newest self-superseded plan is NOT chosen as seed
# ---------------------------------------------------------------------------

@test "section 5 / 8 skip a self-declared SUPERSEDED plan for the current one" {
  # A NEWER plan that self-declares SUPERSEDED must be skipped; the OLDER
  # unmarked plan must win. Both are committed so they don't surface in §3's
  # uncommitted list (which would false-positive the negative grep below).
  # Year-2099 mtimes keep both newer than setup's some-plan.md regardless of
  # wall-clock time; `touch -t CCYYMMDDhhmm` is portable across BSD + GNU.
  printf '# Current plan\n' > "$FIXTURE_REPO/plans/current-plan.md"
  printf '> **⛔ SUPERSEDED by newer**\n' > "$FIXTURE_REPO/plans/old-superseded.md"
  git -C "$FIXTURE_REPO" add plans/current-plan.md plans/old-superseded.md
  git -C "$FIXTURE_REPO" commit -q -m "Add current + superseded plans"
  touch -t 209901010000 "$FIXTURE_REPO/plans/current-plan.md"    # older
  touch -t 209901020000 "$FIXTURE_REPO/plans/old-superseded.md"  # newer

  run_scaffold
  assert_success
  local f="$OUT_DIR/$OUT_FILE_NAME"
  grep -q "current-plan.md" "$f"
  ! grep -q "old-superseded.md" "$f"
}
