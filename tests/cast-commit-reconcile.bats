#!/usr/bin/env bats
# tests/cast-commit-reconcile.bats — reconciler unit tests (D5 part 2)
#
# Isolation: every test uses a temp HOME via setup_temp_home.
# DB provisioned via: env CAST_DB_PATH=... bash scripts/cast-db-init.sh
# Audit fixtures written with printf (NOT heredocs, per BATS authoring gotchas).
# All event timestamps are anchored against an explicit checkpoint to avoid
# the 30-day default-lookback sensitivity to the current date.

bats_require_minimum_version 1.5.0
load helpers/setup

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/cast-commit-reconcile.py"
DB_INIT="$REPO_ROOT/scripts/cast-db-init.sh"
PRE_PUSH_HOOK="$REPO_ROOT/.githooks/pre-push"

# Fixed time anchors — all tests use checkpoint=T0, events at T0+1h
# This avoids the 30-day default-lookback sensitivity.
T0="2026-01-01T11:00:00"   # checkpoint set before events
T1="2026-01-01T12:00:00"   # event timestamp (1h after checkpoint)
PROV_MATCH="2026-01-01T12:02:00"  # provenance within window (2 min after event)
PROV_OUTSIDE="2026-01-01T13:00:00"  # provenance OUTSIDE 15-min window

setup() {
    setup_temp_home
    AUDIT_FILE="$HOME/audit.jsonl"
    CAST_DB="$HOME/cast.db"
    CHECKPOINT="$HOME/run/commit-reconcile-checkpoint"
    # Provision DB with real schema
    env CAST_DB_PATH="$CAST_DB" bash "$DB_INIT" >/dev/null 2>&1
    # Set checkpoint so T1 events pass through the filter
    mkdir -p "$(dirname "$CHECKPOINT")"
    printf '%s' "$T0" > "$CHECKPOINT"
}

teardown() {
    teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: write a COMMIT_HATCH_USED event to the audit file
# Use printf (NOT heredoc) — BATS heredoc @test lines get rewritten.
# Optional 4th arg: repo path. When provided, the event carries a "repo" field;
# when omitted, the event has no repo field (legacy format).
# ---------------------------------------------------------------------------
write_hatch_event() {
    local ts="$1" session_id="$2" in_claude_session="$3" repo="${4:-}"
    if [ -n "$repo" ]; then
        printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"%s","in_claude_session":%s,"repo":"%s"}\n' \
            "$ts" "$session_id" "$in_claude_session" "$repo" >> "$AUDIT_FILE"
    else
        printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"%s","in_claude_session":%s}\n' \
            "$ts" "$session_id" "$in_claude_session" >> "$AUDIT_FILE"
    fi
}

# Helper: insert a commit_provenance row using Python parameterized query.
# Uses sys.argv to pass values — no SQL interpolation, mirrors cast_db.py pattern.
# Optional 3rd arg: repo. When omitted (or empty), row carries repo='' (legacy).
insert_provenance() {
    local recorded_at="$1" sha="${2:-abc123}" repo="${3:-}"
    python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute('INSERT INTO commit_provenance (sha, recorded_at, repo) VALUES (?, ?, ?)',
             (sys.argv[2], sys.argv[3], sys.argv[4]))
conn.commit()
conn.close()
" "$CAST_DB" "$sha" "$recorded_at" "$repo"
}

# ---------------------------------------------------------------------------
# T1: No audit file → status=skip, exit 0
# ---------------------------------------------------------------------------
@test "clean: no audit file → skip exit 0" {
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "skip" ]
}

# ---------------------------------------------------------------------------
# T2: in-session event + matching provenance within window → clean, exit 0
# ---------------------------------------------------------------------------
@test "clean: in-session event with provenance in window → exit 0" {
    write_hatch_event "$T1" "sess-001" "true"
    insert_provenance "$PROV_MATCH"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
}

