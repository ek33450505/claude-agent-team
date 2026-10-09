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
load helpers/prepush-installed

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

# D5b helpers. Identity event = a D5a line (has the "agent_type" key).
# args: ts session_id agent_type agent_id [repo]
write_identity_event() {
    local ts="$1" sid="$2" atype="$3" aid="$4" repo="${5:-}"
    local repo_json=""
    [ -n "$repo" ] && repo_json=",\"repo\":\"$repo\""
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"%s","in_claude_session":true,"agent_type":"%s","agent_id":"%s"%s}\n' \
        "$ts" "$sid" "$atype" "$aid" "$repo_json" >> "$AUDIT_FILE"
}

# Write Claude Code's subagent sidecar. args: session_id agent_id json [subdir]
# subdir "" = flat layout; "workflows/w1" = the workflow layout.
write_sidecar() {
    local sid="$1" aid="$2" json="$3" sub="${4:-}"
    local dir="$HOME/.claude/projects/-tmp-x/$sid/subagents"
    [ -n "$sub" ] && dir="$dir/$sub"
    mkdir -p "$dir"
    printf '%s' "$json" > "$dir/agent-$aid.meta.json"
}

run_reconcile() {
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           PYTHONDONTWRITEBYTECODE=1 \
           "$@" python3 "$RECONCILE"
}

# first violation's field
viol_field() {
    echo "$output" | python3 -c 'import sys,json; print(json.load(sys.stdin)["violations"][0][sys.argv[1]])' "$1"
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

@test "M2b: DB error reason is sanitized in both the JSON and the stderr 'Reason:' line (skip if root)" {
    if [ "$(id -u)" = "0" ]; then
        skip "chmod 000 has no effect as root"
    fi
    write_hatch_event "$T1" "sess-dberr-san" "true"
    chmod 000 "$CAST_DB"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    chmod 644 "$CAST_DB"  # restore so teardown_temp_home can clean up
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "error" ]
    # _sanitize maps every char outside [A-Za-z0-9._:TZ+-] (incl. space) to '?'.
    [[ "$(json_field reason)" == "DB?query?failed:"* ]]
    [[ "$(json_field reason)" != *" "* ]]
    [[ "$stderr" == *"Reason: DB?query?failed:"* ]]
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

# ===========================================================================
# Unverifiable vs missing audit log (inside the Claude Code Bash sandbox
# ~/.claude/logs/audit.jsonl is unreadable; os.path.exists() reported False
# there, so the gate printed a quiet "skip" for a check it never performed).
# ===========================================================================

json_field() {
    echo "$output" | python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

@test "audit missing: genuinely absent file → skip 'audit file not found', exit 0, no WARN" {
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "skip" ]
    [ "$(json_field reason)" = "audit file not found" ]
    [ -z "$stderr" ]
}

@test "audit unreadable: chmod-000 audit file → unverifiable, exit 0, loud stderr WARN, checkpoint kept (skip if root)" {
    if [ "$(id -u)" = "0" ]; then
        skip "chmod 000 has no effect as root"
    fi
    write_hatch_event "$T1" "sess-unreadable" "true"
    chmod 000 "$AUDIT_FILE"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    chmod 644 "$AUDIT_FILE"  # restore so teardown_temp_home can clean up
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "unverifiable" ]
    [[ "$(json_field reason)" == "audit file unreadable: "* ]]
    [[ "$(json_field warning)" == *"NOT performed"* ]]
    [ "$(json_field checked)" = "0" ]
    [[ "$stderr" == *"[CAST WARN]"* ]]
    [[ "$stderr" == *"NOT performed"* ]]
    [[ "$stderr" == *"audit.jsonl"* ]]
    # Nothing was verified, so the checkpoint must not advance.
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

@test "audit unreadable: stat denied (unsearchable parent dir, the sandbox shape) → unverifiable, not skip (skip if root)" {
    if [ "$(id -u)" = "0" ]; then
        skip "chmod 000 has no effect as root"
    fi
    mkdir -p "$HOME/denied"
    printf '' > "$HOME/denied/audit.jsonl"
    chmod 000 "$HOME/denied"
    run --separate-stderr env CAST_AUDIT_PATH="$HOME/denied/audit.jsonl" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    chmod 755 "$HOME/denied"  # restore so teardown_temp_home can clean up
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "unverifiable" ]
    [[ "$(json_field reason)" == "audit file unreadable: "* ]]
    [[ "$stderr" == *"NOT performed"* ]]
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

@test "audit readable: empty readable audit file → clean, exit 0, no WARN (unchanged)" {
    printf '' > "$AUDIT_FILE"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ -z "$stderr" ]
}

