# Shared setup for all install tests
# Uses a temp dir instead of $HOME to avoid polluting real ~/.claude

setup_temp_home() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  # Sentinel: teardown_temp_home will refuse to delete any HOME that lacks this marker
  touch "$HOME/.cast-test-home"
  export TEST_INSTALL_DIR="$HOME/.claude"
}

teardown_temp_home() {
  local target="$HOME"

  # Guard (a): sentinel marker must exist
  if [[ ! -f "$target/.cast-test-home" ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — not a verified test fixture (missing .cast-test-home)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi

  # Guard (b): path must begin with a known temp prefix
  local is_tmp=0
  case "$target" in
    /tmp/*)                  is_tmp=1 ;;
    /private/tmp/*)          is_tmp=1 ;;
    /var/folders/*)          is_tmp=1 ;;
    /private/var/folders/*)  is_tmp=1 ;;
  esac
  if [[ "$is_tmp" -eq 0 ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — not a verified test fixture (not under /tmp, /private/tmp, or /var/folders)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi

  # Guard (c): must not equal the invoking user's real home
  local real_home="${ORIG_HOME:-}"
  # Fallback: reject anything that looks like /Users/<name> without a temp suffix
  if [[ -n "$real_home" && "$target" = "$real_home" ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — matches ORIG_HOME (real user home)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi
  if [[ -z "$real_home" ]]; then
    case "$target" in
      /Users/*)
        echo "FATAL [teardown_temp_home]: refusing to delete '$target' — looks like a real home directory (ORIG_HOME unset)" >&2
        export HOME="$ORIG_HOME"
        return 1
        ;;
    esac
  fi

  # Defensive: evict any com.cast.* launchd jobs registered FROM this temp HOME
  # before deleting it. launchd is a per-user (gui/$uid) domain that $HOME cannot
  # isolate, so a leaked job would outlive this dir and hijack the real daemon's
  # label. CRITICAL: only boot out a label whose CURRENTLY-LOADED job path is under
  # $target — NEVER the real daemon (whose plist lives in the real ~/Library).
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local _uid; _uid="$(id -u)"
    local _plist _label _loaded
    for _plist in "$target"/Library/LaunchAgents/com.cast.*.plist; do
      [[ -e "$_plist" ]] || continue
      _label="$(basename "$_plist" .plist)"
      _loaded="$(launchctl print "gui/$_uid/$_label" 2>/dev/null | awk -F' = ' '/^\tpath = /{print $2; exit}')"
      if [[ -n "$_loaded" && "$_loaded" == "$target/"* ]]; then
        launchctl bootout "gui/$_uid/$_label" 2>/dev/null || true
      fi
    done
  fi

  rm -rf "$target"
  export HOME="$ORIG_HOME"
}

# Seed everything scripts/cast-db-rollup.py needs to exit 0 against a fixture
# DB: the two rollup-summary tables (agent_runs_daily, mcp_calls_daily) it
# checks for up front, AND minimal agent_runs / routing_events source tables
# it unconditionally SELECTs FROM. scripts/cast-db-prune.py runs the rollup
# as a fail-closed gate before any DELETE: if the rollup exits non-zero,
# prune skips ALL delete steps by design.
#
# VERIFIED (2026-08-19): the rollup's _REQUIRED_TABLES check only names the
# two daily tables, but Step A/B run `FROM agent_runs` / `FROM routing_events`
# unconditionally — a fixture missing either source table fails with
# "no such table: agent_runs" even when both daily tables exist. So this
# helper seeds all four, using CREATE TABLE IF NOT EXISTS for every one —
# a caller that already defines its own richer agent_runs/routing_events
# (e.g. cast-db-prune.bats) is left untouched; a caller with neither
# (e.g. the otel fixture) gets empty-but-schema-complete tables, which is
# sufficient for the rollup to run over zero rows and exit 0.
#
# Idempotent — safe to call after other schema setup, and safe to call more
# than once against the same DB.
#
# Usage: seed_rollup_tables "$TEST_DB"
seed_rollup_tables() {
  local db_path="$1"
  sqlite3 "$db_path" "
    CREATE TABLE IF NOT EXISTS agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT,
      started_at TEXT,
      model TEXT,
      status TEXT,
      response TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_input_tokens INTEGER,
      cache_creation_input_tokens INTEGER,
      cost_usd REAL,
      duration_ms INTEGER,
      tool_uses INTEGER
    );
    CREATE TABLE IF NOT EXISTS routing_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT,
      event_type TEXT,
      data TEXT
    );
    CREATE TABLE IF NOT EXISTS agent_runs_daily (
      day TEXT NOT NULL,
      agent TEXT NOT NULL DEFAULT '',
      model TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT '',
      runs INTEGER NOT NULL DEFAULT 0,
      with_response INTEGER NOT NULL DEFAULT 0,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
      cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL NOT NULL DEFAULT 0,
      duration_ms INTEGER NOT NULL DEFAULT 0,
      tool_uses INTEGER NOT NULL DEFAULT 0,
      rolled_up_at TEXT NOT NULL,
      PRIMARY KEY (day, agent, model, status)
    );
    CREATE TABLE IF NOT EXISTS mcp_calls_daily (
      day TEXT NOT NULL,
      mcp_server TEXT NOT NULL DEFAULT '',
      mcp_tool TEXT NOT NULL DEFAULT '',
      outcome TEXT NOT NULL DEFAULT '',
      is_cloud_bound INTEGER NOT NULL DEFAULT 0,
      calls INTEGER NOT NULL DEFAULT 0,
      result_bytes INTEGER NOT NULL DEFAULT 0,
      rolled_up_at TEXT NOT NULL,
      PRIMARY KEY (day, mcp_server, mcp_tool, outcome, is_cloud_bound)
    );
  "
}
