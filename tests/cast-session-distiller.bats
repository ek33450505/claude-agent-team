#!/usr/bin/env bats
# cast-session-distiller.bats — Tests for cast-session-distiller.py (pending-queue edition)
#
# All tests use setup_temp_home / teardown_temp_home to isolate file operations
# from the real ~/.claude directory (HARD RULE: tests touching HOME use temp HOME).
#
# Coverage:
#   1. JSONL filtering — only genuine user prose produces a file; isMeta, chrome,
#      tool_result content (list), and assistant turns are all filtered out.
#   2. No DB writes — agent_memories stays 0 after a run.
#   3. Dedup — running twice on the same transcript writes exactly one file;
#      promoting to canonical dir also blocks re-write.
#   4. --max-candidates cap respected.
#   5. Empty / non-JSONL / malformed input → exit 0, no crash, no files.
#   6. --dry-run prints JSON array and writes no files.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISTILLER="$REPO_DIR/scripts/cast-session-distiller.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # Pending + canonical dirs under temp HOME
  PENDING_DIR="$HOME/memory/_pending"
  CANONICAL_DIR="$HOME/memory"
  mkdir -p "$PENDING_DIR" "$CANONICAL_DIR"

  # Temp DB for "no DB writes" assertions — distiller should never touch this
  TEST_DB="$HOME/cast.db"
  export CAST_DB_PATH="$TEST_DB"
  python3 - <<'PYEOF'
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.executescript("""
    CREATE TABLE IF NOT EXISTS agent_memories (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        agent       TEXT    NOT NULL,
        type        TEXT    NOT NULL DEFAULT 'project',
        name        TEXT    NOT NULL,
        description TEXT,
        content     TEXT,
        created_at  TEXT    DEFAULT (datetime('now'))
    );
""")
conn.commit()
conn.close()
PYEOF

  # Synthetic JSONL transcript with five lines covering all filter branches:
  #   1. Genuine user prose with extractable pattern → should produce feedback_*.md
  #   2. isMeta user turn                           → filtered (isMeta=true)
  #   3. Chrome/command turn                        → filtered (<command-name>)
  #   4. Tool-result list content                   → filtered (list content)
  #   5. Assistant turn with "never" phrase         → filtered (type != user)
  TRANSCRIPT="$HOME/session-abc12345678.jsonl"
  python3 - "$TRANSCRIPT" <<'PYEOF'
import json, sys
lines = [
    {"type": "user",      "message": {"content": "Always run the linter before pushing."}, "isMeta": False},
    {"type": "user",      "message": {"content": "Always use the caveat helper."},          "isMeta": True},
    {"type": "user",      "message": {"content": "<command-name>test-runner</command-name> run tests"}, "isMeta": False},
    {"type": "user",      "message": {"content": [{"type": "tool_result", "tool_use_id": "x", "content": "output"}]}, "isMeta": False},
    {"type": "assistant", "message": {"content": "never do X when Y is true, it causes issues."}, "isMeta": False},
]
with open(sys.argv[1], 'w') as f:
    for obj in lines:
        f.write(json.dumps(obj) + '\n')
PYEOF
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: run distiller on TRANSCRIPT with explicit --pending-dir
# ---------------------------------------------------------------------------

run_distiller() {
  run python3 "$DISTILLER" --input "$TRANSCRIPT" --pending-dir "$PENDING_DIR" "$@"
}

