#!/usr/bin/env bats
# cast-resume-inject-hook.bats — Tests for cast-resume-inject-hook.sh
#
# All tests use setup_temp_home / teardown_temp_home to isolate file operations
# from the real ~/.claude directory (HARD RULE: tests touching HOME use temp HOME).
#
# Coverage:
#   1. No resume-prompts dir → exits 0, empty output.
#   2. Empty resume-prompts dir → exits 0, empty output.
#   3. Auto file only → output has source="auto", hookEventName, body text.
#   4. Manual NEWER than auto → source="manual".
#   5. Manual OLDER than auto → source="auto" (stale-manual shadow guard).
#   6. Manual SAME date as auto → source="manual" (>= tie-break).
#   7. Manual only, no auto → source="manual".
#   8. Wrong-repo file only → exits 0, empty output (slug filter).
#   9. Body with [CAST-DISPATCH] → neutralized to [CAST_DISPATCH].
#  10. Output is valid JSON.
#  11. CLAUDE_SUBPROCESS=1 → subprocess guard fires, empty output.
#  12. Banner skips YAML frontmatter: systemMessage = first real heading, not "---".

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-resume-inject-hook.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME + fixture git repo
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  RESUME_DIR="$HOME/.claude/resume-prompts"

  # Fixture git repo — basename "fixture-repo" is the slug.
  FIXTURE_REPO="$HOME/fixture-repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email "test@example.com"
  git -C "$FIXTURE_REPO" config user.name "Test User"
  git -C "$FIXTURE_REPO" config commit.gpgsign false
  echo "init" > "$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add README.md
  git -C "$FIXTURE_REPO" commit -q -m "Initial commit"
  git -C "$FIXTURE_REPO" branch -M main
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 1. No resume-prompts dir at all
# ---------------------------------------------------------------------------

@test "no resume-prompts dir: exits 0, empty output" {
  # RESUME_DIR intentionally not created — hook must degrade silently.
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 2. Empty resume-prompts dir
# ---------------------------------------------------------------------------

@test "empty resume-prompts dir: exits 0, empty output" {
  mkdir -p "$RESUME_DIR"
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 3. Auto file only
# ---------------------------------------------------------------------------

@test "auto file only: output has source=auto, hookEventName, and body text" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
repo: fixture-repo
---
# Resume — fixture-repo auto: test state
Some body text here.
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial 'source=\"auto\"'
  assert_output --partial '"hookEventName": "SessionStart"'
  assert_output --partial 'Some body text here'
}

# ---------------------------------------------------------------------------
# 4. Manual NEWER than auto → manual wins
# ---------------------------------------------------------------------------

@test "manual dated newer than auto: output has source=manual" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Auto content
FIXTURE
  cat > "$RESUME_DIR/2026-07-10-fixture-repo-kickoff.md" <<'FIXTURE'
---
origin: manual
---
# Manual content — newer date
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial 'source=\"manual\"'
}

# ---------------------------------------------------------------------------
# 5. Manual OLDER than auto → auto wins (stale-manual shadow guard)
# ---------------------------------------------------------------------------

@test "manual dated older than auto: output has source=auto" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Auto content
FIXTURE
  cat > "$RESUME_DIR/2026-07-03-fixture-repo-notes.md" <<'FIXTURE'
---
origin: manual
---
# Old manual content
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial 'source=\"auto\"'
}

# ---------------------------------------------------------------------------
# 6. Manual SAME date as auto → manual wins (>= tie-break)
# ---------------------------------------------------------------------------

@test "manual same date as auto: manual wins via >= tie-break" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Auto content
FIXTURE
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-notes.md" <<'FIXTURE'
---
origin: manual
---
# Same-date manual content
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial 'source=\"manual\"'
}

# ---------------------------------------------------------------------------
# 7. Manual only, no auto
# ---------------------------------------------------------------------------

@test "manual only, no auto: output has source=manual" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-10-fixture-repo-kickoff.md" <<'FIXTURE'
---
origin: manual
---
# Manual-only content
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial 'source=\"manual\"'
}

# ---------------------------------------------------------------------------
# 8. Wrong-repo file only — slug filter must reject it
# ---------------------------------------------------------------------------

@test "wrong-repo file only: exits 0, empty output (slug filter)" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-other-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Other repo auto
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 9. [CAST-DISPATCH] neutralization
# ---------------------------------------------------------------------------

@test "[CAST-DISPATCH] in body is neutralized to [CAST_DISPATCH]" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Resume with directive
Use [CAST-DISPATCH] to route tasks.
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  assert_output --partial '[CAST_DISPATCH]'
  refute_output --partial '[CAST-DISPATCH]'
}

# ---------------------------------------------------------------------------
# 10. Output is valid JSON
# ---------------------------------------------------------------------------

@test "output is valid JSON" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# JSON validity test
Content for JSON test.
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  run env CAST_JSON="$output" python3 -c "import json,os; json.loads(os.environ['CAST_JSON'])"
  assert_success
}

# ---------------------------------------------------------------------------
# 11. CLAUDE_SUBPROCESS=1 → subprocess guard fires, empty output
# ---------------------------------------------------------------------------

@test "CLAUDE_SUBPROCESS=1: subprocess guard fires, empty output" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
---
# Subprocess guard test
FIXTURE
  # No cd needed: the subprocess guard exits before git rev-parse.
  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" </dev/null
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 12. Banner skips YAML frontmatter — systemMessage = first real heading
# ---------------------------------------------------------------------------

@test "banner skips YAML frontmatter: systemMessage is the first real heading" {
  mkdir -p "$RESUME_DIR"
  cat > "$RESUME_DIR/2026-07-06-fixture-repo-auto.md" <<'FIXTURE'
---
origin: resume-scaffold
repo: fixture-repo
---
# Real Title
Body content below the frontmatter.
FIXTURE
  cd "$FIXTURE_REPO"
  run bash "$SCRIPT" </dev/null
  assert_success
  banner=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['systemMessage'])")
  [[ "$banner" == "# Real Title"* ]]
  [[ "$banner" != "---"* ]]
}