# ===========================================================================
# .githooks/pre-push surfaces the reconcile result honestly.
# The hook is driven in a temp git repo against an INSTALLED (temp-HOME)
# ~/.claude/scripts/cast-commit-reconcile.py that is a STUB (prints $STUB_OUT, writes
# $STUB_ERR to stderr, exits $STUB_RC), with every other gate skipped — this isolates
# the reconcile block of the hook. (The hook runs only installed scripts, never repo files.)
# Before the fix the hook discarded the script's stderr on exit 0 and printed
# "reconcile OK" even for an unverifiable (not-performed) check.
# ===========================================================================

prepush_fixture() {
    PP_REPO="$BATS_TEST_TMPDIR/pp-repo"
    mkdir -p "$PP_REPO"
    git init -q "$PP_REPO"
    seed_prepush_install
    printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import os, sys' \
        'sys.stdout.write(os.environ.get("STUB_OUT", "") + "\n")' \
        'sys.stderr.write(os.environ.get("STUB_ERR", "") + "\n")' \
        'sys.exit(int(os.environ.get("STUB_RC", "0")))' \
        > "$INSTALLED/cast-commit-reconcile.py"
    export PP_REPO PRE_PUSH_HOOK
    export CAST_SKIP_PII_CHECK=1 CAST_SKIP_STATS_PUSH=1 CAST_SKIP_DB_CONTRACT=1
    export CAST_SKIP_LEDGER_CHECK=1 CAST_SKIP_RULES_DRIFT=1 CAST_SKIP_README_STRUCTURE=1
}

run_prepush_hook() {
    run --separate-stderr bash -c 'cd "$PP_REPO" && exec bash "$PRE_PUSH_HOOK" </dev/null'
}

@test "pre-push: unverifiable reconcile → stderr WARN surfaced, NOT-verified line, no 'reconcile OK', push allowed" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "unverifiable", "reason": "audit file unreadable: Operation not permitted", "checked": 0, "violations": [], "warning": "D5 commit-provenance check was NOT performed"}'
    export STUB_ERR='[CAST WARN] stub: audit file unreadable'
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "unverifiable"'* ]]
    [[ "$stderr" == *"[CAST WARN] stub: audit file unreadable"* ]]
    [[ "$stderr" == *"reconcile NOT verified (audit log unreadable"* ]]
    [[ "$stderr" == *"audit log unreadable or unparseable"* ]]
    [[ "$stderr" == *"re-push from a normal terminal"* ]]
    [[ "$stderr" == *"check ~/.claude/logs/audit.jsonl"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
}

@test "pre-push: clean reconcile → stdout JSON passed through, 'reconcile OK', stub stderr still discarded" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "clean", "checked": 2, "violations": []}'
    export STUB_ERR='stub-noise-that-must-stay-hidden'
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'{"status": "clean", "checked": 2, "violations": []}'* ]]
    [[ "$output" == *"commit-provenance reconcile OK ✓"* ]]
    [[ "$stderr" != *"stub-noise-that-must-stay-hidden"* ]]
    [[ "$stderr" != *"NOT verified"* ]]
}

@test "pre-push: clean reconcile with unjudged legacy events (cast.db unavailable) → 'partially verified', never plain 'reconcile OK', push allowed" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "clean", "checked": 1, "violations": [], "unjudged_legacy_events": 3, "db_unavailable": "cast.db not found"}'
    export STUB_ERR='stub-noise-that-must-stay-hidden'
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"unjudged_legacy_events": 3'* ]]
    [[ "$stderr" == *"reconcile partially verified: 3 legacy events unjudged (cast.db unavailable)"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
    [[ "$stderr" != *"stub-noise-that-must-stay-hidden"* ]]
}

@test "pre-push: only the exact status key/value counts ('unverifiable' inside another field is a skip, not NOT-verified)" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "skip", "reason": "cast.db not found (was unverifiable before)", "checked": 0, "violations": []}'
    export STUB_ERR=''
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"reconcile SKIPPED (nothing verified)"* ]]
    [[ "$stderr" != *"NOT verified"* ]]
    [[ "$output" != *"reconcile OK"* ]]
}

