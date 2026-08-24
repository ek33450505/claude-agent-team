#!/usr/bin/env bats
# cast_tidy_backup_gate.bats — Fail-closed backup gate for `cast tidy`'s
# cast.db agent_runs prune step (J-16).
#
# `cast tidy` deletes agent_runs rows older than 30 days with no backup and
# no gate, and runs UNATTENDED nightly via launchd (com.cast.tidy /
# cast-cron-setup.sh). The fix mirrors cast-db-prune.py's fail-closed backup
# gate: before the DELETE, cast-db-backup.py is invoked; if it is missing or
# exits non-zero, the DELETE is skipped and `cast tidy` still exits 0
# (preserving the launchd contract) so the rest of tidy still runs.
#
# Coverage:
#   (a) backup succeeds  -> old agent_runs rows ARE pruned
#   (b) backup fails     -> rows SURVIVE, `cast tidy` still exits 0 (the
#       assertion that matters: with the bug reverted — an unguarded DELETE
#       — this test fails because the row is deleted regardless of the
#       backup's exit code)
#   (c) --dry-run         -> deletes nothing AND does not invoke the backup
#       script at all

setup() {
  load 'helpers/setup'
  setup_temp_home

  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CAST_BIN="$REPO_DIR/bin/cast"

  mkdir -p "${HOME}/.claude"
  DB_PATH="${HOME}/.claude/cast.db"
  export CAST_DB_PATH="$DB_PATH"

  # Minimal agent_runs table with one row older than the 30-day prune window.
  sqlite3 "$DB_PATH" "CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, agent_type TEXT, started_at TEXT);"
  sqlite3 "$DB_PATH" "INSERT INTO agent_runs (agent_type, started_at) VALUES ('code-reviewer', datetime('now', '-45 days'));"

  # Fixture scripts dir — bin/cast resolves cast-db-backup.py via
  # CAST_SCRIPTS_DIR (already defaults to \${HOME}/.claude/scripts under the
  # isolated temp HOME, but export it explicitly so the stub path is obvious).
  export CAST_SCRIPTS_DIR="${HOME}/.claude/scripts"
  mkdir -p "$CAST_SCRIPTS_DIR"

  # Marker the backup stub touches, to prove/disprove invocation for --dry-run.
  BACKUP_MARKER="${HOME}/.backup-invoked"
}

teardown() {
  teardown_temp_home
}

_row_count() {
  sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM agent_runs;"
}

@test "cast tidy: successful backup allows the prune to delete old rows" {
  cat > "${CAST_SCRIPTS_DIR}/cast-db-backup.py" <<'PYEOF'
#!/usr/bin/env python3
import sys
print('{"backup_path": "/fake/backup.db"}')
sys.exit(0)
PYEOF
  chmod +x "${CAST_SCRIPTS_DIR}/cast-db-backup.py"

  [ "$(_row_count)" -eq 1 ]

  run bash "$CAST_BIN" tidy
  [ "$status" -eq 0 ]
  [ "$(_row_count)" -eq 0 ]
}

@test "cast tidy: failed backup skips the prune, rows survive, tidy still exits 0" {
  cat > "${CAST_SCRIPTS_DIR}/cast-db-backup.py" <<'PYEOF'
#!/usr/bin/env python3
import sys
sys.exit(1)
PYEOF
  chmod +x "${CAST_SCRIPTS_DIR}/cast-db-backup.py"

  [ "$(_row_count)" -eq 1 ]

  run bash "$CAST_BIN" tidy
  [ "$status" -eq 0 ]
  # The assertion that matters: the row must survive a failed backup.
  [ "$(_row_count)" -eq 1 ]
}

@test "cast tidy: missing backup script (both resolution paths) skips the prune, rows survive" {
  # No cast-db-backup.py written in CAST_SCRIPTS_DIR, AND CAST_REPO_DIR points
  # at an empty temp dir with no scripts/ subdir — bin/cast's own fallback
  # (CAST_SCRIPTS_DIR, then CAST_REPO_DIR/scripts) otherwise finds the real
  # repo's cast-db-backup.py when running from a checkout, so both paths must
  # be closed off to genuinely exercise the "script not found" branch.
  export CAST_REPO_DIR="$(mktemp -d)"
  [ "$(_row_count)" -eq 1 ]

  run bash "$CAST_BIN" tidy
  [ "$status" -eq 0 ]
  [ "$(_row_count)" -eq 1 ]
}

@test "cast tidy: --dry-run deletes nothing and does not invoke the backup script" {
  cat > "${CAST_SCRIPTS_DIR}/cast-db-backup.py" <<PYEOF
#!/usr/bin/env python3
import sys
open("$BACKUP_MARKER", "w").close()
sys.exit(0)
PYEOF
  chmod +x "${CAST_SCRIPTS_DIR}/cast-db-backup.py"

  run bash "$CAST_BIN" tidy --dry-run
  [ "$status" -eq 0 ]
  [ "$(_row_count)" -eq 1 ]
  [ ! -f "$BACKUP_MARKER" ]
}

@test "cast tidy: --dry-run reports the would-be prune count in its summary, not 0" {
  # Regression coverage: db_pruned must be set in the dry-run branch too —
  # every OTHER tidy counter increments in BOTH branches (e.g.
  # plans_archived, status_deleted both sit after the if/else), so dry-run's
  # summary table is a PREVIEW of would-be counts, not just real-run counts.
  # A real run still only counts rows when the backup succeeds and the
  # DELETE actually runs (0 on backup failure) — only dry-run must always
  # preview the would-be count.
  run bash "$CAST_BIN" tidy --dry-run
  [ "$status" -eq 0 ]
  [ "$(_row_count)" -eq 1 ]

  local summary_line
  summary_line="$(printf '%s\n' "$output" | grep "DB agent_runs (>30 days)")"
  [[ "$summary_line" =~ 1$ ]]
}

@test "cast tidy: a hung backup does not hang tidy, does not delete rows, and tidy still exits 0" {
  # Stub sleeps well past the (overridable) timeout bound. A passing run
  # while the bug is present (no timeout wrapper — i.e. a bare
  # `python3 "$backup_script"` with nothing bounding it) waits out the
  # stub's full 10s sleep, the stub then exits 0, so the backup "succeeds"
  # late and the DELETE runs anyway — the row-survives assertion below
  # fails, and elapsed time is >= the sleep duration rather than bounded by
  # the timeout override.
  cat > "${CAST_SCRIPTS_DIR}/cast-db-backup.py" <<'PYEOF'
#!/usr/bin/env python3
import time
time.sleep(10)
PYEOF
  chmod +x "${CAST_SCRIPTS_DIR}/cast-db-backup.py"

  [ "$(_row_count)" -eq 1 ]

  local start_ts end_ts elapsed
  start_ts="$(date +%s)"
  # 1s override so the suite never waits anywhere near the real 120s
  # default or the stub's 10s sleep.
  run env CAST_TIDY_BACKUP_TIMEOUT=1 bash "$CAST_BIN" tidy
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))

  [ "$status" -eq 0 ]
  [ "$(_row_count)" -eq 1 ]
  # Well under the 10s sleep, proving the run was actually bounded rather
  # than happening to finish quickly for an unrelated reason.
  [ "$elapsed" -lt 8 ]
}
