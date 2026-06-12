#!/usr/bin/env bats
# tests/hooks/test_cast_duration_check.bats
# Covers: scripts/cast-duration-check.sh

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-duration-check.sh"

# ── Payload helpers ──────────────────────────────────────────────────────────

make_payload() {
  local agent_type="${1:-code-writer}"
  local agent_id="${2:-agent-dur-001}"
  python3 -c "
import json, sys
print(json.dumps({
    'agent_type': sys.argv[1],
    'agent_id': sys.argv[2],
    'session_id': 'test-session-dur',
}))
" "$agent_type" "$agent_id"
}

# ── Setup / teardown ─────────────────────────────────────────────────────────

setup() {
  TEST_DB="$BATS_TEST_TMPDIR/test-dur.db"
  export CAST_DB_PATH="$TEST_DB"

  python3 - <<'PYEOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute('''CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT, session_id TEXT, status TEXT,
  started_at TEXT, ended_at TEXT,
  agent_id TEXT, duration_ms INTEGER, owns_files TEXT
)''')
con.execute('''CREATE TABLE IF NOT EXISTS routing_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, timestamp TEXT,
  prompt_preview TEXT, action TEXT,
  matched_route TEXT, match_type TEXT,
  pattern TEXT, confidence TEXT, project TEXT,
  event_type TEXT, data TEXT
)''')
con.commit(); con.close()
PYEOF

  unset CLAUDE_SUBPROCESS
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

seed_historical_runs() {
  # Seed N historical runs for an agent_type with given duration_ms (all within 30 days)
  local agent_type="$1"
  local count="$2"
  local duration_ms="$3"
  python3 - <<PYEOF
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
for i in range($count):
    con.execute(
        "INSERT INTO agent_runs (agent, session_id, duration_ms, started_at) VALUES (?, ?, ?, datetime('now','-1 days'))",
        ('$agent_type', 'hist-session', $duration_ms)
    )
con.commit(); con.close()
PYEOF
}

seed_current_run() {
  local agent_type="$1"
  local agent_id="$2"
  local duration_ms="$3"
  python3 - <<PYEOF
import sqlite3, os
db = os.environ['CAST_DB_PATH']
con = sqlite3.connect(db)
con.execute(
    "INSERT INTO agent_runs (agent, agent_id, session_id, duration_ms, started_at) VALUES (?, ?, ?, ?, datetime('now','-1 days'))",
    ('$agent_type', '$agent_id', 'test-session-dur', $duration_ms)
)
con.commit(); con.close()
PYEOF
}

count_slow_events() {
  python3 -c "
import sqlite3, os
con = sqlite3.connect(os.environ['CAST_DB_PATH'])
print(con.execute(\"SELECT COUNT(*) FROM routing_events WHERE event_type='slow_agent'\").fetchone()[0])
con.close()
"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Fewer than 5 historical samples → no slow_agent event (insufficient data)
@test "duration-check: fewer than 5 historical samples → no slow_agent event" {
  # Only 2 historical samples exist; current run has very high duration
  seed_historical_runs 'code-writer' 2 1000
  seed_current_run 'code-writer' 'agent-dur-002' 99999

  CAST_INPUT="$(make_payload 'code-writer' 'agent-dur-002')" run bash "$HOOK" <<< ""
  assert_success
  [ "$(count_slow_events)" -eq 0 ]
}

# 3. ≥5 samples AND current duration > p95 → slow_agent event + [CAST-PERF] stderr
@test "duration-check: current duration_ms exceeds p95 with ≥5 samples → slow_agent event + stderr warning" {
  # 10 historical runs at 1000ms each → p95 is ~1000ms
  seed_historical_runs 'security' 10 1000
  # Current run is 9999ms — well above p95
  seed_current_run 'security' 'agent-dur-fast' 9999

  CAST_INPUT="$(make_payload 'security' 'agent-dur-fast')" run bash "$HOOK" <<< ""
  assert_success
  assert_output --partial "[CAST-PERF]"
  [ "$(count_slow_events)" -eq 1 ]
}

# 4. Current duration ≤ p95 → no event
@test "duration-check: current duration_ms at or below p95 → no slow_agent event" {
  # 10 historical runs at 1000ms each → p95 is ~1000ms
  seed_historical_runs 'debugger' 10 1000
  # Current run is 500ms — below p95
  seed_current_run 'debugger' 'agent-dur-slow' 500

  CAST_INPUT="$(make_payload 'debugger' 'agent-dur-slow')" run bash "$HOOK" <<< ""
  assert_success
  refute_output --partial "[CAST-PERF]"
  [ "$(count_slow_events)" -eq 0 ]
}