@test "pre-push: skip reconcile → JSON passed through, 'SKIPPED (nothing verified)', never 'reconcile OK', push allowed" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "skip", "reason": "audit file not found", "checked": 0, "violations": []}'
    export STUB_ERR=''
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "skip"'* ]]
    [[ "$stderr" == *"commit-provenance reconcile SKIPPED (nothing verified) — push allowed"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
    [[ "$stderr" != *"NOT verified"* ]]
}

@test "pre-push: unknown status on exit 0 → treated as skip, never 'reconcile OK'" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "mystery", "checked": 0, "violations": []}'
    export STUB_ERR='stub-detail-for-unknown-status'
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "mystery"'* ]]
    [[ "$stderr" == *"reconcile SKIPPED (nothing verified)"* ]]
    [[ "$stderr" == *"stub-detail-for-unknown-status"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
}

@test "pre-push: exit 0 with empty stdout → treated as skip, never 'reconcile OK'" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT=''
    export STUB_ERR=''
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"reconcile SKIPPED (nothing verified)"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
}

@test "pre-push: acked reconcile → 'reconcile OK' (a check that ran to a verdict), stub stderr hidden" {
    prepush_fixture
    export STUB_RC=0
    export STUB_OUT='{"status": "acked", "checked": 1, "violations": [{"session_id": "s"}]}'
    export STUB_ERR='stub-noise-that-must-stay-hidden'
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "acked"'* ]]
    [[ "$output" == *"commit-provenance reconcile OK ✓"* ]]
    [[ "$stderr" != *"stub-noise-that-must-stay-hidden"* ]]
    [[ "$stderr" != *"reconcile SKIPPED"* ]]
    [[ "$stderr" != *"NOT verified"* ]]
}

@test "pre-push: reconcile exit 1 → push blocked exactly as before (stdout + stderr relayed, ACK hint, no OK)" {
    prepush_fixture
    export STUB_RC=1
    export STUB_OUT='{"status": "violations", "checked": 1, "violations": [{"session_id": "s"}]}'
    export STUB_ERR='stub-violation-detail'
    run_prepush_hook
    [ "$status" -eq 1 ]
    [[ "$output" == *'"status": "violations"'* ]]
    [[ "$stderr" == *"stub-violation-detail"* ]]
    [[ "$stderr" == *"Blocked: unauthorized in-session self-commit detected."* ]]
    [[ "$stderr" == *"CAST_RECONCILE_ACK=1 git push"* ]]
    [[ "$output" != *"reconcile OK"* ]]
}

# ---------------------------------------------------------------------------
# REAL-script end-to-end: the tests above feed the hook a STUB literal, so a change
# to the real script's json.dumps formatting (e.g. separators) would silently drop
# the hook's exact-match onto its fallback branch. These drive the hook with the
# real script (+ its cast_db.py sibling) installed into the temp HOME.
# ---------------------------------------------------------------------------

prepush_real_script_fixture() {
    prepush_fixture
    cp "$RECONCILE" "$INSTALLED/cast-commit-reconcile.py"
    cp "$REPO_ROOT/scripts/cast_db.py" "$INSTALLED/cast_db.py"
    export CAST_AUDIT_PATH="$AUDIT_FILE"
    export CAST_DB_PATH="$CAST_DB"
    export CAST_RECONCILE_CHECKPOINT="$CHECKPOINT"
}