# ---------------------------------------------------------------------------
# T3: in-session event WITHOUT provenance → violation, exit 1, violation JSON names session
# ---------------------------------------------------------------------------
@test "violation: in-session event without provenance → exit 1 with session_id" {
    write_hatch_event "$T1" "sess-bad" "true"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "violations" ]
    # violation list must name the offending session
    echo "$output" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); assert any(v["session_id"]=="sess-bad" for v in d["violations"]), d'
}

# ---------------------------------------------------------------------------
# T4: Legacy event (no in_claude_session field) → grandfathered, exit 0
# ---------------------------------------------------------------------------
@test "grandfather: event missing in_claude_session field → ignored, exit 0" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"sess-legacy"}\n' \
        "$T1" >> "$AUDIT_FILE"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
}

# ---------------------------------------------------------------------------
# T5: in_claude_session==false → not suspicious, exit 0
# ---------------------------------------------------------------------------
@test "false field: in_claude_session==false → ignored, exit 0" {
    write_hatch_event "$T1" "sess-external" "false"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
}

# ---------------------------------------------------------------------------
# T6: CAST_RECONCILE_ACK=1 → exit 0, status=acked, RECONCILE_ACK_USED appended
# ---------------------------------------------------------------------------
@test "ack: CAST_RECONCILE_ACK=1 with violation → exit 0, acked, ack event appended" {
    write_hatch_event "$T1" "sess-acked" "true"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_ACK=1 \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "acked" ]
    # RECONCILE_ACK_USED event must be appended to audit file
    grep -q "RECONCILE_ACK_USED" "$AUDIT_FILE"
}

# ---------------------------------------------------------------------------
# T7: Garbage / non-JSON line in audit → skipped silently, exit 0
# ---------------------------------------------------------------------------
@test "garbage line: non-JSON in audit → skipped silently, exit 0" {
    printf 'THIS IS NOT JSON\n' >> "$AUDIT_FILE"
    # Also add a harmless non-suspicious event so the file is non-trivial
    write_hatch_event "$T1" "sess-ok" "false"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T8: Checkpoint honored — event older than checkpoint → ignored
# ---------------------------------------------------------------------------
@test "checkpoint: event older than checkpoint → not evaluated (checked=0)" {
    # Write a violation-candidate event older than the checkpoint (T0)
    write_hatch_event "2026-01-01T10:00:00" "sess-old" "true"
    # Checkpoint at T0=11:00 is already set in setup(); event at 10:00 is before it
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    # status=clean because 0 events were checked
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
    checked="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["checked"])')"
    [ "$checked" = "0" ]
}

# ---------------------------------------------------------------------------
# T9: Wiring assertion — pre-push hook contains reconcile invocation
# ---------------------------------------------------------------------------
@test "wiring: pre-push hook invokes cast-commit-reconcile.py" {
    grep -q "cast-commit-reconcile.py" "$PRE_PUSH_HOOK"
}

# ---------------------------------------------------------------------------
# T10 (M1): RECONCILE_ACK_USED carries top-level in_claude_session field.
#           Run with CLAUDECODE unset (env -u) → expect false.
# ---------------------------------------------------------------------------
@test "M1: RECONCILE_ACK_USED top-level in_claude_session==false when CLAUDECODE unset" {
    write_hatch_event "$T1" "sess-ack-field" "true"
    run --separate-stderr env -u CLAUDECODE \
           CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_ACK=1 \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    # Extract the RECONCILE_ACK_USED line and verify top-level in_claude_session
    python3 -c "
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if 'RECONCILE_ACK_USED' in l]
assert lines, 'no RECONCILE_ACK_USED event appended'
d = json.loads(lines[-1])
assert 'in_claude_session' in d, f'missing top-level in_claude_session: {d}'
assert d['in_claude_session'] == False, f'expected False (CLAUDECODE unset), got: {d[\"in_claude_session\"]}'
" "$AUDIT_FILE"
}

