#!/usr/bin/env bats
# tests/claude-subprocess-guard-contract.bats
#
# CONTRACT: Every "observer" hook script (hooks that log/emit data but do not
# block or gate operations) MUST exit 0 with no output and no filesystem writes
# when CLAUDE_SUBPROCESS=1 is set. This file is the single authoritative test
# for that invariant across all observer scripts.
#
# WHY A SEPARATE FILE: The per-file subprocess guard tests were identical in
# intent and nearly identical in code. Consolidating them here removes 16
# near-duplicate test blocks, makes the invariant explicit, and ensures that
# adding a new observer script only requires one line in the list below.
#
# KEEPER TAXONOMY — scripts NOT covered here (maintained in their own files):
#   blocking-guard bypass: cast-tilde-write-guard, cast-no-fake-success-guard,
#     cast-stat-claim-guard, pre-tool-guard, test_push_agent_stash_guard,
#     cast-code-ref-guard — blockers pass '{}' with exit 0 even without the
#     guard, so only the bypass tests detect guard removal.
#   CLI-shaped scripts: cast-notify (whitelist), cast-overlay-sync,
#     cast-memory-review — invoked directly, not via stdin hook pattern.
#   payload-based count asserts: test_cast_truncation_check,
#     test_cast_agent_protocol_check — guard is correct but the value of these
#     tests is in the count/content assertions, not the guard check alone.
#   headless-guard responder: cast-headless-guard.bats — separate contract.
#   post-tool-hook subprocess BEHAVIOR tests: post-tool-hook.bats — the guard
#     here is coupled to the Write/Edit formatter behavior being suppressed.
#   agent-status-reader inverted guard: agent-status-reader.bats — guard exits
#     non-zero intentionally (inverted semantics).
#
# OBSERVER SCRIPT LIST (15 scripts whose per-file guard tests were removed):
#   scripts/cast-session-end.sh
#   scripts/cast-user-prompt-hook.sh
#   scripts/cast-task-created-hook.sh
#   scripts/cast-session-start-health.sh
#   scripts/cast-filechanged-hook.sh
#   scripts/cast-cwdchanged-hook.sh
#   scripts/cast-session-start-hook.sh
#   scripts/cast-subagent-worktree-check.sh
#   scripts/cast-instructions-loaded-hook.sh
#   scripts/cast-tool-failure-hook.sh
#   scripts/cast-time-context-hook.sh
#   scripts/cast-post-compact-hook.sh
#   scripts/cast-session-start-journal.sh
#   scripts/cast-precompact-memory-save.sh
#   scripts/cast-duration-check.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Resolve repo root relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# The canonical list of observer scripts. Paths are repo-relative from REPO_DIR.
OBSERVER_SCRIPTS=(
  "scripts/cast-session-end.sh"
  "scripts/cast-user-prompt-hook.sh"
  "scripts/cast-task-created-hook.sh"
  "scripts/cast-session-start-health.sh"
  "scripts/cast-filechanged-hook.sh"
  "scripts/cast-cwdchanged-hook.sh"
  "scripts/cast-session-start-hook.sh"
  "scripts/cast-subagent-worktree-check.sh"
  "scripts/cast-instructions-loaded-hook.sh"
  "scripts/cast-tool-failure-hook.sh"
  "scripts/cast-time-context-hook.sh"
  "scripts/cast-post-compact-hook.sh"
  "scripts/cast-session-start-journal.sh"
  "scripts/cast-precompact-memory-save.sh"
  "scripts/cast-duration-check.sh"
)

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  mkdir -p "$HOME/.claude/cast"
  unset CLAUDE_SUBPROCESS
  unset CAST_DB_PATH
  unset CAST_INPUT
  unset CLAUDE_SESSION_ID
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: All listed scripts exist on disk
# Fails loudly naming each missing path so renames are caught immediately.
# ---------------------------------------------------------------------------

@test "contract list: every script exists" {
  local failures=()
  for rel in "${OBSERVER_SCRIPTS[@]}"; do
    local path="$REPO_DIR/$rel"
    if [[ ! -f "$path" ]]; then
      failures+=("MISSING: $path")
    fi
  done
  if [[ "${#failures[@]}" -gt 0 ]]; then
    echo "The following observer scripts are missing (rename or delete without updating this contract):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Every observer hook exits 0, produces no output, and writes no
# new files to HOME when CLAUDE_SUBPROCESS=1.
# Accumulates all failures before asserting so one script does not mask others.
# ---------------------------------------------------------------------------

@test "observer hooks: CLAUDE_SUBPROCESS=1 → exit 0, silent, zero filesystem delta" {
  local failures=()

  for rel in "${OBSERVER_SCRIPTS[@]}"; do
    local script="$REPO_DIR/$rel"

    # Skip missing scripts — test 1 already reports them.
    [[ -f "$script" ]] || continue

    # Record a marker so find can detect any file newer than it.
    local marker
    marker="$(mktemp "$HOME/.cast-guard-marker-XXXXXX")"

    # Run the script under CLAUDE_SUBPROCESS=1, capturing stdout+stderr.
    local actual_output
    local actual_status
    actual_output="$(env CLAUDE_SUBPROCESS=1 CAST_INPUT='{}' bash "$script" <<< '{}' 2>&1)" || true
    actual_status="$?"

    # Dimension 1: exit code must be 0
    if [[ "$actual_status" -ne 0 ]]; then
      failures+=("$rel: exit=$actual_status (expected 0)")
    fi

    # Dimension 2: combined output must be empty
    if [[ -n "$actual_output" ]]; then
      local preview
      preview="$(echo "$actual_output" | head -1 | tr -d '\n')"
      failures+=("$rel: non-empty output: ${preview:0:80}")
    fi

    # Dimension 3: no new files written to HOME (excluding the marker itself)
    local new_files
    new_files="$(find "$HOME" -type f -newer "$marker" ! -path "$marker" 2>/dev/null | tr -d ' ')"
    if [[ -n "$new_files" ]]; then
      local file_list
      file_list="$(find "$HOME" -type f -newer "$marker" ! -path "$marker" 2>/dev/null | head -3 | tr '\n' ',')"
      failures+=("$rel: filesystem delta — new files: ${file_list%,}")
    fi

    rm -f "$marker"
  done

  if [[ "${#failures[@]}" -gt 0 ]]; then
    echo "CLAUDE_SUBPROCESS=1 contract violations (${#failures[@]}):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    return 1
  fi
}
