#!/usr/bin/env bats
# tests/cast-db-contract.bats — tests for scripts/cast-db-contract.py
#
# Coverage:
#   - --json emits valid JSON (stderr suppressed; WARN/INFO are expected when
#     cast-desktop or cast.db is absent)
#   - --check exits 0 when baseline matches current scan state (fresh baseline,
#     environment-agnostic: works with or without desktop/DB)
#   - ratchet exits 1 when baseline does not contain known violations
#   - tool is read-only: DB file size unchanged after --db run
#
# Isolated temp HOME: the script derives DEFAULT_DESKTOP_PATH and DEFAULT_DB
# from Path.home(). Temp HOME prevents accidental reads of the real cast.db
# and the real desktop, keeping tests deterministic across environments.
# No tests write to $HOME (only to BATS_TEST_TMPDIR).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONTRACT_SCRIPT="$REPO_DIR/scripts/cast-db-contract.py"

setup() {
  load 'helpers/setup'
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

# ── Test 1: --json emits valid JSON ─────────────────────────────────────────

@test "--json emits valid JSON" {
  # stderr suppressed: WARN/INFO about missing desktop or DB are expected and
  # normal; they must not contaminate stdout (which is checked for JSON validity).
  run bash -c "python3 '$CONTRACT_SCRIPT' --json 2>/dev/null"
  [ "$status" -eq 0 ]

  # Validate that stdout is parseable JSON
  echo "$output" | python3 -m json.tool >/dev/null
  [ $? -eq 0 ]
}

# ── Test 2: --check exits 0 when baseline matches current scan ───────────────

@test "--check exits 0 when baseline matches current scan state" {
  # Generate a fresh baseline from the exact current scan state (temp HOME,
  # no desktop, no DB — environment-agnostic). Then immediately check against
  # that same baseline: no new violations can appear → exit 0.
  local TEMP_BASELINE="$BATS_TEST_TMPDIR/fresh-baseline.json"

  # Suppress stdout/stderr from the baseline-generation step;
  # --update-baseline MUST succeed — failure here is a contract-script regression,
  # not an environment gap. Hard-fail so the regression is visible.
  if ! python3 "$CONTRACT_SCRIPT" \
      --update-baseline --baseline "$TEMP_BASELINE" \
      >/dev/null 2>&1; then
    echo "FAIL: cast-db-contract.py --update-baseline exited non-zero; this is a contract-script regression" >&2
    false
  fi

  run python3 "$CONTRACT_SCRIPT" --check --baseline "$TEMP_BASELINE"
  [ "$status" -eq 0 ]
}

# ── Test 3: ratchet exits 1 when baseline is missing known violations ────────

@test "ratchet exits 1 when baseline does not contain known violations" {
  # An empty baseline treats all violations found by the scan as "new".
  # Even without the desktop (UNCHECKED mode), contradictions and
  # safe-drop-candidates are found → exit 1.
  local EMPTY_BASELINE="$BATS_TEST_TMPDIR/empty-baseline.json"
  printf '{"schema_version":"1.0","contradictions":[],"safe_drop_candidates":[]}\n' \
    > "$EMPTY_BASELINE"

  run python3 "$CONTRACT_SCRIPT" --check --baseline "$EMPTY_BASELINE"
  [ "$status" -eq 1 ]
}

# ── Test 4: desktop-absent --check exits 0 (safe-drop ratchet skipped) ──────
#
# Verifies the honest-degradation ratchet: when cast-desktop is unreachable,
# DESKTOP-COUPLED columns degrade to SAFE-DROP-CANDIDATE. Those degraded entries
# must NOT trigger a new-violation failure. Only contradictions are checked.
#
# Approach:
#   1. Generate a baseline with desktop ABSENT (captures only contradictions
#      and the degraded safe-drop-candidates from that no-desktop view).
#   2. Immediately --check against that same baseline with desktop still absent.
#      Result must be exit 0 — no new violations.
#   3. Confirm stderr states the mode ("contradictions-only … safe-drop ratchet skipped").

@test "--check exits 0 with desktop absent (safe-drop ratchet skipped)" {
  local TEMP_BASELINE="$BATS_TEST_TMPDIR/no-desktop-baseline.json"

  # Step 1: generate baseline in no-desktop mode.
  # --update-baseline MUST succeed — failure here is a contract-script regression,
  # not an environment gap. Hard-fail so the regression is visible.
  if ! python3 "$CONTRACT_SCRIPT" \
      --update-baseline \
      --baseline "$TEMP_BASELINE" \
      --desktop-path /tmp/nonexistent \
      >/dev/null 2>&1; then
    echo "FAIL: cast-db-contract.py --update-baseline (no-desktop mode) exited non-zero; this is a contract-script regression" >&2
    false
  fi

  # Step 2: --check must pass (exit 0) with desktop still absent
  run python3 "$CONTRACT_SCRIPT" \
    --check \
    --baseline "$TEMP_BASELINE" \
    --desktop-path /tmp/nonexistent

  # Step 3: exit code must be 0
  [ "$status" -eq 0 ]

  # Step 4: stderr must state the degraded mode — not silently skip
  [[ "$output" == *"safe-drop ratchet skipped"* ]]
}

# ── Test 5: tool is read-only ────────────────────────────────────────────────

@test "tool is read-only: DB file size unchanged after --db run" {
  local TEMP_DB="$BATS_TEST_TMPDIR/test-readonly.db"

  # Create a minimal SQLite DB
  sqlite3 "$TEMP_DB" "CREATE TABLE test_sentinel (id INTEGER PRIMARY KEY);"

  # Record byte size before run (wc -c redirected form; tr strips macOS whitespace)
  local before_size
  before_size="$(wc -c < "$TEMP_DB" | tr -d ' ')"

  # Run the tool against this DB; the script uses mode=ro URI internally.
  # Exit status may be non-zero (ratchet check); we only care about file size.
  run python3 "$CONTRACT_SCRIPT" --db "$TEMP_DB"

  local after_size
  after_size="$(wc -c < "$TEMP_DB" | tr -d ' ')"

  [ "$before_size" -eq "$after_size" ]
}
