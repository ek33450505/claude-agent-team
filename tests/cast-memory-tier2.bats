#!/usr/bin/env bats
# Tests for CAST Memory Persistence Tier 2 scripts:
#   cast-memory-embed.py, cast-memory-validate.py,
#   cast-memory-router.py (hybrid search), cast-session-distiller.py
#
# Coverage (surviving tests after orphan script cleanup):
#   1-5.   cast-memory-embed: --text, --backfill, graceful on Ollama down,
#          _is_safe_url gating (accepts real URL / rejects external host +
#          non-http scheme), embed_text short-circuits on unsafe URL
#   6-8.   cast-memory-validate: --check, JSON, --archive-stale
#   9-10.  cast-memory-router: hybrid search, Ollama fallback
#   11-13. cast-session-distiller: --dry-run, JSON, feedback pattern → pending candidate

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
EMBED_PY="$REPO_DIR/scripts/cast-memory-embed.py"
VALIDATE_PY="$REPO_DIR/scripts/cast-memory-validate.py"
ROUTER_PY="$REPO_DIR/scripts/cast-memory-router.py"
DISTILLER_PY="$REPO_DIR/scripts/cast-session-distiller.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude"
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
  # Add columns that were previously added by migration scripts (now deleted)
  sqlite3 "$CAST_DB_PATH" "
    ALTER TABLE agent_memories ADD COLUMN importance FLOAT DEFAULT 0.5;
    ALTER TABLE agent_memories ADD COLUMN decay_rate FLOAT DEFAULT 0.995;
    ALTER TABLE agent_memories ADD COLUMN embedding BLOB;
    ALTER TABLE agent_memories ADD COLUMN last_validated_at TEXT;
    CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts
      USING fts5(name, description, content, content=agent_memories, content_rowid=id);
  " 2>/dev/null || true
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast-memory-embed: basic CLI behavior
# ---------------------------------------------------------------------------

@test "cast-memory-embed: --text flag exits 0 (gracefully handles Ollama unavailable)" {
  run python3 "$EMBED_PY" --text "CAST agent memory system"
  assert_success
  # Either Ollama is running (Embedding OK) or gracefully unavailable
  [[ "$output" == *"Embedding OK"* ]] || [[ "$output" == *"Ollama unavailable"* ]]
}

@test "cast-memory-embed: --backfill on fresh DB exits 0" {
  run python3 "$EMBED_PY" --backfill
  assert_success
  # Should report 0 rows backfilled (no content yet) or N rows if Ollama available
  assert_output --partial "Backfilled"
}

@test "cast-memory-embed: graceful when Ollama unreachable (bad port)" {
  # Verify embed_text returns None (no crash) when Ollama is not reachable.
  # We inline a small test by importing the module via a temp Python script.
  local embed_script="$EMBED_PY"
  run python3 - "$embed_script" <<'PYEOF'
import sys, importlib.util, os

src_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("embed", src_path)
mod = importlib.util.module_from_spec(spec)
# Override URL before exec
mod.__dict__['OLLAMA_EMBED_URL'] = 'http://localhost:19999/api/embed'
spec.loader.exec_module(mod)
mod.OLLAMA_EMBED_URL = 'http://localhost:19999/api/embed'

result = mod.embed_text("test text")
if result is None:
    print("graceful: returned None")
    sys.exit(0)
else:
    print("unexpected: got embedding from bad port")
    sys.exit(1)
PYEOF
  assert_success
  assert_output --partial "graceful"
}

@test "cast-memory-embed: _is_safe_url rejects non-local hosts (SSRF gate)" {
  local embed_script="$EMBED_PY"
  run python3 - "$embed_script" <<'PYEOF'
import sys, importlib.util

src_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("embed", src_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# The real hardcoded Ollama URL must remain accepted.
assert mod._is_safe_url(mod.OLLAMA_EMBED_URL) is True, "real OLLAMA_EMBED_URL must stay safe"

# External hosts and non-http(s) schemes must be rejected.
assert mod._is_safe_url("http://evil.example.com/api/embed") is False, "external host must be rejected"
assert mod._is_safe_url("file:///etc/passwd") is False, "non-http(s) scheme must be rejected"

print("ok: _is_safe_url gating correct")
sys.exit(0)
PYEOF
  assert_success
  assert_output --partial "ok: _is_safe_url gating correct"
}

@test "cast-memory-embed: embed_text short-circuits on unsafe URL without network call" {
  local embed_script="$EMBED_PY"
  run python3 - "$embed_script" <<'PYEOF'
import sys, importlib.util

src_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("embed", src_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Point at a non-local host: must be gated before any request is attempted.
mod.OLLAMA_EMBED_URL = "http://example.com/api/embed"

result = mod.embed_text("test text")
if result is None:
    print("graceful: unsafe URL gated, returned None")
    sys.exit(0)
else:
    print("unexpected: got embedding from unsafe URL")
    sys.exit(1)
PYEOF
  assert_success
  assert_output --partial "graceful: unsafe URL gated"
}

# ---------------------------------------------------------------------------
# cast-memory-validate: report, validate, archive
# ---------------------------------------------------------------------------

@test "cast-memory-validate: --check exits 0" {
  run python3 "$VALIDATE_PY" --check
  assert_success
}

@test "cast-memory-validate: --check output is valid JSON" {
  run python3 "$VALIDATE_PY" --check
  assert_success
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "cast-memory-validate: --check reports every seeded memory under the LIMIT cap" {
  # Regression guard for the defensive LIMIT added to load_memories()'s
  # SELECT * — a handful of rows must never be silently truncated.
  sqlite3 "$CAST_DB_PATH" "
    INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate, created_at) VALUES ('shared', 'cast', 'feedback', 'cap-test-one', 'First', 'First memory content.', 0.5, 0.995, datetime('now'));
    INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate, created_at) VALUES ('shared', 'cast', 'feedback', 'cap-test-two', 'Second', 'Second memory content.', 0.5, 0.995, datetime('now'));
    INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate, created_at) VALUES ('shared', 'cast', 'feedback', 'cap-test-three', 'Third', 'Third memory content.', 0.5, 0.995, datetime('now'));
  " 2>/dev/null

  run python3 "$VALIDATE_PY" --check
  assert_success
  assert_output --partial "cap-test-one"
  assert_output --partial "cap-test-two"
  assert_output --partial "cap-test-three"
}

