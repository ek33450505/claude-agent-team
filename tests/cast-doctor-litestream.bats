#!/usr/bin/env bats
# tests/cast-doctor-litestream.bats — doctor Litestream replica freshness check
#
# Tests the degradation ladder added to _cmd_doctor():
#   1. litestream not installed          → INFO
#   2. installed, config missing         → WARN
#   3. config present, daemon not loaded → WARN  (macOS via fake launchctl)
#   4. no launchctl (Linux/CI)           → INFO   (skipped on macOS)
#   5. replica dir missing/empty         → WARN
#   6. replica stale (lag >1h)           → WARN
#   7. replica fresh (lag <1h)           → OK
#
# Isolation: ALL tests use setup_temp_home/teardown_temp_home — never real $HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="${REPO_DIR}/bin/cast"

# ---------------------------------------------------------------------------
# Minimal cast.db (doctor returns early if DB is inaccessible)
# ---------------------------------------------------------------------------
_create_minimal_db() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT, model TEXT, project_dir TEXT, session_type TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0, duration_ms INTEGER, tool_uses INTEGER DEFAULT 0, outcome TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, started_at TEXT, ended_at TEXT, status TEXT, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, confidence REAL DEFAULT 1.0, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS stream_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS swarm_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, status TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS teammate_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, teammate_name TEXT, started_at TEXT, status TEXT);
CREATE TABLE IF NOT EXISTS teammate_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, role TEXT, content TEXT, ts TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, reason TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, severity TEXT, description TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT);
SQL
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  _create_minimal_db "$CAST_DB_PATH"

  # Point litestream root to a path inside the temp HOME so no real system dirs
  # are touched.
  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-litestream-test"

  # CAST_AGENTS_DIR: point at the repo's agents so the frontmatter check passes
  # and doctor doesn't warn about 0 agents.
  export CAST_AGENTS_DIR="${REPO_DIR}/agents/core"

  # Suppress subprocess guard so cast CLI actually runs.
  export CLAUDE_SUBPROCESS=0

  # Fake-binary dir for this test (BATS_TEST_TMPDIR is per-test-isolated)
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  mkdir -p "$FAKE_BIN"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: run 'cast doctor' with a controlled PATH prepended by FAKE_BIN
# ---------------------------------------------------------------------------
_run_doctor_with_path() {
  local extra_path="${1:-}"
  local base_path="${extra_path:+${extra_path}:}${PATH}"
  run env PATH="${base_path}" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
}

# Install a fake litestream binary in FAKE_BIN
_install_fake_litestream() {
  cat > "${FAKE_BIN}/litestream" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FAKE_BIN}/litestream"
}

# Install a fake launchctl that simulates "daemon not loaded" (exit 1)
_install_fake_launchctl_not_loaded() {
  cat > "${FAKE_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${FAKE_BIN}/launchctl"
}

# Install a fake launchctl that simulates "daemon loaded" (exit 0)
_install_fake_launchctl_loaded() {
  cat > "${FAKE_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FAKE_BIN}/launchctl"
}

# Create litestream.yml config at CAST_LITESTREAM_ROOT
_write_fake_config() {
  mkdir -p "${CAST_LITESTREAM_ROOT}"
  cat > "${CAST_LITESTREAM_ROOT}/litestream.yml" <<EOF
dbs:
  - path: ${CAST_DB_PATH}
    replicas:
      - type: file
        path: ${CAST_LITESTREAM_ROOT}/litestream/cast-db
EOF
}

# Create replica dir with a fresh file (mtime = now, lag ~0s)
_create_fresh_replica() {
  mkdir -p "${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  python3 -c "
import os, time
p = '${CAST_LITESTREAM_ROOT}/litestream/cast-db/0000000000000001.ltx'
with open(p, 'wb') as f:
    f.write(b'fake-ltx-frame')
# DB mtime ≈ replica mtime → lag ~0s
"
}

# Create replica dir with a stale file (mtime = 2h ago)
_create_stale_replica() {
  mkdir -p "${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  python3 -c "
import os, time
p = '${CAST_LITESTREAM_ROOT}/litestream/cast-db/0000000000000001.ltx'
with open(p, 'wb') as f:
    f.write(b'fake-ltx-frame')
stale_time = time.time() - 7200  # 2 hours ago
os.utime(p, (stale_time, stale_time))
"
}

# ---------------------------------------------------------------------------
# 1. litestream not installed → INFO
# ---------------------------------------------------------------------------
@test "litestream not installed: prints INFO advisory" {
  # Use a PATH that definitely does not contain litestream (standard system dirs)
  local safe_path="/usr/bin:/usr/sbin:/bin:/sbin"
  run env PATH="${safe_path}" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
  assert_output --partial "Litestream: not installed"
  assert_output --partial "opt-in"
}

