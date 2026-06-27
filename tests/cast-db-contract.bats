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

# ── Test 3: ratchet flags a NEW contradiction absent from the baseline ───────

@test "ratchet flags a new contradiction absent from the baseline (exit-1 path)" {
  # The live schema is clean (S1–S6 drove violations to 0), so the subprocess
  # --check cannot reach the exit-1 path naturally without deliberately corrupting
  # the repo schema. Instead, drive the ratchet comparison directly with a SYNTHETIC
  # contradiction: check_against_baseline() must report it as a NEW violation (the
  # condition on which the caller exits 1). Deterministic and schema-independent.
  local EMPTY_BASELINE="$BATS_TEST_TMPDIR/empty-baseline.json"
  printf '{"schema_version":"1.0","contradictions":[],"safe_drop_candidates":[]}\n' \
    > "$EMPTY_BASELINE"

  run python3 - "$CONTRACT_SCRIPT" "$EMPTY_BASELINE" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("cdc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["cdc"] = m
spec.loader.exec_module(m)
# declared_in_init=True + migration_dropped=True → classification == "CONTRADICTION"
# (highest-priority rule in cast-db-contract.py's classification property).
c = m.ColumnContract(
    table="synthetic_t", column="synthetic_c",
    declared_in_init=True, migration_added=False, migration_dropped=True,
)
assert c.classification == "CONTRADICTION", f"setup error: {c.classification}"
empty = Path(sys.argv[2])
# Empty baseline → the synthetic contradiction is NEW → exit-1 condition holds.
new_contras, new_drops, _ = m.check_against_baseline([c], empty, desktop_found=False)
assert len(new_contras) == 1, f"expected 1 new contradiction, got {new_contras}"
# Symmetric: when the SAME contradiction is already baselined, it is NOT re-flagged.
seeded = empty.parent / "seeded.json"
seeded.write_text('{"schema_version":"1.0","contradictions":[{"table":"synthetic_t","column":"synthetic_c"}],"safe_drop_candidates":[]}')
new2, _, _ = m.check_against_baseline([c], seeded, desktop_found=False)
assert len(new2) == 0, f"baselined contradiction must not re-flag, got {new2}"
print("RATCHET_OK")
PY
  assert_success
  assert_output --partial RATCHET_OK
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