@test "cast-memory-validate: --archive-stale sets importance=0 for old memories" {
  # Seed a memory with created_at 60 days ago (definitely stale)
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate, created_at) VALUES ('shared', 'cast', 'feedback', 'old-memory-archive', 'Old test', 'Old memory content from long ago.', 0.9, 0.995, datetime('now', '-60 days'));" 2>/dev/null

  run python3 "$VALIDATE_PY" --age-days 30 --archive-stale
  assert_success

  importance="$(sqlite3 "$CAST_DB_PATH" "SELECT CAST(importance AS TEXT) FROM agent_memories WHERE name='old-memory-archive';" 2>/dev/null)"
  # SQLite may return "0.0" or "0" depending on version — check it's 0 or 0.0
  python3 -c "import sys; v=sys.argv[1]; sys.exit(0 if float(v) == 0.0 else 1)" "$importance"
}

# ---------------------------------------------------------------------------
# cast-memory-router: hybrid search and Ollama fallback
# ---------------------------------------------------------------------------

@test "cast-memory-router: retrieve mode returns JSON array" {
  # Seed a memory to search against
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate) VALUES ('shared', 'cast', 'feedback', 'router-test-mem', 'Router test', 'BATS test whitespace wc output', 0.8, 0.995);" 2>/dev/null

  run python3 "$ROUTER_PY" --mode retrieve --agent shared --prompt "BATS test wc whitespace" --top-n 3
  assert_success
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)' 2>/dev/null
}

@test "cast-memory-router: retrieve mode falls back gracefully when Ollama down" {
  # Seed a memory and verify retrieval still works without Ollama
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate) VALUES ('shared', 'cast', 'feedback', 'router-fallback-mem', 'Fallback test', 'CAST memory fallback test content', 0.8, 0.995);" 2>/dev/null

  local router_script="$ROUTER_PY"
  local db_path="$CAST_DB_PATH"
  run python3 - "$router_script" "$db_path" <<'PYEOF'
import sys, os, subprocess, json

router_script = sys.argv[1]
db_path = sys.argv[2]

result = subprocess.run(
    [sys.executable, router_script,
     '--mode', 'retrieve',
     '--agent', 'shared',
     '--prompt', 'CAST memory fallback test',
     '--top-n', '2'],
    capture_output=True, text=True, timeout=15,
    env={**os.environ, 'CAST_DB_PATH': db_path}
)
if result.returncode != 0:
    print(f"FAILED: exit {result.returncode}: {result.stderr}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(result.stdout)
    assert isinstance(data, list)
    print("fallback ok")
    sys.exit(0)
except Exception as e:
    print(f"FAILED: bad JSON: {e}\noutput: {result.stdout[:200]}", file=sys.stderr)
    sys.exit(1)
PYEOF
  assert_success
  assert_output --partial "fallback ok"
}

# ---------------------------------------------------------------------------
# cast-session-distiller: stdin-based transcript extraction
# ---------------------------------------------------------------------------

@test "cast-session-distiller: --dry-run exits 0 on empty input" {
  run bash -c "echo '' | python3 '$DISTILLER_PY' --dry-run"
  assert_success
}

@test "cast-session-distiller: --dry-run output is valid JSON" {
  run bash -c "echo '' | python3 '$DISTILLER_PY' --dry-run"
  assert_success
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)'
}

@test "cast-session-distiller: writes _pending candidate for feedback pattern (no DB write)" {
  local pend="$HOME/.claude/distiller-pending"
  run bash -c "echo \"don't mock the database in tests\" | python3 '$DISTILLER_PY' --pending-dir '$pend'"
  assert_success

  # A feedback candidate markdown file landed in the _pending/ queue
  run bash -c "ls '$pend'/feedback_*.md 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" -ge 1 ]

  # The distiller no longer writes to the DB
  mem_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE agent='shared';" 2>/dev/null)"
  [ "$mem_count" -eq 0 ]
}