# ---------------------------------------------------------------------------
# T11 (M3): CHECKPOINT_ADVANCED event is appended after a clean run.
# ---------------------------------------------------------------------------
@test "M3: CHECKPOINT_ADVANCED event appended after clean run" {
    # Non-suspicious event (in_claude_session=false) → clean run → checkpoint advances
    write_hatch_event "$T1" "sess-chkpt" "false"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    grep -q "CHECKPOINT_ADVANCED" "$AUDIT_FILE"
}

# ---------------------------------------------------------------------------
# T12 (M2): Unreadable DB (chmod 000) → status=error, exit 1. Skip if root.
# ---------------------------------------------------------------------------
@test "M2: chmod-000 DB → status=error exit 1 (skip if root)" {
    if [ "$(id -u)" = "0" ]; then
        skip "chmod 000 has no effect as root"
    fi
    write_hatch_event "$T1" "sess-dberr" "true"
    chmod 000 "$CAST_DB"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    chmod 644 "$CAST_DB"  # restore so teardown_temp_home can clean up
    [ "$status" -eq 1 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "error" ]
}

# ===========================================================================
# Repo-scoping tests (D5 hardening — E1/E2/E3)
# These tests do NOT set CAST_RECONCILE_CHECKPOINT (T18/T19) or set it
# explicitly (T13-T17). Paths use $HOME subdirs so realpath is consistent
# across both sides of the comparison (avoids macOS /tmp symlink divergence).
# ===========================================================================

# ---------------------------------------------------------------------------
# R1: Foreign-repo event skipped — the Ed incident regression test.
#     Event carries repo=REPO_B; gate runs for REPO_A → event filtered → exit 0,
#     checked=0 (foreign-repo false-block cannot happen again).
# ---------------------------------------------------------------------------
@test "R1: foreign-repo event skipped (exit 0, checked=0)" {
    local REPO_A="$HOME/repo-a-r1"
    local REPO_B="$HOME/repo-b-r1"
    write_hatch_event "$T1" "sess-foreign" "true" "$REPO_B"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO_A" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    checked="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["checked"])')"
    [ "$checked" = "0" ]
}

# ---------------------------------------------------------------------------
# R2: Same-repo event without provenance → violation, exit 1, violation includes repo.
# ---------------------------------------------------------------------------
@test "R2: same-repo event without provenance → exit 1, violation contains repo" {
    local REPO="$HOME/repo-r2"
    write_hatch_event "$T1" "sess-noprov" "true" "$REPO"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "violations" ]
    # violation list must carry a non-empty repo field
    echo "$output" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); assert any(v.get("repo") for v in d["violations"]), d'
}

# ---------------------------------------------------------------------------
# R3: Cross-repo masking closed — provenance row for REPO_B does NOT satisfy
#     a REPO_A event (the pre-hardening fail-open hole is shut).
# ---------------------------------------------------------------------------
@test "R3: cross-repo masking closed — repo-B provenance does not satisfy repo-A event" {
    local REPO_A="$HOME/repo-a-r3"
    local REPO_B="$HOME/repo-b-r3"
    write_hatch_event "$T1" "sess-masking" "true" "$REPO_A"
    insert_provenance "$PROV_MATCH" "abc12300" "$REPO_B"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO_A" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "violations" ]
}

# ---------------------------------------------------------------------------
# R4: Provenance repo='' (record-time git failure) matches a scoped event →
#     exit 0 (documented fail-open leniency per the D5 compat table).
# ---------------------------------------------------------------------------
@test "R4: provenance repo='' (record-time git failure) matches scoped event → exit 0" {
    local REPO="$HOME/repo-r4"
    write_hatch_event "$T1" "sess-emptyprov" "true" "$REPO"
    insert_provenance "$PROV_MATCH" "abc12301" ""   # repo='' → legacy/degraded row
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
}