@test "litestream not installed: does NOT print WARN or OK for litestream" {
  local safe_path="/usr/bin:/usr/sbin:/bin:/sbin"
  run env PATH="${safe_path}" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
  refute_output --partial "Litestream: replica"
  refute_output --partial "Litestream: installed but config"
}

# ---------------------------------------------------------------------------
# 2. Installed but config missing → WARN
# ---------------------------------------------------------------------------
@test "config missing: prints WARN with setup instruction" {
  _install_fake_litestream
  # Do NOT create litestream.yml
  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: installed but config missing"
  assert_output --partial "cast-litestream-setup.sh"
}

# ---------------------------------------------------------------------------
# 3. Config present, daemon not loaded (macOS launchctl returns 1) → WARN
# ---------------------------------------------------------------------------
@test "daemon not loaded: WARN with launchctl hint" {
  _install_fake_litestream
  _install_fake_launchctl_not_loaded
  _write_fake_config

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: daemon not loaded"
  assert_output --partial "com.cast.litestream.plist"
}

# ---------------------------------------------------------------------------
# 3b. Fresh replica + daemon NOT loaded → WARN about stale replication; no [ok]
# ---------------------------------------------------------------------------
@test "fresh replica + daemon not loaded: WARN about stale replication, no OK line" {
  _install_fake_litestream
  _install_fake_launchctl_not_loaded
  _write_fake_config
  _create_fresh_replica

  _run_doctor_with_path "$FAKE_BIN"
  # Must contain the new WARN about replication going stale
  assert_output --partial "replica present"
  assert_output --partial "daemon not loaded"
  assert_output --partial "replication will go stale"
  # Must NOT contain an [ok] Litestream line (the fresh-OK message)
  refute_output --partial "[ok] Litestream"
}

# ---------------------------------------------------------------------------
# 3c. Replica dir containing ONLY a .DS_Store → treated as missing/empty → WARN
# ---------------------------------------------------------------------------
@test "replica dir with only .DS_Store: treated as empty, prints WARN" {
  _install_fake_litestream
  _install_fake_launchctl_loaded
  _write_fake_config
  # Create replica dir with only a hidden junk file
  mkdir -p "${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  touch "${CAST_LITESTREAM_ROOT}/litestream/cast-db/.DS_Store"

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: replica dir missing or empty"
}

# ---------------------------------------------------------------------------
# 4. No launchctl available (Linux/CI) → INFO about skipped check
#    Skipped on macOS where /bin/launchctl is present and cannot be excluded
#    from PATH without breaking other tool lookups.
# ---------------------------------------------------------------------------
@test "no launchctl: daemon check skipped with INFO" {
  # This rung is only reachable on systems where launchctl is not in PATH.
  # On macOS, /bin/launchctl is always available — skip.
  command -v launchctl >/dev/null 2>&1 && skip "launchctl present on this system (macOS); tested on Linux/CI"

  _install_fake_litestream
  _write_fake_config
  # No launchctl in FAKE_BIN, and PATH controlled to exclude real launchctl

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "daemon check skipped"
  assert_output --partial "launchctl not available"
}

# ---------------------------------------------------------------------------
# 5. Replica dir missing → WARN
# ---------------------------------------------------------------------------
@test "replica dir missing: prints WARN" {
  _install_fake_litestream
  _install_fake_launchctl_loaded
  _write_fake_config
  # Replica dir intentionally not created

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: replica dir missing or empty"
}

@test "replica dir empty: prints WARN" {
  _install_fake_litestream
  _install_fake_launchctl_loaded
  _write_fake_config
  # Create empty replica dir
  mkdir -p "${CAST_LITESTREAM_ROOT}/litestream/cast-db"

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: replica dir missing or empty"
}

# ---------------------------------------------------------------------------
# 6. Replica stale (lag >3600s) → WARN
# ---------------------------------------------------------------------------
@test "replica stale: prints WARN with lag" {
  _install_fake_litestream
  _install_fake_launchctl_loaded
  _write_fake_config
  _create_stale_replica

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: replica stale"
  assert_output --partial ">1h behind cast.db"
}

# ---------------------------------------------------------------------------
# 7. Replica fresh (lag <3600s) → OK
# ---------------------------------------------------------------------------
@test "replica fresh: prints OK with lag" {
  _install_fake_litestream
  _install_fake_launchctl_loaded
  _write_fake_config
  _create_fresh_replica

  _run_doctor_with_path "$FAKE_BIN"
  assert_output --partial "Litestream: replica fresh"
  assert_output --partial "lag"
}