@test "pre-push e2e (real script): chmod-000 audit log → 'NOT verified' shown, no 'reconcile OK', push allowed (skip if root)" {
    if [ "$(id -u)" = "0" ]; then
        skip "chmod 000 has no effect as root"
    fi
    prepush_real_script_fixture
    write_hatch_event "$T1" "sess-unreadable" "true"
    chmod 000 "$AUDIT_FILE"
    run_prepush_hook
    chmod 644 "$AUDIT_FILE"  # restore so teardown_temp_home can clean up
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "unverifiable"'* ]]
    [[ "$stderr" == *"[CAST WARN]"* ]]
    [[ "$stderr" == *"reconcile NOT verified"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

@test "pre-push e2e (real script): readable empty audit log → real 'clean' verdict earns 'reconcile OK'" {
    prepush_real_script_fixture
    printf '' > "$AUDIT_FILE"
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "clean"'* ]]
    [[ "$output" == *"commit-provenance reconcile OK ✓"* ]]
    [[ "$stderr" != *"reconcile SKIPPED"* ]]
    [[ "$stderr" != *"NOT verified"* ]]
}

@test "pre-push e2e (real script): absent audit log → real 'skip' verdict shows SKIPPED, never 'reconcile OK'" {
    prepush_real_script_fixture
    run_prepush_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "skip"'* ]]
    [[ "$stderr" == *"reconcile SKIPPED (nothing verified)"* ]]
    [[ "$output" != *"reconcile OK"* ]]
    [[ "$stderr" != *"reconcile OK"* ]]
}

# S3c rule: the audit log is decoded as strict UTF-8 PER LINE. An undecodable line that
# mentions COMMIT_HATCH_USED may be a damaged hatch event we cannot evaluate -> the
# UnicodeDecodeError propagates -> unverifiable, not a quiet "skip" (never a silent drop).
# An undecodable line WITHOUT that marker is junk: skipped + counted (see the next tests),
# so one stray bad byte cannot switch the provenance check off for every push. Decoding is
# an explicit strict "utf-8" (never the locale default), so the verdict must not depend on
# the runner's locale. These tests run under a latin-1 locale (and with PYTHONUTF8 unset):
# where that locale exists (macOS) a locale-default decode would turn \377 into a silent
# character and the marker-bearing test would fail without the pin; on a host lacking the
# locale Python falls back to its default and the test still checks the mapping.
#
# (Rewritten for S3c: this test previously asserted that ANY non-UTF-8 byte, even on an
# unrelated line, made the whole check unverifiable. It now asserts that only a
# marker-bearing undecodable line does.)
# (Rewritten for D5b, intentional behavior change: a newline-TERMINATED non-UTF-8 line that
# mentions COMMIT_HATCH_USED used to make the whole check unverifiable (exit 0); it is now
# a "corrupt hatch line" VIOLATION (exit 1, Ed 2026-10-04). Only the LAST line of a file
# with no trailing newline (an append in progress) stays unverifiable - tested below.)
@test "audit unparseable: non-UTF-8 line mentioning COMMIT_HATCH_USED (newline-terminated) → corrupt hatch line violation, exit 1" {
    write_hatch_event "$T1" "sess-nonutf8" "true"
    insert_provenance "$PROV_MATCH"
    printf '\377\376 {"event":"COMMIT_HATCH_USED"} not-utf8\n' >> "$AUDIT_FILE"
    run --separate-stderr env -u PYTHONUTF8 LC_ALL=en_US.ISO8859-1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 2)" ]
    [[ "$stderr" == *"corrupt hatch line (line 2)"* ]]
    # Nothing acked: the checkpoint must not advance.
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

@test "audit unparseable: non-UTF-8 hatch line as LAST line without trailing newline → unverifiable (not skip), exit 0, sanitized reason, WARN, checkpoint kept" {
    write_hatch_event "$T1" "sess-nonutf8" "true"
    printf '\377\376 {"event":"COMMIT_HATCH_USED"} not-utf8' >> "$AUDIT_FILE"
    run --separate-stderr env -u PYTHONUTF8 LC_ALL=en_US.ISO8859-1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "unverifiable" ]
    [[ "$(json_field reason)" == "audit file unreadable: "* ]]
    [[ "$(json_field reason)" == *"utf-8"* ]]
    # The exception text is sanitized: no quote / space survives into the reason.
    [[ "$(json_field reason)" != *"'"* ]]
    [[ "$(json_field warning)" == *"NOT performed"* ]]
    [ "$(json_field checked)" = "0" ]
    [[ "$stderr" == *"[CAST WARN]"* ]]
    [[ "$stderr" == *"NOT performed"* ]]
    # Nothing was verified, so the checkpoint must not advance.
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

# A non-UTF-8 line that does NOT mention COMMIT_HATCH_USED is junk: the real hatch event
# is still evaluated (a violation here blocks the push), and the skipped junk is counted
# in the JSON. Junk lines sit both BEFORE and AFTER the event so ordering can't matter.
@test "audit junk byte: unrelated non-UTF-8 lines do NOT disable the check → real violation still blocks, junk counted" {
    printf '\377\376 junk-before\n' >> "$AUDIT_FILE"
    write_hatch_event "$T1" "sess-junk-viol" "true"
    printf 'junk-after \377\n' >> "$AUDIT_FILE"
    run --separate-stderr env -u PYTHONUTF8 LC_ALL=en_US.ISO8859-1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    [ "$(json_field checked)" = "1" ]
    [[ "$output" == *"sess-junk-viol"* ]]
    [ "$(json_field skipped_undecodable_lines)" = "2" ]
    [[ "$stderr" == *"Unauthorized in-session self-commit"* ]]
}

@test "audit junk byte: unrelated non-UTF-8 line + provenance in window → clean exit 0, checkpoint advances, junk counted" {
    write_hatch_event "$T1" "sess-junk-ok" "true"
    printf '\377\376 junk\n' >> "$AUDIT_FILE"
    insert_provenance "$PROV_MATCH"
    run --separate-stderr env -u PYTHONUTF8 LC_ALL=en_US.ISO8859-1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field checked)" = "1" ]
    [ "$(json_field skipped_undecodable_lines)" = "1" ]
    # The check ran, so (unlike unverifiable) the checkpoint advanced past T0.
    [ "$(cat "$CHECKPOINT")" != "$T0" ]
}

@test "audit junk byte: ack mode still acks the real violation alongside a junk line" {
    write_hatch_event "$T1" "sess-junk-ack" "true"
    printf '\377 junk\n' >> "$AUDIT_FILE"
    run --separate-stderr env CAST_RECONCILE_ACK=1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "acked" ]
    [ "$(json_field checked)" = "1" ]
    [ "$(json_field skipped_undecodable_lines)" = "1" ]
}

# Only junk bytes, no hatch marker anywhere -> nothing to evaluate -> clean (not
# unverifiable): there is no hatch event we failed to read.
@test "audit junk byte: file of only non-UTF-8 junk (no hatch marker) → clean, checked 0, junk counted" {
    printf '\377\376\375\n\200\201 more junk\n' > "$AUDIT_FILE"
    run --separate-stderr env -u PYTHONUTF8 LC_ALL=en_US.ISO8859-1 CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field checked)" = "0" ]
    [ "$(json_field skipped_undecodable_lines)" = "2" ]
}

