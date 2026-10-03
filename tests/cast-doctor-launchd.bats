#!/usr/bin/env bats
# tests/cast-doctor-launchd.bats — doctor "launchd jobs loaded" check (#24)
#
# For every $HOME/Library/LaunchAgents/com.cast.*.plist, doctor asks
# _launchd_job_loaded (print-first, list fallback) whether the job is loaded:
#   1. all loaded                       → [ok] launchd: N/N com.cast.* jobs loaded
#   2. one unloaded                     → WARN naming exactly that label
#   3. sandbox shape (print ok, list fails) → loaded, no false "unloaded" WARN
#   4. no launchctl on PATH             → INFO skip
#   5. launchctl present, no plists     → INFO
#   6. plist Label key preferred over the filename
#
# Isolation: setup_temp_home/teardown_temp_home — never the real $HOME. launchctl is
# an argument-aware PATH shim (never the real one, never touches the real domain).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="${REPO_DIR}/bin/cast"

# Minimal cast.db (doctor returns early if the DB is inaccessible)
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

setup() {
  load 'helpers/setup'
  setup_temp_home # sets HOME to a temp dir; exports ORIG_HOME

  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  _create_minimal_db "$CAST_DB_PATH"

  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-litestream-test"
  export CAST_AGENTS_DIR="${REPO_DIR}/agents/core"
  export CLAUDE_SUBPROCESS=0

  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  mkdir -p "$FAKE_BIN"
  LA_DIR="${HOME}/Library/LaunchAgents"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run 'cast doctor' with PATH = FAKE_BIN + the normal PATH.
_run_doctor() {
  run env PATH="${FAKE_BIN}:${PATH}" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
}

# Argument-aware fake launchctl. State lives in sibling files so the stub body needs
# no interpolation:  launchctl.labels = loaded labels (one per line),
#                    launchctl.mode   = "print+list" | "print-only".
# It answers like the real thing: `print gui|user/<uid>/<label>` and (mode permitting)
# `list <label>` succeed only for a loaded label; everything else exits 113
# ("Could not find service"), including any other subcommand or malformed target.
# mode "print-only" is the sandboxed-shell shape: `list` sees an empty domain.
_install_fake_launchctl() {
  local mode="$1"
  shift
  printf '%s\n' "$mode" > "${FAKE_BIN}/launchctl.mode"
  : > "${FAKE_BIN}/launchctl.labels"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "${FAKE_BIN}/launchctl.labels"; done
  cat > "${FAKE_BIN}/launchctl" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
mode="$(cat "$here/launchctl.mode")"
sub="${1:-}"
target="${2:-}"
case "$sub" in
  print)
    case "$target" in
      gui/*/* | user/*/*) label="${target#*/*/}" ;;
      *) exit 113 ;;
    esac
    ;;
  list)
    [ "$mode" = "print-only" ] && exit 113
    label="$target"
    ;;
  *) exit 113 ;;
esac
grep -qxF -- "$label" "$here/launchctl.labels" 2>/dev/null && exit 0
exit 113
EOF
  chmod +x "${FAKE_BIN}/launchctl"
}

