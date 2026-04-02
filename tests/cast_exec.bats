#!/usr/bin/env bats
# cast_exec.bats — Tests for cast-exec.sh (Phase 9.75b)
#
# Coverage:
#   - cast exec --status exits 0 and prints plan_id / batch info when checkpoint exists
#   - cast exec --resume skips batches whose checkpoint status is 'complete'
#   - verify_files check: missing file causes non-zero exit and prints the path
#   - checkpoint filename is keyed to plan_id from the manifest

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EXEC_SH="$REPO_DIR/scripts/cast-exec.sh"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Write a minimal plan file with a json dispatch block.
# Usage: _write_plan <plan_file_path> <plan_id> [verify_file]
#
# When verify_file is provided, the batch includes one agent so verify_files
# logic is reached (zero-agent batches short-circuit before verification).
_write_plan() {
  local plan_file="$1"
  local plan_id="$2"
  local verify_file="${3:-}"

  local verify_json="[]"
  local agents_json="[]"
  if [ -n "$verify_file" ]; then
    verify_json="[\"$verify_file\"]"
    # Include one agent so _run_batch reaches the _verify_files call
    agents_json='[{"subagent_type":"commit","prompt":"test task"}]'
  fi

  cat > "$plan_file" <<PLANEOF
# Test Plan: $plan_id

\`\`\`json dispatch
{
  "plan_id": "$plan_id",
  "batches": [
    {
      "id": 1,
      "description": "test batch",
      "parallel": false,
      "agents": $agents_json,
      "verify_files": $verify_json
    }
  ]
}
\`\`\`
PLANEOF
}

# Write a checkpoint file with a given batch status.
# Usage: _write_checkpoint <checkpoint_dir> <plan_id> <batch_id> <status>
_write_checkpoint() {
  local checkpoint_dir="$1"
  local plan_id="$2"
  local batch_id="$3"
  local status="$4"

  mkdir -p "$checkpoint_dir"
  python3 - "$checkpoint_dir" "$plan_id" "$batch_id" "$status" <<'PYEOF'
import sys, json
from pathlib import Path
checkpoint_dir, plan_id, batch_id, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
state = {
    "plan_id": plan_id,
    "plan_file": f"/tmp/{plan_id}.md",
    "started_at": "2026-01-01T00:00:00Z",
    "batches": {
        batch_id: {
            "status": status,
            "started_at": "2026-01-01T00:00:00Z",
            "completed_at": "2026-01-01T00:01:00Z"
        }
    }
}
checkpoint_file = Path(checkpoint_dir) / f"{plan_id}.json"
checkpoint_file.write_text(json.dumps(state, indent=2))
PYEOF
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"

  # cast-exec.sh writes checkpoints under $HOME/.claude/cast/exec-state
  mkdir -p "$HOME/.claude/cast/exec-state"

  # Stub claude so _dispatch_agent never invokes the real CLI
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/bash
echo "Status: DONE"
exit 0
STUB
  chmod +x "$HOME/bin/claude"
  export PATH="$HOME/bin:$PATH"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# T1 — cast exec --status exits 0 and prints JSON-like output when checkpoint exists
# ---------------------------------------------------------------------------

@test "cast exec --status: exits 0 when checkpoint exists" {
  local plan_id="test-plan-status-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "complete"

  run bash "$EXEC_SH" --status "$plan_file"
  assert_success
}

@test "cast exec --status: prints plan_id in output" {
  local plan_id="test-plan-prints-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "complete"

  run bash "$EXEC_SH" --status "$plan_file"
  assert_success
  assert_output --partial "$plan_id"
}

@test "cast exec --status: prints batch status [DONE] when batch is complete" {
  local plan_id="test-plan-batch-done-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "complete"

  run bash "$EXEC_SH" --status "$plan_file"
  assert_success
  assert_output --partial "[DONE]"
}

# ---------------------------------------------------------------------------
# T2 — cast exec --resume skips batches with status=complete in checkpoint
# ---------------------------------------------------------------------------

@test "cast exec --resume: skips batch when checkpoint status is complete" {
  local plan_id="test-plan-resume-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "complete"

  run bash "$EXEC_SH" --resume "$plan_file"
  assert_success
  # Resume mode prints "already complete — skipping" for complete batches
  assert_output --partial "skipping"
}

@test "cast exec --resume: exits 0 when all batches are already complete" {
  local plan_id="test-plan-all-done-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "complete"

  run bash "$EXEC_SH" --resume "$plan_file"
  assert_success
}

@test "cast exec --resume: does not skip batch when checkpoint status is blocked" {
  local plan_id="test-plan-blocked-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"
  _write_checkpoint "$exec_state_dir" "$plan_id" "1" "blocked"

  run bash "$EXEC_SH" --resume "$plan_file"
  # Should attempt execution (no "skipping" for this batch), exits 0 (no agents to run)
  assert_success
  refute_output --partial "Batch 1: already complete"
}

# ---------------------------------------------------------------------------
# T3 — verify_files: missing file causes non-zero exit and prints path
# ---------------------------------------------------------------------------

@test "cast exec: exits non-zero when verify_file is missing" {
  local plan_id="test-plan-verify-$$"
  local plan_file="$HOME/plan.md"
  local missing_file="$HOME/does-not-exist.txt"

  _write_plan "$plan_file" "$plan_id" "$missing_file"

  run bash "$EXEC_SH" "$plan_file"
  assert_failure
}

@test "cast exec: prints missing verify_file path in error output" {
  local plan_id="test-plan-verify-msg-$$"
  local plan_file="$HOME/plan.md"
  local missing_file="$HOME/does-not-exist.txt"

  _write_plan "$plan_file" "$plan_id" "$missing_file"

  run bash "$EXEC_SH" "$plan_file"
  assert_failure
  assert_output --partial "does-not-exist.txt"
}

@test "cast exec: exits 0 when verify_file exists and is non-empty" {
  local plan_id="test-plan-verify-ok-$$"
  local plan_file="$HOME/plan.md"
  local verify_file="$HOME/output.txt"

  echo "content" > "$verify_file"
  _write_plan "$plan_file" "$plan_id" "$verify_file"

  run bash "$EXEC_SH" "$plan_file"
  assert_success
}

@test "cast exec: exits non-zero when verify_file is empty" {
  local plan_id="test-plan-verify-empty-$$"
  local plan_file="$HOME/plan.md"
  local empty_file="$HOME/empty.txt"

  touch "$empty_file"
  _write_plan "$plan_file" "$plan_id" "$empty_file"

  run bash "$EXEC_SH" "$plan_file"
  assert_failure
}

# ---------------------------------------------------------------------------
# T4 — checkpoint filename matches plan_id from the manifest
# ---------------------------------------------------------------------------

@test "cast exec: checkpoint file is named {plan_id}.json" {
  local plan_id="test-plan-ckpt-name-$$"
  local plan_file="$HOME/plan.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file" "$plan_id"

  # Run exec; it may fail (no claude) but should still init the checkpoint
  bash "$EXEC_SH" "$plan_file" 2>/dev/null || true

  run test -f "${exec_state_dir}/${plan_id}.json"
  assert_success
}

@test "cast exec: two different plan_ids produce two separate checkpoint files" {
  local plan_id_a="test-plan-a-$$"
  local plan_id_b="test-plan-b-$$"
  local plan_file_a="$HOME/plan_a.md"
  local plan_file_b="$HOME/plan_b.md"
  local exec_state_dir="$HOME/.claude/cast/exec-state"

  _write_plan "$plan_file_a" "$plan_id_a"
  _write_plan "$plan_file_b" "$plan_id_b"

  bash "$EXEC_SH" "$plan_file_a" 2>/dev/null || true
  bash "$EXEC_SH" "$plan_file_b" 2>/dev/null || true

  run test -f "${exec_state_dir}/${plan_id_a}.json"
  assert_success

  run test -f "${exec_state_dir}/${plan_id_b}.json"
  assert_success
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "cast exec: missing plan file argument exits 2" {
  run bash "$EXEC_SH"
  [ "$status" -eq 2 ]
}

@test "cast exec: non-existent plan file exits 2" {
  run bash "$EXEC_SH" "$HOME/no-such-file.md"
  [ "$status" -eq 2 ]
}

@test "cast exec: plan without json dispatch block exits 1" {
  local plan_file="$HOME/no-dispatch.md"
  echo "# Just a plain markdown file, no dispatch block" > "$plan_file"

  run bash "$EXEC_SH" "$plan_file"
  assert_failure
  assert_output --partial "json dispatch"
}