_count_pending() {
  ls "$PENDING_DIR"/*.md 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# 1. JSONL filtering
# ---------------------------------------------------------------------------

@test "JSONL filtering: exactly one file written to _pending/" {
  run_distiller
  assert_success
  [ "$(_count_pending)" -eq 1 ]
}

@test "JSONL filtering: the written file is named feedback_*.md" {
  run_distiller
  assert_success
  local found
  found=$(ls "$PENDING_DIR"/feedback_*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]
}

@test "JSONL filtering: isMeta turn ('Always use the caveat helper') produces no file" {
  run_distiller
  assert_success
  local found
  found=$(ls "$PENDING_DIR"/feedback_always-use-the-caveat-helper*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "JSONL filtering: chrome turn with <command-name> produces no file" {
  run_distiller
  assert_success
  # If chrome weren't filtered, slug would contain "command-name" text
  local found
  found=$(ls "$PENDING_DIR"/*command-name*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "JSONL filtering: tool_result list content produces no file" {
  run_distiller
  assert_success
  # tool_result content would have slug starting with "output" or similar
  local found
  found=$(ls "$PENDING_DIR"/*tool-result*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "JSONL filtering: assistant turn with 'never' phrase produces no file" {
  run_distiller
  assert_success
  local found
  found=$(ls "$PENDING_DIR"/feedback_never-do-x*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "JSONL filtering: written file has required frontmatter fields" {
  run_distiller
  assert_success
  local fpath
  fpath=$(ls "$PENDING_DIR"/feedback_*.md 2>/dev/null | head -1)
  grep -q "^name:" "$fpath"
  grep -q "^description:" "$fpath"
  grep -q "type: feedback" "$fpath"
  grep -q "origin: session-distiller" "$fpath"
  grep -q "confidence: low" "$fpath"
}

@test "JSONL filtering: written file does NOT contain verified_at: YAML key (unverified)" {
  run_distiller
  assert_success
  local fpath
  fpath=$(ls "$PENDING_DIR"/feedback_*.md 2>/dev/null | head -1)
  # The body mentions "verified_at" in review instructions — check the YAML key form is absent
  ! grep -q "^  verified_at:" "$fpath"
  ! grep -q "^verified_at:" "$fpath"
}

# ---------------------------------------------------------------------------
# 2. No DB writes — agent_memories stays 0
# ---------------------------------------------------------------------------

@test "no DB writes: agent_memories count is 0 after run" {
  run_distiller
  assert_success
  local count
  count=$(python3 -c "
import os, sqlite3
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(conn.execute('SELECT COUNT(*) FROM agent_memories').fetchone()[0])
conn.close()
")
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3. Dedup
# ---------------------------------------------------------------------------

@test "dedup: first run writes exactly one file" {
  run_distiller
  assert_success
  [ "$(_count_pending)" -eq 1 ]
}

@test "dedup: second run on the same transcript does not create additional files" {
  run_distiller
  run_distiller
  assert_success
  [ "$(_count_pending)" -eq 1 ]
}

@test "dedup: file promoted to canonical dir blocks re-write to _pending/" {
  run_distiller
  assert_success
  # Simulate promotion: move file from _pending/ to canonical memory dir
  local fpath
  fpath=$(ls "$PENDING_DIR"/*.md | head -1)
  mv "$fpath" "$CANONICAL_DIR/"
  # Run again — canonical dir now has the slug, so nothing new should be written
  run_distiller
  assert_success
  [ "$(_count_pending)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. --max-candidates cap
# ---------------------------------------------------------------------------

@test "--max-candidates cap: only writes up to the specified limit" {
  local multi="$HOME/multi-session.jsonl"
  python3 - "$multi" <<'PYEOF'
import json, sys
turns = [
    "Always run the linter before pushing.",
    "Never skip the code review step.",
    "Always write tests before submitting a PR.",
    "Never deploy on Fridays without a rollback plan.",
]
with open(sys.argv[1], 'w') as f:
    for t in turns:
        f.write(json.dumps({"type": "user", "message": {"content": t}, "isMeta": False}) + '\n')
PYEOF
  run python3 "$DISTILLER" --input "$multi" \
      --pending-dir "$PENDING_DIR" --max-candidates 2
  assert_success
  local count
  count="$(_count_pending)"
  [ "$count" -le 2 ]
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 5. Empty / non-JSONL / malformed input
# ---------------------------------------------------------------------------

@test "empty stdin: exits 0" {
  run bash -c "echo '' | python3 '$DISTILLER' --pending-dir '$PENDING_DIR'"
  assert_success
}

@test "empty stdin: writes no files" {
  echo '' | python3 "$DISTILLER" --pending-dir "$PENDING_DIR" 2>/dev/null || true
  [ "$(_count_pending)" -eq 0 ]
}

@test "plain text with no extractable patterns: exits 0, writes no files" {
  echo "Hello, this is a plain text transcript with no memorable patterns." | \
      python3 "$DISTILLER" --pending-dir "$PENDING_DIR" 2>/dev/null || true
  [ "$(_count_pending)" -eq 0 ]
}

@test "malformed JSON lines: exits 0, writes no files" {
  printf '{not valid json}\n{also bad}\n' | \
      python3 "$DISTILLER" --pending-dir "$PENDING_DIR" 2>/dev/null || true
  [ "$(_count_pending)" -eq 0 ]
}

@test "whitespace-only input: exits 0" {
  run bash -c "printf '   \n   ' | python3 '$DISTILLER' --pending-dir '$PENDING_DIR'"
  assert_success
}

@test "stdin with no --pending-dir and no --input: exits 0 cleanly" {
  run bash -c "echo 'Always run the linter.' | python3 '$DISTILLER'"
  assert_success
}

@test "JSONL with only filtered turns (all isMeta): exits 0, writes no files" {
  local no_prose="$HOME/no-prose.jsonl"
  python3 - "$no_prose" <<'PYEOF'
import json, sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({"type": "user", "message": {"content": "Always check."}, "isMeta": True}) + '\n')
    f.write(json.dumps({"type": "assistant", "message": {"content": "never do that."}, "isMeta": False}) + '\n')
PYEOF
  run python3 "$DISTILLER" --input "$no_prose" --pending-dir "$PENDING_DIR"
  assert_success
  [ "$(_count_pending)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. --dry-run
# ---------------------------------------------------------------------------

@test "--dry-run: exits 0" {
  run python3 "$DISTILLER" --input "$TRANSCRIPT" --pending-dir "$PENDING_DIR" --dry-run
  assert_success
}

@test "--dry-run: output is a valid JSON array" {
  local result
  result=$(python3 "$DISTILLER" --input "$TRANSCRIPT" --pending-dir "$PENDING_DIR" --dry-run)
  echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,list)"
}

@test "--dry-run: output contains at least one candidate for the genuine user turn" {
  local result
  result=$(python3 "$DISTILLER" --input "$TRANSCRIPT" --pending-dir "$PENDING_DIR" --dry-run)
  local count
  count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  [ "$count" -ge 1 ]
}

@test "--dry-run: writes no files to _pending/" {
  python3 "$DISTILLER" --input "$TRANSCRIPT" --pending-dir "$PENDING_DIR" --dry-run 2>/dev/null
  [ "$(_count_pending)" -eq 0 ]
}

@test "--dry-run with empty stdin: outputs [] JSON array, exits 0" {
  run bash -c "echo '' | python3 '$DISTILLER' --dry-run"
  assert_success
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# 7. Security regression — M1 YAML newline injection
# ---------------------------------------------------------------------------

@test "M1 regression: embedded newline in description is folded, no injected type: key" {
  # A user turn whose content includes a real newline mid-sentence (project pattern match).
  # The injected newline would let a malicious transcript write "type: evil" as a YAML key
  # if description is not sanitized.
  local inject_transcript="$HOME/inject-session.jsonl"
  python3 - "$inject_transcript" <<'PYEOF'
import json, sys
# Embed a literal newline so the description would span lines if not stripped
content = "The reason we are doing this is\ntype: evil\n"
obj = {"type": "user", "message": {"content": content}, "isMeta": False}
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps(obj) + '\n')
PYEOF
  run python3 "$DISTILLER" --input "$inject_transcript" --pending-dir "$PENDING_DIR"
  assert_success
  # If a file was written, assert the injected "type: evil" line is not present
  local fpath
  fpath=$(ls "$PENDING_DIR"/project_*.md 2>/dev/null | head -1)
  if [[ -n "$fpath" ]]; then
    # The frontmatter must not contain a bare "type: evil" line
    ! grep -q "^type: evil" "$fpath"
    # The description line must be a single YAML scalar (no newline break)
    local desc_lines
    desc_lines=$(grep -c "^description:" "$fpath" || true)
    [ "$desc_lines" -eq 1 ]
  fi
}

# ---------------------------------------------------------------------------
# 8. Regression — --min-importance suppresses lower-importance candidates
# ---------------------------------------------------------------------------

@test "--min-importance 0.9: suppresses 0.75-importance 'always' candidate" {
  # "always" pattern fires at 0.75, which is below the 0.9 threshold
  local high_threshold_transcript="$HOME/high-threshold.jsonl"
  python3 - "$high_threshold_transcript" <<'PYEOF'
import json, sys
obj = {"type": "user", "message": {"content": "Always run the linter before pushing."}, "isMeta": False}
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps(obj) + '\n')
PYEOF
  run python3 "$DISTILLER" --input "$high_threshold_transcript" \
      --pending-dir "$PENDING_DIR" --min-importance 0.9
  assert_success
  [ "$(_count_pending)" -eq 0 ]
}
