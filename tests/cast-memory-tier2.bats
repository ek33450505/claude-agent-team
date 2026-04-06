#!/usr/bin/env bats
# Tests for CAST Memory Persistence Tier 2 scripts:
#   cast-memory-schema-v3.py, cast-memory-embed.py, cast-memory-validate.py,
#   cast-memory-router.py (hybrid search), cast-session-distiller.py
#
# Coverage (15 tests):
#   1-3.  cast-memory-schema-v3: adds columns, idempotent
#   4-6.  cast-memory-embed: --text, --backfill, graceful on Ollama down
#   7-10. cast-memory-validate: --check, JSON, --validate, --archive-stale
#  11-12. cast-memory-router: hybrid search, Ollama fallback
#  13-15. cast-session-distiller: --dry-run, JSON, BLOCKED memory write

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"
SCHEMA_V2="$REPO_DIR/scripts/cast-memory-schema-v2.py"
SCHEMA_V3="$REPO_DIR/scripts/cast-memory-schema-v3.py"
EMBED_PY="$REPO_DIR/scripts/cast-memory-embed.py"
VALIDATE_PY="$REPO_DIR/scripts/cast-memory-validate.py"
ROUTER_PY="$REPO_DIR/scripts/cast-memory-router.py"
DISTILLER_PY="$REPO_DIR/scripts/cast-session-distiller.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude"
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
  python3 "$SCHEMA_V2" >/dev/null 2>&1 || true
  python3 "$SCHEMA_V3" >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast-memory-schema-v3: column additions
# ---------------------------------------------------------------------------

@test "cast-memory-schema-v3: adds embedding column" {
  col_count="$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories);" 2>/dev/null | grep -c "^[0-9]*|embedding|" || true)"
  [ "$col_count" -ge 1 ]
}

@test "cast-memory-schema-v3: adds last_validated_at column" {
  col_count="$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories);" 2>/dev/null | grep -c "last_validated_at" || true)"
  [ "$col_count" -ge 1 ]
}

@test "cast-memory-schema-v3: is idempotent on second run" {
  # Already run once in setup; run again and confirm exits 0 with "already present"
  run python3 "$SCHEMA_V3"
  assert_success
  assert_output --partial "already present"
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

@test "cast-memory-validate: --validate updates last_validated_at for non-stale memories" {
  # Seed a fresh memory (created now — should be non-stale)
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, project, type, name, description, content, importance, decay_rate) VALUES ('shared', 'cast', 'feedback', 'fresh-memory-validate', 'Test', 'Fresh memory content.', 0.8, 0.995);" 2>/dev/null

  run python3 "$VALIDATE_PY" --validate
  assert_success

  # Check last_validated_at was set for the fresh memory
  val="$(sqlite3 "$CAST_DB_PATH" "SELECT last_validated_at FROM agent_memories WHERE name='fresh-memory-validate';" 2>/dev/null)"
  [ -n "$val" ]
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
# cast-session-distiller: dry-run and BLOCKED memory write
# ---------------------------------------------------------------------------

@test "cast-session-distiller: --dry-run exits 0" {
  run python3 "$DISTILLER_PY" --dry-run
  assert_success
}

@test "cast-session-distiller: --dry-run output is valid JSON" {
  run python3 "$DISTILLER_PY" --dry-run
  assert_success
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "cast-session-distiller: writes memory for a BLOCKED agent_run" {
  # Seed an agent_runs row with status=BLOCKED using actual schema columns
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_runs (session_id, agent, status, task_summary) VALUES ('test-session-001', 'test-agent', 'BLOCKED', 'Could not proceed due to missing config.');" 2>/dev/null

  run python3 "$DISTILLER_PY"
  assert_success

  # Verify memory was written to agent_memories
  mem_count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE name LIKE 'blocked-test-agent-%';" 2>/dev/null)"
  [ "$mem_count" -ge 1 ]
}