# With no undecodable line the JSON is unchanged: the counter key appears only when > 0.
@test "audit junk byte: no undecodable lines → no skipped_undecodable_lines key" {
    write_hatch_event "$T1" "sess-nojunk" "true"
    insert_provenance "$PROV_MATCH"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [[ "$output" != *"skipped_undecodable_lines"* ]]
}

# The per-line binary read must keep text-mode universal-newline boundaries: a lone \r
# separates records exactly as \n does, so two events joined by \r are BOTH evaluated
# (a naive split on \n alone would fuse them into one unparseable line and silently
# drop both).
@test "audit newlines: events separated by a lone \\r are both evaluated" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"sess-cr-a","in_claude_session":true}\r{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"sess-cr-b","in_claude_session":true}\n' \
        "$T1" "$T1" > "$AUDIT_FILE"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    [ "$(json_field checked)" = "2" ]
    [[ "$output" == *"sess-cr-a"* ]]
    [[ "$output" == *"sess-cr-b"* ]]
}

@test "audit bad lines: non-dict JSON line ([]) does not hide a later real violation" {
    printf '[]\n' >> "$AUDIT_FILE"
    printf '"str"\n3\n' >> "$AUDIT_FILE"
    write_hatch_event "$T1" "sess-after-nondict" "true"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    echo "$output" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); assert any(v["session_id"]=="sess-after-nondict" for v in d["violations"]), d'
}

