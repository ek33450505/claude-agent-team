#!/usr/bin/env bats
# cast-plugin-smoke.bats — Fresh-machine plugin bootstrap smoke tests.
#
# Validates the plugin's clean-machine bootstrap path (CAST v8.0.0 release gate).
# Every test runs under an isolated temp HOME; real ~/.claude is never touched.
#
# Coverage:
#   1. Empty temp HOME → bootstrap exits 0 + all runtime dirs created
#   2. After bootstrap, ~/.claude/scripts/ contains symlinks into plugin/scripts/
#   3. cast.db initialized (PRAGMA user_version > 0)
#   4. Plugin curates exactly 17 agents; push + morning-briefing excluded
#   5. claude plugin validate --strict (skipped if claude CLI absent)
#   6. Idempotency: second bootstrap is a no-op (exits 0, DB version unchanged)
#   7. cast-hook-owner sentinel: hooks.json defer-guard references the sentinel file

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BOOTSTRAP_SH="$REPO_DIR/scripts/cast-plugin-bootstrap.sh"
PLUGIN_DIR="$REPO_DIR/plugin"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home

  # PATH-shim GUI side-effect surfaces (belt-and-suspenders; bootstrap itself is
  # clean, but cast-db-init.sh or future scripts may gain notification calls).
  _SHIM_DIR="$(mktemp -d)"
  for _cmd in osascript notify-send terminal-notifier open; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_SHIM_DIR/$_cmd"
    chmod +x "$_SHIM_DIR/$_cmd"
  done
  export PATH="$_SHIM_DIR:$PATH"

  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
}