# ---------------------------------------------------------------------------
# R5a: Legacy event (no repo field) still evaluated under CAST_RECONCILE_REPO=<X>
#      and matched by unscoped provenance → exit 0 (fail-closed grandfather kept).
# ---------------------------------------------------------------------------
@test "R5a: legacy event (no repo) with matching provenance → exit 0 under CAST_RECONCILE_REPO" {
    local REPO="$HOME/repo-r5a"
    # write_hatch_event without 4th arg → event has no repo field (legacy)
    write_hatch_event "$T1" "sess-legacyclean" "true"
    insert_provenance "$PROV_MATCH" "abc12302"   # repo='' (unscoped)
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "clean" ]
}

# ---------------------------------------------------------------------------
# R5b: Legacy event (no repo field) without provenance → exit 1 under
#      CAST_RECONCILE_REPO=<X> (fail-closed — legacy events are NOT grandfathered
#      as foreign; they keep today's global evaluation).
# ---------------------------------------------------------------------------
@test "R5b: legacy event (no repo) without provenance → exit 1 under CAST_RECONCILE_REPO" {
    local REPO="$HOME/repo-r5b"
    write_hatch_event "$T1" "sess-legacyviol" "true"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$REPO" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    result="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result" = "violations" ]
}

# ---------------------------------------------------------------------------
# R6: Per-repo checkpoint isolation — a clean push in REPO_A (advancing REPO_A's
#     per-repo checkpoint) must NOT cause REPO_B's pending violation to be skipped.
#     Two-invocation test; CAST_RECONCILE_CHECKPOINT is intentionally UNSET so the
#     script derives its own per-repo checkpoint paths.
# ---------------------------------------------------------------------------
@test "R6: per-repo checkpoint isolation — REPO_A clean does not skip REPO_B pending event" {
    local REPO_A="$HOME/repo-a-isol"
    local REPO_B="$HOME/repo-b-isol"
    # Seed the legacy global checkpoint at T0 (no CAST_RECONCILE_CHECKPOINT env here).
    mkdir -p "$HOME/.claude/run"
    printf '%s' "$T0" > "$HOME/.claude/run/commit-reconcile-checkpoint"
    # Violation event for REPO_B at T1 (after T0).
    write_hatch_event "$T1" "sess-repo-b" "true" "$REPO_B"
    # Invocation 1: REPO_A — REPO_B's event is filtered; clean run advances REPO_A's checkpoint.
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_REPO="$REPO_A" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    checked1="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["checked"])')"
    [ "$checked1" = "0" ]
    # Invocation 2: REPO_B — per-repo checkpoint absent → seeds from legacy T0 →
    # evaluates T1 event → no provenance → violation.  REPO_A's checkpoint advance
    # must NOT have affected this result.
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_REPO="$REPO_B" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    result2="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["status"])')"
    [ "$result2" = "violations" ]
}

# ---------------------------------------------------------------------------
# R7: Legacy-checkpoint seeding — when only the global checkpoint file is present
#     (no per-repo file), the per-repo run must honor it.  A pre-checkpoint event
#     must be filtered (checked=0) — no 30-day re-evaluation storm on first deploy.
# ---------------------------------------------------------------------------
@test "R7: legacy-checkpoint seeding — pre-checkpoint event filtered on first per-repo run" {
    local REPO="$HOME/repo-r7"
    # Seed legacy global checkpoint at T0 (no CAST_RECONCILE_CHECKPOINT env).
    mkdir -p "$HOME/.claude/run"
    printf '%s' "$T0" > "$HOME/.claude/run/commit-reconcile-checkpoint"
    # Write event BEFORE T0 (should be filtered once legacy is seeded).
    write_hatch_event "2026-01-01T10:00:00" "sess-pre-ckpt" "true" "$REPO"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_REPO="$REPO" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    checked="$(echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["checked"])')"
    [ "$checked" = "0" ]
}