# Plant a LaunchAgent plist: _plant_plist <filename-stem> [<Label key value>]
_plant_plist() {
  local stem="$1" label="${2:-$1}"
  mkdir -p "$LA_DIR"
  cat > "${LA_DIR}/${stem}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
# 1. all loaded → ok N/N (a non-CAST plist must not be counted)
# ---------------------------------------------------------------------------
@test "all com.cast.* jobs loaded: ok N/N, no unloaded WARN" {
  _plant_plist com.cast.alpha
  _plant_plist com.cast.beta
  _plant_plist com.cast.gamma
  _plant_plist com.other.unrelated
  _install_fake_launchctl "print+list" com.cast.alpha com.cast.beta com.cast.gamma

  _run_doctor
  assert_output --partial "[ok] launchd: 3/3 com.cast.* jobs loaded"
  refute_output --partial "NOT loaded"
}

# ---------------------------------------------------------------------------
# 2. one unloaded → WARN naming exactly that label
# ---------------------------------------------------------------------------
@test "one job unloaded: WARN names it and reports N-1/N" {
  _plant_plist com.cast.alpha
  _plant_plist com.cast.beta
  _plant_plist com.cast.gamma
  _install_fake_launchctl "print+list" com.cast.alpha com.cast.gamma

  _run_doctor
  assert_output --partial "[!!] launchd: 2/3 com.cast.* jobs loaded"
  assert_output --partial "NOT loaded: com.cast.beta"
  refute_output --partial "[ok] launchd:"
  # the loaded ones are not named as unloaded
  refute_output --partial "NOT loaded: com.cast.alpha"
  refute_output --partial "com.cast.gamma ("
}

# ---------------------------------------------------------------------------
# 3. sandbox shape: `launchctl list` empty, `launchctl print` resolves → loaded
#    (the 2026-10-03 false alarm: 16/16 loaded, sandboxed shell saw 0)
# ---------------------------------------------------------------------------
@test "sandbox shape (print ok, list fails): jobs reported loaded, no false WARN" {
  _plant_plist com.cast.alpha
  _plant_plist com.cast.beta
  _install_fake_launchctl "print-only" com.cast.alpha com.cast.beta

  _run_doctor
  assert_output --partial "[ok] launchd: 2/2 com.cast.* jobs loaded"
  refute_output --partial "NOT loaded"
}

# ---------------------------------------------------------------------------
# 4. no launchctl on PATH (Linux/CI) → INFO skip
#    macOS keeps launchctl in /bin, so build a PATH whose /bin stand-in omits it
#    (symlinks to every other /bin entry) — hermetic on both platforms.
# ---------------------------------------------------------------------------
@test "no launchctl on PATH: INFO skip, never WARN" {
  _plant_plist com.cast.alpha

  local nolc="${BATS_TEST_TMPDIR}/no-launchctl-bin" f
  mkdir -p "$nolc"
  for f in /bin/*; do
    [ "$(basename "$f")" = "launchctl" ] && continue
    ln -s "$f" "${nolc}/$(basename "$f")"
  done
  local safe_path="${nolc}:/usr/bin:/usr/sbin:/sbin"
  # Guard the premise: the constructed PATH really has no launchctl.
  run env PATH="$safe_path" bash -c 'command -v launchctl'
  assert_failure

  run env PATH="$safe_path" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
  assert_output --partial "[--] launchd: check skipped (launchctl not available)"
  refute_output --partial "launchd: 0/"
  refute_output --partial "NOT loaded"
}

# ---------------------------------------------------------------------------
# 5. launchctl present, no com.cast.* plists → INFO (not a vacuous "0/0 ok")
# ---------------------------------------------------------------------------
@test "no com.cast.* plists: INFO, no ok claim" {
  _plant_plist com.other.unrelated
  _install_fake_launchctl "print+list"

  _run_doctor
  assert_output --partial "[--] launchd: no com.cast.* LaunchAgent plists installed"
  refute_output --partial "[ok] launchd:"
  refute_output --partial "NOT loaded"
}

# ---------------------------------------------------------------------------
# 6. the plist's Label key wins over its filename
#    (needs plutil — macOS; elsewhere the filename fallback is what runs)
# ---------------------------------------------------------------------------
@test "plist Label key is preferred over the filename" {
  command -v plutil >/dev/null 2>&1 || skip "plutil not available (non-macOS)"

  _plant_plist com.cast.filename-stem com.cast.label-key
  # Only the Label-key name is loaded: filename-derived lookup would WARN.
  _install_fake_launchctl "print+list" com.cast.label-key

  _run_doctor
  assert_output --partial "[ok] launchd: 1/1 com.cast.* jobs loaded"
  refute_output --partial "NOT loaded"
}