@test "audit bad lines: NUL-in-repo line does not hide a later real violation" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"sess-nul","in_claude_session":true,"repo":"/a\\u0000b"}\n' "$T1" >> "$AUDIT_FILE"
    write_hatch_event "$T1" "sess-after-nul" "true"
    run --separate-stderr env CAST_AUDIT_PATH="$AUDIT_FILE" \
           CAST_DB_PATH="$CAST_DB" \
           CAST_RECONCILE_CHECKPOINT="$CHECKPOINT" \
           CAST_RECONCILE_REPO="$HOME" \
           python3 "$RECONCILE"
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    echo "$output" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); assert any(v["session_id"]=="sess-after-nul" for v in d["violations"]), d'
}


# ===========================================================================
# D5b: identity events - WHO made the hatch commit (sidecar-resolved, never the
# event's own agent_type)
# ===========================================================================

@test "D5b a: identity event, sidecar agentType commit → clean exit 0 even with NO provenance row" {
    write_identity_event "$T1" "sess-id1" "commit" "agentaaa1"
    write_sidecar "sess-id1" "agentaaa1" '{"agentType":"commit","spawnDepth":1}'
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field checked)" = "1" ]
}

@test "D5b b: identity event with empty agent_id → main-session hatch violation exit 1, even WITH a provenance row" {
    write_identity_event "$T1" "sess-id1" "" ""
    insert_provenance "$PROV_MATCH"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    [ "$(viol_field reason)" = "main-session hatch" ]
    [ "$(viol_field agent_id)" = "" ]
    [[ "$stderr" == *"main-session hatch"* ]]
    [[ "$stderr" == *"commit__<label>"* ]]
    [[ "$stderr" == *"CAST_RECONCILE_ACK=1"* ]]
}

@test "D5b c: name-spoof sidecar (agentType==name==commit) → unverifiable violation, event agent_type is not trusted" {
    write_identity_event "$T1" "sess-id1" "commit" "agentccc1"
    write_sidecar "sess-id1" "agentccc1" '{"agentType":"commit","name":"commit"}'
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "commit-agent identity unverifiable (no trusted sidecar)" ]
    [ "$(viol_field agent_type)" = "commit" ]
    [ "$(viol_field agent_id)" = "agentccc1" ]
}

@test "D5b c2: identity event claiming commit but NO sidecar at all → unverifiable violation" {
    write_identity_event "$T1" "sess-id1" "commit" "agentnone"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "commit-agent identity unverifiable (no trusted sidecar)" ]
}

@test "D5b d: sidecar agentType backend-writer → 'agent backend-writer is not the commit agent'" {
    write_identity_event "$T1" "sess-id1" "commit" "agentddd1"
    write_sidecar "sess-id1" "agentddd1" '{"agentType":"backend-writer"}'
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "agent backend-writer is not the commit agent" ]
    [[ "$stderr" == *"agent backend-writer is not the commit agent"* ]]
}

@test "D5b e: named teammate shape with customAgentType commit → clean" {
    write_identity_event "$T1" "sess-id1" "commit__x" "agenteee1"
    write_sidecar "sess-id1" "agenteee1" '{"agentType":"commit__x","name":"commit__x","taskKind":"in_process_teammate","customAgentType":"commit"}'
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
}

@test "D5b f: two candidate sidecars (flat + workflows/w1) for one agent_id → unverifiable violation" {
    write_identity_event "$T1" "sess-id1" "commit" "agentfff1"
    write_sidecar "sess-id1" "agentfff1" '{"agentType":"commit","spawnDepth":1}'
    write_sidecar "sess-id1" "agentfff1" '{"agentType":"commit","spawnDepth":1}' "workflows/w1"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "commit-agent identity unverifiable (no trusted sidecar)" ]
}

@test "D5b g: legacy event (no agent_type key) keeps the window rule - row in window → clean" {
    write_hatch_event "$T1" "sess-leg" "true"
    insert_provenance "$PROV_MATCH"
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
}

@test "D5b g2: legacy event (no agent_type key) with no row in window → violation" {
    write_hatch_event "$T1" "sess-leg" "true"
    insert_provenance "$PROV_OUTSIDE"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(json_field status)" = "violations" ]
    [[ "$output" != *'"agent_type"'* ]]
}

@test "D5b h1: truncated-JSON line mentioning COMMIT_HATCH_USED mid-file → corrupt hatch line violation, exit 1" {
    write_hatch_event "$T1" "sess-ok" "false"
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl\n' "$T1" >> "$AUDIT_FILE"
    write_hatch_event "$T1" "sess-ok2" "false"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 2)" ]
    [[ "$stderr" == *"corrupt hatch line (line 2)"* ]]
}