teardown() {
  teardown_temp_home
  # Clean up shim dir (it is under system /tmp, not HOME, so safe to rm directly)
  [[ -n "${_SHIM_DIR:-}" && "$_SHIM_DIR" == /tmp/* || "$_SHIM_DIR" == /private/tmp/* || "$_SHIM_DIR" == /var/folders/* || "$_SHIM_DIR" == /private/var/folders/* ]] \
    && rm -rf "$_SHIM_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Empty temp HOME: bootstrap exits 0 + runtime dirs created
# ---------------------------------------------------------------------------

@test "bootstrap exits 0 on a fresh empty HOME" {
  run bash "$BOOTSTRAP_SH"
  assert_success
}

@test "bootstrap creates required runtime dirs under \$HOME/.claude" {
  bash "$BOOTSTRAP_SH"

  local expected_dirs=(
    "$HOME/.claude/scripts"
    "$HOME/.claude/logs"
    "$HOME/.claude/agent-status"
    "$HOME/.claude/cast/events"
    "$HOME/.claude/plans"
    "$HOME/.claude/briefings"
    "$HOME/.claude/reports"
    "$HOME/.claude/cast/state"
    "$HOME/.claude/cast/offline-queue"
    "$HOME/.claude/cast/reviews"
    "$HOME/.claude/cast/artifacts"
    "$HOME/.claude/config"
    "$HOME/.claude/backups"
    "$HOME/.claude/agent-memory-local"
  )

  for dir in "${expected_dirs[@]}"; do
    [[ -d "$dir" ]] || {
      echo "MISSING runtime dir: $dir" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# 2. scripts/ contains symlinks pointing into plugin/scripts/
# ---------------------------------------------------------------------------

@test "after bootstrap, \$HOME/.claude/scripts/ contains symlinks into plugin/scripts/" {
  bash "$BOOTSTRAP_SH"

  local scripts_dir="$HOME/.claude/scripts"
  local plugin_scripts="$PLUGIN_DIR/scripts"

  # There must be at least one symlink
  local symlink_count=0
  local f
  for f in "$scripts_dir/"*; do
    [[ -L "$f" ]] || continue
    local target
    target="$(readlink "$f" 2>/dev/null || true)"
    if [[ "$target" == "$plugin_scripts/"* ]]; then
      symlink_count=$((symlink_count + 1))
    fi
  done

  [[ "$symlink_count" -gt 0 ]] || {
    echo "No symlinks from $scripts_dir pointing into $plugin_scripts" >&2
    return 1
  }
}

@test "symlinks in \$HOME/.claude/scripts/ are not broken after bootstrap" {
  bash "$BOOTSTRAP_SH"

  local broken=0
  local f
  for f in "$HOME/.claude/scripts/"*; do
    [[ -L "$f" ]] || continue
    if [[ ! -e "$f" ]]; then
      echo "Broken symlink: $f -> $(readlink "$f" 2>/dev/null || echo '?')" >&2
      broken=$((broken + 1))
    fi
  done

  [[ "$broken" -eq 0 ]] || return 1
}

# ---------------------------------------------------------------------------
# 3. cast.db initialized (PRAGMA user_version > 0)
# ---------------------------------------------------------------------------

@test "cast.db exists after bootstrap" {
  bash "$BOOTSTRAP_SH"
  [[ -f "$HOME/.claude/cast.db" ]]
}

@test "cast.db PRAGMA user_version is greater than 0 after bootstrap" {
  bash "$BOOTSTRAP_SH"

  local ver
  ver="$(sqlite3 "$HOME/.claude/cast.db" "PRAGMA user_version;" 2>/dev/null || echo 0)"
  ver="${ver// /}"  # strip whitespace

  [[ -n "$ver" && "$ver" -gt 0 ]] || {
    echo "PRAGMA user_version = '$ver' (expected > 0)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 4. Plugin curates exactly 17 agents; push + morning-briefing excluded
# ---------------------------------------------------------------------------

@test "plugin/agents/ contains exactly 17 agent files" {
  local count
  count="$(find "$PLUGIN_DIR/agents" -maxdepth 1 -name '*.md' | wc -l)"
  count="${count// /}"  # strip whitespace from wc -l output (macOS pads)

  [[ "$count" -eq 17 ]] || {
    echo "Expected 17 agents in plugin/agents/, got $count" >&2
    find "$PLUGIN_DIR/agents" -maxdepth 1 -name '*.md' >&2
    return 1
  }
}

@test "push.md and morning-briefing.md are NOT in plugin/agents/ (excluded agents)" {
  [[ ! -f "$PLUGIN_DIR/agents/push.md" ]] || {
    echo "push.md should not be present in plugin/agents/" >&2
    return 1
  }
  [[ ! -f "$PLUGIN_DIR/agents/morning-briefing.md" ]] || {
    echo "morning-briefing.md should not be present in plugin/agents/" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 5. claude plugin validate --strict (skipped if CLI absent)
# ---------------------------------------------------------------------------

@test "claude plugin validate --strict passes against committed plugin/" {
  if ! command -v claude >/dev/null 2>&1; then
    skip "claude CLI not available in this environment"
  fi
  run claude plugin validate "$PLUGIN_DIR" --strict
  assert_success
}

# ---------------------------------------------------------------------------
# 6. Idempotency: second bootstrap is a no-op
# ---------------------------------------------------------------------------

@test "second bootstrap run exits 0 (idempotent)" {
  bash "$BOOTSTRAP_SH"
  run bash "$BOOTSTRAP_SH"
  assert_success
}

@test "second bootstrap does not re-initialize cast.db (PRAGMA user_version unchanged)" {
  bash "$BOOTSTRAP_SH"

  local ver1
  ver1="$(sqlite3 "$HOME/.claude/cast.db" "PRAGMA user_version;" 2>/dev/null || echo 0)"
  ver1="${ver1// /}"

  # Run bootstrap again
  bash "$BOOTSTRAP_SH"

  local ver2
  ver2="$(sqlite3 "$HOME/.claude/cast.db" "PRAGMA user_version;" 2>/dev/null || echo 0)"
  ver2="${ver2// /}"

  [[ "$ver1" == "$ver2" ]] || {
    echo "user_version changed from $ver1 to $ver2 on second bootstrap" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 7. cast-hook-owner sentinel: hooks.json defer-guard pattern
# ---------------------------------------------------------------------------

@test "plugin hooks.json references the cast-hook-owner sentinel as a defer-guard" {
  local hooks_json="$PLUGIN_DIR/hooks/hooks.json"

  [[ -f "$hooks_json" ]] || {
    echo "hooks.json not found at $hooks_json" >&2
    return 1
  }

  # Every hook command should check for the sentinel file before running
  grep -q 'cast-hook-owner' "$hooks_json" || {
    echo "cast-hook-owner sentinel not found in $hooks_json" >&2
    return 1
  }
}