@test "D5b h2: non-UTF-8 line mentioning COMMIT_HATCH_USED mid-file → corrupt hatch line violation, exit 1" {
    write_hatch_event "$T1" "sess-ok" "false"
    printf '\377\376 COMMIT_HATCH_USED\n' >> "$AUDIT_FILE"
    write_hatch_event "$T1" "sess-ok2" "false"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 2)" ]
}

@test "D5b h3: non-object JSON line mentioning COMMIT_HATCH_USED → corrupt hatch line violation" {
    printf '["COMMIT_HATCH_USED"]\n' >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 1)" ]
}

@test "D5b h4: truncated-JSON hatch line as LAST line without trailing newline → unverifiable, exit 0, checkpoint kept" {
    write_hatch_event "$T1" "sess-ok" "false"
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl' "$T1" >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "unverifiable" ]
    [[ "$(json_field warning)" == *"NOT performed"* ]]
    [ "$(cat "$CHECKPOINT")" = "$T0" ]
}

@test "D5b h5: the same truncated line WITH a trailing newline → violation (newline decides)" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl\n' "$T1" >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 1)" ]
}

@test "D5b h6: corrupt line → violation; ACK run acks it and records its sha256; next non-ACK run → clean with acked_corrupt_lines 1" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl\n' "$T1" >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 1)" ]

    run_reconcile CAST_RECONCILE_ACK=1
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "acked" ]
    want="$(head -n 1 "$AUDIT_FILE" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)"
    ack_line="$(grep RECONCILE_ACK_USED "$AUDIT_FILE")"
    [[ "$ack_line" == *"\"corrupt_line_sha256\": [\"$want\"]"* ]]

    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field acked_corrupt_lines)" = "1" ]
}

@test "D5b h7: a DIFFERENT corrupt line after an acked one → violation again" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl\n' "$T1" >> "$AUDIT_FILE"
    run_reconcile CAST_RECONCILE_ACK=1
    [ "$status" -eq 0 ]
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"other","in_c\n' "$T1" >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "corrupt hatch line (line 4)" ]
}

@test "D5b h8: a forged RECONCILE_ACK_USED carrying the line's hash is accepted (documented cooperative boundary)" {
    printf '{"event":"COMMIT_HATCH_USED","timestamp":"%s","session_id":"s","in_cl\n' "$T1" >> "$AUDIT_FILE"
    h="$(head -n 1 "$AUDIT_FILE" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)"
    printf '{"event":"RECONCILE_ACK_USED","corrupt_line_sha256":["%s"]}\n' "$h" >> "$AUDIT_FILE"
    run_reconcile
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field acked_corrupt_lines)" = "1" ]
}

@test "D5b i: CAST_RECONCILE_ACK=1 acks a main-session violation → exit 0 acked, RECONCILE_ACK_USED appended, checkpoint advanced" {
    write_identity_event "$T1" "sess-id1" "" ""
    run_reconcile CAST_RECONCILE_ACK=1
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "acked" ]
    [ "$(viol_field reason)" = "main-session hatch" ]
    grep -q RECONCILE_ACK_USED "$AUDIT_FILE"
    [ "$(cat "$CHECKPOINT")" != "$T0" ]
}

@test "D5b j: foreign-repo identity event is still skipped" {
    local other="$HOME/other-repo" mine="$HOME/my-repo"
    mkdir -p "$other" "$mine"
    write_identity_event "$T1" "sess-id1" "" "" "$other"
    run_reconcile CAST_RECONCILE_REPO="$mine"
    [ "$status" -eq 0 ]
    [ "$(json_field status)" = "clean" ]
    [ "$(json_field checked)" = "0" ]
}

@test "D5b k: own-repo main-session identity event IS judged (repo scoping keeps matching events)" {
    local mine="$HOME/my-repo"
    mkdir -p "$mine"
    write_identity_event "$T1" "sess-id1" "" "" "$mine"
    run_reconcile CAST_RECONCILE_REPO="$mine"
    [ "$status" -eq 1 ]
    [ "$(viol_field reason)" = "main-session hatch" ]
}
